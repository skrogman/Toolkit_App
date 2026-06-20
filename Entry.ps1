# ==================================================================
# Target Repo Asset: skrogman/Toolkit_App/contents/Entry.ps1
# Description: Dynamically builds menu from Toolkit_Modules folders
# ==================================================================

$RepoOwner = "skrogman"
$ModulesRepo = "Toolkit_Modules"

# 1. Configure Authorization Headers
$AuthHeader = @{
    'User-Agent' = 'PowerShellSecureLauncher'
}
if ($global:GitHubToken) {
    $AuthHeader.Add('Authorization', "Bearer $global:GitHubToken")
}

# 2. Dynamic Branch & Module Discovery
$Branch = "main"
$DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents/?ref=$Branch"

function Fetch-GitHubString {
    param([string]$Url, [string]$AcceptType = "application/vnd.github.v3+json")
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add('User-Agent', $AuthHeader['User-Agent'])
    $WebClient.Headers.Add('Accept', $AcceptType)
    if ($AuthHeader.ContainsKey('Authorization')) {
        $WebClient.Headers.Add('Authorization', $AuthHeader['Authorization'])
    }
    return $WebClient.DownloadString($Url)
}

# Test 'main' branch, fallback to 'master' if we hit a 404
$RawJson = $null
try {
    $RawJson = Fetch-GitHubString -Url $DiscoveryUrl
} catch {
    if ($_.Exception.Message -like "*404*") {
        $Branch = "master"
        $DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents/?ref=$Branch"
        try { $RawJson = Fetch-GitHubString -Url $DiscoveryUrl } catch {}
    }
}

# Parse folders into dynamic array list
$DynamicModules = @()
if ($RawJson) {
    try {
        $DynamicModules = $RawJson | ConvertFrom-Json | Where-Object { $_.type -eq 'dir' } | Select-Object -ExpandProperty name
    } catch {}
}

# 3. Persistent UI Operational Loop
while ($true) {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "            SECURE IR & ADMIN TOOLKIT             " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "[+] Secure session context inherited successfully." -ForegroundColor Green
    Write-Host "[+] Discovered repository branch mapping: '$Branch'" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "--- DYNAMIC MODULE SELECTION ---" -ForegroundColor Yellow
    
    if ($DynamicModules.Count -eq 0) {
        Write-Host "[X] Warning: No functional modules discovered or access denied." -ForegroundColor Warning
        Write-Host "    Verify token permissions for repository: $ModulesRepo" -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $DynamicModules.Count; $i++) {
            Write-Host "$($i + 1). $($DynamicModules[$i])"
        }
    }
    
    $ExitOptionNumber = $DynamicModules.Count + 1
    Write-Host "$ExitOptionNumber. Exit Launcher Enclave"
    Write-Host ""
    
    $InputSelection = (Read-Host "Select an option (1-$ExitOptionNumber)").Trim()
    
    # Validation checking
    if (-not [int]::TryParse($InputSelection, [ref]$SelectedNumber)) {
        Write-Host "`n[X] Invalid entry format. Use integers only." -ForegroundColor Red
        Start-Sleep -Seconds 1
        continue
    }

    if ($SelectedNumber -eq $ExitOptionNumber) {
        Write-Host "`n[-] Handing context control back to local initialization enclave..." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 750
        return 
    }
    elseif ($SelectedNumber -gt 0 -and $SelectedNumber -le $DynamicModules.Count) {
        $TargetModule = $DynamicModules[$SelectedNumber - 1]
        Write-Host "`n[+] Dispatching pipeline execution sequence for: $TargetModule..." -ForegroundColor Cyan
        
        try {
            # Construct API raw string download target path pointing to subfolder Entry.ps1
            $ModuleUrl = "https://api.github.com/repos/$RepoOwner/$ModulesRepo/contents/$TargetModule/Entry.ps1?ref=$Branch"
            
            # CRITICAL: We pass the raw media type accept header to fetch content stream directly
            $ScriptContent = Fetch-GitHubString -Url $ModuleUrl -AcceptType "application/vnd.github.v3.raw"
            
            if ($ScriptContent) {
                $ScriptBlock = [ScriptBlock]::Create($ScriptContent)
                
                # Execute module payload while piping down structural parameters
                & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            } else {
                throw "Downloaded script block returned empty payload."
            }
        } catch {
            Write-Host "[X] Dynamic Execution Faulted: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Target Endpoint: $ModuleUrl" -ForegroundColor DarkGray
        }
        Read-Host "`nPress Enter to return to module selection..."
    }
    else {
        Write-Host "`n[X] Selection context outside range boundaries." -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
}
