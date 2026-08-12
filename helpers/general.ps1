
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

function Get-ArticlePreviewBlock {
    param (
        [string]$Title,
        [string]$PageId,
        [string]$Content,
        [int]$MaxLength = 200
    )
    $descriptor = "ID: $PageId, titled $Title"
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

function Get-LinksFromHTML {
    param (
        [string]$htmlContent,
        [string]$title,
        [bool]$includeImages = $true,
        [bool]$suppressOutput = $false

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