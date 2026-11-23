# Host-side evidence of what the agent actually read, taken from Copilot CLI's own session events.
# BCQuality's acceptance gate requires the host's record of fully retrieved knowledge articles;
# the model's claim about what it read is never used.
# Event shape (verified against a real log): tool.execution_start {toolCallId, toolName:'view', arguments:{path}}
# paired by toolCallId with tool.execution_complete {success}.
# Depends on Common.ps1 (ConvertTo-RepoRelativePath).
Set-StrictMode -Version Latest

function Get-CopilotStateDir {
    $root = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }   # (verify on the hosted image)
    Join-Path $root 'session-state'
}

function Get-CopilotSessionIds {
    $dir = Get-CopilotStateDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -notlike '.*' } | ForEach-Object Name)
}

function Get-CopilotToolSummary {
    # One line of "toolName ok/failed" counts, so a call that read nothing can be explained in the log.
    param([Parameter(Mandatory)] [string] $EventsPath)
    $names = @{}; $counts = @{}
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        try { $e = $line | ConvertFrom-Json -Depth 20 } catch { continue }
        if ($e -isnot [pscustomobject] -or -not $e.PSObject.Properties['type'] -or -not $e.PSObject.Properties['data']) { continue }
        if ($e.type -eq 'tool.execution_start') { $names[$e.data.toolCallId] = [string]$e.data.toolName }
        elseif ($e.type -eq 'tool.execution_complete' -and $names.ContainsKey($e.data.toolCallId)) {
            $key = "$($names[$e.data.toolCallId]):$(if ($e.data.success) { 'ok' } else { 'failed' })"
            $counts[$key] = 1 + [int]$counts[$key]
        }
    }
    if ($counts.Count -eq 0) { return 'no tool calls' }
    (($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')
}

function Get-CopilotViewLog {
    # Log lines for views of knowledge files: outcome, repo-relative path, and any argument besides `path`
    # (an extra argument such as a line range means a partial read). Other views are only counted.
    param([Parameter(Mandatory)] [string] $EventsPath, [Parameter(Mandatory)] [string] $BCQualityRoot)
    $views = @{}; $other = 0; $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        try { $e = $line | ConvertFrom-Json -Depth 20 } catch { continue }
        if ($e -isnot [pscustomobject] -or -not $e.PSObject.Properties['type'] -or -not $e.PSObject.Properties['data']) { continue }
        if ($e.type -eq 'tool.execution_start' -and $e.data.toolName -eq 'view') { $views[$e.data.toolCallId] = $e.data.arguments }
        elseif ($e.type -eq 'tool.execution_complete' -and $views.ContainsKey($e.data.toolCallId)) {
            $a = $views[$e.data.toolCallId]
            $rel = ConvertTo-RepoRelativePath -Path ([string]$a.path) -Root $BCQualityRoot
            if ($rel -and $rel -match 'knowledge/') {
                $extra = @($a.PSObject.Properties.Name | Where-Object { $_ -ne 'path' })
                $out.Add("  view $(if ($e.data.success) { 'ok' } else { 'failed' }) $rel$(if ($extra) { " [also: $($extra -join ',')]" })")
            }
            else { $other++ }
        }
    }
    $out.Add("  other views: $other")
    $out
}

function Get-RetrievedArticlePaths {
    # Knowledge articles the agent opened in full: a successful `view` of a file under <root>/**/knowledge/*.md
    # with no arguments beyond `path` (any range argument means a partial read, which does not count).
    param([Parameter(Mandatory)] [string] $EventsPath, [Parameter(Mandatory)] [string] $BCQualityRoot)
    $started = @{}
    $ok = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        try { $e = $line | ConvertFrom-Json -Depth 20 } catch { continue }
        if ($e -isnot [pscustomobject] -or -not $e.PSObject.Properties['type'] -or -not $e.PSObject.Properties['data']) { continue }
        if ($e.type -eq 'tool.execution_start' -and $e.data.toolName -eq 'view') {
            $args = $e.data.arguments
            $names = @($args.PSObject.Properties.Name)
            if ($names.Count -eq 1 -and $names[0] -eq 'path') { $started[$e.data.toolCallId] = [string]$args.path }
        }
        elseif ($e.type -eq 'tool.execution_complete' -and $e.data.success -eq $true -and $started.ContainsKey($e.data.toolCallId)) {
            $rel = ConvertTo-RepoRelativePath -Path $started[$e.data.toolCallId] -Root $BCQualityRoot
            if ($rel -and $rel -match '(^|/)knowledge/.+\.md$') { $null = $ok.Add($rel) }
        }
    }
    $ok | Sort-Object   # callers wrap in @() so zero results is an empty array
}
