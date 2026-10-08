# Define some useful Functions 
$ConfluenceSourceStrategies = @(
[PSCustomObject]@{
    OptionMessage= "From a Single/Specific Confluence Space"
    Identifier = 0
}, 
[PSCustomObject]@{
    OptionMessage= "From All Confluence Space(s)"
    Identifier = 1
},
[PSCustomObject]@{
    OptionMessage= "From Multiple Selected Confluence Space(s)"
    Identifier = 2
}
)

function Get-ConfluenceRetryStatusCodes {
    $configured = $ConfluenceRequestRetryStatusCodes ?? $env:CONFLUENCE_REQUEST_RETRY_STATUS_CODES
    if ($null -eq $configured) {
        return @(429, 500, 502, 503, 504)
    }

    $values = @()
    foreach ($item in @($configured)) {
        foreach ($part in ("$item" -split ',')) {
            $code = 0
            if ([int]::TryParse($part.Trim(), [ref]$code)) {
                $values += $code
            }
        }
    }

    if ($values.Count -eq 0) {
        return @(429, 500, 502, 503, 504)
    }

    return @($values | Select-Object -Unique)
}

function Get-ConfluenceResponseStatusCode {
    param(
        [object]$Response,
        [object]$ErrorRecord
    )

    foreach ($candidate in @(
        $Response,
        $ErrorRecord.Exception.Response,
        $ErrorRecord.Exception
    )) {
        if ($null -eq $candidate) { continue }

        try {
            if ($candidate.PSObject.Properties['StatusCode'] -and $null -ne $candidate.StatusCode) {
                return [int]$candidate.StatusCode
            }
        } catch {}

        try {
            if ($candidate.Response -and $candidate.Response.PSObject.Properties['StatusCode'] -and $null -ne $candidate.Response.StatusCode) {
                return [int]$candidate.Response.StatusCode
            }
        } catch {}
    }

    return $null
}

function Get-ConfluenceResponseHeaderValue {
    param(
        [object]$Response,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Response) { return $null }

    foreach ($headerBag in @($Response.Headers, $Response.Content.Headers)) {
        if ($null -eq $headerBag) { continue }

        try {
            $directValue = $headerBag[$Name]
            if ($null -ne $directValue) {
                return (@($directValue) | Select-Object -First 1)
            }
        } catch {}

        try {
            if ($headerBag.AllKeys) {
                foreach ($key in @($headerBag.AllKeys)) {
                    if ("$key" -ieq $Name) {
                        return (@($headerBag[$key]) | Select-Object -First 1)
                    }
                }
            }
        } catch {}

        try {
            foreach ($header in $headerBag.GetEnumerator()) {
                if ("$($header.Key)" -ieq $Name) {
                    return (@($header.Value) | Select-Object -First 1)
                }
            }
        } catch {}
    }

    return $null
}

function Get-ConfluenceRequestRetryDelaySeconds {
    param(
        [object]$Response,
        [int]$Attempt,
        [int]$InitialDelaySeconds = 2,
        [int]$MaxDelaySeconds = 120
    )

    $InitialDelaySeconds = [Math]::Max(1, $InitialDelaySeconds)
    $MaxDelaySeconds = [Math]::Max($InitialDelaySeconds, $MaxDelaySeconds)

    foreach ($headerName in @('Retry-After', 'X-RateLimit-Reset')) {
        $headerValue = Get-ConfluenceResponseHeaderValue -Response $Response -Name $headerName
        if ([string]::IsNullOrWhiteSpace($headerValue)) { continue }

        $seconds = 0
        if ([int]::TryParse("$headerValue", [ref]$seconds)) {
            return [Math]::Min($MaxDelaySeconds, [Math]::Max(1, $seconds))
        }

        try {
            $retryAt = [DateTimeOffset]::Parse("$headerValue", [Globalization.CultureInfo]::InvariantCulture)
            $seconds = [int][Math]::Ceiling(($retryAt.UtcDateTime - (Get-Date).ToUniversalTime()).TotalSeconds)
            if ($seconds -gt 0) {
                return [Math]::Min($MaxDelaySeconds, [Math]::Max(1, $seconds))
            }
        } catch {}
    }

    $delay = $InitialDelaySeconds * [Math]::Pow(2, [Math]::Max(0, $Attempt - 1))
    $delay = [Math]::Min($MaxDelaySeconds, [int][Math]::Ceiling($delay))
    $jitter = if ($MaxDelaySeconds -gt 1) { Get-Random -Minimum 0 -Maximum ([Math]::Min(3, $MaxDelaySeconds)) } else { 0 }
    return [Math]::Min($MaxDelaySeconds, [Math]::Max(1, $delay + $jitter))
}

function Write-ConfluenceRetryMessage {
    param(
        [string]$Uri,
        [string]$Method,
        [int]$StatusCode,
        [int]$DelaySeconds,
        [int]$Attempt,
        [int]$MaxRetries
    )

    $displayUri = if ($Uri.Length -gt 180) { "$($Uri.Substring(0, 177))..." } else { $Uri }
    $message = "Confluence request returned HTTP $StatusCode for $Method $displayUri. Waiting $DelaySeconds second(s) before retry $Attempt of $MaxRetries."
    if (Get-Command PrintAndLog -ErrorAction SilentlyContinue) {
        PrintAndLog -message $message -Color Yellow
    } else {
        Write-Warning $message
    }
}

function Test-ConfluenceRequestShouldRetry {
    param(
        [nullable[int]]$StatusCode,
        [int]$Attempt,
        [int]$MaxRetries
    )

    if ($Attempt -gt $MaxRetries) { return $false }
    if ($null -eq $StatusCode) { return $false }
    return @((Get-ConfluenceRetryStatusCodes)) -contains [int]$StatusCode
}

