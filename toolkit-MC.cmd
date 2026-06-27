<# : Begin batch
@echo off
setlocal
title Cassena Care Toolkit MC
cd /d "%~dp0"
set TK_SELF=%~f0
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -Command "$f=[System.IO.File]::ReadAllText('%~f0'); Invoke-Expression $f"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[System.IO.File]::ReadAllText('%~f0'); Invoke-Expression $f"
)
if %errorlevel% neq 0 pause
endlocal
goto:eof
#>

# ==================================================================
# BOOTSTRAP: toolkit-MC.cmd — Operator Launcher (MC Edition)
# Reads embedded config, authenticates, launches Entry-MC.ps1.
# Populate this file's config via Start-Toolkit.cmd > Option P.
# ==================================================================

# --- ENGINE HANDOFF: PS 5.1 -> PS7 ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "`n[!] PowerShell 7 required. Handing off to pwsh..." -ForegroundColor Cyan
    $TargetScript = if ($env:TK_SELF -and (Test-Path $env:TK_SELF)) { $env:TK_SELF }
                    elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
                    else { $null }
    if (-not $TargetScript) { Write-Host "[!] Cannot locate this file's path." -ForegroundColor Red; Read-Host "Press [Enter] to exit"; exit 1 }
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $Proc = Start-Process pwsh.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"`$f=[System.IO.File]::ReadAllText('$($TargetScript -replace "'","''")'); Invoke-Expression `$f`"" -PassThru -Wait -NoNewWindow
        exit $Proc.ExitCode
    } else {
        Write-Host "[!] FATAL: PowerShell 7 (pwsh) is not installed." -ForegroundColor Red
        Read-Host "Press [Enter] to exit"; exit 1
    }
}

$Mutex = $null

# --- READ EMBEDDED CONFIG (with fallback to sibling launchers) ---
function Read-ConfigFromFile {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path $FilePath)) { return $null }
    $lines     = [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)
    $inBlock   = $false
    $jsonLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -eq '# ===TOOLKIT_CONFIG_BEGIN===') { $inBlock = $true; continue }
        if ($line -eq '# ===TOOLKIT_CONFIG_END===')   { break }
        if ($inBlock) { $jsonLines.Add(($line -replace '^# ?','')) }
    }
    $json = ($jsonLines -join "`n").Trim()
    if ($json -and $json -ne '{}') { try { return $json | ConvertFrom-Json } catch { } }
    return $null
}

function Read-ToolkitConfig {
    # 1. Own embedded config
    $cfg = Read-ConfigFromFile $global:BootstrapSelfPath
    if ($cfg) { return $cfg }

    # 2. Fallback: Bootstrap.cmd or Start-Toolkit.cmd in the same directory
    $dir = [System.IO.Path]::GetDirectoryName($global:BootstrapSelfPath)
    foreach ($name in @('Bootstrap.cmd','Start-Toolkit.cmd')) {
        $path = Join-Path $dir $name
        $cfg  = Read-ConfigFromFile $path
        if ($cfg) {
            Write-Host "  [i] Config loaded from $name" -ForegroundColor DarkCyan
            return $cfg
        }
    }
    return $null
}

# --- AES-256-CBC + PBKDF2 DECRYPTION ---
function Get-DecodedToken($Config) {
    Write-Host "`n=== PROFILE ACCESS VALIDATION ===" -ForegroundColor Yellow
    $Username = (Read-Host "  User profile").Trim()
    if (-not $Config.Users.$Username) { throw "Profile '$Username' not found." }
    $script:LastAuthedUsername = $Username

    Write-Host "  PIN for '$Username': " -NoNewline -ForegroundColor White
    $SecurePin = Read-Host -AsSecureString
    $BSTR      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePin)
    $UserPin   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    Write-Host ""

    $userObj  = $Config.Users.$Username
    $tokenStr = if ($userObj -is [string]) { $userObj } else { $userObj.token   }
    $roleStr  = if ($userObj -is [string]) { $null    } else { $userObj.role    }
    $godMode  = if ($userObj -is [string]) { $false   } else { [bool]$userObj.godMode }

    $parts = $tokenStr -split '\|'
    if ($parts[0] -ne 'v2') { throw "Outdated token format for '$Username'. Re-enroll via Start-Toolkit.cmd Option 2." }

    try {
        $saltBytes = [Convert]::FromBase64String($parts[1])
        $ivBytes   = [Convert]::FromBase64String($parts[2])
        $cipher    = [Convert]::FromBase64String($parts[3])
        $derive    = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                         $UserPin, $saltBytes, 100000,
                         [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $key = $derive.GetBytes(32)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key; $aes.IV = $ivBytes
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $dec   = $aes.CreateDecryptor()
        $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        $pat   = [System.Text.Encoding]::UTF8.GetString($plain).Trim()
    } catch [System.Security.Cryptography.CryptographicException] {
        throw "Incorrect PIN for '$Username'."
    }

    return @{ PAT = $pat; Role = $roleStr; GodMode = $godMode }
}

