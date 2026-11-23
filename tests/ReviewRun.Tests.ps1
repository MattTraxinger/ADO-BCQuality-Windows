BeforeAll {
    # End-to-end run of Invoke-BCQualityReview.ps1 (tier 2, one review area) against a stub BCQuality root and a fake
    # agent provider, to check what the consolidation step does when the acceptance gate rejects its first report and
    # how the shared prompt prefix is built and handed to the provider.
    $script:realScripts = Join-Path $PSScriptRoot '..\scripts'

    function New-Harness {
        # $Gate: what the stub super-skill gate answers on each consolidation attempt.
        # $Shared: the fake provider accepts a shared-context file (like claude-code).
        # $Consolidation: the CodeReviewAgent.consolidation setting; 'default' leaves it out.
        param([string] $Name, [string[]] $Gate, [bool] $Shared = $false, [int] $Tier = 2, [string] $Consolidation = 'agent')
        $root = Join-Path $TestDrive $Name
        $scripts = Join-Path $root 'scripts'; $bcq = Join-Path $root 'bcq'; $repo = Join-Path $root 'repo'; $out = Join-Path $root 'out'
        New-Item -ItemType Directory -Path $bcq, $repo, $out, (Join-Path $bcq 'tools'), (Join-Path $root 'diff') -Force | Out-Null
        Copy-Item -Path $script:realScripts -Destination $scripts -Recurse
        # Fake provider: records every prompt, returns a minimal report.
        Add-Content -LiteralPath (Join-Path $scripts 'AgentProvider.ps1') -Value @"

function Invoke-FakeAgent {
    param(`$Prompt, `$Model, `$AddDirs, `$WorkingDirectory, `$BCQualityRoot, `$TimeoutSeconds, `$SharedContextPath)
    Add-Content -LiteralPath '$($root -replace "'", "''")\prompts.txt' -Value ('PROMPT: ' + `$Prompt)
    Add-Content -LiteralPath '$($root -replace "'", "''")\shared.txt' -Value ('SHARED: ' + `$SharedContextPath)
    [pscustomobject]@{ text = '{"skill":{"id":"al-error-handling-review","version":1},"outcome":"completed","summary":{"counts":{"blocker":0,"major":0,"minor":0,"info":0},"coverage":{"worklist-size":1,"items-evaluated":1}},"findings":[],"suppressed":[]}'; retrieved = @(); usage = `$null }
}
`$script:AgentProviders['fake'] = @{ DisplayName = 'Fake'; Invoke = 'Invoke-FakeAgent'; SharedContext = `$$Shared }
"@
        New-Item -ItemType Directory -Path (Join-Path $bcq 'skills') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bcq 'skills/entry.md') "ENTRY-DOC`r`nline two"
        Set-Content -LiteralPath (Join-Path $bcq 'skills/do.md') 'DO-DOC'
        Set-Content -LiteralPath (Join-Path $bcq 'skill-index.json') '{"skills":[]}'
        Set-Content -LiteralPath (Join-Path $bcq 'tools/Resolve-SkillWorklist.ps1') @'
param($BCQualityRoot, $SuperSkillPath, $EnabledLayers, $DisabledSkills)
[pscustomobject]@{ superSkill = [pscustomobject]@{ id = 'al-code-review'; version = 1 }
    subSkills = @([pscustomobject]@{ id = 'al-error-handling-review'; version = 1; layer = 'microsoft'; path = 'microsoft/skills/review/al-error-handling-review.md' })
    skipped = @() }
'@
        Set-Content -LiteralPath (Join-Path $bcq 'tools/ConvertTo-Sarif.ps1') 'param($ReportPath, $OutputPath, $BCQualityRoot, $SourcePathPrefix) Set-Content $OutputPath "{}"'
        # Gate: leaves always pass; each super call takes the next answer from the list ('ok' or a rejection message).
        $gateList = ($Gate | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
        Set-Content -LiteralPath (Join-Path $bcq 'tools/Validate-FindingsReport.ps1') @"
param(`$ReportPath, `$BCQualityRoot, `$SourceRoot, `$SkillKind, `$AllowBoundedNormalization, `$RetrievedArticlePaths, `$SourcePaths, `$ExpectedCompositionPath)
if (`$SkillKind -ne 'super') { return [pscustomobject]@{ normalized = `$false; report = `$null; removedRanges = @() } }
`$counter = '$($root -replace "'", "''")\super-calls.txt'
`$n = if (Test-Path `$counter) { [int](Get-Content `$counter) } else { 0 }
Set-Content `$counter (`$n + 1)
`$answers = @($gateList)
`$a = `$answers[[Math]::Min(`$n, `$answers.Count - 1)]
if (`$a -ne 'ok') { throw `$a }
[pscustomobject]@{ normalized = `$false; report = `$null; removedRanges = @() }
"@
        $agent = @{ provider = 'fake'; model = 'm'; leafModel = 'm' }
        if ($Consolidation -ne 'default') { $agent.consolidation = $Consolidation }
        Set-Content -LiteralPath (Join-Path $root 'context.json') (@{
                headSha = 'a' * 40; targetBranch = 'refs/heads/main'; mergeBase = 'b' * 40; changedFiles = @('apps/A/x.al')
                settings = @{ tier = $Tier; mode = 'review'; bcVersion = $null; BCQuality = @{ version = '1.9'; repo = 'r'; enabledLayers = @('microsoft'); disabledSkills = @() }
                    CodeReviewAgent = $agent } } | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $root 'apps.json') (ConvertTo-Json -Depth 5 -InputObject @(@{ name = 'app1'; folder = 'apps/A'; files = @('apps/A/x.al'); dir = (Join-Path $root 'diff') }))
        [pscustomobject]@{ Root = $root; Scripts = $scripts; Bcq = $bcq; Repo = $repo; Out = $out }
    }

    function Invoke-Harness {
        param($H)
        & (Join-Path $H.Scripts 'Invoke-BCQualityReview.ps1') -ContextPath (Join-Path $H.Root 'context.json') -AppsPath (Join-Path $H.Root 'apps.json') `
            -RepoDir $H.Repo -BCQualityRoot $H.Bcq -BCQualityCommit ('c' * 40) -OutDir $H.Out 6>$null
        $res = Get-Content (Join-Path $H.Out 'result.json') -Raw | ConvertFrom-Json -Depth 20
        if (-not $res.apps[0].gate -and -not (Test-Path (Join-Path $H.Root 'prompts.txt'))) { throw "review failed before any agent call: $($res.apps[0].gateMessage)" }
        [pscustomobject]@{
            Result  = $res
            Prompts = @(Get-Content (Join-Path $H.Root 'prompts.txt') | Where-Object { $_ -like 'PROMPT:*' })
            Shared  = @(Get-Content (Join-Path $H.Root 'shared.txt') | Where-Object { $_ -like 'SHARED:*' } | ForEach-Object { $_.Substring(8).Trim() })
            Metrics = Get-Content (Join-Path $H.Out 'run-metrics.json') -Raw | ConvertFrom-Json -Depth 20
        }
    }
}

