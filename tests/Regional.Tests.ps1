BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    foreach ($f in 'Common', 'FindingPlacement', 'SuggestionPlacement', 'RegionalGrouping', 'FindingDeduplication', 'AzureDevOps', 'PublishPlan') { . (Join-Path $script:scripts "$f.ps1") }
    $script:schema = Join-Path $PSScriptRoot '..\schemas\bcquality-ado.settings.schema.json'

    $script:layouts = @((ConvertTo-RegionalLayout 'src/Apps/{region}/{path}'), (ConvertTo-RegionalLayout 'src/Layers/{region}/{path}'))

    function New-Item2 {
        # A plan item as New-PublishPlan builds it before grouping.
        param([string] $File, [int] $Line = 10, [string] $Identity = 'same', [string] $Content = 'body')
        [ordered]@{ fingerprint = "fp-$File"; filePath = $File; line = $Line; rule = 'r1'; content = $Content; identity = $Identity }
    }
}

Describe 'ConvertTo-RegionalLayout' {
    It 'accepts a template with one {region} and one {path}' {
        (ConvertTo-RegionalLayout 'src/Apps/{region}/{path}').template | Should -Be 'src/Apps/{region}/{path}'
        (ConvertTo-RegionalLayout '/{path}/Regional/{region}').regex | Should -Not -BeNullOrEmpty
    }
    It 'rejects a template without both placeholders, with a repeated one, or with ..' {
        { ConvertTo-RegionalLayout 'src/Apps/{region}' } | Should -Throw '*{region} and {path} exactly once*'
        { ConvertTo-RegionalLayout 'src/{path}' } | Should -Throw '*exactly once*'
        { ConvertTo-RegionalLayout '{region}/{region}/{path}' } | Should -Throw '*exactly once*'
        { ConvertTo-RegionalLayout '../{region}/{path}' } | Should -Throw "*'..'*"
    }
    It 'matches regex characters in the template literally' {
        $l = ConvertTo-RegionalLayout 'a.b+c/{region}/{path}'
        $l.regex.IsMatch('a.b+c/DE/x.al') | Should -BeTrue
        $l.regex.IsMatch('aXb+c/DE/x.al') | Should -BeFalse
    }
}

Describe 'Get-RegionalPathInfo' {
    It 'splits a path into region and the part shared by every copy' {
        $i = Get-RegionalPathInfo -FilePath 'src/Apps/DE/Foo/Bar/x.al' -Layouts $script:layouts
        $i.region | Should -Be 'DE'; $i.relative | Should -Be 'Foo/Bar/x.al'; $i.layout | Should -Be 'src/Apps/{region}/{path}'
    }
    It 'tries every layout, ignores case in the fixed part, and normalizes separators' {
        (Get-RegionalPathInfo -FilePath 'SRC\layers\US\x.al' -Layouts $script:layouts).layout | Should -Be 'src/Layers/{region}/{path}'
        (Get-RegionalPathInfo -FilePath '/src/Apps/W1/x.al' -Layouts $script:layouts).region | Should -Be 'W1'
    }
    It 'returns nothing for a file outside every layout, and with no layouts' {
        Get-RegionalPathInfo -FilePath 'src/Other/DE/x.al' -Layouts $script:layouts | Should -BeNullOrEmpty
        Get-RegionalPathInfo -FilePath 'src/Apps/DE/x.al' -Layouts @() | Should -BeNullOrEmpty
    }
}

