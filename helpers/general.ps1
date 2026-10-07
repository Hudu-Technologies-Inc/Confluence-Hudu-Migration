
function Get-EnsuredPath {
    param([string]$path)
    $outpath = if (-not $path -or [string]::IsNullOrWhiteSpace($path)) { $(join-path $(Resolve-Path .).path "debug") } else {$path}
    if (-not (Test-Path $outpath)) {
        Get-ChildItem -Path "$outpath" -File -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force
        New-Item -ItemType Directory -Path $outpath -Force -ErrorAction Stop | Out-Null
        write-host "path is now present: $outpath"
    } else {write-host "path is present: $outpath"}
    return $outpath
}


function Write-ErrorObjectsToFile {
    param (
        [Parameter(Mandatory)]
        [object]$ErrorObject,

        [Parameter()]
        [string]$Name = "unnamed",

        [Parameter()]
        [ValidateSet("Black","DarkBlue","DarkGreen","DarkCyan","DarkRed","DarkMagenta","DarkYellow","Gray","DarkGray","Blue","Green","Cyan","Red","Magenta","Yellow","White")]
        [string]$Color
    )

    $stringOutput = try {
        $ErrorObject | Format-List -Force | Out-String
    } catch {
        "Failed to stringify object: $_"
    }

    $propertyDump = try {
        $props = $ErrorObject | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name
        $lines = foreach ($p in $props) {
            try {
                "$p = $($ErrorObject.$p)"
            } catch {
                "$p = <unreadable>"
            }
        }
        $lines -join "`n"
    } catch {
        "Failed to enumerate properties: $_"
    }

    $logContent = @"
==== OBJECT STRING ====
$stringOutput

==== PROPERTY DUMP ====
$propertyDump
"@

    if ($ErroredItemsFolder -and (Test-Path $ErroredItemsFolder)) {
        $SafeName = ($Name -replace '[\\/:*?"<>|]', '_') -replace '\s+', ''
        if ($SafeName.Length -gt 60) {
            $SafeName = $SafeName.Substring(0, 60)
        }
        $filename = "${SafeName}_error_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        $fullPath = Join-Path $ErroredItemsFolder $filename
        Set-Content -Path $fullPath -Value $logContent -Encoding UTF8
        if ($Color) {
            Write-Host "Error written to $fullPath" -ForegroundColor $Color
        } else {
            Write-Host "Error written to $fullPath"
        }
    }

    if ($Color) {
        Write-Host "$logContent" -ForegroundColor $Color
    } else {
        Write-Host "$logContent"
    }
}


function Get-HtmlSnapshotPath {
    param (
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Suffix,
        [Parameter(Mandatory)][string]$OutDir
    )

    $safeTitle = ($Title -replace '[^\w\d\-]', '_') -replace '_+', '_'
    $filename = "${PageId}_${safeTitle}_${Suffix}.html"
    return (Join-Path -Path $OutDir -ChildPath $filename)
}

function Save-MigrationHtmlContent {
    param (
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][string]$Content,
        [Parameter(Mandatory)][string]$Suffix,
        [Parameter(Mandatory)][string]$OutDir
    )

    $path = Get-HtmlSnapshotPath -PageId $PageId -Title $Title -Suffix $Suffix -OutDir $OutDir
    try {
        [System.IO.File]::WriteAllText(
            $path,
            ($Content ?? ''),
            [System.Text.UTF8Encoding]::new($false)
        )
        return $path
    } catch {
        Write-ErrorObjectsToFile -Name "$($_.safeTitle ?? "unnamed")" -ErrorObject @{
            Error       = $_
            PageId      = $PageId 
            ContentLength = if ($null -ne $Content) { $Content.Length } else { 0 }
            Message     ="Error Saving HTML Content"
            OutDir      = $OutDir
        }
    }
}

function Save-HtmlSnapshot {
    param (
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Suffix,
        [Parameter(Mandatory)][string]$OutDir
    )

    $path = Save-MigrationHtmlContent -PageId $PageId -Title $Title -Content $Content -Suffix $Suffix -OutDir $OutDir
    if ($path) {
        Write-Host "Saved HTML snapshot: $path"
    }
}

