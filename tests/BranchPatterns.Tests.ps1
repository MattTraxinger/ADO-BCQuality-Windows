BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    foreach ($f in 'Common', 'BranchPatterns') { . (Join-Path $script:scripts "$f.ps1") }
    $script:schema = Join-Path $PSScriptRoot '..\schemas\bcquality-ado.settings.schema.json'
    function Test-Branch { param([string] $Branch, [string[]] $Patterns) Test-ReviewTargetBranch -Branch $Branch -Patterns $Patterns }
    function Get-ThrownMessage {
        # The message of the exception a script block throws, or $null. Pester's -Throw message is a wildcard pattern,
        # so a pattern that contains [ cannot be asserted with it.
        param([scriptblock] $Block)
        try { & $Block; $null } catch { $_.Exception.Message }
    }
}

Describe 'Branch pattern syntax' {
    It 'matches an exact branch name, case-sensitively, and nothing longer or shorter' {
        Test-Branch 'main' @('main') | Should -BeTrue
        Test-Branch 'Main' @('main') | Should -BeFalse
        Test-Branch 'main2' @('main') | Should -BeFalse
        Test-Branch 'xmain' @('main') | Should -BeFalse
        Test-Branch 'release/1.0' @('release/1.0') | Should -BeTrue
    }
    It '* stays inside one path segment' {
        Test-Branch 'release/1.0' @('release/*') | Should -BeTrue
        Test-Branch 'release/1.0/hotfix' @('release/*') | Should -BeFalse
        Test-Branch 'release/' @('release/*') | Should -BeTrue
        Test-Branch 'release' @('release/*') | Should -BeFalse
        Test-Branch 'feature-x' @('feature*') | Should -BeTrue
    }
    It '** crosses path segments, and **/ also matches no directory at all' {
        Test-Branch 'release/1.0/hotfix' @('release/**') | Should -BeTrue
        Test-Branch 'a/b/c' @('**') | Should -BeTrue
        Test-Branch 'feature/x' @('feature/**/x') | Should -BeTrue
        Test-Branch 'feature/a/b/x' @('feature/**/x') | Should -BeTrue
        Test-Branch 'feature/a/b/y' @('feature/**/x') | Should -BeFalse
    }
    It '? and + repeat the previous character, they are not wildcards' {
        Test-Branch 'v' @('v1?') | Should -BeTrue
        Test-Branch 'v1' @('v1?') | Should -BeTrue
        Test-Branch 'v11' @('v1?') | Should -BeFalse
        Test-Branch 'vx' @('v1?') | Should -BeFalse
        Test-Branch 'v1' @('v[0-9]+') | Should -BeTrue
        Test-Branch 'v123' @('v[0-9]+') | Should -BeTrue
        Test-Branch 'v' @('v[0-9]+') | Should -BeFalse
    }
    It 'supports character classes of letters, digits and -' {
        Test-Branch 'release/v1.2' @('release/v[0-9].[0-9]') | Should -BeTrue
        Test-Branch 'release/vA.2' @('release/v[0-9].[0-9]') | Should -BeFalse
        Test-Branch 'rel-b' @('rel-[a-c]') | Should -BeTrue
    }
    It 'treats other characters, including a dot, literally' {
        Test-Branch 'release/v1.2' @('release/v1.2') | Should -BeTrue
        Test-Branch 'release/v1x2' @('release/v1.2') | Should -BeFalse
        Test-Branch 'a(b)' @('a(b)') | Should -BeTrue
    }
    It 'matches a real * or + when escaped with a backslash' {
        Test-Branch 'a*b' @('a\*b') | Should -BeTrue
        Test-Branch 'axb' @('a\*b') | Should -BeFalse
        Test-Branch 'release/1.0+hotfix' @('release/1.0\+hotfix') | Should -BeTrue
        Test-Branch 'release/1.0hotfix' @('release/1.0\+hotfix') | Should -BeFalse
    }
    It 'defaults to main when there are no patterns' {
        Test-Branch 'main' @() | Should -BeTrue
        Test-Branch 'dev' @() | Should -BeFalse
        Test-Branch 'main' $null | Should -BeTrue
    }
}

