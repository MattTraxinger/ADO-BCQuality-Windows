BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    foreach ($f in 'Common', 'FindingPlacement', 'SuggestionPlacement', 'FindingDeduplication', 'AzureDevOps', 'PublishPlan') { . (Join-Path $script:scripts "$f.ps1") }

    $script:diff = @'
diff --git a/src/x.al b/src/x.al
--- a/src/x.al
+++ b/src/x.al
@@ -3,3 +3,5 @@
     procedure A()
     begin
+        if Rec.Count() > 0 then
+            Message('hi');
     end;
@@ -20,2 +22,2 @@
-old line
+++ looks like a header but is an added line
 kept
'@
    $script:fileLines = @('codeunit 50000 X', '{', '    procedure A()', '    begin', "        if Rec.Count() > 0 then", "            Message('hi');", '    end;', '}')

    # A literal three-backtick fence. Backticks are the escape character inside -like patterns, so fences are
    # checked with .Contains() rather than -like.
    $script:fence3 = '`' * 3

    function New-Finding {
        param([int] $Line = 5, [string] $Code, $Range)
        $loc = [ordered]@{ file = 'src/x.al'; line = $Line }
        if ($Range) { $loc.range = [ordered]@{ 'start-line' = $Range[0]; 'end-line' = $Range[1] } }
        $f = [ordered]@{ id = 'k'; severity = 'minor'; message = 'm'; location = $loc; references = @(); confidence = 'medium' }
        if ($PSBoundParameters.ContainsKey('Code')) { $f['suggested-code'] = $Code }
        ([pscustomobject]$f | ConvertTo-Json -Depth 6 | ConvertFrom-Json -Depth 6)   # same shape the pipeline reads
    }
}

Describe 'Get-DiffAddedLines' {
    It 'lists only added lines, by new-file number, skipping headers, context and deletions' {
        $a = Get-DiffAddedLines -DiffText $script:diff
        @($a | Sort-Object) | Should -Be @(5, 6, 22)
    }
    It 'counts a deleted line as absent from the new file and an added line that starts with ++ as added' {
        $a = Get-DiffAddedLines -DiffText $script:diff
        $a.Contains(22) | Should -BeTrue    # "+++ looks like..." is content inside a hunk
        $a.Contains(23) | Should -BeFalse   # the context line after it
    }
    It 'ignores a no-newline marker and handles CRLF diffs and an empty diff' {
        $crlf = "@@ -1 +1,2 @@`r`n a`r`n+b`r`n\ No newline at end of file`r`n"
        $a = Get-DiffAddedLines -DiffText $crlf
        $a.Count | Should -Be 1
        $a.Contains(2) | Should -BeTrue
        (Get-DiffAddedLines -DiffText '').Count | Should -Be 0
    }
}