Describe 'Group-RegionalItems' {
    It 'changes nothing without layouts' {
        $items = @((New-Item2 'src/Apps/W1/x.al'), (New-Item2 'src/Apps/DE/x.al'))
        $r = Group-RegionalItems -Items $items -Layouts @()
        @($r.items).Count | Should -Be 2; $r.groups | Should -Be 0; $r.merged | Should -Be 0
    }
    It 'merges identical findings in several regions into one on the W1 copy, listing the others' {
        $items = @((New-Item2 'src/Apps/DE/Foo/x.al'), (New-Item2 'src/Apps/W1/Foo/x.al'), (New-Item2 'src/Apps/US/Foo/x.al'))
        $r = Group-RegionalItems -Items $items -Layouts $script:layouts
        @($r.items).Count | Should -Be 1; $r.groups | Should -Be 1; $r.merged | Should -Be 2
        $r.items[0].filePath | Should -Be 'src/Apps/W1/Foo/x.al'
        @($r.items[0].otherRegions | ForEach-Object region) | Should -Be @('DE', 'US')
        $r.items[0].content | Should -BeLike 'body*The same issue exists in these regional copies; apply the equivalent fix in each:*'
        $r.items[0].content.Contains('- `src/Apps/DE/Foo/x.al:10` (DE)') | Should -BeTrue
        $r.items[0].content.Contains('- `src/Apps/US/Foo/x.al:10` (US)') | Should -BeTrue
    }
    It 'uses the first region alphabetically when the primary region is not among them, and honors a configured primary' {
        $items = @((New-Item2 'src/Apps/US/x.al'), (New-Item2 'src/Apps/DE/x.al'))
        (Group-RegionalItems -Items $items -Layouts $script:layouts).items[0].filePath | Should -Be 'src/Apps/DE/x.al'
        $items = @((New-Item2 'src/Apps/US/x.al'), (New-Item2 'src/Apps/DE/x.al'))
        (Group-RegionalItems -Items $items -Layouts $script:layouts -Primary 'us').items[0].filePath | Should -Be 'src/Apps/US/x.al'
    }
    It 'never merges findings whose content differs, or that sit on different lines' {
        $items = @((New-Item2 'src/Apps/W1/x.al' -Identity 'a'), (New-Item2 'src/Apps/DE/x.al' -Identity 'b'))
        @((Group-RegionalItems -Items $items -Layouts $script:layouts).items).Count | Should -Be 2
        $items = @((New-Item2 'src/Apps/W1/x.al' -Line 10), (New-Item2 'src/Apps/DE/x.al' -Line 11))
        @((Group-RegionalItems -Items $items -Layouts $script:layouts).items).Count | Should -Be 2
    }
    It 'does not merge copies of the same region, or across different layouts' {
        $items = @((New-Item2 'src/Apps/DE/x.al'), (New-Item2 'src/Apps/DE/x.al'))
        @((Group-RegionalItems -Items $items -Layouts $script:layouts).items).Count | Should -Be 2
        $items = @((New-Item2 'src/Apps/W1/x.al'), (New-Item2 'src/Layers/DE/x.al'))
        @((Group-RegionalItems -Items $items -Layouts $script:layouts).items).Count | Should -Be 2
    }
    It 'leaves non-regional findings alone, keeps order, and handles two independent clusters' {
        $items = @((New-Item2 'src/Other/z.al'), (New-Item2 'src/Apps/DE/a.al'), (New-Item2 'src/Apps/W1/a.al'), (New-Item2 'src/Apps/DE/b.al'), (New-Item2 'src/Apps/W1/b.al'))
        $r = Group-RegionalItems -Items $items -Layouts $script:layouts
        $r.groups | Should -Be 2; $r.merged | Should -Be 2
        @($r.items | ForEach-Object { $_.filePath }) | Should -Be @('src/Other/z.al', 'src/Apps/W1/a.al', 'src/Apps/W1/b.al')
    }
    It 'skips an item with no identity' {
        $a = New-Item2 'src/Apps/W1/x.al'; $b = New-Item2 'src/Apps/DE/x.al'; $b.identity = ''
        @((Group-RegionalItems -Items @($a, $b) -Layouts $script:layouts).items).Count | Should -Be 2
    }
}

