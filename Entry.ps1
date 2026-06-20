# ==================================================================
# Target Repo Asset: skrogman/Toolkit_App/contents/Entry.ps1
# Architecture: Bootstrap -> Toolkit_App (Here) -> Toolkit_Modules
# ==================================================================

$RunStartTime = Get-Date
$ScriptIdentity = "[ORCHESTRATOR]"
Write-Host "`n$ScriptIdentity === PIPELINE STARTED AT $($RunStartTime.ToString('HH:mm:ss')) ===" -ForegroundColor DarkGray

# Define architectural targets
$RepoOwner = "skrogman"
$ModulesRepo = "Toolkit_Modules"
$Branch = "main"

# --- [1] SECURE AUTHENTICATION CONTEXT ---
$AuthHeader = @{
    'User-Agent' = 'Secure-IR-Enclave'
}

if ($global:GitHubToken) {
    $AuthHeader.Add('Authorization', "Bearer $($global:GitHubToken)")
    Write-Host "$ScriptIdentity [AUTH] Token inherited from global scope." -ForegroundColor DarkGray
} else {
    Write-Host "$ScriptIdentity [!] CRITICAL: Identity token not found." -ForegroundColor Red
}

# --- [2] NETWORK COMMUNICATOR ---
function Invoke-GitHubRequest {
    param([string]$Url, [string]$AcceptType = "application/vnd.github.v3+json")
    Write-Host "$ScriptIdentity [CONNECT] Dispatching GET: $Url" -ForegroundColor DarkGray
    
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
$DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents?ref=$Branch"

try {
    Write-Host "$ScriptIdentity [DISCOVERY] Querying $ModulesRepo on branch '$Branch'..." -ForegroundColor DarkGray
    $RawJson = Invoke-GitHubRequest -Url $DiscoveryUrl
} catch {
    $DiscoveryError = $_.Exception.Message
    if ($DiscoveryError -match "404") {
        $Branch = "master"
        $DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents?ref=$Branch"
        Write-Host "$ScriptIdentity [DISCOVERY] Branch 'main' 404'd. Falling back to '$Branch'..." -ForegroundColor DarkGray
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
        Write-Host "$ScriptIdentity [SUCCESS] Discovered $($DynamicModules.Count) functional modules." -ForegroundColor DarkGray
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
        if ($DiscoveryError) { Write-Host "    API Fault Details: $DiscoveryError" -ForegroundColor Red }
    } else {
        for ($i = 0; $i -lt $DynamicModules.Count; $i++) {
            Write-Host "$($i + 1). $($DynamicModules[$i])"
        }
    }
    
    $ExitOptionNumber = $DynamicModules.Count + 1
    Write-Host "$ExitOptionNumber. Exit Launcher Enclave"
    Write-Host ""
    
    $InputSelection = (Read-Host "Select an option (1-$ExitOptionNumber)").Trim()
    
    # [BUGFIX] Initialize variable prior to [ref] cast
    $SelectedNumber = 0 
    
    if (-not [int]::TryParse($InputSelection, [ref]$SelectedNumber)) {
        Write-Host "`n[X] Invalid entry format. Use integers only." -ForegroundColor Red
        Start-Sleep -Seconds 1
        continue
    }

    if ($SelectedNumber -eq $ExitOptionNumber) {
        $RunEndTime = Get-Date
        Write-Host "`n[-] Purging module context..." -ForegroundColor Yellow
        Write-Host "$ScriptIdentity === PIPELINE TERMINATED AT $($RunEndTime.ToString('HH:mm:ss')) ===" -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 750
        return 
    }
    elseif ($SelectedNumber -gt 0 -and $SelectedNumber -le $DynamicModules.Count) {
        $TargetModule = $DynamicModules[$SelectedNumber - 1]
        Write-Host "`n[+] Dispatching pipeline execution sequence for: $TargetModule..." -ForegroundColor Cyan
        
        try {
            $ModuleUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents/$TargetModule/Entry.ps1?ref=$Branch"
            Write-Host "$ScriptIdentity [EXECUTE] Fetching payload from $TargetModule..." -ForegroundColor DarkGray
            
            $ScriptContent = Invoke-GitHubRequest -Url $ModuleUrl -AcceptType "application/vnd.github.v3.raw"
            
            if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
                throw "Downloaded script block returned empty payload."
            }
            
            $ScriptBlock = [ScriptBlock]::Create($ScriptContent)
            
            # Pass execution down to the target module
            & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            
            Write-Host "$ScriptIdentity [EXECUTE] Payload $TargetModule returned control to Orchestrator." -ForegroundColor DarkGray
        } catch {
            Write-Host "[X] Dynamic Execution Faulted: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Target Endpoint: $ModuleUrl" -ForegroundColor DarkGray
        }
        Read-Host "`nPress Enter to return to module selection..."
    }
}
