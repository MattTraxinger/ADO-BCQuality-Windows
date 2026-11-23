#requires -Version 7.5
<#
.SYNOPSIS
    Seeds an empty Git repository with a release of Microsoft's BCQuality, to be your organization's fork of it.
.DESCRIPTION
    Your own rules go in the Custom layer of a copy of BCQuality that you control (docs/bcquality-fork.md). This script
    creates that copy's first commit: it clones the target, adds Microsoft's repository as the `upstream` remote, makes
    `main` point at the upstream release you name, and pushes `main` plus a `v<Version>` tag. The pipeline clones that tag.
    Upstream's own tag is kept locally as `upstream/v<Version>` and is not pushed, so it can never clash with your release tags.

    Safe to run: it stops if the target already has any branch or tag, if the target is Microsoft's repository, if the
    release does not exist, or if the working folder is not empty. It never deletes anything and never forces a push.
    The target repository has to exist and be empty (no README); it is not created here. Git uses your own credentials.
.EXAMPLE
    pwsh scripts/New-BCQualityFork.ps1 -TargetUrl https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/BCQualityFork -Version 1.9
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TargetUrl,     # the empty repository that becomes your fork
    [Parameter(Mandatory)] [string] $Version,       # the upstream release to start from, major.minor, for example 1.9
    [string] $UpstreamUrl = 'https://github.com/microsoft/BCQuality.git',
    [string] $WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'BCQualityFork')   # where the clone goes; must be new or empty
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    # Runs git, returns its output lines, and throws with that output when git fails.
    param([Parameter(Mandatory)] [string[]] $Arguments, [string] $In)
    $all = if ($In) { @('-C', $In) + $Arguments } else { $Arguments }
    $output = & git @all 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $((@($output) | Out-String).Trim())" }
    @($output | ForEach-Object { "$_" })
}

function Get-RepoIdentity {
    # A comparable form of a repository URL: lower case, no trailing slash or .git.
    param([string] $Url)
    ($Url.Trim().TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
}

if ($Version -notmatch '^\d+\.\d+$') { throw "Version must be an upstream release as major.minor, such as 1.9 (got '$Version')." }
$tag = "v$Version"

# The target must be yours, not Microsoft's, and empty.
if ((Get-RepoIdentity $TargetUrl) -eq (Get-RepoIdentity $UpstreamUrl) -or (Get-RepoIdentity $TargetUrl) -match '^https://github\.com/microsoft/bcquality$') {
    throw 'The target is the upstream repository. Create your own empty repository and pass its URL as -TargetUrl.'
}
$existing = @(Invoke-Git @('ls-remote', $TargetUrl))
if ($existing.Count) { throw "The target already has branches or tags, so it is not seeded again. To bring in a newer upstream release use the update steps in docs/bcquality-fork.md." }

# The release must exist upstream.
if (-not @(Invoke-Git @('ls-remote', '--tags', $UpstreamUrl, "refs/tags/$tag")).Count) { throw "Upstream has no release tagged $tag at $UpstreamUrl." }

# The working folder must be new or empty.
if ((Test-Path -LiteralPath $WorkDir) -and @(Get-ChildItem -LiteralPath $WorkDir -Force).Count) { throw "$WorkDir is not empty. Pass an empty or new -WorkDir." }

Write-Host "Cloning the empty target into $WorkDir"
$null = Invoke-Git @('clone', '--quiet', $TargetUrl, $WorkDir)
$null = Invoke-Git @('remote', 'add', 'upstream', $UpstreamUrl) -In $WorkDir

Write-Host "Fetching upstream release $tag"
$null = Invoke-Git @('fetch', '--quiet', '--no-tags', 'upstream', "refs/tags/${tag}:refs/tags/upstream/$tag") -In $WorkDir
$null = Invoke-Git @('checkout', '--quiet', '-B', 'main', "refs/tags/upstream/$tag") -In $WorkDir
$null = Invoke-Git @('tag', $tag) -In $WorkDir

Write-Host "Pushing main and $tag to the target"
$null = Invoke-Git @('push', '--quiet', 'origin', 'main', "refs/tags/$tag") -In $WorkDir

$commit = @(Invoke-Git @('rev-parse', 'HEAD') -In $WorkDir)[0]   # @() because a one-line result is unrolled to a string
Write-Host ''
Write-Host "Done. $TargetUrl now holds upstream $tag ($commit) as main, tagged $tag."
Write-Host "The clone in $WorkDir has Microsoft's repository as the 'upstream' remote."
Write-Host 'Next: add your rules under custom/ on a branch, merge them, and tag a release such as'
Write-Host "v$Version.1 (see docs/bcquality-fork.md). Then set BCQuality.repo and BCQuality.version in the review settings."
