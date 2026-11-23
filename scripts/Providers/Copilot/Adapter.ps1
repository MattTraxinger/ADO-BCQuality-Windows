# Copilot CLI adapter for Invoke-AgentCall. Behavior moved unchanged from Invoke-BCQualityReview.ps1.
# Contract (every adapter): returns [pscustomobject]@{ text; retrieved; usage } where `retrieved` holds the repo-relative
# knowledge articles the HOST saw the agent read in full, and `usage` is the call's token/cost/model record from the
# CLI's own output (Get-CopilotUsage, shape in scripts/Metrics.ps1) or $null. Neither ever comes from the model.
Set-StrictMode -Version Latest

function Invoke-CopilotAgent {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Model,
        [string[]] $AddDirs = @(),
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $BCQualityRoot,
        [int] $TimeoutSeconds = 900
    )
    $psi = New-AgentProcessInfo -DefaultCommand 'copilot'
    foreach ($a in @('-p', $Prompt)) { $psi.ArgumentList.Add($a) }
    if ($Model) { foreach ($a in @('--model', $Model)) { $psi.ArgumentList.Add($a) } }
    foreach ($d in $AddDirs) { foreach ($a in @('--add-dir', $d)) { $psi.ArgumentList.Add($a) } }
    # Read-only agent: no shell, no writes, so PR content cannot reach the token in the environment (verify flag names).
    foreach ($a in @('--deny-tool', 'shell', '--deny-tool', 'write')) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $before = Get-CopilotSessionIds
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) { $proc.Kill($true); throw "Copilot call timed out after $TimeoutSeconds s." }
    if ($proc.ExitCode -ne 0) { throw "Copilot exited $($proc.ExitCode): $($stderr.Result)" }
    # Evidence of what was read comes from the one session this call created. Anything else fails closed:
    # no retrieved articles, so findings that cite knowledge are rejected by the gate.
    $new = @(Get-CopilotSessionIds | Where-Object { $_ -notin $before })
    $retrieved = @()
    $usage = $null
    if ($new.Count -eq 1) {
        $events = Join-Path (Get-CopilotStateDir) "$($new[0])/events.jsonl"
        if (Test-Path -LiteralPath $events) {
            $retrieved = @(Get-RetrievedArticlePaths -EventsPath $events -BCQualityRoot $BCQualityRoot)
            $usage = Get-CopilotUsage -EventsPath $events   # $null when the session has no usage records
            Write-Host "Copilot tool calls: $(Get-CopilotToolSummary -EventsPath $events)"
            Get-CopilotViewLog -EventsPath $events -BCQualityRoot $BCQualityRoot | ForEach-Object { Write-Host $_ }
        }
        else { Write-Host "##vso[task.logissue type=warning]No events.jsonl in session $($new[0]); no retrieval evidence for this call." }
    }
    else { Write-Host "##vso[task.logissue type=warning]Expected one new Copilot session, found $($new.Count); no retrieval evidence for this call." }
    Write-Host "Copilot call read $($retrieved.Count) knowledge article(s) in full."
    [pscustomobject]@{ text = $stdout.Result; retrieved = @($retrieved); usage = $usage }
}
