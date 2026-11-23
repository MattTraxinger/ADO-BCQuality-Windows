# Helpers for scripts/Sync-BCQualityFork.ps1, which brings a new upstream BCQuality release into an organization fork.
Set-StrictMode -Version Latest

function Get-RepoIdentity {
    # A comparable form of a repository URL or path: lower case, no trailing slash or .git.
    param([string] $Url)
    ($Url.Trim().TrimEnd('/') -replace '\.git$', '').ToLowerInvariant()
}

function Get-LatestUpstreamRelease {
    # From `git ls-remote --tags --refs` lines ("<sha><TAB>refs/tags/<name>"), the highest release named v<major>.<minor>,
    # compared as numbers (v1.10 is newer than v1.9). Other tags (v1.9.1, v2.0-beta, anything else) are not releases.
    # Returns { Tag; Version; Commit }, or $null when there is none.
    param([string[]] $Lines)
    $best = $null
    foreach ($line in $Lines) {
        if ($line -notmatch '^\s*([0-9a-f]{40})\s+refs/tags/v(\d+)\.(\d+)\s*$') { continue }
        $commit = $Matches[1]; $name = "v$($Matches[2]).$($Matches[3])"
        $version = [version]"$($Matches[2]).$($Matches[3])"
        if (-not $best -or $version -gt $best.Version) { $best = [pscustomobject]@{ Tag = $name; Version = $version; Commit = $commit } }
    }
    $best
}

function New-SyncPullRequestText {
    # Title and description of the pull request that brings an upstream release in.
    param(
        [Parameter(Mandatory)] [string] $Tag,
        [Parameter(Mandatory)] [string] $UpstreamUrl,
        [Parameter(Mandatory)] [string] $BaseBranch,
        [string[]] $ChangedFiles = @(),     # files upstream changed since your last common commit
        [int] $CommitCount = 0
    )
    $areas = @($ChangedFiles | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[0] } | Group-Object | Sort-Object Name |
            ForEach-Object { "- ``$($_.Name)``: $($_.Count) file(s)" })
    $site = (Get-RepoIdentity $UpstreamUrl)
    $release = if ($site -match '^https://github\.com/') { "[Release notes and changes]($($UpstreamUrl.Trim().TrimEnd('/') -replace '\.git$', '')/releases/tag/$Tag)" } else { $null }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Brings upstream BCQuality **$Tag** into ``$BaseBranch``: $CommitCount upstream commit(s), $(@($ChangedFiles).Count) changed file(s).")
    if ($areas.Count) { $lines.Add(''); $lines.Add('Where upstream changed things:'); $areas | ForEach-Object { $lines.Add($_) } }
    if ($release) { $lines.Add(''); $lines.Add($release) }
    $lines.Add('')
    $lines.Add('Before you complete this:')
    $lines.Add('- Look at what changed under `microsoft/` and `community/`, and at anything that touched `custom/`.')
    $lines.Add('- Run a review on a sample pull request against this branch if your rules depend on upstream articles.')
    $lines.Add('')
    $lines.Add("After you complete it, tag the merge commit with your own release (for example ``$Tag.1``) and raise ``BCQuality.version``. See docs/bcquality-fork.md.")
    [pscustomobject]@{ Title = "Sync upstream BCQuality $Tag"; Description = ($lines -join "`n") }
}

function New-AdoSyncPullRequest {
    # Opens the pull request in the build's own repository with the build identity's token. Returns { Id; Url }.
    param(
        [Parameter(Mandatory)] [string] $CollectionUri,
        [Parameter(Mandatory)] [string] $Project,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $SourceBranch,
        [Parameter(Mandatory)] [string] $TargetBranch,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Description
    )
    $uri = "$($CollectionUri.TrimEnd('/'))/$([uri]::EscapeDataString($Project))/_apis/git/repositories/$RepositoryId/pullrequests?api-version=7.1"
    $body = [ordered]@{
        sourceRefName = "refs/heads/$SourceBranch"
        targetRefName = "refs/heads/$TargetBranch"
        title         = $Title
        description   = $Description
    } | ConvertTo-Json
    $pr = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $Token" } -Body $body -ContentType 'application/json'
    $webUrl = if ($pr.PSObject.Properties['repository'] -and $pr.repository.PSObject.Properties['webUrl']) { "$($pr.repository.webUrl)/pullrequest/$($pr.pullRequestId)" } else { $null }
    [pscustomobject]@{ Id = $pr.pullRequestId; Url = $webUrl }
}
