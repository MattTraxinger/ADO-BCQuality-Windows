# Host-side evidence of what the agent actually read, taken from Claude Code's own stream-json output
# (`claude -p --output-format stream-json --verbose`). The model's claim about what it read is never used.
# Event shape (verified against a real capture, Claude Code 2.1.x):
#   assistant event, message.content[]: { type:'tool_use', id, name:'Read', input:{ file_path[, offset, limit] } }
#   user event,      message.content[]: { type:'tool_result', tool_use_id, is_error? }
#                    plus top-level tool_use_result.file: { filePath, numLines, startLine, totalLines }
#   result event:    { is_error, subtype, result, total_cost_usd, num_turns, duration_ms, usage{...} }
# Depends on Common.ps1 (Get-OptionalProperty, ConvertTo-RepoRelativePath).
Set-StrictMode -Version Latest

function Read-ClaudeEvents {
    param([Parameter(Mandatory)] [string] $EventsPath)
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        try { $e = $line | ConvertFrom-Json -Depth 50 } catch { continue }
        if ($e -is [pscustomobject] -and $e.PSObject.Properties['type']) { $e }
    }
}

function Get-ClaudeToolCalls {
    # Pairs each tool_use with its tool_result by id. A call with no result is `done = $false`.
    param([Parameter(Mandatory)] [string] $EventsPath)
    $calls = [ordered]@{}
    foreach ($e in Read-ClaudeEvents $EventsPath) {
        $msg = Get-OptionalProperty $e 'message'
        if ($null -eq $msg) { continue }
        foreach ($c in @(Get-OptionalProperty $msg 'content')) {
            if ($c -isnot [pscustomobject]) { continue }
            $ctype = Get-OptionalProperty $c 'type'
            if ($e.type -eq 'assistant' -and $ctype -eq 'tool_use') {
                $calls[[string]$c.id] = [pscustomobject]@{ name = [string]$c.name; input = (Get-OptionalProperty $c 'input'); done = $false; ok = $false; file = $null; error = '' }
            }
            elseif ($e.type -eq 'user' -and $ctype -eq 'tool_result') {
                $id = [string](Get-OptionalProperty $c 'tool_use_id')
                if (-not $calls.Contains($id)) { continue }
                $call = $calls[$id]
                $call.done = $true
                $call.ok = (Get-OptionalProperty $c 'is_error' $false) -ne $true
                if (-not $call.ok) {
                    $body = Get-OptionalProperty $c 'content' ''
                    $call.error = if ($body -is [string]) { $body } else { (@($body) | ForEach-Object { Get-OptionalProperty $_ 'text' '' }) -join ' ' }
                }
                $tur = Get-OptionalProperty $e 'tool_use_result'
                if ($tur -is [pscustomobject]) { $call.file = Get-OptionalProperty $tur 'file' }
            }
        }
    }
    $calls.Values
}

function Test-ClaudeFullRead {
    # A full read: a successful Read whose only argument is file_path AND whose result reports that every line
    # was returned. Missing line counts fail closed (not a full read).
    param([Parameter(Mandatory)] $Call)
    if ($Call.name -ne 'Read' -or -not $Call.done -or -not $Call.ok) { return $false }
    if ($Call.input -isnot [pscustomobject]) { return $false }
    $names = @($Call.input.PSObject.Properties.Name)
    if ($names.Count -ne 1 -or $names[0] -ne 'file_path') { return $false }
    $f = $Call.file
    if ($f -isnot [pscustomobject]) { return $false }
    foreach ($k in 'numLines', 'startLine', 'totalLines') { if (-not $f.PSObject.Properties[$k]) { return $false } }
    ($f.startLine -le 1) -and ($f.numLines -ge $f.totalLines)
}

