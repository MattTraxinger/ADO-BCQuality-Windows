BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\AgentProvider.ps1')   # loads Common and every provider folder
}

Describe 'Copilot retrieval evidence' {
    BeforeAll {
        function Ev($type, $data) { (@{ type = $type; data = $data } | ConvertTo-Json -Depth 6 -Compress) }
        $lines = @(
            (Ev 'tool.execution_start' @{ toolCallId = 'a'; toolName = 'view'; arguments = @{ path = 'C:\bcq\microsoft\knowledge\x\full.md' } })
            (Ev 'tool.execution_complete' @{ toolCallId = 'a'; success = $true })
            (Ev 'tool.execution_start' @{ toolCallId = 'b'; toolName = 'view'; arguments = @{ path = 'C:\bcq\microsoft\knowledge\x\partial.md'; view_range = @(1, 20) } })
            (Ev 'tool.execution_complete' @{ toolCallId = 'b'; success = $true })
            (Ev 'tool.execution_start' @{ toolCallId = 'c'; toolName = 'view'; arguments = @{ path = 'C:\bcq\microsoft\knowledge\x\denied.md' } })
            (Ev 'tool.execution_complete' @{ toolCallId = 'c'; success = $false })
            (Ev 'tool.execution_start' @{ toolCallId = 'd'; toolName = 'view'; arguments = @{ path = 'C:\bcq\skills\do.md' } })
            (Ev 'tool.execution_complete' @{ toolCallId = 'd'; success = $true })
            (Ev 'tool.execution_start' @{ toolCallId = 'e'; toolName = 'view'; arguments = @{ path = 'C:\other\knowledge\y.md' } })
            (Ev 'tool.execution_complete' @{ toolCallId = 'e'; success = $true })
            'not json'
        )
        $script:events = Join-Path $TestDrive 'events.jsonl'
        Set-Content -LiteralPath $script:events -Value $lines
    }
    It 'counts only successful full reads of knowledge articles under the BCQuality root' {
        $r = Get-RetrievedArticlePaths -EventsPath $script:events -BCQualityRoot 'C:\bcq'
        $r | Should -Be @('microsoft/knowledge/x/full.md')
    }
    It 'returns nothing when no events match' {
        $empty = Join-Path $TestDrive 'empty.jsonl'; Set-Content -LiteralPath $empty -Value ''
        @(Get-RetrievedArticlePaths -EventsPath $empty -BCQualityRoot 'C:\bcq').Count | Should -Be 0
    }
}
