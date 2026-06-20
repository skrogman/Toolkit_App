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

$ErrorActionPreference = 'Stop'
$host.UI.RawUI.WindowTitle = 'Toolkit'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

try {
    $DQ = [char]34
    $MemberDef = '[DllImport(' + $DQ + 'user32.dll' + $DQ + ')] public static extern IntPtr GetForegroundWindow(); [DllImport(' + $DQ + 'user32.dll' + $DQ + ')] public static extern bool SetForegroundWindow(IntPtr hWnd);'
    Add-Type -MemberDefinition $MemberDef -Name 'Win32WindowUtil' -Namespace 'Win32UtilNamespace' -ErrorAction SilentlyContinue | Out-Null
} catch {}

$WorkDir = $env:ProgramData + '\SKit\ToolKit'
if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
$ConfigFile = $WorkDir + '\start-toolkit.cfg'
$LogFile    = $WorkDir + '\start-toolkit.log'

if (-not (Test-Path $ConfigFile)) {
    Clear-Host
    $Config = [PSCustomObject]@{
        Settings = [PSCustomObject]@{ VerboseMode = 'false' }
        Users = [PSCustomObject]@{}
    }
    $Config | ConvertTo-Json -Depth 3 | Out-File $ConfigFile -Encoding utf8
} else {
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
}

$global:VerboseMode = $false
$env:TOOLKIT_VERBOSE = 'false'

# Session state persist tracking variables
$global:ActiveUser = $null
$global:GitHubToken = $null

function Show-Menu {
    param ([array]$Options, [string]$Title)
    $selectedIndex = 0
    while ($true) {
        Clear-Host
        Write-Host '==========================================================' -ForegroundColor Cyan
        Write-Host ("                 $Title") -ForegroundColor Green
        Write-Host '==========================================================' -ForegroundColor Cyan
        Write-Host ' Navigation: Use [Up/Down] Arrow Keys, Select with [Enter]' -ForegroundColor DarkGray
        Write-Host ''

        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $selectedIndex) {
                Write-Host "  > $($Options[$i]) " -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host "    $($Options[$i]) " -ForegroundColor Gray
            }
        }

        $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        if ($keyInfo.VirtualKeyCode -eq 38) { $selectedIndex--; if ($selectedIndex -lt 0) { $selectedIndex = $Options.Count - 1 } }
        elseif ($keyInfo.VirtualKeyCode -eq 40) { $selectedIndex++; if ($selectedIndex -ge $Options.Count) { $selectedIndex = 0 } }
        elseif ($keyInfo.VirtualKeyCode -eq 13) { return $selectedIndex }
    }
}

function Get-DuplicateProcesses {
    $CurrentPID = $PID
    $ParentPID = 0
    try {
        $ParentPID = (Get-CimInstance Win32_Process -Filter "ProcessId = $CurrentPID").ParentProcessId
    } catch {
        try { $ParentPID = (Get-WmiObject Win32_Process -Filter "ProcessId = $CurrentPID").ParentProcessId } catch {}
    }
    
    $RawProcesses = @()
    try {
        $RawProcesses = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='cmd.exe'"
    } catch {
        $RawProcesses = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='cmd.exe'"
    }
    
    $RealDups = @()
    foreach ($P in $RawProcesses) {
        if ($P.ProcessId -eq $CurrentPID -or $P.ProcessId -eq $ParentPID) { continue }
        if ($P.CommandLine -like "*start-toolkit*" -or $P.CommandLine -like "*Toolkit_App*") {
            $SysProc = Get-Process -Id $P.ProcessId -ErrorAction SilentlyContinue
            if ($SysProc) { $RealDups += $SysProc }
        }
    }
    return ,$RealDups
}

