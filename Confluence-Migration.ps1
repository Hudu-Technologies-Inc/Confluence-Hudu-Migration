# # Copyright (c) 2025 Hudu Technologies, Inc.
# # All rights reserved.
# #
# # # Redistribution and use of this software in source and binary forms, with or without modification, are permitted under the following conditions:
# #    * Redistributions of source code must retain the above copyright notice, this list of conditions, and the following disclaimer.
# #    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and the following disclaimer in the 
# #      documentation and/or other materials provided with the distribution
# #    * Neither the name of Hudu Technologies nor the names of its contributors may be used to endorse or promote products derived from this software 
# #      without specific prior written permission.
# #
# # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS," WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, 
# # BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL HUDU TECHNOLOGIES 
# # BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT 
# # OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, 
# # EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
# #
# # Authors: Mason Stetler

# # init
# if ($MyInvocation.InvocationName -eq '.') {
#     Write-Host "Script was dot-sourced" -ForegroundColor Green
# } else {
#     Write-Host "Script was executed without dot-sourcing, this is the recommended method of running the script to ensure settings are retained in the session" -ForegroundColor Yellow; write-warning "exiting to prevent issues later on, please dot-source the script by running `. .\yourenvironmentfile.ps1` or `. .\Confluence-Migration.ps1` from powershell 7.5 or later (ideally as Administrator)" -ForegroundColor Red; exit 1;
# }

# # instantiate vars
# $project_workdir=$PSScriptRoot; foreach ($h in @("confluence","general","init")){. "$project_workdir\helpers\$h.ps1"};
# $PowershellVersion = [version](Get-Host).Version; $HuduAppInfo = Get-HuduAppInfo; $CurrentHuduVersion = [version]$HuduAppInfo.version; $articlesEnabled = Get-HuduFeatureAvailability -Core_Feature articles;

# if ($PowershellVersion -lt $requiredPowershellVersion) {Write-Host "PowerShell $requiredPowershellVersion or higher is required. You have $PowershellVersion." -ForegroundColor Red; exit 1;} 
# if ($CurrentHuduVersion -lt [version]$RequiredHuduVersion) {Write-Host "This script requires at least version $RequiredHuduVersion and cannot run with version $CurrentHuduVersion. Please update your version of Hudu."; exit 1;}
# if ($false -eq $articlesEnabled.CentralKB -and $false -eq $articlesEnabled.CompanyKB) {Write-Host "Articles feature is not enabled in Hudu. Exiting script." -ForegroundColor Red; exit 1;}
# $ImageMap = @{}; $ConfluenceToHuduUrlMap = @{}; $Article_Relinking=@{}; $RunSummary=Start-RunSummary; $TrackedAttachments = if ($TrackAttachmentDetails) { [System.Collections.ArrayList]@() } else { $null }; $LinksCreatedCount = 0; $LinksFoundCount = 0; $LinksReplacedCount = 0; $SourcePages = [System.Collections.ArrayList]@(); $destinationChoices = @();
# $Attribution_Options=[System.Collections.ArrayList]@(); $SpaceCompanyMap = @{};

# # Step 1.1- Get spaces and select which or all spaces to get pages from
# PrintAndLog -message  "Getting All Spaces and configuring Source options (Confluence-Side)" -Color Blue
# $AllSpaces=GetAllSpaces -baseUrl $ConfluenceBaseUrl -authHeader "Basic $encodedCreds"
# if ($AllSpaces.Count -eq 0) {
#     PrintAndLog -message  "Sorry, we didnt seem to see any Confluence Spaces! Double-check your credentials and try again." -Color Red
#     exit 1
# } else {try {Set-MigrationRecord} catch {}}
# $allSpacesSourceStrategy = @($ConfluenceSourceStrategies | Where-Object { $_.Identifier -eq 1 } | Select-Object -First 1)[0]
# if ($null -ne $allSpacesSourceStrategy) {$allSpacesSourceStrategy.OptionMessage = "From All ($($AllSpaces.count)) Confluence Space(s)"}
# $multipleSpacesSourceStrategy = @($ConfluenceSourceStrategies | Where-Object { $_.Identifier -eq 2 } | Select-Object -First 1)[0]
# if ($null -ne $multipleSpacesSourceStrategy) {$multipleSpacesSourceStrategy.OptionMessage = "From Multiple Selected Confluence Space(s) (choose from $($AllSpaces.count))"}

