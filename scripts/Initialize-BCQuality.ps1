#requires -Version 7.5
<#
.SYNOPSIS
    Clones the pinned BCQuality release OUTSIDE the client checkout, builds its knowledge index, records its commit.
.DESCRIPTION
    Sets BCQ_ROOT and BCQ_COMMIT. Layers and disabled skills are applied per call by Invoke-BCQualityReview.ps1
    through the task context. Disabled layers and knowledge allow/deny rules are applied here by deleting files from
    this temporary clone (scripts/KnowledgePolicy.ps1) before the index is built, because BCQuality's own tools
    do not enforce them. Entry expects the host to supply knowledge-index.json and the agent runs without a shell,
    so the index is built here too.
    Credentials: a repository in this Azure DevOps organization (an organization fork) is cloned with the build identity's
    token, taken from the SYSTEM_ACCESSTOKEN environment variable of this step; the build service needs Read access to
    it. Any other host gets no credentials, so that repository must be publicly readable.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ContextPath,
    [Parameter(Mandatory)] [string] $TempDir,
    [string] $CollectionUri = $env:SYSTEM_COLLECTIONURI   # the build's organization; decides where the token may be sent
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'BCQualityRepo.ps1')

$ctx = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -Depth 50
$version = $ctx.settings.BCQuality.version
$repo = $ctx.settings.BCQuality.repo
$root = Join-Path $TempDir 'bcquality'
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }   # a reused agent folder must not leak an old clone

$authenticated = Invoke-BCQualityClone -Repo $repo -Version $version -Root $root -CollectionUri $CollectionUri -Token $env:SYSTEM_ACCESSTOKEN
if ($authenticated) { Write-Host "Cloned $repo with the build identity (same Azure DevOps organization)." }

# Prune knowledge to the target branch's allow/deny rules, delete disabled layers, then build knowledge-index.json over
# what is left (scripts/KnowledgePolicy.ps1). BCQuality's own tools do not enforce these rules, so the files must be gone
# before the index is built and before the agent can read them.
. (Join-Path $PSScriptRoot 'KnowledgePolicy.ps1')
$knowledge = $ctx.settings.BCQuality.PSObject.Properties['knowledge']
# @(if ...) not `$x = if ... { @() }`: an if used as an expression unrolls an empty array to $null.
$allow = @(if ($knowledge) { $knowledge.Value.allow })
$deny = @(if ($knowledge) { $knowledge.Value.deny })
$null = Invoke-KnowledgePolicy -BCQualityRoot $root -EnabledLayers @($ctx.settings.BCQuality.enabledLayers) -Allow $allow -Deny $deny
$commit = (git -C $root rev-parse HEAD).Trim()
Write-Host "BCQuality v$version at $commit"
Set-PipelineVariable -Name BCQ_ROOT -Value $root
Set-PipelineVariable -Name BCQ_COMMIT -Value $commit