Describe 'shared prompt prefix' {
    It 'gives every call the same shared file and drops the instruction to read do.md and entry.md' {
        $h = New-Harness 'shared-on' @('ok') $true
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeTrue
        $file = Join-Path $h.Out 'shared-context.md'
        Test-Path $file | Should -BeTrue
        $r.Shared.Count | Should -Be 2                                   # the review area and the consolidation call
        @($r.Shared | Select-Object -Unique) | Should -Be @($file)      # one file, byte-identical for every call
        $text = Get-Content $file -Raw
        $text | Should -BeLike '*# BCQuality shared instructions*'
        $text | Should -BeLike '*## skills/entry.md*ENTRY-DOC*'
        $text | Should -BeLike '*## skills/do.md*DO-DOC*'
        $text | Should -Not -BeLike "*`r*"                              # normalised line endings: same bytes on every agent
        $text | Should -Not -BeLike "*$($h.Bcq -replace '\\', '\\')*"   # no machine-specific path inside the shared text
        $r.Prompts[0] | Should -BeLike "*already contains BCQuality's skills/entry.md and skills/do.md*"
        $r.Prompts[0] | Should -Not -BeLike 'Read *skills/entry.md*'
        $r.Prompts[1] | Should -BeLike "*in your system prompt under 'BCQuality shared instructions'*"
    }

    It 'is byte-identical for two runs of the same BCQuality version' {
        $a = New-Harness 'shared-a' @('ok') $true; $null = Invoke-Harness $a
        $b = New-Harness 'shared-b' @('ok') $true; $null = Invoke-Harness $b
        (Get-FileHash (Join-Path $a.Out 'shared-context.md')).Hash | Should -Be (Get-FileHash (Join-Path $b.Out 'shared-context.md')).Hash
    }

    It 'changes nothing for a provider without support: the prompts read the files, no file is passed' {
        $h = New-Harness 'shared-off' @('ok') $false
        $r = Invoke-Harness $h
        Test-Path (Join-Path $h.Out 'shared-context.md') | Should -BeFalse
        @($r.Shared | Where-Object { $_ }).Count | Should -Be 0
        $r.Prompts[0] | Should -BeLike '*Read *skills/entry.md and *skills/do.md. Execute only*'
        $r.Prompts[1] | Should -BeLike '*rules in *skills/do.md and the super-skill*'
    }

    It 'is not used for tier 1, which is a single call' {
        $h = New-Harness 'shared-tier1' @('ok') $true 1
        $null = Invoke-Harness $h
        Test-Path (Join-Path $h.Out 'shared-context.md') | Should -BeFalse
    }
}