function Get-MigrationPageHtmlContent {
    param (
        [object]$Page,
        [string]$Path,
        [string]$Default = "No Content Found in Confluence Page"
    )

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }

    foreach ($propertyName in @('htmlContent','rawContent','updatedHtml')) {
        if ($null -ne $Page -and $Page.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace($Page.$propertyName)) {
            return $Page.$propertyName
        }
    }

    if ($null -ne $Page -and $Page.body -and $Page.body.storage -and -not [string]::IsNullOrWhiteSpace($Page.body.storage.value)) {
        return $Page.body.storage.value
    }

    return $Default
}

function Clear-MigrationPageHtmlMemory {
    param([object]$Page)

    if ($null -eq $Page) { return }

    foreach ($propertyName in @('htmlContent','rawContent','updatedHtml')) {
        if ($Page.PSObject.Properties[$propertyName]) {
            $Page.$propertyName = $null
        }
    }

    try {
        if ($Page.body -and $Page.body.storage -and $Page.body.storage.PSObject.Properties['value']) {
            $Page.body.storage.value = $null
        }
    } catch {}
}

function Invoke-MigrationMemoryCleanup {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
}
function Get-PercentDone {
    param (
        [int]$Current,
        [int]$Total
    )
    if ($Total -eq 0) {
        return 100}
    $percentDone = ($Current / $Total) * 100
    if ($percentDone -gt 100){
        return 100
    }
    $rounded = [Math]::Round($percentDone, 2)
    return $rounded
}   
function PrintAndLog {
    param (
        [string]$message,

        [Parameter()]
        [ValidateSet("Black","DarkBlue","DarkGreen","DarkCyan","DarkRed","DarkMagenta","DarkYellow","Gray","DarkGray","Blue","Green","Cyan","Red","Magenta","Yellow","White")]
        [string]$Color
    )

    $logline = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $message"

    if ($Color) {
        Write-Host $logline -ForegroundColor $Color
    } else {
        Write-Host $logline
    }

    Add-Content -Path $LogFile -Value $logline
}
function Write-InspectObject {
    param (
        [object]$object,
        [int]$Depth = 32,
        [int]$MaxLines = 16
    )

    $stringifiedObject = $null

    if ($null -eq $object) {
        return "Unreadable Object (null input)"
    }
    # Try JSON
    $stringifiedObject = try {
        $json = $object | ConvertTo-Json -Depth $Depth -ErrorAction Stop
        "# Type: $($object.GetType().FullName)`n$json"
    } catch { $null }

    # Try Format-Table
    if (-not $stringifiedObject) {
        $stringifiedObject = try {
            $object | Format-Table -Force | Out-String
        } catch { $null }
    }

    # Try Format-List
    if (-not $stringifiedObject) {
        $stringifiedObject = try {
            $object | Format-List -Force | Out-String
        } catch { $null }
    }

    # Fallback to manual property dump
    if (-not $stringifiedObject) {
        $stringifiedObject = try {
            $props = $object | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name
            $lines = foreach ($p in $props) {
                try {
                    "$p = $($object.$p)"
                } catch {
                    "$p = <unreadable>"
                }
            }
            "# Type: $($object.GetType().FullName)`n" + ($lines -join "`n")
        } catch {
            "Unreadable Object"
        }
    }

    if (-not $stringifiedObject) {
        $stringifiedObject =  try {"$($($object).ToString())"} catch {$null}
    }
    # Truncate to max lines if necessary
    $lines = $stringifiedObject -split "`r?`n"
    if ($lines.Count -gt $MaxLines) {
        $lines = $lines[0..($MaxLines - 1)] + "... (truncated)"
    }

    return $lines -join "`n"
}

