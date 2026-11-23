#requires -Version 7.5
<#
.SYNOPSIS
    Validates PR metadata and eligibility, reads settings from a trusted source, resolves head SHA and merge base.
.DESCRIPTION
    Settings come from -SettingsFile (written by the calling pipeline) or, without it, from
    `git show origin/<target>:<path>`. Never from the PR head, so a PR cannot change the rules of the
    run that reviews it. Nothing from the PR is executed.
    Writes <OutDir>/context.json and sets pipeline output variables.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoDir,
    [Parameter(Mandatory)] [string] $OutDir,
    [Parameter(Mandatory)] [string] $TargetBranch,     # System.PullRequest.TargetBranch (refs/heads/main)
    [Parameter(Mandatory)] [string] $HeadSha,          # System.PullRequest.SourceCommitId
    [Parameter(Mandatory)] [string] $AuthorIdentity,   # unique name or email of the PR author
    [Parameter(Mandatory)] [string] $SchemaPath,
    [string] $SettingsPath = '.bcquality/settings.json',
    [string] $SettingsFile,                            # pipeline-written settings file; when given, nothing is read from git
    [bool] $IsDraft = $false,
    [string] $DefaultBCQualityVersion
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'BranchPatterns.ps1')

function Invoke-Git { param([string[]] $GitArgs) $out = & git -C $RepoDir @GitArgs 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }; $out }

$target = $TargetBranch -replace '^refs/heads/', ''
$skipReason = $null
$settings = $null
if ($SettingsFile) {
    # A file the calling pipeline wrote itself, outside the PR tree (trusted: it never came from the PR).
    # A missing file is an error, not "use the defaults": the defaults mean the review is off.
    if (-not (Test-Path -LiteralPath $SettingsFile)) { $skipReason = "settings-invalid: settings file not found: $SettingsFile" }
    else { $settingsJson = Get-Content -LiteralPath $SettingsFile -Raw }
}
else {
    $settingsJson = & git -C $RepoDir show "origin/${target}:$SettingsPath" 2>$null
    if ($LASTEXITCODE -ne 0) { $settingsJson = $null }
}
if (-not $skipReason) {
    try { $settings = Read-Settings -Json ($settingsJson -join "`n") -SchemaPath $SchemaPath }
    catch { $skipReason = "settings-invalid: $($_.Exception.Message)" }
}

$mergeBase = (Invoke-Git @('merge-base', "origin/$target", $HeadSha) | Select-Object -First 1).Trim()
$changed = @(Invoke-Git @('diff', '--name-only', '--no-renames', $mergeBase, $HeadSha) |
    Where-Object { $_ -match '\.al$|(^|/)app\.json$' })

if ($settings) {
    if ($DefaultBCQualityVersion -and -not $settings.BCQuality.version) { $settings.BCQuality.version = $DefaultBCQualityVersion }
    # branches is a list of GitHub Actions style patterns (see BranchPatterns.ps1). A bad pattern is a settings error,
    # reported as such, rather than a review that silently never runs.
    $branchIncluded = $false; $branchError = $null
    if ($settings.CodeReviewAgent.enabled) {
        try { $branchIncluded = Test-ReviewTargetBranch -Branch $target -Patterns @($settings.CodeReviewAgent.branches) }
        catch { $branchError = $_.Exception.Message }
    }
    if (-not $settings.CodeReviewAgent.enabled) { $skipReason = 'review-disabled' }
    elseif ($branchError) { $skipReason = "settings-invalid: $branchError" }
    elseif (-not $branchIncluded) { $skipReason = "branch-not-enabled: $target" }
    elseif ($IsDraft) { $skipReason = 'draft-pr' }
    elseif ($AuthorIdentity -in @($settings.CodeReviewAgent.excludedAuthors)) { $skipReason = 'author-excluded' }
    elseif ($changed.Count -eq 0) { $skipReason = 'no-al-changes' }
    elseif ($changed.Count -gt $settings.maxChangedFiles) { $skipReason = "too-many-files: $($changed.Count) > $($settings.maxChangedFiles)" }
    elseif (-not $settings.BCQuality.version) { $skipReason = 'settings-invalid: BCQuality.version is not set' }
}

$context = [ordered]@{
    skipped      = [bool]$skipReason
    skipReason   = $skipReason
    targetBranch = $target
    headSha      = $HeadSha
    mergeBase    = $mergeBase
    changedFiles = $changed
    settings     = $settings
}
Write-Json -Object $context -Path (Join-Path $OutDir 'context.json')
Set-PipelineVariable -Name skip -Value ([string]([bool]$skipReason).ToString().ToLower()) -Output
Set-PipelineVariable -Name skipReason -Value ([string]$skipReason) -Output
# From the target branch's settings (schema-validated enum), so the Generate job maps only this provider's secret.
Set-PipelineVariable -Name provider -Value ([string]$(if ($settings) { $settings.CodeReviewAgent.provider } else { 'copilot' })) -Output
Write-Host "Context: skipped=$([bool]$skipReason) reason='$skipReason' head=$HeadSha base=$mergeBase files=$($changed.Count)"
