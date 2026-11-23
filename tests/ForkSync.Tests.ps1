BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    $script:sync = Join-Path $script:scripts 'Sync-BCQualityFork.ps1'
    . (Join-Path $script:scripts 'ForkSync.ps1')

    function Invoke-TestGit {
        # git with a fixed identity, for building fixtures.
        param([string] $Dir, [Parameter(ValueFromRemainingArguments)] [string[]] $Rest)
        & git -C $Dir -c user.name=t -c user.email=t@example.com @Rest 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git $($Rest -join ' ') failed in $Dir" }
    }
    function Write-TestFile { param([string] $Dir, [string] $Path, [string] $Text)
        $full = Join-Path $Dir $Path
        New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value $Text
    }
    function New-ForkFixture {
        # "Microsoft" with a v1.9 release; your fork seeded from it (as New-BCQualityFork.ps1 does) with one rule of your own; a clone of the fork.
        param([string] $Name)
        $root = Join-Path $TestDrive $Name
        $up = Join-Path $root 'upstream'; $origin = Join-Path $root 'origin.git'; $work = Join-Path $root 'work'
        git init --quiet $up
        Write-TestFile $up 'README.md' 'line one'
        Write-TestFile $up 'microsoft/knowledge/a.md' 'a'
        Write-TestFile $up 'custom/knowledge/.gitkeep' ''
        Invoke-TestGit $up add -A; Invoke-TestGit $up commit --quiet -m 'release 1.9'; Invoke-TestGit $up tag v1.9
        git init --quiet --bare $origin
        git clone --quiet $up $work 2>&1 | Out-Null
        git -C $work remote set-url origin $origin
        Invoke-TestGit $work checkout --quiet -B main v1.9
        Invoke-TestGit $work push --quiet origin main
        git -C $origin symbolic-ref HEAD refs/heads/main
        Write-TestFile $work 'custom/knowledge/style/my-rule.md' 'mine'
        Invoke-TestGit $work add -A; Invoke-TestGit $work commit --quiet -m 'my rule'
        Invoke-TestGit $work push --quiet origin main
        [pscustomobject]@{ Root = $root; Upstream = $up; Origin = $origin; Work = $work }
    }
    function Add-Release {
        # A later upstream release that changes a Microsoft article and adds one.
        param($F, [string] $Tag, [string] $ReadmeText)
        Write-TestFile $F.Upstream 'microsoft/knowledge/a.md' "a for $Tag"
        Write-TestFile $F.Upstream "microsoft/knowledge/new-$Tag.md" 'new'
        if ($ReadmeText) { Write-TestFile $F.Upstream 'README.md' $ReadmeText }
        Invoke-TestGit $F.Upstream add -A; Invoke-TestGit $F.Upstream commit --quiet -m "release $Tag"; Invoke-TestGit $F.Upstream tag $Tag
    }
    function Invoke-Sync {
        param($F, [hashtable] $Extra = @{})
        $out = try { & $script:sync -RepoDir $F.Work -UpstreamUrl $F.Upstream @Extra *>&1 | Out-String } catch { "THROWN: $($_.Exception.Message)" }
        $out
    }
}

Describe 'Choosing the upstream release' {
    It 'takes the highest vMAJOR.MINOR release by number, not by text' {
        $sha = '1' * 40
        $lines = @("$sha`trefs/tags/v1.9", "$sha`trefs/tags/v1.10", "$sha`trefs/tags/v1.2")
        (Get-LatestUpstreamRelease -Lines $lines).Tag | Should -Be 'v1.10'
    }
    It 'ignores tags that are not plain releases' {
        $a = 'a' * 40; $b = 'b' * 40
        $r = Get-LatestUpstreamRelease -Lines @("$a`trefs/tags/v1.9", "$b`trefs/tags/v1.10.1", "$b`trefs/tags/v2.0-beta", "$b`trefs/tags/nightly", "$b`trefs/tags/1.11")
        $r.Tag | Should -Be 'v1.9'
        $r.Commit | Should -Be $a
    }
    It 'returns nothing when there is no release' {
        Get-LatestUpstreamRelease -Lines @() | Should -BeNullOrEmpty
        Get-LatestUpstreamRelease -Lines @(('c' * 40) + "`trefs/tags/latest") | Should -BeNullOrEmpty
    }
}

