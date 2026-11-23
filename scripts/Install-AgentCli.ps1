#requires -Version 7.5
<#
.SYNOPSIS
    Installs the pinned agent CLI for the configured provider into a private folder and publishes how to launch it.
.DESCRIPTION
    Works on Windows and Linux agents and never touches the machine's global npm folder, so it is safe on a
    long-lived self-hosted agent. The provider comes from the settings file; the exact version comes from
    package.json (anything but an exact x.y.z is refused). Sets BCQ_AGENT_PATH (the CLI's entry point: a native
    executable or a Node script, see Providers/AgentLaunch.ps1) and AGENT_CLI_VERSION.
    Runs with no secrets: npm install scripts execute here.
#>
[CmdletBinding()]
param(
    [string] $Provider,                                # copilot | claude-code; or let -SettingsFile say
    [string] $SettingsFile,
    [Parameter(Mandatory)] [string] $PackageJsonPath,
    [Parameter(Mandatory)] [string] $InstallRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Providers/AgentLaunch.ps1')

if ($Provider) { $provider = $Provider }
elseif ($SettingsFile) {
    $settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json -Depth 20
    $provider = Get-OptionalProperty (Get-OptionalProperty $settings 'CodeReviewAgent') 'provider' 'copilot'
}
else { throw 'Give -Provider or -SettingsFile.' }
$package = switch ($provider) {
    'copilot' { '@github/copilot' }
    'claude-code' { '@anthropic-ai/claude-code' }
    default { throw "Unknown agent provider '$provider'." }
}
$deps = (Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json -Depth 20).dependencies
$version = Get-OptionalProperty $deps $package
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "package.json must pin $package to an exact version, found '$version'." }

if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $InstallRoot 'package.json') -Value '{"private":true}' -Encoding utf8
Write-Host "Installing $package@$version into $InstallRoot"
npm install --prefix $InstallRoot --no-audit --no-fund --no-package-lock --ignore-scripts=false "$package@$version"
if ($LASTEXITCODE -ne 0) { throw "npm install of $package@$version failed (exit $LASTEXITCODE)." }

# Find the entry point the package itself declares (bin), so no platform-specific shim is involved.
$pkgDir = Join-Path $InstallRoot "node_modules/$package"
$meta = Get-Content -LiteralPath (Join-Path $pkgDir 'package.json') -Raw | ConvertFrom-Json -Depth 20
$binRel = if ($meta.bin -is [string]) { $meta.bin } else { @($meta.bin.PSObject.Properties)[0].Value }
$entry = Join-Path $pkgDir $binRel
if (-not (Test-Path -LiteralPath $entry)) {
    throw "$package installed but its entry point '$binRel' is missing. If the install ran with scripts disabled by npm policy, its native binary was not placed."
}

# Prove it starts before any secret is involved.
$launch = Get-AgentLaunch -DefaultCommand $package -EntryPath $entry
$out = & $launch.FileName @($launch.PrefixArgs) --version 2>&1
if ($LASTEXITCODE -ne 0) { throw "The installed CLI would not start: $out" }
Write-Host "Installed $package@$version; the CLI reports: $(($out | Select-Object -First 1))"
Set-PipelineVariable -Name BCQ_AGENT_PATH -Value $entry
Set-PipelineVariable -Name AGENT_CLI_VERSION -Value $version