function Select-ObjectFromList($objects, $message, $inspectObjects = $false, $allowNull = $false, $nullLabel = "None/Custom") {
    $objects = @($objects)
    $shouldSortObjects = $objects.Count -gt 1 -and -not ($objects | Where-Object { $_ -is [string] -or $_ -is [ValueType] }) -and -not ($objects | Where-Object { $null -ne $_.Identifier })
    if ($shouldSortObjects) {
        $objects = @($objects | Sort-Object -Property @{
            Expression = {
                if ($null -ne $_.OptionMessage) {
                    "$($_.OptionMessage)"
                } elseif (-not [string]::IsNullOrEmpty($_.attributes.name)) {
                    "$($_.attributes.name)"
                } elseif (-not [string]::IsNullOrEmpty($_.name)) {
                    "$($_.name)"
                } else {
                    "$_"
                }
            }
        })
    }

    $validated = $false
    while (-not $validated) {
        if ($allowNull) { Write-Host "0: $nullLabel" }

        for ($i = 0; $i -lt $objects.Count; $i++) {
            $object = $objects[$i]
            $displayLine = if ($inspectObjects) {
                "$($i+1): $(Write-InspectObject -object $object)"
            } elseif ($null -ne $object.OptionMessage) {
                "$($i+1): $($object.OptionMessage)"
            } elseif (-not $([string]::IsNullOrEmpty($object.attributes.name))) {
                "$($i+1): $($object.attributes.name)"
            } elseif (-not $([string]::IsNullOrEmpty($object.name))) {
                "$($i+1): $($object.name)"
            } else {
                "$($i+1): $($object)"
            }
            Write-Host $displayLine -ForegroundColor $(if ($i % 2 -eq 0) { 'Cyan' } else { 'Yellow' })
        }

        $raw = Read-Host $message

        $parsed = 0
        if (-not [int]::TryParse($raw, [ref]$parsed)) {
            Write-Host "Invalid input. Please enter a number." -ForegroundColor Red
            continue
        }

        if ($parsed -eq 0 -and $allowNull) { return $null }

        if ($parsed -ge 1 -and $parsed -le $objects.Count) {
            return $objects[$parsed - 1]
        } else {
            Write-Host "Invalid selection. Please enter a number from the list." -ForegroundColor Red
        }
    }
}

function Select-ObjectsFromList {
    param(
        [Parameter(Mandatory)][object[]]$Objects,
        [Parameter(Mandatory)][string]$Message,
        [string]$DoneLabel = "Done selecting",
        [bool]$InspectObjects = $false,
        [string[]]$UniqueProperties = @('Id','Key','Name')
    )

    $selected = [System.Collections.ArrayList]@()
    $selectedKeys = @{}
    $available = @($Objects | Where-Object { $null -ne $_ })

    function Get-SelectionKey {
        param([object]$Object)

        foreach ($property in $UniqueProperties) {
            if ($Object.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace("$($Object.$property)")) {
                return "$property`:$($Object.$property)"
            }
        }

        return "$Object"
    }

    while ($true) {
        $remaining = @($available | Where-Object {
            -not $selectedKeys.ContainsKey((Get-SelectionKey -Object $_))
        })

        if ($remaining.Count -eq 0) {
            return $selected
        }

        $prompt = if ($selected.Count -gt 0) {
            "$Message Selected: $($selected.Count). Choose another, or 0 to finish."
        } else {
            "$Message Choose at least one item, or 0 when done."
        }

        $choice = Select-ObjectFromList -Objects $remaining -Message $prompt -inspectObjects $InspectObjects -allowNull $true -nullLabel $DoneLabel
        if ($null -eq $choice) {
            if ($selected.Count -gt 0) {
                return $selected
            }

            Write-Host "Please select at least one item before finishing." -ForegroundColor Yellow
            continue
        }

        $key = Get-SelectionKey -Object $choice
        if (-not $selectedKeys.ContainsKey($key)) {
            $selectedKeys[$key] = $true
            [void]$selected.Add($choice)
            Write-Host "Selected: $(Get-SelectableObjectLabel -Object $choice)" -ForegroundColor Green
        }
    }
}