# $RunSummary.JobInfo.MigrationSource = Select-ConfluenceSourceStrategy -Strategies $ConfluenceSourceStrategies -NonInteractive $NonInteractive -PreselectedSourceStrategy $preselectedSourceStrategy

# # Step 1- Obtain and record pages/attachments for space(s)
# if ([int]$RunSummary.JobInfo.MigrationSource.Identifier -eq 0) {
#     $SingleChosenSpace = Select-ConfluenceSpace -Spaces $AllSpaces -NonInteractive $NonInteractive -PreselectedSingleSpace $preselectedSingleSpace
#     $RunSummary.JobInfo.Spaces.Add($SingleChosenSpace) | Out-Null
#     $RunSummary.JobInfo.MigrationSource.OptionMessage="$($RunSummary.JobInfo.MigrationSource.OptionMessage) (space: $($SingleChosenSpace.name)/$($SingleChosenSpace.key))"
#     Add-ConfluenceSourcePages -Pages @(GetAllPages -SpaceKey $SingleChosenSpace.key -SpaceName $SingleChosenSpace.name -SpaceId $SingleChosenSpace.id -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl -SkipArchived $SkipArchivedConfluenceContent)
# } elseif ([int]$RunSummary.JobInfo.MigrationSource.Identifier -eq 2) {
#     $SelectedSpaces = Select-ConfluenceSpaces -Spaces $AllSpaces -NonInteractive $NonInteractive -PreselectedSpaces ($preselectedSourceSpaces ?? $env:CONFLUENCE_SOURCE_SPACES)
#     foreach ($space in $SelectedSpaces) {
#         PrintAndLog -message "Obtaining Pages from selected space: $($space.name)/$($space.key)" -Color Blue
#         $RunSummary.JobInfo.Spaces.Add($space) | Out-Null
#         $addedPages = @(GetAllPages -SpaceKey $space.key -SpaceName $space.name -SpaceId $space.id -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl -SkipArchived $SkipArchivedConfluenceContent)
#         Add-ConfluenceSourcePages -Pages $addedPages
#         $addedPages = $null
#     }
#     $RunSummary.JobInfo.MigrationSource.OptionMessage="$($RunSummary.JobInfo.MigrationSource.OptionMessage) (spaces: $((@($SelectedSpaces) | ForEach-Object { "$($_.name)/$($_.key)" }) -join ', '))"
# } else {
#     foreach ($space in $AllSpaces) {
#         PrintAndLog -message "Obtaining Pages from space: $($space.name)/$($space.key)" -Color Blue
#         $RunSummary.JobInfo.Spaces.Add($space) | Out-Null
#         $addedPages = @(GetAllPages -SpaceKey $space.key -SpaceName $space.name -SpaceId $space.id -authHeader "Basic $encodedCreds" -baseUrl $ConfluenceBaseUrl -SkipArchived $SkipArchivedConfluenceContent)
#         Add-ConfluenceSourcePages -Pages $addedPages
#         $addedPages = $null
#     }
# }
# $RunSummary.JobInfo.PagesCount = $SourcePages.count

# if ($RunSummary.JobInfo.PagesCount -eq 0) {
#     PrintAndLog -message  "Sorry, we didnt seem to see any Source Articles/Pages in Confluence! Double-check your credentials and try again." -Color Red
#     exit
# } else {
#     $RunSummary.JobInfo.MigrationSource.OptionMessage="Migrate $($RunSummary.JobInfo.PagesCount) Articles/Pages $($RunSummary.JobInfo.MigrationSource.OptionMessage)"
#     PrintAndLog -message "Elected to $($RunSummary.JobInfo.MigrationSource.OptionMessage)" -Color Yellow
# }

# # Step 2: Present Options for Hudu / Destination
# PrintAndLog -message  "Getting All Companies and configuring destination options (Hudu-Side)" -Color Blue
# $all_companies = @(Get-HuduCompanies | Where-Object { $null -ne $_ })
# $hasCentralKb = $true -eq $articlesEnabled.CentralKB; $hasCompanyKb = $true -eq $articlesEnabled.CompanyKB; $hasCompanies = $all_companies.Count -gt 0;

