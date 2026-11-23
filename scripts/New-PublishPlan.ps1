#requires -Version 7.5
<#
.SYNOPSIS
    Builds publish-plan.json from the accepted reports. Runs in the Review stage; Publish only posts the plan.
.DESCRIPTION
    Placement and fingerprints are computed here, against the reviewed head, so the Publish stage needs
    no checkout of PR code and no Copilot token.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResultPath,
    [Parameter(Mandatory)] [string] $ContextPath,
    [Parameter(Mandatory)] [string] $RepoDir,
    [Parameter(Mandatory)] [string] $BCQualityCommit,
    [Parameter(Mandatory)] [string] $OutPath,
    [string] $RunUrl
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'FindingPlacement.ps1')
. (Join-Path $PSScriptRoot 'SuggestionPlacement.ps1')
. (Join-Path $PSScriptRoot 'RegionalGrouping.ps1')
. (Join-Path $PSScriptRoot 'FindingDeduplication.ps1')
. (Join-Path $PSScriptRoot 'PublishPlan.ps1')
. (Join-Path $PSScriptRoot 'BCQualityRepo.ps1')

$result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json -Depth 100
$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json -Depth 50
$head = $result.reviewedHeadSha
$knowledgeBase = Get-KnowledgeBaseUrl -Repo $context.settings.BCQuality.repo -Commit $BCQualityCommit

$items = [System.Collections.Generic.List[object]]::new()
$summaryFindings = [System.Collections.Generic.List[object]]::new()
$allFindings = [System.Collections.Generic.List[object]]::new()
$domains = [System.Collections.Generic.SortedSet[string]]::new()
$failedDomains = [System.Collections.Generic.SortedSet[string]]::new()
$suggestionSetting = Get-OptionalProperty $context.settings.CodeReviewAgent 'suggestions' 'apply'
$suggestionStats = [ordered]@{ apply = 0; manual = 0; none = 0 }
$suggestionReasons = @{}
# Regional copies are a repository convention, so the layouts are configured; none configured means no grouping.
$regionalSettings = Get-OptionalProperty $context.settings.CodeReviewAgent 'regional'
$regionalLayouts = @(foreach ($t in @(Get-OptionalProperty $regionalSettings 'layouts' @())) { ConvertTo-RegionalLayout -Template $t })
$regionalPrimary = [string](Get-OptionalProperty $regionalSettings 'primary' 'W1')
$nearDuplicateLines = [int](Get-OptionalProperty $context.settings.CodeReviewAgent 'nearDuplicateLines' 2)

foreach ($app in $result.apps) {
    $report = Get-Content -LiteralPath $app.reportPath -Raw | ConvertFrom-Json -Depth 100
    foreach ($leaf in @($report.PSObject.Properties['sub-results'] ? $report.'sub-results' : @())) {
        if ($leaf.outcome -eq 'failed') { $null = $failedDomains.Add($leaf.skill.id) } else { $null = $domains.Add($leaf.skill.id) }
    }
    $ranges = @{}
    $addedByFile = @{}
    foreach ($file in $app.files) {
        $diffFile = Join-Path $app.diffDir "diff/$file.diff"
        $diffText = Get-Content -LiteralPath $diffFile -Raw
        $ranges[$file] = Get-DiffRightRanges -DiffText $diffText
        $addedByFile[$file] = Get-DiffAddedLines -DiffText $diffText
    }
    foreach ($f in @($report.findings)) {
        $allFindings.Add($f)
        $placement = Get-FindingPlacement -Finding $f -DiffRangesByFile $ranges
        if ($placement.kind -eq 'inline') {
            $source = @(& git -C $RepoDir show "${head}:$($f.location.file)")
            $fp = Get-FindingFingerprint -KnowledgeId $f.id -FilePath $f.location.file -Context (Get-NormalizedContext -SourceLines $source -Line $f.location.line)
            # The suggestion's span must lie entirely on lines this PR added; otherwise it is only shown as a manual snippet.
            $sp = Get-SuggestionPlan -Finding $f -FileLines $source -AddedLines $addedByFile[($f.location.file -replace '\\', '/').TrimStart('/')] -Setting $suggestionSetting
            $content = New-FindingContent -Finding $f -KnowledgeBaseUrl $knowledgeBase -SuggestionMarkdown (New-SuggestionMarkdown -Plan $sp)
            # `identity` decides whether two findings in regional copies are the same finding; `_mode`/`_reason` carry
            # the suggestion outcome to the counts below. All three are removed before the plan is written.
            $clean = { param($v) ([string]$v).Replace("`r`n", "`n").Trim() }
            $identity = ConvertTo-Json -Compress -InputObject @($f.id, $f.severity, (& $clean $f.message), (Get-OptionalProperty $f 'confidence' ''),
                (Get-OptionalProperty $f 'domain' ''), (& $clean (Get-OptionalProperty $f 'suggested-code' '')))
            $item = [ordered]@{ fingerprint = $fp; filePath = $f.location.file; line = [int]$f.location.line; rule = [string]$f.id; content = $content
                identity = $identity; _mode = $sp.mode; _reason = $sp.reason }
            if ($sp.mode -eq 'apply') {
                # Anchor the thread over exactly the lines the suggestion replaces; offsets cover whole lines.
                $item.line = $sp.startLine; $item.endLine = $sp.endLine
                $item.endOffset = [Math]::Max(2, ([string]$source[$sp.endLine - 1]).TrimEnd("`r").Length + 1)
            }
            $items.Add($item)
        }
        else {
            $where = if ($placement.reason -eq 'no-location') { 'no location' } else { "$($f.location.file):$($f.location.line)" }
            $summaryFindings.Add([pscustomobject]@{ location = $where; severity = $f.severity; message = $f.message })
        }
    }
}