Describe 'Branch pattern exclusions' {
    It 'excludes with a leading ! and lets the last matching pattern decide' {
        $p = @('release/**', '!release/legacy/**')
        Test-Branch 'release/2.0' $p | Should -BeTrue
        Test-Branch 'release/legacy/1.0' $p | Should -BeFalse
        Test-Branch 'feature/x' $p | Should -BeFalse
    }
    It 'reviews an excluded branch again when a later pattern includes it' {
        Test-Branch 'release/legacy/1.0' @('!release/legacy/**', 'release/**') | Should -BeTrue
        Test-Branch 'release/legacy/1.0' @('release/**', '!release/legacy/**', 'release/legacy/1.0') | Should -BeTrue
    }
    It 'handles several positives and exclusions together' {
        $p = @('main', 'release/*', 'hotfix/**', '!release/*-rc*', '!hotfix/tmp/**')
        Test-Branch 'main' $p | Should -BeTrue
        Test-Branch 'release/2.0' $p | Should -BeTrue
        Test-Branch 'release/2.0-rc1' $p | Should -BeFalse
        Test-Branch 'hotfix/a/b' $p | Should -BeTrue
        Test-Branch 'hotfix/tmp/a' $p | Should -BeFalse
    }
}

Describe 'Branch pattern validation' {
    It 'rejects invalid patterns with a message that names the pattern' {
        $m = Get-ThrownMessage { Assert-BranchPatterns @('main', 'release/[a-') }
        $m | Should -Match ([regex]::Escape("'release/[a-'"))
        $m | Should -Match 'invalid character class'
        { Assert-BranchPatterns @('rel[a_b]') } | Should -Throw '*invalid character class*'
        { Assert-BranchPatterns @('?x') } | Should -Throw "*'?'*no character before it*"
        { Assert-BranchPatterns @('a*?') } | Should -Throw '*no character before it*'
        { Assert-BranchPatterns @('a??') } | Should -Throw '*no character before it*'
        { Assert-BranchPatterns @('a++') } | Should -Throw '*no character before it*'
        { Assert-BranchPatterns @('abc\') } | Should -Throw '*ends with a backslash*'
        { Assert-BranchPatterns @('main', '!') } | Should -Throw "*empty after the '!'*"
    }
    It 'rejects whitespace at either end, which would silently never match' {
        { Assert-BranchPatterns @(' main') } | Should -Throw '*whitespace*'
        { Assert-BranchPatterns @('main ') } | Should -Throw '*whitespace*'
    }
    It 'rejects a list that has only exclusions' {
        { Assert-BranchPatterns @('!release/legacy/**') } | Should -Throw '*only exclusions*'
        { Assert-BranchPatterns @('!a', '!b') } | Should -Throw '*only exclusions*'
        { Assert-BranchPatterns @('main', '!release/legacy/**') } | Should -Not -Throw
    }
    It 'accepts no patterns, and validates every pattern before matching any' {
        { Assert-BranchPatterns @() } | Should -Not -Throw
        { Assert-BranchPatterns $null } | Should -Not -Throw
        { Test-Branch 'main' @('main', 'bad[') } | Should -Throw '*invalid character class*'
    }
    It 'takes linear time however many * a pattern has (a backtracking engine times out on these)' {
        $branch = ('a' * 5000) + 'b'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Test-Branch $branch @('a*a*a*a*a*c') | Should -BeFalse
        Test-Branch $branch @('a+a+a+a+a+c') | Should -BeFalse
        Test-Branch $branch @('**a**a**a**a**c') | Should -BeFalse
        Test-Branch ($branch.Substring(0, 5000)) @('a*a*a*a*a*') | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 2
    }
}

Describe 'branches in settings' {
    It 'still defaults to main and still accepts plain names' {
        (Read-Settings -Json '' -SchemaPath $script:schema).CodeReviewAgent.branches | Should -Be @('main')
        $s = Read-Settings -Json '{"CodeReviewAgent":{"branches":["main","release/*","!release/legacy/**"]}}' -SchemaPath $script:schema
        @($s.CodeReviewAgent.branches).Count | Should -Be 3
    }
}

# The real script, in a real git repository with an `origin`, so the target-branch settings read, the pattern check and
# the skip reasons are exercised together.
Describe 'Get-PrContext.ps1 with branch patterns' {
    BeforeAll {
        $script:work = Join-Path $TestDrive 'ctx'
        $bare = Join-Path $script:work 'origin.git'
        $repo = Join-Path $script:work 'repo'
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null
        git init -q --bare $bare 2>&1 | Out-Null
        git clone -q $bare $repo 2>&1 | Out-Null
        function Invoke-RepoGit { param([string[]] $GitArgs) & git -C $repo -c user.email=t@t -c user.name=t @GitArgs 2>&1 | Out-Null }
        $script:repo = $repo
        function New-TargetBranches {
            # A base commit with the settings and one AL file, pushed under every target branch, then a feature commit on top.
            param([string] $SettingsJson, [string[]] $Branches)
            Remove-Item -LiteralPath $repo -Recurse -Force; git clone -q $bare $repo 2>&1 | Out-Null
            Invoke-RepoGit @('checkout', '-q', '-B', 'base')
            New-Item -ItemType Directory -Path (Join-Path $repo '.bcquality') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo '.bcquality/settings.json') -Value $SettingsJson
            Set-Content -LiteralPath (Join-Path $repo 'x.al') -Value 'codeunit 50000 X { }'
            Invoke-RepoGit @('add', '-A'); Invoke-RepoGit @('commit', '-q', '-m', 'base')
            foreach ($b in $Branches) { Invoke-RepoGit @('push', '-q', '--force', 'origin', "base:refs/heads/$b") }
            Invoke-RepoGit @('checkout', '-q', '-B', 'feature')
            Set-Content -LiteralPath (Join-Path $repo 'x.al') -Value 'codeunit 50000 X { // changed }'
            Invoke-RepoGit @('commit', '-q', '-am', 'change')
            Invoke-RepoGit @('fetch', '-q', 'origin')
        }
        function Get-Context {
            param([string] $Target)
            $out = Join-Path $script:work "out-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $out | Out-Null
            $head = (git -C $repo rev-parse HEAD).Trim()
            $null = & pwsh -NoProfile -File (Join-Path $script:scripts 'Get-PrContext.ps1') -RepoDir $repo -OutDir $out -TargetBranch "refs/heads/$Target" `
                -HeadSha $head -AuthorIdentity 'a@b' -SchemaPath $script:schema 2>&1
            Get-Content -LiteralPath (Join-Path $out 'context.json') -Raw | ConvertFrom-Json -Depth 30
        }
        $script:branches = 'main', 'release/2.0', 'release/legacy/1.0', 'release/2.0-rc1', 'feature/x'
    }
    It 'reviews branches the patterns include and skips the others, naming the branch' {
        New-TargetBranches '{"BCQuality":{"version":"1.9"},"CodeReviewAgent":{"enabled":true,"branches":["main","release/*","!release/*-rc*","!release/legacy/**"]}}' $script:branches
        (Get-Context 'main').skipped | Should -BeFalse
        (Get-Context 'release/2.0').skipped | Should -BeFalse
        $c = Get-Context 'release/2.0-rc1'
        $c.skipped | Should -BeTrue; $c.skipReason | Should -Be 'branch-not-enabled: release/2.0-rc1'
        (Get-Context 'release/legacy/1.0').skipReason | Should -Be 'branch-not-enabled: release/legacy/1.0'
        (Get-Context 'feature/x').skipReason | Should -Be 'branch-not-enabled: feature/x'
    }
    It 'still reviews a plain exact branch name, as before' {
        New-TargetBranches '{"BCQuality":{"version":"1.9"},"CodeReviewAgent":{"enabled":true,"branches":["release/2.0"]}}' $script:branches
        (Get-Context 'release/2.0').skipped | Should -BeFalse
        (Get-Context 'main').skipReason | Should -Be 'branch-not-enabled: main'
    }
    It 'reports a bad pattern as invalid settings, not as a silently skipped branch' {
        New-TargetBranches '{"BCQuality":{"version":"1.9"},"CodeReviewAgent":{"enabled":true,"branches":["main","release/[a-"]}}' $script:branches
        $c = Get-Context 'main'
        $c.skipped | Should -BeTrue
        $c.skipReason | Should -Match '^settings-invalid: '
        $c.skipReason | Should -Match ([regex]::Escape("'release/[a-'"))
        $c.skipReason | Should -Match 'invalid character class'
    }
    It 'reports an exclusion-only list as invalid settings' {
        New-TargetBranches '{"BCQuality":{"version":"1.9"},"CodeReviewAgent":{"enabled":true,"branches":["!release/legacy/**"]}}' $script:branches
        (Get-Context 'main').skipReason | Should -BeLike 'settings-invalid: *only exclusions*'
    }
    It 'does not look at the patterns when the review is disabled' {
        New-TargetBranches '{"CodeReviewAgent":{"enabled":false,"branches":["bad["]}}' $script:branches
        (Get-Context 'main').skipReason | Should -Be 'review-disabled'
    }
}
