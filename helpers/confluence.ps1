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
    $Page | Add-Member -NotePropertyName articlePreview   -NotePropertyValue $(Get-ArticlePreviewBlock -Title $Page.title -PageId $Page.id -Content $rawHtml -MaxLength $RunSummary.SetupInfo.PreviewLength) -Force

    $extractedLinks = @(Get-LinksFromHTML -htmlContent $rawHtml -title $Page.title -includeImages $false)
    $Page | Add-Member -NotePropertyName Links      -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName LinksCount -NotePropertyValue $extractedLinks.Count -Force
    $Page | Add-Member -NotePropertyName BaseLinks  -NotePropertyValue $(Get-ConfluenceLinks -page $Page) -Force
    $script:LinksFoundCount += @($Page.BaseLinks).Count + $extractedLinks.Count

    $Page | Add-Member -NotePropertyName stub          -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName updatedHtml   -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName CompanyId     -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName ReplacedLinks -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName ReplacedLinksCount -NotePropertyValue 0 -Force
    $Page | Add-Member -NotePropertyName HuduArticle   -NotePropertyValue $null -Force
    $Page | Add-Member -NotePropertyName CharsTrimmed  -NotePropertyValue 0 -Force

    $attachments = Get-AttachmentsForPage -baseUrl $ConfluenceBaseUrl -pageId $Page.id -authHeader "Basic $encodedCreds"
    $Page | Add-Member -NotePropertyName attachments -NotePropertyValue $attachments -Force

    write-host "page: $Page from space $($Page.SpaceKey ?? $Page.space.key)"
    $attachidx=0
    foreach ($attachment in $Page.attachments) {
        $attachidx=$attachidx+1
        $RunSummary.JobInfo.AttachmentsFound+=1
        write-host "    attachment $attachidx- $attachment"
    }

    Clear-MigrationPageHtmlMemory -Page $Page
    $rawHtml = $null
    $extractedLinks = $null
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
            $attachResponse = Invoke-RestMethod -Uri $attachmentsUrl -Headers @{
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

        $attachResponse = Invoke-RestMethod -Uri $uri -Headers @{
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
                $probe = Invoke-WebRequest -Uri $apiDownloadUrl -Headers @{ Authorization = $AuthHeader } -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
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
            $detail = Invoke-RestMethod -Uri "$BaseUrl/api/v2/attachments/$attachmentId" -Method GET -Headers @{
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
            $response = Invoke-RestMethod -Uri $spacesUrl -Headers @{ Authorization = $authHeader } -Method Get
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
                $spacesUrl = "$baseUrl$($response._links.next)"
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

        $response = Invoke-RestMethod -Uri $pagesUrl -Method GET -Headers @{
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
                    $pageDetail = Invoke-RestMethod -Uri "$baseUrl/api/v2/pages/$($page.id)?body-format=storage" -Method GET -Headers @{
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

        Invoke-WebRequest -Uri $downloadUrl -Headers @{ Authorization = $authHeader } -OutFile $localPath -MaximumRedirection 10 -ErrorAction Stop
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
                $resp = Invoke-RestMethod `
                    -Uri     "$BaseUrl/api/v2/folders/$currentId" `
                    -Headers @{ Authorization = $AuthHeader; Accept = "application/json" }
            } else {
                $resp = Invoke-RestMethod `
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

    $headerRowCount = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($rows[$i].HasHeader) {
            $headerRowCount++
        } else {
            break
        }
    }

    if ($headerRowCount -eq 0 -and $rows.Count -gt 1) {
        $headerRowCount = 1
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
            $rawHeaders += "Column$($column + 1)"
        } else {
            $rawHeaders += ($parts -join ' - ')
        }
    }

    $dataRows = [System.Collections.ArrayList]@()
    for ($rowIndex = $headerRowCount; $rowIndex -lt $rows.Count; $rowIndex++) {
        [void]$dataRows.Add($rows[$rowIndex].Cells)
    }

    $metadataHeaders = @('CompanyId','CompanyName','SpaceKey','SpaceName','PageId','PageTitle','PageUrl','TableIndex','RowIndex')
    $headers = Get-UniqueConfluenceTableHeaders -Headers $rawHeaders -ReservedHeaders $metadataHeaders
    $headerKeys = @($headers | ForEach-Object { Get-ConfluenceTableHeaderKey -Header $_ })

    return [PSCustomObject]@{
        TableIndex     = $TableIndex
        Headers        = @($headers)
        HeaderKeys     = @($headerKeys)
        HeaderRowCount = $headerRowCount
        DataRows       = $dataRows
        ColumnCount    = $maxColumnCount
        RowCount       = $rows.Count
    }
}

function Measure-ConfluenceTableHeaderSimilarity {
    param(
        [string[]]$Left,
        [string[]]$Right
    )

    if ($Left.Count -eq 0 -or $Right.Count -eq 0) { return 0.0 }
    if ($Left.Count -ne $Right.Count) { return 0.0 }

    $positionMatches = 0
    for ($i = 0; $i -lt $Left.Count; $i++) {
        if ($Left[$i] -eq $Right[$i]) {
            $positionMatches++
        }
    }
    $positionScore = $positionMatches / $Left.Count

    $leftTokens = @($Left | ForEach-Object { $_ -split '_' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $rightTokens = @($Right | ForEach-Object { $_ -split '_' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $union = @($leftTokens + $rightTokens | Sort-Object -Unique)
    if ($union.Count -eq 0) { return $positionScore }

    $intersection = @($leftTokens | Where-Object { $rightTokens -contains $_ })
    $tokenScore = $intersection.Count / $union.Count

    return [Math]::Round((0.7 * $positionScore) + (0.3 * $tokenScore), 4)
}

function Get-ConfluenceTableGroup {
    param(
        [System.Collections.ArrayList]$Groups,
        [string[]]$HeaderKeys,
        [double]$Threshold
    )

    $bestGroup = $null
    $bestScore = 0.0
    foreach ($group in $Groups) {
        $score = Measure-ConfluenceTableHeaderSimilarity -Left $group.HeaderKeys -Right $HeaderKeys
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestGroup = $group
        }
    }

    if ($null -ne $bestGroup -and $bestScore -ge $Threshold) {
        return [PSCustomObject]@{
            Group = $bestGroup
            Score = $bestScore
        }
    }

    return $null
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
        [double]$SchemaMatchThreshold = 0.86
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

            $groupMatch = Get-ConfluenceTableGroup -Groups $groups -HeaderKeys $model.HeaderKeys -Threshold $SchemaMatchThreshold
            if ($null -eq $groupMatch) {
                $group = [PSCustomObject]@{
                    Id          = $groups.Count + 1
                    Headers     = $model.Headers
                    HeaderKeys  = $model.HeaderKeys
                    Fingerprint = ($model.HeaderKeys -join '|')
                    Rows        = [System.Collections.ArrayList]@()
                    Tables      = [System.Collections.ArrayList]@()
                }
                [void]$groups.Add($group)
                $matchScore = 1.0
            } else {
                $group = $groupMatch.Group
                $matchScore = $groupMatch.Score
            }

            $tableRecord = [PSCustomObject]@{
                GroupId        = $group.Id
                MatchScore     = $matchScore
                CompanyId      = $pageAttribution.CompanyId
                CompanyName    = $pageAttribution.CompanyName
                SpaceKey       = $page.SpaceKey
                SpaceName      = $page.SpaceName
                PageId         = $page.id
                PageTitle      = $page.title
                PageUrl        = $page.FullUrl
                TableIndex     = $tableIndex
                HeaderRowCount = $model.HeaderRowCount
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

                for ($columnIndex = 0; $columnIndex -lt $group.Headers.Count; $columnIndex++) {
                    $row[$group.Headers[$columnIndex]] = if ($columnIndex -lt $dataRow.Count) { $dataRow[$columnIndex] } else { "" }
                }

                [void]$group.Rows.Add([PSCustomObject]$row)
            }
        }

        $html = $null
        $doc = $null
    }

    $groupSummaries = [System.Collections.ArrayList]@()
    foreach ($group in $groups) {
        $nameSeed = if ($group.Headers.Count -gt 0) { ($group.Headers | Select-Object -First 4) -join '-' } else { "schema" }
        $safeName = Get-SafeFilename -Name $nameSeed -MaxLength 70
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "schema" }

        $csvPath = Join-Path $OutDir ("schema-{0:D3}-{1}.csv" -f $group.Id, $safeName)
        $schemaPath = Join-Path $OutDir ("schema-{0:D3}-{1}.schema.json" -f $group.Id, $safeName)
        $headers = @($metadataHeaders + $group.Headers)

        if ($group.Rows.Count -gt 0) {
            $group.Rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        } else {
            Write-CsvHeaderOnly -Path $csvPath -Headers $headers
        }

        $schema = [PSCustomObject]@{
            GroupId     = $group.Id
            CsvPath     = $csvPath
            Fingerprint = $group.Fingerprint
            Headers     = $group.Headers
            HeaderKeys  = $group.HeaderKeys
            TableCount  = $group.Tables.Count
            RowCount    = $group.Rows.Count
            Tables      = $group.Tables
        }
        $schema | ConvertTo-Json -Depth 10 | Out-File $schemaPath -Encoding UTF8

        [void]$groupSummaries.Add([PSCustomObject]@{
            GroupId     = $group.Id
            CsvPath     = $csvPath
            SchemaPath  = $schemaPath
            Fingerprint = $group.Fingerprint
            TableCount  = $group.Tables.Count
            RowCount    = $group.Rows.Count
            Headers     = ($group.Headers -join ' | ')
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
        Write-CsvHeaderOnly -Path $inventoryCsvPath -Headers @('GroupId','MatchScore','CompanyId','CompanyName','SpaceKey','SpaceName','PageId','PageTitle','PageUrl','TableIndex','HeaderRowCount','ColumnCount','DataRowCount','Headers','HeaderKeys')
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
