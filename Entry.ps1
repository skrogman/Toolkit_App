# ==================================================================
# Target Repo Asset: skrogman/Toolkit_App/contents/Entry.ps1
# Architecture: Bootstrap -> Toolkit_App (Here) -> Toolkit_Modules
# ==================================================================

# Define architectural targets
$RepoOwner = "skrogman"
$ModulesRepo = "Toolkit_Modules"
$Branch = "main" # Fallback to master handled dynamically

# --- [1] SECURE AUTHENTICATION CONTEXT ---
$AuthHeader = @{
    'User-Agent' = 'Secure-IR-Enclave'
}

# Inherit the decrypted identity token from the bootstrap enclave
if ($global:GitHubToken) {
    $AuthHeader.Add('Authorization', "Bearer $($global:GitHubToken)")
} else {
    Write-Host "[!] CRITICAL: Identity token not found in global scope. Module discovery will likely fail." -ForegroundColor Red
}

# --- [2] NETWORK COMMUNICATOR ---
function Invoke-GitHubRequest {
    param(
        [string]$Url,
        [string]$AcceptType = "application/vnd.github.v3+json"
    )
    
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add('User-Agent', $AuthHeader['User-Agent'])
    $WebClient.Headers.Add('Accept', $AcceptType)
    
    if ($AuthHeader.ContainsKey('Authorization')) {
        $WebClient.Headers.Add('Authorization', $AuthHeader['Authorization'])
    }
    
    return $WebClient.DownloadString($Url)
}

# --- [3] DYNAMIC MODULE DISCOVERY ---
$DiscoveryError = $null
$DynamicModules = @()

# NOTE: Removed trailing slash for strict GitHub API compliance
$DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents?ref=$Branch"

try {
    $RawJson = Invoke-GitHubRequest -Url $DiscoveryUrl
} catch {
    $DiscoveryError = $_.Exception.Message
    
    # Fallback protocol if 'main' branch yields a 404
    if ($DiscoveryError -match "404") {
        $Branch = "master"
        $DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents?ref=$Branch"
        try { 
            $RawJson = Invoke-GitHubRequest -Url $DiscoveryUrl 
            $DiscoveryError = $null 
        } catch {
            $DiscoveryError = $_.Exception.Message
        }
    }
}

if ($RawJson) {
    try {
        $DynamicModules = $RawJson | ConvertFrom-Json | Where-Object { $_.type -eq 'dir' } | Select-Object -ExpandProperty name
    } catch {
        $DiscoveryError = "JSON Parsing Fault: $($_.Exception.Message)"
    }
}

# --- [4] PERSISTENT UI ENCLAVE ---
while ($true) {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "            SECURE IR & ADMIN TOOLKIT             " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "[+] Secure session context inherited successfully." -ForegroundColor Green
    Write-Host "[+] Target Architecture: $RepoOwner/$ModulesRepo ($Branch)" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "--- DYNAMIC MODULE SELECTION ---" -ForegroundColor Yellow
    
    if ($DynamicModules.Count -eq 0) {
        Write-Host "[X] Warning: No functional modules discovered." -ForegroundColor Yellow
        if ($DiscoveryError) {
            Write-Host "    API Fault Details: $DiscoveryError" -ForegroundColor Red
        }
        Write-Host "    Action: Verify the identity token has 'Contents: Read' scope for '$ModulesRepo'." -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $DynamicModules.Count; $i++) {
            Write-Host "$($i + 1). $($DynamicModules[$i])"
        }
    }
    
    $ExitOptionNumber = $DynamicModules.Count + 1
    Write-Host "$ExitOptionNumber. Exit Launcher Enclave"
    Write-Host ""
    
    $InputSelection = (Read-Host "Select an option (1-$ExitOptionNumber)").Trim()
    
    # Input Sanitization
    if (-not [int]::TryParse($InputSelection, [ref]$SelectedNumber)) {
        Write-Host "`n[X] Invalid entry format. Use integers only." -ForegroundColor Red
        Start-Sleep -Seconds 1
        continue
    }

    if ($SelectedNumber -eq $ExitOptionNumber) {
        Write-Host "`n[-] Purging module context and returning to bootstrap..." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 750
        return 
    }
    elseif ($SelectedNumber -gt 0 -and $SelectedNumber -le $DynamicModules.Count) {
        $TargetModule = $DynamicModules[$SelectedNumber - 1]
        Write-Host "`n[+] Dispatching pipeline execution sequence for: $TargetModule..." -ForegroundColor Cyan
        
        try {
            # Construct API raw string download target path pointing to subfolder Entry.ps1
            $ModuleUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents/$TargetModule/Entry.ps1?ref=$Branch"
            
            # Fetch payload securely as raw text
            $ScriptContent = Invoke-GitHubRequest -Url $ModuleUrl -AcceptType "application/vnd.github.v3.raw"
            
            if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
                throw "Downloaded script block returned empty payload."
            }
            
            $ScriptBlock = [ScriptBlock]::Create($ScriptContent)
            
            # Execute in current scope, passing down auth headers
            & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            
        } catch {
            Write-Host "[X] Dynamic Execution Faulted: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Target Endpoint: $ModuleUrl" -ForegroundColor DarkGray
        }
        Read-Host "`nPress Enter to return to module selection..."
    }
    else {
        Write-Host "`n[X] Selection context outside valid range boundaries." -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
}
