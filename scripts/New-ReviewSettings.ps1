#requires -Version 7.5
<#
.SYNOPSIS
    Writes the review settings file for the in-job flow (examples/pr-validation/bcquality-review-steps.yml).
.DESCRIPTION
    In the in-job flow the PIPELINE owns the settings: this file is written by a pipeline step, outside the pull
    request tree, so a pull request cannot change its own review rules. Nothing is read from the PR.

    The basics come from parameters. Everything else the settings schema allows (disabled review areas, knowledge
    allow/deny rules, suggestion mode, regional layouts, near-duplicate tolerance, and so on) comes from
    -ExtraSettingsJson (or the BCQ_EXTRA_SETTINGS environment variable), a JSON object that is merged over the basics:
    objects merge key by key, arrays and values replace. Example:

      {"BCQuality":{"disabledSkills":["microsoft/skills/review/al-finance-review.md"]},
       "CodeReviewAgent":{"suggestions":"manual","regional":{"layouts":["src/Apps/{region}/{path}"]}}}

    branches is always '**': the calling pipeline's own condition decides whether a review runs, and the
    target branch is not interpolated into a branch pattern, where a name containing + or other pattern characters
    would not match itself.

    With -SchemaPath the result is validated against the settings schema before anything is written, so a typo in
    the extra settings fails this step with the schema's message instead of surfacing later as a skipped review.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutFile,
    [Parameter(Mandatory)] [string] $BCQualityVersion,
    [string] $EnabledLayers = 'microsoft,community',          # comma separated: microsoft,community,custom
    [string] $Provider = 'claude-code',
    [string] $Model,
    [string] $LeafModel,
    [string] $ExtraSettingsJson = $env:BCQ_EXTRA_SETTINGS,
    [string] $SchemaPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Merge-SettingsOverlay {
    # Objects merge key by key, at any depth; anything else (arrays, strings, numbers, booleans) replaces.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Base, [Parameter(Mandatory)] [System.Collections.IDictionary] $Overlay)
    foreach ($key in $Overlay.Keys) {
        if ($Base.Contains($key) -and $Base[$key] -is [System.Collections.IDictionary] -and $Overlay[$key] -is [System.Collections.IDictionary]) {
            Merge-SettingsOverlay -Base $Base[$key] -Overlay $Overlay[$key]
        }
        else { $Base[$key] = $Overlay[$key] }
    }
}

$agent = [ordered]@{ enabled = $true; branches = @('**'); excludedAuthors = @(); provider = $Provider }
if ($Model) { $agent.model = $Model }
if ($LeafModel) { $agent.leafModel = $LeafModel }
$settings = [ordered]@{
    BCQuality       = [ordered]@{
        version       = $BCQualityVersion
        enabledLayers = @($EnabledLayers.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    CodeReviewAgent = $agent
    mode            = 'advisory'
    tier            = 2
}

if ($ExtraSettingsJson -and $ExtraSettingsJson.Trim()) {
    try { $extra = $ExtraSettingsJson | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop }
    catch { throw "The extra settings are not valid JSON: $($_.Exception.Message)" }
    if ($extra -isnot [System.Collections.IDictionary]) { throw 'The extra settings must be a JSON object, for example {"CodeReviewAgent":{"suggestions":"manual"}}.' }
    Merge-SettingsOverlay -Base $settings -Overlay $extra
}

$json = $settings | ConvertTo-Json -Depth 20
if ($SchemaPath) { $null = Read-Settings -Json $json -SchemaPath $SchemaPath }   # throws with the schema's message

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Set-Content -LiteralPath $OutFile -Value $json -Encoding utf8
Write-Host $json
