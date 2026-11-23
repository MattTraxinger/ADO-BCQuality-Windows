BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Common.ps1')
    $script:schema = Join-Path $PSScriptRoot '..\schemas\bcquality-ado.settings.schema.json'
}

Describe 'Settings' {
    It 'defaults to disabled, advisory, tier 2' {
        $s = Read-Settings -Json '' -SchemaPath $schema
        $s.CodeReviewAgent.enabled | Should -BeFalse
        $s.mode | Should -Be 'advisory'
        $s.tier | Should -Be 2
        $s.maxChangedFiles | Should -Be 60
    }
    It 'overlays given keys and keeps the other defaults' {
        $s = Read-Settings -Json '{"CodeReviewAgent":{"enabled":true},"maxChangedFiles":10}' -SchemaPath $schema
        $s.CodeReviewAgent.enabled | Should -BeTrue
        $s.CodeReviewAgent.branches | Should -Be @('main')
        $s.maxChangedFiles | Should -Be 10
    }
    It 'rejects unknown keys' {
        { Read-Settings -Json '{"nope":1}' -SchemaPath $schema } | Should -Throw
    }
    It 'rejects a malformed version' {
        { Read-Settings -Json '{"BCQuality":{"version":"latest"}}' -SchemaPath $schema } | Should -Throw
        { Read-Settings -Json '{"BCQuality":{"version":"1.9.1.2"}}' -SchemaPath $schema } | Should -Throw
        { Read-Settings -Json '{"BCQuality":{"version":"v1.9"}}' -SchemaPath $schema } | Should -Throw
    }
    It 'accepts major.minor and the major.minor.patch of a fork release' {
        (Read-Settings -Json '{"BCQuality":{"version":"1.9"}}' -SchemaPath $schema).BCQuality.version | Should -Be '1.9'
        (Read-Settings -Json '{"BCQuality":{"version":"1.9.1"}}' -SchemaPath $schema).BCQuality.version | Should -Be '1.9.1'
    }
    It 'rejects status mode on tier 1' {
        { Read-Settings -Json '{"mode":"status","tier":1}' -SchemaPath $schema } | Should -Throw '*tier 2*'
    }
    It 'ranks partial and failed above completed' {
        Get-WorstOutcome @('completed', 'partial', 'not-applicable') | Should -Be 'partial'
        Get-WorstOutcome @('completed', 'failed') | Should -Be 'failed'
    }
    It 'defaults the provider to copilot, accepts claude-code, and rejects anything else' {
        (Read-Settings -Json '' -SchemaPath $schema).CodeReviewAgent.provider | Should -Be 'copilot'
        (Read-Settings -Json '{"CodeReviewAgent":{"enabled":true}}' -SchemaPath $schema).CodeReviewAgent.provider | Should -Be 'copilot'
        (Read-Settings -Json '{"CodeReviewAgent":{"provider":"claude-code"}}' -SchemaPath $schema).CodeReviewAgent.provider | Should -Be 'claude-code'
        { Read-Settings -Json '{"CodeReviewAgent":{"provider":"nope"}}' -SchemaPath $schema } | Should -Throw
    }
}

Describe 'Consolidation setting' {
    It 'is left out by default (the review script then uses the host roll-up)' {
        $s = Read-Settings -Json '' -SchemaPath $schema
        $s.CodeReviewAgent.PSObject.Properties.Name | Should -Not -Contain 'consolidation'
    }
    It 'accepts host and agent and rejects anything else' {
        (Read-Settings -Json '{"CodeReviewAgent":{"consolidation":"agent"}}' -SchemaPath $schema).CodeReviewAgent.consolidation | Should -Be 'agent'
        (Read-Settings -Json '{"CodeReviewAgent":{"consolidation":"host"}}' -SchemaPath $schema).CodeReviewAgent.consolidation | Should -Be 'host'
        { Read-Settings -Json '{"CodeReviewAgent":{"consolidation":"model"}}' -SchemaPath $schema } | Should -Throw
    }
}

Describe 'Optional report properties' {
    It 'returns the default when a property is absent, even under strict mode' {
        Get-OptionalProperty ([pscustomobject]@{ a = 1 }) 'outcome-reason' | Should -BeNullOrEmpty
        Get-OptionalProperty ([pscustomobject]@{ a = 1 }) 'b' 'x' | Should -Be 'x'
        Get-OptionalProperty ([pscustomobject]@{ a = 1 }) 'a' | Should -Be 1
    }
}

Describe 'Repo-relative paths' {
    It 'strips the root, normalizes separators, and returns null outside the root' {
        ConvertTo-RepoRelativePath -Path 'C:\bcq\microsoft\knowledge\x.md' -Root 'C:\bcq' | Should -Be 'microsoft/knowledge/x.md'
        ConvertTo-RepoRelativePath -Path '/home/r/bcq/a/b.md' -Root '/home/r/bcq/' | Should -Be 'a/b.md'
        ConvertTo-RepoRelativePath -Path 'C:\other\x.md' -Root 'C:\bcq' | Should -BeNullOrEmpty
    }
}
