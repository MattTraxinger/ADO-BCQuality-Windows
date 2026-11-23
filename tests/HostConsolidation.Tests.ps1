BeforeDiscovery {
    # The roll-up is checked against BCQuality's own validator (tools/Validate-FindingsReport.ps1), which is what the
    # pipeline's acceptance gate runs. Point BCQUALITY_TEST_ROOT at a BCQuality checkout (the pipeline pins v1.9); by
    # default a sibling folder named BCQuality is used. Without a checkout those tests are skipped.
    $root = if ($env:BCQUALITY_TEST_ROOT) { $env:BCQUALITY_TEST_ROOT } else { Join-Path $PSScriptRoot '..\..\BCQuality' }
    $script:haveBcq = (Test-Path -LiteralPath (Join-Path $root 'tools/Validate-FindingsReport.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $root 'microsoft/knowledge/events/choose-static-vs-manual-subscribers-deliberately.md'))
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Common.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\HostConsolidation.ps1')
    $script:bcqRoot = if ($env:BCQUALITY_TEST_ROOT) { $env:BCQUALITY_TEST_ROOT } else { Join-Path $PSScriptRoot '..\..\BCQuality' }
    $script:validator = Join-Path $script:bcqRoot 'tools/Validate-FindingsReport.ps1'
    $script:src = Join-Path $TestDrive 'src'
    New-Item -ItemType Directory -Path (Join-Path $script:src 'apps/Demo') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:src 'apps/Demo/Sub.Cod.al') -Value (1..30 | ForEach-Object { "// line $_" })
    $script:file = 'apps/Demo/Sub.Cod.al'
    $k = 'microsoft/knowledge'
    $script:events = "$k/events/choose-static-vs-manual-subscribers-deliberately.md"
    $script:dataModeling = "$k/data-modeling/master-data-must-be-inserted-with-trigger.md"
    $script:appsource = "$k/appsource/permission-sets-cover-setup-and-usage-without-super.md"
    $script:style = "$k/style/file-name-object-type-pattern.md"

    function New-TestFinding {
        param([string] $Path, [string] $Severity, [string] $Message, [int] $Line, [int] $EndLine = 0, [string] $Code, [string] $Domain = 'X', [string] $Confidence = 'high')
        $loc = [ordered]@{ file = $script:file; line = $Line }
        if ($EndLine) { $loc['range'] = [ordered]@{ 'start-line' = $Line; 'end-line' = $EndLine } }
        $f = [ordered]@{ id = $Path; severity = $Severity; message = $Message; location = $loc; references = @([ordered]@{ path = $Path }); confidence = $Confidence; domain = $Domain }
        if ($Code) { $f['suggested-code'] = $Code } else { $f['suggested-code-omission-reason'] = 'needs a decision' }
        $f
    }
    function New-TestAgentFinding {
        param([string] $Slug, [string] $Message, [int] $Line)
        [ordered]@{ id = "agent:$Slug"; severity = 'minor'; message = $Message; location = [ordered]@{ file = $script:file; line = $Line }
            references = @(); confidence = 'medium'; domain = 'Error Handling'; 'suggested-code-omission-reason' = 'depends on intent' }
    }
    function New-TestLeaf {
        param([string] $Id, [string] $Outcome = 'completed', [object[]] $Findings = @(), [int] $Worklist = 1, [string] $Reason)
        $counts = [ordered]@{}
        foreach ($s in 'blocker', 'major', 'minor', 'info') { $counts[$s] = @($Findings | Where-Object { $_.severity -eq $s }).Count }
        $items = if ($Outcome -eq 'failed') { 0 } else { $Worklist }
        $r = [ordered]@{ skill = [ordered]@{ id = $Id; version = 1 }; outcome = $Outcome }
        if ($Reason) { $r['outcome-reason'] = $Reason }
        $r['summary'] = [ordered]@{ counts = $counts; coverage = [ordered]@{ 'worklist-size' = $Worklist; 'items-evaluated' = $items } }
        $r['findings'] = @($Findings)
        $r['suppressed'] = @()
        $r
    }
    function Invoke-RollupCheck {
        # Same path as the pipeline: leaves saved as accepted files, read back, rolled up, written, validated.
        param([object[]] $Leaves, [object[]] $Skipped = @())
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($l in $Leaves) { Write-Json -Object $l -Path (Join-Path $dir "accepted/$($l.skill.id).json") }
        $comp = [ordered]@{
            superSkill = [ordered]@{ id = 'al-code-review'; version = 1 }
            subSkills = @($Leaves | ForEach-Object { [ordered]@{ id = $_.skill.id; version = 1 } })
            skipped = @($Skipped)
            acceptedResults = @($Leaves | ForEach-Object { [ordered]@{ id = $_.skill.id; version = 1; reportPath = "accepted/$($_.skill.id).json" } })
        }
        Write-Json -Object $comp -Path (Join-Path $dir 'composition.json')
        $read = @($Leaves | ForEach-Object { Get-Content -LiteralPath (Join-Path $dir "accepted/$($_.skill.id).json") -Raw | ConvertFrom-Json -Depth 100 })
        $rollup = New-HostRollup -SuperSkill $comp.superSkill -Leaves $read -Skipped $Skipped
        $reportPath = Join-Path $dir 'report.json'
        Write-Json -Object $rollup -Path $reportPath
        $paths = @($Leaves | ForEach-Object { $_.findings } | ForEach-Object { $_.references } | ForEach-Object { $_.path } | Sort-Object -Unique)
        $err = ''
        try {
            $null = & $script:validator -ReportPath $reportPath -BCQualityRoot $script:bcqRoot -SourceRoot $script:src -SourcePaths $script:file `
                -SkillKind super -ExpectedCompositionPath (Join-Path $dir 'composition.json') -RetrievedArticlePaths $paths
        }
        catch { $err = $_.Exception.Message }
        [pscustomobject]@{ Report = (Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 100); Error = $err }
    }
}

Describe 'Get-RollupOutcome' {
    It 'follows the do.md outcome rollup' {
        Get-RollupOutcome @() | Should -Be 'not-applicable'
        Get-RollupOutcome @('completed', 'not-applicable') | Should -Be 'completed'
        Get-RollupOutcome @('not-applicable', 'not-applicable') | Should -Be 'not-applicable'
        Get-RollupOutcome @('no-knowledge', 'not-applicable') | Should -Be 'no-knowledge'
        Get-RollupOutcome @('no-knowledge', 'completed') | Should -Be 'completed'
        Get-RollupOutcome @('failed', 'failed') | Should -Be 'failed'
        Get-RollupOutcome @('failed', 'completed') | Should -Be 'partial'
        Get-RollupOutcome @('partial', 'completed') | Should -Be 'partial'
    }
}

Describe 'New-HostRollup against the BCQuality validator' -Skip:(-not $script:haveBcq) {
    It 'keeps every finding of the build that the agent roll-up failed on, agent finding included' {
        # Five areas report findings on one subscriber: the agent finding sits on the same line as two cited findings.
        $leaves = @(
            (New-TestLeaf 'al-appsource-review' -Findings @((New-TestFinding $script:appsource 'major' 'No permission grant for Customer.' 13 -Confidence 'medium' -Domain 'AppSource')))
            (New-TestLeaf 'al-data-modeling-review' -Findings @((New-TestFinding $script:dataModeling 'major' 'Bare Insert skips the trigger.' 13 -Code '        Customer.Insert(true);' -Domain 'Data Modeling')))
            (New-TestLeaf 'al-error-handling-review' -Findings @((New-TestAgentFinding 'unguarded-insert-aborts-export' 'Duplicate key aborts the export.' 13)) -Worklist 0)
            (New-TestLeaf 'al-events-review' -Findings @((New-TestFinding $script:events 'major' 'Static subscriber writes a record.' 10 13 -Confidence 'medium' -Domain 'Events')))
            (New-TestLeaf 'al-style-review' -Findings @((New-TestFinding $script:style 'info' 'File name pattern.' 1 -Domain 'Style')) -Worklist 2)
            (New-TestLeaf 'al-ui-review' -Outcome 'not-applicable' -Worklist 0)
        )
        $r = Invoke-RollupCheck $leaves
        $r.Error | Should -Be ''
        $r.Report.outcome | Should -Be 'completed'
        @($r.Report.findings).Count | Should -Be 5
        $agent = @($r.Report.findings | Where-Object { $_.'from-sub-skill' -eq 'al-error-handling-review' })
        $agent.Count | Should -Be 1
        $agent[0].id | Should -Be 'al-error-handling-review:agent:unguarded-insert-aborts-export'
        @($agent[0].references).Count | Should -Be 0
        $r.Report.summary.counts.major | Should -Be 3
        $r.Report.summary.counts.minor | Should -Be 1
        $r.Report.summary.counts.info | Should -Be 1
        $r.Report.summary.coverage.'worklist-size' | Should -Be 5   # 1 + 1 + 0 + 1 + 2 + 0, summed over the areas
    }

    It 'copies leaf reports unchanged into sub-results, in worklist order' {
        $a = New-TestLeaf 'al-appsource-review' -Findings @((New-TestFinding $script:appsource 'major' 'm1' 13))
        $b = New-TestLeaf 'al-style-review' -Findings @((New-TestFinding $script:style 'info' 'm2' 1))
        $r = Invoke-RollupCheck @($a, $b)
        $r.Error | Should -Be ''
        @($r.Report.'sub-results' | ForEach-Object { $_.skill.id }) | Should -Be @('al-appsource-review', 'al-style-review')
        $r.Report.'sub-results'[0].findings[0].message | Should -Be 'm1'
    }

    It 'merges one concern reported by two areas: highest severity and confidence, first producer' {
        $a = New-TestLeaf 'al-appsource-review' -Findings @((New-TestFinding $script:events 'minor' 'Same words.' 12 -Confidence 'medium' -Domain 'AppSource'))
        $b = New-TestLeaf 'al-events-review' -Findings @((New-TestFinding $script:events 'major' 'Same words.' 12 -Confidence 'high' -Domain 'Events'))
        # same citation, overlapping line, no suggested code on either side, identical message: the validator requires one finding
        $a.findings[0].Remove('suggested-code-omission-reason'); $b.findings[0].Remove('suggested-code-omission-reason')
        $r = Invoke-RollupCheck @($a, $b)
        $r.Error | Should -Be ''
        @($r.Report.findings).Count | Should -Be 1
        $r.Report.findings[0].severity | Should -Be 'major'
        $r.Report.findings[0].confidence | Should -Be 'high'
        $r.Report.findings[0].'from-sub-skill' | Should -Be 'al-appsource-review'
        $r.Report.summary.counts.major | Should -Be 1
    }

    It 'merges two different articles that overlap and prescribe the same code, keeping both references' {
        $a = New-TestLeaf 'al-data-modeling-review' -Findings @((New-TestFinding $script:dataModeling 'major' 'Insert with trigger.' 13 -Code '        Customer.Insert(true);'))
        $b = New-TestLeaf 'al-events-review' -Findings @((New-TestFinding $script:events 'minor' 'Do not write here.' 13 -Code '        Customer.Insert(true);'))
        $r = Invoke-RollupCheck @($a, $b)
        $r.Error | Should -Be ''
        @($r.Report.findings).Count | Should -Be 1
        $r.Report.findings[0].id | Should -Be $script:dataModeling
        @($r.Report.findings[0].references | ForEach-Object { $_.path }) | Should -Be @($script:dataModeling, $script:events)
    }

    It 'leaves out the findings of a failed area and reports partial, naming it' {
        $ok = New-TestLeaf 'al-style-review' -Findings @((New-TestFinding $script:style 'info' 'm' 1))
        $bad = New-TestLeaf 'al-security-review' -Outcome 'failed' -Reason 'leaf report failed validation'
        $r = Invoke-RollupCheck @($ok, $bad)
        $r.Error | Should -Be ''
        $r.Report.outcome | Should -Be 'partial'
        $r.Report.'outcome-reason' | Should -BeLike '*al-security-review*'
        @($r.Report.findings).Count | Should -Be 1
        $r.Report.summary.coverage.'worklist-size' | Should -Be 1   # a failed area adds nothing to coverage
    }

    It 'is failed when every area failed' {
        $r = Invoke-RollupCheck @((New-TestLeaf 'al-a-review' -Outcome 'failed' -Reason 'x'), (New-TestLeaf 'al-b-review' -Outcome 'failed' -Reason 'y'))
        $r.Error | Should -Be ''
        $r.Report.outcome | Should -Be 'failed'
        @($r.Report.findings).Count | Should -Be 0
    }

    It 'is not-applicable when no area applies, and passes configured skips through' {
        $skip = [pscustomobject]@{ id = 'al-testing-review'; version = 1; reason = 'configuration' }
        $r = Invoke-RollupCheck @((New-TestLeaf 'al-ui-review' -Outcome 'not-applicable' -Worklist 0)) @($skip)
        $r.Error | Should -Be ''
        $r.Report.outcome | Should -Be 'not-applicable'
        @($r.Report.'skipped-sub-skills').Count | Should -Be 1
        $r.Report.'skipped-sub-skills'[0].skill.id | Should -Be 'al-testing-review'
        $r.Report.'skipped-sub-skills'[0].reason | Should -Be 'configuration'
    }

    It 'rolls up a finding that has no location one to one' {
        $f = New-TestFinding $script:appsource 'minor' 'App-wide concern.' 1
        $f.Remove('location'); $f.Remove('suggested-code-omission-reason')
        $r = Invoke-RollupCheck @((New-TestLeaf 'al-appsource-review' -Findings @($f)))
        $r.Error | Should -Be ''
        @($r.Report.findings).Count | Should -Be 1
        $r.Report.findings[0].PSObject.Properties.Name | Should -Not -Contain 'location'
    }

    It 'produces a valid empty report when nothing was found' {
        $r = Invoke-RollupCheck @((New-TestLeaf 'al-style-review' -Worklist 2), (New-TestLeaf 'al-ui-review' -Outcome 'not-applicable' -Worklist 0))
        $r.Error | Should -Be ''
        $r.Report.outcome | Should -Be 'completed'
        @($r.Report.findings).Count | Should -Be 0
    }
}
