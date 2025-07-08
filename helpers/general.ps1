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


function Save-HtmlSnapshot {
    param (
        [Parameter(Mandatory)][string]$PageId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Suffix,
        [Parameter(Mandatory)][string]$OutDir
    )

    $safeTitle = ($Title -replace '[^\w\d\-]', '_') -replace '_+', '_'
    $filename = "${PageId}_${safeTitle}_${Suffix}.html"
    $path = Join-Path -Path $OutDir -ChildPath $filename

    try {
        $Content | Out-File -FilePath $path -Encoding UTF8
        Write-Host "Saved HTML snapshot: $path"
    } catch {
        Write-ErrorObjectsToFile -Name "$($_.safeTitle ?? "unnamed")" -ErrorObject @{
            Error       = $_
            PageId      = $PageId 
            Content     = $Content
            Message     ="Error Saving HTML Snapshot"
            OutDir      = $OutDir
        }
    }
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
function Select-Object-From-List($objects,$message,$allowNull = $false) {
    $validated=$false
    while ($validated -eq $false){
        if ($allowNull -eq $true) {
            Write-Host "0: None/Custom"
        }
        for ($i = 0; $i -lt $objects.Count; $i++) {
            $object = $objects[$i]
            if ($null -ne $object.OptionMessage) {
                Write-Host "$($i+1): $($object.OptionMessage)"
            } elseif ($null -ne $object.name) {
                Write-Host "$($i+1): $($object.name)"
            } else {
                Write-Host "$($i+1): $($object)"
            }
        }
        $choice = Read-Host $message
        if ($null -eq $choice -or $choice -lt 0 -or $choice -gt $objects.Count +1) {
            PrintAndLog -message "Invalid selection. Please enter a number from above"
        }
        if ($choice -eq 0 -and $true -eq $allowNull) {
            return $null
        }
        if ($null -ne $objects[$choice - 1]){
            return $objects[$choice - 1]
        }
    }
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
function Get-LinksFromHTML {
    param (
        [string]$htmlContent,
        [string]$title,
        [bool]$includeImages = $true

    )

    $allLinks = @()

    # Match all href attributes inside anchor tags
    $hrefPattern = '<a\s[^>]*?href=["'']([^"'']+)["'']'
    $hrefMatches = [regex]::Matches($htmlContent, $hrefPattern, 'IgnoreCase')
    foreach ($match in $hrefMatches) {
        $allLinks += $match.Groups[1].Value
    }

    if ($includeImages) {
        # Match all src attributes inside img tags
        $srcPattern = '<img\s[^>]*?src=["'']([^"'']+)["'']'
        $srcMatches = [regex]::Matches($htmlContent, $srcPattern, 'IgnoreCase')
        foreach ($match in $srcMatches) {
            $allLinks += $match.Groups[1].Value
        }
    }
    $linkidx=0
    foreach ($link in $allLinks) {
        $linkidx=$linkidx+1
        PrintAndLog -message "link $linkidx of $($allLinks.count) total found for $title - $link" -Color Blue
    }

    return $allLinks | Sort-Object -Unique
}
function Get-SafeFilename {
    param([string]$Name,
        [int]$MaxLength=25
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