# Suggested changes: turns a finding's `suggested-code` into either a one-click suggestion block or a labelled
# manual snippet, and checks that applying it can only touch lines that this PR changed.
#
# BCQuality's contract (skills/do.md): `suggested-code` is a literal replacement for the source lines covered by
# `location.line`, or by `location.range` when it is set. Azure Repos replaces the line(s) a suggestion thread is
# anchored to when the author chooses Apply changes, so the thread must be anchored over exactly that span.
#
# The span check is the safety property: every line the suggestion would replace must be a line the PR added or
# changed (a `+` line in the diff), within the file, and the span must be small. Anything else is never offered as a
# one-click change. It is shown as a manual snippet so the advice is not lost, with the reason.
# This code does not re-derive a span when the model's anchor looks wrong (AL-Go's reorder/insertion matching); a
# suggestion whose declared span fails a check falls back to a manual snippet instead of being moved.
#
# Checked on a live Azure Repos PR: a thread posted with the fence tag below shows as a suggestion and "Apply
# changes" works. Microsoft documents the feature (a light bulb inserts a fenced block) but not the tag, so if a
# future Azure DevOps change shows a raw code block instead of an "Apply changes" button, change it here.
Set-StrictMode -Version Latest

$script:SuggestionFenceTag = 'suggestion'
$script:MaxSuggestionSpanLines = 25

function Get-DiffAddedLines {
    # New-file line numbers of the lines a unified diff adds (`+` lines), as a HashSet[int]. Lines before the first
    # hunk (diff --git, ---, +++) are headers, not content.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $DiffText)
    $added = [System.Collections.Generic.HashSet[int]]::new()
    $inHunk = $false; $new = 0
    foreach ($raw in ($DiffText -split "`r?`n")) {
        if ($raw -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@') { $inHunk = $true; $new = [int]$Matches[1]; continue }
        if (-not $inHunk) { continue }
        if ($raw.StartsWith('+')) { [void]$added.Add($new); $new++ }
        elseif ($raw.StartsWith('-') -or $raw.StartsWith('\')) { }   # deleted line, or "\ No newline at end of file"
        else { $new++ }                                              # context line
    }
    , $added
}

function Resolve-SuggestionSpan {
    # The declared span (location.range, else location.line) and whether it passes every check. Returns
    # { ok; startLine; endLine; reason }; reason names the first failed check.
    # [AllowEmptyString()] is needed as well as [AllowEmptyCollection()]: a mandatory [string[]] rejects an empty string
    # inside the array, and a source file has blank lines.
    param([Parameter(Mandatory)] $Finding, [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $FileLines, [Parameter(Mandatory)] $AddedLines)
    $loc = $Finding.location
    $line = [int]$loc.line; $start = $line; $end = $line
    $range = Get-OptionalProperty $loc 'range'
    if ($range) {
        $start = [int]$range.'start-line'; $end = [int]$range.'end-line'
        if ($start -gt $end -or $line -lt $start -or $line -gt $end) { return [pscustomobject]@{ ok = $false; startLine = $null; endLine = $null; reason = 'range-excludes-line' } }
    }
    $fail = { param($r) [pscustomobject]@{ ok = $false; startLine = $start; endLine = $end; reason = $r } }
    if ($start -lt 1 -or $end -gt @($FileLines).Count) { return & $fail 'span-outside-file' }
    if (($end - $start + 1) -gt $script:MaxSuggestionSpanLines) { return & $fail 'span-too-large' }
    for ($l = $start; $l -le $end; $l++) { if (-not $AddedLines.Contains($l)) { return & $fail 'span-outside-diff' } }
    [pscustomobject]@{ ok = $true; startLine = $start; endLine = $end; reason = $null }
}

function Get-SuggestionPlan {
    # mode: 'apply'  one-click block, thread anchored over [startLine, endLine]
    #       'manual' labelled snippet, thread stays at the finding's line (check failed, or turned off per setting)
    #       'none'   nothing to show (no suggestion, setting off, or it is identical to the source)
    param([Parameter(Mandatory)] $Finding, [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $FileLines, [Parameter(Mandatory)] $AddedLines,
          [ValidateSet('apply', 'manual', 'off')] [string] $Setting = 'apply')
    $none = { param($r) [pscustomobject]@{ mode = 'none'; reason = $r; startLine = $null; endLine = $null; code = '' } }
    $raw = [string](Get-OptionalProperty $Finding 'suggested-code' '')
    if (-not $raw.Trim()) { return & $none 'no-suggestion' }
    if ($Setting -eq 'off') { return & $none 'disabled' }
    $code = ($raw -replace "`r`n?", "`n").TrimEnd("`n")
    $span = Resolve-SuggestionSpan -Finding $Finding -FileLines $FileLines -AddedLines $AddedLines
    if ($span.ok) {
        $original = @($FileLines[($span.startLine - 1)..($span.endLine - 1)] | ForEach-Object { $_.TrimEnd() })
        $proposed = @($code -split "`n" | ForEach-Object { $_.TrimEnd() })
        if ($original.Count -eq $proposed.Count -and -not @(0..($original.Count - 1) | Where-Object { $original[$_] -cne $proposed[$_] }).Count) {
            return & $none 'identical-to-source'
        }
    }
    if (-not $span.ok) { return [pscustomobject]@{ mode = 'manual'; reason = $span.reason; startLine = $null; endLine = $null; code = $code } }
    if ($Setting -eq 'manual') { return [pscustomobject]@{ mode = 'manual'; reason = 'configured'; startLine = $null; endLine = $null; code = $code } }
    [pscustomobject]@{ mode = 'apply'; reason = $null; startLine = $span.startLine; endLine = $span.endLine; code = $code }
}

function Get-SuggestionReasonText {
    param([string] $Reason)
    switch ($Reason) {
        'configured' { 'one-click suggestions are turned off for this repository' }
        'span-outside-diff' { 'it would replace lines this pull request did not change' }
        'span-outside-file' { 'the lines it targets are outside the file' }
        'span-too-large' { 'it targets too many lines for a safe one-click change' }
        'range-excludes-line' { 'the finding reports an inconsistent line range' }
        default { 'it could not be anchored to the changed lines' }
    }
}

function New-SuggestionMarkdown {
    # The fence is one backtick longer than the longest backtick run in the code, so the code cannot close it.
    param([Parameter(Mandatory)] $Plan)
    if ($Plan.mode -eq 'none') { return '' }
    $longest = [int](([regex]::Matches($Plan.code, '`+') | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
    $fence = '`' * [Math]::Max(3, $longest + 1)
    if ($Plan.mode -eq 'apply') { return "$fence$($script:SuggestionFenceTag)`n$($Plan.code)`n$fence" }
    "**Suggested fix** (apply manually: $(Get-SuggestionReasonText $Plan.reason)):`n${fence}al`n$($Plan.code)`n$fence"
}
