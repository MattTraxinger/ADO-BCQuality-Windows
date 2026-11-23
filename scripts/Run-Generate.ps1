#requires -Version 7.5
<#
.SYNOPSIS
    The Generate job's review step: diff, review, validate, plan. Moved out of the template YAML so one script
    serves every provider; the template only chooses which provider's secret is mapped into the step.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ContextPath,
    [Parameter(Mandatory)] [string] $ToolsDir,        # <tools checkout>/scripts
    [Parameter(Mandatory)] [string] $RepoDir,
    [Parameter(Mandatory)] [string] $OutDir,
    [Parameter(Mandatory)] [string] $BCQualityRoot,
    [Parameter(Mandatory)] [string] $BCQualityCommit,
    [string] $AgentVersion = 'unknown',
    [string] $RunUrl
)

$ErrorActionPreference = 'Stop'
$ctx = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -Depth 50

& "$ToolsDir/Get-PrDiff.ps1" -RepoDir $RepoDir -MergeBase $ctx.mergeBase -HeadSha $ctx.headSha `
    -OutDir "$OutDir/diff" -AppFolders @($ctx.settings.appFolders)
& "$ToolsDir/Invoke-BCQualityReview.ps1" -ContextPath $ContextPath -AppsPath "$OutDir/diff/apps.json" `
    -RepoDir $RepoDir -BCQualityRoot $BCQualityRoot -BCQualityCommit $BCQualityCommit `
    -OutDir $OutDir -AgentVersion $AgentVersion
& "$ToolsDir/New-PublishPlan.ps1" -ResultPath "$OutDir/result.json" -ContextPath $ContextPath -RepoDir $RepoDir `
    -BCQualityCommit $BCQualityCommit -OutPath "$OutDir/publish-plan.json" -RunUrl $RunUrl
