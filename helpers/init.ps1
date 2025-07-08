# ---------------------------------------
# Azure Vault Variables
# ---------------------------------------
$AzVault_Name = "hudu-pshell-learning"
$AzVault_HuduSecretName = "demo3-apikey-mason"
$AzVault_ConfluenceAPIKey="ConfluenceAPIKey"
$ContentType = "page"
$ConfluenceToken= $ConfluenceToken ?? "$(Read-Host "Please Enter Confluence Token")"
$confluenceBase="$($ConfluenceDomain).atlassian.net"


# ---------------------------------------
# Hudu Variables
# ---------------------------------------
$HuduBaseURL = $HuduBaseURL ?? 
    $((Read-Host -Prompt 'Set the base domain of your Hudu instance (e.g https://myinstance.huducloud.com)') -replace '[\\/]+$', '') -replace '^(?!https://)', 'https://'
$HuduAPIKey = $HuduAPIKey ?? "$(read-host "Please Enter Hudu API Key")"
$HUDU_MAX_DOCSIZE=6500

# ---------------------------------------
# Confluence Variables
# ---------------------------------------
$ConfluenceDomain = "hudu-integrations"
$Confluence_Username="integrations@hudu.com"
$ConfluenceArticlePreviewLength = 6750
$ConfluenceDomainBase= "https://$confluenceBase"
$ConfluenceBaseUrl ="$ConfluenceDomainBase/wiki"
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

$HAPImodulePath = "C:\Users\$env:USERNAME\Documents\GitHub\HuduAPI\HuduAPI\HuduAPI.psm1"
if (Test-Path $HAPImodulePath) {
    Import-Module $HAPImodulePath -Force
    Write-Host "Module imported from $HAPImodulePath"
} else {
    foreach ($module in @('HuduAPI')) {if (Get-Module -ListAvailable -Name $module) 
        { Write-Host "Importing module, $module..."; Import-Module $module } else {Write-Host "Installing and importing module $module..."; Install-Module $module -Force -AllowClobber; Import-Module $module }
    }
}

Write-Host "Encoding Credentials for Confluence..."
$encodedCreds = [System.Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes("$($Confluence_Username):$($ConfluenceToken)")
)

Write-Host "Authenticating to Hudu instance @$HuduBaseURL..."
New-HuduAPIKey $HuduAPIKey
New-HuduBaseUrl $HuduBaseURL

if ((get-host).version.major -ne 7) {
    Write-Host "Powershell 7 Required" -foregroundcolor Red
    exit 1
}
$RequiredHuduVersion = "2.37.1"
$HuduAppInfo = Get-HuduAppInfo
$CurrentVersion = [version]$HuduAppInfo.version
if ($CurrentVersion -lt [version]$RequiredHuduVersion) {
    Write-Host "This script requires at least version $RequiredHuduVersion and cannot run with version $CurrentVersion. Please update your version of Hudu."
    exit 1
}