function Get-SelectableObjectLabel {
    param([object]$Object)

    if ($null -eq $Object) { return "" }
    if ($null -ne $Object.OptionMessage) { return "$($Object.OptionMessage)" }
    if (-not [string]::IsNullOrEmpty($Object.attributes.name)) { return "$($Object.attributes.name)" }
    if (-not [string]::IsNullOrEmpty($Object.name)) { return "$($Object.name)" }
    if (-not [string]::IsNullOrEmpty($Object.Name)) { return "$($Object.Name)" }
    if (-not [string]::IsNullOrEmpty($Object.key)) { return "$($Object.key)" }
    if (-not [string]::IsNullOrEmpty($Object.Key)) { return "$($Object.Key)" }
    return "$Object"
}

function Select-ConfiguredObjectFromList {
    param(
        [Parameter(Mandatory)][object[]]$Objects,
        [Parameter(Mandatory)][string]$Message,
        [bool]$NonInteractive = $false,
        [object]$PreselectedIdentifier = $null,
        [string[]]$IdentifierProperties = @('Identifier'),
        [object]$DefaultIdentifier = $null,
        [bool]$AutoSelectSingle = $true,
        [string]$SelectionName = "selection",
        [bool]$AllowNull = $false,
        [bool]$InspectObjects = $false
    )

    $Objects = @($Objects | Where-Object { $null -ne $_ })

    if ($Objects.Count -eq 0) {
        if ($AllowNull) { return $null }
        throw "No valid options are available for $SelectionName."
    }

    $hasPreselectedIdentifier = $null -ne $PreselectedIdentifier -and -not [string]::IsNullOrWhiteSpace("$PreselectedIdentifier")
    $preselectedIdentifierIsInvalid = $false

    if ($NonInteractive -and $hasPreselectedIdentifier) {
        $wanted = "$PreselectedIdentifier".Trim()
        $matches = @($Objects | Where-Object {
            $object = $_
            @($IdentifierProperties | Where-Object {
                $property = $_
                $null -ne $object.$property -and "$($object.$property)".Trim() -ieq $wanted
            }).Count -gt 0
        })

        if ($matches.Count -eq 1) {
            PrintAndLog -message "Using preselected $SelectionName`: $(Get-SelectableObjectLabel -Object $matches[0])" -Color Cyan
            return $matches[0]
        }

        if ($matches.Count -gt 1) {
            PrintAndLog -message "Preselected $SelectionName '$wanted' matched multiple options; falling back to interactive selection." -Color Yellow
        } else {
            PrintAndLog -message "Preselected $SelectionName '$wanted' is not valid for the available options; falling back to interactive selection." -Color Yellow
        }
        $preselectedIdentifierIsInvalid = $true
    }

    if ($NonInteractive -and -not $preselectedIdentifierIsInvalid -and $null -ne $DefaultIdentifier -and -not [string]::IsNullOrWhiteSpace("$DefaultIdentifier")) {
        $wantedDefault = "$DefaultIdentifier".Trim()
        $defaultMatches = @($Objects | Where-Object {
            $object = $_
            @($IdentifierProperties | Where-Object {
                $property = $_
                $null -ne $object.$property -and "$($object.$property)".Trim() -ieq $wantedDefault
            }).Count -gt 0
        })

        if ($defaultMatches.Count -eq 1) {
            PrintAndLog -message "Noninteractive mode selected default $SelectionName`: $(Get-SelectableObjectLabel -Object $defaultMatches[0])" -Color Cyan
            return $defaultMatches[0]
        }
    }

    if ($NonInteractive -and -not $preselectedIdentifierIsInvalid -and $AutoSelectSingle -and $Objects.Count -eq 1) {
        PrintAndLog -message "Noninteractive mode selected the only available $SelectionName`: $(Get-SelectableObjectLabel -Object $Objects[0])" -Color Cyan
        return $Objects[0]
    }

    return Select-ObjectFromList -Objects $Objects -Message $Message -inspectObjects $InspectObjects -allowNull $AllowNull
}

