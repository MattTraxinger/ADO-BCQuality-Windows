BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\AgentProvider.ps1')   # loads Common and every provider folder
    $script:fixtures = Join-Path $PSScriptRoot '..\fixtures'
}

Describe 'Knowledge index slices' {
    BeforeAll {
        $script:root = Join-Path $TestDrive 'bcq'
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $rows = @(
            [ordered]@{ path = 'microsoft/knowledge/performance/a.md'; domain = 'performance'; keywords = @('k1', 'k2'); title = 'A'; layer = 'microsoft' }
            [ordered]@{ path = 'microsoft/knowledge/performance/b.md'; domain = 'performance'; keywords = @('k3'); title = 'B'; layer = 'microsoft' }
            [ordered]@{ path = 'community/knowledge/web services/c.md'; domain = 'web services!'; keywords = @(); title = 'C'; layer = 'community' }
        )
        [ordered]@{ version = 1; enabledLayers = @('microsoft', 'community'); articleCount = 3; sourceSnapshot = 'abc'; articles = $rows } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:root 'knowledge-index.json')
    }
    It 'writes one slice per domain with rows unchanged and a safe file name' {
        $d = @(Initialize-KnowledgeIndexSlices -BCQualityRoot $script:root)
        $d | Should -Be @('performance', 'web_services_')
        $s = Get-Content -LiteralPath (Join-Path $script:root 'knowledge-index-slices/performance.json') -Raw | ConvertFrom-Json -Depth 10
        $s.domain | Should -Be 'performance'; $s.articleCount | Should -Be 2; $s.sourceSnapshot | Should -Be 'abc'
        @($s.articles).Count | Should -Be 2
        $s.articles[0].path | Should -Be 'microsoft/knowledge/performance/a.md'
        @($s.articles[0].keywords) | Should -Be @('k1', 'k2')
    }
    It 'returns nothing when there is no index' {
        @(Initialize-KnowledgeIndexSlices -BCQualityRoot (Join-Path $TestDrive 'empty')).Count | Should -Be 0
    }
}

