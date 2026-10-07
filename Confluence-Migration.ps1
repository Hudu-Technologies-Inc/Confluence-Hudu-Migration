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

# init
if ($MyInvocation.InvocationName -eq '.') {
    Write-Host "Script was dot-sourced" -ForegroundColor Green
} else {
    Write-Host "Script was executed without dot-sourcing, this is the recommended method of running the script to ensure settings are retained in the session" -ForegroundColor Yellow; write-warning "exiting to prevent issues later on, please dot-source the script by running `. .\yourenvironmentfile.ps1` or `. .\Confluence-Migration.ps1` from powershell 7.5 or later (ideally as Administrator)" -ForegroundColor Red; exit 1;
}

# instantiate vars
$project_workdir=$PSScriptRoot; foreach ($h in @("init","confluence","general")){. "$project_workdir\helpers\$h.ps1"};
$PowershellVersion = [version](Get-Host).Version; $HuduAppInfo = Get-HuduAppInfo; $CurrentHuduVersion = [version]$HuduAppInfo.version; $articlesEnabled = Get-HuduFeatureAvailability -Core_Feature articles;
$NonInteractive = Get-CoercedBoolean -Value ($noninteractive ?? $env:CONFLUENCE_NONINTERACTIVE ?? $env:NONINTERACTIVE) -Default $false; $ExportConfluenceTables = Get-CoercedBoolean -Value ($ExportConfluenceTables ?? $env:CONFLUENCE_EXPORT_TABLES ?? $env:EXPORT_CONFLUENCE_TABLES) -Default $false; $ConfluenceTableSchemaMatchThreshold = Get-CoercedDouble -Value ($ConfluenceTableSchemaMatchThreshold ?? $env:CONFLUENCE_TABLE_SCHEMA_MATCH_THRESHOLD) -Default 0.86; $SkipArchivedConfluenceContent = Get-CoercedBoolean -Value ($SkipArchivedConfluenceContent ?? $env:CONFLUENCE_SKIP_ARCHIVED ?? $env:SKIP_ARCHIVED_CONFLUENCE_CONTENT) -Default $true; $TrackAttachmentDetails = Get-CoercedBoolean -Value ($TrackAttachmentDetails ?? $env:CONFLUENCE_TRACK_ATTACHMENT_DETAILS) -Default $false;

if ($PowershellVersion -lt $requiredPowershellVersion) {Write-Host "PowerShell $requiredPowershellVersion or higher is required. You have $PowershellVersion." -ForegroundColor Red; exit 1;} 
if ($CurrentHuduVersion -lt [version]$RequiredHuduVersion) {Write-Host "This script requires at least version $RequiredHuduVersion and cannot run with version $CurrentHuduVersion. Please update your version of Hudu."; exit 1;}
if ($false -eq $articlesEnabled.CentralKB -and $false -eq $articlesEnabled.CompanyKB) {Write-Host "Articles feature is not enabled in Hudu. Exiting script." -ForegroundColor Red; exit 1;}
$ImageMap = @{}; $ConfluenceToHuduUrlMap = @{}; $Article_Relinking=@{}; $RunSummary=Start-RunSummary; $TrackedAttachments = if ($TrackAttachmentDetails) { [System.Collections.ArrayList]@() } else { $null }; $LinksCreatedCount = 0; $LinksFoundCount = 0; $LinksReplacedCount = 0; $SourcePages = [System.Collections.ArrayList]@(); $destinationChoices = @();
$Attribution_Options=[System.Collections.ArrayList]@(); $SpaceCompanyMap = @{};

# Step 1.1- Get spaces and select which or all spaces to get pages from
PrintAndLog -message  "Getting All Spaces and configuring Source options (Confluence-Side)" -Color Blue
$AllSpaces=GetAllSpaces -baseUrl $ConfluenceBaseUrl -authHeader "Basic $encodedCreds"
if ($AllSpaces.Count -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Confluence Spaces! Double-check your credentials and try again." -Color Red
    exit 1
} else {try {Set-MigrationRecord} catch {}}
$allSpacesSourceStrategy = @($ConfluenceSourceStrategies | Where-Object { $_.Identifier -eq 1 } | Select-Object -First 1)[0]
if ($null -ne $allSpacesSourceStrategy) {$allSpacesSourceStrategy.OptionMessage = "From All ($($AllSpaces.count)) Confluence Space(s)"}
$multipleSpacesSourceStrategy = @($ConfluenceSourceStrategies | Where-Object { $_.Identifier -eq 2 } | Select-Object -First 1)[0]
if ($null -ne $multipleSpacesSourceStrategy) {$multipleSpacesSourceStrategy.OptionMessage = "From Multiple Selected Confluence Space(s) (choose from $($AllSpaces.count))"}

