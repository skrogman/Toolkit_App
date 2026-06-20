# ==================================================================
# Target Repo Asset: skrogman/Toolkit_App/contents/Entry.ps1
# Architecture: Bootstrap -> Toolkit_App (Here) -> Toolkit_Modules
# ==================================================================

# --- [1] LIFECYCLE INITIALIZATION ---
$ScriptIdentity  = "ORCHESTRATOR"
$OrchStartTime   = Get-Date
$SystemLogStream = @()

function Add-DiagnosticLog {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = (Get-Date).ToString("HH:mm:ss")
    $Formatted = "[$Timestamp] [$ScriptIdentity] [$Level] $Message"
    $script:SystemLogStream += $Formatted
    
    # Also pass to fallback streams in case bootstrap is capturing them
    Write-Debug $Formatted -ErrorAction SilentlyContinue
    Write-Verbose $Formatted -ErrorAction SilentlyContinue
}

Add-DiagnosticLog "Pipeline lifecycle initialized at $($OrchStartTime.ToString('yyyy-MM-dd HH:mm:ss'))."

# --- [2] OMNI-TOKEN HARVESTING ENGINE ---
$TokenSource = "None"
$DiscoveredToken = $null

if ($global:GitHubToken) {
    $DiscoveredToken = $global:GitHubToken
    $TokenSource = "Global Variable (\$global:GitHubToken)"
} elseif ($GitHubToken) {
    $DiscoveredToken = $GitHubToken
    $TokenSource = "Local Variable (\$GitHubToken)"
} elseif ($env:GitHubToken) {
    $DiscoveredToken = $env:GitHubToken
    $TokenSource = "Environment Variable (env:GitHubToken)"
} elseif ($env:GITHUB_TOKEN) {
    $DiscoveredToken = $env:GITHUB_TOKEN
    $TokenSource = "Environment Variable (env:GITHUB_TOKEN)"
} else {
    # Deep memory scan for session tokens matching GitHub PAT layouts
    $SecretScan = Get-Variable | Where-Object { $_.Value -match '^(ghp_|github_pat_)' } | Select-Object -First 1
    if ($SecretScan) {
        $DiscoveredToken = $SecretScan.Value
        $TokenSource = "Memory Scan (Variable: $($SecretScan.Name))"
    }
}

$AuthHeader = @{ 'User-Agent' = 'Secure-IR-Enclave' }
if ($DiscoveredToken) {
    $AuthHeader.Add('Authorization', "Bearer $DiscoveredToken")
    Add-DiagnosticLog "Identity token successfully recovered via $TokenSource."
} else {
    Add-DiagnosticLog "CRITICAL: No identity token found across accessible scopes." "WARN"
}

# --- [3] BOOTSTRAP ENVIRONMENT INSPECTION ---
# Scan for any custom functions or log paths exposed by the wrapper
$DiscoveredLogUtils = Get-Command -Type Function | Where-Object { $_.Name -match 'log|debug|stream|write' } | Select-Object -ExpandProperty Name
if ($DiscoveredLogUtils) {
    Add-DiagnosticLog "Detected wrapper utilities in session context: ($($DiscoveredLogUtils -join ', '))."
}

# --- [4] NETWORK COMMUNICATOR & AUTOMATIC HEALING ---
function Invoke-SafeGitHubRequest {
    param([string]$Url)
    Add-DiagnosticLog "Dispatching API GET request to endpoint: $Url"
    $WebClient = New-Object System.Net.WebClient
    $WebClient.Headers.Add('User-Agent', $AuthHeader['User-Agent'])
    $WebClient.Headers.Add('Accept', "application/vnd.github.v3+json")
    if ($AuthHeader.ContainsKey('Authorization')) {
        $WebClient.Headers.Add('Authorization', $AuthHeader['Authorization'])
    }
    return $WebClient.DownloadString($Url)
}

# Dynamic validation routine targeting name variations (Underscore vs Hyphen)
$RepoOwner = "skrogman"
$RepoNamingOptions = @("Toolkit_Modules", "toolkit-modules")
$BranchOptions = @("main", "master")
$DynamicModules = @()
$ActiveRepoTarget = "None"
$ActiveBranchTarget = "None"
$DiscoveryError = $null
$RawJson = $null

:RepoLoop foreach ($RepoName in $RepoNamingOptions) {
    foreach ($BranchName in $BranchOptions) {
        $DiscoveryUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/contents?ref=$BranchName"
        try {
            $RawJson = Invoke-SafeGitHubRequest -Url $DiscoveryUrl
            if ($RawJson) {
                $ActiveRepoTarget = $RepoName
                $ActiveBranchTarget = $BranchName
                $DiscoveryError = $null
                break :RepoLoop
            }
        } catch {
            $DiscoveryError = $_.Exception.Message
            Add-DiagnosticLog "Endpoint rejected target $RepoName ($BranchName): $DiscoveryError" "WARN"
        }
    }
}

