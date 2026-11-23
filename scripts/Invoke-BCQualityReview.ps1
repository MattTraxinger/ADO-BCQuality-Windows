#requires -Version 7.5
<#
.SYNOPSIS
    Runs the BCQuality review per app folder (Tier 1 or Tier 2) and the acceptance gate, then converts to SARIF.
.DESCRIPTION
    Tier 1: one agent call to the plugin's al-code-review adapter; structural validation only.
    Tier 2: the pipeline resolves the leaf worklist, dispatches each leaf as a separate agent call,
    validates each, then runs one consolidation call validated against the host-owned composition.
    BCQuality owns every review rule; this script owns execution only (docs/standalone-runner.md).
    Raw agent returns are saved unchanged. A report that fails validation is never published as clean.
.NOTES
    Copilot CLI flags below are marked (verify) and stay so until confirmed on a live run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ContextPath,
    [Parameter(Mandatory)] [string] $AppsPath,
    [Parameter(Mandatory)] [string] $RepoDir,
    [Parameter(Mandatory)] [string] $BCQualityRoot,
    [Parameter(Mandatory)] [string] $BCQualityCommit,
    [Parameter(Mandatory)] [string] $OutDir,
    [Alias('CopilotVersion')] [string] $AgentVersion = 'unknown',
    [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'AgentProvider.ps1')
. (Join-Path $PSScriptRoot 'HostConsolidation.ps1')

$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -Depth 50
$settings = $context.settings
$script:Provider = Get-OptionalProperty $settings.CodeReviewAgent 'provider' 'copilot'
$providerName = (Get-AgentProvider $script:Provider).DisplayName   # throws on an unknown provider, before any agent call
$apps = @(Get-Content -LiteralPath $AppsPath -Raw | ConvertFrom-Json -Depth 20)
$superPath = 'microsoft/skills/review/al-code-review.md'
$script:Normalizations = [System.Collections.Generic.List[object]]::new()
$tools = Join-Path $BCQualityRoot 'tools'
$script:AppIndex = 0
$script:AppCount = $apps.Count

function Format-Duration {
    param([double] $Seconds)
    if ($Seconds -lt 60) { return '{0:n0}s' -f $Seconds }
    '{0}m {1:00}s' -f [math]::Floor($Seconds / 60), [int]($Seconds % 60)
}

function Set-ReviewProgress {
    # Drives the progress bar on the pipeline step: overall percent across app folders.
    param([int] $Done, [int] $Total, [string] $Text)
    $pct = [int][math]::Floor(100 * (($script:AppIndex - 1) + $Done / [math]::Max(1, $Total)) / [math]::Max(1, $script:AppCount))
    Write-Host "##vso[task.setprogress value=$pct;]$Text"
}

function Write-ReviewHeader {
    $short = { param($s) if ($s) { $s.Substring(0, [math]::Min(8, $s.Length)) } }
    $model = { param($m) if ($m) { $m } else { "$providerName default" } }
    Write-Host '=============================================================='
    Write-Host ' BCQuality pull request review'
    Write-Host '=============================================================='
    Write-Host "  Reviewing : head $(& $short $context.headSha) against $($context.targetBranch) (merge base $(& $short $context.mergeBase))"
    Write-Host "  Scope     : $(@($context.changedFiles).Count) changed AL/app.json file(s) in $($apps.Count) app folder(s)"
    Write-Host "  Review    : tier $($settings.tier), mode $($settings.mode)"
    Write-Host "  BCQuality : v$($settings.BCQuality.version) at $(& $short $BCQualityCommit); layers: $(@($settings.BCQuality.enabledLayers) -join ', ')"
    Write-Host "  Agent     : $providerName $AgentVersion; leaf model: $(& $model $(if ($settings.CodeReviewAgent.leafModel) { $settings.CodeReviewAgent.leafModel } else { $settings.CodeReviewAgent.model })); consolidation model: $(& $model $settings.CodeReviewAgent.model)"
    foreach ($a in $apps) {
        Write-Host "  App       : $($a.folder)"
        foreach ($f in $a.files) { Write-Host "              - $f" }
    }
    Write-Host '=============================================================='
}
Write-ReviewHeader