$RunSummary.JobInfo.MigrationSource = Select-ConfluenceSourceStrategy -Strategies $ConfluenceSourceStrategies -NonInteractive $NonInteractive -PreselectedSourceStrategy $preselectedSourceStrategy

# Step 1- Obtain and record pages/attachments for space(s)
if ([int]$RunSummary.JobInfo.MigrationSource.Identifier -eq 0) {
    $SingleChosenSpace = Select-ConfluenceSpace -Spaces $AllSpaces -NonInteractive $NonInteractive -PreselectedSingleSpace $preselectedSingleSpace
    $RunSummary.JobInfo.Spaces.Add($SingleChosenSpace) | Out-Null
    $RunSummary.JobInfo.MigrationSource.OptionMessage="$($RunSummary.JobInfo.MigrationSource.OptionMessage) (space: $($SingleChosenSpace.name)/$($SingleChosenSpace.key))"
    Add-ConfluenceSourcePages -Pages @(GetAllPages -SpaceKey $SingleChosenSpace.key -SpaceName $SingleChosenSpace.name -SpaceId $SingleChosenSpace.id -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl -SkipArchived $SkipArchivedConfluenceContent)
} elseif ([int]$RunSummary.JobInfo.MigrationSource.Identifier -eq 2) {
    $SelectedSpaces = Select-ConfluenceSpaces -Spaces $AllSpaces -NonInteractive $NonInteractive -PreselectedSpaces ($preselectedSourceSpaces ?? $env:CONFLUENCE_SOURCE_SPACES)
    foreach ($space in $SelectedSpaces) {
        PrintAndLog -message "Obtaining Pages from selected space: $($space.name)/$($space.key)" -Color Blue
        $RunSummary.JobInfo.Spaces.Add($space) | Out-Null
        $addedPages = @(GetAllPages -SpaceKey $space.key -SpaceName $space.name -SpaceId $space.id -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl -SkipArchived $SkipArchivedConfluenceContent)
        Add-ConfluenceSourcePages -Pages $addedPages
        $addedPages = $null
    }
    $RunSummary.JobInfo.MigrationSource.OptionMessage="$($RunSummary.JobInfo.MigrationSource.OptionMessage) (spaces: $((@($SelectedSpaces) | ForEach-Object { "$($_.name)/$($_.key)" }) -join ', '))"
} else {
    foreach ($space in $AllSpaces) {
        PrintAndLog -message "Obtaining Pages from space: $($space.name)/$($space.key)" -Color Blue
        $RunSummary.JobInfo.Spaces.Add($space) | Out-Null
        $addedPages = @(GetAllPages -SpaceKey $space.key -SpaceName $space.name -SpaceId $space.id -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl -SkipArchived $SkipArchivedConfluenceContent)
        Add-ConfluenceSourcePages -Pages $addedPages
        $addedPages = $null
    }
}
$RunSummary.JobInfo.PagesCount = $SourcePages.count

if ($RunSummary.JobInfo.PagesCount -eq 0) {
    PrintAndLog -message  "Sorry, we didnt seem to see any Source Articles/Pages in Confluence! Double-check your credentials and try again." -Color Red
    exit
} else {
    $RunSummary.JobInfo.MigrationSource.OptionMessage="Migrate $($RunSummary.JobInfo.PagesCount) Articles/Pages $($RunSummary.JobInfo.MigrationSource.OptionMessage)"
    PrintAndLog -message "Elected to $($RunSummary.JobInfo.MigrationSource.OptionMessage)" -Color Yellow
}
if ($NonInteractive) {
    PrintAndLog -message "Noninteractive mode: assuming source data confirmation is yes." -Color Yellow
} elseif ($(Select-ObjectFromList -objects @("yes","no") -message "does this look like the correct source data?") -eq "no") {
    write-error "please re-invoke to start over."; exit 1
}

# Step 2: Present Options for Hudu / Destination
PrintAndLog -message  "Getting All Companies and configuring destination options (Hudu-Side)" -Color Blue
$all_companies = @(Get-HuduCompanies | Where-Object { $null -ne $_ })
$hasCentralKb = $true -eq $articlesEnabled.CentralKB; $hasCompanyKb = $true -eq $articlesEnabled.CompanyKB; $hasCompanies = $all_companies.Count -gt 0;