function Select-ConfluenceSourceStrategy {
    param(
        [Parameter(Mandatory)][object[]]$Strategies,
        [bool]$NonInteractive = $false,
        [object]$PreselectedSourceStrategy = $null
    )

    return Select-ConfiguredObjectFromList `
        -Objects $Strategies `
        -Message "Configure Source (Confluence-Side) Options from Confluence- Migrate pages from which Space(s)?" `
        -NonInteractive $NonInteractive `
        -PreselectedIdentifier $PreselectedSourceStrategy `
        -IdentifierProperties @('Identifier') `
        -DefaultIdentifier 1 `
        -SelectionName "Confluence source strategy"
}

function Select-ConfluenceSpace {
    param(
        [Parameter(Mandatory)][object[]]$Spaces,
        [bool]$NonInteractive = $false,
        [object]$PreselectedSingleSpace = $null
    )

    return Select-ConfiguredObjectFromList `
        -Objects $Spaces `
        -Message "From which single space would you like to migrate pages from?" `
        -NonInteractive $NonInteractive `
        -PreselectedIdentifier $PreselectedSingleSpace `
        -IdentifierProperties @('Key','Name','Id') `
        -AutoSelectSingle $false `
        -SelectionName "Confluence single space"
}

function Select-ConfluenceSpaces {
    param(
        [Parameter(Mandatory)][object[]]$Spaces,
        [bool]$NonInteractive = $false,
        [object]$PreselectedSpaces = $null
    )

    $Spaces = @($Spaces | Where-Object { $null -ne $_ })
    if ($Spaces.Count -eq 0) {
        throw "No Confluence spaces are available for selection."
    }

    $hasPreselectedSpaces = $null -ne $PreselectedSpaces -and -not [string]::IsNullOrWhiteSpace("$PreselectedSpaces")
    if ($NonInteractive -and $hasPreselectedSpaces) {
        $wantedValues = @(
            if ($PreselectedSpaces -is [array]) {
                $PreselectedSpaces
            } else {
                "$PreselectedSpaces" -split '[,;]'
            }
        ) | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $selected = [System.Collections.ArrayList]@()
        $seen = @{}
        foreach ($wanted in $wantedValues) {
            $matches = @($Spaces | Where-Object {
                "$($_.Key)" -ieq $wanted -or "$($_.Name)" -ieq $wanted -or "$($_.Id)" -ieq $wanted
            })

            if ($matches.Count -eq 0) {
                throw "Preselected Confluence space '$wanted' did not match any available spaces."
            }

            foreach ($match in $matches) {
                $key = if (-not [string]::IsNullOrWhiteSpace("$($match.Id)")) { "$($match.Id)" } else { "$($match.Key)" }
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    [void]$selected.Add($match)
                }
            }
        }

        if ($selected.Count -gt 0) {
            PrintAndLog -message "Using preselected Confluence spaces: $((@($selected) | ForEach-Object { Get-SelectableObjectLabel -Object $_ }) -join ', ')" -Color Cyan
            return $selected
        }
    }

    if ($NonInteractive) {
        throw "Multiple Confluence source spaces require preselected spaces in noninteractive mode. Set `$preselectedSourceSpaces or CONFLUENCE_SOURCE_SPACES to a comma-separated list of space keys, names, or ids."
    }

    return Select-ObjectsFromList `
        -Objects $Spaces `
        -Message "Select Confluence source spaces." `
        -DoneLabel "Done selecting spaces" `
        -UniqueProperties @('Id','Key','Name')
}

function Select-HuduDestinationStrategy {
    param(
        [Parameter(Mandatory)][object[]]$DestinationChoices,
        [Parameter(Mandatory)][string]$Message,
        [bool]$NonInteractive = $false,
        [object]$PreselectedDestinationStrategy = $null
    )

    $preselected = $PreselectedDestinationStrategy
    if ($NonInteractive -and $null -ne $preselected -and "$preselected".Trim() -eq "2") {
        PrintAndLog -message "Preselected destination strategy 2 requires per-article choices and cannot run unattended; falling back to interactive destination selection." -Color Yellow
        return Select-ObjectFromList -Objects $DestinationChoices -Message $Message -allowNull $false
    }

    return Select-ConfiguredObjectFromList `
        -Objects $DestinationChoices `
        -Message $Message `
        -NonInteractive $NonInteractive `
        -PreselectedIdentifier $preselected `
        -IdentifierProperties @('Identifier') `
        -SelectionName "Hudu destination strategy"
}