# if (-not $hasCentralKb -and -not $hasCompanyKb) {Write-Warning "Articles are not enabled for Central KB or Company KB in Hudu. Enable at least one article destination before proceeding."; exit 1;}
# if (-not $hasCompanies) {PrintAndLog -message "$(if ($hasCompanyKb) {"Sorry, we didnt seem to see any Companies set up in Hudu... Existing-company destination options will be limited, but the per-space option can create missing companies automatically."} else {"Sorry, we didnt seem to see any Companies set up in Hudu... If you intend to attribute certain articles to certain companies, enable Company KB and add or create companies first."})" -Color Yellow}

# if ($hasCentralKb) {
#     write-host "Central KB core feature is enabled in Hudu"
#     $centralOptionMessage = "To Global/Central Knowledge Base in Hudu (generalized / non-company-specific)"
#     if (-not $hasCompanies) {
#         $centralOptionMessage += " [no companies in Hudu to designate]"
#     } elseif (-not $hasCompanyKb) {
#         $centralOptionMessage += " [company KB is not enabled in Hudu]"
#     }
#     $destinationChoices += [PSCustomObject]@{
#         OptionMessage = $centralOptionMessage
#         Identifier    = 1
#     }
# } else {
#     write-host "Central KB core feature is not enabled in Hudu, not allowing it as option."
# }

# if ($hasCompanyKb) {
#     write-host "Company KB core feature is enabled in Hudu"
#     if ($true -eq $hasCompanies){
#         $destinationChoices += [PSCustomObject]@{
#             OptionMessage = "To a Single Specific Company in Hudu"
#             Identifier    = 0
#         }
#         $destinationChoices += [PSCustomObject]@{
#             OptionMessage = "To Multiple Companies in Hudu - Let Me Choose for Each article ($(@($all_companies).Count) available destination company choices)"
#             Identifier    = 2
#         }
#     }
#     $destinationChoices += [PSCustomObject]@{
#         OptionMessage = "To One Company Per Confluence Space in Hudu - Match by Space Name, Create Missing Companies"
#         Identifier    = 3
#     }
# } else {
#     write-host "Company KB core feature is not enabled in Hudu, not allowing it as option."
# }

# if ($destinationChoices.Count -eq 0) {Write-Warning "No valid Hudu article destination is available. Company KB and Central KB are not available for this migration."; exit 1;}

# $RunSummary.JobInfo.MigrationDest = Select-HuduDestinationStrategy `
#     -DestinationChoices $destinationChoices `
#     -Message "Configure Destination (Hudu-Side) Options- $($RunSummary.JobInfo.MigrationSource.OptionMessage) to where in Hudu?" `
#     -NonInteractive $NonInteractive `
#     -PreselectedDestinationStrategy $preselectedDestinationStrategy

# if ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 0) {
#     $SingleCompanyChoice = Select-HuduCompany `
#         -Companies $all_companies `
#         -Message "Which company to migrate $($SourcePages.count) articles to?" `
#         -NonInteractive $NonInteractive `
#         -PreselectedCompany $preselectedSingleCompany
#     $Attribution_Options=[PSCustomObject]@{
#         CompanyId            = $SingleCompanyChoice.Id
#         CompanyName          = $SingleCompanyChoice.Name
#         OptionMessage        = "Company Name: $($SingleCompanyChoice.Name), Company ID: $($SingleCompanyChoice.Id)"
#         IsGlobalKB           = $false
# }
#     $RunSummary.JobInfo.MigrationDest.OptionMessage="$($RunSummary.JobInfo.MigrationDest.OptionMessage) (Company Name: $($SingleCompanyChoice.Name), Company ID: $($SingleCompanyChoice.Id))"
# } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 1) {
#     $Attribution_Options+=[PSCustomObject]@{
#         CompanyId            = 0
#         CompanyName          = "Global KB"
#         OptionMessage        = "No Company Attribution (Upload As Global/Central KnowledgeBase Article)"
#         IsGlobalKB           = $true
#     }    
# } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 3) {
#     foreach ($space in $RunSummary.JobInfo.Spaces) {
#         $spaceCompany = Resolve-HuduCompanyForConfluenceSpace -Space $space -Companies @($all_companies)
#         $SpaceCompanyMap[[string]$space.Key] = [PSCustomObject]@{
#             SpaceId              = $space.Id
#             SpaceKey             = $space.Key
#             SpaceName            = $space.Name
#             CompanyId            = $spaceCompany.Id
#             CompanyName          = $spaceCompany.Name
#             OptionMessage        = "Space: $($space.Name) ($($space.Key)) -> Company Name: $($spaceCompany.Name), Company ID: $($spaceCompany.Id)"
#             IsGlobalKB           = $false
#         }
#         if (@($all_companies | Where-Object { $_.Id -eq $spaceCompany.Id }).Count -eq 0) {
#             $all_companies = @($all_companies | Where-Object { $null -ne $_ }) + @($spaceCompany)
#         }
#     }

