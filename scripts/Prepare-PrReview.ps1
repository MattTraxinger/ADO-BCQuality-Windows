#requires -Version 7.5
<#
.SYNOPSIS
    Prepares an in-job review: PR metadata (read only), the PR head in its own worktree, eligibility, pinned BCQuality.
.DESCRIPTION
    For pipelines that run the review as steps inside an existing PR validation job (instead of the standalone
    template). Holds the build identity's token (to read the PR) and no AI secret. Settings come from -SettingsFile,
    which the pipeline writes itself outside the PR tree.
    Sets BCQ_CONTEXT (context.json exists), BCQ_SKIP, BCQ_READY, BCQ_REPO_DIR, BCQ_ROOT and BCQ_COMMIT.
    The PR head is checked out into a separate worktree so the job's own workspace is left exactly as it was.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ScriptsRoot,      # folder holding scripts/, schemas/ and package.json
    [Parameter(Mandatory)] [string] $RepoDir,          # the job's checkout
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $SettingsFile,
    [Parameter(Mandatory)] [string] $CollectionUri,
    [Parameter(Mandatory)] [string] $Project,
    [Parameter(Mandatory)] [string] $RepositoryId,
    [Parameter(Mandatory)] [int] $PullRequestId,
    [Parameter(Mandatory)] [string] $TargetBranch,
    [Parameter(Mandatory)] [string] $HeadSha
)

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $ScriptsRoot 'scripts'
. (Join-Path $scripts 'Common.ps1')
. (Join-Path $scripts 'AzureDevOps.ps1')

if (-not $env:SYSTEM_ACCESSTOKEN) { throw 'SYSTEM_ACCESSTOKEN is not mapped into this step.' }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# 1. PR metadata for the eligibility rules (draft, author). Read only.
$ado = New-AdoContext -CollectionUri $CollectionUri -Project $Project -RepositoryId $RepositoryId -PullRequestId $PullRequestId -Token $env:SYSTEM_ACCESSTOKEN
$pr = Get-AdoPullRequest $ado

# 2. The PR head, read only, in its own folder. The job's workspace (the merge checkout) is not touched.
$headDir = Join-Path $WorkDir 'head'
if (Test-Path -LiteralPath $headDir) { git -C $RepoDir worktree remove --force $headDir 2>$null; Remove-Item -LiteralPath $headDir -Recurse -Force -ErrorAction SilentlyContinue }
git -C $RepoDir worktree add --detach $headDir $HeadSha
if ($LASTEXITCODE -ne 0) { throw "Could not check out PR head $HeadSha. Is the checkout shallow? It needs fetchDepth: 0." }

# 3. Eligibility and settings.
$contextDir = Join-Path $WorkDir 'context'
& (Join-Path $scripts 'Get-PrContext.ps1') -RepoDir $RepoDir -OutDir $contextDir -TargetBranch $TargetBranch -HeadSha $HeadSha `
    -AuthorIdentity ([string]$pr.createdBy.uniqueName) -IsDraft ([bool]$pr.isDraft) `
    -SchemaPath (Join-Path $ScriptsRoot 'schemas/bcquality-ado.settings.schema.json') -SettingsFile $SettingsFile
$contextPath = Join-Path $contextDir 'context.json'
$context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json -Depth 50
Set-PipelineVariable -Name BCQ_CONTEXT -Value 'true'
Set-PipelineVariable -Name BCQ_SKIP -Value ([string]([bool]$context.skipped).ToString().ToLower())
if ($context.skipped) {
    Write-Host "BCQuality review skipped: $($context.skipReason)"
    return
}

# 4. The pinned BCQuality release.
Set-PipelineVariable -Name BCQ_REPO_DIR -Value $headDir
& (Join-Path $scripts 'Initialize-BCQuality.ps1') -ContextPath $contextPath -TempDir $WorkDir -CollectionUri $CollectionUri
Set-PipelineVariable -Name BCQ_READY -Value 'true'
Write-Host "Ready: reviewing $HeadSha against $($context.targetBranch)."
