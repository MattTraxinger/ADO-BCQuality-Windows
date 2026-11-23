BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\scripts'
    foreach ($f in 'Common', 'FindingPlacement', 'FindingDeduplication', 'AzureDevOps', 'PublishPlan') { . (Join-Path $scripts "$f.ps1") }
}

Describe 'Placement' {
    BeforeAll {
        $diff = "diff --git a/x.al b/x.al`n--- a/x.al`n+++ b/x.al`n@@ -1,3 +10,4 @@`n a`n+b`n c`n d`n@@ -40 +50 @@`n-x`n+y"
        $script:ranges = @{ 'src/x.al' = (Get-DiffRightRanges -DiffText $diff) }
        function F($file, $line) { [pscustomobject]@{ location = [pscustomobject]@{ file = $file; line = $line } } }
    }
    It 'parses hunk ranges on the new side' {
        $r = Get-DiffRightRanges -DiffText "@@ -1,3 +10,4 @@`n@@ -40 +50 @@"
        $r[0].start | Should -Be 10; $r[0].end | Should -Be 13
        $r[1].start | Should -Be 50; $r[1].end | Should -Be 50
    }
    It 'places a line inside a hunk inline' {
        (Get-FindingPlacement -Finding (F 'src/x.al' 11) -DiffRangesByFile $ranges).kind | Should -Be 'inline'
    }
    It 'moves a line outside the diff to the summary' {
        $p = Get-FindingPlacement -Finding (F 'src/x.al' 30) -DiffRangesByFile $ranges
        $p.kind | Should -Be 'summary'; $p.reason | Should -Be 'line-outside-diff'
    }
    It 'moves a file outside the diff to the summary' {
        (Get-FindingPlacement -Finding (F 'src/y.al' 11) -DiffRangesByFile $ranges).reason | Should -Be 'file-not-in-diff'
    }
    It 'moves a finding without a location to the summary' {
        (Get-FindingPlacement -Finding ([pscustomobject]@{ id = 'a' }) -DiffRangesByFile $ranges).reason | Should -Be 'no-location'
    }
    It 'normalizes a leading slash and backslashes' {
        (Get-FindingPlacement -Finding (F '\src\x.al' 11) -DiffRangesByFile $ranges).kind | Should -Be 'inline'
    }
}

Describe 'Deduplication' {
    It 'gives the same fingerprint regardless of whitespace' {
        $a = Get-NormalizedContext -SourceLines @('  if  x then', 'y') -Line 1
        $b = Get-NormalizedContext -SourceLines @('if x then', 'y') -Line 1
        (Get-FindingFingerprint 'k' 'a.al' $a) | Should -Be (Get-FindingFingerprint 'k' 'a.al' $b)
    }
    It 'differs by knowledge id, file and context' {
        $base = Get-FindingFingerprint 'k' 'a.al' 'c'
        Get-FindingFingerprint 'k2' 'a.al' 'c' | Should -Not -Be $base
        Get-FindingFingerprint 'k' 'b.al' 'c' | Should -Not -Be $base
        Get-FindingFingerprint 'k' 'a.al' 'd' | Should -Not -Be $base
    }
    It 'trusts only fingerprints from threads by our identity' {
        function T($author, $fp) {
            [pscustomobject]@{
                properties = [pscustomobject]@{ 'BCQuality.Fingerprint' = [pscustomobject]@{ '$value' = $fp } }
                comments   = @([pscustomobject]@{ author = [pscustomobject]@{ id = $author } })
            }
        }
        $known = Get-ExistingFingerprints -Threads @((T 'bot' 'mine'), (T 'someone-else' 'forged')) -TrustedAuthorId 'bot'
        $known.Contains('mine') | Should -BeTrue
        $known.Contains('forged') | Should -BeFalse
    }
    It 'ignores threads without properties' {
        $known = Get-ExistingFingerprints -Threads @([pscustomobject]@{ comments = @() }) -TrustedAuthorId 'bot'
        $known.Count | Should -Be 0
    }
}

Describe 'Current-head check' {
    It 'passes when the head is unchanged' {
        Assert-PrHeadUnchanged -ReviewedSha 'ABC' -GetCurrentHead { 'abc' } | Should -BeTrue
    }
    It 'fails when a push moved the head' {
        Assert-PrHeadUnchanged -ReviewedSha 'abc' -GetCurrentHead { 'def' } | Should -BeFalse
    }
}

