BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Common.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\KnowledgePolicy.ps1')
    $script:schema = Join-Path $PSScriptRoot '..\schemas\bcquality-ado.settings.schema.json'

    function New-FakeClone {
        # A minimal BCQuality clone: articles with sibling samples in three layers, and a stand-in index builder
        # that behaves like the real one (lists the .md files of the enabled layers, applies no allow/deny).
        param([string] $Root)
        $files = @(
            'microsoft/knowledge/security/a-secret.md', 'microsoft/knowledge/security/a-secret.good.al', 'microsoft/knowledge/security/a-secret.bad.al',
            'microsoft/knowledge/security/a-secret-extra.md',
            'microsoft/knowledge/performance/slow-loop.md', 'microsoft/knowledge/performance/slow-loop.bad.al',
            'community/knowledge/agents/agent-setup.md', 'community/knowledge/agents/agent-setup.good.al',
            'custom/knowledge/team/naming.md', 'custom/knowledge/team/.gitkeep',
            'microsoft/skills/review/al-code-review.md', 'community/skills/review/community-review.md', 'custom/skills/review/team-review.md')
        foreach ($f in $files) {
            $p = Join-Path $Root $f
            New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
            Set-Content -LiteralPath $p -Value "content of $f"
        }
        New-Item -ItemType Directory -Path (Join-Path $Root 'tools') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'tools/Build-KnowledgeIndex.ps1') -Value @'
param([string] $BCQualityRoot, [string] $IndexPath, [string[]] $EnabledLayers, [string[]] $KnowledgeAllow = @(), [string[]] $KnowledgeDeny = @())
$rows = foreach ($layer in $EnabledLayers) {
    $k = Join-Path $BCQualityRoot "$layer/knowledge"
    if (Test-Path $k) { Get-ChildItem $k -Recurse -File -Filter '*.md' | ForEach-Object {
        [ordered]@{ path = ([System.IO.Path]::GetRelativePath($BCQualityRoot, $_.FullName) -replace '\\', '/'); domain = (Split-Path $_.DirectoryName -Leaf) } } }
}
[ordered]@{ version = 1; articles = @($rows) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $IndexPath
'@
    }

    function Get-Rel {
        param([string] $Root)
        @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\', '/' } | Sort-Object)
    }
}

Describe 'Knowledge globs' {
    It 'keeps * and ? inside one path segment' {
        Test-KnowledgeGlob 'microsoft/knowledge/security/a.md' 'microsoft/knowledge/*/a.md' | Should -BeTrue
        Test-KnowledgeGlob 'microsoft/knowledge/security/deep/a.md' 'microsoft/knowledge/*/a.md' | Should -BeFalse
        Test-KnowledgeGlob 'microsoft/knowledge/security/a.md' 'microsoft/knowledge/security/?.md' | Should -BeTrue
        Test-KnowledgeGlob 'microsoft/knowledge/security/ab.md' 'microsoft/knowledge/security/?.md' | Should -BeFalse
    }
    It 'matches any depth with **/ including none, and anything with a trailing **' {
        Test-KnowledgeGlob 'microsoft/knowledge/security/a.md' '**/security/**' | Should -BeTrue
        Test-KnowledgeGlob 'security/a.md' '**/security/**' | Should -BeTrue
        Test-KnowledgeGlob 'microsoft/knowledge/performance/a.md' '**/security/**' | Should -BeFalse
        Test-KnowledgeGlob 'microsoft/knowledge/security/a.md' 'microsoft/**' | Should -BeTrue
    }
    It 'treats regex characters literally and is case-sensitive' {
        Test-KnowledgeGlob 'microsoft/knowledge/x/a+b(1).md' 'microsoft/knowledge/x/a+b(1).md' | Should -BeTrue
        Test-KnowledgeGlob 'microsoft/knowledge/x/aab.md' 'microsoft/knowledge/x/a+b.md' | Should -BeFalse
        Test-KnowledgeGlob 'microsoft/knowledge/x/A.md' 'microsoft/knowledge/x/a.md' | Should -BeFalse
    }
    It 'accepts backslashes as separators' {
        Test-KnowledgeGlob 'microsoft/knowledge/security/a.md' 'microsoft\knowledge\security\*.md' | Should -BeTrue
    }
    It 'rejects empty, rooted and parent-directory patterns' {
        { Assert-KnowledgePatterns -Patterns @('') -Name 'deny' } | Should -Throw '*empty*'
        { Assert-KnowledgePatterns -Patterns @('/etc/**') -Name 'deny' } | Should -Throw '*relative*'
        { Assert-KnowledgePatterns -Patterns @('C:/x/**') -Name 'allow' } | Should -Throw '*relative*'
        { Assert-KnowledgePatterns -Patterns @('microsoft/../x') -Name 'deny' } | Should -Throw '*..*'
    }
}

