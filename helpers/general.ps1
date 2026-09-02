
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

function Select-ObjectFromList($objects, $message, $inspectObjects = $false, $allowNull = $false) {
    $validated = $false
    while (-not $validated) {
        if ($allowNull) { Write-Host "0: None/Custom" }

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