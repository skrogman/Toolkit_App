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

# Catch the flag file written by option 6 before elevation — survives UAC process boundary
$_AdminMenuFlag = Join-Path $env:TEMP "toolkit_admin_menu.flag"
if (Test-Path $_AdminMenuFlag) {
    $ShiftPressed = $true
    Remove-Item $_AdminMenuFlag -Force -ErrorAction SilentlyContinue
}

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


function Get-ConsoleWindowRect {
    try {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class ConWin {
    [DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@ -ErrorAction SilentlyContinue
        $h = [ConWin]::GetConsoleWindow()
        $r = New-Object ConWin+RECT
        [ConWin]::GetWindowRect($h, [ref]$r) | Out-Null
        return $r
    } catch { return $null }
}

function Show-ConfigMenu {
    # --- Auto-reconnect to debug window from pre-elevation session ---
    $pidFile = Join-Path $env:TEMP "toolkit_debug_active.pid"
    $logFile = Join-Path $env:TEMP "toolkit_debug_active.log"
    if ((Test-Path $pidFile) -and (Test-Path $logFile)) {
        $savedPid = try { [int](Get-Content $pidFile -Raw).Trim() } catch { -1 }
        if ($savedPid -gt 0) {
            $wpfProc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($wpfProc -and -not $wpfProc.HasExited) {
                # Load module if not already loaded (don't stop on error — we wire up manually below)
                $DbgTemp = Join-Path $env:TEMP "DebugWindow.psm1"
                if (-not (Test-Path $DbgTemp)) {
                    try { Invoke-RestMethod "https://raw.githubusercontent.com/skrogman/Toolkit_App/main/DebugWindow.psm1?t=$([guid]::NewGuid())" -OutFile $DbgTemp -UseBasicParsing } catch {}
                }
                if (Test-Path $DbgTemp) { try { Import-Module $DbgTemp -Force -ErrorAction SilentlyContinue } catch {} }

                # Wire up globals directly — Import-Module resets DebugSync so we must do this AFTER import
                $Global:DebugSync = [hashtable]::Synchronized(@{
                    LogFile = $logFile
                    Running = $true
                    WpfProc = $wpfProc
                })

                # Write reconnect banner straight to log file (bypasses sync-state check)
                $isElev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                [System.IO.File]::AppendAllText($logFile, "[$ts] [INFO ] === Debug console reconnected | Elevated: $isElev ===`r`n", [System.Text.Encoding]::UTF8)
                Write-Host "[+] Debug console reconnected (PID $savedPid, Elevated: $isElev)" -ForegroundColor Green
            }
        }
    }

    while ($true) {
        Clear-Host
        Write-Host "=====================================================================" -ForegroundColor Yellow
        Write-Host "             IR TOOLKIT - LOCAL ADMINISTRATION PANEL                  " -ForegroundColor Yellow
        Write-Host "=====================================================================" -ForegroundColor Yellow
        $_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $_dbgTag  = if ($Global:DebugSync -and $Global:DebugSync.Running) { " [Running]" } else { "" }
        $_admTag  = if ($_isAdmin) { " [Elevated]" } else { " [Not Elevated]" }

        Write-Host "  1) Open Debug Console$_dbgTag" -ForegroundColor Cyan
        Write-Host "  2) Roll / Encode New User PAT (Add/Update User with PIN)" -ForegroundColor Cyan
        Write-Host "  3) List Currently Configured Users" -ForegroundColor Cyan
        Write-Host "  4) Exit Administration Panel and Start Production Handoff" -ForegroundColor Green
        Write-Host "  5) Abort & Exit Completely" -ForegroundColor Red
        Write-Host "  6) Relaunch as Administrator$_admTag" -ForegroundColor Magenta
        Write-Host "  7) Authenticate & Launch Toolkit" -ForegroundColor Green
        Write-Host "=====================================================================" -ForegroundColor Yellow

        $MenuChoice = Read-Host "Select an administration option [1-7]"

        switch ($MenuChoice.Trim()) {
            "1" {
                if ($Global:DebugSync -and $Global:DebugSync.Running) {
                    Write-Host "[!] Debug console is already open." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1; continue
                }
                try {
                    Write-Host "[*] Fetching debug module from Toolkit_App repo..." -ForegroundColor DarkGray
                    $DbgTemp = Join-Path $env:TEMP "DebugWindow.psm1"
                    $cb = [guid]::NewGuid().ToString()
                    Invoke-RestMethod -Uri "https://raw.githubusercontent.com/skrogman/Toolkit_App/main/DebugWindow.psm1?t=$cb" -OutFile $DbgTemp -UseBasicParsing
                    Import-Module $DbgTemp -Force -ErrorAction Stop
                    $rect = Get-ConsoleWindowRect
                    $dbgX = if ($rect) { $rect.Left } else { -1 }
                    $dbgY = if ($rect) { [Math]::Max(0, $rect.Bottom + 5) } else { -1 }
                    Start-DebugWindow -X $dbgX -Y $dbgY
                    Start-Sleep -Milliseconds 800
                    Write-DebugWindow "=== TOOLKIT DEBUG CONSOLE ===" -Level INFO
                    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                    Write-DebugWindow "Running as Administrator: $IsAdmin" -Level INFO
                    Write-DebugWindow "Select option 7 to authenticate and launch, or 6 to relaunch elevated." -Level INFO
                } catch {
                    Write-Host "`n[!] Failed to launch debug console: $($_.Exception.Message)" -ForegroundColor Red
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
            "6" {
                if ($_isAdmin) {
                    Write-Host "`n[!] Already running as Administrator." -ForegroundColor Yellow
                    if ($Global:DebugSync -and $Global:DebugSync.Running) { Write-DebugWindow "Already elevated — no relaunch needed." -Level WARN }
                    Start-Sleep -Seconds 2
                } else {
                    $CmdFile = Join-Path $ScriptRootPath 'Start-Toolkit.cmd'
                    Write-Host "`n  Launching: $CmdFile" -ForegroundColor DarkGray
                    if ($Global:DebugSync -and $Global:DebugSync.Running) {
                        Write-DebugWindow "Relaunching as Administrator — debug console will stay open." -Level WARN
                        Start-Sleep -Milliseconds 500
                    }
                    Write-Host "[*] A UAC prompt will appear — click Yes to elevate..." -ForegroundColor Yellow
                    $flagPath = Join-Path $env:TEMP "toolkit_admin_menu.flag"
                    try {
                        # Flag written inside try — only persists if Start-Process succeeds
                        [System.IO.File]::WriteAllText($flagPath, "1")
                        Start-Process -FilePath $CmdFile -Verb RunAs -ErrorAction Stop
                        Write-Host "[+] Elevated process launched. This window will close." -ForegroundColor Green
                        Start-Sleep -Milliseconds 400
                        [Environment]::Exit(0)
                    } catch {
                        Remove-Item $flagPath -Force -ErrorAction SilentlyContinue
                        Write-Host "`n[!] Elevation failed or UAC was denied." -ForegroundColor Red
                        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkRed
                        Write-Host "    Tip: right-click Start-Toolkit.cmd → 'Run as administrator'" -ForegroundColor Yellow
                        if ($Global:DebugSync -and $Global:DebugSync.Running) {
                            Write-DebugWindow "Elevation FAILED: $($_.Exception.Message)" -Level ERROR
                        }
                        Read-Host "`nPress [Enter] to return to menu"
                    }
                }
            }
            "7" {
                if (-not (Test-Path $ConfigFile)) {
                    Write-Host "[!] Create a user via option 2 first." -ForegroundColor Red
                    Start-Sleep -Seconds 2; continue
                }
                try {
                    $Cfg   = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                    $Token = Get-DecodedToken -Config $Cfg

                    $global:ToolkitAuthHeader = @{ Authorization = "Bearer $Token" }
                    $global:ToolkitPAT        = $Token
                    $global:ToolkitRepoOwner  = if ($Cfg.Settings.PublicOwner)  { $Cfg.Settings.PublicOwner  } else { "skrogman" }
                    $global:ToolkitTargetRepo = if ($Cfg.Settings.PublicRepo)   { $Cfg.Settings.PublicRepo   } else { "Toolkit_Modules" }
                    $global:ToolkitBranch     = if ($Cfg.Settings.PublicBranch) { $Cfg.Settings.PublicBranch } else { "main" }
                    $global:ToolkitDebugMode  = ($Global:DebugSync -and $Global:DebugSync.Running)

                    if ($Global:DebugSync -and $Global:DebugSync.Running) {
                        $Snip = if ($Token.Length -ge 10) { $Token.Substring(0,10) + "..." } else { "(empty)" }
                        Write-DebugWindow "=== AUTHENTICATION ===" -Level INFO
                        Write-DebugWindow "Target : $($global:ToolkitRepoOwner)/$($global:ToolkitTargetRepo) [$($global:ToolkitBranch)]" -Level INFO
                        Write-DebugWindow "Token  : $Snip" -Level INFO
                        Write-DebugWindow "Testing GitHub API connectivity..." -Level INFO
                        try {
                            $Res = Invoke-RestMethod -Uri "https://api.github.com/repos/$($global:ToolkitRepoOwner)/$($global:ToolkitTargetRepo)/contents?ref=$($global:ToolkitBranch)" `
                                -Headers $global:ToolkitAuthHeader -Method Get -UseBasicParsing
                            Write-DebugWindow "API OK — $($Res.Count) items in repo root" -Level INFO
                        } catch {
                            Write-DebugWindow "API FAIL: $($_.Exception.Message)" -Level ERROR
                        }
                        Write-DebugWindow "Handing off to TUI..." -Level INFO
                    }
                    return
                } catch {
                    Write-Host "`n[!] Auth failed: $($_.Exception.Message)" -ForegroundColor Red
                    Read-Host "Press [Enter] to return to menu"
                }
            }
        }
    }
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

# Route to admin menu if Shift was held — mutex is already held so only one instance can enter
if ($ShiftPressed) {
    Show-ConfigMenu
    Clear-Host
}

try {
    Write-Host "[+] System Mutex verified. Ingesting assets..." -ForegroundColor DarkGray

    # --- [3] STANDARD PRODUCTION INGESTION WORKFLOW ---
    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing at: $ConfigFile. Hold down the SHIFT key on boot to open the setup menu."
    }

    # --- [4] AUTH — skip if debug mode already set globals via option 1 ---
    if (-not $global:ToolkitAuthHeader) {
        $Config    = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        $YourToken = Get-DecodedToken -Config $Config

        $global:ToolkitAuthHeader = @{ "Authorization" = "Bearer $YourToken" }
        $env:GITHUB_TOKEN         = $YourToken
        $global:GITHUB_TOKEN      = $YourToken
        $global:ToolkitPAT        = $YourToken
        $global:ToolkitRepoOwner  = if ($Config.Settings.PublicOwner)  { $Config.Settings.PublicOwner  } else { "skrogman" }
        $global:ToolkitTargetRepo = if ($Config.Settings.PublicRepo)   { $Config.Settings.PublicRepo   } else { "Toolkit_Modules" }
        $global:ToolkitBranch     = if ($Config.Settings.PublicBranch) { $Config.Settings.PublicBranch } else { "main" }
    }

    # --- [5] LOAD ENTRY.PS1 — local file in debug mode, CDN otherwise ---
    $LocalEntry = Join-Path $ScriptRootPath 'Entry.ps1'
    if ($global:ToolkitDebugMode -and (Test-Path $LocalEntry)) {
        if ($Global:DebugSync -and $Global:DebugSync.Running) {
            Write-DebugWindow "Loading local Entry.ps1 (debug mode — no CDN)" -Level DEBUG
        }
        $MasterCode = Get-Content -Path $LocalEntry -Raw
    } else {
        $CacheBuster           = [guid]::NewGuid().ToString()
        $MasterOrchestratorUrl = "https://raw.githubusercontent.com/$($global:ToolkitRepoOwner)/Toolkit_App/$($global:ToolkitBranch)/Entry.ps1?t=$CacheBuster"
        $MasterCode            = Invoke-RestMethod -Uri $MasterOrchestratorUrl -UseBasicParsing
    }

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
