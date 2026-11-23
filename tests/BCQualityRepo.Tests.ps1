BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\scripts'
    foreach ($f in 'Common', 'PublishPlan', 'BCQualityRepo') { . (Join-Path $script:scripts "$f.ps1") }
    $script:org = 'https://contoso.visualstudio.com/'
    $script:fork = 'https://contoso.visualstudio.com/Contoso%20Platform/_git/BCQuality'
}

Describe 'Same Azure DevOps organization' {
    It 'accepts a repository on the same organization host (visualstudio.com)' {
        Test-SameAdoOrganization -Url $script:fork -CollectionUri $script:org | Should -BeTrue
    }
    It 'accepts the same organization on dev.azure.com, with or without user info or a raw space' {
        $c = 'https://dev.azure.com/contoso/'
        Test-SameAdoOrganization -Url 'https://dev.azure.com/contoso/Proj/_git/BCQuality' -CollectionUri $c | Should -BeTrue
        Test-SameAdoOrganization -Url 'https://contoso@dev.azure.com/contoso/Proj/_git/BCQuality' -CollectionUri $c | Should -BeTrue
        Test-SameAdoOrganization -Url 'https://DEV.azure.com/Contoso/Proj One/_git/BCQuality' -CollectionUri $c | Should -BeTrue
    }
    It 'refuses another organization on dev.azure.com, even one whose name starts the same' {
        $c = 'https://dev.azure.com/contoso/'
        Test-SameAdoOrganization -Url 'https://dev.azure.com/other/Proj/_git/BCQuality' -CollectionUri $c | Should -BeFalse
        Test-SameAdoOrganization -Url 'https://dev.azure.com/contoso-evil/Proj/_git/BCQuality' -CollectionUri $c | Should -BeFalse
    }
    It 'refuses another host, a look-alike host, GitHub and anything that is not https' {
        Test-SameAdoOrganization -Url 'https://github.com/microsoft/BCQuality' -CollectionUri $script:org | Should -BeFalse
        Test-SameAdoOrganization -Url 'https://contoso.visualstudio.com.evil.example/x/_git/y' -CollectionUri $script:org | Should -BeFalse
        Test-SameAdoOrganization -Url 'http://contoso.visualstudio.com/P/_git/R' -CollectionUri $script:org | Should -BeFalse
        Test-SameAdoOrganization -Url 'C:\repos\BCQuality' -CollectionUri $script:org | Should -BeFalse
        Test-SameAdoOrganization -Url '' -CollectionUri $script:org | Should -BeFalse
        Test-SameAdoOrganization -Url $script:fork -CollectionUri '' | Should -BeFalse
    }
    It 'matches an Azure DevOps Server collection by host and collection path' {
        $c = 'https://tfs.contoso.com/tfs/DefaultCollection/'
        Test-SameAdoOrganization -Url 'https://tfs.contoso.com/tfs/DefaultCollection/P/_git/BCQuality' -CollectionUri $c | Should -BeTrue
        Test-SameAdoOrganization -Url 'https://tfs.contoso.com/tfs/OtherCollection/P/_git/BCQuality' -CollectionUri $c | Should -BeFalse
    }
}

Describe 'Links to knowledge articles' {
    It 'uses a GitHub style blob link for a GitHub repository' {
        Get-KnowledgeBaseUrl -Repo 'https://github.com/microsoft/BCQuality/' -Commit 'abc' | Should -Be 'https://github.com/microsoft/BCQuality/blob/abc'
    }
    It 'uses a ?path= link for an Azure DevOps repository, with the project name escaped and no user info' {
        $expected = 'https://contoso.visualstudio.com/Contoso%20Platform/_git/BCQuality?path=/{path}&version=GCabc'
        Get-KnowledgeBaseUrl -Repo $script:fork -Commit 'abc' | Should -Be $expected
        Get-KnowledgeBaseUrl -Repo 'https://contoso.visualstudio.com/Contoso Platform/_git/BCQuality/' -Commit 'abc' | Should -Be $expected
        Get-KnowledgeBaseUrl -Repo 'https://contoso@dev.azure.com/contoso/P/_git/BCQuality' -Commit 'abc' |
            Should -Be 'https://dev.azure.com/contoso/P/_git/BCQuality?path=/{path}&version=GCabc'
    }
    It 'puts the article path where {path} is, escaped, in a markdown link' {
        $base = Get-KnowledgeBaseUrl -Repo $script:fork -Commit 'abc'
        New-KnowledgeLink -Path 'custom/knowledge/style/a b (c).md' -KnowledgeBaseUrl $base |
            Should -Be '[custom/knowledge/style/a b (c).md](https://contoso.visualstudio.com/Contoso%20Platform/_git/BCQuality?path=/custom/knowledge/style/a%20b%20%28c%29.md&version=GCabc)'
    }
    It 'still appends the path to a base URL without {path}' {
        New-KnowledgeLink -Path 'microsoft/a.md' -KnowledgeBaseUrl 'https://x/blob/c/' | Should -Be '[microsoft/a.md](https://x/blob/c/microsoft/a.md)'
    }
}