Describe 'Invoke-KnowledgePolicy' {
    BeforeEach {
        $script:root = Join-Path $TestDrive "clone-$([guid]::NewGuid().ToString('N'))"
        New-FakeClone -Root $script:root
    }

    It 'removes nothing and indexes every article when no rule is set' {
        $r = Invoke-KnowledgePolicy -BCQualityRoot $script:root
        $r.removedCount | Should -Be 0
        $r.indexedCount | Should -Be 5
        (Get-Rel $script:root) | Should -Contain 'microsoft/knowledge/security/a-secret.good.al'
    }

    It 'deny removes the article and its samples, and only those' {
        $r = Invoke-KnowledgePolicy -BCQualityRoot $script:root -Deny @('**/security/a-secret.md')
        $files = Get-Rel $script:root
        $files | Should -Not -Contain 'microsoft/knowledge/security/a-secret.md'
        $files | Should -Not -Contain 'microsoft/knowledge/security/a-secret.good.al'
        $files | Should -Not -Contain 'microsoft/knowledge/security/a-secret.bad.al'
        $files | Should -Contain 'microsoft/knowledge/security/a-secret-extra.md'   # a longer slug is not a sample of this article
        $files | Should -Contain 'microsoft/knowledge/performance/slow-loop.md'
        $r.removedCount | Should -Be 1
        @($r.removed | ForEach-Object path) | Should -Contain 'microsoft/knowledge/security/a-secret.good.al'
        ($r.removed | Where-Object path -EQ 'microsoft/knowledge/security/a-secret.md').reason | Should -Be 'deny-list-hit'
        (Get-Content (Join-Path $script:root 'knowledge-index.json') -Raw | ConvertFrom-Json).articles.path | Should -Not -Contain 'microsoft/knowledge/security/a-secret.md'
    }

    It 'allow keeps only matching articles and records the others as allow-list-miss' {
        $r = Invoke-KnowledgePolicy -BCQualityRoot $script:root -Allow @('microsoft/knowledge/security/**')
        $idx = (Get-Content (Join-Path $script:root 'knowledge-index.json') -Raw | ConvertFrom-Json).articles.path
        @($idx | Sort-Object) | Should -Be @('microsoft/knowledge/security/a-secret-extra.md', 'microsoft/knowledge/security/a-secret.md')
        ($r.removed | Where-Object path -EQ 'community/knowledge/agents/agent-setup.md').reason | Should -Be 'allow-list-miss'
        (Get-Rel $script:root) | Should -Not -Contain 'community/knowledge/agents/agent-setup.good.al'
    }

    It 'deny wins over allow' {
        $null = Invoke-KnowledgePolicy -BCQualityRoot $script:root -Allow @('microsoft/knowledge/security/**') -Deny @('**/a-secret-extra.md')
        $idx = (Get-Content (Join-Path $script:root 'knowledge-index.json') -Raw | ConvertFrom-Json).articles.path
        @($idx) | Should -Be @('microsoft/knowledge/security/a-secret.md')
    }

    It 'deletes a disabled layer: its knowledge, samples and skills, but not placeholder files' {
        $r = Invoke-KnowledgePolicy -BCQualityRoot $script:root -EnabledLayers @('microsoft', 'custom')
        $files = Get-Rel $script:root
        $files | Should -Not -Contain 'community/knowledge/agents/agent-setup.md'
        $files | Should -Not -Contain 'community/knowledge/agents/agent-setup.good.al'
        $files | Should -Not -Contain 'community/skills/review/community-review.md'
        $files | Should -Contain 'custom/skills/review/team-review.md'
        $files | Should -Contain 'microsoft/skills/review/al-code-review.md'
        ($r.removed | Where-Object path -EQ 'community/knowledge/agents/agent-setup.md').reason | Should -Be 'layer-disabled'
        ($r.removed | Where-Object path -EQ 'community/skills/review/community-review.md').kind | Should -Be 'skill'
        ($r.removed | Where-Object path -EQ 'community/knowledge/agents/agent-setup.good.al').kind | Should -Be 'knowledge-sample'
        (Get-Content (Join-Path $script:root 'knowledge-index.json') -Raw | ConvertFrom-Json).articles.path | Should -Not -Contain 'community/knowledge/agents/agent-setup.md'
    }

    It 'leaves a placeholder in a disabled layer alone' {
        $null = Invoke-KnowledgePolicy -BCQualityRoot $script:root -EnabledLayers @('microsoft', 'community')
        (Get-Rel $script:root) | Should -Contain 'custom/knowledge/team/.gitkeep'
        (Get-Rel $script:root) | Should -Not -Contain 'custom/knowledge/team/naming.md'
    }

    It 'applies allow/deny to enabled layers and records disabled-layer removals separately' {
        $r = Invoke-KnowledgePolicy -BCQualityRoot $script:root -EnabledLayers @('microsoft') -Deny @('**/performance/**')
        ($r.removed | Where-Object path -EQ 'microsoft/knowledge/performance/slow-loop.md').reason | Should -Be 'deny-list-hit'
        ($r.removed | Where-Object path -EQ 'community/knowledge/agents/agent-setup.md').reason | Should -Be 'layer-disabled'
    }

    It 'refuses to run without the microsoft layer, before touching any file' {
        { Invoke-KnowledgePolicy -BCQualityRoot $script:root -EnabledLayers @('community') } | Should -Throw "*must include 'microsoft'*"
        (Get-Rel $script:root) | Should -Contain 'community/knowledge/agents/agent-setup.md'
    }

    It 'a pattern that matches nothing removes nothing' {
        (Invoke-KnowledgePolicy -BCQualityRoot $script:root -Deny @('**/no-such-domain/**')).removedCount | Should -Be 0
    }

    It 'writes a report with the policy, counts and content hash' {
        $null = Invoke-KnowledgePolicy -BCQualityRoot $script:root -Deny @('**/performance/**')
        $report = Get-Content (Join-Path $script:root '_filter-report.json') -Raw | ConvertFrom-Json
        $report.knowledgeDeny | Should -Be @('**/performance/**')
        $report.removedCount | Should -Be 1
        $report.contentHash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'gives the same content hash for the same clone and policy, and a different one when content is removed' {
        $a = Invoke-KnowledgePolicy -BCQualityRoot $script:root
        $b = Invoke-KnowledgePolicy -BCQualityRoot $script:root
        $b.contentHash | Should -Be $a.contentHash
        $c = Invoke-KnowledgePolicy -BCQualityRoot $script:root -Deny @('**/performance/**')
        $c.contentHash | Should -Not -Be $a.contentHash
    }

    It 'ignores git metadata when hashing' {
        $a = Invoke-KnowledgePolicy -BCQualityRoot $script:root
        New-Item -ItemType Directory -Path (Join-Path $script:root '.git') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root '.git/HEAD') -Value 'ref: refs/heads/x'
        (Invoke-KnowledgePolicy -BCQualityRoot $script:root).contentHash | Should -Be $a.contentHash
    }

    It 'rejects an unknown layer and a clone without the index builder' {
        { Invoke-KnowledgePolicy -BCQualityRoot $script:root -EnabledLayers @('nope') } | Should -Throw '*Unknown BCQuality layer*'
        Remove-Item -LiteralPath (Join-Path $script:root 'tools') -Recurse -Force
        { Invoke-KnowledgePolicy -BCQualityRoot $script:root } | Should -Throw '*Build-KnowledgeIndex*'
    }

    It 'warns when the rules remove every article' {
        $null = Invoke-KnowledgePolicy -BCQualityRoot $script:root -Deny @('**') -WarningVariable w -WarningAction SilentlyContinue
        $w | Should -Not -BeNullOrEmpty
    }
}

