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

# Catch the flag file written by option 6 before elevation — shared dir survives cross-user UAC boundary
$_ToolkitShared = Join-Path $env:ProgramData "CassenaCareToolkit"
if (-not (Test-Path $_ToolkitShared)) { $null = New-Item -Path $_ToolkitShared -ItemType Directory -Force -ErrorAction SilentlyContinue }
$_AdminMenuFlag = Join-Path $_ToolkitShared "toolkit_admin_menu.flag"
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
    $SecurePinEnroll = Read-Host -AsSecureString
    $BSTR_E    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePinEnroll)
    $PlainPin  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR_E)

    if ([string]::IsNullOrEmpty($RawToken) -or [string]::IsNullOrEmpty($PlainPin)) {
        Write-Host "`n[-] Error: Token and PIN cannot be blank." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    # AES-256-CBC + PBKDF2 (100k iterations, SHA-256)
    $rng       = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    $saltBytes = New-Object byte[] 32; $rng.GetBytes($saltBytes)
    $ivBytes   = New-Object byte[] 16; $rng.GetBytes($ivBytes)
    $derive    = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                     $PlainPin, $saltBytes, 100000,
                     [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $key       = $derive.GetBytes(32)
    $aes       = [System.Security.Cryptography.Aes]::Create()
    $aes.Key   = $key; $aes.IV = $ivBytes
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $enc       = $aes.CreateEncryptor()
    $plain     = [System.Text.Encoding]::UTF8.GetBytes($RawToken)
    $cipher    = $enc.TransformFinalBlock($plain, 0, $plain.Length)
    $tokenStr  = "v2|{0}|{1}|{2}" -f [Convert]::ToBase64String($saltBytes),
                                       [Convert]::ToBase64String($ivBytes),
                                       [Convert]::ToBase64String($cipher)

    $CurrentConfig = [PSCustomObject]@{
        PublicRepo = [PSCustomObject]@{ Owner = "skrogman"; Name = "Toolkit_App"; Branch = "main" }
        Roles      = [PSCustomObject]@{
            admin = [PSCustomObject]@{ tags = @("*") }
            basic = [PSCustomObject]@{ tags = @("basic-access") }
        }
        Users    = [PSCustomObject]@{}
        Settings = [PSCustomObject]@{
            PublicOwner  = "skrogman"
            PublicRepo   = "Toolkit_Modules"
            PublicBranch = "main"
            VerboseMode  = "true"
            DefaultRole  = "basic"
        }
    }
    if (Test-Path $ConfigFile) {
        $CurrentConfig = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
    }

    $existingRoles = if ($CurrentConfig.Roles) {
        ($CurrentConfig.Roles.PSObject.Properties.Name) -join ", "
    } else { "(none yet)" }
    Write-Host "  Available roles: $existingRoles" -ForegroundColor DarkGray
    $AssignedRole = (Read-Host "Assign role for '$Username' (blank = use DefaultRole)").Trim()
    $GodModeInput = (Read-Host "Enable God Mode for '$Username'? Bypasses all tag filters — sees every module [y/N]").Trim().ToLower()
    $GodMode      = ($GodModeInput -eq 'y')

    if (-not $CurrentConfig.Users) {
        $CurrentConfig | Add-Member -NotePropertyName Users -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $userEntry = [PSCustomObject]@{ token = $tokenStr; role = $AssignedRole; godMode = $GodMode }
    if ($CurrentConfig.Users.PSObject.Properties[$Username]) {
        $CurrentConfig.Users.$Username = $userEntry
    } else {
        $CurrentConfig.Users | Add-Member -NotePropertyName $Username -NotePropertyValue $userEntry -Force
    }
    $CurrentConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigFile -Encoding utf8

    Write-Host "`n[+] SUCCESS: Profile '$Username' enrolled with AES-256 encryption." -ForegroundColor Green
    Start-Sleep -Seconds 2
    Clear-Host
}

function Get-DecodedToken($Config) {
    Write-Host "`n=== PROFILE ACCESS VALIDATION ===" -ForegroundColor Yellow
    $Username = (Read-Host "Identify User Profile").Trim()

    if (-not $Config.Users.$Username) {
        throw "Requested profile '$Username' does not exist in the local configuration storage."
    }
    $script:LastAuthedUsername = $Username

    Write-Host "Enter Security PIN for '$Username': " -NoNewline -ForegroundColor White
    $SecurePin = Read-Host -AsSecureString
    $BSTR_D    = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePin)
    $UserPin   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR_D)
    Write-Host ""

    $userObj  = $Config.Users.$Username
    $tokenStr = if ($userObj -is [string]) { $userObj } else { $userObj.token   }
    $roleStr  = if ($userObj -is [string]) { $null    } else { $userObj.role    }
    $godMode  = if ($userObj -is [string]) { $false   } else { [bool]$userObj.godMode }

    $parts = $tokenStr -split '\|'
    if ($parts[0] -ne 'v2') {
        throw "Profile '$Username' uses an outdated token format. Please re-enroll via Option 2."
    }

    try {
        $saltBytes = [Convert]::FromBase64String($parts[1])
        $ivBytes   = [Convert]::FromBase64String($parts[2])
        $cipher    = [Convert]::FromBase64String($parts[3])
        $derive    = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                         $UserPin, $saltBytes, 100000,
                         [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $key       = $derive.GetBytes(32)
        $aes       = [System.Security.Cryptography.Aes]::Create()
        $aes.Key   = $key; $aes.IV = $ivBytes
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $dec   = $aes.CreateDecryptor()
        $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        $pat   = [System.Text.Encoding]::UTF8.GetString($plain).Trim()
    } catch [System.Security.Cryptography.CryptographicException] {
        throw "Incorrect PIN for profile '$Username'."
    }

    return @{ PAT = $pat; Role = $roleStr; GodMode = $godMode }
}

function Invoke-RoleManager {
    while ($true) {
        Clear-Host
        Write-Host "=== ROLE MANAGER ===" -ForegroundColor Yellow

        $Cfg = if (Test-Path $ConfigFile) { Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json } else { $null }
        $DefaultRole = if ($Cfg -and $Cfg.Settings -and $Cfg.Settings.DefaultRole) { $Cfg.Settings.DefaultRole } else { "(not set)" }
        Write-Host "  Default Role: $DefaultRole`n" -ForegroundColor DarkGray

        if ($Cfg -and $Cfg.Roles) {
            Write-Host "  Configured Roles:" -ForegroundColor Yellow
            $Cfg.Roles.PSObject.Properties | ForEach-Object {
                $tags = if ($_.Value.tags) { $_.Value.tags -join ', ' } else { "(no tags)" }
                Write-Host "    $($_.Name)  ->  $tags" -ForegroundColor Gray
            }
        } else {
            Write-Host "  (No roles defined yet)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  a) Create / edit role"          -ForegroundColor Cyan
        Write-Host "  b) Delete role"                 -ForegroundColor Cyan
        Write-Host "  c) Set default role"            -ForegroundColor Cyan
        Write-Host "  d) Toggle God Mode for a user"  -ForegroundColor Yellow
        Write-Host "  e) Back"                        -ForegroundColor Gray
        Write-Host ""

        $RChoice = (Read-Host "  Select [a/b/c/d/e]").Trim().ToLower()

        switch ($RChoice) {
            "a" {
                $RoleName = (Read-Host "  Role name (e.g. admin, analyst, basic)").Trim()
                if ([string]::IsNullOrEmpty($RoleName)) { break }
                $CfgW = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                if ($CfgW.Roles -and $CfgW.Roles.PSObject.Properties[$RoleName]) {
                    Write-Host "  Current tags: $($CfgW.Roles.$RoleName.tags -join ', ')" -ForegroundColor DarkGray
                }
                $TagInput = (Read-Host "  Tags (comma-separated, wildcards ok, e.g. basic-access, *)").Trim()
                $Tags = @($TagInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                if ($Tags.Count -eq 0) { Write-Host "  [!] No tags provided." -ForegroundColor Red; Start-Sleep 1; break }
                if (-not $CfgW.Roles) { $CfgW | Add-Member -NotePropertyName Roles -NotePropertyValue ([PSCustomObject]@{}) -Force }
                $roleObj = [PSCustomObject]@{ tags = $Tags }
                if ($CfgW.Roles.PSObject.Properties[$RoleName]) {
                    $CfgW.Roles.$RoleName = $roleObj
                } else {
                    $CfgW.Roles | Add-Member -NotePropertyName $RoleName -NotePropertyValue $roleObj -Force
                }
                $CfgW | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigFile -Encoding utf8
                Write-Host "  [+] Role '$RoleName' saved with tags: $($Tags -join ', ')" -ForegroundColor Green
                Start-Sleep 1
            }
            "b" {
                $RoleName = (Read-Host "  Role to delete").Trim()
                if ([string]::IsNullOrEmpty($RoleName)) { break }
                $CfgW = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                if (-not ($CfgW.Roles -and $CfgW.Roles.PSObject.Properties[$RoleName])) {
                    Write-Host "  [!] Role '$RoleName' not found." -ForegroundColor Red; Start-Sleep 1; break
                }
                $affected = @($CfgW.Users.PSObject.Properties | Where-Object { $_.Value.role -eq $RoleName } | ForEach-Object { $_.Name })
                if ($affected.Count -gt 0) {
                    Write-Host "  [!] Warning: $($affected.Count) user(s) assigned this role: $($affected -join ', ')" -ForegroundColor Yellow
                    if ((Read-Host "  Delete anyway? [y/N]").Trim().ToLower() -ne 'y') { break }
                }
                $newRoles = [PSCustomObject]@{}
                $CfgW.Roles.PSObject.Properties | Where-Object { $_.Name -ne $RoleName } | ForEach-Object {
                    $newRoles | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value -Force
                }
                $CfgW.Roles = $newRoles
                $CfgW | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigFile -Encoding utf8
                Write-Host "  [+] Role '$RoleName' deleted." -ForegroundColor Green
                Start-Sleep 1
            }
            "c" {
                if (-not ($Cfg -and $Cfg.Roles)) { Write-Host "  [!] No roles defined yet." -ForegroundColor Red; Start-Sleep 1; break }
                $RoleName = (Read-Host "  Set default role").Trim()
                $CfgW = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                if (-not $CfgW.Roles.PSObject.Properties[$RoleName]) {
                    Write-Host "  [!] Role '$RoleName' does not exist." -ForegroundColor Red; Start-Sleep 1; break
                }
                if ($CfgW.Settings.PSObject.Properties['DefaultRole']) {
                    $CfgW.Settings.DefaultRole = $RoleName
                } else {
                    $CfgW.Settings | Add-Member -NotePropertyName DefaultRole -NotePropertyValue $RoleName -Force
                }
                $CfgW | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigFile -Encoding utf8
                Write-Host "  [+] DefaultRole set to '$RoleName'." -ForegroundColor Green
                Start-Sleep 1
            }
            "d" {
                $TargetUser = (Read-Host "  Username to toggle God Mode").Trim()
                if ([string]::IsNullOrEmpty($TargetUser)) { break }
                $CfgW = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                if (-not $CfgW.Users.PSObject.Properties[$TargetUser]) {
                    Write-Host "  [!] User '$TargetUser' not found." -ForegroundColor Red; Start-Sleep 1; break
                }
                $currentGM = [bool]$CfgW.Users.$TargetUser.godMode
                $newGM     = -not $currentGM
                if ($CfgW.Users.$TargetUser.PSObject.Properties['godMode']) {
                    $CfgW.Users.$TargetUser.godMode = $newGM
                } else {
                    $CfgW.Users.$TargetUser | Add-Member -NotePropertyName godMode -NotePropertyValue $newGM -Force
                }
                $CfgW | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigFile -Encoding utf8
                $status = if ($newGM) { "ENABLED" } else { "DISABLED" }
                $color  = if ($newGM) { "Yellow"  } else { "Green"    }
                Write-Host "  [+] God Mode $status for '$TargetUser'." -ForegroundColor $color
                Start-Sleep 1
            }
            "e" { return }
        }
    }
}


function Test-DebugWindowAlive {
    $pf = Join-Path $env:ProgramData "CassenaCareToolkit\toolkit_debug_active.pid"
    if (-not (Test-Path $pf)) { return $false }
    $dpid = try { [int](Get-Content $pf -Raw).Trim() } catch { return $false }
    if ($dpid -le 0) { return $false }
    $proc = Get-Process -Id $dpid -EA SilentlyContinue
    return ($null -ne $proc -and -not $proc.HasExited)
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
    $pidFile = Join-Path $env:ProgramData "CassenaCareToolkit\toolkit_debug_active.pid"
    $logFile = Join-Path $env:ProgramData "CassenaCareToolkit\toolkit_debug_active.log"
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
        $_dbgTag  = if (Test-DebugWindowAlive) { " [Running]" } else { "" }
        $_admTag  = if ($_isAdmin) { " [Elevated]" } else { " [Not Elevated]" }

        Write-Host "  1) Open Debug Console$_dbgTag" -ForegroundColor Cyan
        Write-Host "  2) Roll / Encode New User PAT (Add/Update User with PIN)" -ForegroundColor Cyan
        Write-Host "  3) List Currently Configured Users" -ForegroundColor Cyan
        Write-Host "  4) Exit Administration Panel and Start Production Handoff" -ForegroundColor Green
        Write-Host "  5) Abort & Exit Completely" -ForegroundColor Red
        Write-Host "  6) Relaunch as Administrator$_admTag" -ForegroundColor Magenta
        Write-Host "  7) Authenticate & Launch Toolkit" -ForegroundColor Green
        Write-Host "  8) Manage Roles" -ForegroundColor Cyan
        Write-Host "=====================================================================" -ForegroundColor Yellow

        $MenuChoice = Read-Host "Select an administration option [1-8]"

        switch ($MenuChoice.Trim()) {
            "1" {
                if (Test-DebugWindowAlive) {
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
                    $Data.Users.PSObject.Properties | ForEach-Object {
                        $gmTag   = if ($_.Value.godMode) { " ★ GOD MODE" } else { "" }
                        $roleTag = if ($_.Value -is [string]) {
                            " [legacy token — re-enroll via Option 2]"
                        } elseif ($_.Value.role) {
                            " [role: $($_.Value.role)]$gmTag"
                        } else {
                            " [role: (DefaultRole)]$gmTag"
                        }
                        $color = if ($_.Value.godMode) { "Yellow" } else { "Gray" }
                        Write-Host " -> $($_.Name)$roleTag" -ForegroundColor $color
                    }
                } else { Write-Host "[!] No configuration file detected yet." -ForegroundColor Red }
                Read-Host "`nPress [Enter] to return to menu"
            }
            "4" { return }
            "5" { Exit }
            "6" {
                if ($_isAdmin) {
                    Write-Host "`n[!] Already running as Administrator." -ForegroundColor Yellow
                    if (Get-Command Write-DebugWindow -EA SilentlyContinue) { Write-DebugWindow "Already elevated — no relaunch needed." -Level WARN }
                    Start-Sleep -Seconds 2
                } else {
                    $CmdFile = Join-Path $ScriptRootPath 'Start-Toolkit.cmd'
                    Write-Host "`n  Launching: $CmdFile" -ForegroundColor DarkGray
                    if (Get-Command Write-DebugWindow -EA SilentlyContinue) {
                        Write-DebugWindow "Relaunching as Administrator — debug console will stay open." -Level WARN
                        Start-Sleep -Milliseconds 500
                    }
                    Write-Host "[*] A UAC prompt will appear — click Yes to elevate..." -ForegroundColor Yellow
                    $flagPath = Join-Path $env:ProgramData "CassenaCareToolkit\toolkit_admin_menu.flag"
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
                        if (Get-Command Write-DebugWindow -EA SilentlyContinue) {
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
                    $Cfg        = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
                    $AuthResult = Get-DecodedToken -Config $Cfg
                    $Token      = $AuthResult.PAT
                    $UserRole   = if ($AuthResult.Role) { $AuthResult.Role } else { $Cfg.Settings.DefaultRole }
                    $RoleDef    = if ($Cfg.Roles -and $Cfg.Roles.$UserRole) { $Cfg.Roles.$UserRole } else { $null }

                    $global:ToolkitAuthHeader  = @{ Authorization = "Bearer $Token" }
                    $global:ToolkitPAT         = $Token
                    $global:ToolkitRepoOwner   = if ($Cfg.Settings.PublicOwner)  { $Cfg.Settings.PublicOwner  } else { "skrogman" }
                    $global:ToolkitTargetRepo  = if ($Cfg.Settings.PublicRepo)   { $Cfg.Settings.PublicRepo   } else { "Toolkit_Modules" }
                    $global:ToolkitBranch      = if ($Cfg.Settings.PublicBranch) { $Cfg.Settings.PublicBranch } else { "main" }
                    $global:ToolkitDebugMode   = (Test-DebugWindowAlive)
                    $global:ToolkitAllowedTags = if ($AuthResult.GodMode) { $null } elseif ($RoleDef) { @($RoleDef.tags) } else { @() }
                    $global:ToolkitGodMode     = $AuthResult.GodMode
                    $global:ToolkitUsername    = $script:LastAuthedUsername
                    $global:ToolkitRole        = $UserRole

                    if (Get-Command Write-DebugWindow -EA SilentlyContinue) {
                        $Snip = if ($Token.Length -ge 10) { $Token.Substring(0,10) + "..." } else { "(empty)" }
                        Write-DebugWindow "=== AUTHENTICATION ===" -Level INFO
                        $gmSuffix = if ($AuthResult.GodMode) { " | GOD MODE ACTIVE" } else { "" }
                        Write-DebugWindow "User   : $($global:ToolkitUsername) [role: $UserRole$gmSuffix]" -Level INFO
                        Write-DebugWindow "Tags   : $(if ($global:ToolkitAllowedTags) { $global:ToolkitAllowedTags -join ', ' } else { '* (unrestricted)' })" -Level INFO
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
            "8" { Invoke-RoleManager }
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

    # --- [4] AUTH — skip if debug mode already set globals via option 7 ---
    if (-not $global:ToolkitAuthHeader) {
        $Config     = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        $AuthResult = Get-DecodedToken -Config $Config
        $YourToken  = $AuthResult.PAT
        $UserRole   = if ($AuthResult.Role) { $AuthResult.Role } else { $Config.Settings.DefaultRole }
        $RoleDef    = if ($Config.Roles -and $Config.Roles.$UserRole) { $Config.Roles.$UserRole } else { $null }

        $global:ToolkitAuthHeader  = @{ "Authorization" = "Bearer $YourToken" }
        $env:GITHUB_TOKEN          = $YourToken
        $global:GITHUB_TOKEN       = $YourToken
        $global:ToolkitPAT         = $YourToken
        $global:ToolkitRepoOwner   = if ($Config.Settings.PublicOwner)  { $Config.Settings.PublicOwner  } else { "skrogman" }
        $global:ToolkitTargetRepo  = if ($Config.Settings.PublicRepo)   { $Config.Settings.PublicRepo   } else { "Toolkit_Modules" }
        $global:ToolkitBranch      = if ($Config.Settings.PublicBranch) { $Config.Settings.PublicBranch } else { "main" }
        $global:ToolkitAllowedTags = if ($AuthResult.GodMode) { $null } elseif ($RoleDef) { @($RoleDef.tags) } else { @() }
        $global:ToolkitGodMode     = $AuthResult.GodMode
        $global:ToolkitUsername    = $script:LastAuthedUsername
        $global:ToolkitRole        = $UserRole
    }

    # --- [5] LOAD ENTRY.PS1 — local file in debug mode, CDN otherwise ---
    $LocalEntry = Join-Path $ScriptRootPath 'Entry.ps1'
    if ($global:ToolkitDebugMode -and (Test-Path $LocalEntry)) {
        if (Get-Command Write-DebugWindow -EA SilentlyContinue) {
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
