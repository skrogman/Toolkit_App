#Requires -Version 5.1
# ====================================================================
# TOOLKIT_APP\ENTRY.PS1 (Public Repo - The Menu & Vault Key)
# ====================================================================

$PrivateRepoOwner = "skrogman" # <-- CHANGE THIS
$PrivateRepoName  = "Toolkit_App"
$Branch           = "main"

Clear-Host
Write-Host "=============================================" -ForegroundColor Green
Write-Host "         SECURE IR & ADMIN TOOLKIT           " -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green

# 1. Ask for the key to unlock the private repo
$SecureKey = Read-Host "Enter Toolkit Access Key (PAT)" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
$PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

# Build the authentication header
$AuthHeader = @{
    "Authorization" = "Bearer $PlainToken"
    "Accept"        = "application/vnd.github.v3+json"
}

Write-Host "`nConnecting to secure vault..." -ForegroundColor DarkGray

# 2. Query the PRIVATE repo for available apps
$apiUrl = "https://api.github.com/repos/$PrivateRepoOwner/$PrivateRepoName/contents?ref=$Branch"
try {
    $apiResponse = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $AuthHeader -UseBasicParsing
    
    # Filter for directories that start with "App_"
    $availableApps = $apiResponse | Where-Object { $_.type -eq "dir" -and $_.name -like "App_*" } | Select-Object -ExpandProperty name
} catch {
    Write-Error "Access Denied: Invalid Key or Cannot reach the private repository."
    return
}

if (-not $availableApps) {
    Write-Host "No applications found in the vault." -ForegroundColor Red
    return
}

# 3. Render the Menu
Write-Host "`nPlease select an application to launch:`n"
for ($i = 0; $i -lt $availableApps.Count; $i++) {
    Write-Host " [$($i + 1)] $($availableApps[$i])" -ForegroundColor Cyan
}
Write-Host " [Q] Quit" -ForegroundColor Yellow

$selection = ""
while ($selection -notmatch "^([1-$($availableApps.Count)]|Q|q)$") {
    $selection = Read-Host "`nEnter choice"
}

if ($selection -match 'q') { return }
$selectedApp = $availableApps[[int]$selection - 1]

# 4. Boot the Private App's Entry.ps1
Write-Host "`nStarting $selectedApp..." -ForegroundColor Green
$appRawUrl = "https://raw.githubusercontent.com/$PrivateRepoOwner/$PrivateRepoName/$Branch/$selectedApp/Entry.ps1"

try {
    $appCode = Invoke-RestMethod -Uri $appRawUrl -Method Get -Headers $AuthHeader -UseBasicParsing
    
    # Execute the private App's Entry.ps1 right here in memory.
    # NOTE: We pass the $AuthHeader down so the private app can use it to download its own internal modules.
    $appScriptBlock = [scriptblock]::Create($appCode)
    . $appScriptBlock -AuthHeader $AuthHeader -RepoOwner $PrivateRepoOwner -RepoName $PrivateRepoName -Branch $Branch -AppName $selectedApp
} catch {
    Write-Error "Failed to download $selectedApp's Entry.ps1. Check your access key permissions."
}