Describe 'Claude read scope' {
    It 'scopes read permission to a directory in both the Linux and Windows path forms' {
        Get-ClaudeReadRule '/home/vsts/work/1/client' | Should -Be 'Read(//home/vsts/work/1/client/**)'
        Get-ClaudeReadRule 'C:\work\bcq\' | Should -Be 'Read(/C:/work/bcq/**)'
    }
}

Describe 'Claude retrieval evidence' {
    BeforeAll {
        function Use($id, $path, $extra = @{}) {
            $in = @{ file_path = $path } + $extra
            (@{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = $id; name = 'Read'; input = $in }) } } | ConvertTo-Json -Depth 8 -Compress)
        }
        function Res($id, $file, [bool]$isError = $false) {
            $m = @{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = $id; content = 'x' }) } }
            if ($isError) { $m.message.content[0].is_error = $true }
            if ($file) { $m.tool_use_result = @{ type = 'text'; file = $file } }
            ($m | ConvertTo-Json -Depth 8 -Compress)
        }
        $full = @{ numLines = 3; startLine = 1; totalLines = 3 }
        $k = 'C:\bcq\microsoft\knowledge\x'
        $lines = @(
            (Use 'a' "$k\full.md");     (Res 'a' $full)
            (Use 'b' "$k\partial.md" @{ offset = 0; limit = 1 }); (Res 'b' @{ numLines = 1; startLine = 0; totalLines = 3 })
            (Use 'c' "$k\denied.md");   (Res 'c' $null $true)
            (Use 'd' "$k\truncated.md"); (Res 'd' @{ numLines = 2000; startLine = 1; totalLines = 3000 })
            (Use 'e' "$k\nocounts.md"); (Res 'e' $null)
            (Use 'f' 'C:\bcq\skills\do.md'); (Res 'f' $full)
            (Use 'g' 'C:\other\knowledge\y.md'); (Res 'g' $full)
            (Use 'h' "$k\noresult.md")
            '{"type":"system","subtype":"init"}'
            'not json'
            '{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.0123,"num_turns":4,"duration_ms":900,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}'
        )
        $script:cev = Join-Path $TestDrive 'claude-events.jsonl'
        Set-Content -LiteralPath $script:cev -Value $lines
    }
    It 'counts only successful, verified-complete reads of knowledge articles under the BCQuality root' {
        @(Get-ClaudeRetrievedArticlePaths -EventsPath $script:cev -BCQualityRoot 'C:\bcq') | Should -Be @('microsoft/knowledge/x/full.md')
    }
    It 'returns nothing for an empty stream' {
        $empty = Join-Path $TestDrive 'claude-empty.jsonl'; Set-Content -LiteralPath $empty -Value ''
        @(Get-ClaudeRetrievedArticlePaths -EventsPath $empty -BCQualityRoot 'C:\bcq').Count | Should -Be 0
    }
    It 'summarizes tool calls, including a call that never returned' {
        Get-ClaudeToolSummary -EventsPath $script:cev | Should -Match 'Read:noresult=1'
        Get-ClaudeToolSummary -EventsPath $script:cev | Should -Match 'Read:failed=1'
    }
    It 'explains failed calls with the target and the error text' {
        $log = @(Get-ClaudeFailureLog -EventsPath $script:cev)
        $log.Count | Should -BeGreaterThan 0
        ($log -join "`n") | Should -Match 'failed Read C:\\bcq\\microsoft\\knowledge\\x\\denied.md'
    }
    It 'turns stream events into short progress lines' {
        $root = 'C:\bcq'
        function Ev($json) { $json | ConvertFrom-Json -Depth 10 }
        Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"system","subtype":"init","model":"m1","apiKeySource":"ANTHROPIC_API_KEY","claude_code_version":"2.1.187","tools":["Read","Glob"]}') -BCQualityRoot $root |
            Should -Match 'model=m1.*key source=ANTHROPIC_API_KEY.*tools=Read,Glob'
        Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Read","input":{"file_path":"C:\\bcq\\microsoft\\knowledge\\x\\a.md"}}]}}') -BCQualityRoot $root |
            Should -Be 'Read <bcquality>/microsoft/knowledge/x/a.md'
        Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Read","input":{"file_path":"C:\\x\\f.al","offset":0,"limit":5}}]}}') -BCQualityRoot $root |
            Should -Match 'partial: offset,limit'
        Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":4000,"error_status":429}') -BCQualityRoot $root |
            Should -Match 'API retry.*attempt=2.*retry_delay_ms=4000.*error_status=429'
        Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour"}}') -BCQualityRoot $root |
            Should -Match 'rate limit: status=rejected'
    }
    It 'prints nothing for an allowed rate limit, a user event or prose' {
        function Ev($json) { $json | ConvertFrom-Json -Depth 10 }
        @(Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}')).Count | Should -Be 0
        @(Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a"}]}}')).Count | Should -Be 0
        @(Get-ClaudeLiveLine -StreamEvent (Ev '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}')).Count | Should -Be 0
    }
    It 'reads usage and cost from the result event' {
        $u = Get-ClaudeUsage (Get-ClaudeResultEvent -EventsPath $script:cev)
        $u.inputTokens | Should -Be 10; $u.outputTokens | Should -Be 20
        $u.cacheReadTokens | Should -Be 30; $u.cacheCreationTokens | Should -Be 40
        $u.costUsd | Should -Be 0.0123; $u.turns | Should -Be 4
    }
    It 'has no usage when the stream has no result event' {
        $empty = Join-Path $TestDrive 'claude-empty2.jsonl'; Set-Content -LiteralPath $empty -Value ''
        Get-ClaudeUsage (Get-ClaudeResultEvent -EventsPath $empty) | Should -BeNullOrEmpty
    }
}

# Real Claude Code 2.1.187 streams, trimmed and stripped of local paths and usernames (tests/fixtures).
# These guard against the CLI changing its event shape, which hand-built events cannot do.
Describe 'Claude stream fixtures (real captures)' {
    Context 'a successful call with one denied read' {
        BeforeAll { $script:f = Join-Path $script:fixtures 'claude-stream-success.jsonl' }
        It 'records the one knowledge article read in full' {
            @(Get-ClaudeRetrievedArticlePaths -EventsPath $script:f -BCQualityRoot 'C:/bcq-fixture') | Should -Be @('microsoft/knowledge/demo/a.md')
        }
        It 'counts the denied read as failed and explains it' {
            Get-ClaudeToolSummary -EventsPath $script:f | Should -Be 'Read:failed=1, Read:ok=2'
            (Get-ClaudeFailureLog -EventsPath $script:f) -join "`n" | Should -Match 'failed Read C:/elsewhere/package.json :: Permission to use Read has been denied'
        }
        It 'finds a successful result with usage' {
            $r = Get-ClaudeResultEvent -EventsPath $script:f
            $r.subtype | Should -Be 'success'; $r.is_error | Should -BeFalse
            $u = Get-ClaudeUsage $r
            $u.inputTokens | Should -Be 6; $u.outputTokens | Should -Be 436; $u.turns | Should -Be 4
            [math]::Round($u.costUsd, 4) | Should -Be 0.0297
        }
        It 'produces a session line and one line per tool call' {
            $out = @(Read-ClaudeEvents $script:f | ForEach-Object { Get-ClaudeLiveLine -StreamEvent $_ -BCQualityRoot 'C:/bcq-fixture' })
            $out[0] | Should -Match '^session: model=claude-sonnet.*tools=Glob,Grep,Read'
            @($out | Where-Object { $_ -match '^Read ' }).Count | Should -Be 3
            $out | Should -Contain 'Read <bcquality>/microsoft/knowledge/demo/a.md'
        }
    }
    Context 'a call that read a file in part and ended on an error result' {
        BeforeAll { $script:f = Join-Path $script:fixtures 'claude-stream-partial.jsonl' }
        It 'does not count the partial read, but counts both full reads' {
            @(Get-ClaudeRetrievedArticlePaths -EventsPath $script:f -BCQualityRoot 'C:/bcq-fixture') |
                Should -Be @('microsoft/knowledge/demo/a.md', 'microsoft/knowledge/demo/big.md')
            (Get-ClaudeReadLog -EventsPath $script:f -BCQualityRoot 'C:/bcq-fixture') -join "`n" | Should -Match 'partial/unverified microsoft/knowledge/demo/a.md'
        }
        It 'shows the range arguments on the partial read' {
            $out = @(Read-ClaudeEvents $script:f | ForEach-Object { Get-ClaudeLiveLine -StreamEvent $_ -BCQualityRoot 'C:/bcq-fixture' })
            $out | Should -Contain 'Read <bcquality>/microsoft/knowledge/demo/a.md (partial: offset,limit)'
        }
        It 'reports an error result so the adapter treats the call as failed' {
            $r = Get-ClaudeResultEvent -EventsPath $script:f
            $r.is_error | Should -BeTrue
            $r.subtype | Should -Be 'error_max_budget_usd'
        }
    }
    It 'contains no local paths or usernames' {
        foreach ($name in 'claude-stream-success.jsonl', 'claude-stream-partial.jsonl') {
            $text = Get-Content -LiteralPath (Join-Path $script:fixtures $name) -Raw
            $text | Should -Not -Match 'AppData|C:[\\/]+Users|/home/[^/]+/|/Users/[^/]+/'
        }
    }
}

Describe 'Claude adapter prompt-cache arguments (fake CLI)' {
    BeforeAll {
        # A stand-in for `claude` that records its arguments and working directory, then emits a minimal stream.
        $script:fake = Join-Path $TestDrive 'fake-claude.js'
        $script:log = Join-Path $TestDrive 'fake-claude.log'
        Set-Content -LiteralPath $script:fake -Value @'
const fs = require('fs');
fs.appendFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd() }) + '\n');
console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: '{}', usage: { input_tokens: 1, output_tokens: 1 } }));
'@
        $script:saved = @{ path = $env:BCQ_AGENT_PATH; key = $env:ANTHROPIC_API_KEY; log = $env:FAKE_CLAUDE_LOG }
        $env:BCQ_AGENT_PATH = $script:fake; $env:ANTHROPIC_API_KEY = 'test-key-not-real'; $env:FAKE_CLAUDE_LOG = $script:log
        $script:shared = Join-Path $TestDrive 'shared.md'; Set-Content -LiteralPath $script:shared 'shared text'
        function Invoke-Fake($shared) {
            $p = @{ Prompt = 'p'; Model = 'm'; AddDirs = @($TestDrive); WorkingDirectory = $TestDrive; BCQualityRoot = $TestDrive; TimeoutSeconds = 60 }
            if ($shared) { $p.SharedContextPath = $shared }
            $null = Invoke-ClaudeAgent @p 6>$null
            @(Get-Content -LiteralPath $script:log | ForEach-Object { $_ | ConvertFrom-Json })[-1]
        }
    }
    AfterAll {
        $env:BCQ_AGENT_PATH = $script:saved.path; $env:ANTHROPIC_API_KEY = $script:saved.key; $env:FAKE_CLAUDE_LOG = $script:saved.log
    }
    It 'appends the shared file to the system prompt and moves per-machine sections out of it' {
        $c = Invoke-Fake $script:shared
        $c.argv | Should -Contain '--exclude-dynamic-system-prompt-sections'
        $i = [array]::IndexOf($c.argv, '--append-system-prompt-file')
        $i | Should -BeGreaterThan -1
        $c.argv[$i + 1] | Should -Be $script:shared
        $c.argv[0] | Should -Be '-p'   # the prompt still comes first
    }
    It 'sends no shared-file argument when none is given' {
        $c = Invoke-Fake $null
        $c.argv | Should -Not -Contain '--append-system-prompt-file'
        $c.argv | Should -Contain '--exclude-dynamic-system-prompt-sections'
    }
    It 'uses the same working directory for every call, outside the PR checkout' {
        $a = Invoke-Fake $script:shared; $b = Invoke-Fake $script:shared
        $a.cwd | Should -Be $b.cwd
        $a.cwd | Should -Not -BeLike "$TestDrive*"
        (Split-Path $a.cwd -Leaf) | Should -Be 'bcq-claude-cwd'
    }
    It 'cleans up the per-call event folder' {
        $null = Invoke-Fake $script:shared
        @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'bcq-claude-events-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'Claude adapter authentication (fake CLI)' {
    BeforeAll {
        # A stand-in for `claude` that records whether it was given an API key, then emits a minimal stream.
        $script:fake = Join-Path $TestDrive 'fake-claude-auth.js'
        $script:log = Join-Path $TestDrive 'fake-claude-auth.log'
        Set-Content -LiteralPath $script:fake -Value @'
const fs = require('fs');
fs.appendFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ hasKey: !!process.env.ANTHROPIC_API_KEY }) + '\n');
console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: '{}', usage: { input_tokens: 1, output_tokens: 1 } }));
'@
        $script:saved = @{ path = $env:BCQ_AGENT_PATH; key = $env:ANTHROPIC_API_KEY; log = $env:FAKE_CLAUDE_LOG; auth = $env:BCQ_CLAUDE_AUTH; tf = $env:TF_BUILD }
        $env:BCQ_AGENT_PATH = $script:fake; $env:FAKE_CLAUDE_LOG = $script:log
        function Invoke-Fake {
            $p = @{ Prompt = 'p'; Model = 'm'; AddDirs = @($TestDrive); WorkingDirectory = $TestDrive; BCQualityRoot = $TestDrive; TimeoutSeconds = 60 }
            $null = Invoke-ClaudeAgent @p 6>$null
            @(Get-Content -LiteralPath $script:log | ForEach-Object { $_ | ConvertFrom-Json })[-1]
        }
    }
    BeforeEach { $env:TF_BUILD = $null; $env:BCQ_CLAUDE_AUTH = $null; $env:ANTHROPIC_API_KEY = $null }
    AfterAll {
        $env:BCQ_AGENT_PATH = $script:saved.path; $env:ANTHROPIC_API_KEY = $script:saved.key; $env:FAKE_CLAUDE_LOG = $script:saved.log
        $env:BCQ_CLAUDE_AUTH = $script:saved.auth; $env:TF_BUILD = $script:saved.tf
    }
    It 'passes the API key to the CLI by default' {
        $env:ANTHROPIC_API_KEY = 'test-key-not-real'
        (Invoke-Fake).hasKey | Should -BeTrue
    }
    It 'refuses to start without a key when no subscription login was asked for' {
        { Invoke-Fake } | Should -Throw '*ANTHROPIC_API_KEY is not set*BCQ_CLAUDE_AUTH=subscription*'
    }
    It 'uses the Claude Code login with BCQ_CLAUDE_AUTH=subscription and keeps a key out of the CLI environment' {
        $env:BCQ_CLAUDE_AUTH = 'subscription'
        (Invoke-Fake).hasKey | Should -BeFalse
        $env:ANTHROPIC_API_KEY = 'test-key-not-real'
        (Invoke-Fake).hasKey | Should -BeFalse
        $env:ANTHROPIC_API_KEY | Should -Be 'test-key-not-real'   # only the child's environment is changed
    }
    It 'refuses the subscription login inside a pipeline' {
        $env:BCQ_CLAUDE_AUTH = 'subscription'; $env:TF_BUILD = 'True'
        { Invoke-Fake } | Should -Throw '*refused in a pipeline*'
    }
    It 'rejects an unknown authentication mode instead of guessing' {
        $env:BCQ_CLAUDE_AUTH = 'oauth'
        { Invoke-Fake } | Should -Throw "*BCQ_CLAUDE_AUTH='oauth' is not valid*"
    }
}
