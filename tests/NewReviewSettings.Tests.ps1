BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    $script:schema = Join-Path $PSScriptRoot '..\schemas\bcquality-ado.settings.schema.json'
    . (Join-Path $script:scripts 'Common.ps1')
    . (Join-Path $script:scripts 'BranchPatterns.ps1')

    function Invoke-NewSettings {
        # Runs the real script. Returns { exitCode; output; settings } where settings is the parsed file, or $null.
        param([string[]] $ExtraArgs = @(), [string] $Extra)
        $out = Join-Path $TestDrive "settings-$([guid]::NewGuid().ToString('N')).json"
        $env:BCQ_EXTRA_SETTINGS = $Extra
        try {
            $log = & pwsh -NoProfile -File (Join-Path $script:scripts 'New-ReviewSettings.ps1') -OutFile $out -BCQualityVersion '1.9' -SchemaPath $script:schema @ExtraArgs 2>&1 | Out-String
        }
        finally { Remove-Item Env:BCQ_EXTRA_SETTINGS -ErrorAction SilentlyContinue }
        [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $log; settings = $(if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -Depth 20 }) }
    }
}

Describe 'New-ReviewSettings.ps1 basics' {
    It 'writes the settings the in-job flow has always used, and they satisfy the schema' {
        $r = Invoke-NewSettings -ExtraArgs @('-Provider', 'claude-code', '-Model', 'claude-sonnet-5-5', '-LeafModel', 'claude-sonnet-5-5')
        $r.exitCode | Should -Be 0 -Because $r.output
        $s = $r.settings
        $s.BCQuality.version | Should -Be '1.9'
        @($s.BCQuality.enabledLayers) | Should -Be @('microsoft', 'community')
        $s.CodeReviewAgent.enabled | Should -BeTrue
        $s.CodeReviewAgent.provider | Should -Be 'claude-code'
        $s.CodeReviewAgent.model | Should -Be 'claude-sonnet-5-5'
        $s.CodeReviewAgent.leafModel | Should -Be 'claude-sonnet-5-5'
        @($s.CodeReviewAgent.excludedAuthors).Count | Should -Be 0
        $s.mode | Should -Be 'advisory'; $s.tier | Should -Be 2
    }
    It 'trims and splits the layers, dropping empty entries' {
        $r = Invoke-NewSettings -ExtraArgs @('-EnabledLayers', ' microsoft , ,community,')
        @($r.settings.BCQuality.enabledLayers) | Should -Be @('microsoft', 'community')
    }
    It 'leaves the models out when none are given, rather than writing empty ones' {
        $s = (Invoke-NewSettings).settings
        $s.CodeReviewAgent.PSObject.Properties['model'] | Should -BeNullOrEmpty
        $s.CodeReviewAgent.PSObject.Properties['leafModel'] | Should -BeNullOrEmpty
    }
    It 'always uses ** for branches, so a target name is never interpolated into a pattern' {
        @((Invoke-NewSettings).settings.CodeReviewAgent.branches) | Should -Be @('**')
    }
}

Describe 'New-ReviewSettings.ps1 extra settings' {
    It 'merges objects key by key and replaces arrays, keeping everything else' {
        $extra = '{"BCQuality":{"disabledSkills":["microsoft/skills/review/al-finance-review.md"],"knowledge":{"deny":["**/appsource/**"]}},"CodeReviewAgent":{"suggestions":"manual","nearDuplicateLines":0,"regional":{"layouts":["src/Apps/{region}/{path}"],"primary":"DE"}},"maxChangedFiles":10}'
        $r = Invoke-NewSettings -Extra $extra -ExtraArgs @('-Provider', 'copilot')
        $r.exitCode | Should -Be 0 -Because $r.output
        $s = $r.settings
        @($s.BCQuality.disabledSkills) | Should -Be @('microsoft/skills/review/al-finance-review.md')
        @($s.BCQuality.knowledge.deny) | Should -Be @('**/appsource/**')
        $s.CodeReviewAgent.suggestions | Should -Be 'manual'
        $s.CodeReviewAgent.nearDuplicateLines | Should -Be 0
        @($s.CodeReviewAgent.regional.layouts) | Should -Be @('src/Apps/{region}/{path}')
        $s.CodeReviewAgent.regional.primary | Should -Be 'DE'
        $s.maxChangedFiles | Should -Be 10
        # the basics survive
        $s.BCQuality.version | Should -Be '1.9'
        $s.CodeReviewAgent.provider | Should -Be 'copilot'
        $s.CodeReviewAgent.enabled | Should -BeTrue
        @($s.BCQuality.enabledLayers) | Should -Be @('microsoft', 'community')
    }
    It 'lets the extra settings replace an array the basics set' {
        $r = Invoke-NewSettings -Extra '{"BCQuality":{"enabledLayers":["microsoft"]},"CodeReviewAgent":{"excludedAuthors":["bot@x.com"]}}'
        @($r.settings.BCQuality.enabledLayers) | Should -Be @('microsoft')
        @($r.settings.CodeReviewAgent.excludedAuthors) | Should -Be @('bot@x.com')
    }
    It 'treats blank extra settings as none' {
        (Invoke-NewSettings -Extra '   ').exitCode | Should -Be 0
        (Invoke-NewSettings -Extra '').exitCode | Should -Be 0
    }
    It 'passes the merged result through the schema' {
        $s = $null
        $r = Invoke-NewSettings -Extra '{"CodeReviewAgent":{"suggestions":"apply","regional":{"layouts":["a/{region}/{path}"]}}}'
        $r.exitCode | Should -Be 0 -Because $r.output
        { Read-Settings -Json (ConvertTo-Json $r.settings -Depth 20) -SchemaPath $script:schema } | Should -Not -Throw
    }
}

