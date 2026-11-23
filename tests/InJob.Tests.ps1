BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $script:scripts 'AgentProvider.ps1')   # loads Common, AgentLaunch and every provider folder
    $script:schema = Join-Path $PSScriptRoot '..\schemas\bcquality-ado.settings.schema.json'

    function New-TestRepo {
        # A bare "origin" and a clone with main plus a feature commit that changes one AL file.
        $origin = Join-Path $TestDrive 'origin.git'
        $work = Join-Path $TestDrive 'work'
        git init --quiet --bare --initial-branch=main $origin
        git clone --quiet $origin $work 2>$null
        git -C $work config user.email t@example.com; git -C $work config user.name t
        New-Item -ItemType Directory -Path (Join-Path $work 'apps/A') -Force | Out-Null
        Set-Content (Join-Path $work 'apps/A/app.json') '{}'; Set-Content (Join-Path $work 'apps/A/x.al') 'codeunit 1 X {}'
        git -C $work add -A; git -C $work commit --quiet -m base
        git -C $work push --quiet origin HEAD:main 2>$null
        git -C $work checkout --quiet -b feature
        Add-Content (Join-Path $work 'apps/A/x.al') '// changed'
        git -C $work commit --quiet -am change
        [pscustomobject]@{ Dir = $work; Head = (git -C $work rev-parse HEAD).Trim() }
    }
}

Describe 'Get-PrContext with a pipeline-written settings file' {
    BeforeAll {
        $script:repo = New-TestRepo
        $script:ctxScript = Join-Path $script:scripts 'Get-PrContext.ps1'
        function Run-Ctx($settingsFile, $name) {
            $out = Join-Path $TestDrive $name
            & $script:ctxScript -RepoDir $script:repo.Dir -OutDir $out -TargetBranch 'refs/heads/main' -HeadSha $script:repo.Head `
                -AuthorIdentity 'a@x' -SchemaPath $script:schema -SettingsFile $settingsFile 6>$null
            Get-Content (Join-Path $out 'context.json') -Raw | ConvertFrom-Json -Depth 20
        }
    }
    It 'reviews the changed AL file using only the file given' {
        $f = Join-Path $TestDrive 's-ok.json'
        '{"BCQuality":{"version":"1.9"},"CodeReviewAgent":{"enabled":true,"branches":["main"],"provider":"claude-code"}}' | Set-Content $f
        $c = Run-Ctx $f 'ctx-ok'
        $c.skipped | Should -BeFalse
        $c.settings.CodeReviewAgent.provider | Should -Be 'claude-code'
        @($c.changedFiles) | Should -Be @('apps/A/x.al')
    }
    It 'never falls back to git for settings when a file is given' {
        # The repo has no .bcquality/settings.json on main; a git fallback would report review-disabled, not a missing file.
        $c = Run-Ctx (Join-Path $TestDrive 'does-not-exist.json') 'ctx-missing'
        $c.skipped | Should -BeTrue
        $c.skipReason | Should -Match '^settings-invalid: settings file not found'
    }
    It 'skips a settings file that does not enable the review' {
        $f = Join-Path $TestDrive 's-off.json'; '{"BCQuality":{"version":"1.9"}}' | Set-Content $f
        (Run-Ctx $f 'ctx-off').skipReason | Should -Be 'review-disabled'
    }
    It 'skips a settings file that breaks the schema' {
        $f = Join-Path $TestDrive 's-bad.json'; '{"nope":1}' | Set-Content $f
        (Run-Ctx $f 'ctx-bad').skipReason | Should -Match '^settings-invalid'
    }
}

Describe 'Agent launch' {
    It 'uses the command name when no entry point was installed' {
        $l = Get-AgentLaunch -DefaultCommand 'claude' -EntryPath ''
        $l.FileName | Should -Be 'claude'; @($l.PrefixArgs).Count | Should -Be 0
    }
    It 'starts a native executable directly' {
        $exe = Join-Path $TestDrive 'claude.exe'; Set-Content $exe 'x'
        $l = Get-AgentLaunch -DefaultCommand 'claude' -EntryPath $exe
        $l.FileName | Should -Be $exe; @($l.PrefixArgs).Count | Should -Be 0
    }
    It 'starts a Node script through node, never through a shell' {
        $js = Join-Path $TestDrive 'npm-loader.js'; Set-Content $js 'x'
        $l = Get-AgentLaunch -DefaultCommand 'copilot' -EntryPath $js
        $l.FileName | Should -Match 'node(\.exe)?$'
        @($l.PrefixArgs) | Should -Be @($js)
    }
    It 'refuses an entry point that does not exist' {
        { Get-AgentLaunch -DefaultCommand 'claude' -EntryPath (Join-Path $TestDrive 'gone.exe') } | Should -Throw '*missing file*'
    }
    It 'builds a process that carries the launch arguments first' {
        $js = Join-Path $TestDrive 'loader.js'; Set-Content $js 'x'
        $psi = New-AgentProcessInfo -DefaultCommand 'copilot' -EntryPath $js
        $psi.FileName | Should -Match 'node(\.exe)?$'
        $psi.ArgumentList[0] | Should -Be $js
        $psi.UseShellExecute | Should -BeFalse
    }
}