#     $RunSummary.JobInfo['SpaceCompanyMap'] = @($SpaceCompanyMap.Values)
#     $RunSummary.JobInfo.MigrationDest.OptionMessage="$($RunSummary.JobInfo.MigrationDest.OptionMessage) ($($SpaceCompanyMap.Count) Confluence space(s) mapped)"
# } else {
#     foreach ($company in $all_companies) {
#         $Attribution_Options+=[PSCustomObject]@{
#             CompanyId            = $company.Id
#             CompanyName          = $company.Name
#             OptionMessage        = "Company Name: $($company.Name), Company ID: $($company.Id)"
#             IsGlobalKB           = $false
#         }
#     }
#     if ($hasCentralKb) {
#         $Attribution_Options+=[PSCustomObject]@{
#             CompanyId            = 0
#             CompanyName          = "Global KB"
#             OptionMessage        = "No Company Attribution (Upload As Global/Central KnowledgeBase Article)"
#             IsGlobalKB           = $true
#         }
#     }
#     $Attribution_Options+=[PSCustomObject]@{
#         CompanyId            = -1
#         CompanyName          = "None (SKIP FOR NOW)"
#         OptionMessage        = "Skipped"
#         IsGlobalKB           = $false
#     }
# }

# PrintAndLog -message "You've elected for this migration path: $($RunSummary.JobInfo.MigrationSource.OptionMessage) $($RunSummary.JobInfo.MigrationDest.OptionMessage)." -Color Yellow
# if ($NonInteractive) {} else {Read-Host "Press enter now or CTL+C / Close window to exit now!"}

# # ── TITLE CACHE PRE-PASS ─────────────────────────────────────────────────────
# # Build a lookup of Confluence page ID -> title so Resolve-HuduFolder can
# # identify pages acting as folder containers without extra API calls.
# foreach ($page in $SourcePages) {
#     $script:TitleCache[$page.id] = $page.OriginalTitle
# }
# PrintAndLog "Title cache built: $($script:TitleCache.Count) entries" -Color Cyan

# $script:SpaceHomepageId = if ($SingleChosenSpace) {
#     $spaceDetail = Invoke-RestMethod -Uri "$ConfluenceBaseUrl/api/v2/spaces/$($SingleChosenSpace.Id)" `
#         -Headers @{ Authorization = "Basic $encodedCreds"; Accept = "application/json" }
#     $spaceDetail.homepageId
# } else { $null }
# PrintAndLog "Space homepage ID: $($script:SpaceHomepageId ?? 'none — all-spaces mode or not found')" -Color Cyan


# $RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
# $RunSummary.State="Stubbing articles"
# write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