# Regression: the setup step's `$allow = if (...) { @(...) } else { @() }` turned an empty list into $null, which the
# policy read as one empty pattern and rejected, so every repo without knowledge rules failed at "Install pinned
# BCQuality". These run the step's own lines, taken from the YAML, so the step cannot drift from what is tested.
Describe 'Setup step inputs' {
    BeforeAll {
        # In this repo the step lives in scripts/Initialize-BCQuality.ps1, shared by the standalone template and the in-job flow.
        $yml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Initialize-BCQuality.ps1') -Raw
        $script:stepLines = @($yml -split "`r?`n" | Where-Object { $_ -match '^\s*\$(allow|deny) = ' } | ForEach-Object { $_.Trim() })
        function Read-StepRules {
            # What the step computes from a context.json that was written with the given settings JSON.
            param([string] $SettingsJson)
            $settings = Read-Settings -Json $SettingsJson -SchemaPath $script:schema
            $ctx = [ordered]@{ settings = $settings } | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
            $knowledge = $ctx.settings.BCQuality.PSObject.Properties['knowledge']
            foreach ($line in $script:stepLines) { Invoke-Expression $line }
            [pscustomobject]@{ allow = $allow; deny = $deny }
        }
    }
    It 'finds the two lines that read the rules' { $script:stepLines.Count | Should -Be 2 }
    It 'runs the policy with the default, empty rules' {
        $r = Read-StepRules ''
        @($r.allow).Count | Should -Be 0
        $root = Join-Path $TestDrive "step-$([guid]::NewGuid().ToString('N'))"; New-FakeClone -Root $root
        { Invoke-KnowledgePolicy -BCQualityRoot $root -Allow $r.allow -Deny $r.deny } | Should -Not -Throw
        (Invoke-KnowledgePolicy -BCQualityRoot $root -Allow $r.allow -Deny $r.deny).removedCount | Should -Be 0
    }
    It 'passes only the rules that are set, leaving the other list empty' {
        $r = Read-StepRules '{"BCQuality":{"knowledge":{"deny":["**/performance/**"]}}}'
        @($r.allow).Count | Should -Be 0
        @($r.deny) | Should -Be @('**/performance/**')
        $root = Join-Path $TestDrive "step-$([guid]::NewGuid().ToString('N'))"; New-FakeClone -Root $root
        (Invoke-KnowledgePolicy -BCQualityRoot $root -Allow $r.allow -Deny $r.deny).removedCount | Should -Be 1
    }
    It 'treats $null like an empty list, and still rejects an empty string inside a list' {
        $root = Join-Path $TestDrive "step-$([guid]::NewGuid().ToString('N'))"; New-FakeClone -Root $root
        { Invoke-KnowledgePolicy -BCQualityRoot $root -Allow $null -Deny $null } | Should -Not -Throw
        @(Assert-KnowledgePatterns -Patterns $null -Name 'allow').Count | Should -Be 0
        { Assert-KnowledgePatterns -Patterns @('ok', '') -Name 'allow' } | Should -Throw '*empty*'
    }
}