$script:CallLog = [System.Collections.Generic.List[object]]::new()
$script:CurrentAppName = ''

function Invoke-Agent {
    # Single entry point to the configured provider (scripts/AgentProvider.ps1). Every call, successful or not, goes
    # in the call log with its requested model, timing and the provider-reported usage (scripts/Metrics.ps1).
    param([string] $Prompt, [string] $Model, [string[]] $AddDirs, [string] $Role = 'root', [string] $SkillId = '', [int] $Attempt = 1)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $entry = [ordered]@{ app = $script:CurrentAppName; role = $Role; skillId = $SkillId; attempt = $Attempt
        requestedModel = $Model; ok = $false; seconds = 0; error = $null; usage = $null }
    try {
        $call = Invoke-AgentCall -Provider $script:Provider -Prompt $Prompt -Model $Model -AddDirs $AddDirs `
            -WorkingDirectory $RepoDir -BCQualityRoot $BCQualityRoot -TimeoutSeconds $TimeoutSeconds `
            -SharedContextPath $script:SharedContextPath
        $entry.ok = $true
        $entry.usage = Get-OptionalProperty $call 'usage'
        Write-Host "  usage: $(Format-AgentUsage $entry.usage)"
        $call
    }
    catch { $entry.error = $_.Exception.Message; throw }
    finally { $entry.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); $script:CallLog.Add([pscustomobject]$entry) }
}

function Get-InstructionsClause {
    # How a leaf prompt points at entry.md and do.md. With a shared-context file they are already in the system
    # prompt; the fallback sentence keeps a call working if the CLI did not load that file.
    if ($script:SharedContextPath) {
        return "Your system prompt, under 'BCQuality shared instructions', already contains BCQuality's skills/entry.md and skills/do.md; do not read them again " +
            "(relative paths in them resolve against $BCQualityRoot). If that section is missing, read $BCQualityRoot/skills/entry.md and $BCQualityRoot/skills/do.md first."
    }
    "Read $BCQualityRoot/skills/entry.md and $BCQualityRoot/skills/do.md."
}

function New-SharedContext {
    # BCQuality's entry.md and do.md are read by every call (about 16k tokens). For a provider that can place a file
    # in its system prompt they go there instead, once and byte-identical for every call, so the API cache serves
    # them to all but the first call. The file holds nothing that varies per call or per app (no paths, no times).
    # Returns the file's path, or $null when the provider cannot use it (the prompts then say to read the files).
    if (-not (Test-AgentSharedContext $script:Provider)) { return $null }
    $parts = foreach ($name in 'entry.md', 'do.md') {
        $p = Join-Path $BCQualityRoot "skills/$name"
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        "## skills/$name`n`n" + ((Get-Content -LiteralPath $p -Raw) -replace "`r`n", "`n").TrimEnd()
    }
    $text = "# BCQuality shared instructions`n`nThe two documents below are BCQuality's skills/entry.md and skills/do.md. They are already loaded " +
        "here, so a task that tells you to read them is satisfied by this section; do not read them from disk.`n`n" + ($parts -join "`n`n") + "`n"
    $path = Join-Path $OutDir 'shared-context.md'
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    $path
}
$script:SharedContextPath = if ($settings.tier -eq 1) { $null } else { New-SharedContext }   # tier 1 is one call: nothing to share
if ($script:SharedContextPath) { Write-Host "Shared prompt prefix: $((Get-Item -LiteralPath $script:SharedContextPath).Length) bytes of entry.md and do.md in the system prompt (cached once per run)" }

function Get-JsonObjectText {
    param([string] $Text)
    $first = $Text.IndexOf('{'); $last = $Text.LastIndexOf('}')
    if ($first -lt 0 -or $last -le $first) { throw 'No JSON object in agent output.' }
    $Text.Substring($first, $last - $first + 1)
}