Describe 'Thread body' {
    It 'anchors a finding to the right side of its file' {
        $b = New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -FilePath 'src/x.al' -Line 12
        $b.threadContext.filePath | Should -Be '/src/x.al'
        $b.threadContext.rightFileStart.line | Should -Be 12
        $b.properties['BCQuality.Fingerprint']['$value'] | Should -Be 'fp'
    }
    It 'has no file context for a summary thread' {
        (New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -Kind summary).Contains('threadContext') | Should -BeFalse
    }
    It 'is active by default and closed on request' {
        (New-AdoThreadBody -Content 'm' -Fingerprint 'fp').status | Should -Be 1
        (New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -Kind summary -Status closed).status | Should -Be 4
        { New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -Status fixed } | Should -Throw
    }
}

Describe 'Summary thread status' {
    It 'closes a completed review with no findings' {
        Get-SummaryThreadStatus -Outcome 'completed' -Counts (Get-SeverityCounts -Findings @()) | Should -Be 'closed'
    }
    It 'keeps a completed review with any finding active, info included' {
        Get-SummaryThreadStatus -Outcome 'completed' -Counts (Get-SeverityCounts -Findings @([pscustomobject]@{ severity = 'info' })) | Should -Be 'active'
    }
    It 'closes a review that did not apply' {
        foreach ($o in 'skipped', 'not-applicable', 'no-knowledge') { Get-SummaryThreadStatus -Outcome $o -Counts $null | Should -Be 'closed' }
    }
    It 'keeps partial and failed active, even with no findings' {
        $none = Get-SeverityCounts -Findings @()
        Get-SummaryThreadStatus -Outcome 'partial' -Counts $none | Should -Be 'active'
        Get-SummaryThreadStatus -Outcome 'failed' -Counts $null | Should -Be 'active'
    }
    It 'keeps a completed review without counts active' {
        Get-SummaryThreadStatus -Outcome 'completed' -Counts $null | Should -Be 'active'
    }
}