if ($RawJson) {
    try {
        $DynamicModules = $RawJson | ConvertFrom-Json | Where-Object { $_.type -eq 'dir' } | Select-Object -ExpandProperty name
        Add-DiagnosticLog "Dynamic discovery verified payload structures inside '$ActiveRepoTarget'."
    } catch {
        $DiscoveryError = "JSON Parsing Fault: $($_.Exception.Message)"
        Add-DiagnosticLog "Parsing error encountered reading GitHub payload structure maps." "ERROR"
    }
}

# --- [5] PERSISTENT UI & RUNTIME LOOP ---
while ($true) {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "            SECURE IR & ADMIN TOOLKIT             " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    
    # PERMANENT LIVE DIAGNOSTIC PANEL (Resilient to Clear-Host)
    Write-Host "--- SYSTEM RUNTIME LOG STREAM ---" -ForegroundColor DarkGray
    Write-Host " [*] Orchestrator Start : $($OrchStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
    Write-Host " [*] Active Token Source : $TokenSource" -ForegroundColor DarkGray
    Write-Host " [*] Active Target Path  : $RepoOwner/$ActiveRepoTarget ($ActiveBranchTarget)" -ForegroundColor DarkGray
    
    # Print the last 4 major diagnostic events permanently to the screen
    $LogSuffix = if ($SystemLogStream.Count -gt 4) { $SystemLogStream[-4..-1] } else { $SystemLogStream }
    foreach ($LogLine in $LogSuffix) {
        Write-Host "     $LogLine" -ForegroundColor DarkCyan
    }
    Write-Host "----------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "--- DYNAMIC MODULE SELECTION ---" -ForegroundColor Yellow
    if ($DynamicModules.Count -eq 0) {
        Write-Host "[X] Warning: No execution modules could be constructed." -ForegroundColor Yellow
        if ($DiscoveryError) { Write-Host "    Last API Error: $DiscoveryError" -ForegroundColor Red }
    } else {
        for ($i = 0; $i -lt $DynamicModules.Count; $i++) {
            Write-Host "$($i + 1). $($DynamicModules[$i])"
        }
    }
    
    $ExitOptionNumber = $DynamicModules.Count + 1
    Write-Host "$ExitOptionNumber. Exit Launcher Enclave"
    Write-Host ""
    
    # Input Sanitization
    $SelectedNumber = 0
    $InputSelection = (Read-Host "Select an option (1-$ExitOptionNumber)").Trim()
    
    if (-not [int]::TryParse($InputSelection, [ref]$SelectedNumber)) {
        Write-Host "`n[X] Invalid entry format. Use integers only." -ForegroundColor Red
        Start-Sleep -Seconds 1
        continue
    }

    if ($SelectedNumber -eq $ExitOptionNumber) {
        $OrchEndTime = Get-Date
        Add-DiagnosticLog "Purging orchestrator context. Execution boundary completed at $($OrchEndTime.ToString('HH:mm:ss'))."
        Write-Host "`n[-] Returning control to local initialization enclave..." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 500
        return 
    }
    elseif ($SelectedNumber -gt 0 -and $SelectedNumber -le $DynamicModules.Count) {
        $TargetModule = $DynamicModules[$SelectedNumber - 1]
        Add-DiagnosticLog "Handoff triggered. Dispatching execution boundary to module: $TargetModule"
        Write-Host "`n[+] Invoking execution routine for: $TargetModule..." -ForegroundColor Cyan
        
        try {
            $ModuleUrl = "https://api.github.com/repos/$RepoOwner/$ActiveRepoTarget/contents/$TargetModule/Entry.ps1?ref=$ActiveBranchTarget"
            $ScriptContent = Invoke-SafeGitHubRequest -Url $ModuleUrl
            
            if ([string]::IsNullOrWhiteSpace($ScriptContent)) { throw "Target endpoint payload returned empty data map." }
            
            # Formulate the child execution script block
            $ScriptBlock = [ScriptBlock]::Create($ScriptContent)
            
            # Execute child payload inside current safe context container
            & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            
            Add-DiagnosticLog "Module $TargetModule gracefully yielded control back to Orchestrator core."
        } catch {
            Add-DiagnosticLog "Fault identified inside dynamic payload thread: $($_.Exception.Message)" "ERROR"
            Write-Host "[X] Dynamic Execution Faulted: $($_.Exception.Message)" -ForegroundColor Red
        }
        Read-Host "`nPress Enter to return to module selection..."
    }
    else {
        Write-Host "`n[X] Selection context outside operational range." -ForegroundColor Red
        Start-Sleep -Seconds 1
    }
}
