# ====================================================================
# ENTRY.PS1 (Public Orchestrator & Menu System)
# ====================================================================

$PrivateRepoOwner = "skrogman" 
$PrivateRepoName  = "Toolkit_Modules" # UPDATED: Now targeting your private modules repo
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

# 4. Filter for folders, ignoring hidden git/metadata directories
$apps = $repoContents | Where-Object { $_.type -eq "dir" -and $_.name -notlike ".*" }

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
    
    # Execute the selected app's bootstrapper, passing the PAT header down
    . $appScriptBlock -AuthHeader $AuthHeader -RepoOwner $PrivateRepoOwner -RepoName $PrivateRepoName -Branch $Branch -AppName $selectedApp
} catch {
    Write-Host "`n[X] ERROR: Failed to download $selectedApp's Entry.ps1." -ForegroundColor Red
    Write-Host "GitHub says the file does not exist at this exact path:" -ForegroundColor Gray
    Write-Host $appRawUrl -ForegroundColor Yellow
    Read-Host "`nPress Enter to exit"
    exit
}
