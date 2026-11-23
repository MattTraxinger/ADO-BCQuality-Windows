# Regional grouping: the same finding repeated in several regional copies of the same file becomes ONE comment on a
# primary copy that lists the others, instead of N identical comments (noise) or silently dropping the other copies
# (the author would never be told to fix them).
#
# Which paths are "regional copies" is a repository convention, so it is configured, not assumed. A layout is a path
# template with exactly one {region} and one {path}, for example `src/Apps/{region}/{path}`. Two files are copies of
# each other when they match the same layout with different regions and the same {path}. With no layouts configured
# (the default) nothing is grouped. AL-Go hard-codes Microsoft's own BCApps layout; that one is
# `src/Apps/{region}/{path}` plus `src/Layers/{region}/{path}`, primary W1.
#
# Only genuinely identical findings are merged: same layout, same relative path, same line, and the same rule,
# severity, message, confidence, domain and suggested code (the caller builds that as `identity`). Findings that
# differ in any of those stay separate. A cluster is merged only when it has at least two members, all in distinct
# regions; anything else is left alone. The primary is the configured primary region (default W1) if present,
# otherwise the first region alphabetically.
Set-StrictMode -Version Latest

function ConvertTo-RegionalLayout {
    # Template -> { template; regex }. Literal parts are matched case-insensitively and escaped.
    param([Parameter(Mandatory)] [string] $Template)
    $t = ($Template -replace '\\', '/').Trim().TrimStart('/')
    if (@([regex]::Matches($t, '\{region\}')).Count -ne 1 -or @([regex]::Matches($t, '\{path\}')).Count -ne 1) {
        throw "Regional layout '$Template' must contain {region} and {path} exactly once."
    }
    if (@($t.Split('/') | Where-Object { $_ -eq '..' }).Count) { throw "Regional layout '$Template' must not contain '..'." }
    $rx = [System.Text.StringBuilder]::new('^')
    foreach ($part in [regex]::Split($t, '(\{region\}|\{path\})')) {
        if ($part -eq '{region}') { [void]$rx.Append('(?<region>[^/]+)') }
        elseif ($part -eq '{path}') { [void]$rx.Append('(?<path>.+)') }
        elseif ($part) { [void]$rx.Append([regex]::Escape($part)) }
    }
    [void]$rx.Append('$')
    [pscustomobject]@{ template = $t; regex = [regex]::new($rx.ToString(), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
}

function Get-RegionalPathInfo {
    # { layout; region; relative; path } for a file that matches a layout, otherwise $null.
    param([string] $FilePath, [object[]] $Layouts)
    $p = (([string]$FilePath) -replace '\\', '/').TrimStart('/')
    foreach ($l in @($Layouts)) {
        $m = $l.regex.Match($p)
        if ($m.Success) { return [pscustomobject]@{ layout = $l.template; region = $m.Groups['region'].Value; relative = $m.Groups['path'].Value; path = $p } }
    }
    $null
}

function Format-OtherRegionsNotice {
    param([object[]] $OtherRegions)
    if (-not @($OtherRegions).Count) { return '' }
    $lines = @('**The same issue exists in these regional copies; apply the equivalent fix in each:**')
    foreach ($o in @($OtherRegions)) { $lines += ('- `{0}:{1}` ({2})' -f $o.path, $o.line, $o.region) }
    $lines -join "`n"
}

function Group-RegionalItems {
    # Items are the plan's inline thread items (ordered hashtables) plus `identity`. Returns { items; groups; merged }.
    # Every item keeps its place; merged copies are dropped and the primary gains `otherRegions` and a notice.
    param([object[]] $Items, [object[]] $Layouts, [string] $Primary = 'W1')
    $items = @($Items)
    if (-not @($Layouts).Count -or $items.Count -lt 2) { return [pscustomobject]@{ items = $items; groups = 0; merged = 0 } }
    $clusters = [ordered]@{}
    for ($i = 0; $i -lt $items.Count; $i++) {
        $info = Get-RegionalPathInfo -FilePath $items[$i].filePath -Layouts $Layouts
        if ($null -eq $info -or [string]::IsNullOrWhiteSpace([string]$items[$i].identity)) { continue }
        $key = ConvertTo-Json -InputObject @($info.layout, $info.relative, [int]$items[$i].line, $items[$i].identity) -Compress
        if (-not $clusters.Contains($key)) { $clusters[$key] = [System.Collections.Generic.List[object]]::new() }
        $clusters[$key].Add([pscustomobject]@{ index = $i; info = $info })
    }
    $drop = [System.Collections.Generic.HashSet[int]]::new()
    $groups = 0
    foreach ($members in $clusters.Values) {
        $regions = @($members | ForEach-Object { $_.info.region.ToUpperInvariant() } | Select-Object -Unique)
        if ($members.Count -lt 2 -or $regions.Count -ne $members.Count) { continue }
        $ordered = @($members | Sort-Object { $_.info.region.ToUpperInvariant() }, { $_.info.path })
        # Not `$primary`: variable names are case-insensitive, so that would overwrite the typed $Primary parameter.
        $chosen = @($ordered | Where-Object { $_.info.region -ieq $Primary }) | Select-Object -First 1
        if (-not $chosen) { $chosen = $ordered[0] }
        $others = @($ordered | Where-Object { $_.index -ne $chosen.index } | ForEach-Object {
                [ordered]@{ path = $_.info.path; line = [int]$items[$_.index].line; region = $_.info.region.ToUpperInvariant() } })
        $item = $items[$chosen.index]
        $item.otherRegions = $others
        $item.content = "$($item.content)`n`n$(Format-OtherRegionsNotice -OtherRegions $others)"
        foreach ($m in $ordered) { if ($m.index -ne $chosen.index) { [void]$drop.Add($m.index) } }
        $groups++
    }
    $kept = @(for ($i = 0; $i -lt $items.Count; $i++) { if (-not $drop.Contains($i)) { $items[$i] } })
    [pscustomobject]@{ items = $kept; groups = $groups; merged = $drop.Count }
}