function Get-GateDetail {
    # Strips PowerShell's error frame ("Line | 36 | throw ... ~~~~") and keeps the validator's own message.
    param([string] $Message)
    $flat = ($Message -replace '\s*\r?\n\s*\|?\s*', ' ' -replace '\s+', ' ').Trim()
    foreach ($marker in 'Findings-report acceptance failed:', 'Invalid findings-report JSON or schema:', 'Invalid expected composition:') {
        $i = $flat.LastIndexOf($marker)   # the frame quotes the throw line first; the real message is last
        if ($i -ge 0) { return $flat.Substring($i).Trim() }
    }
    ($flat -replace '~+', '' -replace '\s+', ' ').Trim()
}

function Test-Report {
    # Runs the BCQuality validator in-process: it throws on rejection and returns { normalized, report, removedRanges }.
    # DO's bounded optional-range repair is allowed; the repaired copy replaces the candidate at $Path (the raw
    # return stays in raw/), and each removed range goes to private telemetry only, never into the report.
    param([string] $Path, [string] $Kind, [string[]] $SourcePaths, [string] $CompositionPath, [string[]] $RetrievedPaths = @())
    $v = @{ ReportPath = $Path; BCQualityRoot = $BCQualityRoot; SourceRoot = $RepoDir; SkillKind = $Kind
        AllowBoundedNormalization = $true; RetrievedArticlePaths = $RetrievedPaths }
    if ($SourcePaths) { $v.SourcePaths = $SourcePaths }
    if ($CompositionPath) { $v.ExpectedCompositionPath = $CompositionPath }
    try { $r = & (Join-Path $tools 'Validate-FindingsReport.ps1') @v }
    catch { return [pscustomobject]@{ ok = $false; message = ($_ | Out-String).Trim() } }
    if ($r.normalized) {
        Write-Json -Object $r.report -Path $Path
        foreach ($removed in $r.removedRanges) { $script:Normalizations.Add([ordered]@{ report = $Path; removed = $removed }) }
    }
    [pscustomobject]@{ ok = $true; message = '' }
}

function New-FailedReport {
    # Host-created failed report: schema-shaped, no findings, never clean.
    param([string] $Id, [int] $Version, [string] $Reason)
    [ordered]@{
        skill = [ordered]@{ id = $Id; version = $Version }; outcome = 'failed'; 'outcome-reason' = $Reason
        summary = [ordered]@{ counts = [ordered]@{ blocker = 0; major = 0; minor = 0; info = 0 }
            coverage = [ordered]@{ 'worklist-size' = 0; 'items-evaluated' = 0 } }
        findings = @()
        suppressed = @()
    }
}

function New-TaskContext {
    param([string] $Goal, [string[]] $Inputs)
    $tc = [ordered]@{ goal = $Goal; 'inputs-available' = @($Inputs); technologies = @('al');
        'enabled-layers' = @($settings.BCQuality.enabledLayers) }
    if (@($settings.BCQuality.disabledSkills).Count) { $tc['disabled-skills'] = @($settings.BCQuality.disabledSkills) }
    if ($settings.bcVersion) { $tc['bc-version'] = $settings.bcVersion }
    $tc | ConvertTo-Json -Depth 10 -Compress
}

