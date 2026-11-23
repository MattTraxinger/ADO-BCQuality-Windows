# Knowledge policy for the pinned BCQuality clone: prune knowledge articles to the configured allow/deny globs,
# rebuild the knowledge index over what is left, and record exactly what was removed.
#
# Why the host prunes: BCQuality's index builder does not apply allow/deny rules, it only records them in the index
# header ("a consumer is expected to prune its clone to policy first"), and Entry's `enabled-layers` narrows
# discovery only. So a rule is only real if the files are gone from the clone before the index is built and before
# the agent can read them. Settings come from the target branch (Get-PrContext.ps1), never from the PR.
#
# Patterns are matched against the clone-relative path with forward slashes, for example
# `microsoft/knowledge/security/some-article.md`. `*` and `?` stay within one path segment, `**/` matches any number
# of segments (including none), `**` matches anything. Matching is case-sensitive. A pattern that matches nothing is
# not an error. Deny wins over allow. An empty allow list keeps everything the deny list does not remove.
Set-StrictMode -Version Latest

$script:KnowledgeLayers = @('microsoft', 'community', 'custom')

function ConvertTo-KnowledgeGlobRegex {
    param([Parameter(Mandatory)] [string] $Pattern)
    $p = ($Pattern -replace '\\', '/').Trim()
    $rx = [System.Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $p.Length; $i++) {
        $c = $p[$i]
        if ($c -eq '*' -and $i + 1 -lt $p.Length -and $p[$i + 1] -eq '*') {
            $i++
            if ($i + 1 -lt $p.Length -and $p[$i + 1] -eq '/') { [void]$rx.Append('(?:.*/)?'); $i++ }
            else { [void]$rx.Append('.*') }
        }
        elseif ($c -eq '*') { [void]$rx.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$rx.Append('[^/]') }
        else { [void]$rx.Append([regex]::Escape([string]$c)) }
    }
    [void]$rx.Append('$')
    $rx.ToString()
}

