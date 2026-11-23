# The one seam between the review logic and an agent. The review script calls only Invoke-AgentCall;
# each provider lives in its own folder under scripts/Providers/ and returns { text; retrieved; usage } (see
# Providers/Copilot/Adapter.ps1; `usage` is the shape in Metrics.ps1, or $null). A provider folder holds its
# adapter, its evidence parser, and anything
# else specific to that CLI. Adding a provider means adding a folder and one row below; nothing in
# Tier 1/Tier 2 changes.
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Providers/AgentLaunch.ps1')
. (Join-Path $PSScriptRoot 'Metrics.ps1')
. (Join-Path $PSScriptRoot 'Providers/Copilot/Evidence.ps1')
. (Join-Path $PSScriptRoot 'Providers/Copilot/Metrics.ps1')
. (Join-Path $PSScriptRoot 'Providers/Copilot/Adapter.ps1')
. (Join-Path $PSScriptRoot 'Providers/Claude/Evidence.ps1')
. (Join-Path $PSScriptRoot 'Providers/Claude/IndexSlices.ps1')
. (Join-Path $PSScriptRoot 'Providers/Claude/Adapter.ps1')

# SharedContext: the adapter accepts -SharedContextPath, a file placed in the system prompt so that text common to
# every call of a run is cached once and read from the cache by the other calls (prompt-prefix sharing).
$script:AgentProviders = @{
    copilot       = @{ DisplayName = 'Copilot CLI'; Invoke = 'Invoke-CopilotAgent'; SharedContext = $false }
    'claude-code' = @{ DisplayName = 'Claude Code'; Invoke = 'Invoke-ClaudeAgent'; SharedContext = $true }
}

function Get-AgentProvider {
    # Unknown names throw: a typo must never fall back to some other provider (and its secret).
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'copilot' }
    if (-not $script:AgentProviders.ContainsKey($Name)) {
        throw "Unknown agent provider '$Name'. Supported: $(($script:AgentProviders.Keys | Sort-Object) -join ', ')."
    }
    $script:AgentProviders[$Name]
}

function Invoke-AgentCall {
    param(
        [Parameter(Mandatory)] [string] $Provider,
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Model,
        [string[]] $AddDirs = @(),
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $BCQualityRoot,
        [int] $TimeoutSeconds = 900,
        [string] $SharedContextPath   # ignored by providers without SharedContext support
    )
    $entry = Get-AgentProvider $Provider
    $call = @{ Prompt = $Prompt; Model = $Model; AddDirs = $AddDirs; WorkingDirectory = $WorkingDirectory
        BCQualityRoot = $BCQualityRoot; TimeoutSeconds = $TimeoutSeconds }
    if ($SharedContextPath -and (Test-AgentSharedContext $Provider)) { $call.SharedContextPath = $SharedContextPath }
    & $entry.Invoke @call
}

function Test-AgentSharedContext {
    # True when the provider places a shared-context file in its system prompt (see $script:AgentProviders).
    param([string] $Provider)
    $entry = Get-AgentProvider $Provider
    $entry.ContainsKey('SharedContext') -and [bool]$entry.SharedContext
}
