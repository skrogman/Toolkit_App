<# : Begin batch
@echo off
setlocal
title Toolkit
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -Command "$f=[System.IO.File]::ReadAllText('%~f0'); Invoke-Expression $f"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[System.IO.File]::ReadAllText('%~f0'); Invoke-Expression $f"
)
echo execution is complete, we'll exit the cmd now
pause
endlocal
goto:eof
#>




# ==================================================================
# LOCAL BOOTSTRAPPER & ADMIN PANEL: Start-Toolkit.ps1
# Features: PS5 -> PS7 Auto-Handoff, Global PAT Inheritance,
#           Hidden PIN Entry, and Anonymous Public Downloads
# ==================================================================
$ErrorActionPreference = "Stop"

# Establish execution path fallback environments
$ScriptRootPath = if ([string]::IsNullOrEmpty($PSScriptRoot)) { $PWD.Path } else { $PSScriptRoot }
$ConfigFile = Join-Path $ScriptRootPath "start-toolkit.cfg"
$global:ToolkitDebugMode = $false

# --- [0] HARDWARE KEY REGISTER & STATE INHERITANCE ---
try {
    $SourceCode = @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32Keyboard {
        [DllImport("user32.dll")]
        public static extern short GetKeyState(int nVirtKey);
    }
'@
    Add-Type -TypeDefinition $SourceCode -ErrorAction SilentlyContinue
    $ShiftPressed = (([Win32Keyboard]::GetKeyState(0x10) -band 0x8000) -eq 0x8000)
} catch {
    $ShiftPressed = [System.Windows.Forms.Control]::ModifierKeys.HasFlag([System.Windows.Forms.Keys]::Shift)
}

# Catch the environment flag if we just did a PS5 -> PS7 Engine Handoff
if ($env:TK_FORCE_MENU -eq "1") { $ShiftPressed = $true }

# --- [1] ENGINE HANDOFF: PS 5.1 CLS-COMPLIANCE BYPASS ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "`n[!] Legacy PowerShell 5.1 Engine Detected." -ForegroundColor DarkGray
    Write-Host "[+] Terminal.Gui TUI requires PowerShell 7+ (pwsh) to bypass CLS compliance crashes." -ForegroundColor Cyan
    Write-Host "[+] Handing off execution to pwsh.exe natively..." -ForegroundColor Green
    Start-Sleep -Milliseconds 600

    # Carry the Shift key menu state over the process boundary
    if ($ShiftPressed) { [System.Environment]::SetEnvironmentVariable("TK_FORCE_MENU", "1", "Process") }
    
    $TargetScript = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { Join-Path $ScriptRootPath "Start-Toolkit.ps1" }
    
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $Proc = Start-Process pwsh.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$TargetScript`"" -PassThru -Wait -NoNewWindow
        Exit $Proc.ExitCode
    } else {
        Write-Host "`n[!] FATAL: pwsh.exe (PowerShell 7) is not installed or not in your system PATH!" -ForegroundColor Red
        Write-Host "Please install PowerShell 7 to run Terminal.Gui orchestrator modules." -ForegroundColor Red
        Read-Host "Press [Enter] to abort"
        Exit
    }
}