function Invoke-ConfluenceRestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [object]$Body,
        [string]$ContentType,
        [nullable[int]]$MaxRetries = $null,
        [nullable[int]]$InitialDelaySeconds = $null,
        [nullable[int]]$MaxDelaySeconds = $null
    )

    $effectiveMaxRetries = if ($null -ne $MaxRetries) { [int]$MaxRetries } elseif ($null -ne $ConfluenceRequestMaxRetries) { [int]$ConfluenceRequestMaxRetries } else { 8 }
    $effectiveInitialDelay = if ($null -ne $InitialDelaySeconds) { [int]$InitialDelaySeconds } elseif ($null -ne $ConfluenceRequestInitialDelaySeconds) { [int]$ConfluenceRequestInitialDelaySeconds } else { 2 }
    $effectiveMaxDelay = if ($null -ne $MaxDelaySeconds) { [int]$MaxDelaySeconds } elseif ($null -ne $ConfluenceRequestMaxDelaySeconds) { [int]$ConfluenceRequestMaxDelaySeconds } else { 120 }
    $attempt = 0

    while ($true) {
        $requestParams = @{
            Uri         = $Uri
            Method      = $Method
            Headers     = $Headers
            ErrorAction = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Body')) { $requestParams.Body = $Body }
        if (-not [string]::IsNullOrWhiteSpace($ContentType)) { $requestParams.ContentType = $ContentType }

        try {
            return Invoke-RestMethod @requestParams
        } catch {
            $attempt += 1
            $statusCode = Get-ConfluenceResponseStatusCode -ErrorRecord $_
            if (-not (Test-ConfluenceRequestShouldRetry -StatusCode $statusCode -Attempt $attempt -MaxRetries $effectiveMaxRetries)) {
                throw
            }

            $delay = Get-ConfluenceRequestRetryDelaySeconds -Response $_.Exception.Response -Attempt $attempt -InitialDelaySeconds $effectiveInitialDelay -MaxDelaySeconds $effectiveMaxDelay
            Write-ConfluenceRetryMessage -Uri $Uri -Method $Method -StatusCode $statusCode -DelaySeconds $delay -Attempt $attempt -MaxRetries $effectiveMaxRetries
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-ConfluenceWebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$OutFile,
        [nullable[int]]$MaximumRedirection = $null,
        [switch]$SkipHttpErrorCheck,
        [nullable[int]]$MaxRetries = $null,
        [nullable[int]]$InitialDelaySeconds = $null,
        [nullable[int]]$MaxDelaySeconds = $null
    )

    $effectiveMaxRetries = if ($null -ne $MaxRetries) { [int]$MaxRetries } elseif ($null -ne $ConfluenceRequestMaxRetries) { [int]$ConfluenceRequestMaxRetries } else { 8 }
    $effectiveInitialDelay = if ($null -ne $InitialDelaySeconds) { [int]$InitialDelaySeconds } elseif ($null -ne $ConfluenceRequestInitialDelaySeconds) { [int]$ConfluenceRequestInitialDelaySeconds } else { 2 }
    $effectiveMaxDelay = if ($null -ne $MaxDelaySeconds) { [int]$MaxDelaySeconds } elseif ($null -ne $ConfluenceRequestMaxDelaySeconds) { [int]$ConfluenceRequestMaxDelaySeconds } else { 120 }
    $attempt = 0

    while ($true) {
        $requestParams = @{
            Uri         = $Uri
            Method      = $Method
            Headers     = $Headers
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) { $requestParams.OutFile = $OutFile }
        if ($null -ne $MaximumRedirection) { $requestParams.MaximumRedirection = [int]$MaximumRedirection }
        if ($SkipHttpErrorCheck) { $requestParams.SkipHttpErrorCheck = $true }

        try {
            $response = Invoke-WebRequest @requestParams
            $statusCode = Get-ConfluenceResponseStatusCode -Response $response
            if (Test-ConfluenceRequestShouldRetry -StatusCode $statusCode -Attempt ($attempt + 1) -MaxRetries $effectiveMaxRetries) {
                $attempt += 1
                $delay = Get-ConfluenceRequestRetryDelaySeconds -Response $response -Attempt $attempt -InitialDelaySeconds $effectiveInitialDelay -MaxDelaySeconds $effectiveMaxDelay
                Write-ConfluenceRetryMessage -Uri $Uri -Method $Method -StatusCode $statusCode -DelaySeconds $delay -Attempt $attempt -MaxRetries $effectiveMaxRetries
                Start-Sleep -Seconds $delay
                continue
            }

            return $response
        } catch {
            $attempt += 1
            $statusCode = Get-ConfluenceResponseStatusCode -ErrorRecord $_
            if (-not (Test-ConfluenceRequestShouldRetry -StatusCode $statusCode -Attempt $attempt -MaxRetries $effectiveMaxRetries)) {
                throw
            }

            $delay = Get-ConfluenceRequestRetryDelaySeconds -Response $_.Exception.Response -Attempt $attempt -InitialDelaySeconds $effectiveInitialDelay -MaxDelaySeconds $effectiveMaxDelay
            Write-ConfluenceRetryMessage -Uri $Uri -Method $Method -StatusCode $statusCode -DelaySeconds $delay -Attempt $attempt -MaxRetries $effectiveMaxRetries
            Start-Sleep -Seconds $delay
        }
    }
}

function Initialize-ConfluenceSourcePage {
    param([Parameter(Mandatory)][object]$Page)

    $Page | Add-Member -NotePropertyName FetchedBy      -NotePropertyValue $localhost_name -Force
    $Page | Add-Member -NotePropertyName OriginalTitle  -NotePropertyValue $Page.title -Force
    $Page | Add-Member -NotePropertyName title          -NotePropertyValue $(Get-SafeTitle -name $Page.title) -Force

    $rawHtml = Get-MigrationPageHtmlContent -Page $Page -Path $null
    $rawHtmlPath = Save-MigrationHtmlContent -PageId $Page.id -Title $Page.title -Content $rawHtml -Suffix "before" -OutDir $TmpOutputDir
    $Page | Add-Member -NotePropertyName RawHtmlPath      -NotePropertyValue $rawHtmlPath -Force
    $Page | Add-Member -NotePropertyName PreparedHtmlPath -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName FinalHtmlPath    -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName htmlContent      -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName rawContent       -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName articlePreview   -NotePropertyValue $null -Force

    $Page | Add-Member -NotePropertyName Links      -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName LinksCount -NotePropertyValue 0 -Force
    $Page | Add-Member -NotePropertyName BaseLinks  -NotePropertyValue $(Get-ConfluenceLinks -page $Page) -Force
    $script:LinksFoundCount += @($Page.BaseLinks).Count

    $Page | Add-Member -NotePropertyName stub          -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName updatedHtml   -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName CompanyId     -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName ReplacedLinks -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName ReplacedLinksCount -NotePropertyValue 0 -Force
    $Page | Add-Member -NotePropertyName HuduArticle   -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName CharsTrimmed  -NotePropertyValue 0 -Force

    $attachments = Get-AttachmentsForPage -baseUrl $ConfluenceBaseUrl -pageId $Page.id -authHeader "Basic $encodedCreds"
    $Page | Add-Member -NotePropertyName attachments -NotePropertyValue $attachments -Force

    foreach ($attachment in $Page.attachments) {
        $RunSummary.JobInfo.AttachmentsFound+=1
    }

    Clear-MigrationPageHtmlMemory -Page $Page
    $rawHtml = $null
    return $Page
}

function Add-ConfluenceSourcePages {
    param([object[]]$Pages)

    foreach ($page in @($Pages)) {
        $initializedPage = Initialize-ConfluenceSourcePage -Page $page
        [void]$script:SourcePages.Add($initializedPage)
    }

    Invoke-MigrationMemoryCleanup
}

function Get-AttachmentsForPage {
    param (
        [string]$PageId,
        [string]$BaseUrl,
        [string]$AuthHeader
    )

    $AllAttachments = [System.Collections.ArrayList]@()
    $limit = 50
    $attachmentsUrl = "$BaseUrl/api/v2/pages/$PageId/attachments?limit=$limit"

    try {
        do {
            $attachResponse = Invoke-ConfluenceRestMethod -Uri $attachmentsUrl -Headers @{
                Authorization = $AuthHeader
                Accept        = 'application/json'
            }

            foreach ($attachment in @($attachResponse.results)) {
                [void]$AllAttachments.Add($attachment)
            }
            $nextPath = $attachResponse._links.next
            $attachmentsUrl = if ($nextPath) {
                Resolve-ConfluenceUrl -BaseUrl $BaseUrl -PathOrUrl $nextPath
            } else {
                $null
            }
        } while ($attachmentsUrl)

        return $AllAttachments
    } catch {
        PrintAndLog -message "Could not retrieve v2 attachments for page $PageId; falling back to v1 endpoint. $($_.Exception.Message)" -Color Yellow
    }

    $start = 0
    do {
        $uri = "$BaseUrl/rest/api/content/$PageId/child/attachment" +
               "?limit=$limit&start=$start&expand=version,metadata"

        $attachResponse = Invoke-ConfluenceRestMethod -Uri $uri -Headers @{
            Authorization = $AuthHeader
            Accept        = 'application/json'
        }

        foreach ($attachment in @($attachResponse.results)) {
            [void]$AllAttachments.Add($attachment)
        }
        $start += $limit
    } while ($attachResponse.size -eq $limit)

    return $AllAttachments
}

function Resolve-ConfluenceUrl {
    param (
        [string]$BaseUrl,
        [string]$PathOrUrl
    )

    if ([string]::IsNullOrWhiteSpace($PathOrUrl)) {
        return $null
    }

    if ($PathOrUrl -match '^https?://') {
        return $PathOrUrl
    }

    $domainBase = $BaseUrl -replace '/wiki$', ''
    if ($PathOrUrl.StartsWith('/wiki')) {
        return "$domainBase$PathOrUrl"
    }

    if ($PathOrUrl.StartsWith('/')) {
        return "$BaseUrl$PathOrUrl"
    }

    return "$BaseUrl/$PathOrUrl"
}

function Get-ConfluenceAttachmentIdCandidates {
    param ([object]$Attachment)

    $ids = @()
    if (-not [string]::IsNullOrWhiteSpace($Attachment.id)) {
        $ids += [string]$Attachment.id
    }

    if (-not [string]::IsNullOrWhiteSpace($Attachment.ari) -and $Attachment.ari -match 'attachment/([^:/]+)$') {
        $ids += $Matches[1]
    }

    if (-not [string]::IsNullOrWhiteSpace($Attachment.id) -and $Attachment.id -match '^att(\d+)$') {
        $ids += $Matches[1]
    }

    return $ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Resolve-ConfluenceAttachmentDownloadUrl {
    param (
        [object]$Attachment,
        [string]$BaseUrl,
        [string]$AuthHeader,
        [string]$PageId
    )

    $attachmentPageId = if (-not [string]::IsNullOrWhiteSpace($PageId)) { $PageId } else { $Attachment.pageId }
    if (-not [string]::IsNullOrWhiteSpace($attachmentPageId)) {
        foreach ($attachmentId in (Get-ConfluenceAttachmentIdCandidates -Attachment $Attachment)) {
            $apiDownloadUrl = "$BaseUrl/rest/api/content/$attachmentPageId/child/attachment/$attachmentId/download"
            $probe = $null
            try {
                $probe = Invoke-ConfluenceWebRequest -Uri $apiDownloadUrl -Headers @{ Authorization = $AuthHeader } -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck
                if ($probe -and [int]$probe.StatusCode -ge 200 -and [int]$probe.StatusCode -lt 400) {
                    return $apiDownloadUrl
                }
            } catch {
                if ($probe -and [int]$probe.StatusCode -ge 200 -and [int]$probe.StatusCode -lt 400) {
                    return $apiDownloadUrl
                }
                continue
            }
        }
    }

    foreach ($candidate in @($Attachment.downloadLink, $Attachment._links.download)) {
        $url = Resolve-ConfluenceUrl -BaseUrl $BaseUrl -PathOrUrl $candidate
        if ($url) {
            return $url
        }
    }

    foreach ($attachmentId in (Get-ConfluenceAttachmentIdCandidates -Attachment $Attachment)) {
        try {
            $detail = Invoke-ConfluenceRestMethod -Uri "$BaseUrl/api/v2/attachments/$attachmentId" -Method GET -Headers @{
                Authorization = $AuthHeader
                Accept        = 'application/json'
            }

            foreach ($candidate in @($detail.downloadLink, $detail._links.download)) {
                $url = Resolve-ConfluenceUrl -BaseUrl $BaseUrl -PathOrUrl $candidate
                if ($url) {
                    return $url
                }
            }
        } catch {
            continue
        }
    }

    throw "No download URL found for Confluence attachment '$($Attachment.title)' (id '$($Attachment.id)', ari '$($Attachment.ari)')."
}

function GetAllSpaces {
    param (
        [string]$baseUrl,
        [string]$authHeader
    )
    $spacesUrl = "${baseUrl}/rest/api/space?limit=100"
    $all_spaces = @()
    try {
        while ($spacesUrl) {
            # Retrieve spaces
            $response = Invoke-ConfluenceRestMethod -Uri $spacesUrl -Headers @{ Authorization = $authHeader } -Method Get
            # Collect space details
            $response.results | ForEach-Object {
                $all_spaces += [PSCustomObject]@{
                    Name          = $_.name
                    Status        = $_.status
                    OptionMessage = $_.name
                    Key           = $_.key
                    Id            = $_.id
                }
            }
            # Check if there is a next page
            if ($response._links.next) {
                $spacesUrl = Resolve-ConfluenceUrl -BaseUrl $baseUrl -PathOrUrl $response._links.next
            } else {
                $spacesUrl = $null
            }
        }
    } catch {
                Write-ErrorObjectsToFile -Name "$($_.name ?? "unnamed")" -ErrorObject @{
                    Error       = $_
                    Record      = $record 
                    Attachment  = $att
                    Message     ="Error During Spaces Request"
                    response    = $response
                    spacesUrl  = $spacesUrl
                }
            }
    return $all_spaces
}
function GetAllPages {
    param (
        [string]$baseUrl,
        [string]$SpaceKey,
        [string]$SpaceName,
        [string]$authHeader,
        [string]$SpaceId = "",
        [string]$ContentType = "page",
        [bool]$SkipArchived = $true
    )

    $AllPages = [System.Collections.ArrayList]@()
    $limit = 25

    # Use v2 API if SpaceId provided, fall back to v1 if not
    if ($SpaceId -ne "") {
        $statusFilter = if ($SkipArchived) { "&status=current" } else { "" }
        $pagesUrl = "$baseUrl/api/v2/spaces/$SpaceId/pages?limit=$limit&body-format=storage$statusFilter"
    } else {
        $statusFilter = if ($SkipArchived) { "&status=current" } else { "" }
        $pagesUrl = "$baseUrl/rest/api/content?spaceKey=$SpaceKey&type=$ContentType&expand=body.storage,version&limit=$limit$statusFilter"
    }

    PrintAndLog -message "Retrieving Confluence content from space '$SpaceKey'..."

    do {
        PrintAndLog -message "Querying: $pagesUrl"

        $response = Invoke-ConfluenceRestMethod -Uri $pagesUrl -Method GET -Headers @{
            "Authorization" = $authHeader
            "Accept"        = "application/json"
        }

        if ($response.results -and $response.results.Count -gt 0) {
            foreach ($page in $response.results) {
                $pageStatus = if ($null -ne $page.status) { "$($page.status)".Trim().ToLowerInvariant() } else { "" }
                if ($SkipArchived -and -not [string]::IsNullOrWhiteSpace($pageStatus) -and $pageStatus -ne "current") {
                    PrintAndLog -message "Skipping Confluence page '$($page.title)' ($($page.id)) from space '$SpaceKey' because status is '$pageStatus'." -Color Gray
                    continue
                }

                # v2 API returns body differently — normalize to v1 shape
                if ($SpaceId -ne "" -and $page.body -and $page.body.storage) {
                    # already in correct shape — body.storage.value exists
                } elseif ($SpaceId -ne "" -and -not $page.body) {
                    # v2 sometimes needs body fetched separately if missing
                    $pageDetail = Invoke-ConfluenceRestMethod -Uri "$baseUrl/api/v2/pages/$($page.id)?body-format=storage" -Method GET -Headers @{
                        "Authorization" = $authHeader
                        "Accept"        = "application/json"
                    }
                    $page | Add-Member -NotePropertyName body -NotePropertyValue $pageDetail.body -Force
                }

                $page | Add-Member -NotePropertyName FullUrl  -NotePropertyValue "$baseUrl$($page._links.webui)" -Force
                $page | Add-Member -NotePropertyName SpaceKey -NotePropertyValue "$SpaceKey" -Force
                $page | Add-Member -NotePropertyName SpaceName -NotePropertyValue "$SpaceName" -Force
                [void]$AllPages.Add($page)
            }
        }

        # Pagination — v2 cursor-based, v1 offset-based
        $nextPath = $response._links.next
        if ($nextPath) {
            $domain = $baseUrl -replace '/wiki$', ''
            $pagesUrl = if ($nextPath.StartsWith("/wiki")) { "$domain$nextPath" } else { "$baseUrl$nextPath" }
        } else {
            $pagesUrl = $null
        }

    } while ($pagesUrl)

    PrintAndLog -message "Downloaded $($AllPages.Count) page(s) from space: $SpaceKey."
    return $AllPages
}


function Invoke-ConfluenceAttachDownload {
    param (
        [PSCustomObject]$attachment,
        [PSCustomObject]$page,
        [string]$pageId,
        [string]$title,
        [string]$ConfluenceBaseUrl,
        [string]$TmpOutputDir,
        [string]$encodedCreds
    )

    $authHeader = "Basic $encodedCreds"
    $filename = Get-SafeFilename -Name ($attachment.title ?? "attachment-$($attachment.id ?? $pageId)")
    $downloadUrl = $null
    $localPath = Join-Path -Path $TmpOutputDir -ChildPath $filename
    $ext = [IO.Path]::GetExtension($filename).ToLower()
    $imageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg')
    $isImage = $imageExtensions -contains $ext
    $record = [PSCustomObject]@{
        FileName           = $filename
        Extension          = $ext
        IsImage            = $isImage
        PageId             = $pageId
        PageTitle          = $title
        AttachmentId       = $attachment.id
        AttachmentAri      = $attachment.ari
        SourceUrl          = $null
        LocalPath          = $localPath
        UploadResult       = $null
        FileUploadResult   = $null
        PublicPhotoResult  = $null
        HuduArticleId      = $null
        HuduUploadType     = $null
        HuduFileUploadUrl  = $null
        HuduPublicPhotoUrl = $null
        SuccessDownload    = $false
        AttachmentSize     = 0
        AttachmentTooLarge = $false
    }

    try {
        $downloadUrl = Resolve-ConfluenceAttachmentDownloadUrl -Attachment $attachment -BaseUrl $ConfluenceBaseUrl -AuthHeader $authHeader -PageId $pageId
        $record.SourceUrl = $downloadUrl

        Invoke-ConfluenceWebRequest -Uri $downloadUrl -Headers @{ Authorization = $authHeader } -OutFile $localPath -MaximumRedirection 10 | Out-Null
        Write-Host "Saved attachment: $filename"

        $record.SuccessDownload = $true
        $record.AttachmentSize = (Get-Item -LiteralPath $localPath).Length
        $record.AttachmentTooLarge = $record.AttachmentSize -gt 100MB

        return $record
    } catch {
        Write-ErrorObjectsToFile -Name "$($record.FileName)" -ErrorObject @{
            Error       = $_
            Record      = $record
            Attachment  = $attachment
            Message     = "Error During Attachment Download"
            DownloadUrl = $downloadUrl
        }

        return $record
    }
}

function Invoke-MigrationPageAttachmentProcessing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Page,
        [int]$ProgressParentId = 2
    )

    $pageImageMap = @{}
    $attachments = @($Page.attachments | Where-Object { $null -ne $_ })
    PrintAndLog -message "Starting dl/ul of $($attachments.Count) attachments found for $($Page.title)" -Color Green

    $AttachIDX = 0
    foreach ($att in $attachments) {
        $AttachIDX += 1
        $attachPercent = Get-PercentDone -Current $AttachIDX -Total $attachments.Count

        if ($ProgressParentId -ge 0) {
            Write-Progress -Id 3 -ParentId $ProgressParentId -Activity "Attachments: $($Page.title)" -Status "$AttachIDX of $($attachments.Count)" -PercentComplete $attachPercent
        }

        $record = Invoke-ConfluenceAttachDownload -attachment $att -page $Page -pageId $Page.id -title $Page.title -ConfluenceBaseUrl $ConfluenceBaseUrl -TmpOutputDir $TmpOutputDir -encodedCreds $encodedCreds

        if ($null -eq $record) {
            $record = [PSCustomObject]@{
                FileName           = $(Get-SafeFilename -Name $($att.title ?? "Title not present for page id $($Page.id ?? 0)"))
                Extension          = [IO.Path]::GetExtension($att.title).ToLower()
                IsImage            = $false
                PageId             = $($Page.id)
                PageTitle          = $($Page.title)
                AttachmentId       = $att.id
                AttachmentAri      = $att.ari
                SourceUrl          = $null
                LocalPath          = $null
                UploadResult       = $null
                FileUploadResult   = $null
                PublicPhotoResult  = $null
                HuduArticleId      = $null
                HuduUploadType     = $null
                HuduFileUploadUrl  = $null
                HuduPublicPhotoUrl = $null
                SuccessDownload    = $false
                AttachmentSize     = 0
                AttachmentTooLarge = $false
            }
        }

        if ($TrackAttachmentDetails -and $null -ne $TrackedAttachments) {
            [void]$TrackedAttachments.Add($record)
        }

        if ($record -and $record.SuccessDownload -and $record.LocalPath) {
            printandlog -message "Downloaded Attachment $AttachIDX of $($attachments.Count) for $($Page.title) - $($record.FileName)" -Color Yellow

            if ($true -eq $record.AttachmentTooLarge) {
                $ErrorObject = @{
                    Attachment = $record.Filename
                    Problem    = "$($record.Filename) is TOO LARGE for Hudu. Manual Action is required. Skipping."
                    page       = "Confluence page with Id $($Page.id), titled $($Page.title)"
                    Article    = "Hudu stub with id $($($Page.stub).id) at $($($Page.stub).url)"
                }
                $RunSummary.Errors.Add($ErrorObject) | Out-Null
                $RunSummary.JobInfo.UploadsErrored += 1
                Write-ErrorObjectsToFile -ErrorObject $ErrorObject -name "Attach-Error-$($record.Filename)"
                continue
            }

            try {
                PrintAndLog -Message "Uploading attachment: $($record.FileName) => record_id=$($($Page.stub).id) record_type=Article" -Color Green
                $upload = $null
                $fileUpload = $null
                $publicPhoto = $null
                $commonPublicPhotoExtensions = @('.jpg', '.jpeg', '.png', '.gif')
                $shouldKeepUploadCopy = ($true -eq $record.IsImage -and $commonPublicPhotoExtensions -contains $record.Extension)

                if ($true -eq $record.IsImage) {
                    $publicPhoto = New-HuduPublicPhoto -FilePath $record.LocalPath -record_id $($Page.stub).id -record_type 'Article'
                    $publicPhoto = $publicPhoto.public_photo ?? $publicPhoto
                    $upload = $publicPhoto

                    if ($shouldKeepUploadCopy) {
                        $fileUpload = New-HuduUpload -FilePath $record.LocalPath -record_id $($Page.stub).id -record_type 'Article'
                        $fileUpload = $fileUpload.upload ?? $fileUpload
                    }
                } else {
                    $fileUpload = New-HuduUpload -FilePath $record.LocalPath -record_id $($Page.stub).id -record_type 'Article'
                    $fileUpload = $fileUpload.upload ?? $fileUpload
                    $upload = $fileUpload
                }

                Write-Host "$($upload.slug)"
                $fileUploadRef = if ($fileUpload -and -not [string]::IsNullOrWhiteSpace($fileUpload.slug)) { $fileUpload.slug } elseif ($fileUpload) { $fileUpload.id } else { $null }
                $huduFileUploadUrl = if ($fileUploadRef) { "$HuduBaseUrl/file/$fileUploadRef" } else { $null }
                $huduPublicPhotoUrl = if ($publicPhoto) { $publicPhoto.url ?? "$HuduBaseUrl/public_photo/$($publicPhoto.id)" } else { $null }
                $huduUploadUrl = if ($publicPhoto) {
                    $huduPublicPhotoUrl
                } else {
                    $huduFileUploadUrl
                }

                $script:LinksCreatedCount += 1
                if ($fileUpload -and $publicPhoto) {
                    $script:LinksCreatedCount += 1
                }

                $normalizedFileName = $record.FileName.ToLowerInvariant()
                $embeddableMediaKind = Get-HuduEmbeddableUploadMediaKind -Path $record.FileName
                $pageImageMap[$normalizedFileName] = @{
                    Id             = $upload.id
                    Slug           = $upload.slug
                    Url            = $huduUploadUrl
                    Type           = if ($publicPhoto) { 'image' } else { 'upload' }
                    MediaKind      = $embeddableMediaKind
                    FileUploadId   = $fileUpload.id
                    FileUploadSlug = $fileUpload.slug
                    FileUploadUrl  = $huduFileUploadUrl
                    PublicPhotoId  = $publicPhoto.id
                    PublicPhotoUrl = $huduPublicPhotoUrl
                }

                $record.UploadResult = $upload
                $record.FileUploadResult = $fileUpload
                $record.PublicPhotoResult = $publicPhoto
                $record.HuduUploadType = $pageImageMap[$normalizedFileName].Type
                $record.HuduFileUploadUrl = $huduFileUploadUrl
                $record.HuduPublicPhotoUrl = $huduPublicPhotoUrl
                $record.HuduArticleId = $($Page.stub).id
                $RunSummary.JobInfo.UploadsCreated += if ($fileUpload -and $publicPhoto) { 2 } else { 1 }
            } catch {
                $ErrorInfo = @{
                    Error   = $_
                    Record  = $record.AttachmentSize ?? 0
                    Message = "Error During Attachment Upload"
                    Article = "Hudu Article id $($Page.stub.id) at $($Page.stub.url)"
                    Page    = "Confluence page with Id $($Page.id), titled $($Page.title)- $($Page.FullUrl ?? '')"
                }
                $RunSummary.Errors.add($ErrorInfo) | Out-Null
                $RunSummary.JobInfo.UploadsErrored += 1
                Write-ErrorObjectsToFile -Name "$($record.FileName)" -ErrorObject $ErrorInfo
            }
        } else {
            printandlog -message "Failed to download Attachment $AttachIDX of $($attachments.Count) for $($Page.title) - $($record.FileName)" -Color Red
            $RunSummary.JobInfo.UploadsErrored += 1
        }
    }

    if ($ProgressParentId -ge 0) {
        Write-Progress -Id 3 -ParentId $ProgressParentId -Activity "Attachments: $($Page.title)" -Completed
    }

    return $pageImageMap
}