function Invoke-Tier1 {
    param($App, [string] $Work, [string[]] $AddDirs)
    $diffs = Join-Path $App.dir 'diff'
    $prompt = "Follow $BCQualityRoot/skills/al-code-review/SKILL.md with PLUGIN_ROOT=$BCQualityRoot. " +
        "Review the pull request changes for app folder '$($App.folder)'. The input type is pr-diff; per-file unified diffs are under $diffs, and the final sources are in $RepoDir. " +
        "task-context: $(New-TaskContext 'Review this pull request' @('pr-diff')). Return only the findings-report JSON."
    $raw = Join-Path $Work 'raw/review.txt'
    $tag = "[app $($script:AppIndex)/$($script:AppCount) | step 1/1]"
    Write-Host ">> $tag quick-start review of '$($App.folder)' (one agent call)"
    Set-ReviewProgress -Done 0 -Total 1 -Text 'Quick-start review'
    $call = Invoke-Agent -Prompt $prompt -Model $settings.CodeReviewAgent.model -AddDirs $AddDirs -Role root -SkillId 'al-code-review'
    New-Item -ItemType Directory -Path (Split-Path $raw) -Force | Out-Null
    Set-Content -LiteralPath $raw -Value $call.text -Encoding utf8
    $candidate = Join-Path $Work 'accepted-report.json'
    Set-Content -LiteralPath $candidate -Value (Get-JsonObjectText $call.text) -Encoding utf8
    $v = Test-Report -Path $candidate -Kind 'super' -SourcePaths $App.files -RetrievedPaths $call.retrieved
    [pscustomobject]@{ valid = $v.ok; message = $v.message; leaves = @() }
}

