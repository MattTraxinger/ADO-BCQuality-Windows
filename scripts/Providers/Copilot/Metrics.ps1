# Usage and model from Copilot CLI's own session events (the same events.jsonl the retrieval evidence uses), so no
# extra telemetry setup is needed. Shape verified against a real capture from Copilot CLI 1.0.105: one
# `session.usage_record` event per model API call, data.usage = { model, inputTokens, outputTokens, cacheReadTokens,
# cacheWriteTokens, reasoningTokens, cost, duration, copilotUsage: { totalNanoAiu } }.
# Copilot's inputTokens counts the whole prompt, cache reads and writes included; the shared shape keeps fresh input
# separate (see scripts/Metrics.ps1), so the cache parts are subtracted. `cost` is Copilot's premium-request count;
# AI credits are nano-AIU / 1e9, reported only when every record carries it.
# Depends on Common.ps1 (Get-OptionalProperty) and Metrics.ps1 (New-AgentUsage).
Set-StrictMode -Version Latest

function Get-CopilotUsage {
    # Returns a usage object, or $null when the session has no usage records (nothing is guessed).
    param([Parameter(Mandatory)] [string] $EventsPath)
    $records = 0; $nanoRecords = 0
    $in = 0L; $out = 0L; $read = 0L; $write = 0L; $reason = 0L; $dur = 0L
    $premium = [decimal]0; $nano = [decimal]0
    $models = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadLines($EventsPath)) {
        try { $e = $line | ConvertFrom-Json -Depth 30 } catch { continue }
        if ($e -isnot [pscustomobject] -or (Get-OptionalProperty $e 'type') -ne 'session.usage_record') { continue }
        $u = Get-OptionalProperty (Get-OptionalProperty $e 'data') 'usage'
        if ($u -isnot [pscustomobject]) { continue }
        $records++
        $prompt = [long](Get-OptionalProperty $u 'inputTokens' 0)
        $cr = [long](Get-OptionalProperty $u 'cacheReadTokens' 0)
        $cw = [long](Get-OptionalProperty $u 'cacheWriteTokens' 0)
        $in += [Math]::Max(0L, $prompt - $cr - $cw); $read += $cr; $write += $cw
        $out += [long](Get-OptionalProperty $u 'outputTokens' 0)
        $reason += [long](Get-OptionalProperty $u 'reasoningTokens' 0)
        $dur += [long](Get-OptionalProperty $u 'duration' 0)
        $premium += [decimal](Get-OptionalProperty $u 'cost' 0)
        $m = [string](Get-OptionalProperty $u 'model' ''); if ($m) { $models.Add($m) }
        $cu = Get-OptionalProperty $u 'copilotUsage'
        $n = Get-OptionalProperty $cu 'totalNanoAiu'
        if ($null -ne $n) { $nano += [decimal]$n; $nanoRecords++ }
    }
    if (-not $records) { return $null }
    New-AgentUsage -Source 'copilot-cli' -Models $models.ToArray() -InputTokens $in -OutputTokens $out -CacheReadTokens $read `
        -CacheCreationTokens $write -ReasoningTokens $reason -PremiumRequests ([double]$premium) -DurationMs $dur -ApiCalls $records `
        -AiCredits $(if ($nanoRecords -eq $records) { [math]::Round([double]($nano / 1000000000), 9) } else { $null })
}