function Sync-DebugWindow {
    param([switch]$ForceOpen)
    $ActiveTails = Get-Process | Where-Object { $_.MainWindowTitle -match 'Toolkit-DebugStream' }
    if ($global:VerboseMode -or $ForceOpen) {
        if (-not $ActiveTails) {
            if (-not (Test-Path $LogFile)) { New-Item -Path $LogFile -ItemType File -Force | Out-Null }
            Clear-Content $LogFile -ErrorAction SilentlyContinue
            $OriginalHwnd = [IntPtr]::Zero
            try { $OriginalHwnd = [Win32UtilNamespace.Win32WindowUtil]::GetForegroundWindow() } catch {}
            $TailScript = 'Clear-Host; Write-Host ''=== LIVE TOOLKIT DEBUG STREAM ==='' -ForegroundColor Yellow; Get-Content ''' + $LogFile + ''' -Wait -Tail 30'
            $EncodedCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($TailScript))
            $StartArgs = '/c title Toolkit-DebugStream && powershell.exe -NoProfile -EncodedCommand ' + $EncodedCmd
            Start-Process -FilePath 'cmd.exe' -ArgumentList $StartArgs -WindowStyle Normal
            Start-Sleep -Milliseconds 450
            if ($OriginalHwnd -and $OriginalHwnd -ne [IntPtr]::Zero) {
                try { [Win32UtilNamespace.Win32WindowUtil]::SetForegroundWindow($OriginalHwnd) | Out-Null } catch {}
            }
        }
    } else {
        if ($ActiveTails) { $ActiveTails | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
}

function Log-Write {
    param([string]$Msg)
    $Timestamp = Get-Date -Format 'HH:mm:ss'
    "[${Timestamp}] $Msg" | Out-File $LogFile -Append -Encoding utf8
}

function Read-MaskedPIN {
    param([string]$Prompt)
    Write-Host $Prompt -NoNewline
    $Secret = ''
    while ($true) {
        $Key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        if ($Key.VirtualKeyCode -eq 13) { Write-Host ''; break }
        elseif ($Key.VirtualKeyCode -eq 8) {
            if ($Secret.Length -gt 0) {
                $Secret = $Secret.Substring(0, $Secret.Length - 1)
                Write-Host '`b `b' -NoNewline
            }
        }
        elseif ($Key.Character -ne 0) {
            $Secret += $Key.Character
            Write-Host '*' -NoNewline
        }
    }
    return $Secret
}

function Read-PasteSafePAT {
    param([string]$Prompt)
    Write-Host $Prompt -NoNewline
    $SecureObject = Read-Host -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureObject)
    $UnmanagedString = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    return $UnmanagedString
}

# --- PERSISTENT SELECTION HOOK LOOP ---
while ($true) {
    $UserList = @()
    if ($Config.Users) { $UserList = $Config.Users | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name }
    
    $MenuOptions = @()

    # Dynamic UI Layout: Check if a validated active identity bypass context exists
    if ($global:ActiveUser -and $global:GitHubToken) {
        $MenuOptions += "Launch Toolkit Enclave (Active: $global:ActiveUser)"
        $MenuOptions += "Sign Out / Switch Identity Profile"
    } else {
        foreach ($u in $UserList) { $MenuOptions += ("Identity Sign-In: $u") }
        $MenuOptions += 'Register New Security Profile'
    }
    
    $Dups = Get-DuplicateProcesses
    if ($Dups.Count -gt 0) {
        $MenuOptions += "Clear Duplicate Toolkit Windows ($($Dups.Count) found)"
    }
    
    $vStatus = if ($global:VerboseMode) { 'ON' } else { 'OFF' }
    $MenuOptions += "Toggle Floating Debug Log [$vStatus]"
    $MenuOptions += 'Exit Launcher'

    $SelIndex = Show-Menu -Options $MenuOptions -Title 'SECURE TOOLKIT ENCLAVE INITIALIZATION'
    $Selection = $MenuOptions[$SelIndex]

    if ($Selection -eq 'Exit Launcher') { exit }
    elseif ($Selection -match 'Toggle Floating Debug Log') {
        $global:VerboseMode = -not $global:VerboseMode
        Sync-DebugWindow
        continue
    }
    elseif ($Selection -match 'Clear Duplicate Toolkit Windows') {
        Clear-Host
        Write-Host "[-] Purging target duplicate context command lines..." -ForegroundColor Yellow
        foreach ($P in $Dups) { $P | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        continue
    }
    elseif ($Selection -eq 'Sign Out / Switch Identity Profile') {
        Log-Write "[AUTH] User explicitly signed out from session: $global:ActiveUser"
        $global:ActiveUser = $null
        $global:GitHubToken = $null
        $env:GITHUB_TOKEN = $null
        continue
    }
    elseif ($Selection -eq 'Register New Security Profile') {
        Clear-Host
        Write-Host '--- Register New Security Profile ---' -ForegroundColor Yellow
        Write-Host 'Enter Local Profile Name: ' -NoNewline
        $NewUser = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($NewUser)) { continue }
        $NewPatStr = Read-PasteSafePAT -Prompt 'Paste GitHub PAT (Input hidden, press Enter): '
        if ([string]::IsNullOrWhiteSpace($NewPatStr)) { continue }
        $NewPinStr = Read-MaskedPIN -Prompt 'Create a 4-Digit PIN: '
        if ([string]::IsNullOrWhiteSpace($NewPinStr)) { continue }
        
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $keyBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($NewPinStr))
        $SecureString = ConvertTo-SecureString $NewPatStr -AsPlainText -Force
        $EncryptedPat = ConvertFrom-SecureString $SecureString -Key $keyBytes
        
        $Config.Users | Add-Member -MemberType NoteProperty -Name $NewUser -Value $EncryptedPat -Force
        $Config | ConvertTo-Json -Depth 3 | Out-File $ConfigFile -Encoding utf8
        Write-Host "`n[+] Profile saved!" -ForegroundColor Green
        Log-Write "[CONFIG] Registered new identifier profile: $NewUser"
        Start-Sleep -Seconds 1
        continue
    }
    
    # ---------------------------------------------------------
    # STEP 1: AUTHENTICATION HANDLING
    # ---------------------------------------------------------
    elseif ($Selection -match 'Identity Sign-In:') {
        $TargetUser = $Selection.Replace('Identity Sign-In: ', '').Trim()
        Clear-Host
        Write-Host "--- Access Profile: $TargetUser ---" -ForegroundColor Cyan
        $PinStr = Read-MaskedPIN -Prompt "Enter PIN: "
        try {
            Log-Write "[AUTH] Attempting decryption for profile: $TargetUser"
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $keyBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($PinStr))
            $EncryptedPat = $Config.Users.$TargetUser
            $SecurePat = ConvertTo-SecureString $EncryptedPat -Key $keyBytes
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePat)
            $global:GitHubToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
            
            # Save the active target profile identity context globally
            $global:ActiveUser = $TargetUser
            $env:GITHUB_TOKEN = $global:GitHubToken
            
            Log-Write "[AUTH] [SUCCESS] Identity token unlocked for $global:ActiveUser."
            Write-Host "`n[+] Identity unlocked successfully! Updating menu..." -ForegroundColor Green
            
            Start-Sleep -Seconds 1
            continue 
            
        } catch {
            Log-Write '[AUTH] [WARN] Decryption failure. Invalid PIN.'
            Write-Host "`n[X] Invalid PIN." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
    }

    # ---------------------------------------------------------
    # STEP 2: APP LAUNCH HANDLING
    # ---------------------------------------------------------
    elseif ($Selection -match 'Launch Toolkit Enclave') {
        # -----------------------------------------------------
        # CRITICAL FIX: Explicitly map all token variables 
        # that the remote script needs before initialization!
        # -----------------------------------------------------
        $global:DevToken    = $global:GitHubToken
        $global:PAT         = $global:GitHubToken
        $global:Token       = $global:GitHubToken
        $env:GITHUB_TOKEN   = $global:GitHubToken

        # --- LEAN & MEAN ENCLAVE DISPATCH ---
        Clear-Host
        Write-Host '==========================================================' -ForegroundColor Green
        Write-Host '               CONNECTING TO SECURITY APP                 ' -ForegroundColor Green
        Write-Host '==========================================================' -ForegroundColor Green
        Write-Host "Target Endpoint: skrogman/Toolkit_App (User: $global:ActiveUser)" -ForegroundColor Cyan

        Log-Write "[START] Dispatching pipeline asset payload pull from Toolkit_App for user $global:ActiveUser"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        try {
            $WebClient = New-Object System.Net.WebClient
            $WebClient.Headers.Add('User-Agent', 'PowerShellSecureLauncher')
            $WebClient.Headers.Add('Accept', 'application/vnd.github.v3.raw')
            if ($global:GitHubToken) { $WebClient.Headers.Add('Authorization', "Bearer $global:GitHubToken") }
            
            $EntryUrl = "https://api.github.com/repos/skrogman/Toolkit_App/contents/Entry.ps1?ref=main"
            Log-Write "[CONNECT] Dispatching GET request to: $EntryUrl"
            
            $code = $WebClient.DownloadString($EntryUrl)
            
            if ($code) {
                Log-Write '[SUCCESS] Stream downloaded. Invoking platform pipeline.'
                Clear-Host
                Invoke-Expression $code
            }
        } catch {
            Log-Write "[ERROR] Pipeline faulted: $($_.Exception.Message)"
            Write-Host ''
            Write-Host '[X] Core Connection Failed or Enclave Access Denied.' -ForegroundColor Red
            Write-Host "Endpoint: $EntryUrl" -ForegroundColor DarkGray
            if ($_.Exception.Response) {
                $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $RawResp = $Reader.ReadToEnd()
                Log-Write "[HTTP-DETAILS] $RawResp"
                Write-Host "Response Details: $RawResp" -ForegroundColor DarkGray
            }
            Write-Host "`nPress Enter to return to initialization menu..." -ForegroundColor Yellow
            Read-Host | Out-Null
        }
    }
}