function Test-KnowledgeGlob {
    # True when the clone-relative path matches the glob.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Pattern)
    [regex]::IsMatch($Path, (ConvertTo-KnowledgeGlobRegex -Pattern $Pattern), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Assert-KnowledgePatterns {
    # Returns the normalized patterns (forward slashes); throws on anything that could point outside the clone.
    # No patterns at all ($null or empty) is valid and means "no rule"; an empty string inside a list is an error.
    param([AllowNull()] [string[]] $Patterns, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Patterns) { return }
    foreach ($raw in @($Patterns)) {
        $p = ([string]$raw -replace '\\', '/').Trim()
        if (-not $p) { throw "BCQuality.knowledge.$Name contains an empty pattern." }
        if ($p.StartsWith('/') -or $p -match '^[A-Za-z]:') { throw "BCQuality.knowledge.$Name pattern '$raw' must be relative to the BCQuality root." }
        if (@($p.Split('/') | Where-Object { $_ -eq '..' }).Count) { throw "BCQuality.knowledge.$Name pattern '$raw' must not contain '..'." }
        $p
    }
}

function Get-KnowledgeContentHash {
    # SHA-256 over the retained content (path and file hash, ordinal order). Excludes git metadata and the files
    # this policy generates, so the same clone and the same policy always give the same hash.
    param([Parameter(Mandatory)] [string] $Root)
    $skip = @('_filter-report.json', 'knowledge-index.json')
    $rels = [System.Collections.Generic.List[string]]::new()
    foreach ($f in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $rel = [System.IO.Path]::GetRelativePath($Root, $f.FullName) -replace '\\', '/'
        if ($rel.StartsWith('.git/') -or $rel.StartsWith('knowledge-index-slices/') -or $rel -in $skip) { continue }
        $rels.Add($rel)
    }
    $sorted = $rels.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    $lines = foreach ($rel in $sorted) {
        $h = (Get-FileHash -LiteralPath (Join-Path $Root $rel) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$rel`0$h"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').ToLowerInvariant()
}

function Invoke-KnowledgePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BCQualityRoot,
        [string[]] $EnabledLayers = $script:KnowledgeLayers,
        [string[]] $Allow = @(),
        [string[]] $Deny = @(),
        [string] $ReportPath
    )
    $root = (Resolve-Path -LiteralPath $BCQualityRoot).Path
    $builder = Join-Path $root 'tools/Build-KnowledgeIndex.ps1'
    if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) { throw "BCQuality is missing tools/Build-KnowledgeIndex.ps1 under $root." }
    $layers = @($EnabledLayers)
    foreach ($l in $layers) { if ($script:KnowledgeLayers -notcontains $l) { throw "Unknown BCQuality layer '$l'. Allowed: $($script:KnowledgeLayers -join ', ')." } }
    # The review's super-skill lives in the microsoft layer; fail here, before any agent call, rather than mid-review.
    if ($layers -notcontains 'microsoft') { throw "BCQuality.enabledLayers must include 'microsoft': the review's super-skill (microsoft/skills/review/al-code-review.md) lives in that layer." }
    $allow = @(Assert-KnowledgePatterns -Patterns $Allow -Name 'allow')
    $deny = @(Assert-KnowledgePatterns -Patterns $Deny -Name 'deny')
    if (-not $ReportPath) { $ReportPath = Join-Path $root '_filter-report.json' }

    $removed = [System.Collections.Generic.List[object]]::new()

    # A disabled layer is deleted, not just left out of the index: Entry's `enabled-layers` only narrows discovery,
    # and the agent can read anything that is on disk. Skills go too, so no review area can come from it.
    foreach ($layer in @($script:KnowledgeLayers | Where-Object { $layers -notcontains $_ })) {
        foreach ($area in 'knowledge', 'skills') {
            $areaRoot = Join-Path $root "$layer/$area"
            if (-not (Test-Path -LiteralPath $areaRoot -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $areaRoot -Recurse -File)) {
                $kind = if ($file.Extension -eq '.md') { if ($area -eq 'skills') { 'skill' } else { 'knowledge' } }
                elseif ($area -eq 'knowledge' -and $file.Extension -eq '.al') { 'knowledge-sample' }
                else { continue }   # .gitkeep and the like are not content
                $rel = [System.IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'
                Remove-Item -LiteralPath $file.FullName -Force
                $removed.Add([ordered]@{ path = $rel; kind = $kind; reason = 'layer-disabled' })
            }
        }
    }

    foreach ($layer in $layers) {
        $knowledgeRoot = Join-Path $root "$layer/knowledge"
        if (-not (Test-Path -LiteralPath $knowledgeRoot -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $knowledgeRoot -Recurse -File -Filter '*.md')) {
            $rel = [System.IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'
            $reason = $null
            if ($deny.Count -and @($deny | Where-Object { Test-KnowledgeGlob -Path $rel -Pattern $_ }).Count) { $reason = 'deny-list-hit' }
            elseif ($allow.Count -and -not @($allow | Where-Object { Test-KnowledgeGlob -Path $rel -Pattern $_ }).Count) { $reason = 'allow-list-miss' }
            if (-not $reason) { continue }
            # An article's code samples are named <slug>.<kind>.al next to it; they go with it.
            $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $samples = @(Get-ChildItem -LiteralPath $file.DirectoryName -File | Where-Object { $_.Name.StartsWith("$slug.", [StringComparison]::Ordinal) -and $_.Name.EndsWith('.al', [StringComparison]::Ordinal) })
            Remove-Item -LiteralPath $file.FullName -Force
            $removed.Add([ordered]@{ path = $rel; kind = 'knowledge'; reason = $reason })
            foreach ($s in $samples) {
                $sRel = [System.IO.Path]::GetRelativePath($root, $s.FullName) -replace '\\', '/'
                Remove-Item -LiteralPath $s.FullName -Force
                $removed.Add([ordered]@{ path = $sRel; kind = 'knowledge-sample'; reason = $reason })
            }
        }
    }

    $indexPath = Join-Path $root 'knowledge-index.json'
    if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force }
    & $builder -BCQualityRoot $root -IndexPath $indexPath -EnabledLayers $layers -KnowledgeAllow $allow -KnowledgeDeny $deny | Out-Null
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw 'Build-KnowledgeIndex.ps1 did not produce knowledge-index.json.' }
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 20
    $indexed = @(if ($index.PSObject.Properties['articles']) { $index.articles | ForEach-Object { [string]$_.path } })
    foreach ($r in @($removed | Where-Object { $_.kind -eq 'knowledge' })) {
        if ($indexed -contains $r.path) { throw "Removed BCQuality knowledge is still in the generated index: $($r.path)" }
    }
    if (($allow.Count -or $deny.Count) -and $indexed.Count -eq 0) {
        Write-Warning 'The knowledge allow/deny rules removed every article; reviews will find no knowledge to apply.'
    }

    $hash = Get-KnowledgeContentHash -Root $root
    $report = [ordered]@{
        enabledLayers = $layers; knowledgeAllow = $allow; knowledgeDeny = $deny
        indexedCount = $indexed.Count; removedCount = @($removed | Where-Object { $_.kind -eq 'knowledge' }).Count
        contentHash = $hash; removed = @($removed)
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    Write-Host "Knowledge policy: $($report.removedCount) article(s) removed, $($indexed.Count) indexed; content hash $hash"
    [pscustomobject]$report
}
