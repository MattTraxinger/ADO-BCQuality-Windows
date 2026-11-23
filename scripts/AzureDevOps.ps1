# Azure DevOps REST calls for pull request threads, statuses and head checks.
# Every endpoint and field name marked (verify) is marked (verify) until confirmed on a live run.
Set-StrictMode -Version Latest

function New-AdoContext {
    param(
        [Parameter(Mandatory)] [string] $CollectionUri,   # $(System.CollectionUri)
        [Parameter(Mandatory)] [string] $Project,
        [Parameter(Mandatory)] [string] $RepositoryId,
        [Parameter(Mandatory)] [int] $PullRequestId,
        [Parameter(Mandatory)] [string] $Token
    )
    [pscustomobject]@{
        Root    = $CollectionUri.TrimEnd('/')
        Base    = "$($CollectionUri.TrimEnd('/'))/$([uri]::EscapeDataString($Project))/_apis"
        Repo    = $RepositoryId
        Pr      = $PullRequestId
        Headers = @{ Authorization = "Bearer $Token" }
    }
}

function Invoke-Ado {
    param($Ctx, [string] $Url, [string] $Method = 'GET', $Body, [string] $ApiVersion = '7.1')
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    $request = @{ Uri = "$Url${sep}api-version=$ApiVersion"; Method = $Method; Headers = $Ctx.Headers }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 20
        $request.ContentType = 'application/json'
    }
    Invoke-RestMethod @request
}

function Get-PrUrl {
    param($Ctx, [string] $Suffix = '')
    "$($Ctx.Base)/git/repositories/$($Ctx.Repo)/pullRequests/$($Ctx.Pr)$Suffix"
}

function Get-AdoPullRequest {
    param($Ctx)
    Invoke-Ado $Ctx (Get-PrUrl $Ctx)
}

function Get-AdoAuthenticatedUserId {
    # The identity that authors our threads (verify: connectionData shape for the build service).
    param($Ctx)
    (Invoke-Ado $Ctx "$($Ctx.Root)/_apis/connectionData" -ApiVersion '7.1-preview').authenticatedUser.id   # preview-only endpoint
}

function Get-AdoThreads {
    param($Ctx)
    (Invoke-Ado $Ctx (Get-PrUrl $Ctx '/threads')).value
}

function Assert-PrHeadUnchanged {
    # Returns $true when the PR's current source commit equals the reviewed SHA.
    param([Parameter(Mandatory)] [string] $ReviewedSha, [Parameter(Mandatory)] [scriptblock] $GetCurrentHead)
    $current = & $GetCurrentHead
    $current -ieq $ReviewedSha
}

function New-AdoThreadBody {
    # Builds the REST body. File-anchored when -FilePath and -Line are given (verify field names).
    # -EndLine/-EndOffset anchor the thread over a span (a suggestion replaces the lines its thread covers); without
    # them the thread covers the first character of -Line, as before.
    # -Rule (the finding's knowledge id) is stored on the thread so a later run can recognize a near-duplicate of it.
    # -Status 'closed' posts the thread already resolved, so it does not hold the PR's comment-resolution policy.
    param([Parameter(Mandatory)] [string] $Content, [Parameter(Mandatory)] [string] $Fingerprint,
          [string] $FilePath, [int] $Line, [string] $Kind = 'finding', [int] $EndLine, [int] $EndOffset, [string] $Rule,
          [ValidateSet('active', 'closed')] [string] $Status = 'active')
    $body = [ordered]@{
        comments   = @(@{ parentCommentId = 0; content = $Content; commentType = 1 })
        status     = $(if ($Status -eq 'closed') { 4 } else { 1 })   # 1 active, 4 closed
        properties = @{
            'BCQuality.Fingerprint' = @{ '$type' = 'System.String'; '$value' = $Fingerprint }
            'BCQuality.Kind'        = @{ '$type' = 'System.String'; '$value' = $Kind }
        }
    }
    if ($Rule) { $body.properties['BCQuality.Rule'] = @{ '$type' = 'System.String'; '$value' = $Rule } }
    if ($FilePath -and $Line -gt 0) {
        $body.threadContext = [ordered]@{
            filePath       = '/' + ($FilePath -replace '\\', '/').TrimStart('/')
            rightFileStart = @{ line = $Line; offset = 1 }
            rightFileEnd   = @{ line = $(if ($EndLine -gt $Line) { $EndLine } else { $Line }); offset = $(if ($EndOffset -gt 0) { $EndOffset } else { 2 }) }
        }
    }
    $body
}

function Add-AdoThread {
    param($Ctx, [Parameter(Mandatory)] $Body)
    Invoke-Ado $Ctx (Get-PrUrl $Ctx '/threads') -Method POST -Body $Body
}

function Set-AdoPrStatus {
    # state: succeeded | failed | notApplicable (verify). The context name is what a team makes required.
    param($Ctx, [ValidateSet('succeeded', 'failed', 'notApplicable')] [string] $State, [string] $Description, [string] $TargetUrl)
    $body = @{ state = $State; description = $Description; context = @{ name = 'review'; genre = 'bcquality' } }
    if ($TargetUrl) { $body.targetUrl = $TargetUrl }
    Invoke-Ado $Ctx (Get-PrUrl $Ctx '/statuses') -Method POST -Body $body
}