function Invoke-Tier2 {
    param($App, [string] $Work, [string[]] $AddDirs)
    $worklist = & (Join-Path $tools 'Resolve-SkillWorklist.ps1') -BCQualityRoot $BCQualityRoot -SuperSkillPath $superPath `
        -EnabledLayers @($settings.BCQuality.enabledLayers) -DisabledSkills @($settings.BCQuality.disabledSkills)
    $index = Get-Content -LiteralPath (Join-Path $BCQualityRoot 'skill-index.json') -Raw | ConvertFrom-Json -Depth 50
    $host_ = Join-Path $Work 'host'            # host-owned, never given to the agent
    $acceptedDir = Join-Path $host_ 'accepted'
    $composeIn = Join-Path $Work 'compose-input' # agent-readable copies for consolidation
    foreach ($d in $acceptedDir, $composeIn, (Join-Path $Work 'raw')) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

    # Expected composition is fixed before any agent call. Resolver skips carry no version: enrich from the index.
    $skipped = @($worklist.skipped | ForEach-Object {
            $decl = $_.declaredPath; $ver = ($index.skills | Where-Object path -CEQ $decl | Select-Object -First 1).version
            [ordered]@{ id = $_.id; version = $ver; reason = $_.reason } })
    $compositionPath = Join-Path $host_ 'composition.json'
    $composition = [ordered]@{
        superSkill = [ordered]@{ id = $worklist.superSkill.id; version = $worklist.superSkill.version }
        subSkills = @($worklist.subSkills | ForEach-Object { [ordered]@{ id = $_.id; version = $_.version } })
        skipped = $skipped; acceptedResults = @()
    }
    Write-Json -Object $composition -Path $compositionPath

    $leafModel = if ($settings.CodeReviewAgent.leafModel) { $settings.CodeReviewAgent.leafModel } else { $settings.CodeReviewAgent.model }
    $leafOutcomes = [System.Collections.Generic.List[object]]::new()
    $accepted = [System.Collections.Generic.List[object]]::new()
    $allRetrieved = [System.Collections.Generic.HashSet[string]]::new()   # host-recorded reads across all leaves
    $appSw = [Diagnostics.Stopwatch]::StartNew()
    $total = @($worklist.subSkills).Count + 1   # every review area plus the consolidation call
    $done = 0
    Write-Host "App $($script:AppIndex) of $($script:AppCount): '$($App.folder)' - $(@($worklist.subSkills).Count) review areas, then consolidation ($total steps)"
    foreach ($s in $skipped) { Write-Host "   skipped by configuration: $($s.id)" }
    foreach ($leaf in $worklist.subSkills) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tag = "[app $($script:AppIndex)/$($script:AppCount) | step $($done + 1)/$total]"
        Write-Host ">> $tag $($leaf.id) ($($leaf.layer) layer)"
        Set-ReviewProgress -Done $done -Total $total -Text "$($leaf.id) ($($done + 1) of $total)"
        Write-Host "##[group]$tag $($leaf.id): agent activity"
        $acceptedPath = Join-Path $acceptedDir "$($leaf.id).json"
        $candidate = Join-Path $Work "raw/$($leaf.id).json"
        $reason = $null
        $basePrompt = "$(Get-InstructionsClause) Execute only the action skill at $BCQualityRoot/$($leaf.path) " +
            "with input type pr-diff: per-file unified diffs are under $(Join-Path $App.dir 'diff'); final sources are in $RepoDir. " +
            "task-context: $(New-TaskContext 'Review this pull request' @('pr-diff')). " +
            "Before returning, check your report against $BCQualityRoot/schemas/findings-report.schema.json and the producer pre-emission checklist in do.md: " +
            "include every required property (including 'suppressed', as [] when nothing is suppressed), and emit one strict JSON value with every quote and line break inside strings escaped. " +
            "Return only the findings-report JSON."
        $feedback = ''
        # One documented retry replaces a failed attempt (standalone-runner.md); only a rejected report is retried,
        # never a timeout or a Copilot error. Every raw return is kept.
        foreach ($attempt in 1, 2) {
            $reason = $null
            try { $call = Invoke-Agent -Prompt ($basePrompt + $feedback) -Model $leafModel -AddDirs $AddDirs -Role leaf -SkillId $leaf.id -Attempt $attempt }
            catch { $reason = "leaf invocation failed: $($_.Exception.Message)"; break }
            $suffix = if ($attempt -eq 1) { '' } else { '.retry' }
            Set-Content -LiteralPath (Join-Path $Work "raw/$($leaf.id)$suffix.txt") -Value $call.text -Encoding utf8   # raw return, unchanged
            foreach ($p in $call.retrieved) { $null = $allRetrieved.Add($p) }
            try {
                Set-Content -LiteralPath $candidate -Value (Get-JsonObjectText $call.text) -Encoding utf8
                $v = Test-Report -Path $candidate -Kind 'leaf' -SourcePaths $App.files -RetrievedPaths $call.retrieved
            }
            catch { $v = [pscustomobject]@{ ok = $false; message = $_.Exception.Message } }
            if ($v.ok) { Copy-Item -LiteralPath $candidate -Destination $acceptedPath; break }
            $detail = Get-GateDetail $v.message
            Set-Content -LiteralPath (Join-Path $Work "raw/$($leaf.id)$suffix.gate.txt") -Value $v.message -Encoding utf8   # full validator output, for audit
            Write-Host "Attempt $attempt rejected by the acceptance gate: $detail"
            $reason = "leaf report failed validation$(if ($attempt -eq 2) { ' after one retry' }): $($detail.Substring(0, [Math]::Min(400, $detail.Length)))"
            $feedback = " Your previous attempt was rejected by the acceptance gate: $($detail.Substring(0, [Math]::Min(1200, $detail.Length))) Fix every listed defect and return the complete corrected report."
            if ($attempt -eq 1) { Write-Host 'Retrying once.' }
        }
        Write-Host '##[endgroup]'
        if ($reason) { Write-Json -Object (New-FailedReport -Id $leaf.id -Version $leaf.version -Reason $reason) -Path $acceptedPath }
        $accepted.Add([ordered]@{ id = $leaf.id; version = $leaf.version; reportPath = "accepted/$($leaf.id).json" })
        Copy-Item -LiteralPath $acceptedPath -Destination (Join-Path $composeIn "$($leaf.id).json")
        $leafCalls = @($script:CallLog | Where-Object { $_.app -eq $script:CurrentAppName -and $_.role -eq 'leaf' -and $_.skillId -eq $leaf.id })
        $leafOutcomes.Add([ordered]@{ id = $leaf.id; accepted = -not $reason; reason = $reason; seconds = [int]$sw.Elapsed.TotalSeconds
                attempts = $leafCalls.Count; usage = (Merge-AgentUsage @($leafCalls | ForEach-Object { $_.usage })) })
        $done++
        $leafReport = Get-Content -LiteralPath $acceptedPath -Raw | ConvertFrom-Json -Depth 100
        $nFindings = @($leafReport.findings).Count
        $eta = if ($done -lt $total) { ", about $(Format-Duration ($appSw.Elapsed.TotalSeconds / $done * ($total - $done))) left (estimate)" } else { '' }
        Write-Host "<< $tag $($leaf.id): $($leafReport.outcome), $nFindings finding(s), $(Format-Duration $sw.Elapsed.TotalSeconds); elapsed $(Format-Duration $appSw.Elapsed.TotalSeconds)$eta"
        if ($reason) { Write-Host "##vso[task.logissue type=warning]$($leaf.id) could not be reviewed: $($reason.Substring(0, [Math]::Min(250, $reason.Length)))" }
    }
    $composition.acceptedResults = @($accepted)
    Write-Json -Object $composition -Path $compositionPath

    # Consolidation runs only after every leaf has finished.
    $final = Join-Path $Work 'accepted-report.json'
    $tag = "[app $($script:AppIndex)/$($script:AppCount) | step $total/$total]"

    function Invoke-AgentConsolidation {
        # The agent rolls the area reports up (and does the super-skill's self-review pass). It sees the parent's variables.
        Write-Host ">> $tag consolidation: combining $(@($worklist.subSkills).Count) area reports and running the final acceptance gate"
        Set-ReviewProgress -Done ($total - 1) -Total $total -Text "consolidation ($total of $total)"
        Write-Host "##[group]$tag consolidation: agent activity"
        $order = ($worklist.subSkills | ForEach-Object { "$($_.id).json" }) -join ', '
        $doRef = if ($script:SharedContextPath) { "skills/do.md (in your system prompt under 'BCQuality shared instructions'; if that section is missing, read $BCQualityRoot/skills/do.md)" } else { "$BCQualityRoot/skills/do.md" }
        $basePrompt = "Follow the composition, deduplication and outcome rules in $doRef and the super-skill at $BCQualityRoot/$superPath. " +
            "The accepted leaf reports are in $composeIn, in this declared order: $order. Do not re-run or alter any leaf; " +
            "copy them unchanged into sub-results. Skipped leaves: $((($skipped | ConvertTo-Json -Depth 5 -Compress))). Return only the rolled-up findings-report JSON."
        $feedback = ''
        # Same one documented retry as the review areas: only a rejected report is retried, never a failed invocation.
        # A common rejection is a finding silently merged into another one; the validator then names the area to restore.
        foreach ($attempt in 1, 2) {
            $suffix = if ($attempt -eq 1) { '' } else { '.retry' }
            try {
                $call = Invoke-Agent -Prompt ($basePrompt + $feedback) -Model $settings.CodeReviewAgent.model -AddDirs @($composeIn, $BCQualityRoot) -Role root -SkillId 'al-code-review' -Attempt $attempt
                Set-Content -LiteralPath (Join-Path $Work "raw/consolidation$suffix.txt") -Value $call.text -Encoding utf8   # raw return, unchanged
                foreach ($p in $call.retrieved) { $null = $allRetrieved.Add($p) }
                Set-Content -LiteralPath $final -Value (Get-JsonObjectText $call.text) -Encoding utf8
                $v = Test-Report -Path $final -Kind 'super' -SourcePaths $App.files -CompositionPath $compositionPath -RetrievedPaths @($allRetrieved | Sort-Object)
            }
            catch { $v = [pscustomobject]@{ ok = $false; message = "consolidation invocation failed: $($_.Exception.Message)" }; break }
            if ($v.ok) { break }
            $detail = Get-GateDetail $v.message
            Set-Content -LiteralPath (Join-Path $Work "raw/consolidation$suffix.gate.txt") -Value $v.message -Encoding utf8   # full validator output, for audit
            Write-Host "Attempt $attempt rejected by the acceptance gate: $detail"
            $hint = if ($detail -match 'SUPER_FINDING_MISSING') {
                "Every finding from every leaf must still be represented in the rolled-up findings. Do not drop or merge a leaf's finding into another finding, " +
                "including an agent finding (id starting 'agent:'); keep it and prefix a non-citation id with '<from-sub-skill>:' as do.md requires. " } else { '' }
            $feedback = " Your previous attempt was rejected by the acceptance gate: $($detail.Substring(0, [Math]::Min(1200, $detail.Length))) " +
                "${hint}Fix every listed defect and return the complete corrected report."
            if ($attempt -eq 1) { Write-Host 'Retrying once.' }
        }
        Write-Host '##[endgroup]'
        $v
    }

    # Default: the host rolls the reports up in code (scripts/HostConsolidation.ps1): no agent call, deterministic, and
    # every finding is kept. The same acceptance gate checks it; if the gate rejects it, the agent does the roll-up.
    # `consolidation: "agent"` keeps the agent roll-up, which also performs the super-skill's cross-cutting self-review.
    $mode = Get-OptionalProperty $settings.CodeReviewAgent 'consolidation' 'host'
    $how = 'agent'
    $v = $null
    if ($mode -ceq 'host') {
        Write-Host ">> $tag consolidation: merging $(@($worklist.subSkills).Count) area reports in code (no agent call) and running the final acceptance gate"
        Set-ReviewProgress -Done ($total - 1) -Total $total -Text "consolidation ($total of $total)"
        try {
            $leafReports = @($worklist.subSkills | ForEach-Object { Get-Content -LiteralPath (Join-Path $acceptedDir "$($_.id).json") -Raw | ConvertFrom-Json -Depth 100 })
            Write-Json -Object (New-HostRollup -SuperSkill $composition.superSkill -Leaves $leafReports -Skipped $skipped) -Path $final
            $v = Test-Report -Path $final -Kind 'super' -SourcePaths $App.files -CompositionPath $compositionPath -RetrievedPaths @($allRetrieved | Sort-Object)
        }
        catch { $v = [pscustomobject]@{ ok = $false; message = "host consolidation failed: $($_.Exception.Message)" } }
        if ($v.ok) { $how = 'host' }
        else {
            Write-Host "Host roll-up rejected by the acceptance gate, so the agent will do it: $(Get-GateDetail $v.message)"
            if (Test-Path -LiteralPath $final) { Copy-Item -LiteralPath $final -Destination (Join-Path $Work 'raw/consolidation-host.json') -Force }
            Set-Content -LiteralPath (Join-Path $Work 'raw/consolidation-host.gate.txt') -Value $v.message -Encoding utf8
        }
    }
    if ($how -ne 'host') { $v = Invoke-AgentConsolidation }
    Write-Host "<< $tag consolidation ($how): $(if ($v.ok) { 'accepted' } else { 'REJECTED by the acceptance gate' }); app total $(Format-Duration $appSw.Elapsed.TotalSeconds)"
    Set-ReviewProgress -Done $total -Total $total -Text 'consolidation done'
    [pscustomobject]@{ valid = $v.ok; message = $v.message; leaves = @($leafOutcomes); consolidation = $how }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($app in $apps) {
    $script:AppIndex++
    $script:CurrentAppName = $app.name
    $work = Join-Path $OutDir $app.name
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $addDirs = @($RepoDir, $BCQualityRoot, $app.dir)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $run = if ($settings.tier -eq 1) { Invoke-Tier1 $app $work $addDirs } else { Invoke-Tier2 $app $work $addDirs } }
    catch { $run = [pscustomobject]@{ valid = $false; message = $_.Exception.Message; leaves = @() } }

    $reportPath = Join-Path $work 'accepted-report.json'
    if (-not $run.valid) {
        Write-Host "##vso[task.logissue type=warning]Acceptance gate rejected $($app.name): $($run.message)"
        Write-Host "Gate message for $($app.name):`n$($run.message)"
        # Never publish an unvalidated report: replace it with a failed one; the raw payloads stay for audit.
        Write-Json -Object (New-FailedReport -Id 'al-code-review' -Version 1 -Reason "Acceptance gate rejected the review: $($run.message)") -Path $reportPath
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 100
    $sarifPath = Join-Path $work 'bcquality.sarif'
    $sarifArgs = @('-NoProfile', '-File', (Join-Path $tools 'ConvertTo-Sarif.ps1'), '-ReportPath', $reportPath, '-OutputPath', $sarifPath, '-BCQualityRoot', $BCQualityRoot)
    if ($app.folder -ne '.') { $sarifArgs += '-SourcePathPrefix'; $sarifArgs += $app.folder }
    & pwsh @sarifArgs | Out-Null
    $results.Add([ordered]@{
            name = $app.name; folder = $app.folder; files = @($app.files); diffDir = $app.dir
            consolidation = (Get-OptionalProperty $run 'consolidation' 'agent'); outcome = $report.outcome; outcomeReason = (Get-OptionalProperty $report 'outcome-reason'); gate = $run.valid; gateMessage = $run.message
            reportPath = $reportPath; sarifPath = $sarifPath; leaves = @($run.leaves); seconds = [int]$sw.Elapsed.TotalSeconds })
    $failedLeaves = @($run.leaves | Where-Object { -not $_.accepted })
    Write-Host "== App $($script:AppIndex) of $($script:AppCount) '$($app.folder)': $($report.outcome), $(@($report.findings).Count) finding(s), $(Format-Duration $sw.Elapsed.TotalSeconds)$(if ($failedLeaves.Count) { "; NOT reviewed: $(($failedLeaves | ForEach-Object id) -join ', ')" })"
}