Describe 'Near-duplicate threads' {
    BeforeAll {
        function New-Thread {
            param([string] $Author = 'me', [string] $Rule = 'r1', [string] $Path = '/src/x.al', [int] $Line = 10, [string] $Kind = 'finding', [switch] $Deleted, [switch] $NoContext)
            $props = [ordered]@{ 'BCQuality.Fingerprint' = @{ '$type' = 'System.String'; '$value' = 'fp' }; 'BCQuality.Kind' = @{ '$type' = 'System.String'; '$value' = $Kind } }
            if ($Rule) { $props['BCQuality.Rule'] = @{ '$type' = 'System.String'; '$value' = $Rule } }
            $t = [ordered]@{ comments = @(@{ author = @{ id = $Author } }); properties = $props; isDeleted = [bool]$Deleted }
            if (-not $NoContext) { $t.threadContext = @{ filePath = $Path; rightFileStart = @{ line = $Line; offset = 1 } } }
            $t | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8
        }
    }
    It 'collects anchors only from our own, live finding threads that recorded their rule' {
        $threads = @(
            (New-Thread -Line 10)
            (New-Thread -Author 'someone-else' -Line 20)
            (New-Thread -Rule '' -Line 30)             # posted before rules were recorded
            (New-Thread -Kind summary -Line 40)
            (New-Thread -Deleted -Line 50)
            (New-Thread -NoContext)
        )
        $loc = Get-ExistingThreadLocations -Threads $threads -TrustedAuthorId 'me'
        $loc.Count | Should -Be 1
        $loc[0].line | Should -Be 10; $loc[0].path | Should -Be 'src/x.al'; $loc[0].rule | Should -Be 'r1'
    }
    It 'matches the same rule in the same file within the tolerance, either side' {
        $existing = @([pscustomobject]@{ path = 'src/x.al'; line = 10; rule = 'r1' })
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 10 -Rule 'r1' | Should -BeTrue
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 12 -Rule 'r1' | Should -BeTrue
        Test-NearDuplicateThread -Existing $existing -Path '/src/x.al' -Line 8 -Rule 'r1' | Should -BeTrue
    }
    It 'does not match a different rule, file, or a line beyond the tolerance' {
        $existing = @([pscustomobject]@{ path = 'src/x.al'; line = 10; rule = 'r1' })
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 13 -Rule 'r1' | Should -BeFalse
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 10 -Rule 'r2' | Should -BeFalse
        Test-NearDuplicateThread -Existing $existing -Path 'src/y.al' -Line 10 -Rule 'r1' | Should -BeFalse
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 13 -Rule 'r1' -Tolerance 3 | Should -BeTrue
    }
    It 'is off with a tolerance of 0, with no rule, and with nothing existing' {
        $existing = @([pscustomobject]@{ path = 'src/x.al'; line = 10; rule = 'r1' })
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 10 -Rule 'r1' -Tolerance 0 | Should -BeFalse
        Test-NearDuplicateThread -Existing $existing -Path 'src/x.al' -Line 10 -Rule '' | Should -BeFalse
        Test-NearDuplicateThread -Existing @() -Path 'src/x.al' -Line 10 -Rule 'r1' | Should -BeFalse
    }
    It 'records the rule on the thread only when given one' {
        (New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -FilePath 'src/x.al' -Line 1 -Rule 'r1').properties['BCQuality.Rule']['$value'] | Should -Be 'r1'
        (New-AdoThreadBody -Content 'm' -Fingerprint 'fp' -FilePath 'src/x.al' -Line 1).properties.ContainsKey('BCQuality.Rule') | Should -BeFalse
    }
}

Describe 'Regional and near-duplicate settings' {
    It 'default to no layouts, primary W1 and a tolerance of 2' {
        $s = Read-Settings -Json '' -SchemaPath $script:schema
        @($s.CodeReviewAgent.regional.layouts).Count | Should -Be 0
        $s.CodeReviewAgent.regional.primary | Should -Be 'W1'
        $s.CodeReviewAgent.nearDuplicateLines | Should -Be 2
    }
    It 'keep the default primary when only layouts are given' {
        $s = Read-Settings -Json '{"CodeReviewAgent":{"regional":{"layouts":["src/Apps/{region}/{path}"]}}}' -SchemaPath $script:schema
        @($s.CodeReviewAgent.regional.layouts) | Should -Be @('src/Apps/{region}/{path}')
        $s.CodeReviewAgent.regional.primary | Should -Be 'W1'
    }
    It 'reject a layout without both placeholders and an out-of-range tolerance' {
        { Read-Settings -Json '{"CodeReviewAgent":{"regional":{"layouts":["src/Apps/{region}"]}}}' -SchemaPath $script:schema } | Should -Throw
        { Read-Settings -Json '{"CodeReviewAgent":{"regional":{"layouts":["{path}"]}}}' -SchemaPath $script:schema } | Should -Throw
        { Read-Settings -Json '{"CodeReviewAgent":{"nearDuplicateLines":-1}}' -SchemaPath $script:schema } | Should -Throw
        { Read-Settings -Json '{"CodeReviewAgent":{"nearDuplicateLines":21}}' -SchemaPath $script:schema } | Should -Throw
        (Read-Settings -Json '{"CodeReviewAgent":{"nearDuplicateLines":0}}' -SchemaPath $script:schema).CodeReviewAgent.nearDuplicateLines | Should -Be 0
    }
}