function Get-ClaudeRetrievedArticlePaths {
    # Knowledge articles the agent opened in full: <root>/**/knowledge/*.md, repo-relative, sorted.
    param([Parameter(Mandatory)] [string] $EventsPath, [Parameter(Mandatory)] [string] $BCQualityRoot)
    $ok = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($call in Get-ClaudeToolCalls $EventsPath) {
        if (-not (Test-ClaudeFullRead $call)) { continue }
        $rel = ConvertTo-RepoRelativePath -Path ([string]$call.input.file_path) -Root $BCQualityRoot
        if ($rel -and $rel -match '(^|/)knowledge/.+\.md$') { $null = $ok.Add($rel) }
    }
    $ok | Sort-Object
}

function Get-ClaudeToolSummary {
    # One line of "Tool ok/failed" counts so a call that read nothing can be explained in the log.
    param([Parameter(Mandatory)] [string] $EventsPath)
    $counts = @{}
    foreach ($call in Get-ClaudeToolCalls $EventsPath) {
        $key = "$($call.name):$(if (-not $call.done) { 'noresult' } elseif ($call.ok) { 'ok' } else { 'failed' })"
        $counts[$key] = 1 + [int]$counts[$key]
    }
    if ($counts.Count -eq 0) { return 'no tool calls' }
    (($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')
}

function Get-ClaudeReadLog {
    # Log lines for reads of knowledge files (full, partial or failed); other reads are only counted.
    param([Parameter(Mandatory)] [string] $EventsPath, [Parameter(Mandatory)] [string] $BCQualityRoot)
    $other = 0; $out = [System.Collections.Generic.List[string]]::new()
    foreach ($call in Get-ClaudeToolCalls $EventsPath) {
        if ($call.name -ne 'Read' -or $call.input -isnot [pscustomobject]) { continue }
        $rel = ConvertTo-RepoRelativePath -Path ([string](Get-OptionalProperty $call.input 'file_path' '')) -Root $BCQualityRoot
        if ($rel -and $rel -match 'knowledge/') {
            $state = if (-not $call.ok) { 'failed' } elseif (Test-ClaudeFullRead $call) { 'full' } else { 'partial/unverified' }
            $out.Add("  read $state $rel")
        }
        else { $other++ }
    }
    $out.Add("  other reads: $other")
    $out
}

function Get-ClaudeFailureLog {
    # Log lines for the first failed tool calls: tool, the path or pattern it targeted, and the error text, so a
    # denied read is explained in the step log instead of only counted. Paths and messages come from tool
    # inputs/results, never from the model's own text.
    param([Parameter(Mandatory)] [string] $EventsPath, [int] $Max = 8)
    $out = [System.Collections.Generic.List[string]]::new(); $n = 0
    foreach ($call in Get-ClaudeToolCalls $EventsPath) {
        if (-not $call.done -or $call.ok) { continue }
        $n++
        if ($out.Count -ge $Max) { continue }
        $target = if ($call.input -is [pscustomobject]) {
            $t = Get-OptionalProperty $call.input 'file_path' (Get-OptionalProperty $call.input 'path' (Get-OptionalProperty $call.input 'pattern' ''))
            [string]$t
        } else { '' }
        $msg = (([string]$call.error) -replace '\s+', ' ').Trim()
        $out.Add("  failed $($call.name) $target :: $($msg.Substring(0, [Math]::Min(220, $msg.Length)))")
    }
    if ($n -gt $Max) { $out.Add("  ... and $($n - $Max) more failed call(s)") }
    $out
}

function Get-ClaudeLiveLine {
    # Short progress lines for one stream event while a call runs. Returns nothing for events not worth a line.
    # Text comes from tool inputs and system events, never from the model's prose, and tool results are not printed.
    param([Parameter(Mandatory)] $StreamEvent, [string] $BCQualityRoot)
    $short = {
        param($p)
        $p = [string]$p
        $rel = if ($BCQualityRoot -and $p) { ConvertTo-RepoRelativePath -Path $p -Root $BCQualityRoot } else { $null }
        if ($rel) { "<bcquality>/$rel" } else { $p }
    }
    switch ($StreamEvent.type) {
        'system' {
            $sub = [string](Get-OptionalProperty $StreamEvent 'subtype' '')
            if ($sub -eq 'init') {
                "session: model=$(Get-OptionalProperty $StreamEvent 'model' '?'), key source=$(Get-OptionalProperty $StreamEvent 'apiKeySource' '?'), cli=$(Get-OptionalProperty $StreamEvent 'claude_code_version' '?'), tools=$(@(Get-OptionalProperty $StreamEvent 'tools' @()) -join ',')"
            }
            elseif ($sub -match 'retry') {
                $bits = foreach ($k in 'attempt', 'max_retries', 'retry_delay_ms', 'error_status', 'error') {
                    $v = Get-OptionalProperty $StreamEvent $k; if ($null -ne $v) { "$k=$v" }
                }
                "API retry ($sub): $($bits -join ', ')"
            }
        }
        'rate_limit_event' {
            $i = Get-OptionalProperty $StreamEvent 'rate_limit_info'
            $status = [string](Get-OptionalProperty $i 'status' '')
            if ($status -and $status -ne 'allowed') { "rate limit: status=$status type=$(Get-OptionalProperty $i 'rateLimitType' '?')" }
        }
        'assistant' {
            $msg = Get-OptionalProperty $StreamEvent 'message'
            foreach ($c in @(Get-OptionalProperty $msg 'content' @())) {
                if ($c -isnot [pscustomobject] -or (Get-OptionalProperty $c 'type') -ne 'tool_use') { continue }
                $in = Get-OptionalProperty $c 'input'
                $name = [string]$c.name
                switch ($name) {
                    'Read' {
                        $extra = if ($in -is [pscustomobject]) { @($in.PSObject.Properties.Name | Where-Object { $_ -ne 'file_path' }) } else { @() }
                        "Read $(& $short (Get-OptionalProperty $in 'file_path'))$(if ($extra) { " (partial: $($extra -join ','))" })"
                    }
                    'Glob' { "Glob $(Get-OptionalProperty $in 'pattern') in $(& $short (Get-OptionalProperty $in 'path' ''))" }
                    'Grep' { "Grep '$(Get-OptionalProperty $in 'pattern')' in $(& $short (Get-OptionalProperty $in 'path' ''))" }
                    default { "$name (unexpected tool)" }
                }
            }
        }
    }
}

function Get-ClaudeResultEvent {
    # The final `result` event, or $null when the stream ended without one.
    param([Parameter(Mandatory)] [string] $EventsPath)
    $r = $null
    foreach ($e in Read-ClaudeEvents $EventsPath) { if ($e.type -eq 'result') { $r = $e } }
    $r
}

function Get-ClaudeUsage {
    # Token counts and cost from the result event. Cost is API-equivalent, not necessarily what is billed.
    # Observed models are the keys of `modelUsage`, which the CLI fills from what the API actually answered with.
    # Depends on Metrics.ps1 (New-AgentUsage).
    param($ResultEvent)
    if ($null -eq $ResultEvent) { return $null }
    $u = Get-OptionalProperty $ResultEvent 'usage'
    $mu = Get-OptionalProperty $ResultEvent 'modelUsage'
    New-AgentUsage -Source 'claude-code' `
        -Models $(if ($mu -is [pscustomobject]) { @($mu.PSObject.Properties.Name) } else { @() }) `
        -InputTokens ([long](Get-OptionalProperty $u 'input_tokens' 0)) `
        -OutputTokens ([long](Get-OptionalProperty $u 'output_tokens' 0)) `
        -CacheReadTokens ([long](Get-OptionalProperty $u 'cache_read_input_tokens' 0)) `
        -CacheCreationTokens ([long](Get-OptionalProperty $u 'cache_creation_input_tokens' 0)) `
        -CostUsd ([double](Get-OptionalProperty $ResultEvent 'total_cost_usd' 0)) `
        -Turns ([int](Get-OptionalProperty $ResultEvent 'num_turns' 0)) `
        -DurationMs ([int](Get-OptionalProperty $ResultEvent 'duration_ms' 0))
}