function Invoke-MigrationPageContentPreparation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Page,
        [hashtable]$ImageMap = @{}
    )

    $rawContent = Get-MigrationPageHtmlContent -Page $Page -Path $Page.RawHtmlPath
    PrintAndLog -Message "Updating HTML content for $($Page.title)" -Color Yellow

    $blankArticleHtml = '<p>&nbsp;</p>'
    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        PrintAndLog -Message "Raw HTML content is empty for $($Page.title). Using blank article placeholder." -Color Yellow
        $updatedHtml = $blankArticleHtml
    } else {
        $updatedHtml = Convert-ConfluenceHtml `
            -Html $rawContent `
            -ImageMap $ImageMap `
            -HuduBaseUrl $HuduBaseUrl

        if ([string]::IsNullOrWhiteSpace($updatedHtml)) {
            PrintAndLog -Message "Converted HTML content is empty for $($Page.title). Falling back to raw content." -Color Yellow
            $updatedHtml = $rawContent
        } else {
            $updatedHtml = Cleanup-ResidualConfluenceHtml -Html $updatedHtml

            if ([string]::IsNullOrWhiteSpace($updatedHtml)) {
                PrintAndLog -Message "Cleaned HTML content is empty for $($Page.title). Falling back to raw content." -Color Yellow
                $updatedHtml = $rawContent
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($updatedHtml)) {
        PrintAndLog -Message "Prepared HTML content is empty for $($Page.title). Using blank article placeholder." -Color Yellow
        $updatedHtml = $blankArticleHtml
    }

    $Page.charsTrimmed = [Math]::Max(0, (($rawContent ?? '').Length - ($updatedHtml ?? '').Length))
    PrintAndLog -Message "Removed $($Page.charsTrimmed) characters of bloat from $($Page.title)" -Color Green
    $Page.PreparedHtmlPath = Save-MigrationHtmlContent -PageId $Page.id -Title $Page.title -Content $updatedHtml -Suffix "after" -OutDir $TmpOutputDir
    Write-Host "Saved HTML snapshot: $($Page.PreparedHtmlPath)"
    PrintAndLog "Prepared Article: $($Page.title) to $($($Page.CompanyId) ?? 'Global KB') with attachment links converted. Final content update is deferred until relinking." -Color Green

    $rawContent = $null
    $updatedHtml = $null
    Clear-MigrationPageHtmlMemory -Page $Page

    return $Page.PreparedHtmlPath
}

function Invoke-MigrationPageRelinkAndFinalize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArticleId,
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][object]$RelinkIndex,
        [Parameter(Mandatory)][hashtable]$UrlMap,
        [bool]$RelinkReferencedTitleText = $true,
        [bool]$RelinkAllTitleText = $false
    )

    $relPage = $Entry.Page
    $htmlContent = $null
    $FinalContents = $null
    $finalLinks = $null

    try {
        $htmlContent = Get-MigrationPageHtmlContent -Page $relPage -Path $Entry.ContentPath -Default "unknown contents"
        $sourceLinks = @(Get-LinksFromHTML -htmlContent $htmlContent -title $relPage.title -includeImages $false -suppressOutput $true)
        $relPage.LinksCount = $sourceLinks.Count
        $script:LinksFoundCount += $sourceLinks.Count

        $relinkResult = Invoke-ConfluenceHtmlRelink `
            -Html $htmlContent `
            -Entry $Entry `
            -RelinkIndex $RelinkIndex `
            -UrlMap $UrlMap `
            -ConfluenceDomain $ConfluenceDomain `
            -ConfluenceDomainBase $ConfluenceDomainBase `
            -ConfluenceBaseUrl $ConfluenceBaseUrl `
            -RelinkReferencedTitleText $RelinkReferencedTitleText `
            -RelinkAllTitleText $RelinkAllTitleText

        $FinalContents = $relinkResult.Html

        if ($FinalContents.Length -gt $RunSummary.SetupInfo.HuduMaxContentLength) {
            PrintAndLog "Content Length Warning: Final relinked content is too large. Safe-Maximum is $($RunSummary.SetupInfo.HuduMaxContentLength) Characters, and this is $($FinalContents.length) chars long! Adding as attached document!"
            $htmlPath = Join-Path $TmpOutputDir -ChildPath ("LargeDoc_{0}.html" -f (Get-SafeFilename ([IO.Path]::GetFileNameWithoutExtension($($relPage.title)))))
            Set-Content -Path $htmlPath -Value $FinalContents -Encoding UTF8

            $htmlAttachment = New-HuduUpload -FilePath $htmlPath -record_id $ArticleId -record_type 'Article'
            $htmlAttachment = $htmlAttachment.upload ?? $htmlAttachment

            $htmlAttachmentFileRef = if (-not [string]::IsNullOrWhiteSpace($htmlAttachment.slug)) { $htmlAttachment.slug } else { $htmlAttachment.id }
            $FinalContents = "Full content too long. See attached file: <a href='$HuduBaseUrl/file/$htmlAttachmentFileRef'>$($relPage.title).html</a>"

            $RunSummary.Warnings.add(@{
                Warning    = "Document from page $($relPage.title) was too large and was uploaded as standalone HTML File after relinking; Please review."
                ArticleURL = $relPage.stub.url ?? "URL not found"
                PageURL    = $relPage.FullUrl ?? ("$ConfluenceBaseUrl$($relPage._links.webui)" ?? "URL not found")
            }) | Out-Null
        }

        $finalLinks = @(Get-LinksFromHTML -htmlContent $FinalContents -title $relPage.title -includeImages $false -suppressOutput $true)
        $relPage.ReplacedLinksCount = @($finalLinks | Where-Object { $_ -ilike "*$HuduBaseURL*" }).Count
        $relPage.ReplacedLinks = $null

        $relPage.FinalHtmlPath = Save-MigrationHtmlContent -PageId $relPage.id -Title $relPage.title -Content $FinalContents -Suffix "final" -OutDir $TmpOutputDir
        $Entry.FinalContentPath = $relPage.FinalHtmlPath

        $response = Set-HuduArticle -ArticleId $ArticleId -Content $FinalContents -Name $relPage.title
        $relPage.HuduArticle = $response.Article ?? $response
        $Entry.HuduArticle = $relPage.HuduArticle
        $script:LinksReplacedCount += $relPage.ReplacedLinksCount
        PrintAndLog -Message "Updated article [$($relPage.title)] with length: $($FinalContents.Length), relink replacements attempted: $($relinkResult.ReplacementCount)" -Color Cyan

        return $true
    } catch {
        $ErrorInfo = @{
            Message    = "Error finalizing article content: $($relPage.title)"
            Error      = $_
            HuduArticle = $Entry.HuduArticle
            Page       = "Confluence page with Id $($relPage.id), titled $($relPage.title)- $($relPage.FullUrl ?? '')"
            ArticleURL = $($relPage.stub.url ?? "URL not found")
        }
        $RunSummary.Errors.add($ErrorInfo) | Out-Null
        $RunSummary.JobInfo.ArticlesErrored += 1
        Write-ErrorObjectsToFile -name "finalarticle-$($relPage.title)" -ErrorObject $ErrorInfo
        return $false
    } finally {
        $htmlContent = $null
        $FinalContents = $null
        $finalLinks = $null
        $sourceLinks = $null
    }
}

function New-HuduStubArticle {
    param (
        [string]$Title,
        [string]$Content,
        [nullable[int]]$CompanyId,
        [nullable[int]]$FolderId
    )

    $params = @{
        Name    = $Title
        Content = $Content
    }
    if ($CompanyId -ne $null -and $CompanyId -ne -1) {
        $params.CompanyId = $CompanyId
    }
    if ($FolderId -ne $null) {
        $params.FolderId = $FolderId
    }
    $stub = (New-HuduArticle @params)
    $stub = $stub.article ?? $stub

    return $stub
}

