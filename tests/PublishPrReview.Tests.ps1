# Runs the real Publish-PrReview.ps1 against a small fake Azure DevOps server (HttpListener on localhost), so the
# glue between the plan, the existing threads and the REST calls is exercised, not only the helper functions.
BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    $script:work = Join-Path $TestDrive 'publish'
    New-Item -ItemType Directory -Path $script:work -Force | Out-Null

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $listener.Start()
    $script:port = $listener.LocalEndpoint.Port; $listener.Stop()

    function Add-Prop { param($Table, $Name, $Value) $Table[$Name] = @{ '$type' = 'System.String'; '$value' = $Value } }
    function New-ExistingThread {
        param([string] $Author, [string] $Fingerprint, [string] $Rule, [string] $Path, [int] $Line)
        $props = [ordered]@{}
        Add-Prop $props 'BCQuality.Fingerprint' $Fingerprint
        Add-Prop $props 'BCQuality.Kind' 'finding'
        if ($Rule) { Add-Prop $props 'BCQuality.Rule' $Rule }
        [ordered]@{ id = 1; comments = @(@{ author = @{ id = $Author } }); properties = $props
            threadContext = @{ filePath = $Path; rightFileStart = @{ line = $Line; offset = 1 } } }
    }
    $existing = @(
        (New-ExistingThread -Author 'me' -Fingerprint 'fpOld' -Rule 'r1' -Path '/src/x.al' -Line 10)        # ours, with a rule
        (New-ExistingThread -Author 'someone-else' -Fingerprint 'fpTheirs' -Rule 'r3' -Path '/src/x.al' -Line 50)   # not ours
        (New-ExistingThread -Author 'me' -Fingerprint 'fpKnown' -Rule '' -Path '/src/x.al' -Line 70)         # ours, from before rules were recorded
    )
    [ordered]@{ value = $existing } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $script:work 'threads.json')

    $server = {
        param($Port, $Dir)
        $l = [System.Net.HttpListener]::new(); $l.Prefixes.Add("http://localhost:$Port/"); $l.Start()
        while ($l.IsListening) {
            $c = $l.GetContext(); $req = $c.Request; $path = $req.Url.AbsolutePath
            $body = if ($req.HasEntityBody) { [System.IO.StreamReader]::new($req.InputStream).ReadToEnd() } else { '' }
            $out = '{}'
            if ($req.HttpMethod -eq 'GET' -and $path -like '*/connectionData') { $out = '{"authenticatedUser":{"id":"me"}}' }
            elseif ($req.HttpMethod -eq 'GET' -and $path -like '*/threads') { $out = Get-Content -LiteralPath (Join-Path $Dir 'threads.json') -Raw }
            elseif ($req.HttpMethod -eq 'GET' -and $path -like '*/pullRequests/7') { $out = '{"lastMergeSourceCommit":{"commitId":"HEAD"}}' }
            elseif ($req.HttpMethod -eq 'POST' -and $path -like '*/threads') { Add-Content -LiteralPath (Join-Path $Dir 'posted.jsonl') -Value ($body -replace "`r?`n", ' ') }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
            $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($bytes, 0, $bytes.Length); $c.Response.Close()
        }
    }
    $script:job = Start-Job -ScriptBlock $server -ArgumentList $script:port, $script:work
    $ready = $false
    for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
        try { $null = Invoke-RestMethod "http://localhost:$($script:port)/_apis/connectionData"; $ready = $true } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw 'The fake Azure DevOps server did not start.' }

    function New-PlanItem {
        param([string] $Fingerprint, [string] $Rule, [int] $Line, [string] $Content = 'finding', [int] $EndLine = 0, [int] $EndOffset = 0)
        $i = [ordered]@{ fingerprint = $Fingerprint; filePath = 'src/x.al'; line = $Line; rule = $Rule; content = $Content }
        if ($EndLine) { $i.endLine = $EndLine; $i.endOffset = $EndOffset }
        $i
    }
    $items = @(
        (New-PlanItem 'fpA' 'r1' 12)                                       # same rule 2 lines from our thread: near-duplicate
        (New-PlanItem 'fpB' 'r2' 11)                                       # different rule: posted
        (New-PlanItem 'fpC' 'r1' 30)                                       # same rule but far away: posted
        (New-PlanItem 'fpKnown' 'r9' 70)                                   # fingerprint already on a thread of ours: skipped as known
        (New-PlanItem 'fpS' 'r4' 20 -EndLine 22 -EndOffset 18 -Content 'with suggestion')   # span anchor and rule carried through
        (New-PlanItem 'fpF' 'r3' 50)                                       # same rule/line as someone else's thread: posted
    )
    $plan = [ordered]@{ reviewedHeadSha = 'HEAD'; outcome = 'completed'; mode = 'advisory'; statusState = $null; nearDuplicateLines = 2
        summary = [ordered]@{ fingerprint = 'sumfp'; content = 'summary' }; items = $items }
    $planPath = Join-Path $script:work 'plan.json'
    $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath
    $ctxPath = Join-Path $script:work 'context.json'
    [ordered]@{ headSha = 'HEAD'; settings = [ordered]@{ mode = 'advisory' } } | ConvertTo-Json | Set-Content -LiteralPath $ctxPath

    function Invoke-Publish {
        param([string] $PlanPath)
        $env:SYSTEM_ACCESSTOKEN = 'token'
        Remove-Item -LiteralPath (Join-Path $script:work 'posted.jsonl') -ErrorAction SilentlyContinue
        $out = & pwsh -NoProfile -File (Join-Path $script:scripts 'Publish-PrReview.ps1') -ContextPath $ctxPath -PlanPath $PlanPath `
            -CollectionUri "http://localhost:$($script:port)/" -Project 'p' -RepositoryId 'r' -PullRequestId 7 2>&1 | Out-String
        $posted = if (Test-Path (Join-Path $script:work 'posted.jsonl')) { @(Get-Content (Join-Path $script:work 'posted.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 }) } else { @() }
        [pscustomobject]@{ output = $out; exitCode = $LASTEXITCODE; posted = $posted }
    }
    $script:run = Invoke-Publish -PlanPath $planPath
    function Get-Fp { param($Thread) $Thread.properties.'BCQuality.Fingerprint'.'$value' }
}

AfterAll {
    if ($script:job) { Stop-Job $script:job -ErrorAction SilentlyContinue; Remove-Job $script:job -Force -ErrorAction SilentlyContinue }
}

Describe 'Publish-PrReview against a fake Azure DevOps' {
    It 'finishes cleanly' {
        $script:run.exitCode | Should -Be 0
    }
    It 'skips a finding that is a near-duplicate of an earlier thread of ours for the same rule, and says so' {
        $fps = @($script:run.posted | ForEach-Object { Get-Fp $_ })
        $fps | Should -Not -Contain 'fpA'
        $script:run.output | Should -BeLike '*Skipping near-duplicate of an earlier thread: src/x.al:12 (r1)*'
        $script:run.output | Should -BeLike '*Published 5 new thread(s); skipped 1 near-duplicate(s); summary thread=active.*'   # four findings and the summary
        @($script:run.posted).Count | Should -Be 5
    }
    It 'still posts a different rule nearby, the same rule far away, and a rule that only someone else posted' {
        $fps = @($script:run.posted | ForEach-Object { Get-Fp $_ })
        $fps | Should -Contain 'fpB'
        $fps | Should -Contain 'fpC'
        $fps | Should -Contain 'fpF'
    }
    It 'skips a finding whose fingerprint is already on a thread of ours, without counting it as a near-duplicate' {
        @($script:run.posted | ForEach-Object { Get-Fp $_ }) | Should -Not -Contain 'fpKnown'
    }
    It 'records the rule on every posted finding thread and anchors a suggestion over its span' {
        $b = $script:run.posted | Where-Object { (Get-Fp $_) -eq 'fpB' }
        $b.properties.'BCQuality.Rule'.'$value' | Should -Be 'r2'
        $s = $script:run.posted | Where-Object { (Get-Fp $_) -eq 'fpS' }
        $s.properties.'BCQuality.Rule'.'$value' | Should -Be 'r4'
        $s.threadContext.rightFileStart.line | Should -Be 20
        $s.threadContext.rightFileEnd.line | Should -Be 22
        $s.threadContext.rightFileEnd.offset | Should -Be 18
    }
    It 'posts the summary thread without a rule' {
        $sum = $script:run.posted | Where-Object { (Get-Fp $_) -eq 'sumfp' }
        $sum | Should -Not -BeNullOrEmpty
        $sum.properties.PSObject.Properties['BCQuality.Rule'] | Should -BeNullOrEmpty
    }
    It 'does not suppress anything when the plan has no tolerance (a plan from before this setting)' {
        $old = Get-Content (Join-Path $script:work 'plan.json') -Raw | ConvertFrom-Json -Depth 20
        $old.PSObject.Properties.Remove('nearDuplicateLines')
        $oldPath = Join-Path $script:work 'plan-old.json'
        $old | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $oldPath
        $r = Invoke-Publish -PlanPath $oldPath
        @($r.posted | ForEach-Object { Get-Fp $_ }) | Should -Contain 'fpA'
    }
}

Describe 'Publish-PrReview log line' {
    BeforeAll {
        function Invoke-LogPlan {
            param([string] $Name, [string] $Mode = 'advisory', [string] $StatusState, [string] $SummaryFingerprint = 'sumfp2', [string] $ThreadStatus)
            $summary = [ordered]@{ fingerprint = $SummaryFingerprint; content = 'summary' }
            if ($ThreadStatus) { $summary.threadStatus = $ThreadStatus }
            $p = [ordered]@{ reviewedHeadSha = 'HEAD'; outcome = 'completed'; mode = $Mode; statusState = $(if ($StatusState) { $StatusState } else { $null })
                summary = $summary; items = @() }
            $path = Join-Path $script:work "plan-$Name.json"
            $p | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
            Invoke-Publish -PlanPath $path
        }
    }
    It 'says the summary thread was posted closed, with no PR status in advisory mode' {
        $r = Invoke-LogPlan 'closed' -ThreadStatus 'closed'
        $r.output | Should -BeLike '*Published 1 new thread(s); summary thread=closed.*'
        $r.output | Should -Not -BeLike '*status=.*'
    }
    It 'says the summary was already posted when its fingerprint is on a thread of ours' {
        $r = Invoke-LogPlan 'known' -SummaryFingerprint 'fpKnown' -ThreadStatus 'closed'
        @($r.posted).Count | Should -Be 0
        $r.output | Should -BeLike '*Published 0 new thread(s); summary already posted.*'
    }
    It 'adds the PR status in status mode' {
        $r = Invoke-LogPlan 'status' -Mode 'status' -StatusState 'failed' -ThreadStatus 'active'
        $r.output | Should -BeLike '*Published 1 new thread(s); summary thread=active; PR status=failed.*'
    }
}