$overall = Get-WorstOutcome @($results | ForEach-Object { $_.outcome })
Write-Json -Path (Join-Path $OutDir 'result.json') -Object ([ordered]@{
        outcome = $overall; reviewedHeadSha = $context.headSha; tier = $settings.tier; mode = $settings.mode; apps = @($results) })
# Usage, cost and the requested-vs-observed model check. The full per-call record goes to run-metrics.json;
# diagnostics.json carries the totals.
$runMetrics = New-RunMetrics -Calls @($script:CallLog)
Write-Json -Object $runMetrics -Path (Join-Path $OutDir 'run-metrics.json')
$metricsSummary = [ordered]@{}
foreach ($k in $runMetrics.Keys) { if ($k -ne 'processes') { $metricsSummary[$k] = $runMetrics[$k] } }
Get-RunMetricsLog -Metrics $runMetrics | ForEach-Object { Write-Host $_ }

# The knowledge policy's own record (what the allow/deny rules removed) travels with the review artifact.
$filterReport = Join-Path $BCQualityRoot '_filter-report.json'
$knowledgeFilter = $null
if (Test-Path -LiteralPath $filterReport) {
    Copy-Item -LiteralPath $filterReport -Destination (Join-Path $OutDir 'knowledge-filter-report.json') -Force
    $fr = Get-Content -LiteralPath $filterReport -Raw | ConvertFrom-Json -Depth 20
    $knowledgeFilter = [ordered]@{ allow = @($fr.knowledgeAllow); deny = @($fr.knowledgeDeny); indexedCount = $fr.indexedCount
        removedCount = $fr.removedCount; contentHash = $fr.contentHash }
}
Write-Json -Path (Join-Path $OutDir 'diagnostics.json') -Object ([ordered]@{
        bcqualityRepo = $settings.BCQuality.repo; bcqualityVersion = $settings.BCQuality.version; bcqualityCommit = $BCQualityCommit
        knowledgeFilter = $knowledgeFilter; metrics = $metricsSummary
        provider = $script:Provider; agentCliVersion = $AgentVersion; requestedModel = $settings.CodeReviewAgent.model; requestedLeafModel = $settings.CodeReviewAgent.leafModel
        reviewedHeadSha = $context.headSha; tier = $settings.tier; normalizations = @($script:Normalizations)
        apps = @($results | ForEach-Object { [ordered]@{ name = $_.name; outcome = $_.outcome; seconds = $_.seconds; leaves = $_.leaves } }) })
Write-Host "Review outcome: $overall"