# --- CRYPTO & ALIGNMENT HELPERS ---
function New-UserTokenConfig {
    Clear-Host
    Write-Host "=== ROLL / ENCODE USER PAT DATA ===" -ForegroundColor Yellow
    $Username = Read-Host "Enter Target Username (e.g., Steve)"
    if ([string]::IsNullOrEmpty($Username)) { return }
    
    $RawToken = Read-Host "Paste New GitHub Plain-text PAT"
    
    Write-Host "Establish Access PIN for this Profile: " -NoNewline -ForegroundColor White
    $UserPin = Read-Host -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UserPin)
    $PlainPin = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    
    if ([string]::IsNullOrEmpty($RawToken) -or [string]::IsNullOrEmpty($PlainPin)) {
        Write-Host "`n[-] Error: Token and PIN cannot be blank." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $Salt = [guid]::NewGuid().ToString().Replace("-","").Substring(0,16)
    $SecretKey = "$PlainPin$Salt".PadRight(32).Substring(0,32)
    
    $TokenBytes = [System.Text.Encoding]::Unicode.GetBytes($RawToken)
    $KeyBytes   = [System.Text.Encoding]::Unicode.GetBytes($SecretKey)
    $MixedBytes = New-Object byte[] $TokenBytes.Length
    
    for($i=0; $i -lt $TokenBytes.Length; $i++) {
        $MixedBytes[$i] = $TokenBytes[$i] -bxor $KeyBytes[$i % $KeyBytes.Length]
    }
    
    $EncodedPayload = [System.Convert]::ToBase64String($MixedBytes)
    $FinalConfigString = "$Salt|$EncodedPayload|$([guid]::NewGuid().ToString().Replace('-',''))"
    
    $CurrentConfig = @{ PublicRepo = @{ Owner = "skrogman"; Name = "Toolkit_App"; Branch = "main" }; Users = @{}; Settings = @{ PublicOwner = "skrogman"; PublicRepo = "Toolkit_Modules"; PublicBranch = "main"; VerboseMode = "true" } }
    if (Test-Path $ConfigFile) {
        $CurrentConfig = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    }
    
    $CurrentConfig.Users.$Username = $FinalConfigString
    $CurrentConfig | ConvertTo-Json -Depth 5 | Out-File -FilePath $ConfigFile -Encoding utf8
    
    Write-Host "`n[+] SUCCESS: Profile '$Username' securely encoded to config." -ForegroundColor Green
    Start-Sleep -Seconds 2
    Clear-Host
}

function Get-DecodedToken($Config) {
    Write-Host "`n=== PROFILE ACCESS VALIDATION ===" -ForegroundColor Yellow
    $Username = Read-Host "Identify User Profile"
    
    if (-not $Config.Users.$Username) {
        throw "Requested profile '$Username' does not exist in the local configuration storage."
    }
    
    Write-Host "Enter Security PIN for '$Username': " -NoNewline -ForegroundColor White
    $SecurePin = Read-Host -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePin)
    $UserPin = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    Write-Host "" 

    $EncodedToken = $Config.Users.$Username
    
    if ($EncodedToken -match '\|') {
        $Segments = $EncodedToken.Split('|')
        $Salt = $Segments[0]
        $Payload = $Segments[1]
        
        $SecretKey = "$UserPin$Salt".PadRight(32).Substring(0,32)
        $MixedBytes = [System.Convert]::FromBase64String($Payload)
        $KeyBytes   = [System.Text.Encoding]::Unicode.GetBytes($SecretKey)
        $DecodedBytes = New-Object byte[] $MixedBytes.Length
        
        for($i=0; $i -lt $MixedBytes.Length; $i++) {
            $DecodedBytes[$i] = $MixedBytes[$i] -bxor $KeyBytes[$i % $KeyBytes.Length]
        }
        
        return [System.Text.Encoding]::Unicode.GetString($DecodedBytes).Trim().Replace("`0", "")
    } else {
        $RawBytes = [System.Convert]::FromBase64String($EncodedToken)
        return [System.Text.Encoding]::UTF8.GetString($RawBytes).Trim().Replace("`0", "")
    }
}