Describe 'Cloning with the build identity' {
    BeforeAll {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:gitExit = 0
        # Stands in for git: records its arguments and the environment it was started with.
        function git {
            $script:calls.Add([pscustomobject]@{ Args = @($args); Count = $env:GIT_CONFIG_COUNT; Key = $env:GIT_CONFIG_KEY_0; Value = $env:GIT_CONFIG_VALUE_0; Prompt = $env:GIT_TERMINAL_PROMPT })
            $global:LASTEXITCODE = $script:gitExit
            if ($script:gitExit -ne 0) { 'fatal: Authentication failed' }
        }
    }
    AfterAll { Remove-Item Function:\git -ErrorAction SilentlyContinue }
    BeforeEach { $script:calls.Clear(); $script:gitExit = 0 }

    It 'sends the token as a header through the environment for a repository in the same organization' {
        $used = Invoke-BCQualityClone -Repo $script:fork -Version '1.9' -Root 'r' -CollectionUri $script:org -Token 'SECRET'
        $used | Should -BeTrue
        $script:calls.Count | Should -Be 1
        $c = $script:calls[0]
        $c.Key | Should -Be 'http.extraheader'
        $c.Value | Should -Be 'AUTHORIZATION: bearer SECRET'
        $c.Count | Should -Be '1'
        $c.Prompt | Should -Be '0'
        ($c.Args -join ' ') | Should -Be "clone --quiet --depth 1 --branch v1.9 $script:fork r"
        ($c.Args -join ' ') | Should -Not -Match 'SECRET'
    }
    It 'leaves the environment as it found it, also after a failure' {
        $env:GIT_CONFIG_COUNT = $null; $env:GIT_TERMINAL_PROMPT = 'keep'
        $script:gitExit = 128
        { Invoke-BCQualityClone -Repo $script:fork -Version '1.9' -Root 'r' -CollectionUri $script:org -Token 'SECRET' } | Should -Throw
        $env:GIT_CONFIG_COUNT | Should -BeNullOrEmpty
        $env:GIT_CONFIG_KEY_0 | Should -BeNullOrEmpty
        $env:GIT_CONFIG_VALUE_0 | Should -BeNullOrEmpty
        $env:GIT_TERMINAL_PROMPT | Should -Be 'keep'
        $env:GIT_TERMINAL_PROMPT = $null
    }
    It 'sends no credentials to another host' {
        $used = Invoke-BCQualityClone -Repo 'https://github.com/microsoft/BCQuality' -Version '1.9' -Root 'r' -CollectionUri $script:org -Token 'SECRET'
        $used | Should -BeFalse
        $script:calls[0].Key | Should -BeNullOrEmpty
        $script:calls[0].Value | Should -BeNullOrEmpty
    }
    It 'sends no credentials when there is no token or no collection URI' {
        (Invoke-BCQualityClone -Repo $script:fork -Version '1.9' -Root 'r' -CollectionUri $script:org -Token '') | Should -BeFalse
        (Invoke-BCQualityClone -Repo $script:fork -Version '1.9' -Root 'r' -CollectionUri '' -Token 'SECRET') | Should -BeFalse
        $script:calls | ForEach-Object { $_.Value | Should -BeNullOrEmpty }
    }
    It 'names the fix when a same-organization clone fails, and never prints the token' {
        $script:gitExit = 128
        $m = try { Invoke-BCQualityClone -Repo $script:fork -Version '1.9' -Root 'r' -CollectionUri $script:org -Token 'SECRET'; $null } catch { $_.Exception.Message }
        $m | Should -Match 'Read access'
        $m | Should -Match 'tag v1\.9'
        $m | Should -Match 'Authentication failed'
        $m | Should -Not -Match 'SECRET'
        $m = try { Invoke-BCQualityClone -Repo $script:fork -Version '1.9' -Root 'r' -CollectionUri $script:org -Token ''; $null } catch { $_.Exception.Message }
        $m | Should -Match 'SYSTEM_ACCESSTOKEN'
        $m = try { Invoke-BCQualityClone -Repo 'https://github.com/x/y' -Version '1.9' -Root 'r' -CollectionUri $script:org -Token 'SECRET'; $null } catch { $_.Exception.Message }
        $m | Should -Match 'publicly readable'
    }
}

Describe 'Cloning a tag with real git' {
    BeforeAll {
        $script:haveGit = [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
        if ($script:haveGit) {
            $script:src = Join-Path $TestDrive 'fork'
            git init --quiet $script:src
            git -C $script:src -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m one
            git -C $script:src tag v1.9
        }
    }
    It 'clones the tagged release' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        $root = Join-Path $TestDrive 'clone'
        Invoke-BCQualityClone -Repo $script:src -Version '1.9' -Root $root | Should -BeFalse
        (git -C $root rev-parse HEAD) | Should -Be (git -C $script:src rev-parse HEAD)
    }
    It 'fails with a message when the tag does not exist' -Skip:(-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        { Invoke-BCQualityClone -Repo $script:src -Version '9.9' -Root (Join-Path $TestDrive 'nope') } | Should -Throw '*Could not clone BCQuality v9.9*'
    }
}