Describe 'New-ReviewSettings.ps1 refuses bad input and writes nothing' {
    It 'rejects extra settings that are not JSON' {
        $r = Invoke-NewSettings -Extra '{not json'
        $r.exitCode | Should -Not -Be 0
        $r.output | Should -Match 'not valid JSON'
        $r.settings | Should -BeNullOrEmpty
    }
    It 'rejects extra settings that are not an object' {
        $r = Invoke-NewSettings -Extra '["a"]'
        $r.exitCode | Should -Not -Be 0
        $r.output | Should -Match 'must be a JSON object'
        $r.settings | Should -BeNullOrEmpty
    }
    It 'rejects a key the schema does not know, with the schema''s message, and writes no file' {
        $r = Invoke-NewSettings -Extra '{"CodeReviewAgent":{"suggestons":"manual"}}'
        $r.exitCode | Should -Not -Be 0
        $r.output | Should -Match 'do not satisfy the schema'
        $r.settings | Should -BeNullOrEmpty
    }
    It 'rejects a value the schema does not allow' {
        $r = Invoke-NewSettings -Extra '{"CodeReviewAgent":{"suggestions":"sometimes"}}'
        $r.exitCode | Should -Not -Be 0
        $r.settings | Should -BeNullOrEmpty
    }
}

# Why branches is '**': the settings are patterns now, and a target branch name is not always a pattern that matches itself.
Describe 'Get-PrContext.ps1 with the generated settings file' {
    BeforeAll {
        $script:work = Join-Path $TestDrive 'ctx'
        $bare = Join-Path $script:work 'origin.git'
        $script:repo = Join-Path $script:work 'repo'
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null
        git init -q --bare $bare 2>&1 | Out-Null
        git clone -q $bare $script:repo 2>&1 | Out-Null
        function Invoke-RepoGit { param([string[]] $GitArgs) & git -C $script:repo -c user.email=t@t -c user.name=t @GitArgs 2>&1 | Out-Null }
        $script:targets = 'main', 'release/1.0+hotfix', 'feature/c++'
        Invoke-RepoGit @('checkout', '-q', '-B', 'base')
        Set-Content -LiteralPath (Join-Path $script:repo 'x.al') -Value 'codeunit 50000 X { }'
        Invoke-RepoGit @('add', '-A'); Invoke-RepoGit @('commit', '-q', '-m', 'base')
        foreach ($b in $script:targets) { Invoke-RepoGit @('push', '-q', '--force', 'origin', "base:refs/heads/$b") }
        Invoke-RepoGit @('checkout', '-q', '-B', 'feature')
        Set-Content -LiteralPath (Join-Path $script:repo 'x.al') -Value 'codeunit 50000 X { // changed }'
        Invoke-RepoGit @('commit', '-q', '-am', 'change')
        Invoke-RepoGit @('fetch', '-q', 'origin')
        $script:head = (git -C $script:repo rev-parse HEAD).Trim()
        function Get-Context {
            param([string] $Target, [string] $SettingsFile)
            $out = Join-Path $script:work "out-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $out | Out-Null
            $null = & pwsh -NoProfile -File (Join-Path $script:scripts 'Get-PrContext.ps1') -RepoDir $script:repo -OutDir $out -TargetBranch "refs/heads/$Target" `
                -HeadSha $script:head -AuthorIdentity 'a@b' -SchemaPath $script:schema -SettingsFile $SettingsFile 2>&1
            Get-Content -LiteralPath (Join-Path $out 'context.json') -Raw | ConvertFrom-Json -Depth 30
        }
    }
    It 'reviews every target branch, including names with + in them' {
        $file = Join-Path $TestDrive 'generated.json'
        $null = & pwsh -NoProfile -File (Join-Path $script:scripts 'New-ReviewSettings.ps1') -OutFile $file -BCQualityVersion '1.9' -SchemaPath $script:schema
        foreach ($t in $script:targets) {
            $c = Get-Context -Target $t -SettingsFile $file
            $c.skipped | Should -BeFalse -Because "target '$t' skipped with '$($c.skipReason)'"
        }
    }
    It 'shows why: branches = @($target), the old shape, skips or rejects a target that contains +' {
        foreach ($t in 'release/1.0+hotfix', 'feature/c++') {
            $old = Join-Path $TestDrive "old-$([guid]::NewGuid().ToString('N')).json"
            [ordered]@{ BCQuality = [ordered]@{ version = '1.9' }; CodeReviewAgent = [ordered]@{ enabled = $true; branches = @($t) } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $old
            (Get-Context -Target $t -SettingsFile $old).skipped | Should -BeTrue
        }
        $ok = Join-Path $TestDrive 'old-main.json'
        [ordered]@{ BCQuality = [ordered]@{ version = '1.9' }; CodeReviewAgent = [ordered]@{ enabled = $true; branches = @('main') } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ok
        (Get-Context -Target 'main' -SettingsFile $ok).skipped | Should -BeFalse   # plain names were never affected
    }
}