# ── FOLDER RESOLUTION ────────────────────────────────────────────────────────
# FolderCache: Confluence parentId -> Hudu folder ID
# TitleCache:  Confluence ID -> title (covers both pages and folders)
# SpaceHomepageId: set per-space before migration loop so we can exclude it from paths
$script:FolderCache     = @{}
$script:TitleCache      = @{}
$script:SpaceHomepageId = $null

function Get-ConfluenceFolderPath {
    param (
        [string]$StartId,      # the page/folder whose ancestors we want
        [string]$StartType,    # "page" or "folder"
        [string]$AuthHeader,
        [string]$BaseUrl
    )

    $path      = @()
    $currentId = $StartId
    $currentType = $StartType

    while ($currentId) {
        # Stop at the space homepage — don't include it in the path
        if ($currentId -eq $script:SpaceHomepageId) { break }

        # Return from cache if we've seen this node before
        if ($script:TitleCache.ContainsKey($currentId)) {
            $path = @($script:TitleCache[$currentId]) + $path
            break
        }

        try {
            if ($currentType -eq "folder") {
                $resp = Invoke-ConfluenceRestMethod `
                    -Uri     "$BaseUrl/api/v2/folders/$currentId" `
                    -Headers @{ Authorization = $AuthHeader; Accept = "application/json" }
            } else {
                $resp = Invoke-ConfluenceRestMethod `
                    -Uri     "$BaseUrl/api/v2/pages/$currentId" `
                    -Headers @{ Authorization = $AuthHeader; Accept = "application/json" }
            }

            $title = $resp.title
            $script:TitleCache[$currentId] = $title
            $path        = @($title) + $path   # prepend so root comes first
            $currentId   = $resp.parentId
            $currentType = $resp.parentType
        } catch {
            PrintAndLog "  ⚠️  Could not fetch $currentType $currentId while building path — stopping" -Color Yellow
            break
        }
    }

    return $path
}

function Resolve-HuduFolder {
    param (
        [string]$ParentId,
        [string]$ParentType,
        [nullable[int]]$CompanyId=$null,
        [string]$AuthHeader,
        [string]$BaseUrl
    )

    if (-not $ParentId) { return $null }

    # Space homepage as parent = top-level page, no folder needed
    if ($ParentId -eq $script:SpaceHomepageId) { return $null }

    $cacheKey = "$($CompanyId ?? 'global'):$ParentId"

    # Already resolved this parent for this destination scope
    if ($script:FolderCache.ContainsKey($cacheKey)) {
        return $script:FolderCache[$cacheKey]
    }

    # Build full path by walking up through pages and/or folders
    $path = Get-ConfluenceFolderPath -StartId $ParentId -StartType $ParentType -AuthHeader $AuthHeader -BaseUrl $BaseUrl

    if (-not $path -or $path.Count -eq 0) {
        PrintAndLog "  ⚠️  Could not resolve folder path for $ParentId — skipping" -Color Yellow
        return $null
    }

    try {
        $folder = $null
        if ($null -eq $CompanyId -or $CompanyId -lt 1){
            $folder   = Initialize-HuduFolder -FolderPath $path
        } else {
            $folder   = Initialize-HuduFolder -FolderPath $path -CompanyId $CompanyId
        }
        $folderId = $folder.id
        $script:FolderCache[$cacheKey] = $folderId
        PrintAndLog "  📁 '$($path -join " → ")' → Hudu folder ID $folderId" -Color Cyan
        return $folderId
    } catch {
        PrintAndLog "  ⚠️  Initialize-HuduFolder failed for '$($path -join " / ")' — $($_)" -Color Yellow
        return $null
    }
}


