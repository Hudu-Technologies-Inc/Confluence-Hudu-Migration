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


$ImageMap = @{}
$ConfluenceToHuduUrlMap = @{}
$Article_Relinking=@{}
$RunSummary=@{
    State="Set-Up"
    CompletedStates=@()
    SetupInfo=@{
        HuduDestination     = $HuduBaseUrl
        HuduMaxContentLength= 4500
        ConfluenceSource    = $ConfluenceBaseUrl
        HuduVersion         = [version]$HuduAppInfo.version
        PowershellVersion   = [version]$PowershellVersion
        project_workdir     = $project_workdir
        StartedAt           = $(get-date)
        FinishedAt          = $null
        RunDuration         = $null
        PreviewLength       = 2500

    }
    JobInfo=@{
        MigrationSource     = [PSCustomObject]@{}
        MigrationDest       = [PSCustomObject]@{}
        Spaces              = [System.Collections.ArrayList]@()
        PagesCount          = 0
        LinksCreated        = 0
        LinksFound          = 0
        LinksReplaced       = 0
        ArticlesCreated     = 0
        ArticlesSkipped     = 0
        ArticlesErrored     = 0
        AttachmentsFound    = 0
        UploadsCreated      = 0
        UploadsErrored      = 0
    }
    Errors                  = [System.Collections.ArrayList]@()
    Warnings                = [System.Collections.ArrayList]@()
}
$TrackedAttachments = [System.Collections.ArrayList]@()
$AllReplacedLinks =  [System.Collections.ArrayList]@()
$AllFoundLinks =[System.Collections.ArrayList]@()
$AllNewLinks = [System.Collections.ArrayList]@()        

# Step 1.1- Get spaces and select which or all spaces to get pages from
PrintAndLog -message  "Getting All Spaces and configuring Source options (Confluence-Side)" -Color Blue
$AllSpaces=GetAllSpaces -baseUrl $ConfluenceBaseUrl -authHeader "Basic $encodedCreds"
if ($AllSpaces.Count -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Confluence Spaces! Double-check your credentials and try again." -Color Red
    exit 1
}

$SourcePages = @()
$RunSummary.JobInfo.MigrationSource=$(Select-Object-From-List -Objects @(
[PSCustomObject]@{
    OptionMessage= "From a Single/Specific Confluence Space"
    Identifier = 0
}, 
[PSCustomObject]@{
    OptionMessage= "From All ($($AllSpaces.count)) Confluence Space(s)"
    Identifier = 1
}) -message "Configure Source (Confluence-Side) Options from Confluence- Migrate pages from which Space(s)?" -allowNull $false)

# Step 1- Obtain and record pages/attachments for space(s)
if ([int]$RunSummary.JobInfo.MigrationSource.Identifier -eq 0) {
    $SingleChosenSpace=$(Select-Object-From-List -Objects $AllSpaces - Message "From which single space would you like to migrate pages from?")  
    $RunSummary.JobInfo.Spaces.Add($SingleChosenSpace) | Out-Null
    $RunSummary.JobInfo.MigrationSource.OptionMessage="$($RunSummary.JobInfo.MigrationSource.OptionMessage) (space: $($SingleChosenSpace.name)/$($SingleChosenSpace.key))"
    $SourcePages=$(GetAllPages -SpaceKey $SingleChosenSpace.key -SpaceName $SingleChosenSpace.name -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl)
} else {
    foreach ($space in $AllSpaces) {
        PrintAndLog -message "Obtaining Pages from space: $($space.name)/$($space.key)" -Color Blue
        $RunSummary.JobInfo.Spaces.Add($space) | Out-Null
        $addedPages = $(GetAllPages -SpaceKey $space.key -SpaceName $space.name -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl)
        $SourcePages+=$addedPages
    }
}

