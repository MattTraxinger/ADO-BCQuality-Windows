BeforeAll {
    $script:script = Join-Path $PSScriptRoot '..\scripts\New-BCQualityFork.ps1'
    $script:haveGit = [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)

    function New-Fixture {
        # A stand-in "Microsoft" repository with a v1.9 release (and a later commit that the release does not include), and an empty target.
        param([string] $Name)
        $root = Join-Path $TestDrive $Name
        $upstream = Join-Path $root 'upstream'
        git init --quiet $upstream
        New-Item -ItemType Directory -Path (Join-Path $upstream 'custom/knowledge') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $upstream 'custom/knowledge/.gitkeep') -Value ''
        Set-Content -LiteralPath (Join-Path $upstream 'README.md') -Value 'release'
        git -C $upstream add -A
        git -C $upstream -c user.name=t -c user.email=t@example.com commit --quiet -m release
        git -C $upstream tag v1.9
        Set-Content -LiteralPath (Join-Path $upstream 'README.md') -Value 'after the release'
        git -C $upstream -c user.name=t -c user.email=t@example.com commit --quiet -am later
        $target = Join-Path $root 'target.git'
        git init --quiet --bare $target
        [pscustomobject]@{ Root = $root; Upstream = $upstream; Target = $target; Work = (Join-Path $root 'work') }
    }
    function Get-ThrownMessage {
        param([scriptblock] $Block)
        try { & $Block; $null } catch { $_.Exception.Message }
    }
}

Describe 'New-BCQualityFork' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    It 'seeds the empty target with the release as main, tagged with the release, and keeps upstream tags out of it' {
        $f = New-Fixture 'ok'
        $log = (& $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir $f.Work *>&1 | Out-String)

        $release = git -C $f.Upstream rev-parse v1.9
        $log | Should -Match "upstream v1\.9 \($release\) as main"   # the whole commit id, not its first letter
        (git -C $f.Target rev-parse main) | Should -Be $release
        (git -C $f.Target rev-parse 'refs/tags/v1.9^{commit}') | Should -Be $release
        @(git -C $f.Target tag --list) | Should -Be @('v1.9')        # not upstream/v1.9
        (git -C $f.Target show 'main:README.md') | Should -Be 'release'   # the release, not the later upstream commit
        (git -C $f.Target ls-tree -r --name-only main) | Should -Contain 'custom/knowledge/.gitkeep'
    }
    It 'leaves a clone that can fetch and merge later upstream releases' {
        $f = New-Fixture 'clone'
        & $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir $f.Work *> $null
        (git -C $f.Work remote get-url upstream) | Should -Be $f.Upstream
        (git -C $f.Work remote get-url origin) | Should -Be $f.Target
        (git -C $f.Work rev-parse 'refs/tags/upstream/v1.9') | Should -Be (git -C $f.Upstream rev-parse v1.9)
        (git -C $f.Work branch --show-current) | Should -Be 'main'
    }
    It 'refuses a target that already has content, and changes nothing' {
        $f = New-Fixture 'full'
        & $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir $f.Work *> $null
        $before = git -C $f.Target rev-parse main
        $m = Get-ThrownMessage { & $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir (Join-Path $f.Root 'work2') *> $null }
        $m | Should -Match 'already has branches or tags'
        (git -C $f.Target rev-parse main) | Should -Be $before
    }
    It 'refuses the upstream repository as the target' {
        $f = New-Fixture 'same'
        (Get-ThrownMessage { & $script:script -TargetUrl $f.Upstream -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir $f.Work }) | Should -Match 'target is the upstream'
        (Get-ThrownMessage { & $script:script -TargetUrl 'https://github.com/microsoft/BCQuality.git' -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir $f.Work }) | Should -Match 'target is the upstream'
        (Get-ThrownMessage { & $script:script -TargetUrl 'https://GitHub.com/Microsoft/BCQuality/' -Version '1.9' -WorkDir $f.Work }) | Should -Match 'target is the upstream'
    }
    It 'refuses a release that does not exist upstream' {
        $f = New-Fixture 'norelease'
        (Get-ThrownMessage { & $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version '9.9' -WorkDir $f.Work }) | Should -Match 'no release tagged v9.9'
        @(git -C $f.Target tag --list).Count | Should -Be 0
    }
    It 'refuses a version that is not major.minor' {
        $f = New-Fixture 'badversion'
        foreach ($v in 'latest', '1', '1.9.1', 'v1.9') {
            (Get-ThrownMessage { & $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version $v -WorkDir $f.Work }) | Should -Match 'major.minor'
        }
    }
    It 'refuses a working folder that already has files, and leaves them alone' {
        $f = New-Fixture 'busy'
        New-Item -ItemType Directory -Path $f.Work | Out-Null
        Set-Content -LiteralPath (Join-Path $f.Work 'mine.txt') -Value 'keep'
        (Get-ThrownMessage { & $script:script -TargetUrl $f.Target -UpstreamUrl $f.Upstream -Version '1.9' -WorkDir $f.Work }) | Should -Match 'is not empty'
        (Get-Content -LiteralPath (Join-Path $f.Work 'mine.txt')) | Should -Be 'keep'
        @(git -C $f.Target tag --list).Count | Should -Be 0
    }
}