function Convert-ConfluenceHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html,

        [hashtable]$ImageMap = @{},
        [string]$HuduBaseUrl
    )

    function Get-HtmlEncoded {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        return [System.Net.WebUtility]::HtmlEncode($Text)
    }

    function Get-HtmlDecoded {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        return [System.Net.WebUtility]::HtmlDecode($Text)
    }

    function Get-HuduAttachmentReference {
        param([object]$MapEntry)

        if ($MapEntry.Type -in @('upload', 'video', 'audio') -and -not [string]::IsNullOrWhiteSpace($MapEntry.Slug)) {
            return $MapEntry.Slug
        }

        return $MapEntry.Id
    }

    function Get-HuduEmbeddableUploadMediaKind {
        param([Parameter(Mandatory)][string]$Path)
        $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($extension -in @('.mp4', '.m4v', '.webm', '.ogv', '.mov', '.mkv')) { return 'Video' }
        if ($extension -in @('.mp3', '.m4a', '.aac', '.wav', '.ogg', '.oga', '.opus', '.flac', '.weba')) { return 'Audio' }
        return $null
    }

    function Get-HuduArticleContentUrl {
        param(
            [string]$Url,
            [string]$FallbackPath,
            [string]$HuduBaseUrl
        )

        $contentUrl = if (-not [string]::IsNullOrWhiteSpace($Url)) { $Url } else { $FallbackPath }

        if ([string]::IsNullOrWhiteSpace($contentUrl)) {
            return ''
        }

        $base = $HuduBaseUrl.TrimEnd('/')
        if ($contentUrl.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $contentUrl.Substring($base.Length)
        }

        return $contentUrl
    }

    function Get-YouTubeEmbedUrl {
        param([string]$Url)

        if ([string]::IsNullOrWhiteSpace($Url)) {
            return $null
        }

        $decodedUrl = [System.Net.WebUtility]::HtmlDecode($Url).Trim()

        # Standard watch URL
        if ($decodedUrl -match '(?i)(?:https?:\/\/)?(?:www\.)?youtube\.com\/watch\?(?:[^#]*&)?v=([^&"#?/]+)') {
            return "https://www.youtube.com/embed/$($Matches[1])"
        }

        # Short URL
        if ($decodedUrl -match '(?i)(?:https?:\/\/)?youtu\.be\/([^&"#?/]+)') {
            return "https://www.youtube.com/embed/$($Matches[1])"
        }

        # Existing embed URL
        if ($decodedUrl -match '(?i)(?:https?:\/\/)?(?:www\.)?youtube\.com\/embed\/([^&"#?/]+)') {
            return "https://www.youtube.com/embed/$($Matches[1])"
        }

        # Shorts URL
        if ($decodedUrl -match '(?i)(?:https?:\/\/)?(?:www\.)?youtube\.com\/shorts\/([^&"#?/]+)') {
            return "https://www.youtube.com/embed/$($Matches[1])"
        }

        return $null
    }

    function Get-HuduAttachmentMarkup {
        param(
            [string]$Filename,
            [hashtable]$ImageMap,
            [string]$HuduBaseUrl
        )

        $key = $Filename.ToLowerInvariant()

        if (-not $ImageMap.ContainsKey($key)) {
            Write-Warning "Attachment '$Filename' not found in ImageMap"
            return "<!-- Missing attachment: $(Get-HtmlEncoded $Filename) -->"
        }

        $mapEntry = $ImageMap[$key]
        $id = Get-HuduAttachmentReference -MapEntry $mapEntry
        $type = $mapEntry.Type

        $publicPhotoUrl = Get-HuduArticleContentUrl -Url ($mapEntry.PublicPhotoUrl ?? $mapEntry.Url) -FallbackPath "/public_photo/$id" -HuduBaseUrl $HuduBaseUrl
        $fileUrl        = Get-HuduArticleContentUrl -Url ($mapEntry.FileUploadUrl ?? $mapEntry.Url) -FallbackPath "/file/$id" -HuduBaseUrl $HuduBaseUrl
        $safeFilename   = Get-HtmlEncoded $Filename
        $safeFileUrl    = Get-HtmlEncoded $fileUrl
        $mediaKind      = $mapEntry.MediaKind

        if ([string]::IsNullOrWhiteSpace($mediaKind)) {
            $mediaKind = Get-HuduEmbeddableUploadMediaKind -Path $Filename
        }

        if ($type -eq 'image' -or $Filename -match '\.(gif|bmp|svg|png|jpe?g|webp)$') {
            return "<figure><img src=""$publicPhotoUrl"" alt=""$safeFilename""></figure>"
        }
        elseif ($mediaKind -eq 'Video') {
            return "<figure><video controls preload='metadata' src='$safeFileUrl'></video><figcaption>$safeFilename</figcaption></figure>"
        }
        elseif ($mediaKind -eq 'Audio') {
            return "<figure><audio controls preload='metadata' src='$safeFileUrl'></audio><figcaption>$safeFilename</figcaption></figure>"
        }
        else {
            return "<p><a href='$safeFileUrl'>$safeFilename</a></p>"
        }
    }

    function Get-RemoteMediaMarkup {
        param(
            [string]$Url,
            [string]$AltText = ''
        )

        $decodedUrl = Get-HtmlDecoded $Url
        $safeUrl    = Get-HtmlEncoded $decodedUrl
        $safeAlt    = Get-HtmlEncoded $AltText

        $ytEmbed = Get-YouTubeEmbedUrl -Url $decodedUrl
        if ($ytEmbed) {
            return "<figure><iframe width='560' height='315' src='$ytEmbed' title='Embedded video' frameborder='0' allowfullscreen></iframe></figure>"
        }

        $remoteMediaKind = Get-HuduEmbeddableUploadMediaKind -Path ($decodedUrl -replace '[?#].*$', '')

        if ($remoteMediaKind -eq 'Video') {
            return "<figure><video controls preload='metadata' src='$safeUrl'></video></figure>"
        }

        if ($remoteMediaKind -eq 'Audio') {
            return "<figure><audio controls preload='metadata' src='$safeUrl'></audio></figure>"
        }

        if ($decodedUrl -match '\.(gif|bmp|svg|png|jpe?g|webp)(\?|#|$)') {
            if ([string]::IsNullOrWhiteSpace($safeAlt)) { $safeAlt = $safeUrl }
            return "<figure><a href='$safeUrl' target='_blank'><img src='$safeUrl' alt='$safeAlt' /></a></figure>"
        }

        return "<p><a href='$safeUrl' target='_blank'>$safeUrl</a></p>"
    }

    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    # 1) <ac:image> with <ri:attachment ... />
    # ac:image with ri:attachment
    $Html = [regex]::Replace(
        $Html,
        '<ac:image\b[^>]*>(?:(?!</?ac:image\b).)*?<ri:attachment\b[^>]*ri:filename="([^"]+)"[^>]*/>(?:(?!</?ac:image\b).)*?</ac:image>',
        {
            param($m)
            $filename = $m.Groups[1].Value
            Get-HuduAttachmentMarkup -Filename $filename -ImageMap $ImageMap -HuduBaseUrl $HuduBaseUrl
        },
        $regexOptions
    )

    # 2) ac:image with ri:url
    $Html = [regex]::Replace(
        $Html,
        '<ac:image\b([^>]*)>(?:(?!</?ac:image\b).)*?<ri:url\b[^>]*ri:value="([^"]+)"[^>]*/>(?:(?!</?ac:image\b).)*?</ac:image>',
        {
            param($m)
            $attrs = $m.Groups[1].Value
            $url   = $m.Groups[2].Value
            $alt   = ''

            if ($attrs -match '\bac:alt="([^"]*)"') {
                $alt = $Matches[1]
            }

            Get-RemoteMediaMarkup -Url $url -AltText $alt
        },
        $regexOptions
    )

    # 3) view-file macro with ri:attachment
    $Html = [regex]::Replace(
        $Html,
        '<ac:structured-macro\b[^>]*ac:name="view-file"[^>]*>.*?<ri:attachment\b[^>]*ri:filename="([^"]+)"[^>]*/>.*?</ac:structured-macro>',
        {
            param($m)
            $filename = $m.Groups[1].Value
            Get-HuduAttachmentMarkup -Filename $filename -ImageMap $ImageMap -HuduBaseUrl $HuduBaseUrl
        },
        $regexOptions
    )

    # 3) <ac:link> with <ri:attachment ... />
    $Html = [regex]::Replace(
        $Html,
        '<ac:link\b[^>]*>\s*<ri:attachment\b[^>]*ri:filename="([^"]+)"[^>]*/>\s*</ac:link>',
        {
            param($m)

            $filename = $m.Groups[1].Value
            $key = $filename.ToLowerInvariant()

            if ($ImageMap.ContainsKey($key)) {
                $mapEntry = $ImageMap[$key]
                $id = Get-HuduAttachmentReference -MapEntry $mapEntry
                $path = if ($mapEntry.Type -eq 'image') { 'public_photo' } else { 'file' }
                return "<a href='$HuduBaseUrl/$path/$id'>$(Get-HtmlEncoded $filename)</a>"
            }

            return "<!-- Missing attachment link: $(Get-HtmlEncoded $filename) -->"
        },
        $regexOptions
    )

    # 4) Task lists
    $Html = [regex]::Replace(
        $Html,
        '<ac:task-list\b[^>]*>(.*?)</ac:task-list>',
        {
            param($listMatch)

            $inner = $listMatch.Groups[1].Value

            $inner = [regex]::Replace(
                $inner,
                '<ac:task\b[^>]*>.*?<ac:task-status>(.*?)</ac:task-status>(.*?)</ac:task>',
                {
                    param($m)

                    $status    = $m.Groups[1].Value.Trim()
                    $bodyBlock = $m.Groups[2].Value
                    $body = ''

                    if ($bodyBlock -match '<ac:task-body>(.*?)</ac:task-body>') {
                        $body = $Matches[1]
                        $body = $body -replace '</?span[^>]*>', ''
                        $body = $body -replace '</?p[^>]*>', ''
                        $body = $body.Trim()
                    }

                    if (-not $body) { return '' }

                    $checkbox = if ($status -eq 'complete') { '☑' } else { '☐' }
                    return "<p>$checkbox $body</p>"
                },
                $regexOptions
            )

            return $inner.Trim()
        },
        $regexOptions
    )

    # 5) Status macros
    $Html = [regex]::Replace(
        $Html,
        '<ac:structured-macro\b[^>]*ac:name="status"[^>]*>(.*?)</ac:structured-macro>',
        {
            param($m)

            $inner = $m.Groups[1].Value
            $title = ''
            $colour = ''

            if ($inner -match '<ac:parameter\b[^>]*ac:name="title"[^>]*>(.*?)</ac:parameter>') {
                $title = (Get-HtmlDecoded $Matches[1]).Trim()
            }

            if ($inner -match '<ac:parameter\b[^>]*ac:name="colour"[^>]*>(.*?)</ac:parameter>') {
                $colour = (Get-HtmlDecoded $Matches[1]).Trim().ToLowerInvariant()
            }

            if ([string]::IsNullOrWhiteSpace($title)) {
                $title = 'status'
            }

            $class = switch ($colour) {
                'green'  { 'status-green' }
                'yellow' { 'status-yellow' }
                'red'    { 'status-red' }
                'blue'   { 'status-blue' }
                default  { 'status-neutral' }
            }

            return "<span class='confluence-status $class'>$(Get-HtmlEncoded $title)</span>"
        },
        $regexOptions
    )

    # 6) Emoji fallback
    $Html = [regex]::Replace(
        $Html,
        '<ac:emoticon\b[^>]*ac:emoji-fallback="([^"]*)"[^>]*/?>',
        {
            param($m)
            Get-HtmlDecoded $m.Groups[1].Value
        },
        $regexOptions
    )

    # 7) Placeholder
    $Html = [regex]::Replace(
        $Html,
        '<ac:placeholder\b[^>]*>(.*?)</ac:placeholder>',
        {
            param($m)
            $text = (Get-HtmlDecoded $m.Groups[1].Value).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return '' }
            return "<em>$(Get-HtmlEncoded $text)</em>"
        },
        $regexOptions
    )

    # 8) ADF extension blocks
    $Html = [regex]::Replace(
        $Html,
        '<ac:adf-extension\b[^>]*>.*?</ac:adf-extension>',
        '',
        $regexOptions
    )

    # 9) Remove leftover ri tags
    $Html = [regex]::Replace($Html, '<ri:[^>]+?/>', '', $regexOptions)
    $Html = [regex]::Replace($Html, '</?ri:[a-zA-Z0-9:_-]+\b[^>]*>', '', $regexOptions)

    # 10) Remove leftover ac tags only as tags, not as broad blocks
    $Html = [regex]::Replace($Html, '</?ac:[a-zA-Z0-9:_-]+\b[^>]*>', '', $regexOptions)

    # 11) Cleanup
    $Html = $Html -replace '<p>\s*</p>', ''
    $Html = $Html -replace '<p>\s*<br\s*/?>\s*</p>', ''
    $Html = $Html -replace '<li>\s*</li>', ''
    $Html = $Html -replace '/wikihttps://', 'https://'

    return $Html
}
function Cleanup-ResidualConfluenceHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html
    )

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ''
    }

    # Normalize self-closing tags
    $Html = $Html -replace '<p\s*/>', '<p></p>'
    $Html = $Html -replace '<td\s*/>', '<td></td>'
    $Html = $Html -replace '<th\s*/>', '<th></th>'
    $Html = $Html -replace '<li\s*/>', '<li></li>'

    # Remove empty paragraphs
    $Html = [regex]::Replace($Html, '<p>\s*(?:<br\s*/?>|\&nbsp;|\s)*</p>', '', 'IgnoreCase')

    # Remove empty list items
    $Html = [regex]::Replace($Html, '<li>\s*(?:<p>\s*(?:<br\s*/?>|\&nbsp;|\s)*</p>\s*)*</li>', '', 'IgnoreCase')

    # Remove empty table cells
    $Html = [regex]::Replace($Html, '<t([dh])>\s*(?:<p>\s*(?:<br\s*/?>|\&nbsp;|\s)*</p>\s*)*</t\1>', '<t$1></t$1>', 'IgnoreCase')

    # Remove fully empty rows
    $Html = [regex]::Replace(
        $Html,
        '<tr>\s*(?:<t[dh]>\s*</t[dh]>\s*)+</tr>',
        '',
        'IgnoreCase'
    )

    # Remove paragraphs that only wrap block elements
    $Html = [regex]::Replace($Html, '<p\b[^>]*>\s*(<(?:figure|table|h[1-6]|ul|ol)[^>]*>.*?</(?:figure|table|h[1-6]|ul|ol)>)\s*</p>', '$1', 'Singleline,IgnoreCase')

    # Collapse repeated blank lines between tags
    $Html = [regex]::Replace($Html, '>\s{2,}<', '><')

    # Optional: strip blank lines in general
    $Html = [regex]::Replace($Html, "(`r`n|\r|\n){2,}", "`n")

    return $Html.Trim()
}
function Get-SafeTitle {
    param ([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_')
}

function Get-ConfluenceLinks {
    param (
        [PSCustomObject]$page,
        [bool]$includeRelativeLinks=$false
        )
        
    $BaseUrls = @($ConfluenceDomainBase,$ConfluenceBaseUrl)
    if ($true -eq $includeRelativeLinks) {
        $BaseUrls+=""
    }

    $title = [System.Net.WebUtility]::UrlEncode($page.title)
    $id = $page.id
    $tinyui = $page._links.tinyui
    $webui = $page._links.webui
    $editui = $page._links.editui
    $self = $page._links.self
    $expandible = $body.storage._expandable.content

    $possible_links = @()

    foreach ($baseurl in $BaseUrls) {
        foreach ($identifier in @($title, $id)) {
            $possible_links += @(
                "$baseurl/wiki/rest/api/content/$identifier",
                "$baseurl/rest/api/content/$identifier",
                "$baseurl/wiki/$identifier",
                "$baseurl/pageId=$identifier",
                "$baseurl/pageId?$identifier",
                "$baseurl/page/$identifier",
                "$baseurl/pages/$identifier"
            )
        }

        foreach ($path in @($webui, $editui, $tinyui, $self, $expandible)) {
            if ($null -ne $path) {
                $possible_links += @(
                    "$baseurl/wiki$path",
                    "$baseurl$path",
                    "$baseurl$path"
                )
            }
        }
    }


    return $possible_links | Sort-Object { $_.Length } -Descending -Unique
}
function Strip-ConfluenceBloat {
    param([string]$Html)

    # ── TASK LISTS ────────────────────────────────────────────────────────────
    # MUST run before the generic <ac:*> stripper below.
    #
    # Handles:
    #   - <ac:task-list> with optional attributes (ac:task-list-id etc.)
    #   - <ac:task> items with optional/empty <ac:task-body>
    #   - Multiple task lists in a single page
    #
    # Produces: <p>☐ task text</p> (one paragraph per task, no list wrapper)

    $Html = [regex]::Replace($Html, '<ac:task-list[^>]*>(.*?)</ac:task-list>', {
        param($listMatch)
        $inner = $listMatch.Groups[1].Value

        # Convert each ac:task — task-body is optional (some tasks are empty)
        $inner = [regex]::Replace($inner, '<ac:task>.*?<ac:task-status>(.*?)</ac:task-status>(.*?)</ac:task>', {
            param($m)
            $status    = $m.Groups[1].Value.Trim()
            $bodyBlock = $m.Groups[2].Value

            # Extract body text if present
            $body = ''
            if ($bodyBlock -match '<ac:task-body>(.*?)</ac:task-body>') {
                $body = $Matches[1]
                $body = $body -replace '<span[^>]*>', '' -replace '</span>', ''
                $body = $body -replace '</?p>', ''
                $body = $body.Trim()
            }

            # Skip empty tasks entirely
            if (-not $body) { return '' }

            $checkbox = if ($status -eq 'complete') { '☑' } else { '☐' }
            return "<p>$checkbox $body</p>"
        }, 'Singleline')

        # Only emit content if there are actual tasks
        $inner = $inner.Trim()
        if ($inner) { return $inner } else { return '' }
    }, 'Singleline')

    # ── GENERIC AC / RI TAG REMOVAL ───────────────────────────────────────────
    # Safe to run now that task lists have been converted above.

    # Remove all remaining <ac:*>...</ac:*>
    $Html = [regex]::Replace($Html, '<ac:[^>]+>.*?</ac:[^>]+>', '', 'Singleline')

    # Remove self-closing <ac:... />
    $Html = [regex]::Replace($Html, '<ac:[^>]+?/>', '', 'Singleline')

    # Remove <ri:...> and <ri:.../>
    $Html = [regex]::Replace($Html, '<ri:[^>]+?>', '', 'Singleline')
    $Html = [regex]::Replace($Html, '<ri:[^>]+?/>', '', 'Singleline')

    # ── CLEANUP ───────────────────────────────────────────────────────────────

    # Remove empty paragraphs
    $Html = [regex]::Replace($Html, '<p>\s*</p>', '', 'Singleline')

    # Remove placeholders
    $Html = $Html -replace '<ac:placeholder>.*?<\/ac:placeholder>', ''

    # Strip empty list items
    $Html = $Html -replace '<li>\s*<p\s*/>\s*</li>', ''
    $Html = $Html -replace '<li>\s*<p><br\s*/?></p>\s*</li>', ''

    # Remove empty table rows
    $Html = $Html -replace '<tr>(\s*<td>(<p\s*/>|<p><br\s*/?></p>)</td>\s*)+</tr>', ''
    $Html = $Html -replace '<tr>(\s*<td>(<p\s*\/>|<p><br\s*\/?><\/p>)<\/td>\s*)+</tr>', ''

    # Emojis to Unicode fallback character
    $Html = $Html -replace '<ac:emoticon[^>]*?ac:emoji-fallback="(.*?)"[^>]*>', '$1'

    # Strip Atlassian ADF extension blocks
    $Html = $Html -replace '<ac:adf-extension>.*?</ac:adf-extension>', ''

    # Remove Atlassian boilerplate meeting headers
    $Html = $Html -replace '<h2>.*?(Date|Participants|Goals|Discussion topics|Decisions).*?</h2>', ''

    # Fix malformed URLs produced by Confluence link rewriting
    $Html = $Html -replace '/wikihttps://', 'https://'
    $Html = $Html -replace "https://$ConfluenceDomain\.atlassian\.net/wikihttps://", 'https://'

    return $Html
}


function Get-CoercedBoolean {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    if ($text -match '^(1|true|yes|y|on|enabled)$') { return $true }
    if ($text -match '^(0|false|no|n|off|disabled)$') { return $false }

    return $Default
}

function Get-CoercedDouble {
    param(
        [object]$Value,
        [double]$Default
    )

    if ($null -eq $Value) { return $Default }
    $parsed = 0.0
    if ([double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function Get-CoercedInteger {
    param(
        [object]$Value,
        [int]$Default,
        [int]$Minimum = [int]::MinValue,
        [int]$Maximum = [int]::MaxValue
    )

    if ($null -eq $Value) { return $Default }

    $parsed = 0
    if (-not [int]::TryParse("$Value", [ref]$parsed)) {
        return $Default
    }

    return [Math]::Min($Maximum, [Math]::Max($Minimum, $parsed))
}

function Normalize-ConfluenceTableCellText {
    param([object]$Text)

    if ($null -eq $Text) { return "" }

    $value = [System.Net.WebUtility]::HtmlDecode("$Text")
    $value = $value -replace "$([char]0x00A0)", ' '
    $value = $value -replace '\s+', ' '
    return $value.Trim()
}

function Get-ConfluenceTableHeaderKey {
    param([string]$Header)

    $value = (Normalize-ConfluenceTableCellText -Text $Header).ToLowerInvariant()
    $value = $value -replace '[^a-z0-9]+', '_'
    $value = $value.Trim('_')
    if ([string]::IsNullOrWhiteSpace($value)) { return "column" }
    return $value
}

function Test-ConfluenceTableCellLooksLikeData {
    param([string]$Text)

    $value = Normalize-ConfluenceTableCellText -Text $Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }

    if ($value.Length -gt 64) { return $true }
    if ($value -match '(?i)\bhttps?://|www\.|@[\w.-]+\.[a-z]{2,}\b') { return $true }
    if ($value -match '\b(?:\d{1,3}\.){3}\d{1,3}\b') { return $true }
    if ($value -match '(?i)\b[0-9a-f]{2}(?::[0-9a-f]{2}){5}\b') { return $true }
    if ($value -match '\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b\d{4}-\d{2}-\d{2}\b') { return $true }
    if ($value -match '\b\d{3}[-.)\s]?\d{3}[-.\s]?\d{4}\b') { return $true }
    if ($value -match '(?i)\b\d+\s+[a-z0-9 .#-]+(?:st|street|ave|avenue|rd|road|dr|drive|blvd|boulevard|ln|lane|ct|court|terrace|pkwy|parkway|hwy|highway|suite|ste|unit)\b') { return $true }
    if ($value -match '\b[A-Z0-9]{4,}(?:-[A-Z0-9]{4,}){1,}\b') { return $true }
    if ($value -match '^\$?\d+(?:,\d{3})*(?:\.\d+)?%?$') { return $true }

    return $false
}

function Test-ConfluenceTableCellHasHeaderKeyword {
    param([string]$Text)

    $key = Get-ConfluenceTableHeaderKey -Header $Text
    if ([string]::IsNullOrWhiteSpace($key)) { return $false }

    $headerTokens = @(
        'name','role','contact','phone','email','user','username','computer','pc','hostname',
        'server','service','description','time','duration','setting','property','value',
        'ip','address','mac','port','internal','external','product','key','license',
        'serial','version','installed','notes','note','printer','provider','device',
        'function','location','login','date','type','quantity','qty','status','technician',
        'subnet','vlan','purpose','wan','lan','gateway','dns','model','make','warranty',
        'account','expires','expiration','coverage','start','end','path','letter'
    )

    foreach ($token in $headerTokens) {
        if ($key -match "(^|_)$([regex]::Escape($token))(_|$)") {
            return $true
        }
    }

    return $false
}

function Test-ConfluenceTableCellLooksLikeHeader {
    param([string]$Text)

    $value = Normalize-ConfluenceTableCellText -Text $Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    if ($value.Length -gt 48) { return $false }
    if ($value -notmatch '[A-Za-z]') { return $false }
    if (Test-ConfluenceTableCellLooksLikeData -Text $value) { return $false }

    $wordCount = @($value -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($wordCount -gt 7) { return $false }

    return $true
}

function Test-ConfluenceTableFirstRowLooksLikeHeader {
    param([object[]]$Rows)

    if ($Rows.Count -lt 2) { return $false }

    $firstCells = @($Rows[0].Cells)
    $nonBlank = @($firstCells | Where-Object { -not [string]::IsNullOrWhiteSpace((Normalize-ConfluenceTableCellText -Text $_)) })
    if ($nonBlank.Count -lt 2) { return $false }

    if ($firstCells.Count -eq 2) {
        $firstHasHeaderKeyword = Test-ConfluenceTableCellHasHeaderKeyword -Text $firstCells[0]
        $secondHasHeaderKeyword = Test-ConfluenceTableCellHasHeaderKeyword -Text $firstCells[1]
        $secondIsHeaderWord = Test-ConfluenceTableCellLooksLikeHeader -Text $firstCells[1]
        if ($firstHasHeaderKeyword -and -not $secondHasHeaderKeyword -and -not ($secondIsHeaderWord -and $firstCells[1] -match '(?i)^(value|description|notes?|detail|setting|property)$')) {
            return $false
        }
    }

    $headerLikeCount = @($nonBlank | Where-Object { Test-ConfluenceTableCellLooksLikeHeader -Text $_ }).Count
    $dataLikeCount = @($nonBlank | Where-Object { Test-ConfluenceTableCellLooksLikeData -Text $_ }).Count
    $keywordCount = @($nonBlank | Where-Object { Test-ConfluenceTableCellHasHeaderKeyword -Text $_ }).Count

    $headerRatio = $headerLikeCount / $nonBlank.Count
    $maxDataCells = [Math]::Max(1, [Math]::Floor($nonBlank.Count * 0.34))

    if ($headerRatio -lt 0.60 -or $dataLikeCount -gt $maxDataCells) {
        return $false
    }

    $secondCells = @($Rows[1].Cells | Where-Object { -not [string]::IsNullOrWhiteSpace((Normalize-ConfluenceTableCellText -Text $_)) })
    $secondDataLikeCount = @($secondCells | Where-Object { Test-ConfluenceTableCellLooksLikeData -Text $_ }).Count

    return ($keywordCount -ge 2 -or $secondDataLikeCount -gt $dataLikeCount)
}

function Get-UniqueConfluenceTableHeaders {
    param(
        [string[]]$Headers,
        [string[]]$ReservedHeaders = @()
    )

    $seen = @{}
    $reserved = @{}
    foreach ($reservedHeader in $ReservedHeaders) {
        $reserved[$reservedHeader.ToLowerInvariant()] = $true
    }

    $uniqueHeaders = @()
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $header = Normalize-ConfluenceTableCellText -Text $Headers[$i]
        if ([string]::IsNullOrWhiteSpace($header)) {
            $header = "Column$($i + 1)"
        }

        $header = $header -replace '[\r\n]+', ' '
        $header = $header -replace '[\\/:*?"<>|]', '_'
        $baseHeader = $header

        if ($reserved.ContainsKey($baseHeader.ToLowerInvariant())) {
            $baseHeader = "Table_$baseHeader"
        }

        $candidate = $baseHeader
        $suffix = 2
        while ($seen.ContainsKey($candidate.ToLowerInvariant()) -or $reserved.ContainsKey($candidate.ToLowerInvariant())) {
            $candidate = "$baseHeader`_$suffix"
            $suffix++
        }

        $seen[$candidate.ToLowerInvariant()] = $true
        $uniqueHeaders += $candidate
    }

    return $uniqueHeaders
}

function ConvertTo-ConfluenceXmlDocument {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }

    $safeHtml = $Html
    $entityMap = @{
        '&nbsp;'  = '&#160;'
        '&ndash;' = '-'
        '&mdash;' = '-'
        '&hellip;' = '...'
        '&copy;'  = '(c)'
        '&reg;'   = '(r)'
        '&trade;' = '(tm)'
        '&lsquo;' = "'"
        '&rsquo;' = "'"
        '&ldquo;' = '"'
        '&rdquo;' = '"'
    }

    foreach ($entity in $entityMap.Keys) {
        $safeHtml = $safeHtml.Replace($entity, $entityMap[$entity])
    }

    $safeHtml = [regex]::Replace($safeHtml, '&(?!amp;|lt;|gt;|quot;|apos;|#[0-9]+;|#x[0-9a-fA-F]+;)', '&amp;')
    $safeHtml = [regex]::Replace($safeHtml, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')

    $wrapped = "<root xmlns:ac=`"http://atlassian.com/content`" xmlns:ri=`"http://atlassian.com/resource/identifier`">$safeHtml</root>"

    try {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $settings.CheckCharacters = $false

        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($wrapped), $settings)
        $doc = [System.Xml.XmlDocument]::new()
        $doc.PreserveWhitespace = $false
        $doc.Load($reader)
        return $doc
    } catch {
        return $null
    }
}

function Test-ConfluenceNodeBelongsToTable {
    param(
        [System.Xml.XmlNode]$Node,
        [System.Xml.XmlNode]$TableNode
    )

    $ancestor = $Node.ParentNode
    while ($null -ne $ancestor) {
        if ($ancestor.LocalName -eq 'table') {
            return [object]::ReferenceEquals($ancestor, $TableNode)
        }
        $ancestor = $ancestor.ParentNode
    }

    return $false
}

function Get-ConfluenceTableAttributeInt {
    param(
        [System.Xml.XmlElement]$Node,
        [string]$Name,
        [int]$Default = 1
    )

    $value = $Node.GetAttribute($Name)
    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }

    return $Default
}

function Convert-ConfluenceHtmlTableToModel {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$TableNode,
        [int]$TableIndex = 1
    )

    $rowNodes = @($TableNode.SelectNodes(".//*[local-name()='tr']") | Where-Object {
        Test-ConfluenceNodeBelongsToTable -Node $_ -TableNode $TableNode
    })

    if ($rowNodes.Count -eq 0) { return $null }

    $rowSpans = @{}
    $rows = [System.Collections.ArrayList]@()

    foreach ($rowNode in $rowNodes) {
        $rowCells = @{}
        $rowHasHeader = $false

        foreach ($key in @($rowSpans.Keys)) {
            $columnIndex = [int]$key
            $rowCells[$columnIndex] = $rowSpans[$key].Text
            $rowSpans[$key].RemainingRows--
            if ($rowSpans[$key].RemainingRows -le 0) {
                $rowSpans.Remove($key)
            }
        }

        $cellNodes = @($rowNode.ChildNodes | Where-Object {
            $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -in @('th', 'td')
        })

        $columnIndex = 0
        foreach ($cellNode in $cellNodes) {
            if ($cellNode.LocalName -eq 'th') {
                $rowHasHeader = $true
            }

            while ($rowCells.ContainsKey($columnIndex)) {
                $columnIndex++
            }

            $cellText = Normalize-ConfluenceTableCellText -Text $cellNode.InnerText
            $colSpan = Get-ConfluenceTableAttributeInt -Node $cellNode -Name 'colspan' -Default 1
            $rowSpan = Get-ConfluenceTableAttributeInt -Node $cellNode -Name 'rowspan' -Default 1

            for ($offset = 0; $offset -lt $colSpan; $offset++) {
                $targetColumn = $columnIndex + $offset
                $rowCells[$targetColumn] = $cellText

                if ($rowSpan -gt 1) {
                    $rowSpans[$targetColumn] = [PSCustomObject]@{
                        Text          = $cellText
                        RemainingRows = $rowSpan - 1
                    }
                }
            }

            $columnIndex += $colSpan
        }

        if ($rowCells.Count -gt 0) {
            $maxColumn = ($rowCells.Keys | Measure-Object -Maximum).Maximum
            $cells = for ($i = 0; $i -le $maxColumn; $i++) {
                if ($rowCells.ContainsKey($i)) { $rowCells[$i] } else { "" }
            }

            [void]$rows.Add([PSCustomObject]@{
                Cells     = @($cells)
                HasHeader = $rowHasHeader
            })
        }
    }

    if ($rows.Count -eq 0) { return $null }

    $maxColumnCount = ($rows | ForEach-Object { $_.Cells.Count } | Measure-Object -Maximum).Maximum
    foreach ($row in $rows) {
        while ($row.Cells.Count -lt $maxColumnCount) {
            $row.Cells += ""
        }
    }

    $explicitHeaderRowCount = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($rows[$i].HasHeader) {
            $explicitHeaderRowCount++
        } else {
            break
        }
    }

    $headerRowCount = $explicitHeaderRowCount
    $headerSource = "ExplicitTh"
    $headerConfidence = 1.0

    if ($headerRowCount -eq 0 -and (Test-ConfluenceTableFirstRowLooksLikeHeader -Rows @($rows))) {
        $headerRowCount = 1
        $headerSource = "InferredFirstRow"
        $headerConfidence = 0.72
    } elseif ($headerRowCount -eq 0) {
        $headerSource = "Generated"
        $headerConfidence = 0.15
    }

    $rawHeaders = @()
    for ($column = 0; $column -lt $maxColumnCount; $column++) {
        $parts = @()
        for ($headerRow = 0; $headerRow -lt $headerRowCount; $headerRow++) {
            $part = Normalize-ConfluenceTableCellText -Text $rows[$headerRow].Cells[$column]
            if (-not [string]::IsNullOrWhiteSpace($part) -and $parts -notcontains $part) {
                $parts += $part
            }
        }

        if ($parts.Count -eq 0) {
            if ($headerSource -eq "Generated" -and $maxColumnCount -eq 2) {
                $rawHeaders += @("Field", "Value")[$column]
            } elseif ($headerSource -eq "Generated" -and $maxColumnCount -eq 1) {
                $rawHeaders += "Value"
            } else {
                $rawHeaders += "Column$($column + 1)"
            }
        } else {
            $rawHeaders += ($parts -join ' - ')
        }
    }

    $dataRows = [System.Collections.ArrayList]@()
    for ($rowIndex = $headerRowCount; $rowIndex -lt $rows.Count; $rowIndex++) {
        [void]$dataRows.Add($rows[$rowIndex].Cells)
    }

    $sampleText = (
        @($rows | Select-Object -First 4 | ForEach-Object { $_.Cells }) |
            Where-Object { -not [string]::IsNullOrWhiteSpace((Normalize-ConfluenceTableCellText -Text $_)) } |
            Select-Object -First 24
    ) -join ' '

    $metadataHeaders = @('CompanyId','CompanyName','SpaceKey','SpaceName','PageId','PageTitle','PageUrl','TableIndex','RowIndex')
    $headers = Get-UniqueConfluenceTableHeaders -Headers $rawHeaders -ReservedHeaders $metadataHeaders
    $headerKeys = @($headers | ForEach-Object { Get-ConfluenceTableHeaderKey -Header $_ })

    return [PSCustomObject]@{
        TableIndex     = $TableIndex
        Headers        = @($headers)
        HeaderKeys     = @($headerKeys)
        HeaderRowCount = $headerRowCount
        HeaderSource   = $headerSource
        HeaderConfidence = $headerConfidence
        DataRows       = $dataRows
        ColumnCount    = $maxColumnCount
        RowCount       = $rows.Count
        SampleText     = $sampleText
    }
}