# $StubbedPages=[System.Collections.ArrayList]@()
# $PageIDX=0
# foreach ($page in $SourcePages) {
#     $PageIDX=$PageIDX+1
#     $completionPercentage = Get-PercentDone -Current $PageIDX -Total $SourcePages.count
#     #Generate articl preview
#     $page.CompanyId = $null
#     if ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 0) {
#         $page.CompanyId = $SingleCompanyChoice.id
#     } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 1) {
#         $page.CompanyId = $null  # global KB
#     } elseif ([int]$RunSummary.JobInfo.MigrationDest.Identifier -eq 3) {
#         $spaceMapKey = [string]$page.SpaceKey
#         $pageDestination = $SpaceCompanyMap[$spaceMapKey]
#         if ($null -eq $pageDestination) {
#             throw "No Hudu company mapping was found for Confluence space key '$spaceMapKey' while migrating page '$($page.title)'."
#         }
#         $page.CompanyId = $pageDestination.CompanyId
#     } else {
#         if ([string]::IsNullOrWhiteSpace($page.articlePreview)) {
#             $previewHtml = Get-MigrationPageHtmlContent -Page $page -Path $page.RawHtmlPath -Default ''
#             $page.articlePreview = Get-ArticlePreviewBlock -Title $page.title -PageId $page.id -Content $previewHtml -MaxLength $RunSummary.SetupInfo.PreviewLength
#             $previewHtml = $null
#         }

#         $pagePrompt = "Migrating Article: $($page.articlePreview)`nSpace: $($page.SpaceKey ?? 'unknown')`nURL: $($page.FullUrl ?? 'not found')`nWhich company to migrate into?"
#         $page.CompanyId = $(Select-ObjectFromList -message $pagePrompt -objects $Attribution_Options).CompanyId
#     }

#     if ($null -ne $page.CompanyId -and $page.CompanyId -eq -1) {
#         printandlog -message "Skipping page/article transfer for $($page.title)" -Color Gray
#         $RunSummary.Warnings+=@{
#             Message     =      "User Elected to skip page/article transfer for $($page.title)"
#             PageSkipped =      "Page with Confluence ID $($page.id), Titled $($page.title) was skipped by user. $($page.FullUrl ?? '')"
#         }
#         $RunSummary.JobInfo.Skipped+=1
#         continue
#     }

#     # Resolve Hudu folder for this page (company-scoped migrations only)
#     $folderId = $null
#     if ($page.parentId) {
#         $folderId = Resolve-HuduFolder `
#             -ParentId   $page.parentId `
#             -ParentType ($page.parentType ?? "page") `
#             -CompanyId  $page.CompanyId `
#             -AuthHeader "Basic $encodedCreds" `
#             -BaseUrl    $ConfluenceBaseUrl
#     }

#     #stub article
#     if ($null -eq $page.CompanyId -or $page.CompanyId -lt 1) {
#         printandlog -message "Stubbing global KB article" -Color yellow
#         $page.stub = New-HuduStubArticle -Title $($page.title) -Content "Migration stub. Final content will be populated after relinking."  -FolderId $folderId
#     } else {
#         printandlog -message "Stubbing KB article for Hudu company ID: $($page.CompanyId), folder: $($folderId ?? 'none')" -Color Yellow
#         $page.stub = New-HuduStubArticle -Title $($page.title) -Content "Migration stub. Final content will be populated after relinking." -CompanyId $($page.CompanyId) -FolderId $folderId
#     }
#     PrintAndLog -message "Article $($page.title) Stubbed with id $($($page.stub).id); $($($page.stub) | ConvertTo-Json -Depth 3)" -Color Green

#     if ($null -eq $page.stub) {
#         $ErrorObject =@{
#             Error="Error Stubbing Article for Confluence page with id - $($page.id), titled $($page.title)"
#         }
#         Write-ErrorObjectsToFile -name "Stub-$($page.title)" -ErrorObject $ErrorObject
#         $RunSummary.Errors.add($ErrorObject)
#         $RunSummary.JobInfo.ArticlesErrored+=1
#         continue
#     }
#     $RunSummary.JobInfo.ArticlesCreated+=1
#     $RunSummary.JobInfo.LinksCreated+=1
#     $LinksCreatedCount+=1
#     foreach ($baseLink in $page.BaseLinks) {
#         $ConfluenceToHuduUrlMap[$baseLink] = $page.stub.url
#     }
#     [void]$StubbedPages.Add($page)
#     $articleId = [string]$page.stub.id
#     $Article_Relinking[$articleId]=[PSCustomObject]@{
#         HuduArticle           = $page.stub
#         Page                  = $page
#         ContentPath           = $null
#         FinalContentPath      = $null
#         LinkCount             = $page.LinksCount
#         DestinationBatchKey   = Get-MigrationDestinationBatchKey -Page $page
#         DestinationBatchLabel = Get-MigrationDestinationBatchLabel -Page $page
#     }
#     Write-Progress -Activity "Stubbing $($page.title)" -Status "$completionPercentage%" -PercentComplete $completionPercentage
# }

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
            -SchemaMatchThreshold $ConfluenceTableSchemaMatchThreshold `
            -UseTitleGrouping $ConfluenceTableTitleGrouping `
            -TitleCategoryMatchThreshold $ConfluenceTableTitleMatchThreshold

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