function Select-HuduCompany {
    param(
        [Parameter(Mandatory)][object[]]$Companies,
        [Parameter(Mandatory)][string]$Message,
        [bool]$NonInteractive = $false,
        [object]$PreselectedCompany = $null
    )

    return Select-ConfiguredObjectFromList `
        -Objects $Companies `
        -Message $Message `
        -NonInteractive $NonInteractive `
        -PreselectedIdentifier $PreselectedCompany `
        -IdentifierProperties @('Id','Name','Slug') `
        -SelectionName "Hudu company"
}
function Get-YesNoResponse($message) {
    do {
        $response = Read-Host "$message (y/n)"
        $response = if($null -ne $response) {$response.ToLower()} else {""}
        if ($response -eq 'y' -or $response -eq 'yes') {
            return $true
        } elseif ($response -eq 'n' -or $response -eq 'no') {
            return $false
        } else {
            PrintAndLog -message "Invalid input. Please enter 'y' for Yes or 'n' for No."
        }
    }
    while ($true)
}
function Start-RunSummary {
    return @{
    State="Set-Up"
    CompletedStates=@()
    SetupInfo=@{
        HuduDestination     = $HuduBaseUrl
        HuduMaxContentLength= 196000
        ConfluenceSource    = $ConfluenceBaseUrl
        HuduVersion         = [version]$HuduAppInfo.version
        PowershellVersion   = [version]$PowershellVersion
        project_workdir     = $project_workdir
        NonInteractive      = $NonInteractive
        TableExportEnabled  = $ExportConfluenceTables
        TableExportSchemaMatchThreshold = $ConfluenceTableSchemaMatchThreshold
        SkipArchivedConfluenceContent = $SkipArchivedConfluenceContent
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
}

function Get-ArticlePreviewBlock {
    param (
        [string]$Title,
        [string]$PageId,
        [string]$Content,
        [int]$MaxLength = 200
    )
    $descriptor = "ID: $PageId, titled $Title"
    $Content = $Content ?? ''
    $snippet = if ($Content.Length -gt $MaxLength) {
        $Content.Substring(0, $MaxLength) + "..."
    } else {
        $Content
    }

@"
Mapping Confluence Page $descriptor ---
Title: $Title
Snippet: $snippet
"@
}
function Write-TimedMessage {
    Param(
        [string]$Message,
        [string]$DefaultResponse,
        [int]$Timeout = 0  # Optional timeout in seconds for non-interactive mode
    )

    # Check non-interactive mode
    if ($NonInteractive -eq $true) {
        if ($Timeout -gt 0) {
            $TimeoutStatement = "- Waiting for $Timeout seconds due to noninteractive mode. Control + c now if you do not wish to continue."
        } else {
            $TimeoutStatement = ""
        }
        if ($DefaultResponse -eq $null -or $DefaultResponse -eq ""){
            $DefaultResponse="Proceeding"
        }

        if ($null -eq $DefaultResponse) {
            Write-Host "$Message $TimeoutStatement"
        } else {
            Write-Host "$Message $TimeoutStatement - Noninteractive mode. Assuming response of ($DefaultResponse) after timeout."
        }

        # Apply timeout if specified
        if ($Timeout -gt 0) {
            Start-Sleep -Seconds $Timeout
        }

        return $DefaultResponse
    } else {
        # Interactive mode
        return Read-Host -Prompt $Message
    }
}
function Get-LinksFromHTML {
    param (
        [string]$htmlContent,
        [string]$title,
        [bool]$includeImages = $true,
        [bool]$suppressOutput = $false

    )

    $allLinks = [System.Collections.ArrayList]@()

    # Match all href attributes inside anchor tags
    $hrefPattern = '<a\s[^>]*?href=["'']([^"'']+)["'']'
    $hrefMatches = [regex]::Matches($htmlContent, $hrefPattern, 'IgnoreCase')
    foreach ($match in $hrefMatches) {
        [void]$allLinks.Add($match.Groups[1].Value)
    }

    if ($includeImages) {
        # Match all src attributes inside img tags
        $srcPattern = '<img\s[^>]*?src=["'']([^"'']+)["'']'
        $srcMatches = [regex]::Matches($htmlContent, $srcPattern, 'IgnoreCase')
        foreach ($match in $srcMatches) {
            [void]$allLinks.Add($match.Groups[1].Value)
        }
    }
    if ($false -eq $suppressOutput){
        $linkidx=0
        foreach ($link in $allLinks) {
            $linkidx=$linkidx+1
            PrintAndLog -message "link $linkidx of $($allLinks.count) total found for $title - $link" -Color Blue
        }
    }

    return $allLinks | Sort-Object -Unique
}
function Get-SafeFilename {
    param([string]$Name,
        [int]$MaxLength=100
    )

    # If there's a '?', take only the part before it
    $BaseName = $Name -split '\?' | Select-Object -First 1

    # Extract extension (including the dot), if present
    $Extension = [System.IO.Path]::GetExtension($BaseName)
    $NameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($BaseName)

    # Sanitize name and extension
    $SafeName = $NameWithoutExt -replace '[\\\/:*?"<>|]', '_'
    $SafeExt = $Extension -replace '[\\\/:*?"<>|]', '_'

    # Truncate base name to 25 chars
    if ($SafeName.Length -gt $MaxLength) {
        $SafeName = $SafeName.Substring(0, $MaxLength)
    }

    return "$SafeName$SafeExt"
}




function Set-ReleaseArtifact {
    Remove-Item -Path "$($(get-childitem -path "." -Recurse -Directory "artifacts" | Select-Object -first 1).fullname)\*.txt" -Force -ErrorAction SilentlyContinue
    Get-GitCheckoutInfo | Out-File "$($(get-childitem -path "." -Recurse -Directory "artifacts" | Select-Object -first 1).fullname)\$($(Get-Date -Format o | ForEach-Object { $_ -replace ":", "." })).txt" -Encoding utf8
}
function Get-ReleaseArtifact {
    $artifact = (Get-ChildItem -Path "." -Recurse -Directory "artifacts" | Select-Object -First 1 | Get-ChildItem -Filter "*.txt" | Select-Object -First 1)
    if (-not $(test-path $artifact.FullName)) {
        return $null
    }
    return "$(Get-Content -Path $artifact.FullName)"
}

function Get-GitCheckoutInfo {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path
    )
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return ($(Get-ReleaseArtifact) ?? "No Git installation found, cannot discern checkout info")
    }
    Push-Location -LiteralPath $Path
    try {
        $insideRepo = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0 -or $insideRepo -ne 'true') {
            return "Not inside a Git repository"
        }
        $commit = git rev-parse HEAD 2>$null
        $branch = git branch --show-current 2>$null
        if ([string]::IsNullOrWhiteSpace($branch)) {
            $branch = '(detached HEAD)'
        }
        $remoteUrl = git remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0) {
            $remoteUrl = $null
        }
        return "using commit $commit from branch $branch of repo $remoteUrl"
    }
    finally {
        Pop-Location
    }
}

