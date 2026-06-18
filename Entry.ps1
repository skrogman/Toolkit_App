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
    # 1. We add '-ErrorAction Stop' here so it fails silently and instantly jumps to the catch block
    $appCode = Invoke-RestMethod -Uri $appRawUrl -Method Get -Headers $AuthHeader -UseBasicParsing -ErrorAction Stop
    
    $appScriptBlock = [scriptblock]::Create($appCode)
    . $appScriptBlock -AuthHeader $AuthHeader -RepoOwner $PrivateRepoOwner -RepoName $PrivateRepoName -Branch $Branch -AppName $selectedApp
} catch {
    # 2. We use Write-Host instead of Write-Error so it prints clean text
    Write-Host "`n[X] ERROR: Failed to download $selectedApp's Entry.ps1." -ForegroundColor Red
    Write-Host "GitHub says the file does not exist at this exact path:" -ForegroundColor Gray
    Write-Host $appRawUrl -ForegroundColor Yellow
    
    # 3. This pauses the script so the window stays open for you to read it!
    Read-Host "`nPress Enter to exit"
    exit
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