# $RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"
# $RunSummary.State="Processing articles by destination"
# write-host "Part $($RunSummary.CompletedStates.count): $($RunSummary.State)" -ForegroundColor Magenta

# $DestinationBatches = @(Get-MigrationDestinationBatches -Pages @($StubbedPages))
# $RelinkIndex = New-MigrationRelinkIndex -Relinking $Article_Relinking
# Write-MigrationRelinkCheckpoint -Relinking $Article_Relinking -Path "$TmpOutputDir\Article_Relinking.json"
# $ConfluenceToHuduUrlMap | ConvertTo-Json -Depth 5 | Out-File "$TmpOutputDir\UrlMap.json"
# PrintAndLog -message "Processing $($StubbedPages.Count) stubbed article(s) in $($DestinationBatches.Count) destination batch(es). Referenced-title relinking: $RelinkReferencedTitleText. All-title fallback: $RelinkAllTitleText." -Color Cyan

# $BatchIDX = 0
# $TotalProcessedPages = 0
# foreach ($batch in $DestinationBatches) {
#     $BatchIDX += 1
#     $batchPages = @($batch.Pages)
#     $batchPercent = Get-PercentDone -Current $BatchIDX -Total $DestinationBatches.Count

#     Write-Progress -Id 1 -Activity "Processing destination batches" -Status "$($batch.Label) ($BatchIDX of $($DestinationBatches.Count))" -PercentComplete $batchPercent
#     PrintAndLog -message "Starting destination batch $BatchIDX of $($DestinationBatches.Count): $($batch.Label) ($($batchPages.Count) article(s))" -Color Magenta

#     $PageIDX = 0
#     foreach ($page in $batchPages) {
#         $PageIDX += 1
#         $TotalProcessedPages += 1
#         $pagePercent = Get-PercentDone -Current $PageIDX -Total $batchPages.Count
#         $articleId = [string]$page.stub.id
#         $entry = $Article_Relinking[$articleId]

#         Write-Progress -Id 2 -ParentId 1 -Activity "Processing $($batch.Label)" -Status "$PageIDX of $($batchPages.Count): $($page.title)" -PercentComplete $pagePercent

#         if ($null -eq $entry) {
#             $ErrorInfo = @{
#                 Message = "Missing relink entry for article id $articleId"
#                 Page    = "Confluence page with Id $($page.id), titled $($page.title)- $($page.FullUrl ?? '')"
#             }
#             $RunSummary.Errors.add($ErrorInfo) | Out-Null
#             $RunSummary.JobInfo.ArticlesErrored += 1
#             Write-ErrorObjectsToFile -name "missing-relink-$($page.title)" -ErrorObject $ErrorInfo
#             continue
#         }

#         $pageImageMap = $null
#         try {
#             $pageImageMap = Invoke-MigrationPageAttachmentProcessing -Page $page -ProgressParentId 2
#             if ($null -eq $pageImageMap -or $pageImageMap -isnot [hashtable]) {
#                 $pageImageMap = @{}
#             }

#             if ($pageImageMap.Count -gt 0) {
#                 $pageImageMap | ConvertTo-Json -Depth 5 | Out-File "$TmpOutputDir\ImageMap-$($page.title).json"
#             }

#             $entry.ContentPath = Invoke-MigrationPageContentPreparation -Page $page -ImageMap $pageImageMap
#             Write-MigrationPageCheckpoint -Page $page -Path "$TmpOutputDir\wip-page-$($page.title).json"

