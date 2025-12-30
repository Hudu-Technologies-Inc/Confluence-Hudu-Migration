


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

        $response = Invoke-RestMethod -Uri $uri -Headers @{
            Authorization = $AuthHeader
            Accept        = 'application/json'
        }

        $AllAttachments += $response.results
        $start += $limit
    } while ($response.size -eq $limit)

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
                }
            }
            # Check if there is a next page
            if ($response._links.next) {
                $spacesUrl = "${baseUrl}${response._links.next}"
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
        [string]$ContentType = "page"
    )

    $AllPages = @()
    $start = 0
    $limit = 25
    $pagesUrl = "$baseUrl/rest/api/content?spaceKey=$SpaceKey&type=$ContentType&expand=body.storage,version&_limit=$limit&start=$start"

    PrintAndLog -message "Retrieving Confluence content from space '$SpaceKey'..."

    do {
        PrintAndLog -message "Querying: $pagesUrl"

        $response = Invoke-RestMethod -Uri $pagesUrl -Method GET -Headers @{
            "Authorization" = $authHeader
            "Accept"        = "application/json"
        }

        if ($response.results -and $response.results.Count -gt 0) {
            $AllPages += $response.results

            foreach ($page in $response.results) {
                $page | Add-Member -NotePropertyName FullUrl -NotePropertyValue "$baseUrl$($page._links.webui)" -Force
                $page | Add-Member -NotePropertyName SpaceKey -NotePropertyValue "$SpaceKey" -Force
                $page | Add-Member -NotePropertyName SpaceName -NotePropertyValue "$SpaceName" -Force
            }
        }

        # Update URL for next page if available
        if ($response._links.next) {
            $pagesUrl = "$baseUrl$response._links.next"
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
        $isImage = $false

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
        [nullable[int]]$CompanyId
    )

    $params = @{
        Name    = $Title
        Content = $Content
    }
    if ($CompanyId -ne $null -and $CompanyId -ne -1) {
        $params.CompanyId = $CompanyId
    }
    $stub = (New-HuduArticle @params)
    $stub = $stub.article ?? $stub

    return $stub
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
            $imgUrl = "$HuduBaseUrl/public_photo/$id"
            $fileUrl = "$HuduBaseUrl/file/$id"

            if ($isImage) {
                # Wrap image in link to itself
                return "<a href='$fileUrl' target='_blank'><img src='$fileUrl' alt='$filename' /></a>"
            } elseif ($filename.ToLower() -match '\.(gif|bmp|svg|png|jpg|jpeg)$') {
                return "<a href='$fileUrl' target='_blank'><img src='$fileUrl' alt='$filename' /></a>"
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

    # Remove all <ac:*>...</ac:*>
    $Html = [regex]::Replace($Html, '<ac:[^>]+>.*?</ac:[^>]+>', '', 'Singleline')

    # Remove self-closing <ac:... />
    $Html = [regex]::Replace($Html, '<ac:[^>]+?/>', '', 'Singleline')

    # Remove <ri:...> and <ri:.../>
    $Html = [regex]::Replace($Html, '<ri:[^>]+?>', '', 'Singleline')
    $Html = [regex]::Replace($Html, '<ri:[^>]+?/>', '', 'Singleline')

    # Convert <ac:task> blocks into bullet list items
    $html = [regex]::Replace($html, '<ac:task>(.*?)<ac:task-body>(.*?)<\/ac:task-body>.*?<\/ac:task>', {
        param($match)
        $taskBody = $match.Groups[2].Value
        # Optional: strip paragraph tags
        $taskBody = $taskBody -replace '<\/?p>', ''
        return "<li>☐ $taskBody</li>"
    }, 'Singleline')

    # Wrap the resulting tasks in a <ul> block
    if ($html -match '<li>☐') {
        $html = $html -replace '(<li>☐.*?</li>)', '<ul>$1</ul>'
    }

    # Remove empty paragraphs
    $Html = [regex]::Replace($Html, '<p>\s*</p>', '', 'Singleline')
    if ($Html -match '/wikihttps://') {
        $Html = $Html -replace '/wikihttps://', 'https://'
    }
    # Remove placeholders
    $html = $html -replace '<ac:placeholder>.*?<\/ac:placeholder>', ''

    # Strip empty paragraphs
    $html = $html -replace '<li>\s*<p\s*/>\s*</li>', ''
    $html = $html -replace '<li>\s*<p><br\s*/?></p>\s*</li>', ''
    # Remove empty rows
    $html = $html -replace '<tr>(\s*<td>(<p\s*/>|<p><br\s*/?></p>)</td>\s*)+</tr>', ''
    $html = $html -replace '<tr>(\s*<td>(<p\s*\/>|<p><br\s*\/?><\/p>)<\/td>\s*)+</tr>', ''
    # Emojis to Unicode
    $html = $html -replace '<ac:emoticon[^>]*?ac:emoji-fallback="(.*?)"[^>]*>', '$1'
    # Strip atlassian structured doc bloc
    $html = $html -replace '<ac:adf-extension>.*?</ac:adf-extension>', ''
    # Remove atlassian boilerplate headers
    $html = $html -replace '<h2>.*?(Date|Participants|Goals|Discussion topics|Decisions).*?</h2>', ''

    $html = $html -replace '/wikihttps://', 'https://'
    $htmlContent = $htmlContent -replace "https://$ConfluenceDomain.atlassian.net/wikihttps://", 'https://'

    return $Html
}