BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\AgentProvider.ps1')   # loads Common, Metrics and every provider folder
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'

    function New-Call {
        param($Usage, [string] $Requested = '', [bool] $Ok = $true, [string] $Role = 'leaf', [string] $Skill = 's1', [int] $Attempt = 1)
        [pscustomobject]@{ app = 'app1'; role = $Role; skillId = $Skill; attempt = $Attempt; requestedModel = $Requested; ok = $Ok; seconds = 2.5; error = $(if (-not $Ok) { 'boom' }); usage = $Usage }
    }
    function New-ClaudeLike { param([long] $In = 10, [long] $Out = 20, [double] $Cost = 0.5, [string[]] $Models = @('claude-sonnet-5-5'))
        New-AgentUsage -Source 'claude-code' -Models $Models -InputTokens $In -OutputTokens $Out -CacheReadTokens 100 -CacheCreationTokens 50 -CostUsd $Cost -Turns 2 -DurationMs 1000 }
}

Describe 'Merge-AgentUsage' {
    It 'returns nothing when there is nothing to merge' {
        Merge-AgentUsage @() | Should -BeNullOrEmpty
        Merge-AgentUsage @($null, $null) | Should -BeNullOrEmpty
    }
    It 'sums fields, unions models and keeps unreported fields null' {
        $m = Merge-AgentUsage @((New-ClaudeLike -In 10 -Cost 0.25), (New-ClaudeLike -In 5 -Cost 0.5 -Models @('claude-sonnet-5-5', 'other')))
        $m.inputTokens | Should -Be 15
        $m.outputTokens | Should -Be 40
        $m.cacheReadTokens | Should -Be 200
        $m.costUsd | Should -Be 0.75
        $m.turns | Should -Be 4
        $m.models | Should -Be @('claude-sonnet-5-5', 'other')
        $m.aiCredits | Should -BeNullOrEmpty
        $m.reasoningTokens | Should -BeNullOrEmpty
        $m.complete | Should -BeTrue
    }
    It 'is incomplete when any part is incomplete' {
        $a = New-ClaudeLike; $b = New-AgentUsage -Source 'claude-code' -InputTokens 1 -OutputTokens 1 -Complete $false
        (Merge-AgentUsage @($a, $b)).complete | Should -BeFalse
    }
    It 'does not accumulate float noise in cost' {
        $parts = 1..10 | ForEach-Object { New-ClaudeLike -Cost 0.1 }
        (Merge-AgentUsage $parts).costUsd | Should -Be 1.0
    }
}

Describe 'Get-ModelCheck' {
    It 'verifies an exact match and a dated snapshot of the requested model' {
        Get-ModelCheck -Requested 'claude-sonnet-5-5' -Observed @('claude-sonnet-5-5') | Should -Be 'verified'
        Get-ModelCheck -Requested 'claude-sonnet-5-5' -Observed @('claude-sonnet-5-5-20260101') | Should -Be 'verified'
    }
    It 'flags an alias that resolved to a different model' {
        Get-ModelCheck -Requested 'sonnet' -Observed @('claude-sonnet-4-6') | Should -Be 'mismatch'
    }
    It 'accepts the requested model when the CLI also reports a helper model, as Claude Code does with Haiku (real log)' {
        Get-ModelCheck -Requested 'claude-sonnet-5-5' -Observed @('claude-haiku-4-5-20251001', 'claude-sonnet-5-5') | Should -Be 'verified'
        Get-ModelCheck -Requested 'claude-sonnet-5-5' -Observed @('claude-sonnet-5-5-20260101', 'claude-haiku-4-5-20251001') | Should -Be 'verified'
    }
    It 'still flags an alias that resolved elsewhere when a helper model is also reported' {
        Get-ModelCheck -Requested 'sonnet' -Observed @('claude-haiku-4-5-20251001', 'claude-sonnet-4-6') | Should -Be 'mismatch'
    }
    It 'lists the other models separately' {
        Get-OtherModels -Requested 'claude-sonnet-5-5' -Observed @('claude-haiku-4-5-20251001', 'claude-sonnet-5-5') | Should -Be @('claude-haiku-4-5-20251001')
        @(Get-OtherModels -Requested 'claude-sonnet-5-5' -Observed @('claude-sonnet-5-5', 'claude-sonnet-5-5-20260101')).Count | Should -Be 0
    }
    It 'does not treat a longer model name as the requested one' {
        Get-ModelCheck -Requested 'claude-sonnet-5' -Observed @('claude-sonnet-5-5') | Should -Be 'mismatch'
    }
    It 'says unverifiable when a model was requested but none observed, and not-requested when none was asked for' {
        Get-ModelCheck -Requested 'x' -Observed @() | Should -Be 'unverifiable'
        Get-ModelCheck -Requested '' -Observed @('anything') | Should -Be 'not-requested'
    }
}

