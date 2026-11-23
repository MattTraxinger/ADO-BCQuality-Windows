# Pure functions that turn accepted reports into a publish plan (threads, summary, status).
Set-StrictMode -Version Latest

function Get-SeverityCounts {
    param([object[]] $Findings)
    $c = [ordered]@{ blocker = 0; major = 0; minor = 0; info = 0 }
    foreach ($f in $Findings) { $c[$f.severity]++ }
    $c
}

function Get-SeverityBadge {
    # A coloured marker for BCQuality's severities (blocker, major, minor, info). Anything else gets a neutral marker.
    # Built from code points so this file stays plain ASCII whatever encoding an editor or git applies to it.
    param([string] $Severity)
    $codePoint = switch ($Severity) {
        'blocker' { 0x1F534 }   # red circle
        'major' { 0x1F7E0 }     # orange circle
        'minor' { 0x1F7E1 }     # yellow circle
        'info' { 0x1F535 }      # blue circle
        default { 0x26AA }      # white circle
    }
    [char]::ConvertFromUtf32($codePoint)
}

function Get-DistinctReferencePaths {
    # The knowledge articles a finding cites, in order, without repeats or blanks.
    param($Finding)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in @(Get-OptionalProperty $Finding 'references' @())) {
        $p = (([string](Get-OptionalProperty $r 'path' '')) -replace '\\', '/').Trim().TrimStart('/')
        if ($p -and $seen.Add($p)) { $p }
    }
}

function New-KnowledgeLink {
    # [path](base/path) with the characters that would end the link early escaped; plain code when there is no base URL.
    # A base URL containing {path} (an Azure DevOps ?path= link, see Get-KnowledgeBaseUrl) has the path put there instead.
    param([Parameter(Mandatory)] [string] $Path, [string] $KnowledgeBaseUrl)
    if (-not $KnowledgeBaseUrl) { return ('`{0}`' -f $Path) }
    $text = $Path.Replace('[', '\[').Replace(']', '\]')
    $escaped = $Path.Replace(' ', '%20').Replace('(', '%28').Replace(')', '%29')
    $url = if ($KnowledgeBaseUrl.Contains('{path}')) { $KnowledgeBaseUrl.Replace('{path}', $escaped.Replace('&', '%26').Replace('#', '%23')) }
    else { "$($KnowledgeBaseUrl.TrimEnd('/'))/$escaped" }
    "[$text]($url)"
}

function New-FindingContent {
    # Severity badge, severity, confidence, the message, an optional suggestion, and a link to every knowledge article
    # the finding cites. A finding with no reference is labeled advisory.
    param([Parameter(Mandatory)] $Finding, [string] $KnowledgeBaseUrl, [string] $SuggestionMarkdown)
    $paths = @(Get-DistinctReferencePaths -Finding $Finding)
    $confidence = Get-OptionalProperty $Finding 'confidence' 'unspecified'
    $severity = [string]$Finding.severity
    $lines = @("$(Get-SeverityBadge $severity) **$($severity.ToUpper())** · confidence: $confidence", '', $Finding.message)
    if ($SuggestionMarkdown) { $lines += ''; $lines += $SuggestionMarkdown }
    if ($paths.Count -eq 1) {
        $lines += ''; $lines += "Knowledge: $(New-KnowledgeLink -Path $paths[0] -KnowledgeBaseUrl $KnowledgeBaseUrl)"
    }
    elseif ($paths.Count -gt 1) {
        $lines += ''; $lines += 'Knowledge:'
        foreach ($p in $paths) { $lines += "- $(New-KnowledgeLink -Path $p -KnowledgeBaseUrl $KnowledgeBaseUrl)" }
    }
    else {
        $lines += ''; $lines += '_Advisory: agent finding without a BCQuality knowledge reference._'
    }
    $lines -join "`n"
}

function Get-StatusState {
    # status mode only. partial/failed never succeed; completed fails only on blocker findings (assumption, see README).
    param([string] $Outcome, [object[]] $Findings)
    switch ($Outcome) {
        'completed' { if (@($Findings | Where-Object severity -eq 'blocker').Count -gt 0) { 'failed' } else { 'succeeded' } }
        { $_ -in 'not-applicable', 'no-knowledge', 'skipped' } { 'notApplicable' }
        default { 'failed' }
    }
}

function Get-SummaryThreadStatus {
    # The summary thread is posted closed when it asks nothing of the author: a completed review with no findings, or
    # a review that did not apply (skipped, not-applicable, no-knowledge). An active thread holds the PR's
    # comment-resolution policy, so a clean summary would otherwise block completion until someone resolves it.
    # partial and failed stay active: they are not clean results and someone should look at them.
    param([string] $Outcome, $Counts)
    if ($Outcome -in 'not-applicable', 'no-knowledge', 'skipped') { return 'closed' }
    if ($Outcome -eq 'completed' -and $Counts -and ($Counts.blocker + $Counts.major + $Counts.minor + $Counts.info) -eq 0) { return 'closed' }
    'active'
}

function New-SummaryContent {
    param([string] $Outcome, [string] $Reason, $Counts, [string[]] $Domains, [string] $BCQualityVersion,
          [string] $BCQualityCommit, [string] $RunUrl, [object[]] $SummaryFindings = @(), [string] $HeadSha,
          [string[]] $FailedDomains = @())
    $first = switch ($Outcome) {
        'completed' { 'BCQuality review: completed.' }
        'partial' { 'BCQuality review: PARTIAL. Part of the review is missing, so this is not a clean result.' }
        'failed' { 'BCQuality review: FAILED. This is not a clean result.' }
        'skipped' { "BCQuality review: skipped ($Reason)." }
        default { "BCQuality review: $Outcome." }
    }
    $lines = @($first)
    if ($Reason -and $Outcome -notin 'skipped', 'completed') { $lines += "Reason: $Reason" }
    if ($Counts) { $lines += ''; $lines += "Findings: $($Counts.blocker) blocker, $($Counts.major) major, $($Counts.minor) minor, $($Counts.info) info." }
    if ($Domains.Count) { $lines += "Domains reviewed: $($Domains -join ', ')." }
    if ($FailedDomains.Count) { $lines += "Domains NOT reviewed (failed): $($FailedDomains -join ', ')." }
    if ($SummaryFindings.Count) {
        $lines += ''; $lines += 'Findings not anchored to a changed line:'
        foreach ($s in $SummaryFindings) { $lines += "- ``$($s.location)`` $(Get-SeverityBadge ([string]$s.severity)) [$($s.severity)] $($s.message)" }
    }
    if ($BCQualityVersion) { $lines += ''; $lines += "BCQuality $BCQualityVersion at commit ``$BCQualityCommit``. Reviewed head ``$HeadSha``." }
    if ($RunUrl) { $lines += "Pipeline run: $RunUrl" }
    $lines -join "`n"
}

function Get-SummaryFingerprint {
    # Excludes the run URL so a rerun on an unchanged PR produces the same fingerprint.
    param([string] $HeadSha, [string] $Outcome, [string] $Reason, $Counts, [string] $BCQualityCommit)
    $text = "summary|$HeadSha|$Outcome|$Reason|$($Counts | ConvertTo-Json -Compress)|$BCQualityCommit"
    ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))) -replace '-', '').ToLowerInvariant()
}
