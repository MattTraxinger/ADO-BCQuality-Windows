# Run metrics, shared by every provider. Each adapter returns `usage` (or $null) in the shape built by New-AgentUsage,
# taken from the CLI's own output (Claude's `result` event, Copilot's session events), never from the model.
# The review script logs every agent call, then New-RunMetrics folds the log into totals, per-call records, and a
# check that the model the CLI reported is the model that was asked for.
#
# Token fields use one convention for both providers: `inputTokens` is fresh (uncached) input only, and cache reads
# and cache writes are separate, so the three add up to the prompt size. A field the provider does not report is
# $null, never 0. Cost is provider-specific: `costUsd` is Claude's API-equivalent cost (not necessarily what is
# billed); `aiCredits` and `premiumRequests` are Copilot's.
# Calls that fail or time out return no usage, so totals are floors; `complete` says whether every call reported.
Set-StrictMode -Version Latest

$script:UsageSumFields = 'inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheCreationTokens', 'reasoningTokens',
    'costUsd', 'aiCredits', 'premiumRequests', 'turns', 'durationMs', 'apiCalls'

function New-AgentUsage {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [string[]] $Models = @(),
        [object] $InputTokens, [object] $OutputTokens, [object] $CacheReadTokens, [object] $CacheCreationTokens,
        [object] $ReasoningTokens, [object] $CostUsd, [object] $AiCredits, [object] $PremiumRequests,
        [object] $Turns, [object] $DurationMs, [object] $ApiCalls,
        [bool] $Complete = $true
    )
    [pscustomobject][ordered]@{
        source              = $Source
        models              = @($Models | Where-Object { $_ } | Sort-Object -Unique)
        inputTokens         = $InputTokens
        outputTokens        = $OutputTokens
        cacheReadTokens     = $CacheReadTokens
        cacheCreationTokens = $CacheCreationTokens
        reasoningTokens     = $ReasoningTokens
        costUsd             = $CostUsd
        aiCredits           = $AiCredits
        premiumRequests     = $PremiumRequests
        turns               = $Turns
        durationMs          = $DurationMs
        apiCalls            = $ApiCalls
        complete            = $Complete
    }
}

