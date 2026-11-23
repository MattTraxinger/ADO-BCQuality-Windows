# How to start an agent CLI. Shared by every provider adapter.
# Install-AgentCli.ps1 installs the pinned CLI into a private folder and publishes its entry point as
# BCQ_AGENT_PATH. When that is unset (the Linux template installs globally), the CLI is found on PATH.
# The entry point is launched directly, never through cmd.exe, so the prompt text is never parsed by a shell:
#   a native executable (Claude Code: bin/claude.exe) is started as is;
#   a Node script (Copilot: npm-loader.js) is started as `node <script>`.
Set-StrictMode -Version Latest

function Get-AgentLaunch {
    param([Parameter(Mandatory)] [string] $DefaultCommand, [string] $EntryPath = $env:BCQ_AGENT_PATH)
    if ([string]::IsNullOrWhiteSpace($EntryPath)) {
        return [pscustomobject]@{ FileName = $DefaultCommand; PrefixArgs = @() }
    }
    if (-not (Test-Path -LiteralPath $EntryPath)) { throw "BCQ_AGENT_PATH points to a missing file: $EntryPath" }
    if ($EntryPath -match '\.(c|m)?js$') {
        $node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        return [pscustomobject]@{ FileName = $node; PrefixArgs = @($EntryPath) }
    }
    [pscustomobject]@{ FileName = $EntryPath; PrefixArgs = @() }
}

function New-AgentProcessInfo {
    # A ProcessStartInfo for the CLI with its launch arguments already added.
    param([Parameter(Mandatory)] [string] $DefaultCommand, [string] $EntryPath = $env:BCQ_AGENT_PATH)
    $launch = Get-AgentLaunch -DefaultCommand $DefaultCommand -EntryPath $EntryPath
    $psi = [Diagnostics.ProcessStartInfo]::new($launch.FileName)
    foreach ($a in $launch.PrefixArgs) { $psi.ArgumentList.Add($a) }
    $psi
}