function Measure-ConfluenceTableHeaderSimilarity {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    if ($Left.Count -eq 0 -or $Right.Count -eq 0) { return 0.0 }

    $positionMatches = 0
    $maxCount = [Math]::Max($Left.Count, $Right.Count)
    $minCount = [Math]::Min($Left.Count, $Right.Count)
    for ($i = 0; $i -lt $minCount; $i++) {
        if ($Left[$i] -eq $Right[$i]) {
            $positionMatches++
        }
    }
    $positionScore = $positionMatches / $maxCount
    $countScore = $minCount / $maxCount

    $leftTokens = @($Left | ForEach-Object { $_ -split '_' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $rightTokens = @($Right | ForEach-Object { $_ -split '_' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $union = @($leftTokens + $rightTokens | Sort-Object -Unique)
    if ($union.Count -eq 0) { return [Math]::Round((0.8 * $positionScore) + (0.2 * $countScore), 4) }

    $intersection = @($leftTokens | Where-Object { $rightTokens -contains $_ })
    $tokenScore = $intersection.Count / $union.Count

    return [Math]::Round((0.45 * $positionScore) + (0.40 * $tokenScore) + (0.15 * $countScore), 4)
}

function Get-ConfluenceTableTextTokens {
    param([string]$Text)

    $value = (Normalize-ConfluenceTableCellText -Text $Text).ToLowerInvariant()
    $value = $value -replace '[^a-z0-9]+', ' '

    $stopWords = @{
        'a'=$true; 'an'=$true; 'and'=$true; 'are'=$true; 'as'=$true; 'at'=$true; 'by'=$true
        'for'=$true; 'from'=$true; 'in'=$true; 'into'=$true; 'is'=$true; 'it'=$true
        'of'=$true; 'on'=$true; 'or'=$true; 'the'=$true; 'to'=$true; 'with'=$true
        'inc'=$true; 'llc'=$true; 'ltd'=$true; 'corp'=$true; 'corporation'=$true
        'company'=$true; 'co'=$true; 'client'=$true; 'customer'=$true; 'kb'=$true
        'page'=$true; 'pages'=$true; 'article'=$true; 'articles'=$true; 'info'=$true
        'information'=$true; 'old'=$true; 'new'=$true; 'current'=$true
    }

    $synonyms = @{
        'pcs'='computer'; 'pc'='computer'; 'workstation'='computer'; 'workstations'='computer'
        'laptop'='computer'; 'laptops'='computer'; 'desktop'='computer'; 'desktops'='computer'
        'computers'='computer'; 'licenses'='license'; 'licensing'='license'; 'licensed'='license'
        'keys'='key'; 'serials'='serial'; 'users'='user'; 'devices'='device'; 'printers'='printer'
        'servers'='server'; 'vlans'='vlan'; 'subnets'='subnet'; 'addresses'='address'
        'locations'='location'; 'providers'='provider'; 'circuits'='circuit'
    }

    $tokens = [System.Collections.ArrayList]@()
    foreach ($token in @($value -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        if ($token.Length -lt 2) { continue }
        if ($token -match '^\d+$') { continue }
        if ($stopWords.ContainsKey($token)) { continue }
        if ($synonyms.ContainsKey($token)) { $token = $synonyms[$token] }
        if (-not $tokens.Contains($token)) {
            [void]$tokens.Add($token)
        }
    }

    return @($tokens)
}

function Remove-ConfluenceTableOrganizationText {
    param(
        [string]$Text,
        [object]$Page,
        [object]$PageAttribution,
        [object[]]$Companies = @()
    )

    $clean = Normalize-ConfluenceTableCellText -Text $Text
    if ([string]::IsNullOrWhiteSpace($clean)) { return "" }

    $orgNames = [System.Collections.ArrayList]@()
    foreach ($candidate in @($Page.SpaceName, $Page.SpaceKey, $PageAttribution.CompanyName)) {
        if (-not [string]::IsNullOrWhiteSpace("$candidate") -and "$candidate".Length -gt 2) {
            [void]$orgNames.Add("$candidate")
        }
    }

    foreach ($company in @($Companies | Where-Object { $null -ne $_ })) {
        if (-not [string]::IsNullOrWhiteSpace($company.Name) -and $company.Name.Length -gt 4) {
            [void]$orgNames.Add($company.Name)
        }
    }

    foreach ($orgName in @($orgNames | Sort-Object Length -Descending -Unique)) {
        $clean = [regex]::Replace($clean, [regex]::Escape($orgName), ' ', 'IgnoreCase')
    }

    $clean = [regex]::Replace($clean, '(?i)\b(incorporated|inc|llc|ltd|corp|corporation|company|co)\b\.?', ' ')
    $clean = [regex]::Replace($clean, '\s+', ' ')
    return $clean.Trim()
}

function Get-ConfluenceTableTitleGroup {
    param(
        [Parameter(Mandatory)][object]$Page,
        [Parameter(Mandatory)][object]$Model,
        [object]$PageAttribution,
        [object[]]$Companies = @(),
        [bool]$Enabled = $true
    )

    if (-not $Enabled) {
        return [PSCustomObject]@{ Key = $null; Name = $null; Score = 0.0; Tokens = @(); Source = "Disabled" }
    }

    $pageTitle = Remove-ConfluenceTableOrganizationText -Text ($Page.OriginalTitle ?? $Page.title) -Page $Page -PageAttribution $PageAttribution -Companies $Companies
    $headerText = @($Model.Headers) -join ' '
    $sampleText = $Model.SampleText ?? ''
    $titleLower = $pageTitle.ToLowerInvariant()
    $combinedLower = "$pageTitle $headerText $sampleText".ToLowerInvariant()

    function New-TableTitleGroup {
        param([string]$Key, [string]$Name, [double]$Score, [string]$Source)
        $tokens = Get-ConfluenceTableTextTokens -Text $pageTitle
        return [PSCustomObject]@{
            Key    = $Key
            Name   = $Name
            Score  = $Score
            Tokens = @($tokens)
            Source = $Source
        }
    }

    function Test-TableCategory {
        param([string]$Pattern, [string]$NegativePattern = $null)
        if (-not [string]::IsNullOrWhiteSpace($NegativePattern) -and $combinedLower -match $NegativePattern) { return $false }
        return $combinedLower -match $Pattern
    }

    $titleScore = 0.86
    $mixedScore = 0.70

    if (Test-TableCategory -Pattern '(office|physical|mailing|shipping|billing|site|location).{0,24}address|address.{0,24}(office|physical|mailing|shipping|billing|site|location)' -NegativePattern '\b(ip|mac|network|external|internal|wan|lan)\s+address') { return New-TableTitleGroup -Key 'office_locations' -Name 'Office Locations' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(o365|office\s*365|microsoft\s*365|msft|exchange|mailbox|tenant)\b') { return New-TableTitleGroup -Key 'microsoft_365' -Name 'Microsoft 365' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(requirement|requirements|user\s+story|project|status|current\s+step|epic|target\s+release)\b') { return New-TableTitleGroup -Key 'projects' -Name 'Projects and Requirements' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(retired|retirement|decommission|disposed)\b') { return New-TableTitleGroup -Key 'retired_assets' -Name 'Retired Assets' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(backup|backups|veeam|job|duration|reboot\s+time)\b') { return New-TableTitleGroup -Key 'backup_jobs' -Name 'Backups and Jobs' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(product\s+key|license|licence|licensing|activation|registration|redemption|serial|installed\s+on|software|product\s+#|product\s+number|cd\s*key)\b') { return New-TableTitleGroup -Key 'software_licenses' -Name 'Software Licenses' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(provider|internet|isp|circuit|fiber|dsl|broadband|comcast|spectrum|at&t|att|google\s+fiber|centurylink|windstream|hypercore|skypan|skspan|ralk|wan\s+1|wan\s+2)\b') { return New-TableTitleGroup -Key 'internet_circuits' -Name 'Internet Circuits' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(vlan|vlans)\b') { return New-TableTitleGroup -Key 'vlans' -Name 'VLANs' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(port\s+forward|forwarding|external\s+port|internal\s+port|nat|firewall\s+rule)\b') { return New-TableTitleGroup -Key 'port_forwards' -Name 'Port Forwards' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(wifi|wi-fi|wireless|ssid|wpa|passphrase)\b') { return New-TableTitleGroup -Key 'wireless' -Name 'Wireless' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(printer|copier|scanner|print\s+queue)\b') { return New-TableTitleGroup -Key 'printers' -Name 'Printers' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(switch|switches|switch\s+name)\b') { return New-TableTitleGroup -Key 'switches' -Name 'Switches' -Score $titleScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(firewall|router|sonicwall|fortinet|meraki|ubiquiti|unifi|network\s+device)\b') { return New-TableTitleGroup -Key 'network_devices' -Name 'Network Devices' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(ip\s+scheme|ip\s+address|subnet|dhcp|dns|gateway|static\s+ip|mac\s+address|network\s+address|accessible\s+range)\b') { return New-TableTitleGroup -Key 'network_ip' -Name 'Network IPs and Subnets' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(server|servers|hyper-v|vmware|domain\s+controller|cpu|ram|disk)\b') { return New-TableTitleGroup -Key 'servers' -Name 'Servers' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(hostname|computer|pc|workstation|laptop|desktop|make[_\s/]*model|warranty|asset)\b') { return New-TableTitleGroup -Key 'computers' -Name 'Computers' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(contact|contacts|role|phone|email|staff|employee)\b') { return New-TableTitleGroup -Key 'contacts' -Name 'Contacts' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(vendor|supplier|support\s+options|licensed\s+with|spam\s+filter)\b') { return New-TableTitleGroup -Key 'vendors' -Name 'Vendors' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(login|password|secret|credential|account|admin)\b') { return New-TableTitleGroup -Key 'credentials_access' -Name 'Credentials and Access' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(path|drive\s+letter|mapped\s+drive|share|unc)\b') { return New-TableTitleGroup -Key 'shares_paths' -Name 'Shares and Paths' -Score $mixedScore -Source 'Keyword' }
    if (Test-TableCategory -Pattern '\b(voip|phone|extension|did|voice)\b') { return New-TableTitleGroup -Key 'phones_voice' -Name 'Phones and Voice' -Score $mixedScore -Source 'Keyword' }

    $tokens = @(Get-ConfluenceTableTextTokens -Text $pageTitle | Select-Object -First 3)
    if ($tokens.Count -gt 0) {
        $name = ($tokens | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase($_) }) -join ' '
        return [PSCustomObject]@{
            Key    = "title_$($tokens -join '_')"
            Name   = "Title - $name"
            Score  = 0.46
            Tokens = $tokens
            Source = "TitleTokens"
        }
    }

    return [PSCustomObject]@{ Key = $null; Name = $null; Score = 0.0; Tokens = @(); Source = "None" }
}

function Get-ConfluenceTableGroup {
    param(
        [System.Collections.ArrayList]$Groups,
        [Parameter(Mandatory)][object]$Model,
        [object]$TitleGroup,
        [double]$Threshold,
        [double]$TitleCategoryThreshold = 0.74
    )

    $bestGroup = $null
    $bestScore = 0.0
    $bestHeaderScore = 0.0
    $bestTitleMatch = $false

    foreach ($group in $Groups) {
        $headerScore = Measure-ConfluenceTableHeaderSimilarity -Left @($group.HeaderKeys) -Right @($Model.HeaderKeys)
        $sameTitleGroup = (
            $null -ne $TitleGroup -and
            -not [string]::IsNullOrWhiteSpace($TitleGroup.Key) -and
            -not [string]::IsNullOrWhiteSpace($group.TitleGroupKey) -and
            $TitleGroup.Key -eq $group.TitleGroupKey
        )

        $score = $headerScore
        if ($sameTitleGroup) {
            $titleScore = [Math]::Max([double]$TitleGroup.Score, [double]$group.TitleGroupScore)
            $categoryBoost = if ($titleScore -ge 0.65) { 0.90 } else { 0.76 }
            if ($Model.HeaderSource -eq 'Generated' -or $group.HeaderSource -eq 'Generated') {
                $categoryBoost += 0.04
            }
            $score = [Math]::Max($headerScore, [Math]::Min(0.96, $categoryBoost))
        } elseif ($Model.HeaderSource -eq 'Generated' -or $group.HeaderSource -eq 'Generated') {
            $score = $headerScore * 0.55
        }

        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestHeaderScore = $headerScore
            $bestGroup = $group
            $bestTitleMatch = $sameTitleGroup
        }
    }

    if ($null -ne $bestGroup -and ($bestScore -ge $Threshold -or ($bestTitleMatch -and $bestScore -ge $TitleCategoryThreshold))) {
        return [PSCustomObject]@{
            Group       = $bestGroup
            Score       = [Math]::Round($bestScore, 4)
            HeaderScore = [Math]::Round($bestHeaderScore, 4)
            TitleMatch  = $bestTitleMatch
        }
    }

    return $null
}

function Resolve-ConfluenceTableGroupHeader {
    param(
        [Parameter(Mandatory)][object]$Group,
        [Parameter(Mandatory)][string]$Header
    )

    $headerKey = Get-ConfluenceTableHeaderKey -Header $Header
    if ($Group.HeaderKeyToName.ContainsKey($headerKey)) {
        return $Group.HeaderKeyToName[$headerKey]
    }

    $candidate = Normalize-ConfluenceTableCellText -Text $Header
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = "Column$($Group.Headers.Count + 1)"
    }

    $baseCandidate = $candidate
    $suffix = 2
    while (@($Group.Headers | Where-Object { "$_" -ieq $candidate }).Count -gt 0) {
        $candidate = "$baseCandidate`_$suffix"
        $suffix++
    }

    $Group.HeaderKeyToName[$headerKey] = $candidate
    [void]$Group.Headers.Add($candidate)
    [void]$Group.HeaderKeys.Add($headerKey)
    $Group.Fingerprint = (@($Group.HeaderKeys) -join '|')
    return $candidate
}

function Add-ConfluenceTableGroupHeaders {
    param(
        [Parameter(Mandatory)][object]$Group,
        [string[]]$Headers
    )

    foreach ($header in @($Headers)) {
        [void](Resolve-ConfluenceTableGroupHeader -Group $Group -Header $header)
    }
}

function Convert-ConfluenceTableGroupRowsForCsv {
    param(
        [Parameter(Mandatory)][System.Collections.ArrayList]$Rows,
        [Parameter(Mandatory)][string[]]$Headers
    )

    foreach ($row in $Rows) {
        $ordered = [ordered]@{}
        foreach ($header in $Headers) {
            if ($row -is [System.Collections.IDictionary]) {
                $ordered[$header] = if ($row.Contains($header)) { $row[$header] } else { "" }
            } elseif ($row.PSObject.Properties[$header]) {
                $ordered[$header] = $row.PSObject.Properties[$header].Value
            } else {
                $ordered[$header] = ""
            }
        }
        [PSCustomObject]$ordered
    }
}

function Get-ConfluenceTablePageAttribution {
    param(
        [Parameter(Mandatory)][object]$Page,
        [hashtable]$SpaceCompanyMap = @{},
        [object]$SingleCompanyChoice,
        [object[]]$AttributionOptions = @(),
        [object[]]$Companies = @()
    )

    $companyId = $Page.CompanyId
    if ($null -eq $companyId -or $companyId -lt 1) {
        $companyName = if ($companyId -eq -1) { "Skipped" } else { "Global KB" }
        return [PSCustomObject]@{
            CompanyId   = $companyId
            CompanyName = $companyName
        }
    }

    $spaceMapKey = [string]$Page.SpaceKey
    if ($SpaceCompanyMap.ContainsKey($spaceMapKey)) {
        return [PSCustomObject]@{
            CompanyId   = $SpaceCompanyMap[$spaceMapKey].CompanyId
            CompanyName = $SpaceCompanyMap[$spaceMapKey].CompanyName
        }
    }

    if ($null -ne $SingleCompanyChoice -and $SingleCompanyChoice.Id -eq $companyId) {
        return [PSCustomObject]@{
            CompanyId   = $SingleCompanyChoice.Id
            CompanyName = $SingleCompanyChoice.Name
        }
    }

    $match = @($AttributionOptions | Where-Object { $_.CompanyId -eq $companyId } | Select-Object -First 1)[0]
    if ($null -eq $match) {
        $match = @($Companies | Where-Object { $_.Id -eq $companyId } | Select-Object -First 1)[0]
    }

    return [PSCustomObject]@{
        CompanyId   = $companyId
        CompanyName = $match.CompanyName ?? $match.Name ?? "Company ID $companyId"
    }
}

function Write-CsvHeaderOnly {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Headers
    )

    $line = ($Headers | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','
    Set-Content -Path $Path -Value $line -Encoding UTF8
}

function Export-ConfluenceTables {
    param(
        [Parameter(Mandatory)][object[]]$Pages,
        [Parameter(Mandatory)][string]$OutDir,
        [hashtable]$SpaceCompanyMap = @{},
        [object]$SingleCompanyChoice,
        [object[]]$AttributionOptions = @(),
        [object[]]$Companies = @(),
        [double]$SchemaMatchThreshold = 0.86,
        [bool]$UseTitleGrouping = $true,
        [double]$TitleCategoryMatchThreshold = 0.74
    )

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

    $groups = [System.Collections.ArrayList]@()
    $inventory = [System.Collections.ArrayList]@()
    $parseWarnings = [System.Collections.ArrayList]@()
    $metadataHeaders = @('CompanyId','CompanyName','SpaceKey','SpaceName','PageId','PageTitle','PageUrl','TableIndex','RowIndex')

    foreach ($page in $Pages) {
        $html = Get-MigrationPageHtmlContent -Page $page -Path $page.RawHtmlPath -Default $null
        if ([string]::IsNullOrWhiteSpace($html) -or $html -notmatch '<table\b') {
            continue
        }

        $doc = ConvertTo-ConfluenceXmlDocument -Html $html
        if ($null -eq $doc) {
            [void]$parseWarnings.Add([PSCustomObject]@{
                PageId    = $page.id
                PageTitle = $page.title
                Problem   = "Could not parse page storage HTML as XML; no tables exported from this page."
            })
            continue
        }

        $tableNodes = @($doc.SelectNodes("//*[local-name()='table']"))
        if ($tableNodes.Count -eq 0) { continue }

        $pageAttribution = Get-ConfluenceTablePageAttribution `
            -Page $page `
            -SpaceCompanyMap $SpaceCompanyMap `
            -SingleCompanyChoice $SingleCompanyChoice `
            -AttributionOptions $AttributionOptions `
            -Companies $Companies

        $tableIndex = 0
        foreach ($tableNode in $tableNodes) {
            $tableIndex++
            $model = Convert-ConfluenceHtmlTableToModel -TableNode $tableNode -TableIndex $tableIndex
            if ($null -eq $model -or $model.ColumnCount -eq 0) {
                continue
            }

            $titleGroup = Get-ConfluenceTableTitleGroup `
                -Page $page `
                -Model $model `
                -PageAttribution $pageAttribution `
                -Companies $Companies `
                -Enabled $UseTitleGrouping

            $groupMatch = Get-ConfluenceTableGroup `
                -Groups $groups `
                -Model $model `
                -TitleGroup $titleGroup `
                -Threshold $SchemaMatchThreshold `
                -TitleCategoryThreshold $TitleCategoryMatchThreshold

            if ($null -eq $groupMatch) {
                $headers = [System.Collections.ArrayList]@()
                $headerKeys = [System.Collections.ArrayList]@()
                $group = [PSCustomObject]@{
                    Id                = $groups.Count + 1
                    GroupName         = $titleGroup.Name
                    TitleGroupKey     = $titleGroup.Key
                    TitleGroupScore   = $titleGroup.Score
                    TitleGroupSource  = $titleGroup.Source
                    Headers           = $headers
                    HeaderKeys        = $headerKeys
                    HeaderKeyToName   = @{}
                    Fingerprint       = ''
                    HeaderSource      = $model.HeaderSource
                    HeaderConfidence  = $model.HeaderConfidence
                    Rows              = [System.Collections.ArrayList]@()
                    Tables            = [System.Collections.ArrayList]@()
                }
                Add-ConfluenceTableGroupHeaders -Group $group -Headers $model.Headers
                [void]$groups.Add($group)
                $matchScore = 1.0
                $headerMatchScore = 1.0
                $titleMatched = $false
            } else {
                $group = $groupMatch.Group
                $matchScore = $groupMatch.Score
                $headerMatchScore = $groupMatch.HeaderScore
                $titleMatched = $groupMatch.TitleMatch
                Add-ConfluenceTableGroupHeaders -Group $group -Headers $model.Headers
                if ([string]::IsNullOrWhiteSpace($group.GroupName) -and -not [string]::IsNullOrWhiteSpace($titleGroup.Name)) {
                    $group.GroupName = $titleGroup.Name
                }
                if ($model.HeaderConfidence -gt $group.HeaderConfidence) {
                    $group.HeaderSource = $model.HeaderSource
                    $group.HeaderConfidence = $model.HeaderConfidence
                }
            }

            $tableRecord = [PSCustomObject]@{
                GroupId        = $group.Id
                MatchScore     = $matchScore
                HeaderMatchScore = $headerMatchScore
                TitleMatched   = $titleMatched
                TitleGroupKey  = $titleGroup.Key
                TitleGroupName = $titleGroup.Name
                CompanyId      = $pageAttribution.CompanyId
                CompanyName    = $pageAttribution.CompanyName
                SpaceKey       = $page.SpaceKey
                SpaceName      = $page.SpaceName
                PageId         = $page.id
                PageTitle      = $page.title
                PageUrl        = $page.FullUrl
                TableIndex     = $tableIndex
                HeaderRowCount = $model.HeaderRowCount
                HeaderSource   = $model.HeaderSource
                HeaderConfidence = $model.HeaderConfidence
                ColumnCount    = $model.ColumnCount
                DataRowCount   = $model.DataRows.Count
                Headers        = ($model.Headers -join ' | ')
                HeaderKeys     = ($model.HeaderKeys -join ' | ')
            }

            [void]$group.Tables.Add($tableRecord)
            [void]$inventory.Add($tableRecord)

            $rowIndex = 0
            foreach ($dataRow in $model.DataRows) {
                $rowIndex++
                $row = [ordered]@{
                    CompanyId  = $pageAttribution.CompanyId
                    CompanyName= $pageAttribution.CompanyName
                    SpaceKey   = $page.SpaceKey
                    SpaceName  = $page.SpaceName
                    PageId     = $page.id
                    PageTitle  = $page.title
                    PageUrl    = $page.FullUrl
                    TableIndex = $tableIndex
                    RowIndex   = $rowIndex
                }

                for ($columnIndex = 0; $columnIndex -lt $model.Headers.Count; $columnIndex++) {
                    $groupHeader = Resolve-ConfluenceTableGroupHeader -Group $group -Header $model.Headers[$columnIndex]
                    $row[$groupHeader] = if ($columnIndex -lt $dataRow.Count) { $dataRow[$columnIndex] } else { "" }
                }

                [void]$group.Rows.Add([PSCustomObject]$row)
            }
        }

        $html = $null
        $doc = $null
    }

    $groupSummaries = [System.Collections.ArrayList]@()
    foreach ($group in $groups) {
        $nameSeed = if (-not [string]::IsNullOrWhiteSpace($group.GroupName)) {
            $group.GroupName
        } elseif ($group.Headers.Count -gt 0) {
            ($group.Headers | Select-Object -First 4) -join '-'
        } else {
            "schema"
        }
        $safeName = Get-SafeFilename -Name $nameSeed -MaxLength 70
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "schema" }

        $csvPath = Join-Path $OutDir ("schema-{0:D3}-{1}.csv" -f $group.Id, $safeName)
        $schemaPath = Join-Path $OutDir ("schema-{0:D3}-{1}.schema.json" -f $group.Id, $safeName)
        $headers = @($metadataHeaders + @($group.Headers))

        if ($group.Rows.Count -gt 0) {
            Convert-ConfluenceTableGroupRowsForCsv -Rows $group.Rows -Headers $headers |
                Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        } else {
            Write-CsvHeaderOnly -Path $csvPath -Headers $headers
        }

        $schema = [PSCustomObject]@{
            GroupId          = $group.Id
            GroupName        = $group.GroupName
            TitleGroupKey    = $group.TitleGroupKey
            TitleGroupScore  = $group.TitleGroupScore
            TitleGroupSource = $group.TitleGroupSource
            CsvPath          = $csvPath
            Fingerprint      = $group.Fingerprint
            Headers          = @($group.Headers)
            HeaderKeys       = @($group.HeaderKeys)
            HeaderSource     = $group.HeaderSource
            HeaderConfidence = $group.HeaderConfidence
            TableCount       = $group.Tables.Count
            RowCount         = $group.Rows.Count
            Tables           = $group.Tables
        }
        $schema | ConvertTo-Json -Depth 10 | Out-File $schemaPath -Encoding UTF8

        [void]$groupSummaries.Add([PSCustomObject]@{
            GroupId          = $group.Id
            GroupName        = $group.GroupName
            TitleGroupKey    = $group.TitleGroupKey
            CsvPath          = $csvPath
            SchemaPath       = $schemaPath
            Fingerprint      = $group.Fingerprint
            TableCount       = $group.Tables.Count
            RowCount         = $group.Rows.Count
            HeaderSource     = $group.HeaderSource
            HeaderConfidence = $group.HeaderConfidence
            Headers          = (@($group.Headers) -join ' | ')
        })
    }

    $inventoryCsvPath = Join-Path $OutDir "table-inventory.csv"
    $inventoryJsonPath = Join-Path $OutDir "table-inventory.json"
    $summaryPath = Join-Path $OutDir "table-export-summary.json"
    $warningsPath = Join-Path $OutDir "table-export-warnings.json"

    if ($inventory.Count -gt 0) {
        $inventory | Export-Csv -Path $inventoryCsvPath -NoTypeInformation -Encoding UTF8
        $inventory | ConvertTo-Json -Depth 10 | Out-File $inventoryJsonPath -Encoding UTF8
    } else {
        Write-CsvHeaderOnly -Path $inventoryCsvPath -Headers @('GroupId','MatchScore','HeaderMatchScore','TitleMatched','TitleGroupKey','TitleGroupName','CompanyId','CompanyName','SpaceKey','SpaceName','PageId','PageTitle','PageUrl','TableIndex','HeaderRowCount','HeaderSource','HeaderConfidence','ColumnCount','DataRowCount','Headers','HeaderKeys')
        @() | ConvertTo-Json | Out-File $inventoryJsonPath -Encoding UTF8
    }

    if ($parseWarnings.Count -gt 0) {
        $parseWarnings | ConvertTo-Json -Depth 5 | Out-File $warningsPath -Encoding UTF8
    }

    $totalExportedRows = ($groups | ForEach-Object { $_.Rows.Count } | Measure-Object -Sum).Sum
    if ($null -eq $totalExportedRows) { $totalExportedRows = 0 }

    $summary = [PSCustomObject]@{
        Enabled              = $true
        OutputDir            = $OutDir
        GeneratedAt          = (Get-Date)
        SchemaMatchThreshold = $SchemaMatchThreshold
        UseTitleGrouping     = $UseTitleGrouping
        TitleCategoryMatchThreshold = $TitleCategoryMatchThreshold
        GroupCount           = $groups.Count
        TableCount           = $inventory.Count
        RowCount             = [int]$totalExportedRows
        InventoryCsvPath     = $inventoryCsvPath
        InventoryJsonPath    = $inventoryJsonPath
        WarningsPath         = if ($parseWarnings.Count -gt 0) { $warningsPath } else { $null }
        Groups               = $groupSummaries
    }

    $summary | ConvertTo-Json -Depth 10 | Out-File $summaryPath -Encoding UTF8
    return $summary
}
