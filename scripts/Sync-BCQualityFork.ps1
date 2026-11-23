#requires -Version 7.2
<#
.SYNOPSIS
    Brings the newest upstream BCQuality release into your fork, as a branch and a pull request. Never changes main.
.DESCRIPTION
    Meant to run on a schedule in your fork (examples/bcquality-fork/sync-upstream.yml), or by hand in a clone of it.
    It looks at Microsoft's release tags (v<major>.<minor> only, not upstream's main branch), and if the newest one is not
    already part of your base branch it merges that release into a new branch `sync-upstream-v<release>`, pushes the
    branch, and opens a pull request. Upstream tags are kept in the clone as upstream/v<release> and are never pushed.

    It does nothing, and exits successfully, when your fork already has the newest release or a branch for it already
    exists (delete that branch to have it proposed again). If the merge conflicts it aborts, pushes nothing and fails with
    the conflicting files. It never pushes the base branch and never forces a push.

    The clone needs its full history (fetchDepth: 0 in a pipeline). Pushing and the pull request use the build identity's
    token (SYSTEM_ACCESSTOKEN), which needs Contribute, Create branch and Contribute to pull requests on the repository.
    Pass -CollectionUri, -Project and -RepositoryId to open the pull request; without them the branch is pushed only.
.EXAMPLE
    pwsh scripts/Sync-BCQualityFork.ps1 -RepoDir . -CollectionUri $(System.CollectionUri) -Project $(System.TeamProject) -RepositoryId $(Build.Repository.ID)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoDir,                 # a clone of your fork, with origin pointing at it
    [string] $UpstreamUrl = 'https://github.com/microsoft/BCQuality.git',
    [string] $BaseBranch = 'main',
    [string] $Token = $env:SYSTEM_ACCESSTOKEN,                # sent to origin only, as a one-off header
    [string] $CollectionUri,
    [string] $Project,
    [string] $RepositoryId,
    [string] $AuthorName = 'BCQuality fork sync',
    [string] $AuthorEmail = 'bcquality-fork-sync@noreply.invalid'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ForkSync.ps1')

function Invoke-Git {
    # Runs git in the clone and returns its output lines; throws with the output when git fails, unless -AllowFailure
    # (then $script:GitExit holds the exit code). -Authenticated sends the token to origin through this process's
    # environment only, so it is neither on the command line nor stored in the clone.
    param([Parameter(Mandatory)] [string[]] $Arguments, [switch] $Authenticated, [switch] $AllowFailure)
    $names = 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_TERMINAL_PROMPT'
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        if ($Authenticated -and $Token) {
            $env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'http.extraheader'; $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: bearer $Token"
        }
        $output = & git -C $RepoDir @Arguments 2>&1
        $script:GitExit = $LASTEXITCODE
    }
    finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
    if ($script:GitExit -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed: $((@($output) | Out-String).Trim())" }
    @($output | ForEach-Object { "$_" })
}

function Set-SyncResult {
    param([string] $Result)
    Write-Host "##vso[task.setvariable variable=BCQ_SYNC_RESULT]$Result"
}

# --- Checks -----------------------------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $RepoDir)) { throw "$RepoDir does not exist." }
$null = Invoke-Git @('rev-parse', '--is-inside-work-tree')
$origin = @(Invoke-Git @('remote', 'get-url', 'origin'))[0]
if ((Get-RepoIdentity $origin) -eq (Get-RepoIdentity $UpstreamUrl) -or (Get-RepoIdentity $origin) -match '^https://github\.com/microsoft/bcquality$') {
    throw 'origin is the upstream repository. Run this in a clone of your own fork.'
}
if (@(Invoke-Git @('status', '--porcelain')).Count) { throw "$RepoDir has uncommitted changes. Use a clean clone." }

# --- Which release is the newest, and is it already here --------------------------------------------------------------
if (@(Invoke-Git @('remote')) -contains 'upstream') { $null = Invoke-Git @('remote', 'set-url', 'upstream', $UpstreamUrl) }
else { $null = Invoke-Git @('remote', 'add', 'upstream', $UpstreamUrl) }

