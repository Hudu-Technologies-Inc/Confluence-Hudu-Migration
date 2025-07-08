# Copyright (c) 2025 Hudu Technologies, Inc.
# All rights reserved.
#
# # Redistribution and use of this software in source and binary forms, with or without modification, are permitted under the following conditions:
#    * Redistributions of source code must retain the above copyright notice, this list of conditions, and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and the following disclaimer in the 
#      documentation and/or other materials provided with the distribution
#    * Neither the name of Hudu Technologies nor the names of its contributors may be used to endorse or promote products derived from this software 
#      without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS," WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, 
# BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL HUDU TECHNOLOGIES 
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT 
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, 
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
#
# Authors: Mason Stetler



$project_workdir=$PSScriptRoot
. ".\helpers\init.ps1"
. ".\helpers\confluence.ps1"
. ".\helpers\general.ps1"

$TrackedAttachments = [System.Collections.ArrayList]@()
$TrackedAssets = [System.Collections.ArrayList]@()

$AllReplacedLinks =  [System.Collections.ArrayList]@()
$AllFoundLinks =[System.Collections.ArrayList]@()
$AllNewLinks = [System.Collections.ArrayList]@()


$ImageMap = @{}
$ConfluenceToHuduUrlMap = @{}
$Article_Relinking=@{}

# Step 1.1- Get spaces and select which or all spaces to get pages from
PrintAndLog -message  "Getting All Spaces and configuring Source options (Confluence-Side)" -Color Blue
$AllSpaces=GetAllSpaces -baseUrl $ConfluenceBaseUrl -authHeader "Basic $encodedCreds"
if ($AllSpaces.Count -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Confluence Spaces! Double-check your credentials and try again." -Color Red
}

$SourcePages = @()
$SourceMigrationChoice=$(Select-Object-From-List -Objects @(
[PSCustomObject]@{
    OptionMessage= "From a Single/Specific Confluence Space"
    Identifier = 0
}, 
[PSCustomObject]@{
    OptionMessage= "From All ($($AllSpaces.count)) Confluence Space(s)"
    Identifier = 1
}) -message "Configure Source (Confluence-Side) Options from Confluence- Migrate pages from which Space(s)?" -allowNull $false)

# Step 1.2- Obtain and record pages/attachments for space(s)
if ([int]$SourceMigrationChoice.Identifier -eq 0) {
    $SingleChosenSpace=$(Select-Object-From-List -Objects $AllSpaces - Message "From which single space would you like to migrate pages from?")  
    $SingleChosenSpace.OptionMessage="$($SingleChosenSpace.OptionMessage) (space: $($SingleChosenSpace.name)/$($SingleChosenSpace.key))"
    $SourcePages=$(GetAllPages -SpaceKey $SingleChosenSpace.key -SpaceName $SingleChosenSpace.name -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl)
} else {
    foreach ($space in $AllSpaces) {
        PrintAndLog -message "Obtaining Pages from space: $($space.name)/$($space.key)" -Color Blue
        $addedPages = $(GetAllPages -SpaceKey $space.key -SpaceName $space.name -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl)
        $SourcePages+=$addedPages
    }
}


