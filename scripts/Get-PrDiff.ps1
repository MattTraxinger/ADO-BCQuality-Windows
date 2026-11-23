#requires -Version 7.5
<#
.SYNOPSIS
    Writes per-file unified diffs for AL and app.json changes between the merge base and the reviewed head.
.DESCRIPTION
    Port of the idea in AL-Go's Git.ps1: literal pathspecs so file names are never treated as globs.
    Files are grouped by app folder (nearest ancestor containing app.json, or the configured appFolders).
    Writes <OutDir>/<appIndex>/diff/<path>.diff plus <OutDir>/apps.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoDir,
    [Parameter(Mandatory)] [string] $MergeBase,
    [Parameter(Mandatory)] [string] $HeadSha,
    [Parameter(Mandatory)] [string] $OutDir,
    [string[]] $AppFolders = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-AppFolderFor {
    param([string] $File, [string[]] $Apps)
    $Apps | Where-Object { $_ -eq '.' -or $File.StartsWith("$_/") } |
        Sort-Object Length -Descending | Select-Object -First 1
}

$files = @(& git -C $RepoDir diff --name-only --no-renames $MergeBase $HeadSha |
    Where-Object { $_ -match '\.al$|(^|/)app\.json$' })

$apps = if ($AppFolders.Count) { @($AppFolders | ForEach-Object { $_.Trim('/').Replace('\', '/') }) }
else {
    @(& git -C $RepoDir ls-tree -r --name-only $HeadSha | Where-Object { $_ -match '(^|/)app\.json$' } |
        ForEach-Object { $d = [IO.Path]::GetDirectoryName($_); if ($d) { $d.Replace('\', '/') } else { '.' } })
}

$groups = @{}
foreach ($file in $files) {
    $app = Get-AppFolderFor -File $file -Apps $apps
    if (-not $app) { continue }   # change outside any app folder: not reviewed
    if (-not $groups.ContainsKey($app)) { $groups[$app] = [System.Collections.Generic.List[string]]::new() }
    $groups[$app].Add($file)
}

$manifest = [System.Collections.Generic.List[object]]::new()
$index = 0
foreach ($app in ($groups.Keys | Sort-Object)) {
    $index++
    $dir = Join-Path $OutDir "app$index"
    foreach ($file in $groups[$app]) {
        $diff = & git -C $RepoDir --literal-pathspecs diff --no-renames --unified=3 $MergeBase $HeadSha -- $file
        $target = Join-Path $dir "diff/$file.diff"
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Set-Content -LiteralPath $target -Value ($diff -join "`n") -Encoding utf8
    }
    $manifest.Add([ordered]@{ name = "app$index"; folder = $app; dir = $dir; files = @($groups[$app]) })
}
Write-Json -Object @($manifest) -Path (Join-Path $OutDir 'apps.json')
Write-Host "Diff: $($manifest.Count) app folder(s), $($files.Count) changed file(s)."