$release = Get-LatestUpstreamRelease -Lines @(Invoke-Git @('ls-remote', '--tags', '--refs', 'upstream', 'refs/tags/v*'))
if (-not $release) { throw "Upstream $UpstreamUrl has no release tagged v<major>.<minor>." }
$tag = $release.Tag
$upstreamRef = "refs/tags/upstream/$tag"
$baseRef = "refs/remotes/origin/$BaseBranch"

$null = Invoke-Git @('fetch', '--quiet', '--no-tags', 'origin', "+refs/heads/${BaseBranch}:$baseRef") -Authenticated
$null = Invoke-Git @('fetch', '--quiet', '--no-tags', 'upstream', "refs/tags/${tag}:$upstreamRef")

$null = Invoke-Git @('merge-base', '--is-ancestor', $upstreamRef, $baseRef) -AllowFailure
if ($script:GitExit -eq 0) {
    Write-Host "Up to date: $BaseBranch already contains upstream $tag."
    Set-SyncResult 'up-to-date'
    return
}

$branch = "sync-upstream-$tag"
if (@(Invoke-Git @('ls-remote', '--heads', 'origin', "refs/heads/$branch") -Authenticated).Count) {
    Write-Host "Already proposed: branch $branch exists. Complete or delete it to continue."
    Set-SyncResult 'already-proposed'
    return
}

# --- Merge on a new branch --------------------------------------------------------------------------------------------
$changed = @(Invoke-Git @('diff', '--name-only', "$baseRef...$upstreamRef") -AllowFailure)
if ($script:GitExit -ne 0) { $changed = @() }   # unrelated histories: the merge below reports it
$count = @(Invoke-Git @('rev-list', '--count', '--no-merges', "$baseRef..$upstreamRef") -AllowFailure)
$commitCount = if ($script:GitExit -eq 0 -and $count[0] -match '^\d+$') { [int]$count[0] } else { 0 }

$null = Invoke-Git @('checkout', '--quiet', '-B', $branch, $baseRef)
$null = Invoke-Git @('-c', "user.name=$AuthorName", '-c', "user.email=$AuthorEmail", 'merge', '--no-ff', '--no-edit', '-m', "Merge upstream BCQuality $tag", $upstreamRef) -AllowFailure
if ($script:GitExit -ne 0) {
    $conflicts = @(Invoke-Git @('diff', '--name-only', '--diff-filter=U') -AllowFailure | Where-Object { $_ })
    $null = Invoke-Git @('merge', '--abort') -AllowFailure
    $null = Invoke-Git @('checkout', '--quiet', '--detach', $baseRef) -AllowFailure
    Set-SyncResult 'conflict'
    $where = if ($conflicts.Count) { "These files conflict: $($conflicts -join ', ')." } else { 'The histories are unrelated or the merge could not be made.' }
    throw "Merging upstream $tag into $BaseBranch needs a person. $where Nothing was pushed. Merge it by hand: git fetch upstream tag $tag; git checkout -b $branch $BaseBranch; git merge $tag. See docs/bcquality-fork.md."
}

$null = Invoke-Git @('push', '--quiet', 'origin', "refs/heads/${branch}:refs/heads/$branch") -Authenticated
Write-Host "Pushed ${branch}: upstream $tag merged into $BaseBranch ($commitCount upstream commit(s), $($changed.Count) changed file(s))."

# --- Pull request -----------------------------------------------------------------------------------------------------
if ($CollectionUri -and $Project -and $RepositoryId -and $Token) {
    $text = New-SyncPullRequestText -Tag $tag -UpstreamUrl $UpstreamUrl -BaseBranch $BaseBranch -ChangedFiles $changed -CommitCount $commitCount
    $pr = New-AdoSyncPullRequest -CollectionUri $CollectionUri -Project $Project -RepositoryId $RepositoryId -Token $Token `
        -SourceBranch $branch -TargetBranch $BaseBranch -Title $text.Title -Description $text.Description
    Write-Host "Opened pull request $($pr.Id): $($pr.Url)"
    Set-SyncResult 'pull-request'
}
else {
    Write-Host "No pull request was opened (pass -CollectionUri, -Project and -RepositoryId, and a token). Open one from $branch into $BaseBranch."
    Set-SyncResult 'branch-pushed'
}