if (-not $hasCentralKb -and -not $hasCompanyKb) {Write-Warning "Articles are not enabled for Central KB or Company KB in Hudu. Enable at least one article destination before proceeding."; exit 1;}
if (-not $hasCompanies) {PrintAndLog -message "$(if ($hasCompanyKb) {"Sorry, we didnt seem to see any Companies set up in Hudu... Existing-company destination options will be limited, but the per-space option can create missing companies automatically."} else {"Sorry, we didnt seem to see any Companies set up in Hudu... If you intend to attribute certain articles to certain companies, enable Company KB and add or create companies first."})" -Color Yellow}

if ($hasCentralKb) {
    write-host "Central KB core feature is enabled in Hudu"
    $centralOptionMessage = "To Global/Central Knowledge Base in Hudu (generalized / non-company-specific)"
    if (-not $hasCompanies) {
        $centralOptionMessage += " [no companies in Hudu to designate]"
    } elseif (-not $hasCompanyKb) {
        $centralOptionMessage += " [company KB is not enabled in Hudu]"
    }
    $destinationChoices += [PSCustomObject]@{
        OptionMessage = $centralOptionMessage
        Identifier    = 1
    }
} else {
    write-host "Central KB core feature is not enabled in Hudu, not allowing it as option."
}

if ($hasCompanyKb) {
    write-host "Company KB core feature is enabled in Hudu"
    if ($true -eq $hasCompanies){
        $destinationChoices += [PSCustomObject]@{
            OptionMessage = "To a Single Specific Company in Hudu"
            Identifier    = 0
        }
        $destinationChoices += [PSCustomObject]@{
            OptionMessage = "To Multiple Companies in Hudu - Let Me Choose for Each article ($(@($all_companies).Count) available destination company choices)"
            Identifier    = 2
        }
    }
    $destinationChoices += [PSCustomObject]@{
        OptionMessage = "To One Company Per Confluence Space in Hudu - Match by Space Name, Create Missing Companies"
        Identifier    = 3
    }
} else {
    write-host "Company KB core feature is not enabled in Hudu, not allowing it as option."
}

if ($destinationChoices.Count -eq 0) {Write-Warning "No valid Hudu article destination is available. Company KB and Central KB are not available for this migration."; exit 1;}

$RunSummary.JobInfo.MigrationDest = Select-HuduDestinationStrategy `
    -DestinationChoices $destinationChoices `
    -Message "Configure Destination (Hudu-Side) Options- $($RunSummary.JobInfo.MigrationSource.OptionMessage) to where in Hudu?" `
    -NonInteractive $NonInteractive `
    -PreselectedDestinationStrategy $preselectedDestinationStrategy

if ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 0) {
    $SingleCompanyChoice = Select-HuduCompany `
        -Companies $all_companies `
        -Message "Which company to migrate $($SourcePages.count) articles to?" `
        -NonInteractive $NonInteractive `
        -PreselectedCompany $preselectedSingleCompany
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
} elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 3) {
    foreach ($space in $RunSummary.JobInfo.Spaces) {
        $spaceCompany = Resolve-HuduCompanyForConfluenceSpace -Space $space -Companies @($all_companies)
        $SpaceCompanyMap[[string]$space.Key] = [PSCustomObject]@{
            SpaceId              = $space.Id
            SpaceKey             = $space.Key
            SpaceName            = $space.Name
            CompanyId            = $spaceCompany.Id
            CompanyName          = $spaceCompany.Name
            OptionMessage        = "Space: $($space.Name) ($($space.Key)) -> Company Name: $($spaceCompany.Name), Company ID: $($spaceCompany.Id)"
            IsGlobalKB           = $false
        }
        if (@($all_companies | Where-Object { $_.Id -eq $spaceCompany.Id }).Count -eq 0) {
            $all_companies = @($all_companies | Where-Object { $null -ne $_ }) + @($spaceCompany)
        }
    }

    $RunSummary.JobInfo['SpaceCompanyMap'] = @($SpaceCompanyMap.Values)
    $RunSummary.JobInfo.MigrationDest.OptionMessage="$($RunSummary.JobInfo.MigrationDest.OptionMessage) ($($SpaceCompanyMap.Count) Confluence space(s) mapped)"
} else {
    foreach ($company in $all_companies) {
        $Attribution_Options+=[PSCustomObject]@{
            CompanyId            = $company.Id
            CompanyName          = $company.Name
            OptionMessage        = "Company Name: $($company.Name), Company ID: $($company.Id)"
            IsGlobalKB           = $false
        }
    }
    if ($hasCentralKb) {
        $Attribution_Options+=[PSCustomObject]@{
            CompanyId            = 0
            CompanyName          = "Global KB"
            OptionMessage        = "No Company Attribution (Upload As Global/Central KnowledgeBase Article)"
            IsGlobalKB           = $true
        }
    }
    $Attribution_Options+=[PSCustomObject]@{
        CompanyId            = -1
        CompanyName          = "None (SKIP FOR NOW)"
        OptionMessage        = "Skipped"
        IsGlobalKB           = $false
    }
}