foreach ($page in $SourcePages) {
    $page | Add-Member -NotePropertyName FetchedBy     -NotePropertyValue $localhost_name -Force
    $page | Add-Member -NotePropertyName OriginalTitle -NotePropertyValue $page.title -Force
    $page | Add-Member -NotePropertyName title         -NotePropertyValue $(Get-SafeTitle -name $page.title) -Force
    $page | Add-Member -NotePropertyName htmlContent   -NotePropertyValue $page.body.storage.value -Force
    $page | Add-Member -NotePropertyName rawContent    -NotePropertyValue $page.body.storage.value -Force
    $page | Add-Member -NotePropertyName articlePreview -NotePropertyValue $(Get-ArticlePreviewBlock -Title $page.title -PageId $page.id -Content $page.body.storage.value) -Force
    $page | Add-Member -NotePropertyName stub          -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName updatedHtml   -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName CompanyId     -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName ReplacedLinks -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName RegexLinks    -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName HuduArticle   -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName CharsTrimmed  -NotePropertyValue 0 -Force
    $page | Add-Member -NotePropertyName Links         -NotePropertyValue $(Get-LinksFromHTML -htmlContent $page.body.storage.value -title $page.title -includeImages $false) -Force
    $page | Add-Member -NotePropertyName BaseLinks     -NotePropertyValue $(Get-ConfluenceLinks -page $page) -Force
    $attachments = Get-AttachmentsForPage -baseUrl $ConfluenceBaseUrl -pageId $page.id -authHeader "Basic $encodedCreds"
    $page | Add-Member -NotePropertyName attachments -NotePropertyValue $attachments -Force


    foreach ($link in $page.BaseLinks) {
        $AllFoundLinks.add([PSCustomObject]@{
            Type       = 'BaseLink'
            PageId     = $page.id
            PageTitle  = $page.title
            Link       = $link
        })
    }

    foreach ($link in $page.Links) {
        $AllFoundLinks.add([PSCustomObject]@{
            Type       = 'ExtractedHtmlLink'
            PageId     = $page.id
            PageTitle  = $page.title
            Link       = $link.href
        })
    }

    write-host "page: $page from space $($page.space.key)"
    $attachidx=0
    foreach ($attachment in $page.attachments) {
        $attachidx=$attachidx+1
        write-host "    attachment $attachidx- $attachment"
    }
    

}
if ($SourcePages.Count -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Source Articles/Pages in Confluence! Double-check your credentials and try again." -Color Red
    exit
} else {
    $SourceMigrationChoice.OptionMessage="Migrate $($SourcePages.count) Articles/Pages $($SourceMigrationChoice.OptionMessage)"
    PrintAndLog -message "Elected to $SourceMigrationChoice" -Color Yellow
}
if ($(Select-Object-From-List -objects @("yes","no") -message "does this look correct?") -eq "no") {write-error "please re-invoke to start over."; exit 1}


# STEP 2: Present Options for Hudu / Destination
PrintAndLog -message  "Getting All Companies and configuring destination options (Hudu-Side)" -Color Blue
$all_companies = Get-HuduCompanies
if ($all_companies.Count -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Companies set up in Hudu... If you intend to attribute certain articles to certain companies, be sure to add your companies first!" -Color Red
}
$Attribution_Options=@()
$DestMigrationChoice=$(Select-Object-From-List -Objects @(
    [PSCustomObject]@{
        OptionMessage= "To a Single Specific Company in Hudu"
        Identifier = 0
    },
    [PSCustomObject]@{
        OptionMessage= "To Global Knowledge Base in Hudu (generalized / non-company-specific)"
        Identifier = 1
    }, 
    [PSCustomObject]@{
        OptionMessage= "To Multiple Companies in Hudu - Let Me Choose for Each article ($($all_companies.count) available destination company choices)"
        Identifier = 2
    }
) -message "Configure Destination (Hudu-Side) Options- $($SourceMigrationChoice.OptionMessage) to where in Hudu?" -allowNull $false)

if ([int]$DestMigrationChoice.Identifier -eq 0) {
    $SingleCompanyChoice=$(Select-Object-From-List -Objects $all_companies -message "Which company to $($SourcePages.OptionMessage) ($($SourcePages.count)) articles to?")
    $Attribution_Options=[PSCustomObject]@{
        CompanyId            = $SingleCompanyChoice.Id
        CompanyName          = $SingleCompanyChoice.Name
        OptionMessage        = "Company Name: $($SingleCompanyChoice.Name), Company ID: $($SingleCompanyChoice.Id)"
        IsGlobalKB           = $false
    }
    $DestMigrationChoice.OptionMessage="$($DestMigrationChoice.OptionMessage) (Company Name: $($SingleCompanyChoice.Name), Company ID: $($SingleCompanyChoice.Id))"
} elseif ([int]$DestMigrationChoice.Identifier -eq 1) {
    $Attribution_Options+=[PSCustomObject]@{
        CompanyId            = 0
        CompanyName          = "Global KB"
        OptionMessage        = "No Company Attribution (Upload As Global KnowledgeBase Article)"
        IsGlobalKB           = $true
    }    
} else {
        $Attribution_Options = @()
    foreach ($company in $all_companies) {
        $Attribution_Options+=[PSCustomObject]@{
            CompanyId            = $company.Id
            CompanyName          = $company.Name
            OptionMessage        = "Company Name: $($company.Name), Company ID: $($company.Id)"
            IsGlobalKB           = $false
        }
    }
    $Attribution_Options+=[PSCustomObject]@{
        CompanyId            = 0
        CompanyName          = "Global KB"
        OptionMessage        = "No Company Attribution (Upload As Global KnowledgeBase Article)"
        IsGlobalKB           = $true
    }
    $Attribution_Options+=[PSCustomObject]@{
        CompanyId            = -1
        CompanyName          = "None (SKIP FOR NOW)"
        OptionMessage        = "Skipped"
        IsGlobalKB           = $false
    }
}

