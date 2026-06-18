#Requires -Version 5.1
# ====================================================================
# TOOLKIT_APP\ENTRY.PS1 (Public Repo - The Menu & Vault Key)
# ====================================================================

$PrivateRepoOwner = "skrogman" # <-- CHANGE THIS
$PrivateRepoName  = "Toolkit_App"
$Branch           = "main"

Write-Host "`n===========================================================" -ForegroundColor Green
Write-Host "               SECURE IR & ADMIN TOOLKIT                   " -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green

# 1. Use the local PIN token if it exists, otherwise ask for it
if ($global:DevToken) {
    Write-Host ">>> Local Toolkit PIN Detected. Bypassing manual entry..." -ForegroundColor DarkGray
    $PlainToken = $global:DevToken
} else {
    $SecureKey = Read-Host "Enter Toolkit Access Key (PAT)" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    $PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}

# 2. Build the authentication header
$AuthHeader = @{
    "Authorization" = "Bearer $PlainToken"
    "Accept"        = "application/vnd.github.v3+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

Write-Host "`nConnecting to secure vault..." -ForegroundColor Cyan

# 3. Ask GitHub for the contents of the Private Vault
$apiUrl = "https://api.github.com/repos/$PrivateRepoOwner/$PrivateRepoName/contents"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $repoContents = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $AuthHeader -UseBasicParsing
} catch {
    Write-Host "`n[X] Access Denied or Repository Not Found." -ForegroundColor Red
    Write-Host "Error Details: $_" -ForegroundColor Gray
    Read-Host "`nPress Enter to exit"
    exit
}

# 4. Filter for Folders (Updated to match your specific repository structure)
$apps = $repoContents | Where-Object { $_.type -eq "dir" }

if ($apps.Count -eq 0) {
    Write-Host "`n[!] No applications found in the vault." -ForegroundColor Yellow
    Read-Host "`nPress Enter to exit"
    exit
}

# 5. Build the Dynamic Menu
Write-Host "`nAvailable Toolkits:`n" -ForegroundColor White
$i = 1
foreach ($app in $apps) {
    Write-Host "  [$i] $($app.name)" -ForegroundColor Cyan
    $i++
}

# 6. Get User Selection
Write-Host ""
$selection = 0
while ($selection -lt 1 -or $selection -gt $apps.Count) {
    [int]$selection = Read-Host "Select a toolkit to load (1-$($apps.Count))"
}

$selectedApp = $apps[$selection - 1].name
Write-Host "`n[+] Bootstrapping $selectedApp..." -ForegroundColor Green

# 7. Download and Launch the selected app's internal Entry.ps1
$appRawUrl = "https://raw.githubusercontent.com/$PrivateRepoOwner/$PrivateRepoName/$Branch/$selectedApp/Entry.ps1"

try {
    $appCode = Invoke-RestMethod -Uri $appRawUrl -Method Get -Headers $AuthHeader -UseBasicParsing -ErrorAction Stop
    $appScriptBlock = [scriptblock]::Create($appCode)
    
    # Execute the selected app's bootstrapper, passing the PAT header so it can download its own modules
    . $appScriptBlock -AuthHeader $AuthHeader -RepoOwner $PrivateRepoOwner -RepoName $PrivateRepoName -Branch $Branch -AppName $selectedApp
} catch {
    Write-Host "`n[X] ERROR: Failed to download $selectedApp's Entry.ps1." -ForegroundColor Red
    Write-Host "GitHub says the file does not exist at this exact path:" -ForegroundColor Gray
    Write-Host $appRawUrl -ForegroundColor Yellow
    Read-Host "`nPress Enter to exit"
    exit
}
#Clear-Host
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