Describe 'Publish plan' {
    It 'formats a finding that has no references or confidence' {
        $f = [pscustomobject]@{ severity = 'minor'; message = 'm' }
        { New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://x' } | Should -Not -Throw
    }
    It 'never reports partial or failed as succeeded' {
        Get-StatusState -Outcome 'partial' -Findings @() | Should -Be 'failed'
        Get-StatusState -Outcome 'failed' -Findings @() | Should -Be 'failed'
        Get-StatusState -Outcome 'completed' -Findings @() | Should -Be 'succeeded'
        Get-StatusState -Outcome 'completed' -Findings @([pscustomobject]@{ severity = 'blocker' }) | Should -Be 'failed'
        Get-StatusState -Outcome 'skipped' -Findings @() | Should -Be 'notApplicable'
    }
    It 'states partial and failed in the first line' {
        (New-SummaryContent -Outcome 'partial' -Reason 'r' -HeadSha 'h' -Domains @()) -split "`n" | Select-Object -First 1 | Should -Match 'PARTIAL'
        (New-SummaryContent -Outcome 'failed' -Reason 'r' -HeadSha 'h' -Domains @()) -split "`n" | Select-Object -First 1 | Should -Match 'FAILED'
    }
    It 'labels agent findings advisory and links knowledge-backed ones' {
        $agent = [pscustomobject]@{ severity = 'minor'; confidence = 'low'; message = 'm'; references = @() }
        New-FindingContent -Finding $agent -KnowledgeBaseUrl 'https://x/blob/c' | Should -Match 'Advisory'
        $known = [pscustomobject]@{ severity = 'major'; confidence = 'high'; message = 'm'; references = @([pscustomobject]@{ path = 'microsoft/a.md' }) }
        New-FindingContent -Finding $known -KnowledgeBaseUrl 'https://x/blob/c' | Should -Match 'https://x/blob/c/microsoft/a.md'
    }
    It 'gives each severity its own marker and a neutral one to anything else' {
        $badge = @{ blocker = 0x1F534; major = 0x1F7E0; minor = 0x1F7E1; info = 0x1F535 }
        foreach ($s in $badge.Keys) { Get-SeverityBadge $s | Should -Be ([char]::ConvertFromUtf32($badge[$s])) }
        Get-SeverityBadge 'unknown' | Should -Be ([char]::ConvertFromUtf32(0x26AA))
        Get-SeverityBadge '' | Should -Be ([char]::ConvertFromUtf32(0x26AA))
        @('blocker', 'major', 'minor', 'info', 'other' | ForEach-Object { Get-SeverityBadge $_ } | Select-Object -Unique).Count | Should -Be 5
    }
    It 'starts the comment with the severity badge, the severity and the confidence' {
        $f = [pscustomobject]@{ severity = 'major'; confidence = 'high'; message = 'MSG'; references = @([pscustomobject]@{ path = 'microsoft/a.md' }) }
        $first = (New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://x/blob/c') -split "`n" | Select-Object -First 1
        $first | Should -Be "$([char]::ConvertFromUtf32(0x1F7E0)) **MAJOR** · confidence: high"
    }
    It 'links the one article a finding cites on a single line' {
        $f = [pscustomobject]@{ severity = 'minor'; confidence = 'high'; message = 'm'; references = @([pscustomobject]@{ path = 'microsoft/a.md'; sha = ('a' * 40) }) }
        $lines = (New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://x/blob/c/') -split "`n"
        $lines | Should -Contain 'Knowledge: [microsoft/a.md](https://x/blob/c/microsoft/a.md)'
    }
    It 'links every article a finding cites, in order, once each' {
        $refs = @('microsoft/a.md', 'community/b.md', 'microsoft/a.md', '/microsoft/c.md', '') | ForEach-Object { [pscustomobject]@{ path = $_ } }
        $f = [pscustomobject]@{ severity = 'major'; confidence = 'high'; message = 'm'; references = $refs }
        $c = New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://x/blob/c'
        $links = @($c -split "`n" | Where-Object { $_.StartsWith('- [') })
        $links | Should -Be @('- [microsoft/a.md](https://x/blob/c/microsoft/a.md)', '- [community/b.md](https://x/blob/c/community/b.md)', '- [microsoft/c.md](https://x/blob/c/microsoft/c.md)')
        ($c -split "`n") | Should -Contain 'Knowledge:'
        $c | Should -Not -Match 'Advisory'
    }
    It 'escapes characters that would end the link early' {
        $f = [pscustomobject]@{ severity = 'minor'; confidence = 'high'; message = 'm'; references = @([pscustomobject]@{ path = 'microsoft/a [b] (c).md' }) }
        $c = New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://x/blob/c'
        $c | Should -Match ([regex]::Escape('[microsoft/a \[b\] (c).md](https://x/blob/c/microsoft/a%20[b]%20%28c%29.md)'))
    }
    It 'names the articles as plain code when there is no base URL, and does not call that advisory' {
        $f = [pscustomobject]@{ severity = 'minor'; confidence = 'high'; message = 'm'; references = @([pscustomobject]@{ path = 'microsoft/a.md' }, [pscustomobject]@{ path = 'microsoft/b.md' }) }
        $c = New-FindingContent -Finding $f
        ($c -split "`n") | Should -Contain '- `microsoft/a.md`'
        ($c -split "`n") | Should -Contain '- `microsoft/b.md`'
        $c | Should -Not -Match 'Advisory'
    }
    It 'has no Knowledge line for an agent finding, only the advisory note' {
        $f = [pscustomobject]@{ severity = 'info'; confidence = 'low'; message = 'm'; references = @() }
        $c = New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://x/blob/c'
        $c | Should -Match 'Advisory'
        $c | Should -Not -Match 'Knowledge:'
    }
    It 'reads references from a real finding as the pipeline loads it from JSON' {
        $json = '{"id":"k","severity":"blocker","message":"m","confidence":"high","references":[{"path":"microsoft/knowledge/performance/use-isempty-for-existence-check.md","sha":"0123456789abcdef0123456789abcdef01234567"}]}'
        $f = $json | ConvertFrom-Json -Depth 10
        $c = New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://github.com/microsoft/BCQuality/blob/abc123'
        ($c -split "`n")[0] | Should -Be "$([char]::ConvertFromUtf32(0x1F534)) **BLOCKER** · confidence: high"
        $c | Should -Match ([regex]::Escape('[microsoft/knowledge/performance/use-isempty-for-existence-check.md](https://github.com/microsoft/BCQuality/blob/abc123/microsoft/knowledge/performance/use-isempty-for-existence-check.md)'))
    }
    It 'puts the badge on findings listed in the summary because they have no changed line' {
        $s = New-SummaryContent -Outcome 'completed' -HeadSha 'h' -Domains @() -SummaryFindings @([pscustomobject]@{ location = 'src/x.al:3'; severity = 'major'; message = 'MSG' })
        $s | Should -Match ([regex]::Escape("``src/x.al:3`` $([char]::ConvertFromUtf32(0x1F7E0)) [major] MSG"))
    }
    It 'keeps the summary fingerprint stable across reruns' {
        $c = [ordered]@{ blocker = 0; major = 1; minor = 0; info = 0 }
        (Get-SummaryFingerprint 'h' 'completed' '' $c 'c1') | Should -Be (Get-SummaryFingerprint 'h' 'completed' '' $c 'c1')
        (Get-SummaryFingerprint 'h' 'completed' '' $c 'c1') | Should -Not -Be (Get-SummaryFingerprint 'h2' 'completed' '' $c 'c1')
    }
}