PrintAndLog -message "You've elected for this migration path: $($SourceMigrationChoice.OptionMessage) $($DestMigrationChoice.OptionMessage)." -Color Yellow
Read-Host "Press enter now or CTL+C / Close window to exit now!"

write-host "Part 1: Stubbing articles" -ForegroundColor Magenta
$PageIDX=0
foreach ($page in $SourcePages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count
    #Generate articl preview
            
    if ([int]$DestMigrationChoice.Identifier -eq 0) {
        $page.CompanyId = $SingleCompanyChoice.id
    } elseif ([int]$DestMigrationChoice.Identifier -eq 1) {
        $page.CompanyId = $null  # global KB
    } else {
        $page.CompanyId = $($Company_attribution ?? (Select-Object-From-List -message "Migrating Article: $($page.articlePreview ?? "no preview")... Which company to migrate into?" -objects $Attribution_Options)).CompanyId
    }

    #stub article
    if ($null -eq $page.CompanyId -or $page.CompanyId -lt 1) {
        printandlog -message "Stubbing global KB article"
        $page.stub = $(New-HuduStubArticle -Title $($page.title) -Content "stubbed preview - $($page.articlePreview)")
    } else {
        printandlog -message "Stubbing KB article for Hudu company ID: $($page.CompanyId)"
        $page.stub =$( New-HuduStubArticle -Title $($page.title) -Content "stubbed preview - $($page.articlePreview)" -CompanyId $($page.CompanyId))
    }
    PrintAndLog -message "Article $($page.title) Stubbed with id $($($page.stub).id); $($($page.stub) | ConvertTo-Json -Depth 3)" -Color Green

    if ($null -eq $page.stub) {
        Write-ErrorObjectsToFile -name "Stub-$($page.title)" -ErrorObject @{
            Error="Error Stubbing Article: $($page.title)"
            Descriptor=$descriptor
            PageId=$($page.id)
        }
        continue
    }
    $AllNewLinks.Add([PSCustomObject]@{
        PageId        = $page.id
        PageTitle     = $page.title
        HuduUrl       = $page.stub.url
        ArticleId     = $page.stub.id
    })
    Write-Progress -Activity "Stubbing $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

}