$RunSummary.JobInfo.PagesCount = $SourcePages.count
foreach ($page in $SourcePages) {
    $page | Add-Member -NotePropertyName FetchedBy     -NotePropertyValue $localhost_name -Force
    $page | Add-Member -NotePropertyName OriginalTitle -NotePropertyValue $page.title -Force
    $page | Add-Member -NotePropertyName title         -NotePropertyValue $(Get-SafeTitle -name $page.title) -Force
    $page | Add-Member -NotePropertyName htmlContent   -NotePropertyValue $page.body.storage.value -Force
    $page | Add-Member -NotePropertyName rawContent    -NotePropertyValue $page.body.storage.value -Force
    $page | Add-Member -NotePropertyName articlePreview -NotePropertyValue $(Get-ArticlePreviewBlock -Title $page.title -PageId $page.id -Content $page.body.storage.value -MaxLength $RunSummary.SetupInfo.PreviewLength) -Force
    $page | Add-Member -NotePropertyName Links         -NotePropertyValue $(Get-LinksFromHTML -htmlContent $page.body.storage.value -title $page.title -includeImages $false) -Force
    $page | Add-Member -NotePropertyName BaseLinks     -NotePropertyValue $(Get-ConfluenceLinks -page $page) -Force
    $page | Add-Member -NotePropertyName stub          -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName updatedHtml   -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName CompanyId     -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName ReplacedLinks -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName HuduArticle   -NotePropertyValue $null -Force
    $page | Add-Member -NotePropertyName CharsTrimmed  -NotePropertyValue 0 -Force
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
        $RunSummary.JobInfo.AttachmentsFound+=1
        write-host "    attachment $attachidx- $attachment"
    }
}

if ($RunSummary.JobInfo.PagesCount -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Source Articles/Pages in Confluence! Double-check your credentials and try again." -Color Red
    exit
} else {
    $RunSummary.JobInfo.MigrationSource.OptionMessage="Migrate $($RunSummary.JobInfo.PagesCount) Articles/Pages $($RunSummary.JobInfo.MigrationSource.OptionMessage)"
    PrintAndLog -message "Elected to $($RunSummary.JobInfo.MigrationSource.OptionMessage)" -Color Yellow
}
if ($(Select-Object-From-List -objects @("yes","no") -message "does this look like the correct source data?") -eq "no") {write-error "please re-invoke to start over."; exit 1}


# Step 2: Present Options for Hudu / Destination
PrintAndLog -message  "Getting All Companies and configuring destination options (Hudu-Side)" -Color Blue
$all_companies = Get-HuduCompanies
if ($all_companies.Count -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Companies set up in Hudu... If you intend to attribute certain articles to certain companies, be sure to add your companies first!" -Color Red
}
$Attribution_Options=[System.Collections.ArrayList]@()
$RunSummary.JobInfo.MigrationDest=$(Select-Object-From-List -Objects @(
    [PSCustomObject]@{
        OptionMessage= "To a Single Specific Company in Hudu"
        Identifier = 0
    },
    [PSCustomObject]@{
        OptionMessage= "To Global/Central Knowledge Base in Hudu (generalized / non-company-specific)"
        Identifier = 1
    }, 
    [PSCustomObject]@{
        OptionMessage= "To Multiple Companies in Hudu - Let Me Choose for Each article ($($all_companies.count) available destination company choices)"
        Identifier = 2
    }) -message "Configure Destination (Hudu-Side) Options- $($RunSummary.JobInfo.MigrationSource.OptionMessage) to where in Hudu?" -allowNull $false)


if ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 0) {
    $SingleCompanyChoice=$(Select-Object-From-List -Objects $all_companies -message "Which company to $($SourcePages.OptionMessage) ($($SourcePages.count)) articles to?")
    $Attribution_Options=[PSCustomObject]@{
        CompanyId            = $SingleCompanyChoice.Id
        CompanyName          = $SingleCompanyChoice.Name
        OptionMessage        = "Company Name: $($SingleCompanyChoice.Name), Company ID: $($SingleCompanyChoice.Id)"
        IsGlobalKB           = $false
}
    $RunSummary.JobInfo.MigrationDest.OptionMessage="$($RunSummary.JobInfo.MigrationDest.OptionMessage) (Company Name: $($SingleCompanyChoice.Name), Company ID: $($SingleCompanyChoice.Id))"
} elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 1) {
    $Attribution_Options+=[PSCustomObject]@{
        CompanyId            = 0
        CompanyName          = "Global KB"
        OptionMessage        = "No Company Attribution (Upload As Global/Central KnowledgeBase Article)"
        IsGlobalKB           = $true
    }    
} else {
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
        OptionMessage        = "No Company Attribution (Upload As Global/Central KnowledgeBase Article)"
        IsGlobalKB           = $true
    }
    $Attribution_Options+=[PSCustomObject]@{
        CompanyId            = -1
        CompanyName          = "None (SKIP FOR NOW)"
        OptionMessage        = "Skipped"
        IsGlobalKB           = $false
    }
}

PrintAndLog -message "You've elected for this migration path: $($RunSummary.JobInfo.MigrationSource.OptionMessage) $($RunSummary.JobInfo.MigrationDest.OptionMessage)." -Color Yellow
Read-Host "Press enter now or CTL+C / Close window to exit now!"

$RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
$RunSummary.State="Stubbing articles"
write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

