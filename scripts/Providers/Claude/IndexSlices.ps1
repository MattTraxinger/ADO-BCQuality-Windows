# Per-domain slices of knowledge-index.json, for agents whose file reader cannot open the whole index.
# Claude Code's Read tool refuses files over 256 KB / 25,000 tokens, and the index is about 260 KB. BCQuality's
# own retrieval helpers need a shell, which the review agent never gets, so the host cuts the index into
# domain slices that fit. Rows are copied unchanged from the index the pinned clone produced; nothing is added,
# reordered or dropped, so a slice is exactly "the rows whose domain is X". Reading an index is never evidence
# of retrieval: only article reads count (Evidence.ps1 in this folder). Depends on Common.ps1 (Get-OptionalProperty).
Set-StrictMode -Version Latest

function Initialize-KnowledgeIndexSlices {
    # Returns the sorted domain names that have a slice; empty when there is no index to slice.
    param([Parameter(Mandatory)] [string] $BCQualityRoot)
    $index = Join-Path $BCQualityRoot 'knowledge-index.json'
    if (-not (Test-Path -LiteralPath $index)) { return @() }
    $dir = Join-Path $BCQualityRoot 'knowledge-index-slices'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $j = Get-Content -LiteralPath $index -Raw | ConvertFrom-Json -Depth 20
    $domains = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @($j.articles) | Group-Object domain) {
        $safe = ([string]$g.Name) -replace '[^A-Za-z0-9-]', '_'
        $slice = [ordered]@{
            version = Get-OptionalProperty $j 'version'; enabledLayers = Get-OptionalProperty $j 'enabledLayers'
            sourceSnapshot = Get-OptionalProperty $j 'sourceSnapshot'; domain = [string]$g.Name
            articleCount = $g.Count; articles = @($g.Group)
        }
        $slice | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath (Join-Path $dir "$safe.json") -Encoding utf8
        $domains.Add($safe)
    }
    @($domains | Sort-Object)
}
