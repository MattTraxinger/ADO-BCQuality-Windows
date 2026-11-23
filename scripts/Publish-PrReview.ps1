#requires -Version 7.5
<#
.SYNOPSIS
    Posts the publish plan to the pull request. Holds PR write rights and no Copilot token.
.DESCRIPTION
    Posts nothing when the PR head moved since the review. Only fingerprints found on threads
    authored by our own identity are trusted for deduplication. Never reports partial or failed as clean.
    The SYSTEM_ACCESSTOKEN environment variable carries the build identity's token.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ContextPath,
    [string] $PlanPath,
    [Parameter(Mandatory)] [string] $CollectionUri,
    [Parameter(Mandatory)] [string] $Project,
    [Parameter(Mandatory)] [string] $RepositoryId,
    [Parameter(Mandatory)] [int] $PullRequestId,
    [string] $RunUrl
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'AzureDevOps.ps1')
. (Join-Path $PSScriptRoot 'FindingDeduplication.ps1')
. (Join-Path $PSScriptRoot 'PublishPlan.ps1')

if (-not (Test-Path -LiteralPath $ContextPath)) {
    Write-Host '##vso[task.logissue type=warning]No context artifact; the Context job did not finish. Nothing to publish.'
    return
}
$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -Depth 50
$ctx = New-AdoContext -CollectionUri $CollectionUri -Project $Project -RepositoryId $RepositoryId -PullRequestId $PullRequestId -Token $env:SYSTEM_ACCESSTOKEN

# Build the plan: the review's plan, a skipped plan, or a failed plan when the review left no result.
if ($PlanPath -and (Test-Path -LiteralPath $PlanPath)) { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json -Depth 50 }
else {
    $outcome = if ($context.skipped) { 'skipped' } else { 'failed' }
    $reason = if ($context.skipped) { $context.skipReason } else { 'The review stage produced no result; see the pipeline run.' }
    $mode = if ($context.settings) { $context.settings.mode } else { 'advisory' }
    $plan = [pscustomobject]@{
        reviewedHeadSha = $context.headSha; outcome = $outcome; mode = $mode
        statusState = if ($mode -eq 'status') { Get-StatusState -Outcome $outcome -Findings @() } else { $null }
        summary = [pscustomobject]@{
            fingerprint = Get-SummaryFingerprint -HeadSha $context.headSha -Outcome $outcome -Reason $reason -Counts $null -BCQualityCommit ''
            content = New-SummaryContent -Outcome $outcome -Reason $reason -Counts $null -Domains @() -RunUrl $RunUrl -HeadSha $context.headSha
            threadStatus = Get-SummaryThreadStatus -Outcome $outcome -Counts $null }
        items = @()
    }
}

if (-not (Assert-PrHeadUnchanged -ReviewedSha $plan.reviewedHeadSha -GetCurrentHead { (Get-AdoPullRequest $ctx).lastMergeSourceCommit.commitId })) {
    Write-Host "PR head moved since the review of $($plan.reviewedHeadSha). Posting nothing; rerun the policy."
    return
}

$me = Get-AdoAuthenticatedUserId $ctx
$threads = Get-AdoThreads $ctx
$known = Get-ExistingFingerprints -Threads $threads -TrustedAuthorId $me
# Earlier threads only: threads posted in this run never suppress each other.
$existingLocations = Get-ExistingThreadLocations -Threads $threads -TrustedAuthorId $me
$tolerance = [int](Get-OptionalProperty $plan 'nearDuplicateLines' 0)
$posted = 0; $nearDuplicates = 0
foreach ($item in @($plan.items)) {
    if ($known.Contains($item.fingerprint)) { continue }
    # Same rule, same file, within a couple of lines of a thread we already posted: the code around a finding was
    # edited, which changed its fingerprint, but it is the same issue. Do not post it again.
    $rule = [string](Get-OptionalProperty $item 'rule' '')
    if (Test-NearDuplicateThread -Existing $existingLocations -Path $item.filePath -Line ([int]$item.line) -Rule $rule -Tolerance $tolerance) {
        Write-Host "Skipping near-duplicate of an earlier thread: $($item.filePath):$($item.line) ($rule)"
        $nearDuplicates++; continue
    }
    # A suggestion thread covers the lines it replaces (endLine/endOffset); other threads keep the single-line anchor.
    $body = New-AdoThreadBody -Content $item.content -Fingerprint $item.fingerprint -FilePath $item.filePath -Line $item.line -Rule $rule `
        -EndLine ([int](Get-OptionalProperty $item 'endLine' 0)) -EndOffset ([int](Get-OptionalProperty $item 'endOffset' 0))
    $null = Add-AdoThread $ctx $body; $posted++
}
$summaryNote = 'summary already posted'
if (-not $known.Contains($plan.summary.fingerprint)) {
    # A plan written before threadStatus existed has none: post it active, as before.
    $summaryStatus = [string](Get-OptionalProperty $plan.summary 'threadStatus' 'active')
    $null = Add-AdoThread $ctx (New-AdoThreadBody -Content $plan.summary.content -Fingerprint $plan.summary.fingerprint -Kind 'summary' -Status $summaryStatus); $posted++
    $summaryNote = "summary thread=$summaryStatus"
}
if ($plan.mode -eq 'status' -and $plan.statusState) {
    Set-AdoPrStatus $ctx -State $plan.statusState -Description "BCQuality review: $($plan.outcome)" -TargetUrl $RunUrl
}
$prStatus = if ($plan.mode -eq 'status' -and $plan.statusState) { "; PR status=$($plan.statusState)" } else { '' }
Write-Host "Published $posted new thread(s)$(if ($nearDuplicates) { "; skipped $nearDuplicates near-duplicate(s)" }); $summaryNote$prStatus."
