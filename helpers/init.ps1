# ---------------------------------------
# Azure Vault Variables
# ---------------------------------------
$AzVault_Name = "hudu-pshell-learning"
$AzVault_HuduSecretName = "demo3-apikey-mason"
$AzVault_ConfluenceAPIKey="ConfluenceAPIKey"

# ---------------------------------------
# Hudu Variables
# ---------------------------------------
$HuduBaseURL = $HuduBaseURL ?? 
    $((Read-Host -Prompt 'Set the base domain of your Hudu instance (e.g https://myinstance.huducloud.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
$HuduAPIKey = $HuduAPIKey ?? "$(read-host "Please Enter Hudu API Key")"

# ---------------------------------------
# User-Entered Confluence Variables
# ---------------------------------------
$ConfluenceToken= $ConfluenceToken ?? "$(Read-Host "Please Enter Confluence Token")"
$ConfluenceDomain = $ConfluenceDomain ?? "$(read-host "please enter your Confluence subdomain (e.g 'hudu-integrations' would be valid for 'https://www.hudu-integrations.atlassian.net'.)")"

# these are used for various link replacement later on.
$ConfluenceDomain = ($ConfluenceDomain -replace '^https?://','' -replace '/.*$','' -replace '\.atlassian\.net$','')
$confluenceBase="$($ConfluenceDomain).atlassian.net"
$ConfluenceDomainBase= "https://$confluenceBase"
$ConfluenceBaseUrl ="$ConfluenceDomainBase/wiki"
$Confluence_Username=$Confluence_Username ?? "$(read-host 'please enter the username associated with your Confluence account / token [this should generally be your associated email address]')"
@($ConfluenceDomain, $confluenceBase, $ConfluenceDomainBase, $ConfluenceBaseUrl) | ForEach-Object { Write-Host "Set Confluence variable: $_" -ForegroundColor Green }

# ---------------------------------------
# quick validation
# ---------------------------------------
while ($HuduAPIKey.Length -ne 24) {
    $HuduAPIKey = (Read-Host -Prompt "Get a Hudu API Key from $($settings.HuduBaseDomain)/admin/api_keys").Trim()
    Clear-Host
    if ($HuduAPIKey.Length -ne 24) {
        Write-Host "This doesn't seem to be a valid Hudu API key. It is $($HuduAPIKey.Length) characters long, but should be 24." -ForegroundColor Red
    }
}
while ($ConfluenceToken.Length -ne 192) {
    $ConfluenceToken= $("$(Read-Host "Please Enter Confluence Token")")
    Clear-Host
    if ($ConfluenceToken.Length -ne 192) {
        Write-Host "This doesn't seem to be a valid confluence token. It is $($ConfluenceToken.Length) characters long, but should be 192." -ForegroundColor Red
    }
}
# ---------------------------------------
# internal variables, set up folders
# ---------------------------------------
$TmpOutputDir=$(join-path $project_workdir "tmp")
$LogsDir=$(join-path $project_workdir "logs")
$ErroredItemsFolder=$(join-path $LogsDir "errored")
$LogFile = $(join-path $LogsDir "ConfluenceTransfer.log")

$TmpOutputDir = "./tmp"
foreach ($folder in @($TmpOutputDir,$LogsDir,$ErroredItemsFolder)) {
    if (!(Test-Path -Path "$folder")) { New-Item "$folder" -ItemType Directory }
    Get-ChildItem -Path "$folder" -File -Recurse -Force | Remove-Item -Force
}

function Set-Huduinitialized {
    param (
            [string]$HAPImodulePath = "C:\Users\$env:USERNAME\Documents\GitHub\HuduAPI\HuduAPI\HuduAPI.psm1",
            [bool]$use_hudu_fork = $true,
            [version]$RequiredHuduVersion = [version]"2.39.6",
            $DisallowedVersions = @([version]"2.37.0"),
            [string]$HuduApiRepositoryUrl = $($env:HUDUAPI_REPOSITORY_URL ?? "https://github.com/Hudu-Technologies-Inc/HuduAPI.git"),
            [string]$HuduApiBranch = $($env:HUDUAPI_REPOSITORY_BRANCH ?? "master"),
            [bool]$AllowHuduGalleryFallback = $false
        )

    function Set-HuduInstance {
        param ([string]$HuduBaseURL,[string]$HuduAPIKey)
        $HuduBaseURL = $HuduBaseURL ?? 
            $((Read-Host -Prompt 'Set the base domain of your Hudu instance (e.g https://myinstance.huducloud.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
        $HuduAPIKey = $HuduAPIKey ?? "$(read-host "Please Enter Hudu API Key")"
        while ($HuduAPIKey.Length -ne 24) {
            $HuduAPIKey = (Read-Host -Prompt "Get a Hudu API Key from $($settings.HuduBaseDomain)/admin/api_keys").Trim()
            if ($HuduAPIKey.Length -ne 24) {
                Write-Host "This doesn't seem to be a valid Hudu API key. It is $($HuduAPIKey.Length) characters long, but should be 24." -ForegroundColor Red
            }
        }
        New-HuduAPIKey $HuduAPIKey
        New-HuduBaseURL $HuduBaseURL
    }

    function Test-HuduApiModuleLayout {
        param([Parameter(Mandatory)][string]$ModulePath)

        if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
            return $false
        }

        $moduleDirectory = Split-Path -Path $ModulePath -Parent
        return (
            (Test-Path -LiteralPath (Join-Path $moduleDirectory "Public") -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $moduleDirectory "Private") -PathType Container)
        )
    }

    function Get-GitHubRepositoryParts {
        param([Parameter(Mandatory)][string]$RepositoryUrl)

        if ($RepositoryUrl -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$') {
            return $null
        }

        [PSCustomObject]@{
            Owner = $matches.owner
            Repo  = ($matches.repo -replace '\.git$', '')
        }
    }

    function New-HuduApiStagingRoot {
        $tempRoot = Join-Path $env:TEMP "HuduAPI-Fork-$([guid]::NewGuid().Guid)"
        New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction Stop | Out-Null
        return (Join-Path $tempRoot "HuduAPI")
    }

    function Save-GitHubContentsDirectory {
        param(
            [Parameter(Mandatory)][string]$Owner,
            [Parameter(Mandatory)][string]$Repo,
            [Parameter(Mandatory)][string]$Branch,
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$DestinationPath
        )

        $encodedPath = (($Path -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        $encodedBranch = [System.Uri]::EscapeDataString($Branch)
        $uri = "https://api.github.com/repos/$Owner/$Repo/contents/$encodedPath`?ref=$encodedBranch"
        $headers = @{ "User-Agent" = "Hudu-Init" }
        $items = @(Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop)

        New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
        foreach ($item in $items) {
            $destination = Join-Path $DestinationPath $item.name
            if ($item.type -eq "dir") {
                $childPath = [string]$item.PSObject.Properties["path"].Value
                if ([string]::IsNullOrWhiteSpace($childPath)) {
                    $childPath = "$Path/$($item.name)"
                }
                Save-GitHubContentsDirectory -Owner $Owner -Repo $Repo -Branch $Branch -Path $childPath -DestinationPath $destination
            } elseif ($item.type -eq "file") {
                $downloadUrl = [string]$item.PSObject.Properties["download_url"].Value
                if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
                    throw "GitHub API did not return a download URL for $($item.name)."
                }
                Invoke-WebRequest -Uri $downloadUrl -Headers $headers -OutFile $destination -ErrorAction Stop | Out-Null
            }
        }
    }

    function Install-HuduApiForkNinjaStyle {
        param(
            [Parameter(Mandatory)][string]$RepositoryUrl,
            [Parameter(Mandatory)][string]$Branch,
            [Parameter(Mandatory)][string]$StagingRepoRoot
        )

        $repoParts = Get-GitHubRepositoryParts -RepositoryUrl $RepositoryUrl
        if (-not $repoParts) {
            throw "Ninja-Style install only supports github.com repository URLs."
        }

        $moduleDirectory = Join-Path $StagingRepoRoot "HuduAPI"
        Save-GitHubContentsDirectory -Owner $repoParts.Owner -Repo $repoParts.Repo -Branch $Branch -Path "HuduAPI" -DestinationPath $moduleDirectory
    }

    function Install-HuduApiForkSamuraiStyle {
        param(
            [Parameter(Mandatory)][string]$RepositoryUrl,
            [Parameter(Mandatory)][string]$Branch,
            [Parameter(Mandatory)][string]$StagingRepoRoot
        )

        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) {
            throw "git was not found on this machine."
        }

        $oldGitPrompt = $env:GIT_TERMINAL_PROMPT
        $oldGitSshCommand = $env:GIT_SSH_COMMAND
        try {
            $env:GIT_TERMINAL_PROMPT = "0"
            $env:GIT_SSH_COMMAND = "ssh -o BatchMode=yes"
            & $git.Source clone --depth 1 --branch $Branch $RepositoryUrl $StagingRepoRoot
            if ($LASTEXITCODE -ne 0) {
                throw "git clone exited with code $LASTEXITCODE."
            }
        } finally {
            $env:GIT_TERMINAL_PROMPT = $oldGitPrompt
            $env:GIT_SSH_COMMAND = $oldGitSshCommand
        }
    }

    function Install-HuduApiForkAshigaruStyle {
        param(
            [Parameter(Mandatory)][string]$RepositoryUrl,
            [Parameter(Mandatory)][string]$Branch,
            [Parameter(Mandatory)][string]$StagingRepoRoot
        )

        $repoParts = Get-GitHubRepositoryParts -RepositoryUrl $RepositoryUrl
        if (-not $repoParts) {
            throw "Ashigaru-Warrior-Style install only supports github.com repository URLs."
        }

        $stagingParent = Split-Path -Path $StagingRepoRoot -Parent
        $zip = Join-Path $stagingParent "HuduAPI.zip"
        $extractRoot = Join-Path $stagingParent "zip-extract"
        $zipUri = "https://codeload.github.com/$($repoParts.Owner)/$($repoParts.Repo)/zip/refs/heads/$Branch"
        $headers = @{ "User-Agent" = "Hudu-Init" }

        Invoke-WebRequest -Uri $zipUri -Headers $headers -OutFile $zip -ErrorAction Stop | Out-Null
        Expand-Archive -Path $zip -DestinationPath $extractRoot -Force -ErrorAction Stop

        $extracted = Get-ChildItem -LiteralPath $extractRoot -Directory -ErrorAction Stop | Select-Object -First 1
        if (-not $extracted) {
            throw "Downloaded archive did not contain a repository directory."
        }

        Move-Item -LiteralPath $extracted.FullName -Destination $StagingRepoRoot -Force -ErrorAction Stop
    }

    function Install-HuduApiFork {
        param(
            [Parameter(Mandatory)][string]$ModulePath,
            [Parameter(Mandatory)][string]$RepositoryUrl,
            [Parameter(Mandatory)][string]$Branch
        )

        $targetRepoRoot = Split-Path -Path (Split-Path -Path $ModulePath -Parent) -Parent
        $targetParent = Split-Path -Path $targetRepoRoot -Parent
        $stagingRepoRoot = $null
        $successfulMethod = $null

        $installMethods = @(
            @{
                Name = "Ninja-Style"
                Script = {
                    param($repoUrl, $branchName, $stagingRoot)
                    Install-HuduApiForkNinjaStyle -RepositoryUrl $repoUrl -Branch $branchName -StagingRepoRoot $stagingRoot
                }
            },
            @{
                Name = "Ashigaru-Warrior-Style"
                Script = {
                    param($repoUrl, $branchName, $stagingRoot)
                    Install-HuduApiForkAshigaruStyle -RepositoryUrl $repoUrl -Branch $branchName -StagingRepoRoot $stagingRoot
                }
            },
            @{
                Name = "Samurai-Style"
                Script = {
                    param($repoUrl, $branchName, $stagingRoot)
                    Install-HuduApiForkSamuraiStyle -RepositoryUrl $repoUrl -Branch $branchName -StagingRepoRoot $stagingRoot
                }
            }
        )

        foreach ($method in $installMethods) {
            $stagingRepoRoot = New-HuduApiStagingRoot
            $stagingContainer = Split-Path -Path $stagingRepoRoot -Parent

            try {
                Write-Host "Trying HuduAPI fork install via $($method.Name) from $RepositoryUrl ($Branch)." -ForegroundColor Cyan
                & $method.Script $RepositoryUrl $Branch $stagingRepoRoot

                $stagedModulePath = Join-Path $stagingRepoRoot "HuduAPI\HuduAPI.psm1"
                if (-not (Test-HuduApiModuleLayout -ModulePath $stagedModulePath)) {
                    throw "Downloaded fork did not include a complete HuduAPI module layout."
                }

                $successfulMethod = $method.Name
                break
            } catch {
                Write-Warning "$($method.Name) HuduAPI fork install failed: $($_.Exception.Message)"
                if (Test-Path -LiteralPath $stagingContainer) {
                    Remove-Item -LiteralPath $stagingContainer -Recurse -Force -ErrorAction SilentlyContinue
                }
                $stagingRepoRoot = $null
            }
        }

        if (-not $successfulMethod) {
            throw "Unable to install HuduAPI fork from $RepositoryUrl ($Branch)."
        }

        New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $targetRepoRoot) {
            $backupPath = "$targetRepoRoot.backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Move-Item -LiteralPath $targetRepoRoot -Destination $backupPath -Force -ErrorAction Stop
            Write-Warning "Existing incomplete HuduAPI path was moved to $backupPath."
        }

        $stagingGitPath = Join-Path $stagingRepoRoot ".git"
        if (Test-Path -LiteralPath $stagingGitPath) {
            Remove-Item -LiteralPath $stagingGitPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        $stagingContainer = Split-Path -Path $stagingRepoRoot -Parent
        New-Item -ItemType Directory -Path $targetRepoRoot -Force -ErrorAction Stop | Out-Null
        Get-ChildItem -LiteralPath $stagingRepoRoot -Force -ErrorAction Stop |
            Copy-Item -Destination $targetRepoRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $stagingContainer) {
            Remove-Item -LiteralPath $stagingContainer -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Installed HuduAPI fork via $successfulMethod to $targetRepoRoot." -ForegroundColor Green
    }

    try {
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction Stop
        Write-Host "Process execution policy set to Bypass for this PowerShell session." -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not set process execution policy to Bypass: $($_.Exception.Message)"
    }

    if ($true -eq $use_hudu_fork) {
        if (-not (Test-HuduApiModuleLayout -ModulePath $HAPImodulePath)) {
            Write-Host "Using latest $HuduApiBranch branch of HuduAPI fork." -ForegroundColor Cyan
            Install-HuduApiFork -ModulePath $HAPImodulePath -RepositoryUrl $HuduApiRepositoryUrl -Branch $HuduApiBranch
        }
    } else {
        Write-Host "Assuming PSGallery Module if not already locally cloned at $HAPImodulePath"
    }

    if (Test-HuduApiModuleLayout -ModulePath $HAPImodulePath) {
        $huduApiManifestPath = [System.IO.Path]::ChangeExtension($HAPImodulePath, ".psd1")
        $huduApiImportPath = if (Test-Path -LiteralPath $huduApiManifestPath -PathType Leaf) { $huduApiManifestPath } else { $HAPImodulePath }
        Import-Module $huduApiImportPath -Force -ErrorAction Stop
        Write-Host "Module imported from $huduApiImportPath"
    } elseif ($true -eq $use_hudu_fork -and -not $AllowHuduGalleryFallback) {
        write-host "Sorry, it seems we weren't able to load the Hudu-Fork of HuduAPI module, which is required for the latest features that this fork provides."
        write-host "You can manually download this project https://github.com/Hudu-Technologies-Inc/HuduAPI and extract it to Documents/GitHub folder."
        throw "HuduAPI fork was requested, but no complete fork module was available at $HAPImodulePath. PSGallery fallback is disabled."
    } elseif ((Get-Module -ListAvailable -Name HuduAPI).Version -ge [version]'3.1.1') {
        Import-Module HuduAPI -ErrorAction Stop
        Write-Host "Module 'HuduAPI' imported from global/module path"
    } else {
        Install-Module HuduAPI -MinimumVersion 2.4.5 -Scope CurrentUser -Force -ErrorAction Stop
        Import-Module HuduAPI -ErrorAction Stop
        Write-Host "Installed and imported HuduAPI from PSGallery"
    }

    Set-HuduInstance -HuduBaseURL $($hudubaseurl ?? $null) -HuduAPIKey $($huduapikey ?? $null)

    # Check we have the correct version
    $CurrentVersion = [version]($(Get-HuduAppInfo).version)

    if ($CurrentVersion -lt [version]$RequiredHuduVersion -or $DisallowedVersions -contains $CurrentVersion) {
        Write-Host "This script requires at least version $RequiredHuduVersion and cannot run with version $CurrentVersion. Please update your version of Hudu."
        exit 1
    } else {
        write-host "Current version $CurrentVersion is compatible."
    }

    return $CurrentVersion
}


Set-Huduinitialized

Write-Host "Encoding Credentials for Confluence..."
$encodedCreds = [System.Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes("$($Confluence_Username):$($ConfluenceToken)")
)

Write-Host "Authenticating to Hudu instance @$HuduBaseURL..."
New-HuduAPIKey $HuduAPIKey
New-HuduBaseUrl $HuduBaseURL

$PowershellVersion = [version](Get-Host).Version
$requiredPowershellVersion = [version]"7.5.0"
Write-Host "Required PowerShell version: $requiredPowershellVersion" -ForegroundColor Blue

if ($PowershellVersion -lt $requiredPowershellVersion) {
    Write-Host "PowerShell $requiredPowershellVersion or higher is required. You have $PowershellVersion." -ForegroundColor Red
    exit 1
} else {
    Write-Host "PowerShell version $PowershellVersion found" -ForegroundColor Green
}


$RequiredHuduVersion = "2.40.1"
$HuduAppInfo = Get-HuduAppInfo
$CurrentVersion = [version]$HuduAppInfo.version
if ($CurrentVersion -lt [version]$RequiredHuduVersion) {
    Write-Host "This script requires at least version $RequiredHuduVersion and cannot run with version $CurrentVersion. Please update your version of Hudu."
    exit 1
}