$StubbedPages=@()
$PageIDX=0
foreach ($page in $SourcePages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count
    #Generate articl preview
            
    if ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 0) {
        $page.CompanyId = $SingleCompanyChoice.id
    } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 1) {
        $page.CompanyId = $null  # global KB
    } else {
        $page.CompanyId = $(Select-Object-From-List -message "Migrating Article: $($page.articlePreview ?? "no preview")... Which company to migrate into?" -objects $Attribution_Options).CompanyId
    }

    #stub article
    if ($null -eq $page.CompanyId -or $page.CompanyId -eq 0) {
        printandlog -message "Stubbing global KB article" -Color yellow
        $page.stub = New-HuduStubArticle -Title $($page.title) -Content "stubbed preview - $($page.articlePreview)"
    } elseif ($page.CompanyId -lt 0) {
        printandlog -message "Skipping page/article transfer for $($page.title)" -Color Gray
        $RunSummary.Warnings+=@{
            Message     =      "User Elected to skip page/article transfer for $($page.title)"
            PageSkipped =      "Page with Confluence ID $($page.id), Titled $($page.title) was skipped by user. $($page.FullUrl ?? '')"
        }
        $RunSummary.JobInfo.Skipped+=1
        continue
    } else {
        printandlog -message "Stubbing KB article for Hudu company ID: $($page.CompanyId)" -Color  Yellow
        $page.stub = New-HuduStubArticle -Title $($page.title) -Content "stubbed preview - $($page.articlePreview)" -CompanyId $($page.CompanyId)
    }
    PrintAndLog -message "Article $($page.title) Stubbed with id $($($page.stub).id); $($($page.stub) | ConvertTo-Json -Depth 3)" -Color Green

    if ($null -eq $page.stub) {
        $ErrorObject =@{
            Error="Error Stubbing Article for Confluence page with id - $($page.id), titled $($page.title)"
        }
        Write-ErrorObjectsToFile -name "Stub-$($page.title)" -ErrorObject $ErrorObject
        $RunSummary.Errors.add($ErrorObject)
        $RunSummary.JobInfo.ArticlesErrored+=1
        continue
    }
    $RunSummary.JobInfo.ArticlesCreated+=1
    $RunSummary.JobInfo.LinksCreated+=1
    $AllNewLinks.Add([PSCustomObject]@{
        PageId        = $page.id
        PageTitle     = $page.title
        HuduUrl       = $page.stub.url
        ArticleId     = $page.stub.id
    })
    $StubbedPages+=$page
    Write-Progress -Activity "Stubbing $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage
}

$RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
$RunSummary.State="Processing Attachments"
write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

