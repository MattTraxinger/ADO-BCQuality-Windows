# Fingerprints findings and filters out ones already posted by our own identity.
Set-StrictMode -Version Latest

$script:FingerprintProperty = 'BCQuality.Fingerprint'

function Get-NormalizedContext {
    # Whitespace-insensitive code context: the finding's line and its immediate neighbours.
    param([string[]] $SourceLines, [int] $Line)
    if (-not $SourceLines -or $Line -lt 1) { return '' }
    $from = [Math]::Max(1, $Line - 1)
    $to = [Math]::Min($SourceLines.Count, $Line + 1)
    (($from..$to | ForEach-Object { ($SourceLines[$_ - 1] -replace '\s+', ' ').Trim() }) -join "`n")
}

function Get-FindingFingerprint {
    param([string] $KnowledgeId, [string] $FilePath, [string] $Context)
    $text = "$KnowledgeId|$(($FilePath -replace '\\', '/').TrimStart('/'))|$Context"
    $hash = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-ExistingThreadLocations {
    # Where our earlier finding threads are anchored, for near-duplicate suppression. Only threads whose first comment
    # was written by $TrustedAuthorId and that recorded their rule (BCQuality.Rule) count; older threads carry no rule,
    # so they are never used to suppress anything. Deleted threads are ignored.
    param([object[]] $Threads, [Parameter(Mandatory)] [string] $TrustedAuthorId)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Threads) {
        if ((Get-OptionalProperty $t 'isDeleted' $false) -eq $true) { continue }
        $props = Get-OptionalProperty $t 'properties'
        if ($null -eq $props) { continue }
        $rule = Get-OptionalProperty $props 'BCQuality.Rule'
        $kind = Get-OptionalProperty $props 'BCQuality.Kind'
        if ($null -eq $rule -or ($kind -and [string](Get-OptionalProperty $kind '$value') -ne 'finding')) { continue }
        $first = @($t.comments) | Select-Object -First 1
        if ($null -eq $first -or $first.author.id -ne $TrustedAuthorId) { continue }
        $ctx = Get-OptionalProperty $t 'threadContext'
        $start = Get-OptionalProperty $ctx 'rightFileStart'
        $path = [string](Get-OptionalProperty $ctx 'filePath' '')
        if (-not $path -or $null -eq $start) { continue }
        $out.Add([pscustomobject]@{ path = ($path -replace '\\', '/').TrimStart('/'); line = [int](Get-OptionalProperty $start 'line' 0); rule = [string](Get-OptionalProperty $rule '$value') })
    }
    , $out
}

function Test-NearDuplicateThread {
    # True when an earlier thread for the same rule is anchored in the same file within $Tolerance lines.
    # A tolerance of 0 turns the check off (exact repeats are caught by the fingerprint).
    param([object[]] $Existing, [string] $Path, [int] $Line, [string] $Rule, [int] $Tolerance = 2)
    if ($Tolerance -lt 1 -or -not $Rule) { return $false }
    $p = ($Path -replace '\\', '/').TrimStart('/')
    foreach ($e in @($Existing)) {
        if ($e.rule -ceq $Rule -and $e.path -ceq $p -and [Math]::Abs($e.line - $Line) -le $Tolerance) { return $true }
    }
    $false
}

function Get-ExistingFingerprints {
    # Reads fingerprints only from threads whose first comment was written by $TrustedAuthorId.
    param([object[]] $Threads, [Parameter(Mandatory)] [string] $TrustedAuthorId)
    $found = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in $Threads) {
        if (-not $t.PSObject.Properties['properties'] -or $null -eq $t.properties) { continue }
        $prop = $t.properties.PSObject.Properties[$script:FingerprintProperty]
        if (-not $prop) { continue }
        $first = @($t.comments) | Select-Object -First 1
        if ($null -eq $first -or $first.author.id -ne $TrustedAuthorId) { continue }
        $null = $found.Add([string]$prop.Value.'$value')
    }
    , $found
}
