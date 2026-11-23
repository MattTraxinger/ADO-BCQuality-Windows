# Shared helpers. Dot-source from other scripts.
Set-StrictMode -Version Latest

$script:OutcomeRank = @{ 'not-applicable' = 0; 'no-knowledge' = 1; 'completed' = 2; 'partial' = 3; 'failed' = 4 }

function Get-DefaultSettings {
    [ordered]@{
        BCQuality       = [ordered]@{
            version        = $null   # null = the template's bundled default
            repo           = 'https://github.com/microsoft/BCQuality'
            enabledLayers  = @('microsoft', 'community', 'custom')
            disabledSkills = @()
            knowledge      = [ordered]@{ allow = @(); deny = @() }   # globs on clone-relative article paths; see KnowledgePolicy.ps1
        }
        CodeReviewAgent = [ordered]@{
            enabled         = $false
            branches        = @('main')
            excludedAuthors = @()
            suggestions     = 'apply'    # apply | manual | off; see SuggestionPlacement.ps1
            nearDuplicateLines = 2       # same rule within this many lines of an earlier thread is not posted again; 0 = off
            regional        = [ordered]@{ layouts = @(); primary = 'W1' }   # see RegionalGrouping.ps1; no layouts = no grouping
            provider        = 'copilot'
            model          = $null   # null = Copilot CLI default; never guessed
            leafModel       = $null
        }
        appFolders      = @()          # empty = auto-detect app.json
        bcVersion       = $null
        maxChangedFiles = 60
        mode            = 'advisory'
        tier            = 2
    }
}

function Merge-Settings {
    # Overlay a parsed settings object (PSCustomObject) onto the defaults, at any depth: an object overlays the
    # default object of the same name key by key, so setting only knowledge.allow keeps the default knowledge.deny.
    param([Parameter(Mandatory)] $Defaults, $Overrides)
    if ($null -eq $Overrides) { return $Defaults }
    foreach ($prop in $Overrides.PSObject.Properties) {
        $current = $Defaults[$prop.Name]
        if ($current -is [System.Collections.IDictionary] -and $prop.Value -is [pscustomobject]) {
            $null = Merge-Settings -Defaults $current -Overrides $prop.Value
        }
        else { $Defaults[$prop.Name] = $prop.Value }
    }
    $Defaults
}

function Read-Settings {
    # Validates raw JSON text against the schema, then merges it over the defaults.
    param([string] $Json, [Parameter(Mandatory)] [string] $SchemaPath)
    $settings = Get-DefaultSettings
    if ([string]::IsNullOrWhiteSpace($Json)) { return $settings }
    if (-not (Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
        $null = Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorVariable schemaError -ErrorAction SilentlyContinue
        throw "Settings do not satisfy the schema: $($schemaError -join '; ')"
    }
    $parsed = $Json | ConvertFrom-Json -Depth 20
    $settings = Merge-Settings -Defaults $settings -Overrides $parsed
    if ($settings.mode -eq 'status' -and $settings.tier -ne 2) {
        throw "mode 'status' requires tier 2."
    }
    $settings
}

function Get-WorstOutcome {
    param([string[]] $Outcomes)
    if (-not $Outcomes) { return 'not-applicable' }
    $Outcomes | Sort-Object { $script:OutcomeRank[$_] } -Descending | Select-Object -First 1
}

function Get-OptionalProperty {
    # Reads a property that the findings-report schema leaves optional; StrictMode would throw on a missing one.
    param($Object, [string] $Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $Default }
}

function ConvertTo-RepoRelativePath {
    # Absolute path under $Root -> repo-relative with forward slashes; $null when outside $Root.
    # Shared by every provider's evidence parser.
    param([string] $Path, [string] $Root)
    $p = $Path -replace '\\', '/'
    $r = ($Root -replace '\\', '/').TrimEnd('/') + '/'
    $cmp = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($p.StartsWith($r, $cmp)) { $p.Substring($r.Length) } else { $null }
}

function Write-Json {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)] [string] $Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Object | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Set-PipelineVariable {
    param([string] $Name, [string] $Value, [switch] $Output)
    $suffix = if ($Output) { ';isOutput=true' } else { '' }
    Write-Host "##vso[task.setvariable variable=$Name$suffix]$Value"
}
