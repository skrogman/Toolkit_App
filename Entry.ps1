$ErrorActionPreference = 'Stop'

Clear-Host
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host '               SECURE IR & ADMIN TOOLKIT                   ' -ForegroundColor Green
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host ''

# 1. Inherit the Authentication Context from the Launcher
$Token = $null
if ($global:GitHubToken) { 
    $Token = $global:GitHubToken 
} elseif ($env:GITHUB_TOKEN) { 
    $Token = $env:GITHUB_TOKEN 
}

if (-not $Token) {
    Write-Host '[!] No identity token inherited from the launcher.' -ForegroundColor Yellow
    Write-Host '    Public modules will load, but private vaults will return 404 Not Found.' -ForegroundColor DarkGray
} else {
    Write-Host '[+] Secure session context inherited successfully.' -ForegroundColor Green
}

# 2. Configure Next-Stage Vault Connection
# (Change these variables to point to your actual secondary module/script)
$TargetOwner  = 'skrogman'
$TargetRepo   = 'Toolkit_Modules' 
$TargetBranch = 'main'
$TargetFile   = 'Main.ps1' # <-- Update this if your next script is named something else!

Write-Host "Connecting to secure vault ($TargetRepo)..." -ForegroundColor Cyan

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {
    # 3. Securely Fetch Payload
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add('User-Agent', 'PowerShellSecureLauncher')
    $WebClient.Headers.Add('Accept', 'application/vnd.github.v3.raw')
    
    # Inject the inherited token into the web request
    if ($Token) { 
        $WebClient.Headers.Add('Authorization', "Bearer $Token") 
    }
    
    $VaultUrl = "https://api.github.com/repos/$TargetOwner/$TargetRepo/contents/$TargetFile?ref=$TargetBranch"
    
    $Payload = $WebClient.DownloadString($VaultUrl)
    
    if ($Payload) {
        Write-Host '[+] Vault payload retrieved successfully. Executing...' -ForegroundColor Green
        Start-Sleep -Milliseconds 600
        Clear-Host
        
        # 4. Execute the Main Toolkit Application
        Invoke-Expression $Payload
    }
} catch {
    # 5. Native Error Handling (Mirrors your previous screenshots)
    Write-Host ''
    Write-Host '[X] Access Denied or Repository Not Found.' -ForegroundColor Red
    Write-Host "Endpoint: $VaultUrl" -ForegroundColor DarkGray
    
    if ($_.Exception.Response) {
        $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $RawError = $Reader.ReadToEnd()
        Write-Host "Error Details:`n$RawError" -ForegroundColor DarkGray
    } else {
        Write-Host "Error Details:`n$($_.Exception.Message)" -ForegroundColor DarkGray
    }
    
    Write-Host "`nPress Enter to exit..." -ForegroundColor Yellow
    Read-Host | Out-Null
    exit
}