PrintAndLog -message "You've elected for this migration path: $($RunSummary.JobInfo.MigrationSource.OptionMessage) $($RunSummary.JobInfo.MigrationDest.OptionMessage)." -Color Yellow
if ($NonInteractive) {} else {Read-Host "Press enter now or CTL+C / Close window to exit now!"}

# ── TITLE CACHE PRE-PASS ─────────────────────────────────────────────────────
# Build a lookup of Confluence page ID -> title so Resolve-HuduFolder can
# identify pages acting as folder containers without extra API calls.
foreach ($page in $SourcePages) {
    $script:TitleCache[$page.id] = $page.OriginalTitle
}
PrintAndLog "Title cache built: $($script:TitleCache.Count) entries" -Color Cyan

$script:SpaceHomepageId = if ($SingleChosenSpace) {
    $spaceDetail = Invoke-RestMethod -Uri "$ConfluenceBaseUrl/api/v2/spaces/$($SingleChosenSpace.Id)" `
        -Headers @{ Authorization = "Basic $encodedCreds"; Accept = "application/json" }
    $spaceDetail.homepageId
} else { $null }
PrintAndLog "Space homepage ID: $($script:SpaceHomepageId ?? 'none — all-spaces mode or not found')" -Color Cyan


$RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
$RunSummary.State="Stubbing articles"
write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

$StubbedPages=[System.Collections.ArrayList]@()
$PageIDX=0
foreach ($page in $SourcePages) {
    $PageIDX=$PageIDX+1
    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count
    #Generate articl preview
    $page.CompanyId = $null
    if ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 0) {
        $page.CompanyId = $SingleCompanyChoice.id
    } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 1) {
        $page.CompanyId = $null  # global KB
    } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 3) {
        $spaceMapKey = [string]$page.SpaceKey
        $pageDestination = $SpaceCompanyMap[$spaceMapKey]
        if ($null -eq $pageDestination) {
            throw "No Hudu company mapping was found for Confluence space key '$spaceMapKey' while migrating page '$($page.title)'."
        }
        $page.CompanyId = $pageDestination.CompanyId
    } else {
        $page.CompanyId = $(Select-ObjectFromList -message "Migrating Article: $($page.articlePreview ?? "no preview")... Which company to migrate into?" -objects $Attribution_Options).CompanyId
    }

    if ($null -ne $page.CompanyId -and $page.CompanyId -eq -1) {
        printandlog -message "Skipping page/article transfer for $($page.title)" -Color Gray
        $RunSummary.Warnings+=@{
            Message     =      "User Elected to skip page/article transfer for $($page.title)"
            PageSkipped =      "Page with Confluence ID $($page.id), Titled $($page.title) was skipped by user. $($page.FullUrl ?? '')"
        }
        $RunSummary.JobInfo.Skipped+=1
        continue
    }

    # Resolve Hudu folder for this page (company-scoped migrations only)
    $folderId = $null
    if ($page.parentId) {
        $folderId = Resolve-HuduFolder `
            -ParentId   $page.parentId `
            -ParentType ($page.parentType ?? "page") `
            -CompanyId  $page.CompanyId `
            -AuthHeader "Basic $encodedCreds" `
            -BaseUrl    $ConfluenceBaseUrl
    }

    #stub article
    if ($null -eq $page.CompanyId -or $page.CompanyId -lt 1) {
        printandlog -message "Stubbing global KB article" -Color yellow
        $page.stub = New-HuduStubArticle -Title $($page.title) -Content "Migration stub. Final content will be populated after relinking."  -FolderId $folderId
    } else {
        printandlog -message "Stubbing KB article for Hudu company ID: $($page.CompanyId), folder: $($folderId ?? 'none')" -Color Yellow
        $page.stub = New-HuduStubArticle -Title $($page.title) -Content "Migration stub. Final content will be populated after relinking." -CompanyId $($page.CompanyId) -FolderId $folderId
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
    $LinksCreatedCount+=1
    foreach ($baseLink in $page.BaseLinks) {
        $ConfluenceToHuduUrlMap[$baseLink] = $page.stub.url
    }
    [void]$StubbedPages.Add($page)
    Write-Progress -Activity "Stubbing $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage
}

