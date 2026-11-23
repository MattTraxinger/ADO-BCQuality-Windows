# Claude Code adapter for Invoke-AgentCall. Authenticates with ANTHROPIC_API_KEY, or for local runs only with the
# developer's Claude Code login (BCQ_CLAUDE_AUTH=subscription, see Test-ClaudeSubscriptionAuth).
# Contract (every adapter): returns [pscustomobject]@{ text; retrieved; usage } where `retrieved` holds the
# repo-relative knowledge articles the HOST saw the agent read in full (Get-ClaudeRetrievedArticlePaths).
Set-StrictMode -Version Latest

function Get-ClaudeReadRule {
    # Path-scoped allow rule for one directory. `/` + an absolute path gives Claude Code's absolute-path form
    # on Linux (`//home/...`) and a working form on Windows (`/C:/...`). A bare `Read` rule would allow reads
    # anywhere, and with no rule at all dontAsk denies everything; both were observed with Claude Code 2.1.x.
    # One Read rule also covers Glob and Grep inside the directory. A wrong spelling fails closed: reads are
    # denied, no article is recorded as read, and findings that cite knowledge are rejected by the gate.
    param([Parameter(Mandatory)] [string] $Dir)
    "Read(/$(($Dir -replace '\\', '/').TrimEnd('/'))/**)"
}

function Test-ClaudeSubscriptionAuth {
    # True when a local run asked for the developer's Claude Code login (BCQ_CLAUDE_AUTH=subscription).
    # Refused in a pipeline: a developer's login must never stand in for the pipeline's own key.
    $mode = [string]$env:BCQ_CLAUDE_AUTH
    if ([string]::IsNullOrWhiteSpace($mode) -or $mode -eq 'api-key') { return $false }
    if ($mode -ne 'subscription') { throw "BCQ_CLAUDE_AUTH='$mode' is not valid. Use 'subscription' (local runs only) or leave it unset." }
    if ($env:TF_BUILD -eq 'True') { throw 'BCQ_CLAUDE_AUTH=subscription is for local runs only and is refused in a pipeline (TF_BUILD is set).' }
    $true
}