write-host "Part 2: Process Attachments" -ForegroundColor Magenta
$PageIDX=0
foreach ($page in $SourcePages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count


    # get attachment / embedded images
    PrintAndLog -message "Starting dl/ul of $($page.attachments.count) attachments found for $($page.title)" -Color Green

    # download attachments + upload attachments and atytach to stub
    $AttachIDX=0
    foreach ($att in $page.attachments) {
        $AttachIDX+=1
        $UploadedAsDoc=$false
        $record = Invoke-ConfluenceAttachDownload -attachment $att -page $page -pageId $page.id -title $page.title -ConfluenceBaseUrl $ConfluenceBaseUrl -TmpOutputDir $TmpOutputDir -encodedCreds $encodedCreds

        [void]$TrackedAttachments.Add($record ?? [PSCustomObject]@{
            FileName         = $(Get-SafeFilename -Name $($record.title ?? "Title not present for page id $($page.id ?? 0)"))
            Extension        = [IO.Path]::GetExtension($record.title).ToLower()
            IsImage          = $record.title.ToLower() -match '\.(jpg|jpeg|png)$'
            PageId           = $($page.id)
            PageTitle        = $($page.title)
            SourceUrl        = "$ConfluenceBaseUrl$($record._links.download)"
            LocalPath        = 
            UploadResult     = $null
            HuduArticleId    = $null
            HuduUploadType   = $null
            SuccessDownload  = $false
            AttachmentSize   = (Get-Item "$TmpOutputDir\$($record.title)").Length
            AttachmentTooLarge=$((Get-Item "$TmpOutputDir\$($record.title)").Length -gt 100MB)
        })

        printandlog -message "Downloaded Attachment $AttachIDX of $($page.attachments.Count) for $($page.title) - $($attachment.filename ?? "File")" -Color Yellow
        if ($record -and $record.SuccessDownload -and $record.LocalPath) {
            if ($true -eq $record.AttachmentTooLarge) {
                Write-ErrorObjectsToFile -ErrorObject @{
                    Attachment = $record
                    Problem    = "$($record.Filename) is TOO LARGE for Hudu. Manual Action is required. Skipping."
                    page       = $page
                } -name "Attach-Error-$($record.Filename)"
                continue
            }

            try {
                PrintAndLog -Message "Uploading image: $($record.FileName) => record_id=$($($page.stub).id) record_type=Article" -Color Green
                $upload=$null
                if ($record.IsImage) {
                    $upload = $((New-HuduPublicPhoto -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article').public_photo)
                } else {
                    $upload = New-HuduUpload -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article'
                }
                $AllNewLinks.Add([PSCustomObject]@{
                    PageId        = $page.id
                    PageTitle     = $page.title
                    LocalFile     = $record.FileName
                    HuduUrl       = $upload.url
                    HuduUploadId  = $upload.id
                })
                $normalizedFileName = $record.FileName.ToLowerInvariant()
                $ImageMap[$normalizedFileName] = @{
                    Id   = $upload.id
                    Type = if ($record.IsImage) { 'image' } else { 'upload' }
                }

                $record.UploadResult    = $upload
                $record.HuduUploadType  = $ImageMap[$normalizedFileName].Type
                $record.HuduArticleId   = $($page.stub).id

            } catch {
                Write-ErrorObjectsToFile -Name "$($record.FileName)" -ErrorObject @{
                    Error       =$_
                    Record      =$record
                    Attachment  =$att
                    Message     ="Error During Attachment Upload"
                    Article     =$($page.stub)
                    Page        =$page
                }
            }
        }
    }
    Write-Progress -Activity "Processing attachments for $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

}
$ImageMap | ConvertTo-Json -Depth 5 | Out-File "$TmpOutputDir\ImageMap-$($page.title).json"


write-host "Part 3: Replacing Embed/Attachment Links and Confluence Bloat" -ForegroundColor Magenta
$PageIDX=0
foreach ($page in $SourcePages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count

    # Find and replace image URLs with base64-encoded versions 

    $page.rawContent=$page.htmlContent ?? "No Content Found in Confluence"
    $page.updatedHtml=$page.htmlContent ?? "No Content Found in Confluence"
    Save-HtmlSnapshot -PageId $page.id -Title $page.title -Content $page.rawContent -Suffix "before" -OutDir $TmpOutputDir

    PrintAndLog -Message "Stripping bloat for $($page.title)" -Color Yellow
    # $page.updatedHtml = Strip-ConfluenceBloat -Html $page.rawContent ?? "no content"
    $page.updatedHtml = Replace-ConfluenceAttachmentTags -Html $page.updatedHtml -ImageMap $ImageMap -HuduBaseUrl $HuduBaseUrl
    $page.charsTrimmed =  $page.rawContent.length - $($page.updatedHtml).length
    PrintAndLog -Message "Removed $($page.charsTrimmed) characters of bloat from $($page.title)" -Color Green
    Save-HtmlSnapshot -PageId $page.id -Title $page.title -Content $($page.updatedHtml) -Suffix "after" -OutDir $TmpOutputDir


    PrintAndLog "Populating Article: $($page.articlePreview) to $($($page.CompanyId) ?? 'Global KB') with relinked contents" -Color Green

    if ($($page.updatedHtml).Length -gt $HUDU_MAX_DOCSIZE) {
        PrintAndLog "Content Length Warning: Content, even after stripping bloat is too large. Safe-Maximum is $HUDU_MAX_DOCSIZE Characters, and this is $($($page.updatedHtml).length) chars long! Adding as attached document!"
        $htmlPath = Join-Path $TmpOutputDir -ChildPath ("LargeDoc_{0}.html" -f (Get-SafeFilename ([IO.Path]::GetFileNameWithoutExtension($($page.title)))))
        Set-Content -Path $htmlPath -Value $($page.updatedHtml) -Encoding UTF8

        $htmlAttachment = New-HuduUpload -FilePath $htmlPath -record_id $($page.stub).id -record_type 'Article'
        # $AllNewLinks+=$htmlAttachment.url

        $FinalContents = "Full content too long. See attached file: <a href='$HuduBaseUrl/file/$($htmlAttachment.id)'>$($page.title).html</a>"
    } else {
        $FinalContents=$($($page.updatedHtml) ?? "unknown contents")
    }
    try {
        if ($null -ne $($page.CompanyId) -and $($page.CompanyId) -ne -1) {
            $page.HuduArticle = $(Set-HuduArticle -ArticleId $($page.stub).id -Content $FinalContents -name $($($page.title) ?? "Unknown Title") -CompanyId $($page.CompanyId)).Article
        } else {
            $page.HuduArticle = $(Set-HuduArticle -ArticleId $($page.stub).id -Content $FinalContents -name $($($page.title) ?? "Unknown Title")).Article
        }
        
    } catch {
        Write-ErrorObjectsToFile -name "Pop-$($page.title)" -ErrorObject @{
            Message="Error Populating Article: $($page.title)"
            Error=$_
            HuduArticle=$(Get-HuduArticles -id $($page.stub).id).Article
            Page=$page
        }
        continue
    }

    if ($true -eq $UploadedAsDoc) {
        continue
    }

    # Track relinking info. we'll want to relink articles/pages after all are created.
    $Article_Relinking[$($page.stub).id]=[PSCustomObject]@{
        HuduArticle    = $(Get-HuduArticles -id $($page.stub).id).article
        Page           = $page
        content        = $FinalContents ?? $($page.updatedHtml)
        Links          = $page.links
    }
    Write-Progress -Activity "Processing content for $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

    $page | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\wip-page-$($page.title).json"
}

$Article_Relinking.GetEnumerator() |
    ForEach-Object { [ordered]@{ "$($_.Key)" = $_.Value } } |
    ConvertTo-Json -Depth 10 |
    Out-File "$TmpOutputDir\Article_Relinking.json"
$ConfluenceToHuduUrlMap | ConvertTo-Json -Depth 5 | Out-File "$TmpOutputDir\UrlMap.json"



PrintAndLog -Message "Part 4: Relinking Imported Articles" -Color Yellow
$PageIDX=0
foreach ($id in $Article_Relinking.Keys) {
    $entry = $Article_Relinking[$id]
    $relPage = $entry.Page
    $htmlContent = $relPage.updatedHtml ?? $entry.HuduArticle.content
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count

    $pattern = 'https://' + [regex]::Escape($ConfluenceDomain) + '\.atlassian\.net[^"''\s<>]*'
    $htmlContent = $htmlContent -replace $pattern, ''
    $htmlContent = [regex]::Replace($htmlContent, 'content/(\d+)', {
        param($match)
        $id = $match.Groups[1].Value
        $page = $Article_Relinking.Values | Where-Object { $_.Page.id -eq $id }
        if ($page) {
            PrintAndLog -Message "Replacing REST content/$id with → $($page.HuduArticle.url)" -Color Cyan
            return $page.HuduArticle.url
        }
        return $match.Value
    })
    $htmlContent = [regex]::Replace($htmlContent, 'pages/(\d+)', {
        param($match)
        $id = $match.Groups[1].Value
        $page = $Article_Relinking.Values | Where-Object { $_.Page.id -eq $id }
        if ($page) {
            PrintAndLog -Message "Replacing /pages/$id with → $($page.HuduArticle.url)" -Color Cyan
            return $page.HuduArticle.url
        }
        return $match.Value
    })

    # 1. Replace direct match or /wiki<url>
    foreach ($confluenceUrl in $ConfluenceToHuduUrlMap.Keys) {
        $huduUrl = $ConfluenceToHuduUrlMap[$confluenceUrl]
        $escaped = [regex]::Escape($confluenceUrl)

        if ($htmlContent -match $escaped) {
            $htmlContent = $htmlContent -replace $escaped, $huduUrl
            PrintAndLog -Message "Matched and replaced escaped url: $confluenceUrl → $huduUrl" -Color Green
        }
        $malformed = $confluenceUrl -replace '^https?://[^/]+', ''  # remove domain only
        $escapedMalformed = [regex]::Escape($malformed)

        if ($htmlContent -match $escapedMalformed) {
            $htmlContent = $htmlContent -replace $escapedMalformed, $huduUrl
            PrintAndLog -Message "Matched and replaced /wiki url: $malformed → $huduUrl" -Color Green
        }
    }
 
    # 3. Regex to match href="/12345" or href="/12345?someparam"
    $pattern = 'https://' + [regex]::Escape($ConfluenceDomain) + '\.atlassian\.net/wiki(?:/[^"''\s<>]*)?'
    $htmlContent = [regex]::Replace($htmlContent, $pattern, {
        param($match)
        $matchedId = $match.Groups[1].Value
        $matchedPage = $Article_Relinking.Values | Where-Object { $_.Page.id -eq $matchedId }

        if ($matchedPage) {
            $replacement = $matchedPage.HuduArticle.url
            PrintAndLog -Message "Replaced object refrence (PageId) url $matchedId → $replacement" -Color Cyan
            return $replacement
        }
        return $match.Value
    }, 'IgnoreCase')

    # 4. Replace legacy Confluence view links like ?pageId=98429
    $pageIdPattern = [regex]::Escape("pageId=$($entry.Page.id)")
    if ($htmlContent -match $pageIdPattern) {
        $htmlContent = $htmlContent -replace $pageIdPattern, $huduUrl
        PrintAndLog -Message "Replaced legacy pageId=$($entry.Page.id)" -Color Green
    }

    # 5. Replace direct "page/<id>" references
    $pagePathPattern = [regex]::Escape("page/$($entry.Page.id)")
    if ($htmlContent -match $pagePathPattern) {
        $htmlContent = $htmlContent -replace [regex]::Escape($pagePathPattern), $entry.HuduArticle.url
        PrintAndLog -Message "Replaced page/$($entry.Page.id) → $($entry.HuduArticle.url)" -Color Green
    }

    foreach ($sourcePage in $SourcePages) {
        $htmlContent = $htmlContent -replace $sourcePage.title, "<a href='$($sourcePage.HuduArticle.url ?? $sourcePage.stub.url)'>$($sourcePage.title)</a>"
        foreach ($baselink in $sourcePage.BaseLinks) {
            $htmlContent = $htmlContent -replace $baselink, $($sourcePage.HuduArticle.url ?? $sourcePage.stub.url)
        }
    }
    $relPage.ReplacedLinks = $(Get-LinksFromHTML -htmlContent $htmlContent -title $relPage.title -includeImages $false)
    $response = Set-HuduArticle -ArticleId $id -Content $htmlContent -Name $relPage.title
    $relPage.HuduArticle = $response.Article
    PrintAndLog -Message "Updated article [$($relPage.title)] with length: $($htmlContent.Length)" -Color Cyan

    # Optional: also update the Article_Relinking entry with new content
    $Article_Relinking[$id].content = $relPage.HuduArticle.content

    $relPage | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\completed-page-$($relPage.title).json"
    $AllReplacedLinks.Add($relPage.ReplacedLinks)

    $completionPercentage = Get-PercentDone -Current ($PageIDX++) -Total $SourcePages.Count
    Write-Progress -Activity "Finalizing $($relPage.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

}

$AllReplacedLinks | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\replacedlinks.json"
$AllFoundLinks | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\foundlinks.json"
$AllNewLinks | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\newewLinks.json"
$Article_Relinking.GetEnumerator() |
    ForEach-Object { [ordered]@{ "$($_.Key)" = $_.Value } } |
    ConvertTo-Json -Depth 10 |
    Out-File "$TmpOutputDir\Article_Relinking.json"
$ConfluenceToHuduUrlMap | ConvertTo-Json -Depth 5 | Out-File "$TmpOutputDir\UrlMap.json"
