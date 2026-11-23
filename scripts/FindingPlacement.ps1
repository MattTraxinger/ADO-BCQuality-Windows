# Maps findings onto the right-hand (new file) side of a unified diff.
Set-StrictMode -Version Latest

function Get-DiffRightRanges {
    # Returns @{ start; end } ranges of new-file lines present in the diff, one per hunk.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $DiffText)
    $ranges = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($DiffText, '(?m)^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')) {
        $start = [int]$m.Groups[1].Value
        $count = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 1 }
        if ($count -gt 0) { $ranges.Add([pscustomobject]@{ start = $start; end = $start + $count - 1 }) }
    }
    , $ranges.ToArray()
}

function Test-LineInRanges {
    param([int] $Line, [object[]] $Ranges)
    foreach ($r in $Ranges) { if ($Line -ge $r.start -and $Line -le $r.end) { return $true } }
    $false
}

function Get-FindingPlacement {
    # 'inline' when the finding's file and line are inside the diff; otherwise 'summary'.
    # Nothing is dropped: a finding with no location or outside the diff lands in the summary.
    param([Parameter(Mandatory)] $Finding, [Parameter(Mandatory)] [hashtable] $DiffRangesByFile)
    $loc = if ($Finding.PSObject.Properties['location']) { $Finding.location } else { $null }
    if ($null -eq $loc -or -not $loc.PSObject.Properties['file'] -or -not $loc.PSObject.Properties['line']) {
        return [pscustomobject]@{ kind = 'summary'; reason = 'no-location' }
    }
    $file = ($loc.file -replace '\\', '/').TrimStart('/')
    if (-not $DiffRangesByFile.ContainsKey($file)) {
        return [pscustomobject]@{ kind = 'summary'; reason = 'file-not-in-diff' }
    }
    if (Test-LineInRanges -Line ([int]$loc.line) -Ranges $DiffRangesByFile[$file]) {
        return [pscustomobject]@{ kind = 'inline'; reason = $null }
    }
    [pscustomobject]@{ kind = 'summary'; reason = 'line-outside-diff' }
}