function Invoke-DiagnosticsEngine($AuthHeader, $Config) {
    Clear-Host
    $Owner  = if ($Config.Settings.PublicOwner) { $Config.Settings.PublicOwner } else { "skrogman" }
    $Repo   = if ($Config.Settings.PublicRepo) { $Config.Settings.PublicRepo } else { "Toolkit_Modules" }
    $Branch = if ($Config.Settings.PublicBranch) { $Config.Settings.PublicBranch } else { "main" }

    Write-Host "=====================================================================" -ForegroundColor Yellow
    Write-Host "                     LIVE ENVIRONMENT RUNTIME DEBUG                  " -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Yellow
    Write-Host "  * Target Repository: $Owner/$Repo [$Branch]" -ForegroundColor Gray
    Write-Host "  * Token Status      : Transmitted via Encrypted Local Config File" -ForegroundColor Gray
    Write-Host "=====================================================================`n" -ForegroundColor Yellow
    
    Write-Host "[DEBUG] Testing cloud connectivity to Private Modules via API..." -ForegroundColor Cyan
    $TestUrl = "https://api.github.com/repos/$Owner/$Repo/contents?ref=$Branch"
    try {
        $TestResponse = Invoke-RestMethod -Uri $TestUrl -Headers $AuthHeader -Method Get -UseBasicParsing
        Write-Host "[DEBUG] SUCCESS: Private API communication clean. Discovered $($TestResponse.Count) files." -ForegroundColor Green
    } catch {
        Write-Host "[DEBUG] FAILURE: GitHub API rejected connection!" -ForegroundColor Red
        Write-Host "[DEBUG] Error Message: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`n[DEBUG] Pulling cloud master orchestrator payload..." -ForegroundColor Cyan
    $CacheBuster = [guid]::NewGuid().ToString()
    $MasterOrchestratorUrl = "https://raw.githubusercontent.com/$Owner/Toolkit_App/$Branch/Entry.ps1?t=$CacheBuster"

    try {
        $FetchHeaders = if ($AuthHeader) { $AuthHeader } else { @{} }
        $MasterCode = Invoke-RestMethod -Uri $MasterOrchestratorUrl -Headers $FetchHeaders -UseBasicParsing
        Write-Host "[DEBUG] Code payload loaded ($($MasterCode.Length) characters)." -ForegroundColor Green
        Write-Host "`n[DEBUG] Executing Cloud Code Block...`n" -ForegroundColor Yellow

        $ScriptBlock = [scriptblock]::Create($MasterCode)
        $ErrorActionPreference = "Continue"
        . $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $Owner -TargetRepo $Repo -Branch $Branch
    } catch {
        Write-Host "[!] Diagnostics caught an execution crash: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`n=====================================================================" -ForegroundColor Yellow
    Write-Host " [!] DEBUG RUN COMPLETED. Console output preserved for analysis." -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Yellow
    Read-Host "Press [Enter] to exit the admin diagnostic workspace panel"
}

function Show-ConfigMenu {
    while ($true) {
        Clear-Host
        Write-Host "=====================================================================" -ForegroundColor Yellow
        Write-Host "             IR TOOLKIT - LOCAL ADMINISTRATION PANEL                  " -ForegroundColor Yellow
        Write-Host "=====================================================================" -ForegroundColor Yellow
        Write-Host "  1) Launch Cloud Diagnostics (Debug Engine Mode)" -ForegroundColor Cyan
        Write-Host "  2) Roll / Encode New User PAT (Add/Update User with PIN)" -ForegroundColor Cyan
        Write-Host "  3) List Currently Configured Users" -ForegroundColor Cyan
        Write-Host "  4) Exit Administration Panel and Start Production Handoff" -ForegroundColor Green
        Write-Host "  5) Abort & Exit Completely" -ForegroundColor Red
        Write-Host "=====================================================================" -ForegroundColor Yellow
        
        $MenuChoice = Read-Host "Select an administration option [1-5]"
        
        switch ($MenuChoice.Trim()) {
            "1" {
                if (-not (Test-Path $ConfigFile)) { Write-Host "[!] Create a user via option 2 first." -ForegroundColor Red; Start-Sleep -Seconds 2; continue }
                $Cfg = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                try {
                    $Token = Get-DecodedToken -Config $Cfg
                    
                    # Ensure downstream payload gets Token variables inside debug as well
                    $global:ToolkitAuthHeader = @{ "Authorization" = "Bearer $Token" }
                    $env:GITHUB_TOKEN = $Token
                    $global:GITHUB_TOKEN = $Token
                    
                    Invoke-DiagnosticsEngine -AuthHeader $global:ToolkitAuthHeader -Config $Cfg
                } catch {
                    Write-Host "`n[!] Authentication Blocked: $($_.Exception.Message)" -ForegroundColor Red
                    Read-Host "Press [Enter] to return to menu"
                }
            }
            "2" { New-UserTokenConfig }
            "3" {
                if (Test-Path $ConfigFile) {
                    $Data = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                    Write-Host "`nConfigured Profiles:" -ForegroundColor Yellow
                    $Data.Users.PSObject.Properties | ForEach-Object { Write-Host " -> $($_.Name)" -ForegroundColor Gray }
                } else { Write-Host "[!] No configuration file detected yet." -ForegroundColor Red }
                Read-Host "`nPress [Enter] to return to menu"
            }
            "4" { return }
            "5" { Exit }
        }
    }
}

# Route to menu if trigger state exists
if ($ShiftPressed) {
    Show-ConfigMenu
    Clear-Host
}

# --- [2] SINGLE-INSTANCE LOCK SYSTEM ---
$MutexName  = "Global\SkrogmanIRToolkitEnclaveLock"
$CreatedNew = $false
$Mutex      = [System.Threading.Mutex]::new($true, $MutexName, [ref]$CreatedNew)

if (-not $CreatedNew) {
    Write-Host "`n[!] WARNING: Another instance of Toolkit Enclave is already running!" -ForegroundColor Yellow
    $Choice = Read-Host "Allow multi-instance? [Y]es / [N or Enter] to kill old sessions & launch"
    
    if ($Choice.Trim().ToUpper() -eq 'Y') {
        Write-Host "[+] Running in Multi-Instance mode. Bypassing lock..." -ForegroundColor Cyan
        if ($Mutex) { $Mutex.Dispose(); $Mutex = $null }
    } else {
        Write-Host "[+] Initiating process wipe to take over instance lock..." -ForegroundColor Cyan
        $CurrentPID = $PID
        $ProcList = Get-CimInstance -ClassName Win32_Process -Filter "Name like 'powershell%.exe' or Name like 'pwsh%.exe' or Name like 'cmd.exe'"
        $OtherInstances = $ProcList | Where-Object {
            $_.ProcessId -ne $CurrentPID -and ($_.CommandLine -match "Start-Toolkit" -or $_.CommandLine -match "start-toolkit")
        }
        foreach ($P in $OtherInstances) {
            Stop-Process -Id $P.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 600
        if ($Mutex) { $Mutex.Dispose() }
        $Mutex = [System.Threading.Mutex]::new($true, $MutexName, [ref]$CreatedNew)
    }
}

try {
    Write-Host "[+] System Mutex verified. Ingesting assets..." -ForegroundColor DarkGray

    # --- [3] STANDARD PRODUCTION INGESTION WORKFLOW ---
    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing at: $ConfigFile. Hold down the SHIFT key on boot to open the setup menu."
    }

    $Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    $YourToken = Get-DecodedToken -Config $Config

    # --- [4] GLOBAL DOWNSTREAM INHERITANCE INJECTION ---
    # Shotgun the token into standard environmental variables to fix the 404
    # This guarantees the Entry.ps1 orchestrator inherits full private access rights
    $global:ToolkitAuthHeader = @{ "Authorization" = "Bearer $YourToken" } 
    $env:GITHUB_TOKEN         = $YourToken
    $global:GITHUB_TOKEN      = $YourToken
    $global:ToolkitPAT        = $YourToken
    
    $global:ToolkitRepoOwner  = if ($Config.Settings.PublicOwner) { $Config.Settings.PublicOwner } else { "skrogman" }
    $global:ToolkitTargetRepo = if ($Config.Settings.PublicRepo) { $Config.Settings.PublicRepo } else { "Toolkit_Modules" }
    $global:ToolkitBranch     = if ($Config.Settings.PublicBranch) { $Config.Settings.PublicBranch } else { "main" }

    # --- [5] STANDARD PRODUCTION HANDOFF ---
    $CacheBuster = [guid]::NewGuid().ToString()
    $MasterOrchestratorUrl = "https://raw.githubusercontent.com/$($global:ToolkitRepoOwner)/Toolkit_App/$($global:ToolkitBranch)/Entry.ps1?t=$CacheBuster"

    $MasterCode = Invoke-RestMethod -Uri $MasterOrchestratorUrl -UseBasicParsing
    $ScriptBlock = [scriptblock]::Create($MasterCode)

    Clear-Host
    . $ScriptBlock -AuthHeader $global:ToolkitAuthHeader -RepoOwner $global:ToolkitRepoOwner -TargetRepo $global:ToolkitTargetRepo -Branch $global:ToolkitBranch

} catch {
    Write-Host "`n[!] Critical Failure during initialization: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press [Enter] to exit"
} finally {
    if ($Mutex) {
        $Mutex.ReleaseMutex()
        $Mutex.Dispose()
    }
}