if ($ExportConfluenceTables) {
    $tableExportDir = Join-Path $LogsDir "tables"
    PrintAndLog -message "Auxiliary Confluence table export enabled. Writing grouped CSVs and schema inventory to $tableExportDir" -Color Cyan
    try {
        $tableExportSummary = Export-ConfluenceTables `
            -Pages @($SourcePages) `
            -OutDir $tableExportDir `
            -SpaceCompanyMap $SpaceCompanyMap `
            -SingleCompanyChoice $SingleCompanyChoice `
            -AttributionOptions @($Attribution_Options) `
            -Companies @($all_companies) `
            -SchemaMatchThreshold $ConfluenceTableSchemaMatchThreshold

        $RunSummary.JobInfo['TableExport'] = $tableExportSummary
        PrintAndLog -message "Table export complete: $($tableExportSummary.TableCount) table(s), $($tableExportSummary.GroupCount) schema group(s), $($tableExportSummary.RowCount) row(s)." -Color Green
    } catch {
        $ErrorObject = @{
            Error   = $_
            Message = "Error exporting Confluence tables to grouped CSVs"
            OutDir  = $tableExportDir
        }
        $RunSummary.Errors.Add($ErrorObject) | Out-Null
        Write-ErrorObjectsToFile -Name "TableExport" -ErrorObject $ErrorObject
        PrintAndLog -message "Table export failed, continuing main migration. Details were written to the error logs." -Color Yellow
    }
} else {
    PrintAndLog -message "Auxiliary Confluence table export is disabled. Set CONFLUENCE_EXPORT_TABLES=true or `$ExportConfluenceTables=`$true to enable grouped CSV exports." -Color Gray
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

        if ($null -eq $record) {
            $record = [PSCustomObject]@{
                FileName           = $(Get-SafeFilename -Name $($att.title ?? "Title not present for page id $($page.id ?? 0)"))
                Extension          = [IO.Path]::GetExtension($att.title).ToLower()
                IsImage            = $false
                PageId             = $($page.id)
                PageTitle          = $($page.title)
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
            printandlog -message "Downloaded Attachment $AttachIDX of $($page.attachments.Count) for $($page.title) - $($record.FileName)" -Color Yellow
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
                PrintAndLog -Message "Uploading attachment: $($record.FileName) => record_id=$($($page.stub).id) record_type=Article" -Color Green
                $upload=$null
                $fileUpload=$null
                $publicPhoto=$null
                $commonPublicPhotoExtensions = @('.jpg', '.jpeg', '.png', '.gif')
                $shouldKeepUploadCopy = ($true -eq $record.IsImage -and $commonPublicPhotoExtensions -contains $record.Extension)

                if ($true -eq $record.IsImage) {
                    $publicPhoto = New-HuduPublicPhoto -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article'
                    $publicPhoto = $publicPhoto.public_photo ?? $publicPhoto
                    $upload = $publicPhoto

                    if ($shouldKeepUploadCopy) {
                        $fileUpload = New-HuduUpload -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article'
                        $fileUpload = $fileUpload.upload ?? $fileUpload
                    }
                } else {
                    $fileUpload = New-HuduUpload -FilePath $record.LocalPath -record_id $($page.stub).id -record_type 'Article'
                    $fileUpload = $fileUpload.upload ?? $fileUpload
                    $upload = $fileUpload
                }
                write-host "$($upload.slug)"
                $fileUploadRef = if ($fileUpload -and -not [string]::IsNullOrWhiteSpace($fileUpload.slug)) { $fileUpload.slug } elseif ($fileUpload) { $fileUpload.id } else { $null }
                $huduFileUploadUrl = if ($fileUploadRef) { "$HuduBaseUrl/file/$fileUploadRef" } else { $null }
                $huduPublicPhotoUrl = if ($publicPhoto) { $publicPhoto.url ?? "$HuduBaseUrl/public_photo/$($publicPhoto.id)" } else { $null }
                $huduUploadUrl = if ($publicPhoto) {
                    $huduPublicPhotoUrl
                } else {
                    $huduFileUploadUrl
                }
                $LinksCreatedCount+=1
                if ($fileUpload -and $publicPhoto) {
                    $LinksCreatedCount+=1
                }
                $normalizedFileName = $record.FileName.ToLowerInvariant()
                $embeddableMediaKind = Get-HuduEmbeddableUploadMediaKind -Path $record.FileName
                $ImageMap[$normalizedFileName] = @{
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

                $record.UploadResult    = $upload
                $record.FileUploadResult = $fileUpload
                $record.PublicPhotoResult = $publicPhoto
                $record.HuduUploadType  = $ImageMap[$normalizedFileName].Type
                $record.HuduFileUploadUrl = $huduFileUploadUrl
                $record.HuduPublicPhotoUrl = $huduPublicPhotoUrl
                $record.HuduArticleId   = $($page.stub).id
                $RunSummary.JobInfo.UploadsCreated += if ($fileUpload -and $publicPhoto) { 2 } else { 1 }
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
        } else {
            printandlog -message "Failed to download Attachment $AttachIDX of $($page.attachments.Count) for $($page.title) - $($record.FileName)" -Color Red
            $RunSummary.JobInfo.UploadsErrored+=1
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

    $rawContent = Get-MigrationPageHtmlContent -Page $page -Path $page.RawHtmlPath

    PrintAndLog -Message "Updating HTML content for $($page.title)" -Color Yellow
    # $updatedHtml = Strip-ConfluenceBloat -Html $rawContent
    # $updatedHtml = Replace-ConfluenceAttachmentTags -Html $updatedHtml -ImageMap $ImageMap -HuduBaseUrl $HuduBaseUrl
    $blankArticleHtml = '<p>&nbsp;</p>'

    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        PrintAndLog -Message "Raw HTML content is empty for $($page.title). Using blank article placeholder." -Color Yellow
        $updatedHtml = $blankArticleHtml
    } else {
        $updatedHtml = Convert-ConfluenceHtml `
            -Html $rawContent `
            -ImageMap $ImageMap `
            -HuduBaseUrl $HuduBaseUrl

        if ([string]::IsNullOrWhiteSpace($updatedHtml)) {
            PrintAndLog -Message "Converted HTML content is empty for $($page.title). Falling back to raw content." -Color Yellow
            $updatedHtml = $rawContent
        } else {
            $updatedHtml = Cleanup-ResidualConfluenceHtml -Html $updatedHtml

            if ([string]::IsNullOrWhiteSpace($updatedHtml)) {
                PrintAndLog -Message "Cleaned HTML content is empty for $($page.title). Falling back to raw content." -Color Yellow
                $updatedHtml = $rawContent
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($updatedHtml)) {
        PrintAndLog -Message "Prepared HTML content is empty for $($page.title). Using blank article placeholder." -Color Yellow
        $updatedHtml = $blankArticleHtml
    }

    $page.charsTrimmed =  [Math]::Max(0, (($rawContent ?? '').Length - ($updatedHtml ?? '').Length))
    PrintAndLog -Message "Removed $($page.charsTrimmed) characters of bloat from $($page.title)" -Color Green
    $page.PreparedHtmlPath = Save-MigrationHtmlContent -PageId $page.id -Title $page.title -Content $updatedHtml -Suffix "after" -OutDir $TmpOutputDir
    Write-Host "Saved HTML snapshot: $($page.PreparedHtmlPath)"


    PrintAndLog "Prepared Article: $($page.articlePreview) to $($($page.CompanyId) ?? 'Global KB') with attachment links converted. Final content update is deferred until relinking." -Color Green

    # Track relinking info. we'll want to relink articles/pages after all are created.
    $Article_Relinking[$($page.stub).id]=[PSCustomObject]@{
        HuduArticle    = $page.stub
        Page           = $page
        ContentPath    = $page.PreparedHtmlPath
        FinalContentPath = $null
        LinkCount      = $page.LinksCount
    }
    Write-Progress -Activity "Processing content for $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

    $page | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\wip-page-$($page.title).json"
    $rawContent = $null
    $updatedHtml = $null
    Clear-MigrationPageHtmlMemory -Page $page
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
$ConfluencePageIdToRelinkEntry = @{}
foreach ($entry in $Article_Relinking.Values) {
    if ($entry.Page -and -not [string]::IsNullOrWhiteSpace($entry.Page.id)) {
        $ConfluencePageIdToRelinkEntry[[string]$entry.Page.id] = $entry
    }
}
$RelinkReplacementPages = @($StubbedPages | ForEach-Object {
    [PSCustomObject]@{
        Title    = $_.title
        HuduUrl  = $_.HuduArticle.url ?? $_.stub.url
        BaseLinks = $_.BaseLinks
    }
})

foreach ($articleId in @($Article_Relinking.Keys)) {
    $entry = $Article_Relinking[$articleId]
    $relPage = $entry.Page
    $htmlContent = Get-MigrationPageHtmlContent -Page $relPage -Path $entry.ContentPath -Default "unknown contents"
    $PageIDX=$PageIDX+1

    $pattern = 'https://' + [regex]::Escape($ConfluenceDomain) + '\.atlassian\.net[^"''\s<>]*'
    $htmlContent = $htmlContent -replace $pattern, ''
    $htmlContent = [regex]::Replace($htmlContent, 'content/(\d+)', {
        param($match)
        $matchedId = $match.Groups[1].Value
        $targetEntry = $ConfluencePageIdToRelinkEntry[[string]$matchedId]
        if ($targetEntry) {
            $replacement = $targetEntry.HuduArticle.url ?? $targetEntry.Page.stub.url
            PrintAndLog -Message "Replacing REST content/$matchedId with → $replacement" -Color Cyan
            return $replacement
        }
        return $match.Value
    })
    $htmlContent = [regex]::Replace($htmlContent, 'pages/(\d+)', {
        param($match)
        $matchedId = $match.Groups[1].Value
        $targetEntry = $ConfluencePageIdToRelinkEntry[[string]$matchedId]
        if ($targetEntry) {
            $replacement = $targetEntry.HuduArticle.url ?? $targetEntry.Page.stub.url
            PrintAndLog -Message "Replacing /pages/$matchedId with → $replacement" -Color Cyan
            return $replacement
        }
        return $match.Value
    })

    # 1. Replace direct match or /wiki<url>
    foreach ($confluenceUrl in $ConfluenceToHuduUrlMap.Keys) {
        if ([string]::IsNullOrWhiteSpace($confluenceUrl)) { continue }

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
 
    # 2. Regex to match Confluence wiki URLs that contain a page id.
    $pattern = 'https://' + [regex]::Escape($ConfluenceDomain) + '\.atlassian\.net/wiki(?:/[^"''\s<>]*?(\d+)[^"''\s<>]*)?'
    $htmlContent = [regex]::Replace($htmlContent, $pattern, {
        param($match)
        $matchedId = $match.Groups[1].Value
        $matchedPage = if (-not [string]::IsNullOrWhiteSpace($matchedId)) { $ConfluencePageIdToRelinkEntry[[string]$matchedId] } else { $null }

        if ($matchedPage) {
            $replacement = $matchedPage.HuduArticle.url ?? $matchedPage.Page.stub.url
            PrintAndLog -Message "Replaced object refrence (PageId) url $matchedId → $replacement" -Color Cyan
            return $replacement
        }
        return $match.Value
    }, 'IgnoreCase')

    # 3. Replace legacy Confluence view links like ?pageId=98429
    $pageIdPattern = [regex]::Escape("pageId=$($entry.Page.id)")
    if ($htmlContent -match $pageIdPattern) {
        $htmlContent = $htmlContent -replace $pageIdPattern, $entry.HuduArticle.url
        PrintAndLog -Message "Replaced legacy pageId=$($entry.Page.id)" -Color Green
    }

    # 4. Replace direct "page/<id>" references
    $pagePathPattern = [regex]::Escape("page/$($entry.Page.id)")
    if ($htmlContent -match $pagePathPattern) {
        $htmlContent = $htmlContent -replace $pagePathPattern, $entry.HuduArticle.url
        PrintAndLog -Message "Replaced page/$($entry.Page.id) → $($entry.HuduArticle.url)" -Color Green
    }

# fixed so that links containing parentheses or other special characters are properly escaped in regex replacement
    foreach ($sourcePage in $RelinkReplacementPages) {
        if ([string]::IsNullOrWhiteSpace($sourcePage.HuduUrl)) { continue }

        if (-not [string]::IsNullOrWhiteSpace($sourcePage.Title) -and $htmlContent.IndexOf($sourcePage.Title, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $htmlContent = $htmlContent -replace [regex]::Escape($sourcePage.Title), "<a href='$($sourcePage.HuduUrl)'>$($sourcePage.Title)</a>"
        }

        foreach ($baselink in $sourcePage.BaseLinks) {
            if ([string]::IsNullOrWhiteSpace($baselink)) { continue }
            if ($htmlContent.IndexOf($baselink, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $htmlContent = $htmlContent -replace [regex]::Escape($baselink), $sourcePage.HuduUrl
            }
        }
    }

    $FinalContents = $htmlContent
    try {
        if ($FinalContents.Length -gt $RunSummary.SetupInfo.HuduMaxContentLength) {
            PrintAndLog "Content Length Warning: Final relinked content is too large. Safe-Maximum is $($RunSummary.SetupInfo.HuduMaxContentLength) Characters, and this is $($FinalContents.length) chars long! Adding as attached document!"
            $htmlPath = Join-Path $TmpOutputDir -ChildPath ("LargeDoc_{0}.html" -f (Get-SafeFilename ([IO.Path]::GetFileNameWithoutExtension($($relPage.title)))))
            Set-Content -Path $htmlPath -Value $FinalContents -Encoding UTF8

            $htmlAttachment = New-HuduUpload -FilePath $htmlPath -record_id $articleId -record_type 'Article'
            $htmlAttachment = $htmlAttachment.upload ?? $htmlAttachment

            $htmlAttachmentFileRef = if (-not [string]::IsNullOrWhiteSpace($htmlAttachment.slug)) { $htmlAttachment.slug } else { $htmlAttachment.id }
            $FinalContents = "Full content too long. See attached file: <a href='$HuduBaseUrl/file/$htmlAttachmentFileRef'>$($relPage.title).html</a>"

            $RunSummary.Warnings.add(@{
                Warning="Document from page $($relPage.title) was too large and was uploaded as standalone HTML File after relinking; Please review."
                ArticleURL=$relPage.stub.url ?? "URL not found"
                PageURL=$relPage.FullUrl ?? ("$ConfluenceBaseUrl$($relPage._links.webui)" ?? "URL not found")
            })
        }

        $finalLinks = @(Get-LinksFromHTML -htmlContent $FinalContents -title $relPage.title -includeImages $false)
        $relPage.ReplacedLinksCount = @($finalLinks | Where-Object { $_ -ilike "*$HuduBaseURL*" }).Count
        $relPage.ReplacedLinks = $null

        $relPage.FinalHtmlPath = Save-MigrationHtmlContent -PageId $relPage.id -Title $relPage.title -Content $FinalContents -Suffix "final" -OutDir $TmpOutputDir
        $Article_Relinking[$articleId].FinalContentPath = $relPage.FinalHtmlPath

        $response = Set-HuduArticle -ArticleId $articleId -Content $FinalContents -Name $relPage.title
        $relPage.HuduArticle = $response.Article ?? $response
        $Article_Relinking[$articleId].HuduArticle = $relPage.HuduArticle
        $LinksReplacedCount += $relPage.ReplacedLinksCount
        PrintAndLog -Message "Updated article [$($relPage.title)] with length: $($FinalContents.Length)" -Color Cyan
    } catch {
        $ErrorInfo=@{
            Message="Error finalizing article content: $($relPage.title)"
            Error=$_
            HuduArticle=$entry.HuduArticle
            Page = "Confluence page with Id $($relPage.id), titled $($relPage.title)- $($relPage.FullUrl ?? '')"
            ArticleURL=$($relPage.stub.url ?? "URL not found")
        }
        $RunSummary.Errors.add($ErrorInfo)
        $RunSummary.JobInfo.ArticlesErrored+=1
        Write-ErrorObjectsToFile -name "finalarticle-$($relPage.title)" -ErrorObject $ErrorInfo
        $htmlContent = $null
        $FinalContents = $null
        $finalLinks = $null
        Invoke-MigrationMemoryCleanup
        continue
    }

    $relPage | ConvertTo-Json -Depth 10 | Out-File "$TmpOutputDir\completed-page-$($relPage.title).json"

    $completionPercentage = Get-PercentDone -Current $PageIDX -Total $Article_Relinking.Count
    Write-Progress -Activity "Finalizing $($relPage.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage

    $htmlContent = $null
    $FinalContents = $null
    $finalLinks = $null
    if (($PageIDX % 25) -eq 0) {
        Invoke-MigrationMemoryCleanup
    }
}

# Final step - Wrap up
Write-Host "Calculating results, please wait." -ForegroundColor cyan
$Article_Relinking.GetEnumerator() |
    ForEach-Object { [ordered]@{ "$($_.Key)" = $_.Value } } |
    ConvertTo-Json -Depth 10 |
    Out-File "$TmpOutputDir\Article_Relinking.json"
$RunSummary.SetupInfo.FinishedAt        = $(get-date)
$RunSummary.JobInfo.LinksCreated        = $LinksCreatedCount
$RunSummary.JobInfo.LinksReplaced       = $LinksReplacedCount
$RunSummary.JobInfo.LinksFound          = $LinksFoundCount
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