function Invoke-ClaudeAgent {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Model,
        [string[]] $AddDirs = @(),
        [Parameter(Mandatory)] [string] $WorkingDirectory,   # accepted for the contract; deliberately not used, see below
        [Parameter(Mandatory)] [string] $BCQualityRoot,
        [int] $TimeoutSeconds = 900,
        [string] $SharedContextPath   # text common to every call of a run, appended to the system prompt (see below)
    )
    # Authentication. The pipeline uses ANTHROPIC_API_KEY. A developer running the review locally
    # (scripts/Invoke-LocalReview.ps1) sets BCQ_CLAUDE_AUTH=subscription instead: the key is removed from the CLI's
    # environment so it uses the developer's own Claude Code login. That mode is refused inside a pipeline (TF_BUILD).
    $subscription = Test-ClaudeSubscriptionAuth
    if (-not $subscription -and -not $env:ANTHROPIC_API_KEY) {
        throw 'ANTHROPIC_API_KEY is not set. The claude-code provider authenticates with an API key, or, for a local run only, with the Claude Code login when BCQ_CLAUDE_AUTH=subscription.'
    }

    # Claude's Read tool cannot open the 260 KB index, so give it per-domain slices and say so. Without this the
    # agent cannot find candidate articles and returns a valid `failed` report (seen in a real run).
    $domains = @(Initialize-KnowledgeIndexSlices -BCQualityRoot $BCQualityRoot)
    if ($domains.Count) {
        $Prompt += "`n`nTool note for this environment: your Read tool cannot open $BCQualityRoot/knowledge-index.json (it is over the tool's size limit). " +
            "Wherever a skill tells you to read that index, read the per-domain slices in $BCQualityRoot/knowledge-index-slices/ instead: <domain>.json holds exactly that domain's rows from the index, in the same format. " +
            "Available domains: $($domains -join ', '). Read each slice you need in full; if a skill spans several domains, read each one's slice. " +
            "Read opens files only, so use Glob to list a directory, and do not guess file names."
    }

    # Run from a clean, empty directory, never the PR checkout: Claude Code reads CLAUDE.md, hooks and settings
    # from its working directory, and the PR controls those files. All paths in the prompts are absolute and
    # reachable through --add-dir. --safe-mode disables CLAUDE.md, hooks, skills, plugins and MCP. --bare was tried
    # first but it also removes Glob and Grep from the tool set (init showed tools=Read only), so the agent could
    # not list a directory; --safe-mode keeps all three read tools. Auth is still ANTHROPIC_API_KEY from the
    # environment (the init event reports the key source, which the log prints).
    #
    # Prompt caching: the API caches by exact prefix (tools, then system prompt, then messages), so every call of a
    # run pays the cache-write price for anything that differs early on. Two things keep the front stable:
    #  * the working directory is the SAME empty folder for every call (a random name per call changed the system
    #    prompt each time), and --exclude-dynamic-system-prompt-sections moves what still varies per call (cwd,
    #    environment, --add-dir list) out of the system prompt into the first user message;
    #  * -SharedContextPath (BCQuality's do.md and entry.md, identical for every call) is appended to the system
    #    prompt, so it is written to the cache once and read from it by the other calls instead of being read
    #    through the Read tool, and written to the cache again, in every call.
    # Only the per-call event log needs a unique place; it lives in its own folder, outside the working directory.
    $clean = Join-Path ([IO.Path]::GetTempPath()) 'bcq-claude-cwd'
    New-Item -ItemType Directory -Path $clean -Force | Out-Null
    Get-ChildItem -LiteralPath $clean -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $callDir = Join-Path ([IO.Path]::GetTempPath()) "bcq-claude-events-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $callDir -Force | Out-Null
    try {
        $psi = New-AgentProcessInfo -DefaultCommand 'claude'
        if ($subscription) { [void]$psi.Environment.Remove('ANTHROPIC_API_KEY') }   # a key would take precedence over the login
        # The prompt must come first: the variadic options below would otherwise swallow it.
        foreach ($a in @('-p', $Prompt)) { $psi.ArgumentList.Add($a) }
        if ($Model) { foreach ($a in @('--model', $Model)) { $psi.ArgumentList.Add($a) } }
        $psi.ArgumentList.Add('--exclude-dynamic-system-prompt-sections')
        if ($SharedContextPath) { foreach ($a in @('--append-system-prompt-file', $SharedContextPath)) { $psi.ArgumentList.Add($a) } }
        # Read-only agent. --tools removes every other built-in (no shell, no write, no web). dontAsk denies
        # anything not pre-approved, and the only approvals are Read rules scoped to the directories below.
        foreach ($a in @('--tools', 'Read,Glob,Grep', '--permission-mode', 'dontAsk',
                '--safe-mode', '--no-session-persistence', '--output-format', 'stream-json', '--verbose')) { $psi.ArgumentList.Add($a) }
        if (@($AddDirs).Count) {
            $psi.ArgumentList.Add('--allowedTools'); foreach ($d in $AddDirs) { $psi.ArgumentList.Add((Get-ClaudeReadRule $d)) }
            $psi.ArgumentList.Add('--add-dir'); foreach ($d in $AddDirs) { $psi.ArgumentList.Add($d) }
        }
        Write-Host "Claude read scope: $((@($AddDirs) | ForEach-Object { Get-ClaudeReadRule $_ }) -join ' ')"
        $psi.WorkingDirectory = $clean
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [Diagnostics.Process]::Start($psi)
        $stderr = $proc.StandardError.ReadToEndAsync()
        # Stream the event output as it arrives: every line goes to events.jsonl (the evidence source) and a short
        # progress line goes to the log, so a slow call shows whether it is reading, thinking or waiting on the API.
        # Polling ReadLineAsync keeps this on one thread; no runspace hand-off.
        $events = Join-Path $callDir 'events.jsonl'
        $writer = [IO.StreamWriter]::new($events, $false, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $stamp = { "  [$([int]$sw.Elapsed.TotalSeconds)s]" }
            $reader = $proc.StandardOutput
            $pending = $reader.ReadLineAsync()
            $toolCalls = 0; $thinking = 0; $lastLine = ''; $lastPrint = 0.0
            while ($true) {
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $proc.Kill($true); throw "Claude call timed out after $TimeoutSeconds s." }
                if ($pending.IsCompleted) {
                    $line = $pending.Result
                    if ($null -eq $line) { break }
                    $writer.WriteLine($line)
                    if ($line -match '"subtype":"thinking_tokens".*?"estimated_tokens":(\d+)') { $thinking = [int]$Matches[1] }
                    else {
                        try { $evt = $line | ConvertFrom-Json -Depth 30 } catch { $evt = $null }
                        if ($evt -is [pscustomobject]) {
                            foreach ($l in @(Get-ClaudeLiveLine -StreamEvent $evt -BCQualityRoot $BCQualityRoot)) {
                                if (-not $l) { continue }
                                if ($l -match '^(Read|Glob|Grep) ') { $toolCalls++; $lastLine = $l }
                                Write-Host "$(& $stamp) $l"; $lastPrint = $sw.Elapsed.TotalSeconds
                            }
                        }
                    }
                    $pending = $reader.ReadLineAsync()
                    continue
                }
                if ($sw.Elapsed.TotalSeconds - $lastPrint -ge 30) {
                    Write-Host "$(& $stamp) ... working: $toolCalls tool call(s) so far$(if ($thinking) { ", thinking ~$thinking tokens this turn" })$(if ($lastLine) { "; last: $lastLine" })"
                    $lastPrint = $sw.Elapsed.TotalSeconds
                }
                Start-Sleep -Milliseconds 100
            }
        }
        finally { $writer.Dispose() }
        if (-not $proc.WaitForExit(60000)) { $proc.Kill($true); throw 'Claude did not exit after closing its output.' }
        $result = Get-ClaudeResultEvent -EventsPath $events
        if ($proc.ExitCode -ne 0 -or $null -eq $result -or (Get-OptionalProperty $result 'is_error' $false)) {
            $why = if ($result) { "$(Get-OptionalProperty $result 'subtype' 'error'): $(Get-OptionalProperty $result 'result' '')" } else { 'no result event' }
            throw "Claude exited $($proc.ExitCode) ($why) $($stderr.Result)".Trim()
        }
        # Evidence comes from the host-captured stream. If it cannot be parsed, no reads are recorded and
        # findings that cite knowledge are rejected by the gate (fail closed).
        $retrieved = @(Get-ClaudeRetrievedArticlePaths -EventsPath $events -BCQualityRoot $BCQualityRoot)
        Write-Host "Claude tool calls: $(Get-ClaudeToolSummary -EventsPath $events)"
        Get-ClaudeReadLog -EventsPath $events -BCQualityRoot $BCQualityRoot | ForEach-Object { Write-Host $_ }
        Get-ClaudeFailureLog -EventsPath $events | ForEach-Object { Write-Host $_ }
        Write-Host "Claude call read $($retrieved.Count) knowledge article(s) in full."
        [pscustomobject]@{ text = [string](Get-OptionalProperty $result 'result' ''); retrieved = @($retrieved); usage = (Get-ClaudeUsage $result) }
    }
    finally { Remove-Item -LiteralPath $callDir -Recurse -Force -ErrorAction SilentlyContinue }
}