Describe 'Pull request text and request' {
    It 'names the release, counts what changed by area, and links the release notes on GitHub' {
        $t = New-SyncPullRequestText -Tag 'v1.10' -UpstreamUrl 'https://github.com/microsoft/BCQuality.git' -BaseBranch 'main' `
            -ChangedFiles @('microsoft/knowledge/a.md', 'microsoft/knowledge/b.md', 'community/x.md', 'custom/README.md') -CommitCount 3
        $t.Title | Should -Be 'Sync upstream BCQuality v1.10'
        $t.Description | Should -Match 'v1\.10\*\* into `main`: 3 upstream commit\(s\), 4 changed file\(s\)'
        $t.Description | Should -Match '`microsoft`: 2 file\(s\)'
        $t.Description | Should -Match '`custom`: 1 file\(s\)'
        $t.Description | Should -Match 'https://github.com/microsoft/BCQuality/releases/tag/v1\.10'
        $t.Description.Length | Should -BeLessThan 4000
    }
    It 'sends the branches, title and token to the pull requests endpoint' {
        Mock Invoke-RestMethod { [pscustomobject]@{ pullRequestId = 42; repository = [pscustomobject]@{ webUrl = 'https://dev.azure.com/o/P%20Q/_git/R' } } }
        $pr = New-AdoSyncPullRequest -CollectionUri 'https://dev.azure.com/o/' -Project 'P Q' -RepositoryId 'rid' -Token 'T' `
            -SourceBranch 'sync-upstream-v1.10' -TargetBranch 'main' -Title 'ttl' -Description 'desc'
        $pr.Id | Should -Be 42
        $pr.Url | Should -Be 'https://dev.azure.com/o/P%20Q/_git/R/pullrequest/42'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://dev.azure.com/o/P%20Q/_apis/git/repositories/rid/pullrequests?api-version=7.1' -and $Method -eq 'Post' -and
            $Headers.Authorization -eq 'Bearer T' -and
            (($Body | ConvertFrom-Json).sourceRefName -eq 'refs/heads/sync-upstream-v1.10') -and (($Body | ConvertFrom-Json).targetRefName -eq 'refs/heads/main')
        }
    }
}

