# Where BCQuality comes from: cloning the pinned release (with the build's own token when the repository is in this
# Azure DevOps organization, as an organization fork usually is) and linking review comments to its articles.
Set-StrictMode -Version Latest

function Get-RepoLocation {
    # { Host; Authority; Path } of an https URL; $null for anything else. Path is the escaped absolute path.
    param([string] $Url)
    $uri = $null
    if (-not $Url -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { return $null }
    [pscustomobject]@{ Host = $uri.Host.ToLowerInvariant(); Authority = $uri.Authority.ToLowerInvariant(); Path = $uri.AbsolutePath }
}

function Test-SameAdoOrganization {
    # True when $Url is on the host of the build's collection URI and under its path. That is the organization on
    # dev.azure.com (https://dev.azure.com/<org>/...), any repository on <org>.visualstudio.com, and the collection of an
    # Azure DevOps Server. The token is sent only when this is true, so a settings file cannot send it to another host.
    param([string] $Url, [string] $CollectionUri)
    $repo = Get-RepoLocation $Url
    $collection = Get-RepoLocation $CollectionUri
    if (-not $repo -or -not $collection -or $repo.Authority -ne $collection.Authority) { return $false }
    $prefix = $collection.Path.TrimEnd('/') + '/'
    ($repo.Path.TrimEnd('/') + '/').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-BCQualityClone {
    # Clones tag v<Version> of the BCQuality repository into $Root. For a repository in the build's own organization the
    # token goes in as a one-off http header through the environment of this git process only, so it is not on the
    # command line and not written to the clone's .git/config. Returns $true when the token was used.
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $Root,
        [string] $CollectionUri,
        [string] $Token
    )
    $sameOrg = [bool]($CollectionUri -and (Test-SameAdoOrganization -Url $Repo -CollectionUri $CollectionUri))
    $useToken = $sameOrg -and [bool]$Token
    $names = 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_TERMINAL_PROMPT'
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:GIT_TERMINAL_PROMPT = '0'   # a repository that needs credentials must fail, not wait for a prompt
        if ($useToken) {
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'http.extraheader'
            $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: bearer $Token"
        }
        $output = git clone --quiet --depth 1 --branch "v$Version" $Repo $Root 2>&1
        $ok = $LASTEXITCODE -eq 0
    }
    finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
    if (-not $ok) {
        $hint = if ($useToken) { "The build identity was used; it needs Read access to that repository, and the tag v$Version must exist." }
        elseif ($sameOrg) { 'The repository is in this Azure DevOps organization, so map SYSTEM_ACCESSTOKEN into this step and give the build service Read access to it.' }
        else { 'Check that the repository is publicly readable (no credentials are sent to other hosts) and that the tag exists.' }
        throw "Could not clone BCQuality v$Version from $Repo. $hint $((@($output) | Out-String).Trim())"
    }
    $useToken
}

function Get-KnowledgeBaseUrl {
    # Where an article path goes to make a link. GitHub style (<repo>/blob/<commit>/<path>) is the default; an Azure DevOps
    # repository (a /_git/ URL) uses <repo>?path=/<path>&version=GC<commit>, written with {path} marking the spot.
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Commit)
    $location = Get-RepoLocation $Repo
    if ($location -and $location.Path -match '/_git/') {
        # Rebuilt from host and path so any user name in the URL is dropped.
        return "https://$($location.Authority)$($location.Path.TrimEnd('/'))?path=/{path}&version=GC$Commit"
    }
    "$($Repo.TrimEnd('/'))/blob/$Commit"
}