#             [void](Invoke-MigrationPageRelinkAndFinalize `
#                 -ArticleId $articleId `
#                 -Entry $entry `
#                 -RelinkIndex $RelinkIndex `
#                 -UrlMap $ConfluenceToHuduUrlMap `
#                 -RelinkReferencedTitleText $RelinkReferencedTitleText `
#                 -RelinkAllTitleText $RelinkAllTitleText)

#             Write-MigrationPageCheckpoint -Page $page -Path "$TmpOutputDir\completed-page-$($page.title).json"
#         } catch {
#             $ErrorInfo = @{
#                 Message    = "Error processing article batch item: $($page.title)"
#                 Error      = $_
#                 HuduArticle = $entry.HuduArticle
#                 Page       = "Confluence page with Id $($page.id), titled $($page.title)- $($page.FullUrl ?? '')"
#                 ArticleURL = $($page.stub.url ?? "URL not found")
#             }
#             $RunSummary.Errors.add($ErrorInfo) | Out-Null
#             $RunSummary.JobInfo.ArticlesErrored += 1
#             Write-ErrorObjectsToFile -name "batcharticle-$($page.title)" -ErrorObject $ErrorInfo
#         } finally {
#             $pageImageMap = $null
#             try {
#                 if ($page.PSObject.Properties['attachments']) {
#                     $page.attachments = $null
#                 }
#             } catch {}

#             Clear-MigrationPageHtmlMemory -Page $page

#             if (($TotalProcessedPages % 10) -eq 0) {
#                 Write-MigrationRelinkCheckpoint -Relinking $Article_Relinking -Path "$TmpOutputDir\Article_Relinking.json"
#                 Invoke-MigrationMemoryCleanup
#             }
#         }
#     }

#     Write-Progress -Id 2 -ParentId 1 -Activity "Processing $($batch.Label)" -Completed
#     Write-MigrationRelinkCheckpoint -Relinking $Article_Relinking -Path "$TmpOutputDir\Article_Relinking.json"
#     Invoke-MigrationMemoryCleanup
# }

# Write-Progress -Id 1 -Activity "Processing destination batches" -Completed
# $RunSummary.CompletedStates += "$($RunSummary.State) finished in $($($(Get-Date) - $RunSummary.SetupInfo.StartedAt).ToString())"

# # Final step - Wrap up
# Write-Host "Calculating results, please wait." -ForegroundColor cyan
# Write-MigrationRelinkCheckpoint -Relinking $Article_Relinking -Path "$TmpOutputDir\Article_Relinking.json"
# $RunSummary.SetupInfo.FinishedAt        = $(get-date)
# $RunSummary.JobInfo.LinksCreated        = $LinksCreatedCount
# $RunSummary.JobInfo.LinksReplaced       = $LinksReplacedCount
# $RunSummary.JobInfo.LinksFound          = $LinksFoundCount
# $RunSummary.SetupInfo.RunDuration       = $($RunSummary.SetupInfo.FinishedAt - $RunSummary.SetupInfo.StartedAt).ToString()
# $RunSummary.CompletedStates += "finished in $($RunSummary.SetupInfo.RunDuration)"
# $RunSummary.State="Finished"

# $ConfluenceToHuduUrlMap | ConvertTo-Json -Depth 15 | Out-File "$TmpOutputDir\UrlMap.json"
# foreach ($varname in @("encodedCreds","HuduAPIKey","ConfluenceToken")) {
#     remove-variable -name varname -Force -ErrorAction SilentlyContinue
# }
# # Serialize summary JSON
# $SummaryJson = $RunSummary | ConvertTo-Json -Depth 15

# # Nicely print a cleaned-up version to the console
# $SummaryJson -split "`n" | ForEach-Object {
#     $_ -replace '[\{\[]', '⤵' `
#        -replace '[\}\]]', '' `
#        -replace '",', '"' `
#        -replace '^', '  '
# }
# $SummaryJson | ConvertTo-Json -Depth 15 | Out-File "$(join-path $LogsDir -ChildPath "job-summary.json")"

# # Print final state summary
# Write-Host "$($RunSummary.CompletedStates.Count): $($RunSummary.State) in $($RunSummary.SetupInfo.RunDuration) with $($RunSummary.Errors.Count) errors and $($RunSummary.Warnings.Count) warnings" -ForegroundColor Magenta