Describe 'Resolve-SuggestionSpan' {
    BeforeAll { $script:added = Get-DiffAddedLines -DiffText $script:diff }
    It 'accepts a single added line' {
        $r = Resolve-SuggestionSpan -Finding (New-Finding -Line 5 -Code 'x') -FileLines $script:fileLines -AddedLines $script:added
        $r.ok | Should -BeTrue; $r.startLine | Should -Be 5; $r.endLine | Should -Be 5
    }
    It 'accepts a declared range of added lines' {
        $r = Resolve-SuggestionSpan -Finding (New-Finding -Line 5 -Range @(5, 6) -Code 'x') -FileLines $script:fileLines -AddedLines $script:added
        $r.ok | Should -BeTrue; $r.startLine | Should -Be 5; $r.endLine | Should -Be 6
    }
    It 'rejects a span that includes a context line the PR did not change' {
        (Resolve-SuggestionSpan -Finding (New-Finding -Line 4 -Code 'x') -FileLines $script:fileLines -AddedLines $script:added).reason | Should -Be 'span-outside-diff'
        (Resolve-SuggestionSpan -Finding (New-Finding -Line 6 -Range @(6, 7) -Code 'x') -FileLines $script:fileLines -AddedLines $script:added).reason | Should -Be 'span-outside-diff'
    }
    It 'rejects a range that does not contain the reported line, or runs backwards' {
        (Resolve-SuggestionSpan -Finding (New-Finding -Line 5 -Range @(6, 6) -Code 'x') -FileLines $script:fileLines -AddedLines $script:added).reason | Should -Be 'range-excludes-line'
        (Resolve-SuggestionSpan -Finding (New-Finding -Line 6 -Range @(6, 5) -Code 'x') -FileLines $script:fileLines -AddedLines $script:added).reason | Should -Be 'range-excludes-line'
    }
    It 'rejects a span past the end of the file and one that is too large' {
        (Resolve-SuggestionSpan -Finding (New-Finding -Line 9 -Code 'x') -FileLines $script:fileLines -AddedLines $script:added).reason | Should -Be 'span-outside-file'
        $many = [System.Collections.Generic.HashSet[int]]::new([int[]](1..100))
        $r = Resolve-SuggestionSpan -Finding (New-Finding -Line 3 -Range @(1, 40) -Code 'x') -FileLines (1..100 | ForEach-Object { "l$_" }) -AddedLines $many
        $r.reason | Should -Be 'span-too-large'
    }
}

Describe 'Get-SuggestionPlan' {
    BeforeAll { $script:added = Get-DiffAddedLines -DiffText $script:diff }
    It 'offers a one-click change for a valid span and carries the span' {
        $p = Get-SuggestionPlan -Finding (New-Finding -Line 5 -Code '        if not Rec.IsEmpty() then') -FileLines $script:fileLines -AddedLines $script:added
        $p.mode | Should -Be 'apply'; $p.startLine | Should -Be 5; $p.endLine | Should -Be 5
        $p.code | Should -Be '        if not Rec.IsEmpty() then'
    }
    It 'falls back to a manual snippet, with the reason, when the span fails a check' {
        $p = Get-SuggestionPlan -Finding (New-Finding -Line 4 -Code '    begin  // x') -FileLines $script:fileLines -AddedLines $script:added
        $p.mode | Should -Be 'manual'; $p.reason | Should -Be 'span-outside-diff'
    }
    It 'shows nothing when there is no suggestion, it is turned off, or it equals the source' {
        (Get-SuggestionPlan -Finding (New-Finding -Line 5) -FileLines $script:fileLines -AddedLines $script:added).mode | Should -Be 'none'
        (Get-SuggestionPlan -Finding (New-Finding -Line 5 -Code 'x') -FileLines $script:fileLines -AddedLines $script:added -Setting off).reason | Should -Be 'disabled'
        (Get-SuggestionPlan -Finding (New-Finding -Line 5 -Code "        if Rec.Count() > 0 then   ") -FileLines $script:fileLines -AddedLines $script:added).reason | Should -Be 'identical-to-source'
    }
    It 'treats a whitespace-only change as a real change' {
        (Get-SuggestionPlan -Finding (New-Finding -Line 5 -Code "    if Rec.Count() > 0 then") -FileLines $script:fileLines -AddedLines $script:added).mode | Should -Be 'apply'
    }
    It 'uses a manual snippet for every valid span when the setting is manual' {
        $p = Get-SuggestionPlan -Finding (New-Finding -Line 5 -Code 'x') -FileLines $script:fileLines -AddedLines $script:added -Setting manual
        $p.mode | Should -Be 'manual'; $p.reason | Should -Be 'configured'
    }
    It 'normalizes CRLF and trailing newlines in the suggested code' {
        $p = Get-SuggestionPlan -Finding (New-Finding -Line 5 -Range @(5, 6) -Code "a`r`nb`r`n") -FileLines $script:fileLines -AddedLines $script:added
        $p.code | Should -Be "a`nb"
    }
}

