BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\AgentProvider.ps1')   # loads Common and every provider folder
}

Describe 'Agent provider seam' {
    It 'resolves copilot and claude-code, and treats blank as copilot' {
        (Get-AgentProvider 'copilot').DisplayName | Should -Be 'Copilot CLI'
        (Get-AgentProvider 'claude-code').DisplayName | Should -Be 'Claude Code'
        (Get-AgentProvider '').DisplayName | Should -Be 'Copilot CLI'
    }
    It 'refuses to guess an unknown provider' {
        { Get-AgentProvider 'nope' } | Should -Throw '*Unknown agent provider*'
    }
    It 'routes a call to the adapter with every argument and returns its result' {
        Mock Invoke-CopilotAgent { [pscustomobject]@{ text = 'ok'; retrieved = @('a.md') } }
        $r = Invoke-AgentCall -Provider 'copilot' -Prompt 'p' -Model 'm' -AddDirs @('d') -WorkingDirectory 'w' -BCQualityRoot 'r' -TimeoutSeconds 5
        $r.text | Should -Be 'ok'
        Should -Invoke Invoke-CopilotAgent -Times 1 -ParameterFilter {
            $Prompt -eq 'p' -and $Model -eq 'm' -and $AddDirs -contains 'd' -and $WorkingDirectory -eq 'w' -and $BCQualityRoot -eq 'r' -and $TimeoutSeconds -eq 5 }
    }
    It 'routes claude-code to the Claude adapter' {
        Mock Invoke-ClaudeAgent { [pscustomobject]@{ text = 'c'; retrieved = @() } }
        (Invoke-AgentCall -Provider 'claude-code' -Prompt 'p' -WorkingDirectory 'w' -BCQualityRoot 'r').text | Should -Be 'c'
        Should -Invoke Invoke-ClaudeAgent -Times 1
    }
    It 'does not call any adapter for an unknown provider' {
        Mock Invoke-CopilotAgent { }
        Mock Invoke-ClaudeAgent { }
        { Invoke-AgentCall -Provider 'nope' -Prompt 'p' -WorkingDirectory 'w' -BCQualityRoot 'r' } | Should -Throw
        Should -Invoke Invoke-CopilotAgent -Times 0
        Should -Invoke Invoke-ClaudeAgent -Times 0
    }
}