# Collapse identical findings in regional copies into one thread, then count what is actually going to be posted.
$grouped = Group-RegionalItems -Items @($items) -Layouts $regionalLayouts -Primary $regionalPrimary
$items = [System.Collections.Generic.List[object]]::new()
foreach ($it in $grouped.items) {
    $suggestionStats[$it._mode]++
    if ($it._mode -ne 'apply' -and $it._reason -ne 'no-suggestion') { $suggestionReasons["$($it._mode):$($it._reason)"] = 1 + [int]$suggestionReasons["$($it._mode):$($it._reason)"] }
    foreach ($k in 'identity', '_mode', '_reason') { $it.Remove($k) }
    $items.Add($it)
}

$outcome = $result.outcome
$reason = ($result.apps | Where-Object { $_.outcomeReason } | ForEach-Object { $_.outcomeReason }) -join ' | '
$counts = Get-SeverityCounts -Findings @($allFindings)
$summary = [ordered]@{
    fingerprint = Get-SummaryFingerprint -HeadSha $head -Outcome $outcome -Reason $reason -Counts $counts -BCQualityCommit $BCQualityCommit
    content     = New-SummaryContent -Outcome $outcome -Reason $reason -Counts $counts -Domains @($domains) -FailedDomains @($failedDomains) -BCQualityVersion $context.settings.BCQuality.version `
        -BCQualityCommit $BCQualityCommit -RunUrl $RunUrl -SummaryFindings @($summaryFindings) -HeadSha $head
    threadStatus = Get-SummaryThreadStatus -Outcome $outcome -Counts $counts
}
$state = if ($result.mode -eq 'status') { Get-StatusState -Outcome $outcome -Findings @($allFindings) } else { $null }

Write-Json -Path $OutPath -Object ([ordered]@{
        reviewedHeadSha = $head; outcome = $outcome; mode = $result.mode; statusState = $state
        summary = $summary; items = @($items); nearDuplicateLines = $nearDuplicateLines
        regional = [ordered]@{ layouts = @($regionalLayouts | ForEach-Object { $_.template }); primary = $regionalPrimary; groups = $grouped.groups; merged = $grouped.merged }
        suggestions = [ordered]@{ setting = $suggestionSetting; oneClick = $suggestionStats.apply; manual = $suggestionStats.manual; none = $suggestionStats.none
            reasons = $suggestionReasons } })
# The PR status is set only in status mode; in advisory mode the summary thread status is all there is to report.
Write-Host "Publish plan: $($items.Count) inline thread(s), $($summaryFindings.Count) in summary, summary thread=$($summary.threadStatus)$(if ($state) { ", PR status=$state" })"
if ($regionalLayouts.Count) { Write-Host "Regional grouping: $($grouped.groups) group(s), $($grouped.merged) regional copy(ies) merged into another thread." }
Write-Host "Suggestions ($suggestionSetting): $($suggestionStats.apply) one-click, $($suggestionStats.manual) manual, $($suggestionStats.none) none$(if ($suggestionReasons.Count) { ' [' + (($suggestionReasons.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ') + ']' })"