# Regression: a mandatory [string[]] parameter rejects an empty string inside the array, and real AL files have blank
# lines between procedures. The first live review of such a file died in New-PublishPlan with "Cannot bind argument
# to parameter 'FileLines' because it is an empty string". The fixtures above had no blank lines, so tests missed it.
Describe 'Source files with blank lines' {
    BeforeAll {
        $script:blankLines = @('codeunit 50000 X', '{', '    procedure A()', '    begin', '        if Rec.Count() > 0 then', '    end;', '', '    procedure B()', '    begin', '    end;', '}', '')
        $script:blankDiff = @'
@@ -3,3 +3,4 @@
     procedure A()
     begin
+        if Rec.Count() > 0 then
     end;
'@
        $script:blankAdded = Get-DiffAddedLines -DiffText $script:blankDiff
    }
    It 'checks a span in a file that contains blank lines, including one at the end' {
        $r = Resolve-SuggestionSpan -Finding (New-Finding -Line 5 -Code 'x') -FileLines $script:blankLines -AddedLines $script:blankAdded
        $r.ok | Should -BeTrue; $r.startLine | Should -Be 5
    }
    It 'plans a one-click suggestion in a file that contains blank lines' {
        $p = Get-SuggestionPlan -Finding (New-Finding -Line 5 -Code '        if not Rec.IsEmpty() then') -FileLines $script:blankLines -AddedLines $script:blankAdded
        $p.mode | Should -Be 'apply'; $p.startLine | Should -Be 5
    }
    It 'compares a span that itself contains a blank line' {
        $added = [System.Collections.Generic.HashSet[int]]::new([int[]](6, 7, 8))
        $p = Get-SuggestionPlan -Finding (New-Finding -Line 6 -Range @(6, 7) -Code "    end;`n") -FileLines $script:blankLines -AddedLines $added
        $p.mode | Should -BeIn 'apply', 'none'   # must not throw on the blank line; the content decides which
        $p.mode | Should -Not -Be 'manual'
    }
    It 'runs New-PublishPlan.ps1 on a file with blank lines' {
        $work = Join-Path $TestDrive 'blank'
        $repo = Join-Path $work 'repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'src/x.al') -Value $script:blankLines
        git -C $repo init -q 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t commit -q -m c 2>&1 | Out-Null
        $head = (git -C $repo rev-parse HEAD).Trim()
        $appDir = Join-Path $work 'app'
        New-Item -ItemType Directory -Path (Join-Path $appDir 'diff/src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appDir 'diff/src/x.al.diff') -Value $script:blankDiff
        $report = Join-Path $appDir 'accepted-report.json'
        [ordered]@{ outcome = 'completed'; findings = @((New-Finding -Line 5 -Code '        if not Rec.IsEmpty() then')) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report
        $result = Join-Path $work 'result.json'
        [ordered]@{ outcome = 'completed'; reviewedHeadSha = $head; mode = 'advisory'
            apps = @([ordered]@{ reportPath = $report; files = @('src/x.al'); diffDir = $appDir; outcomeReason = $null }) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $result
        $ctx = Join-Path $work 'ctx.json'
        [ordered]@{ headSha = $head; settings = [ordered]@{ BCQuality = [ordered]@{ repo = 'https://github.com/microsoft/BCQuality'; version = '1.9' }; CodeReviewAgent = [ordered]@{ suggestions = 'apply' } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ctx
        $out = Join-Path $work 'plan.json'
        $log = & pwsh -NoProfile -File (Join-Path $script:scripts 'New-PublishPlan.ps1') -ResultPath $result -ContextPath $ctx -RepoDir $repo -BCQualityCommit abc -OutPath $out 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $log
        $plan = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -Depth 20
        $plan.suggestions.oneClick | Should -Be 1
    }
}

Describe 'New-SuggestionMarkdown' {
    It 'renders an applicable block with the suggestion fence tag' {
        $md = New-SuggestionMarkdown -Plan ([pscustomobject]@{ mode = 'apply'; reason = $null; code = "a`nb" })
        $md | Should -Be "``````suggestion`na`nb`n``````"
    }
    It 'labels a manual snippet and says why' {
        $md = New-SuggestionMarkdown -Plan ([pscustomobject]@{ mode = 'manual'; reason = 'span-outside-diff'; code = 'a' })
        $md.StartsWith('**Suggested fix** (apply manually: it would replace lines this pull request did not change):') | Should -BeTrue
        $md.Contains("$($script:fence3)al`na`n$($script:fence3)") | Should -BeTrue
        $md.Contains("$($script:fence3)suggestion") | Should -BeFalse
    }
    It 'uses a fence longer than any backtick run in the code, so the code cannot close it' {
        $three = '`' * 3; $four = '`' * 4
        $md = New-SuggestionMarkdown -Plan ([pscustomobject]@{ mode = 'apply'; reason = $null; code = "x`n$three oops" })
        $md.StartsWith("${four}suggestion") | Should -BeTrue
        $md.EndsWith("`n$four") | Should -BeTrue
    }
    It 'renders nothing for none' {
        New-SuggestionMarkdown -Plan ([pscustomobject]@{ mode = 'none'; reason = 'x'; code = '' }) | Should -Be ''
    }
}

Describe 'Thread anchoring over a span' {
    It 'keeps the single-character anchor without an end line' {
        $b = New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -FilePath 'src/x.al' -Line 12
        $b.threadContext.rightFileEnd.line | Should -Be 12; $b.threadContext.rightFileEnd.offset | Should -Be 2
    }
    It 'anchors from the first character of the first line to the end of the last line' {
        $b = New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -FilePath 'src/x.al' -Line 5 -EndLine 6 -EndOffset 31
        $b.threadContext.rightFileStart.line | Should -Be 5; $b.threadContext.rightFileStart.offset | Should -Be 1
        $b.threadContext.rightFileEnd.line | Should -Be 6; $b.threadContext.rightFileEnd.offset | Should -Be 31
    }
    It 'covers a whole single line when only the end offset is given' {
        $b = New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -FilePath 'src/x.al' -Line 5 -EndOffset 30
        $b.threadContext.rightFileEnd.line | Should -Be 5; $b.threadContext.rightFileEnd.offset | Should -Be 30
    }
}

Describe 'Finding content with a suggestion' {
    It 'puts the suggestion between the message and the knowledge link' {
        $f = [pscustomobject]@{ severity = 'minor'; message = 'MSG'; confidence = 'high'; references = @([pscustomobject]@{ path = 'microsoft/knowledge/x/y.md' }) }
        $c = New-FindingContent -Finding $f -KnowledgeBaseUrl 'https://example/repo/blob/abc' -SuggestionMarkdown "``````suggestion`nz`n``````"
        $c.IndexOf('MSG') | Should -BeLessThan $c.IndexOf('suggestion')
        $c.IndexOf('suggestion') | Should -BeLessThan $c.IndexOf('Knowledge:')
    }
    It 'is unchanged without a suggestion' {
        $f = [pscustomobject]@{ severity = 'minor'; message = 'MSG'; confidence = 'high'; references = @() }
        (New-FindingContent -Finding $f) | Should -Not -BeLike '*suggestion*'
    }
}

Describe 'New-PublishPlan end to end' {
    BeforeAll {
        $script:work = Join-Path $TestDrive 'plan'
        $repo = Join-Path $script:work 'repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'src/x.al') -Value $script:fileLines
        git -C $repo init -q 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t commit -q -m c 2>&1 | Out-Null
        $script:head = (git -C $repo rev-parse HEAD).Trim()
        $script:repo = $repo

        $appDir = Join-Path $script:work 'app'
        New-Item -ItemType Directory -Path (Join-Path $appDir 'diff/src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appDir 'diff/src/x.al.diff') -Value @'
diff --git a/src/x.al b/src/x.al
--- a/src/x.al
+++ b/src/x.al
@@ -3,3 +3,5 @@
     procedure A()
     begin
+        if Rec.Count() > 0 then
+            Message('hi');
     end;
'@
        $findings = @(
            (New-Finding -Line 5 -Code '        if not Rec.IsEmpty() then')                       # one-click, single line
            (New-Finding -Line 6 -Code '            Message(''hello'');')                          # one-click, other line
            (New-Finding -Line 4 -Code '    begin // changed')                                     # context line: manual
            (New-Finding -Line 5 -Code '        if Rec.Count() > 0 then')                          # identical: nothing shown
        )
        # distinct knowledge ids so fingerprints differ
        for ($i = 0; $i -lt $findings.Count; $i++) { $findings[$i].id = "k$i" }
        $reportPath = Join-Path $appDir 'accepted-report.json'
        [ordered]@{ outcome = 'completed'; findings = $findings } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath
        $script:resultPath = Join-Path $script:work 'result.json'
        [ordered]@{ outcome = 'completed'; reviewedHeadSha = $script:head; mode = 'advisory'
            apps = @([ordered]@{ reportPath = $reportPath; files = @('src/x.al'); diffDir = $appDir; outcomeReason = $null }) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:resultPath
        function Invoke-Plan {
            param([string] $Setting)
            $ctx = Join-Path $script:work "ctx-$Setting.json"
            [ordered]@{ headSha = $script:head; settings = [ordered]@{ BCQuality = [ordered]@{ repo = 'https://github.com/microsoft/BCQuality'; version = '1.9' }
                    CodeReviewAgent = [ordered]@{ suggestions = $Setting } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ctx
            $out = Join-Path $script:work "plan-$Setting.json"
            $null = & pwsh -NoProfile -File (Join-Path $script:scripts 'New-PublishPlan.ps1') -ResultPath $script:resultPath -ContextPath $ctx -RepoDir $script:repo -BCQualityCommit abc -OutPath $out
            if ($LASTEXITCODE -ne 0) { throw "New-PublishPlan.ps1 exited $LASTEXITCODE" }
            Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -Depth 20
        }
        $script:applyPlan = Invoke-Plan 'apply'
        $script:manualPlan = Invoke-Plan 'manual'
        $script:offPlan = Invoke-Plan 'off'
    }
    It 'puts a one-click block on a valid span and anchors the thread over the whole line' {
        $i = $script:applyPlan.items | Where-Object { $_.content -like '*if not Rec.IsEmpty*' }
        $i.content.Contains("$($script:fence3)suggestion`n        if not Rec.IsEmpty() then`n$($script:fence3)") | Should -BeTrue
        $i.line | Should -Be 5; $i.endLine | Should -Be 5
        $i.endOffset | Should -Be (("        if Rec.Count() > 0 then").Length + 1)
    }
    It 'shows a manual snippet, anchored at the finding line, when the span includes an unchanged line' {
        $i = $script:applyPlan.items | Where-Object { $_.content -like '*begin // changed*' }
        $i.content | Should -BeLike '*apply manually: it would replace lines this pull request did not change*'
        $i.content.Contains("$($script:fence3)suggestion") | Should -BeFalse
        $i.content.Contains("$($script:fence3)al") | Should -BeTrue
        $i.PSObject.Properties['endLine'] | Should -BeNullOrEmpty
    }
    It 'shows no block for a suggestion identical to the source, but still posts the finding' {
        @($script:applyPlan.items | Where-Object { -not $_.content.Contains($script:fence3) }).Count | Should -Be 1
    }
    It 'reports counts and reasons' {
        $s = $script:applyPlan.suggestions
        $s.setting | Should -Be 'apply'; $s.oneClick | Should -Be 2; $s.manual | Should -Be 1; $s.none | Should -Be 1
        $s.reasons.'manual:span-outside-diff' | Should -Be 1
        $s.reasons.'none:identical-to-source' | Should -Be 1
    }
    It 'keeps fingerprints identical whatever the setting, so a rerun after a setting change posts no duplicates' {
        @($script:applyPlan.items.fingerprint | Sort-Object) | Should -Be @($script:offPlan.items.fingerprint | Sort-Object)
        @($script:applyPlan.items.fingerprint | Sort-Object) | Should -Be @($script:manualPlan.items.fingerprint | Sort-Object)
    }
    It 'uses manual snippets only when configured manual, and no blocks at all when off' {
        @($script:manualPlan.items | Where-Object { $_.content.Contains("$($script:fence3)suggestion") }).Count | Should -Be 0
        @($script:manualPlan.items | Where-Object { $_.content.Contains('apply manually: one-click suggestions are turned off') }).Count | Should -Be 2   # the unchanged-line one keeps its own, more specific reason
        @($script:offPlan.items | Where-Object { $_.content.Contains($script:fence3) }).Count | Should -Be 0
    }
}

# The plan line names the summary thread status it plans, and the PR status only in status mode (advisory mode sets none).
Describe 'New-PublishPlan log line' {
    BeforeAll {
        $script:logWork = Join-Path $TestDrive 'logline'
        $repo = Join-Path $script:logWork 'repo'
        New-Item -ItemType Directory -Path (Join-Path $repo 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'src/x.al') -Value $script:fileLines
        git -C $repo init -q 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t commit -q -m c 2>&1 | Out-Null
        $script:logHead = (git -C $repo rev-parse HEAD).Trim()
        $script:logRepo = $repo
        $script:logApp = Join-Path $script:logWork 'app'
        New-Item -ItemType Directory -Path (Join-Path $script:logApp 'diff/src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:logApp 'diff/src/x.al.diff') -Value $script:diff
        $script:logCtx = Join-Path $script:logWork 'ctx.json'
        [ordered]@{ headSha = $script:logHead; settings = [ordered]@{ BCQuality = [ordered]@{ repo = 'https://github.com/microsoft/BCQuality'; version = '1.9' }
                CodeReviewAgent = [ordered]@{ suggestions = 'apply' } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:logCtx
        function Get-PlanLog {
            param([string] $Name, [string] $Mode, [object[]] $Findings)
            $report = Join-Path $script:logWork "$Name-report.json"
            [ordered]@{ outcome = 'completed'; findings = @($Findings) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report
            $result = Join-Path $script:logWork "$Name-result.json"
            [ordered]@{ outcome = 'completed'; reviewedHeadSha = $script:logHead; mode = $Mode
                apps = @([ordered]@{ reportPath = $report; files = @('src/x.al'); diffDir = $script:logApp; outcomeReason = $null }) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $result
            $log = & pwsh -NoProfile -File (Join-Path $script:scripts 'New-PublishPlan.ps1') -ResultPath $result -ContextPath $script:logCtx -RepoDir $script:logRepo `
                -BCQualityCommit abc -OutPath (Join-Path $script:logWork "$Name-plan.json") 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "New-PublishPlan.ps1 exited $LASTEXITCODE`n$log" }
            @($log -split "`r?`n" | Where-Object { $_ -like 'Publish plan:*' })[0]
        }
    }
    It 'names the closed summary thread of a clean advisory review and no PR status' {
        Get-PlanLog 'clean' 'advisory' @() | Should -Be 'Publish plan: 0 inline thread(s), 0 in summary, summary thread=closed'
    }
    It 'names the active summary thread of an advisory review with findings and no PR status' {
        Get-PlanLog 'findings' 'advisory' @((New-Finding -Line 5)) | Should -Be 'Publish plan: 1 inline thread(s), 0 in summary, summary thread=active'
    }
    It 'adds the PR status in status mode' {
        $blocker = New-Finding -Line 5; $blocker.severity = 'blocker'   # only a blocker fails the status
        Get-PlanLog 'status' 'status' @($blocker) | Should -Be 'Publish plan: 1 inline thread(s), 0 in summary, summary thread=active, PR status=failed'
    }
}