Describe 'New-PublishPlan with regional copies' {
    BeforeAll {
        $script:work = Join-Path $TestDrive 'regional'
        $repo = Join-Path $script:work 'repo'
        $lines = @('codeunit 50000 X', '{', '    procedure A()', '    begin', "        if Rec.Count() > 0 then", '    end;', '}')
        foreach ($region in 'W1', 'DE', 'US') {
            New-Item -ItemType Directory -Path (Join-Path $repo "src/Apps/$region/Foo") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo "src/Apps/$region/Foo/x.al") -Value $lines
        }
        git -C $repo init -q 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
        git -C $repo -c user.email=t@t -c user.name=t commit -q -m c 2>&1 | Out-Null
        $head = (git -C $repo rev-parse HEAD).Trim()

        $diff = @'
diff --git a/x b/x
--- a/x
+++ b/x
@@ -3,2 +3,3 @@
     procedure A()
     begin
+        if Rec.Count() > 0 then
'@
        function New-F { param([string] $File, [string] $Id = 'k', [string] $Message = 'm')
            [ordered]@{ id = $Id; severity = 'minor'; message = $Message; location = [ordered]@{ file = $File; line = 5 }; references = @(); confidence = 'medium' } }
        $apps = foreach ($region in 'W1', 'DE', 'US') {
            $file = "src/Apps/$region/Foo/x.al"
            $appDir = Join-Path $script:work "app-$region"
            New-Item -ItemType Directory -Path (Join-Path $appDir "diff/src/Apps/$region/Foo") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $appDir "diff/$file.diff") -Value $diff
            $findings = @((New-F -File $file))
            if ($region -eq 'DE') { $findings += (New-F -File $file -Id 'other' -Message 'only in DE') }   # not repeated elsewhere
            $report = Join-Path $appDir 'accepted-report.json'
            [ordered]@{ outcome = 'completed'; findings = $findings } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $report
            [ordered]@{ reportPath = $report; files = @($file); diffDir = $appDir; outcomeReason = $null }
        }
        $script:resultPath = Join-Path $script:work 'result.json'
        [ordered]@{ outcome = 'completed'; reviewedHeadSha = $head; mode = 'advisory'; apps = @($apps) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:resultPath
        $script:repo = $repo; $script:head = $head
        function Invoke-Plan {
            param([string] $Name, $Agent)
            $ctx = Join-Path $script:work "ctx-$Name.json"
            [ordered]@{ headSha = $script:head; settings = [ordered]@{ BCQuality = [ordered]@{ repo = 'https://github.com/microsoft/BCQuality'; version = '1.9' }; CodeReviewAgent = $Agent } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ctx
            $out = Join-Path $script:work "plan-$Name.json"
            $null = & pwsh -NoProfile -File (Join-Path $script:scripts 'New-PublishPlan.ps1') -ResultPath $script:resultPath -ContextPath $ctx -RepoDir $script:repo -BCQualityCommit abc -OutPath $out
            if ($LASTEXITCODE -ne 0) { throw "New-PublishPlan.ps1 exited $LASTEXITCODE" }
            Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -Depth 20
        }
        $script:off = Invoke-Plan 'off' ([ordered]@{ suggestions = 'off' })
        $script:on = Invoke-Plan 'on' ([ordered]@{ suggestions = 'off'; regional = [ordered]@{ layouts = @('src/Apps/{region}/{path}') }; nearDuplicateLines = 3 })
    }
    It 'posts every copy when no layouts are configured' {
        @($script:off.items).Count | Should -Be 4
        $script:off.regional.groups | Should -Be 0
    }
    It 'merges the identical finding across W1, DE and US into one thread, and keeps the finding that is only in DE' {
        @($script:on.items).Count | Should -Be 2
        $script:on.regional.groups | Should -Be 1; $script:on.regional.merged | Should -Be 2
        $merged = $script:on.items | Where-Object { $_.rule -eq 'k' }
        $merged.filePath | Should -Be 'src/Apps/W1/Foo/x.al'
        $merged.content | Should -BeLike '*apply the equivalent fix in each*src/Apps/DE/Foo/x.al:5*(DE)*src/Apps/US/Foo/x.al:5*(US)*'
        ($script:on.items | Where-Object { $_.rule -eq 'other' }).filePath | Should -Be 'src/Apps/DE/Foo/x.al'
    }
    It 'records the rule on each item, the tolerance and the layouts, and leaves no internal fields behind' {
        $i = $script:on.items[0]
        $i.rule | Should -Not -BeNullOrEmpty
        $i.PSObject.Properties['identity'] | Should -BeNullOrEmpty
        $i.PSObject.Properties['_mode'] | Should -BeNullOrEmpty
        $script:on.nearDuplicateLines | Should -Be 3
        @($script:on.regional.layouts) | Should -Be @('src/Apps/{region}/{path}')
        $script:off.nearDuplicateLines | Should -Be 2
    }
    It 'keeps the primary fingerprint, so a rerun with or without grouping matches the same thread' {
        $offPrimary = $script:off.items | Where-Object { $_.rule -eq 'k' -and $_.filePath -eq 'src/Apps/W1/Foo/x.al' }
        ($script:on.items | Where-Object { $_.rule -eq 'k' }).fingerprint | Should -Be $offPrimary.fingerprint
    }
    It 'counts the suggestion outcome for the threads that are posted, not for merged copies' {
        $script:on.suggestions.none | Should -Be 2
    }
}
