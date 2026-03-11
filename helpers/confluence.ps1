# Define some useful Functions 

function Get-AttachmentsForPage {
    param (
        [string]$PageId,
        [string]$BaseUrl,
        [string]$AuthHeader
    )

    $AllAttachments = @()
    $limit = 50
    $start = 0

    do {
        $uri = "$BaseUrl/rest/api/content/$PageId/child/attachment" +
               "?limit=$limit&start=$start&expand=version,metadata"

        $attachResponse = Invoke-RestMethod -Uri $uri -Headers @{
            Authorization = $AuthHeader
            Accept        = 'application/json'
        }

        $AllAttachments += $attachResponse.results
        $start += $limit
    } while ($attachResponse.size -eq $limit)

    return $AllAttachments
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
                    OptionMessage = $_.key
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
        [string]$ContentType = "page"
    )

    $AllPages = @()
    $limit = 25

    # Use v2 API if SpaceId provided, fall back to v1 if not
    if ($SpaceId -ne "") {
        $pagesUrl = "$baseUrl/api/v2/spaces/$SpaceId/pages?limit=$limit&body-format=storage"
    } else {
        $pagesUrl = "$baseUrl/rest/api/content?spaceKey=$SpaceKey&type=$ContentType&expand=body.storage,version&limit=$limit"
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
                $AllPages += $page
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
        [string]$title
    )

    $filename = Get-SafeFilename -Name $attachment.title
    $downloadUrl = "$ConfluenceBaseUrl$($attachment._links.download)"
    $localPath = Join-Path -Path $TmpOutputDir -ChildPath $filename

    try {
        Invoke-WebRequest -Uri $downloadUrl -Headers @{ Authorization = "Basic $encodedCreds" } -OutFile $localPath -ErrorAction Stop
        Write-Host "Saved attachment: $filename"

        $ext = [IO.Path]::GetExtension($filename).ToLower()
        $imageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg')
        $isImage = $imageExtensions -contains $ext

        $record = [PSCustomObject]@{
            FileName         = $filename
            Extension        = $ext
            IsImage          = $isImage
            PageId           = $pageId
            PageTitle        = $title
            SourceUrl        = $downloadUrl
            LocalPath        = $localPath
            UploadResult     = $null
            HuduArticleId    = $null
            HuduUploadType   = $null
            SuccessDownload  = $true
        }

        return $record
    } catch {
                Write-ErrorObjectsToFile -Name "$($record.FileName)" -ErrorObject @{
                    Error       = $_
                    Record      = $record 
                    Attachment  = $att
                    Message     ="Error During Spaces Request"
                    response    = $response
                    spacesUrl  = $spacesUrl
                }
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
        [int]$CompanyId,
        [string]$AuthHeader,
        [string]$BaseUrl
    )

    if (-not $ParentId) { return $null }

    # Space homepage as parent = top-level page, no folder needed
    if ($ParentId -eq $script:SpaceHomepageId) { return $null }

    # Already resolved this parent
    if ($script:FolderCache.ContainsKey($ParentId)) {
        return $script:FolderCache[$ParentId]
    }

    # Build full path by walking up through pages and/or folders
    $path = Get-ConfluenceFolderPath -StartId $ParentId -StartType $ParentType -AuthHeader $AuthHeader -BaseUrl $BaseUrl

    if (-not $path -or $path.Count -eq 0) {
        PrintAndLog "  ⚠️  Could not resolve folder path for $ParentId — skipping" -Color Yellow
        return $null
    }

    try {
        $folder   = Initialize-HuduFolder -FolderPath $path -CompanyId $CompanyId
        $folderId = $folder.id
        $script:FolderCache[$ParentId] = $folderId
        PrintAndLog "  📁 '$($path -join " → ")' → Hudu folder ID $folderId" -Color Cyan
        return $folderId
    } catch {
        PrintAndLog "  ⚠️  Initialize-HuduFolder failed for '$($path -join " / ")' — $($_)" -Color Yellow
        return $null
    }
}


function Replace-ConfluenceAttachmentTags {
    param(
        [string]$Html,
        [hashtable]$ImageMap,
        [string]$HuduBaseUrl
    )

 # Handle <ac:image><ri:attachment /></ac:image>
    $imagePattern = '<ac:image[^>]*?>\s*<ri:attachment\s+ri:filename="([^"]+)"[^>]*?\/>\s*<\/ac:image>'
    $Html = [regex]::Replace($Html, $imagePattern, {
        param($match)
        $filename = $match.Groups[1].Value.ToLowerInvariant()
        if ($ImageMap.ContainsKey($filename)) {
            $mapEntry = $ImageMap[$filename]
            $id = $mapEntry.Id
            $isImage = $mapEntry.Type -eq 'image'

            $publicPhotoUrl = "$HuduBaseUrl/public_photo/$id"
            $fileUrl = "$HuduBaseUrl/file/$id"

            if ($isImage) {
                return "<a href='$publicPhotoUrl' target='_blank'><img src='$publicPhotoUrl' alt='$filename' /></a>"
            } elseif ($filename.ToLower() -match '\.(gif|bmp|svg|png|jpg|jpeg)$') {
                return "<a href='$publicPhotoUrl' target='_blank'><img src='$publicPhotoUrl' alt='$filename' /></a>"
            } else {
                return "<a href='$fileUrl'>$filename</a>"
            }
        } else {
            Write-Warning "Image '$filename' not found in ImageMap"
            return "<!-- Missing image: $filename -->"
        }
    })

    # Handle <ac:link><ri:attachment /></ac:link>
    $linkPattern = '<ac:link[^>]*?>\s*<ri:attachment\s+ri:filename="([^"]+)"[^>]*?\/>\s*<\/ac:link>'
    $Html = [regex]::Replace($Html, $linkPattern, {
        param($match)
        $filename = $match.Groups[1].Value.ToLowerInvariant()
        if ($ImageMap.ContainsKey($filename)) {
            $mapEntry = $ImageMap[$filename]
            $id = $mapEntry.Id
            $path = ($mapEntry.Type -eq 'image') ? 'public_photo' : 'file'
            return "<a href='$HuduBaseUrl/$path/$id'>$filename</a>"
        } else {
            return "<!-- Missing attachment: $filename -->"
        }
    })
    return $Html
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
    # Produces: <ul><li>&#x2610; task text</li>...</ul>

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

            $checkbox = if ($status -eq 'complete') { '&#x2611;' } else { '&#x2610;' }
            return "<li>$checkbox $body</li>"
        }, 'Singleline')

        # Only emit a <ul> if there are actual list items
        $inner = $inner.Trim()
        if ($inner) { return "<ul>`n$inner`n</ul>" } else { return '' }
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