$PageIDX=0
foreach ($page in $StubbedPages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $StubbedPages.count


    # get attachment / embedded images
    PrintAndLog -message "Starting dl/ul of $($page.attachments.count) attachments found for $($page.title)" -Color Green

    # download attachments + upload attachments and atytach to stub
    $AttachIDX=0
    foreach ($att in $page.attachments) {
        $AttachIDX+=1
        $UploadedAsDoc=$false

        # Start Attachment Download
        $record = Invoke-ConfluenceAttachDownload -attachment $att -page $page -pageId $page.id -title $page.title -ConfluenceBaseUrl $ConfluenceBaseUrl -TmpOutputDir $TmpOutputDir -encodedCreds $encodedCreds

        [void]$TrackedAttachments.Add($record ?? [PSCustomObject]@{
            FileName         = $(Get-SafeFilename -Name $($record.title ?? "Title not present for page id $($page.id ?? 0)"))
            Extension        = [IO.Path]::GetExtension($record.title).ToLower()
            IsImage          = $record.title.ToLower() -match '\.(jpg|jpeg|png)$'
            PageId           = $($page.id)
            PageTitle        = $($page.title)
            SourceUrl        = "$ConfluenceBaseUrl$($record._links.download)"
            LocalPath        = "$TmpOutputDir\$($record.title)"
            UploadResult     = $null
            HuduArticleId    = $null
            HuduUploadType   = $null
            SuccessDownload  = $false
            AttachmentSize   = (Get-Item "$TmpOutputDir\$($record.title)").Length
            AttachmentTooLarge=$((Get-Item "$TmpOutputDir\$($record.title)").Length -gt 100MB)
        })

        printandlog -message "Downloaded Attachment $AttachIDX of $($page.attachments.Count) for $($page.title) - $($attachment.filename ?? "File")" -Color Yellow
        if ($record -and $record.SuccessDownload -and $record.LocalPath) {
            # Handle attachments that are too large for Hudu (larger than)
            if ($true -eq $record.AttachmentTooLarge) {
                $ErrorObject=@{
                    Attachment = $record.Filename
                    Problem    = "$($record.Filename) is TOO LARGE for Hudu. Manual Action is required. Skipping."
                    page       = "Confluence page with Id $($page.id), titled $($page.title)"
                    Article    = "Hudu stub with id $($($page.stub).id) at $($($page.stub).url)"
                }
                $RunSummary.Errors = $ErrorObject
                $RunSummary.JobInfo.UploadsErrored+=1
                Write-ErrorObjectsToFile -ErrorObject $ErrorObject -name "Attach-Error-$($record.Filename)"
                continue
            }
            # Start attachment upload if download successful and meets criteria
            try {
                PrintAndLog -Message "Uploading image: $($record.FileName) => record_id=$($($page.stub).id) record_type=Article" -Color Green
                $upload=$null
                if ($record.IsImage) {
                    $upload = New-HuduPublicPhoto -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article'
                    $upload = $upload.public_photo ?? $upload
                } else {
                    $upload = New-HuduUpload -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article'
                    $upload = $upload.upload ?? $upload
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
                $RunSummary.JobInfo.UploadsCreated += 1
            } catch {
                $ErrorInfo=@{
                    Error       =$_
                    Record      = $record.AttachmentSize ?? 0
                    Message     = "Error During Attachment Upload"
                    Article     = "Hudu Article id $($page.stub.id) at $($page.stub.url)"
                    Page        = "Confluence page with Id $($page.id), titled $($page.title)- $($page.FullUrl ?? '')"
                }
                $RunSummary.Errors.add($ErrorInfo)
                $RunSummary.JobInfo.UploadsErrored+=1
                Write-ErrorObjectsToFile -Name "$($record.FileName)" -ErrorObject $ErrorInfo
            }
        }
    }
    Write-Progress -Activity "Processing attachments for $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

}

$ImageMap | ConvertTo-Json -Depth 5 | Out-File "$TmpOutputDir\ImageMap-$($page.title).json"
$RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
$RunSummary.State="Replacing Embed/Attachment Links and Confluence Bloat"
write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

$PageIDX=0
foreach ($page in $StubbedPages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $StubbedPages.count

    # Find and replace image URLs with base64-encoded versions 

    $page.rawContent  = if ($null -ne $page.htmlContent -and $page.htmlContent.length -ge 1) {$page.htmlContent} else {"No Content Found in Confluence Page"}
    $page.updatedHtml = if ($null -ne $page.htmlContent -and $page.htmlContent.length -ge 1) {$page.htmlContent} else {"No Content Found in Confluence Page"}
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
            $page.HuduArticle = $(Set-HuduArticle -ArticleId $($page.stub).id -Content $FinalContents -name $($($page.title) ?? "Unknown Title") -CompanyId $($page.CompanyId))
        } else {
            $page.HuduArticle = $(Set-HuduArticle -ArticleId $($page.stub).id -Content $FinalContents -name $($($page.title) ?? "Unknown Title"))
        }
        $page.HuduArticle = $page.HuduArticle.article ?? $page.HuduArticle
        
    } catch {
        # Handle articles that are too large having an issue during file upload / linking
        $ErrorInfo=@{
            Message="Error Uploading article with content that is too long: $($page.title)"
            Error=$_
            HuduArticle=$(Get-HuduArticles -id $($page.stub).id).Article
            Page = "Confluence page with Id $($page.id), titled $($page.title)- $($page.FullUrl ?? '')"
            ArticleURL=$($page.stub.url ?? "URL not found")
        }
        $RunSummary.Errors.add($ErrorInfo)
        $RunSummary.JobInfo.ArticlesErrored+=1
        Write-ErrorObjectsToFile -name "largearticle-$($page.title)" -ErrorObject $ErrorInfo
        continue
    }

    if ($true -eq $UploadedAsDoc) {
        # Add a warning for articles that are too large being uploaded as linked standalone file
        $RunSummary.Warnings.add(@{
            Warning="Document from page $($page.title) was too large and was uploaded as standalone HTML File; Please review."
            ArticleURL=$htmlAttachment.Article.url ?? ($page.stub.url ?? "URL not found")
            PageURL=$page.FullUrl ?? ("$baseUrl$($page._links.webui)" ?? "URL not found")
        })
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

$RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
$RunSummary.State="Relinking Imported Articles"
write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

$PageIDX=0
foreach ($id in $Article_Relinking.Keys) {
    $entry = $Article_Relinking[$id]
    $relPage = $entry.Page
    $htmlContent = $relPage.updatedHtml ?? $entry.HuduArticle.content
    $PageIDX=$PageIDX+1

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
 
    # 2. Regex to match href="/12345" or href="/12345?someparam"
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

    # 3. Replace legacy Confluence view links like ?pageId=98429
    $pageIdPattern = [regex]::Escape("pageId=$($entry.Page.id)")
    if ($htmlContent -match $pageIdPattern) {
        $htmlContent = $htmlContent -replace $pageIdPattern, $huduUrl
        PrintAndLog -Message "Replaced legacy pageId=$($entry.Page.id)" -Color Green
    }

    # 4. Replace direct "page/<id>" references
    $pagePathPattern = [regex]::Escape("page/$($entry.Page.id)")
    if ($htmlContent -match $pagePathPattern) {
        $htmlContent = $htmlContent -replace [regex]::Escape($pagePathPattern), $entry.HuduArticle.url
        PrintAndLog -Message "Replaced page/$($entry.Page.id) → $($entry.HuduArticle.url)" -Color Green
    }

    foreach ($sourcePage in $StubbedPages) {
        $htmlContent = $htmlContent -replace $sourcePage.title, "<a href='$($sourcePage.HuduArticle.url ?? $sourcePage.stub.url)'>$($sourcePage.title)</a>"
        foreach ($baselink in $sourcePage.BaseLinks) {
            $htmlContent = $htmlContent -replace $baselink, $($sourcePage.HuduArticle.url ?? $sourcePage.stub.url)
        }
    }
    $relPage.ReplacedLinks = $(Get-LinksFromHTML -htmlContent $htmlContent -title $relPage.title -includeImages $false)
    $response = Set-HuduArticle -ArticleId $id -Content $htmlContent -Name $relPage.title
    $relPage.HuduArticle = $response.Article ?? $response
    PrintAndLog -Message "Updated article [$($relPage.title)] with length: $($htmlContent.Length)" -Color Cyan

    # Optional: also update the Article_Relinking entry with new content
    $Article_Relinking[$id].content = $relPage.HuduArticle.content

    $relPage | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\completed-page-$($relPage.title).json"
    $AllReplacedLinks.Add($relPage.ReplacedLinks)

    $completionPercentage = Get-PercentDone -Current ($PageIDX++) -Total $Article_Relinking.Count
    Write-Progress -Activity "Finalizing $($relPage.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

}

# Final step - Wrap up
Write-Host "Calculating results, please wait." -ForegroundColor cyan
$Article_Relinking.GetEnumerator() |
    ForEach-Object { [ordered]@{ "$($_.Key)" = $_.Value } } |
    ConvertTo-Json -Depth 10 |
    Out-File "$TmpOutputDir\Article_Relinking.json"
$RunSummary.SetupInfo.FinishedAt        = $(get-date)
$RunSummary.JobInfo.LinksCreated        = $AllNewLinks.count
$RunSummary.JobInfo.LinksReplaced       = $(($StubbedPages | ForEach-Object { Get-LinksFromHTML -htmlContent $_ -title "" -includeImages $true -suppressOutput $true } | Where-Object { $_ -ilike "*$HuduBaseURL*" }).count)
$RunSummary.JobInfo.LinksFound          = $AllFoundLinks.count
$RunSummary.SetupInfo.RunDuration       = $($RunSummary.SetupInfo.FinishedAt - $RunSummary.SetupInfo.StartedAt).ToString()
$RunSummary.CompletedStates += "finished in $($RunSummary.SetupInfo.RunDuration)"
$RunSummary.State="Finished"

$ConfluenceToHuduUrlMap | ConvertTo-Json -Depth 15 | Out-File "$TmpOutputDir\UrlMap.json"
foreach ($varname in @("encodedCreds","HuduAPIKey","ConfluenceToken")) {
    remove-variable -name varname -Force -ErrorAction SilentlyContinue
}
# Serialize summary JSON
$SummaryJson = $RunSummary | ConvertTo-Json -Depth 15

# Nicely print a cleaned-up version to the console
$SummaryJson -split "`n" | ForEach-Object {
    $_ -replace '[\{\[]', '⤵' `
       -replace '[\}\]]', '' `
       -replace '",', '"' `
       -replace '^', '  '
}
$SummaryJson | ConvertTo-Json -Depth 15 | Out-File "$(join-path $LogsDir -ChildPath "job-summary.json")"

# Print final state summary
Write-Host "$($RunSummary.CompletedStates.Count): $($RunSummary.State) in $($RunSummary.SetupInfo.RunDuration) with $($RunSummary.Errors.Count) errors and $($RunSummary.Warnings.Count) warnings" -ForegroundColor Magenta