function Set-MigrationRecord {
    [CmdletBinding()]
    param(
        [string]$HuduBaseUrl = $(Get-HuduBaseURL),
        [securestring]$HuduApiKey = $(Get-HuduApiKey),
        [string]$CheckOutinfo = $(Get-GitCheckoutInfo),
        [bool]$selfService = $([bool]::Parse(($env:selfservicemigration ?? "true"))),
        [string]$product = "Confluence"

    )
    $response = $null
    $resolvedBaseUrl = $null
    $resolvedApiKey = $null
    $requestUri = $null

    try {
        if ([string]::IsNullOrWhiteSpace($HuduBaseUrl)) {
            throw "Hudu base URL is not set."
        }

        if ($null -eq $HuduApiKey) {
            throw "Hudu API key is not set."
        }

        $resolvedBaseUrl = $HuduBaseUrl.TrimEnd('/')
        $resolvedApiKey = (New-Object PSCredential 'user', $HuduApiKey).GetNetworkCredential().Password

        if ([string]::IsNullOrWhiteSpace($resolvedApiKey)) {
            throw "Resolved Hudu API key is empty."
        }
        $requestBody = @{
            product = $product
            self_service = $selfService
            version = $CheckOutinfo
        }
        $requestJson = $requestBody | ConvertTo-Json -Depth 5

        $requestUri = "$resolvedBaseUrl/api/v1/migrations"
        $response = Invoke-WebRequest `
            -Method Post `
            -Body $requestJson `
            -Uri $requestUri `
            -Headers @{ 'x-api-key' = $resolvedApiKey; 'Accept' = 'application/json' } `
            -ContentType 'application/json; charset=utf-8' `
            -SkipHttpErrorCheck `
            -ErrorAction Stop

        $statusCode = [int]$response.StatusCode

     
    } catch {
       write-warning $_.exception.message
       return $false
    }

    return $true
}
function Get-HuduEmbeddableUploadMediaKind {
  param([Parameter(Mandatory)][string]$Path)
  $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($extension -in @('.mp4', '.m4v', '.webm', '.ogv', '.mov', '.mkv')) { return 'Video' }
  if ($extension -in @('.mp3', '.m4a', '.aac', '.wav', '.ogg', '.oga', '.opus', '.flac', '.weba')) { return 'Audio' }
  return $null
}

function Get-NormalizedCompanyName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    return ($Name.Trim() -replace '\s+', ' ').ToLowerInvariant()
}



function Resolve-HuduCompanyForConfluenceSpace {
    param(
        [Parameter(Mandatory)][object]$Space,
        [object[]]$Companies = @()
    )

    $spaceName = if (-not [string]::IsNullOrWhiteSpace($Space.Name)) { $Space.Name.Trim() } else { $Space.Key.Trim() }
    $normalizedSpaceName = Get-NormalizedCompanyName -Name $spaceName

    $Companies = @($Companies | Where-Object { $null -ne $_ })
    $matches = @($Companies | Where-Object {
        (Get-NormalizedCompanyName -Name $_.Name) -eq $normalizedSpaceName
    })

    if ($matches.Count -eq 1) {
        PrintAndLog -message "Matched Confluence space '$($Space.Name)' ($($Space.Key)) to existing Hudu company '$($matches[0].Name)' (ID: $($matches[0].Id))." -Color Green
        return $matches[0]
    }

    if ($matches.Count -gt 1) {
        PrintAndLog -message "Multiple Hudu companies match Confluence space '$($Space.Name)' ($($Space.Key)); please choose the destination company." -Color Yellow
        return $(Select-ObjectFromList -Objects $matches -message "Which Hudu company should Confluence space '$($Space.Name)' ($($Space.Key)) migrate into?")
    }

    PrintAndLog -message "No Hudu company matched Confluence space '$($Space.Name)' ($($Space.Key)); creating company '$spaceName'." -Color Yellow
    $createdCompanyResponse = New-HuduCompany -Name $spaceName -nickname "$($space.key)" -Notes "Created by Confluence migration from Confluence space '$($Space.Name)' (key: $($Space.Key), id: $($Space.Id))."
    $createdCompanyResponse = $createdCompanyResponse.company ?? $createdCompanyResponse
    $createdCompany = Get-HuduCompanies -id $createdCompanyResponse.id

    if ($null -eq $createdCompany -or $null -eq $createdCompany.Id) {
        $createdCompany = @(Get-HuduCompanies -Name $spaceName | Where-Object {
            (Get-NormalizedCompanyName -Name $_.Name) -eq $normalizedSpaceName
        } | Select-Object -First 1)[0]
    }

    if ($null -eq $createdCompany -or $null -eq $createdCompany.Id) {
        throw "Unable to create or retrieve Hudu company for Confluence space '$($Space.Name)' ($($Space.Key))."
    }

    PrintAndLog -message "Created Hudu company '$($createdCompany.Name)' (ID: $($createdCompany.Id)) for Confluence space '$($Space.Name)' ($($Space.Key))." -Color Green
    return $createdCompany
}