Describe 'Format-AgentUsage' {
    It 'says not reported for no usage' { Format-AgentUsage $null | Should -Be 'not reported' }
    It 'formats Claude usage with cost and model' {
        $t = Format-AgentUsage (New-ClaudeLike -In 1234 -Out 5 -Cost 0.0297)
        $t | Should -BeLike 'in 1,234 (+100 cache read, +50 cache write), out 5*cost $0.0297 (API-equivalent)*model claude-sonnet-5-5'
    }
    It 'formats Copilot usage with credits and premium requests, without a dollar cost' {
        $u = New-AgentUsage -Source 'copilot-cli' -Models @('m') -InputTokens 1 -OutputTokens 2 -ReasoningTokens 3 -AiCredits 9.37309 -PremiumRequests 3
        $t = Format-AgentUsage $u
        $t | Should -BeLike '*reasoning 3*AI credits 9.373*premium requests 3*'
        $t | Should -Not -BeLike '*cost $*'
    }
}

Describe 'New-RunMetrics' {
    It 'totals usage, counts failures and records each call with its model check' {
        $calls = @(
            (New-Call -Usage (New-ClaudeLike -In 10) -Requested 'claude-sonnet-5-5' -Skill 'a')
            (New-Call -Usage (New-ClaudeLike -In 20) -Requested 'claude-sonnet-5-5' -Skill 'b')
            (New-Call -Usage $null -Requested 'claude-sonnet-5-5' -Ok $false -Skill 'c')
        )
        $m = New-RunMetrics -Calls $calls
        $m.calls | Should -Be 3
        $m.failedCalls | Should -Be 1
        $m.callsWithoutUsage | Should -Be 1
        $m.usage.inputTokens | Should -Be 30
        $m.usage.complete | Should -BeFalse
        $m.models | Should -Be @('claude-sonnet-5-5')
        @($m.processes).Count | Should -Be 3
        $m.processes[0].modelCheck | Should -Be 'verified'
        $m.processes[2].modelCheck | Should -Be 'call-failed'   # a failed call has no model to verify, and is not "unverifiable"
        $m.processes[2].error | Should -Be 'boom'
        @($m.modelMismatches).Count | Should -Be 0
    }
    It 'lists a mismatch once however many calls hit it' {
        $u = New-ClaudeLike -Models @('claude-sonnet-4-6')
        $m = New-RunMetrics -Calls @((New-Call -Usage $u -Requested 'sonnet' -Skill 'a'), (New-Call -Usage $u -Requested 'sonnet' -Skill 'b'))
        @($m.modelMismatches).Count | Should -Be 1
        $m.modelMismatches[0].requested | Should -Be 'sonnet'
        $m.modelMismatches[0].observed | Should -Be 'claude-sonnet-4-6'
    }
    It 'handles a run with no calls' {
        $m = New-RunMetrics -Calls @()
        $m.calls | Should -Be 0
        $m.usage | Should -BeNullOrEmpty
    }
    It 'round-trips through JSON' {
        $m = New-RunMetrics -Calls @((New-Call -Usage (New-ClaudeLike) -Requested 'claude-sonnet-5-5'))
        $back = $m | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $back.usage.inputTokens | Should -Be 10
        $back.processes[0].usage.models | Should -Be 'claude-sonnet-5-5'
    }
}