Describe 'knowledge settings' {
    It 'defaults to empty allow and deny' {
        $s = Read-Settings -Json '' -SchemaPath $schema
        @($s.BCQuality.knowledge.allow).Count | Should -Be 0
        @($s.BCQuality.knowledge.deny).Count | Should -Be 0
    }
    It 'setting only allow keeps the default deny, and other BCQuality keys are untouched' {
        $s = Read-Settings -Json '{"BCQuality":{"knowledge":{"allow":["microsoft/**"]}}}' -SchemaPath $schema
        $s.BCQuality.knowledge.allow | Should -Be @('microsoft/**')
        @($s.BCQuality.knowledge.deny).Count | Should -Be 0
        @($s.BCQuality.enabledLayers).Count | Should -Be 3
    }
    It 'survives the JSON round trip through the context file' {
        $s = Read-Settings -Json '{"BCQuality":{"knowledge":{"deny":["**/x/**"]}}}' -SchemaPath $schema
        $back = $s | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $back.BCQuality.knowledge.deny | Should -Be @('**/x/**')
        @($back.BCQuality.knowledge.allow).Count | Should -Be 0
    }
    It 'rejects unknown keys and empty patterns' {
        { Read-Settings -Json '{"BCQuality":{"knowledge":{"block":[]}}}' -SchemaPath $schema } | Should -Throw
        { Read-Settings -Json '{"BCQuality":{"knowledge":{"deny":[""]}}}' -SchemaPath $schema } | Should -Throw
        { Read-Settings -Json '{"BCQuality":{"knowledge":{"allow":"microsoft/**"}}}' -SchemaPath $schema } | Should -Throw
    }
}
