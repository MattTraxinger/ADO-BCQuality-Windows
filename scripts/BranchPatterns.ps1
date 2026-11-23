# Which pull request target branches get a review: CodeReviewAgent.branches as an ordered list of branch patterns, in
# the syntax GitHub Actions uses for `branches:` filters (the same one AL-Go uses), matched against the target branch's
# short name (`main`, not `refs/heads/main`).
#
#   *          any characters except `/`          release/*     matches release/1.0, not release/1.0/hotfix
#   **         any characters including `/`       release/**    matches both;  `**/` also matches no directory at all
#   ?  +       repeat the PREVIOUS character: `?` zero or one, `+` one or more. They are not wildcards:
#              v1?  matches v and v1;  v[0-9]+  matches v1 and v123
#   [abc] [0-9] a character class, letters, digits and `-` only
#   \          the next character literally, so `\+` or `\*` match a real + or *
#   !          a leading `!` excludes. Patterns are evaluated in order and the LAST one that matches decides, so
#              ["release/**", "!release/legacy/**"] reviews release/2.0 but not release/legacy/1.0, and the reverse order
#              reviews both.
#
# Everything else is literal and matching is case-sensitive. A list must hold at least one pattern that is not an
# exclusion: a list of only exclusions can never match, which is a mistake, so it is rejected instead of silently
# never reviewing anything. An invalid pattern is rejected the same way (the caller reports `settings-invalid`).
# A branch name that really contains `+` (Git allows it) must be written `\+`. `?`, `*`, `[` and `\` cannot appear in
# a Git branch name, so existing exact names keep matching.
# Matching uses .NET's non-backtracking regex engine, so the time taken is linear in the branch name however many `*`
# a pattern has (a backtracking engine takes polynomial time on something like `a*a*a*a*a*c`); a timeout remains as a
# last resort.
Set-StrictMode -Version Latest

$script:BranchPatternOptions = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::NonBacktracking

function ConvertTo-BranchPatternRegex {
    # One pattern WITHOUT its leading `!` -> an anchored regular expression. Throws on anything invalid.
    param([Parameter(Mandatory)] [string] $Glob, [string] $Original = $Glob)
    $rx = [System.Text.StringBuilder]::new('\A')
    $canQuantify = $false
    for ($i = 0; $i -lt $Glob.Length; $i++) {
        $c = $Glob[$i]
        switch -CaseSensitive ($c) {
            '\' {
                $i++
                if ($i -ge $Glob.Length) { throw "Branch pattern '$Original' ends with a backslash." }
                [void]$rx.Append([regex]::Escape([string]$Glob[$i])); $canQuantify = $true
            }
            '*' {
                if ($i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
                    $i++
                    if ($i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '/') { [void]$rx.Append('(?:.*/)?'); $i++ }
                    else { [void]$rx.Append('.*') }
                }
                else { [void]$rx.Append('[^/]*') }
                $canQuantify = $false
            }
            '[' {
                $end = $Glob.IndexOf(']', $i + 1)
                if ($end -lt 0 -or $Glob.Substring($i + 1, $end - $i - 1) -cnotmatch '\A[A-Za-z0-9-]+\z') {
                    throw "Branch pattern '$Original' has an invalid character class; use letters, digits and - between [ and ]."
                }
                [void]$rx.Append($Glob.Substring($i, $end - $i + 1)); $i = $end; $canQuantify = $true
            }
            { $_ -eq '?' -or $_ -eq '+' } {
                if (-not $canQuantify) { throw "Branch pattern '$Original' has a '$c' with no character before it to repeat." }
                [void]$rx.Append($c); $canQuantify = $false
            }
            default { [void]$rx.Append([regex]::Escape([string]$c)); $canQuantify = $true }
        }
    }
    [void]$rx.Append('\z')
    $rx.ToString()
}

function Assert-BranchPatterns {
    # Throws for a pattern that is empty, has stray whitespace at either end, is invalid, or for a list that has no
    # pattern other than exclusions. No patterns at all is valid and means the default, `main`.
    param([string[]] $Patterns)
    $list = @($Patterns | Where-Object { $null -ne $_ })
    if (-not $list.Count) { return }
    $positive = 0
    foreach ($p in $list) {
        if ($p -ne $p.Trim()) { throw "Branch pattern '$p' must not start or end with whitespace." }
        $exclude = $p.StartsWith('!')
        $glob = if ($exclude) { $p.Substring(1) } else { $p }
        if (-not $exclude) { $positive++ }
        if (-not $glob) { throw "Branch pattern '$p' is empty after the '!'." }
        $null = ConvertTo-BranchPatternRegex -Glob $glob -Original $p
    }
    if (-not $positive) { throw "CodeReviewAgent.branches has only exclusions ($($list -join ', ')), so no branch can ever match. Add a pattern that is not an exclusion." }
}

function Test-ReviewTargetBranch {
    # True when the branch is included by the patterns: evaluated in order, the last pattern that matches decides.
    param([Parameter(Mandatory)] [string] $Branch, [string[]] $Patterns)
    $list = @($Patterns | Where-Object { $null -ne $_ })
    if (-not $list.Count) { $list = @('main') }
    Assert-BranchPatterns -Patterns $list
    $included = $false
    foreach ($p in $list) {
        $exclude = $p.StartsWith('!')
        $regex = ConvertTo-BranchPatternRegex -Glob $(if ($exclude) { $p.Substring(1) } else { $p }) -Original $p
        if ([regex]::IsMatch($Branch, $regex, $script:BranchPatternOptions, [TimeSpan]::FromSeconds(1))) { $included = -not $exclude }
    }
    $included
}