Describe 'Sync-BCQualityFork' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    It 'does nothing when the fork already has the newest release' {
        $f = New-ForkFixture 'uptodate'
        $out = Invoke-Sync $f
        $out | Should -Match 'Up to date'
        @(git -C $f.Origin branch --list) | Should -HaveCount 1
        @(git -C $f.Origin tag --list) | Should -HaveCount 0
    }
    It 'merges a new release onto a new branch, keeps your rules, never touches main, and pushes no upstream tags' {
        $f = New-ForkFixture 'merge'
        Add-Release $f 'v1.10'
        $mainBefore = git -C $f.Origin rev-parse main
        $out = Invoke-Sync $f
        $out | Should -Match 'Pushed sync-upstream-v1.10'
        $out | Should -Match 'BCQ_SYNC_RESULT\]branch-pushed'

        (git -C $f.Origin rev-parse main) | Should -Be $mainBefore
        $branch = 'refs/heads/sync-upstream-v1.10'
        (git -C $f.Origin show "${branch}:microsoft/knowledge/a.md") | Should -Be 'a for v1.10'     # the new release
        (git -C $f.Origin show "${branch}:custom/knowledge/style/my-rule.md") | Should -Be 'mine'    # your rule
        (git -C $f.Origin show "${branch}:microsoft/knowledge/new-v1.10.md") | Should -Be 'new'
        $parents = @(git -C $f.Origin log -1 --format=%P $branch) -split ' '
        $parents | Should -HaveCount 2
        $parents | Should -Contain $mainBefore
        $parents | Should -Contain (git -C $f.Upstream rev-parse v1.10)
        (git -C $f.Origin log -1 --format=%s $branch) | Should -Be 'Merge upstream BCQuality v1.10'
        @(git -C $f.Origin tag --list) | Should -HaveCount 0
        @(git -C $f.Work status --porcelain) | Should -HaveCount 0
    }
    It 'takes only the release, not upstream commits made after it' {
        $f = New-ForkFixture 'tagsonly'
        Add-Release $f 'v1.10'
        Write-TestFile $f.Upstream 'microsoft/knowledge/unreleased.md' 'work in progress'
        Invoke-TestGit $f.Upstream add -A; Invoke-TestGit $f.Upstream commit --quiet -m 'after the release'
        $null = Invoke-Sync $f
        @(git -C $f.Origin ls-tree -r --name-only refs/heads/sync-upstream-v1.10) | Should -Not -Contain 'microsoft/knowledge/unreleased.md'
    }
    It 'proposes the newest of several releases it has missed, once' {
        $f = New-ForkFixture 'twice'
        Add-Release $f 'v1.10'; Add-Release $f 'v1.11'
        $first = Invoke-Sync $f
        $first | Should -Match 'Pushed sync-upstream-v1.11'
        @(git -C $f.Origin branch --list 'sync-upstream-*') | Should -HaveCount 1
        $tip = git -C $f.Origin rev-parse refs/heads/sync-upstream-v1.11
        $second = Invoke-Sync $f
        $second | Should -Match 'Already proposed'
        (git -C $f.Origin rev-parse refs/heads/sync-upstream-v1.11) | Should -Be $tip
    }
    It 'stops being needed once the sync branch is merged into main' {
        $f = New-ForkFixture 'merged'
        Add-Release $f 'v1.10'
        $null = Invoke-Sync $f
        Invoke-TestGit $f.Work fetch --quiet origin
        Invoke-TestGit $f.Work checkout --quiet main
        Invoke-TestGit $f.Work merge --quiet --ff-only origin/sync-upstream-v1.10
        Invoke-TestGit $f.Work push --quiet origin main
        (Invoke-Sync $f) | Should -Match 'Up to date'
    }
    It 'fails on a conflict, names the file, pushes nothing and leaves the clone clean' {
        $f = New-ForkFixture 'conflict'
        Write-TestFile $f.Work 'README.md' 'line one, changed by the fork'
        Invoke-TestGit $f.Work commit --quiet -am 'fork edits the readme'; Invoke-TestGit $f.Work push --quiet origin main
        Add-Release $f 'v1.10' 'line one, changed by upstream'
        $out = Invoke-Sync $f
        $out | Should -Match 'THROWN: Merging upstream v1.10 into main needs a person'
        $out | Should -Match 'README.md'
        $out | Should -Match 'Nothing was pushed'
        @(git -C $f.Origin branch --list 'sync-upstream-*') | Should -HaveCount 0
        @(git -C $f.Work status --porcelain) | Should -HaveCount 0
        @(git -C $f.Work diff --name-only --diff-filter=U) | Should -HaveCount 0
    }
    It 'refuses a clone whose origin is the upstream repository' {
        $f = New-ForkFixture 'wrongorigin'
        git -C $f.Work remote set-url origin $f.Upstream
        (Invoke-Sync $f) | Should -Match 'origin is the upstream repository'
    }
    It 'refuses a clone with uncommitted changes' {
        $f = New-ForkFixture 'dirty'
        Write-TestFile $f.Work 'scratch.txt' 'x'
        (Invoke-Sync $f) | Should -Match 'uncommitted changes'
    }
    It 'fails clearly when upstream has no release' {
        $f = New-ForkFixture 'norelease'
        git -C $f.Upstream tag -d v1.9 | Out-Null
        (Invoke-Sync $f) | Should -Match 'has no release'
    }
}