Describe 'host consolidation in the review run' {
    It 'rolls the reports up in code by default: one agent call (the area), none for the merge' {
        $h = New-Harness 'host-default' @('ok') -Consolidation 'default'
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeTrue
        $r.Result.apps[0].consolidation | Should -Be 'host'
        $r.Prompts.Count | Should -Be 1
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.txt') | Should -BeFalse
        $report = Get-Content (Join-Path $h.Out 'app1/accepted-report.json') -Raw | ConvertFrom-Json -Depth 50
        $report.skill.id | Should -Be 'al-code-review'
        $report.outcome | Should -Be 'completed'
        @($report.'sub-results').Count | Should -Be 1
    }

    It 'does the same when the setting says host' {
        $h = New-Harness 'host-explicit' @('ok') -Consolidation 'host'
        $r = Invoke-Harness $h
        $r.Result.apps[0].consolidation | Should -Be 'host'
        $r.Prompts.Count | Should -Be 1
    }

    It 'falls back to the agent roll-up when the gate rejects the host one, and keeps the rejected report' {
        $h = New-Harness 'host-rejected' @('Findings-report acceptance failed: SUPER_FINDING_MISSING at $.findings: x', 'ok') -Consolidation 'host'
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeTrue
        $r.Result.apps[0].consolidation | Should -Be 'agent'
        $r.Prompts.Count | Should -Be 2   # the area, then the agent roll-up
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation-host.json') | Should -BeTrue
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation-host.gate.txt') | Should -BeTrue
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.txt') | Should -BeTrue
    }

    It 'fails closed when neither roll-up passes the gate' {
        $h = New-Harness 'host-both-fail' @('Findings-report acceptance failed: NOPE at $: x') -Consolidation 'host'
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeFalse
        $r.Result.outcome | Should -Be 'failed'
        $r.Prompts.Count | Should -Be 3   # the area, then the agent roll-up and its one retry
    }

    It 'keeps the agent roll-up when the setting says agent' {
        $h = New-Harness 'agent-setting' @('ok') -Consolidation 'agent'
        $r = Invoke-Harness $h
        $r.Result.apps[0].consolidation | Should -Be 'agent'
        $r.Prompts.Count | Should -Be 2
    }
}

Describe 'consolidation retry' {
    It 'accepts the first consolidation without retrying' {
        $h = New-Harness 'first-ok' @('ok')
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeTrue
        $r.Prompts.Count | Should -Be 2   # one review area + one consolidation
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.retry.txt') | Should -BeFalse
    }

    It 'retries once with the gate message and accepts the second report' {
        $msg = "Findings-report acceptance failed: SUPER_FINDING_MISSING at `$.findings: No valid rolled-up finding represents a finding from 'al-error-handling-review' at its source location."
        $h = New-Harness 'second-ok' @($msg, 'ok')
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeTrue
        $r.Prompts.Count | Should -Be 3
        $r.Prompts[2] | Should -BeLike '*SUPER_FINDING_MISSING*'
        $r.Prompts[2] | Should -BeLike "*prefix a non-citation id*"
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.txt') | Should -BeTrue
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.retry.txt') | Should -BeTrue
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.gate.txt') | Should -BeTrue
        @($r.Metrics.processes | Where-Object { $_.skillId -eq 'al-code-review' }).Count | Should -BeGreaterThan 0
    }

    It 'fails closed after one retry and keeps the raw output' {
        $h = New-Harness 'both-fail' @('Findings-report acceptance failed: SOMETHING_ELSE at $: nope')
        $r = Invoke-Harness $h
        $r.Result.apps[0].gate | Should -BeFalse
        $r.Result.outcome | Should -Be 'failed'
        $r.Prompts.Count | Should -Be 3
        $r.Prompts[2] | Should -Not -BeLike '*prefix a non-citation id*'   # the agent-finding hint is only for SUPER_FINDING_MISSING
        Test-Path (Join-Path $h.Out 'app1/raw/consolidation.retry.gate.txt') | Should -BeTrue
    }
}