# --- LAUNCH ---
try {
    $ErrorActionPreference = "Stop"

    $global:BootstrapSelfPath = if ($env:TK_SELF -and (Test-Path $env:TK_SELF)) { $env:TK_SELF }
                                 elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
                                 else { $null }

    # Single-instance mutex (separate from Bootstrap.cmd so both can run simultaneously)
    $MutexName  = "Global\SkrogmanIRToolkitMCLock"
    $CreatedNew = $false
    $Mutex      = [System.Threading.Mutex]::new($true, $MutexName, [ref]$CreatedNew)
    if (-not $CreatedNew) {
        Write-Host "`n[!] Another Toolkit MC instance is already running." -ForegroundColor Yellow
        $c = (Read-Host "  [Y] Allow multi-instance  /  [Enter] Take over").Trim().ToUpper()
        if ($c -eq 'Y') {
            $Mutex.Dispose(); $Mutex = $null
        } else {
            $thisPid = $PID
            Get-CimInstance Win32_Process -Filter "Name like 'pwsh%.exe' or Name like 'powershell%.exe'" |
                Where-Object { $_.ProcessId -ne $thisPid -and $_.CommandLine -match 'toolkit-MC' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
            Start-Sleep -Milliseconds 600
            $Mutex.Dispose()
            $Mutex = [System.Threading.Mutex]::new($true, $MutexName, [ref]$CreatedNew)
        }
    }

    $Config = Read-ToolkitConfig
    if (-not $Config) {
        throw "No configuration found in this file.`n`n  Use Start-Toolkit.cmd > Option P to publish the config here.`n  This creates a standalone bootstrap with embedded credentials."
    }

    $AuthResult = Get-DecodedToken -Config $Config
    $Token      = $AuthResult.PAT
    $UserRole   = if ($AuthResult.Role) { $AuthResult.Role } else { $Config.Settings.DefaultRole }
    $RoleDef    = if ($Config.Roles -and $Config.Roles.$UserRole) { $Config.Roles.$UserRole } else { $null }

    $global:ToolkitAuthHeader  = @{ Authorization = "Bearer $Token" }
    $global:ToolkitPAT         = $Token
    $global:ToolkitRepoOwner   = if ($Config.Settings.PublicOwner)  { $Config.Settings.PublicOwner  } else { "skrogman" }
    $global:ToolkitTargetRepo  = if ($Config.Settings.PublicRepo)   { $Config.Settings.PublicRepo   } else { "Toolkit_Modules" }
    $global:ToolkitBranch      = if ($Config.Settings.PublicBranch) { $Config.Settings.PublicBranch } else { "main" }
    $global:ToolkitAllowedTags = if ($AuthResult.GodMode) { $null } elseif ($RoleDef) { @($RoleDef.tags) } else { @() }
    $global:ToolkitGodMode     = $AuthResult.GodMode
    $global:ToolkitUsername    = $script:LastAuthedUsername
    $global:ToolkitRole        = $UserRole
    $global:ToolkitDebugMode   = $false

    $CacheBuster = [guid]::NewGuid().ToString()
    $EntryUrl    = "https://raw.githubusercontent.com/$($global:ToolkitRepoOwner)/Toolkit_App/$($global:ToolkitBranch)/Entry-MC.ps1?t=$CacheBuster"
    $Code        = Invoke-RestMethod -Uri $EntryUrl -UseBasicParsing -ErrorAction Stop

    Clear-Host
    . ([scriptblock]::Create($Code)) `
        -AuthHeader $global:ToolkitAuthHeader `
        -RepoOwner  $global:ToolkitRepoOwner `
        -TargetRepo $global:ToolkitTargetRepo `
        -Branch     $global:ToolkitBranch

} catch {
    Write-Host "`n[!] $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "`nPress [Enter] to exit"
} finally {
    if ($Mutex) { try { $Mutex.ReleaseMutex() } catch {} ; $Mutex.Dispose() }
}

# ===TOOLKIT_CONFIG_BEGIN===
# {}
# ===TOOLKIT_CONFIG_END===