function Merge-AgentUsage {
    # Sums usage objects. A field no part reported stays $null; a field some parts reported is the sum of those.
    param([object[]] $Usage)
    $parts = @($Usage | Where-Object { $null -ne $_ })
    if (-not $parts.Count) { return $null }
    $sum = [ordered]@{}
    foreach ($f in $script:UsageSumFields) {
        $vals = @($parts | ForEach-Object { $_.$f } | Where-Object { $null -ne $_ })
        $sum[$f] = if ($vals.Count) { ($vals | Measure-Object -Sum).Sum } else { $null }
    }
    foreach ($f in 'costUsd', 'aiCredits', 'premiumRequests') { if ($null -ne $sum[$f]) { $sum[$f] = [math]::Round([double]$sum[$f], 9) } }
    New-AgentUsage -Source (@($parts | ForEach-Object source | Sort-Object -Unique) -join '+') `
        -Models @($parts | ForEach-Object { $_.models }) `
        -InputTokens $sum.inputTokens -OutputTokens $sum.outputTokens -CacheReadTokens $sum.cacheReadTokens `
        -CacheCreationTokens $sum.cacheCreationTokens -ReasoningTokens $sum.reasoningTokens -CostUsd $sum.costUsd `
        -AiCredits $sum.aiCredits -PremiumRequests $sum.premiumRequests -Turns $sum.turns -DurationMs $sum.durationMs `
        -ApiCalls $sum.apiCalls -Complete (@($parts | Where-Object { -not $_.complete }).Count -eq 0)
}

function Get-ModelCheck {
    # 'verified'       the requested model is among the models the CLI reported (a -YYYYMMDD snapshot suffix is accepted)
    # 'mismatch'       the CLI did not report the requested model, for example an alias that resolved to an older one
    # 'unverifiable'   a model was requested but the CLI reported none
    # 'not-requested'  no model was configured, so the CLI's default was used
    param([string] $Requested, [string[]] $Observed = @())
    if (-not $Requested) { return 'not-requested' }
    $obs = @($Observed | Where-Object { $_ })
    if (-not $obs.Count) { return 'unverifiable' }
    # Verified means the requested model is among the models reported. Claude Code also reports a small helper model
    # (Haiku) for its own side tasks on most calls, so extra models are not a mismatch; Get-OtherModels lists them.
    if (@($obs | Where-Object { Test-IsRequestedModel -Requested $Requested -Model $_ }).Count) { 'verified' } else { 'mismatch' }
}

function Test-IsRequestedModel {
    # The requested name, or a dated snapshot of it (`<name>-YYYYMMDD`). A longer name such as claude-sonnet-5-5 is not
    # a snapshot of claude-sonnet-5.
    param([string] $Requested, [string] $Model)
    $Model -eq $Requested -or $Model -match ('^' + [regex]::Escape($Requested) + '-\d{8}$')
}

function Get-OtherModels {
    # Models the CLI reported besides the requested one (helper models it chose for its own side tasks).
    param([string] $Requested, [string[]] $Observed = @())
    @($Observed | Where-Object { $_ -and -not (Test-IsRequestedModel -Requested $Requested -Model $_) } | Sort-Object -Unique)
}

function Format-AgentUsage {
    param($Usage)
    if ($null -eq $Usage) { return 'not reported' }
    $n = { param($v) ([long]$v).ToString('N0', [cultureinfo]::InvariantCulture) }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Usage.inputTokens -or $null -ne $Usage.outputTokens) {
        $cache = @()
        if ($null -ne $Usage.cacheReadTokens) { $cache += "$(& $n $Usage.cacheReadTokens) cache read" }
        if ($null -ne $Usage.cacheCreationTokens) { $cache += "$(& $n $Usage.cacheCreationTokens) cache write" }
        $t = "in $(& $n $Usage.inputTokens)$(if ($cache) { " (+$($cache -join ', +'))" }), out $(& $n $Usage.outputTokens)"
        if ($null -ne $Usage.reasoningTokens) { $t += ", reasoning $(& $n $Usage.reasoningTokens)" }
        $parts.Add($t)
    }
    if ($null -ne $Usage.costUsd) { $parts.Add(('cost ${0} (API-equivalent)' -f ([double]$Usage.costUsd).ToString('0.0000', [cultureinfo]::InvariantCulture))) }
    if ($null -ne $Usage.aiCredits) { $parts.Add("AI credits $(([double]$Usage.aiCredits).ToString('0.000', [cultureinfo]::InvariantCulture))") }
    if ($null -ne $Usage.premiumRequests) { $parts.Add("premium requests $(([double]$Usage.premiumRequests).ToString('0.##', [cultureinfo]::InvariantCulture))") }
    if (@($Usage.models).Count) { $parts.Add("model $(@($Usage.models) -join ', ')") }
    $parts -join '; '
}

function New-RunMetrics {
    # Folds the call log (one entry per agent call: app, role, skillId, attempt, requestedModel, ok, seconds, error,
    # usage) into totals, per-call records with their model check, and the list of model mismatches.
    param([object[]] $Calls = @())
    $calls = @($Calls)
    $processes = foreach ($c in $calls) {
        $observed = if ($c.usage) { @($c.usage.models) } else { @() }
        [ordered]@{
            app = $c.app; role = $c.role; skillId = $c.skillId; attempt = $c.attempt
            requestedModel = if ($c.requestedModel) { $c.requestedModel } else { $null }
            observedModels = $observed
            modelCheck = $(if ($c.ok) { Get-ModelCheck -Requested $c.requestedModel -Observed $observed } else { 'call-failed' })
            otherModels = @(if ($c.requestedModel) { Get-OtherModels -Requested $c.requestedModel -Observed $observed })
            ok = $c.ok; seconds = $c.seconds; error = $c.error; usage = $c.usage
        }
    }
    $processes = @($processes)
    $withoutUsage = @($calls | Where-Object { $null -eq $_.usage }).Count
    $total = Merge-AgentUsage @($calls | ForEach-Object { $_.usage })
    if ($total -and $withoutUsage) { $total.complete = $false }
    $mismatches = @($processes | Where-Object { $_.modelCheck -eq 'mismatch' } | ForEach-Object {
            [pscustomobject]@{ requested = $_.requestedModel; observed = (@($_.observedModels) -join ', ') } } |
            Sort-Object requested, observed -Unique | ForEach-Object { [ordered]@{ requested = $_.requested; observed = $_.observed } })
    [ordered]@{
        schemaVersion = 1
        calls = $calls.Count
        failedCalls = @($calls | Where-Object { -not $_.ok }).Count
        callsWithoutUsage = $withoutUsage
        usage = $total
        models = @($processes | ForEach-Object { $_.observedModels } | Where-Object { $_ } | Sort-Object -Unique)
        modelMismatches = $mismatches
        otherModels = @($processes | Where-Object { $_.modelCheck -eq 'verified' } | ForEach-Object { $_.otherModels } | Where-Object { $_ } | Sort-Object -Unique)
        processes = $processes
    }
}

function Get-RunMetricsLog {
    # Lines for the step log; warnings use the pipeline's issue syntax so they show on the run summary.
    param([Parameter(Mandatory)] $Metrics)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Usage: $($Metrics.calls) agent call(s), $($Metrics.failedCalls) failed; $(Format-AgentUsage $Metrics.usage)")
    if ($Metrics.callsWithoutUsage) {
        $lines.Add("##vso[task.logissue type=warning]$($Metrics.callsWithoutUsage) of $($Metrics.calls) agent call(s) reported no usage (failed, timed out, or the provider did not report it), so the totals are a lower bound.")
    }
    foreach ($m in @($Metrics.modelMismatches)) {
        $lines.Add("##vso[task.logissue type=warning]Model '$($m.requested)' was requested but the CLI reported '$($m.observed)'. An alias resolves to whatever the CLI treats as current; set a full model name in CodeReviewAgent.model / leafModel.")
    }
    if (@($Metrics.otherModels).Count) {
        $lines.Add("The CLI also reported helper model(s) besides the requested one: $(@($Metrics.otherModels) -join ', '). These are models the CLI picks for its own side tasks, not the review model; the requested model was used.")
    }
    $unverifiable = @($Metrics.processes | Where-Object { $_.modelCheck -eq 'unverifiable' }).Count
    if ($unverifiable) { $lines.Add("##vso[task.logissue type=warning]The CLI reported no model for $unverifiable call(s), so the requested model could not be verified.") }
    $lines
}