Describe 'Get-RunMetricsLog' {
    It 'prints a usage line and warns about a lower bound and a model mismatch' {
        $u = New-ClaudeLike -Models @('claude-sonnet-4-6')
        $m = New-RunMetrics -Calls @((New-Call -Usage $u -Requested 'sonnet'), (New-Call -Usage $null -Ok $false -Requested 'sonnet'))
        $log = @(Get-RunMetricsLog -Metrics $m)
        $log[0] | Should -BeLike 'Usage: 2 agent call(s), 1 failed; in *'
        ($log -join "`n") | Should -BeLike "*task.logissue type=warning]1 of 2 agent call(s) reported no usage*"
        ($log -join "`n") | Should -BeLike "*Model 'sonnet' was requested but the CLI reported 'claude-sonnet-4-6'*"
    }
    It 'warns that a model could not be verified only for a call that succeeded without reporting one' {
        $failed = New-RunMetrics -Calls @((New-Call -Usage $null -Ok $false -Requested 'm'))
        (Get-RunMetricsLog -Metrics $failed) -join "`n" | Should -Not -BeLike '*could not be verified*'
        $silent = New-RunMetrics -Calls @((New-Call -Usage $null -Ok $true -Requested 'm'))
        (Get-RunMetricsLog -Metrics $silent) -join "`n" | Should -BeLike '*reported no model for 1 call(s)*'
    }
    It 'reports a helper model as information, not as a warning, and records it in the metrics' {
        $u = New-ClaudeLike -Models @('claude-haiku-4-5-20251001', 'claude-sonnet-5-5')
        $m = New-RunMetrics -Calls @((New-Call -Usage $u -Requested 'claude-sonnet-5-5'), (New-Call -Usage $u -Requested 'claude-sonnet-5-5' -Skill 's2'))
        $m.processes[0].modelCheck | Should -Be 'verified'
        $m.otherModels | Should -Be @('claude-haiku-4-5-20251001')
        @($m.modelMismatches).Count | Should -Be 0
        $log = @(Get-RunMetricsLog -Metrics $m)
        $log.Count | Should -Be 2
        $log[1] | Should -BeLike '*helper model(s) besides the requested one: claude-haiku-4-5-20251001*the requested model was used*'
        $log[1].StartsWith('##vso') | Should -BeFalse
    }
    It 'prints only the usage line for a clean run' {
        $m = New-RunMetrics -Calls @((New-Call -Usage (New-ClaudeLike) -Requested 'claude-sonnet-5-5'))
        @(Get-RunMetricsLog -Metrics $m).Count | Should -Be 1
    }
}

# Real-shape fixtures: the Copilot one is trimmed to the fields read, with numbers taken from a real Copilot CLI
# 1.0.105 session; the Claude one is a real Claude Code 2.1.187 capture whose `sonnet` alias resolved to 4.6.
Describe 'Provider usage from real-shape fixtures' {
    It 'reads Copilot usage records, keeping fresh input apart from cache and skipping other events and bad lines' {
        $u = Get-CopilotUsage -EventsPath (Join-Path $script:fixtures 'copilot-events-usage.jsonl')
        $u.source | Should -Be 'copilot-cli'
        $u.apiCalls | Should -Be 3
        $u.inputTokens | Should -Be 10          # (30459-0-30455) + (32631-30455-2174) + (32845-32629-212)
        $u.cacheReadTokens | Should -Be 63084
        $u.cacheCreationTokens | Should -Be 32841
        $u.outputTokens | Should -Be 530
        $u.reasoningTokens | Should -Be 48
        $u.premiumRequests | Should -Be 3
        $u.durationMs | Should -Be 8645
        $u.aiCredits | Should -Be 9.37309
        $u.models | Should -Be @('claude-sonnet-5.5')
        $u.costUsd | Should -BeNullOrEmpty
    }
    It 'reports no usage, not zero, when a Copilot session has no usage records' {
        $f = Join-Path $TestDrive 'copilot-none.jsonl'
        Set-Content -LiteralPath $f -Value '{"type":"session.start","data":{}}'
        Get-CopilotUsage -EventsPath $f | Should -BeNullOrEmpty
    }
    It 'leaves AI credits unreported when a record lacks nano-AIU' {
        $f = Join-Path $TestDrive 'copilot-nonano.jsonl'
        Set-Content -LiteralPath $f -Value '{"type":"session.usage_record","data":{"usage":{"model":"m","inputTokens":5,"outputTokens":1,"cacheReadTokens":0,"cacheWriteTokens":0,"cost":1}}}'
        $u = Get-CopilotUsage -EventsPath $f
        $u.aiCredits | Should -BeNullOrEmpty
        $u.inputTokens | Should -Be 5
    }
    It 'never goes negative when cache counts exceed the prompt count' {
        $f = Join-Path $TestDrive 'copilot-odd.jsonl'
        Set-Content -LiteralPath $f -Value '{"type":"session.usage_record","data":{"usage":{"model":"m","inputTokens":5,"outputTokens":1,"cacheReadTokens":9,"cacheWriteTokens":9}}}'
        (Get-CopilotUsage -EventsPath $f).inputTokens | Should -Be 0
    }
    It 'reads the observed model from a real Claude result and flags the alias as a mismatch' {
        $u = Get-ClaudeUsage (Get-ClaudeResultEvent -EventsPath (Join-Path $script:fixtures 'claude-stream-success.jsonl'))
        $u.source | Should -Be 'claude-code'
        $u.models | Should -Be @('claude-sonnet-4-6')
        $u.cacheReadTokens | Should -Be 24188
        Get-ModelCheck -Requested 'sonnet' -Observed $u.models | Should -Be 'mismatch'
        Get-ModelCheck -Requested 'claude-sonnet-4-6' -Observed $u.models | Should -Be 'verified'
    }
}
