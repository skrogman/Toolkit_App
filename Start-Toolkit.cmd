<# : Begin batch
@echo off
setlocal
title Toolkit
cd /d "%~dp0"
set TK_SELF=%~f0
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
$global:ToolkitSelfPath = if ($env:TK_SELF -and (Test-Path $env:TK_SELF)) { $env:TK_SELF }
                          elseif ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) { $MyInvocation.MyCommand.Path }
                          else { $null }
$global:ToolkitDebugMode = $false

function Read-EmbeddedConfig {
    if (-not $global:ToolkitSelfPath) { return $null }
    $lines     = [System.IO.File]::ReadAllLines($global:ToolkitSelfPath, [System.Text.Encoding]::UTF8)
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

function Write-EmbeddedConfig($Config) {
    if (-not $global:ToolkitSelfPath) { return }
    $json    = $Config | ConvertTo-Json -Depth 10
    $pfxd    = ($json -split '\r?\n' | ForEach-Object { "# $_" }) -join "`r`n"
    $block   = "# ===TOOLKIT_CONFIG_BEGIN===`r`n$pfxd`r`n# ===TOOLKIT_CONFIG_END==="
    $content = [System.IO.File]::ReadAllText($global:ToolkitSelfPath, [System.Text.Encoding]::UTF8)
    if ($content -match '(?ms)# ===TOOLKIT_CONFIG_BEGIN===.*?# ===TOOLKIT_CONFIG_END===') {
        $content = $content -replace '(?ms)# ===TOOLKIT_CONFIG_BEGIN===.*?# ===TOOLKIT_CONFIG_END===', $block
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n$block`r`n"
    }
    [System.IO.File]::WriteAllText($global:ToolkitSelfPath, $content, [System.Text.UTF8Encoding]::new($false))
}

# Ensure shared dir exists (used by Option 6 elevation flag)
$_ToolkitShared = Join-Path $env:ProgramData "CassenaCareToolkit"
if (-not (Test-Path $_ToolkitShared)) { $null = New-Item -Path $_ToolkitShared -ItemType Directory -Force -ErrorAction SilentlyContinue }

# --- ENGINE HANDOFF: PS 5.1 -> PS7 ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "`n[!] PowerShell 7 required. Handing off to pwsh..." -ForegroundColor Cyan
    $TargetScript = if ($env:TK_SELF -and (Test-Path $env:TK_SELF)) { $env:TK_SELF }
                    elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
                    else { $null }
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $Proc = Start-Process pwsh.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$TargetScript`"" -PassThru -Wait -NoNewWindow
        Exit $Proc.ExitCode
    } else {
        Write-Host "[!] FATAL: PowerShell 7 (pwsh) is not installed." -ForegroundColor Red
        Read-Host "Press [Enter] to abort"; Exit
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
    $existing = Read-EmbeddedConfig
    if ($existing) { $CurrentConfig = $existing }

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
    Write-EmbeddedConfig $CurrentConfig

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

        $Cfg = Read-EmbeddedConfig
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
                $CfgW = Read-EmbeddedConfig
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
                Write-EmbeddedConfig $CfgW
                Write-Host "  [+] Role '$RoleName' saved with tags: $($Tags -join ', ')" -ForegroundColor Green
                Start-Sleep 1
            }
            "b" {
                $RoleName = (Read-Host "  Role to delete").Trim()
                if ([string]::IsNullOrEmpty($RoleName)) { break }
                $CfgW = Read-EmbeddedConfig
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
                Write-EmbeddedConfig $CfgW
                Write-Host "  [+] Role '$RoleName' deleted." -ForegroundColor Green
                Start-Sleep 1
            }
            "c" {
                if (-not ($Cfg -and $Cfg.Roles)) { Write-Host "  [!] No roles defined yet." -ForegroundColor Red; Start-Sleep 1; break }
                $RoleName = (Read-Host "  Set default role").Trim()
                $CfgW = Read-EmbeddedConfig
                if (-not $CfgW.Roles.PSObject.Properties[$RoleName]) {
                    Write-Host "  [!] Role '$RoleName' does not exist." -ForegroundColor Red; Start-Sleep 1; break
                }
                if ($CfgW.Settings.PSObject.Properties['DefaultRole']) {
                    $CfgW.Settings.DefaultRole = $RoleName
                } else {
                    $CfgW.Settings | Add-Member -NotePropertyName DefaultRole -NotePropertyValue $RoleName -Force
                }
                Write-EmbeddedConfig $CfgW
                Write-Host "  [+] DefaultRole set to '$RoleName'." -ForegroundColor Green
                Start-Sleep 1
            }
            "d" {
                $TargetUser = (Read-Host "  Username to toggle God Mode").Trim()
                if ([string]::IsNullOrEmpty($TargetUser)) { break }
                $CfgW = Read-EmbeddedConfig
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
                Write-EmbeddedConfig $CfgW
                $status = if ($newGM) { "ENABLED" } else { "DISABLED" }
                $color  = if ($newGM) { "Yellow"  } else { "Green"    }
                Write-Host "  [+] God Mode $status for '$TargetUser'." -ForegroundColor $color
                Start-Sleep 1
            }
            "e" { return }
        }
    }
}


function Invoke-PublishToBootstrap {
    $Cfg = Read-EmbeddedConfig
    if (-not $Cfg) {
        Write-Host "[!] No config to publish — enroll a user first (Option 2)." -ForegroundColor Red
        Read-Host "Press [Enter] to return"; return
    }

    $BootstrapPath = Join-Path $ScriptRootPath "Bootstrap.cmd"
    if (-not (Test-Path $BootstrapPath)) {
        $BootstrapPath = (Read-Host "  Bootstrap.cmd not found in script dir. Enter full path").Trim()
        if (-not (Test-Path $BootstrapPath)) {
            Write-Host "  [!] File not found." -ForegroundColor Red
            Read-Host "Press [Enter] to return"; return
        }
    }

    Clear-Host
    Write-Host "=== PUBLISH CONFIG TO BOOTSTRAP ===" -ForegroundColor Yellow
    Write-Host "  Target : $BootstrapPath`n" -ForegroundColor DarkGray

    if ((Read-Host "  Publish current config to Bootstrap.cmd? [y/N]").Trim().ToLower() -ne 'y') {
        Write-Host "  Cancelled." -ForegroundColor Yellow; Start-Sleep 1; return
    }

    try {
        $json      = $Cfg | ConvertTo-Json -Depth 10
        $jsonLines = $json -split '\r?\n'

        # Line-by-line replacement — avoids regex replace with multiline content
        $allLines = [System.IO.File]::ReadAllLines($BootstrapPath, [System.Text.Encoding]::UTF8)
        $outLines = [System.Collections.Generic.List[string]]::new()
        $inBlock  = $false
        $replaced = $false

        foreach ($line in $allLines) {
            if ($line -eq '# ===TOOLKIT_CONFIG_BEGIN===') {
                $inBlock = $true
                $outLines.Add('# ===TOOLKIT_CONFIG_BEGIN===')
                foreach ($jl in $jsonLines) { $outLines.Add("# $jl") }
                $outLines.Add('# ===TOOLKIT_CONFIG_END===')
                $replaced = $true
                continue
            }
            if ($line -eq '# ===TOOLKIT_CONFIG_END===') { $inBlock = $false; continue }
            if (-not $inBlock) { $outLines.Add($line) }
        }

        if (-not $replaced) {
            $outLines.Add('# ===TOOLKIT_CONFIG_BEGIN===')
            foreach ($jl in $jsonLines) { $outLines.Add("# $jl") }
            $outLines.Add('# ===TOOLKIT_CONFIG_END===')
        }

        [System.IO.File]::WriteAllLines($BootstrapPath, $outLines.ToArray(), [System.Text.UTF8Encoding]::new($false))
        Write-Host "`n  [+] Config published — Bootstrap.cmd is now self-contained." -ForegroundColor Green
        Write-Host "  Distribute Bootstrap.cmd to operators as a single file." -ForegroundColor DarkGray
    } catch {
        Write-Host "`n  [!] Failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Read-Host "`n  Press [Enter] to return"
}

function Invoke-PATDiagnostic {
    $Cfg = Read-EmbeddedConfig
    if (-not $Cfg) {
        Write-Host "[!] No config found — enroll a user via Option 2 first." -ForegroundColor Red
        Read-Host "Press [Enter] to return"; return
    }

    Clear-Host
    Write-Host "=== PAT DIAGNOSTIC ===" -ForegroundColor Yellow
    Write-Host "  Step 1: Decrypt stored PAT" -ForegroundColor DarkGray
    Write-Host "  Step 2: Test PAT validity against GitHub (/user)" -ForegroundColor DarkGray
    Write-Host "  Step 3: Test access to Toolkit_Modules repo" -ForegroundColor DarkGray
    Write-Host ""

    # Step 1 — decrypt
    $Pat = $null
    try {
        $AuthResult = Get-DecodedToken -Config $Cfg
        $Pat = $AuthResult.PAT
        $Prefix = if ($Pat.Length -ge 16) { $Pat.Substring(0,12) + "..." + $Pat.Substring($Pat.Length-4) } else { "(short)" }
        Write-Host "  [1] PASS — Decryption succeeded" -ForegroundColor Green
        Write-Host "        PAT  : $Prefix" -ForegroundColor DarkGray
        Write-Host "        Role : $($AuthResult.Role)" -ForegroundColor DarkGray
        Write-Host "        GM   : $($AuthResult.GodMode)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [1] FAIL — $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "`n  Press [Enter] to return"; return
    }

    $AuthHdr = @{ Authorization = "Bearer $Pat"; 'User-Agent' = 'ToolkitDiag/1.0' }

    # Step 2 — test PAT against /user
    Write-Host ""
    try {
        $GhUser = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $AuthHdr -UseBasicParsing -ErrorAction Stop
        Write-Host "  [2] PASS — PAT is valid. GitHub login: $($GhUser.login)" -ForegroundColor Green
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "?" }
        Write-Host "  [2] FAIL $code — PAT is invalid or revoked: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        >> Generate a new PAT and re-enroll via Option 2." -ForegroundColor Yellow
        Read-Host "`n  Press [Enter] to return"; return
    }

    # Step 3 — test Toolkit_Modules access
    $Owner  = if ($Cfg.Settings.PublicOwner)  { $Cfg.Settings.PublicOwner  } else { "skrogman" }
    $Repo   = if ($Cfg.Settings.PublicRepo)   { $Cfg.Settings.PublicRepo   } else { "Toolkit_Modules" }
    $Branch = if ($Cfg.Settings.PublicBranch) { $Cfg.Settings.PublicBranch } else { "main" }
    Write-Host ""
    try {
        $Contents = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/contents?ref=$Branch" -Headers $AuthHdr -UseBasicParsing -ErrorAction Stop
        $DirCount = @($Contents | Where-Object { $_.type -eq 'dir' }).Count
        Write-Host "  [3] PASS — Repo accessible. Found $DirCount director(ies) in $Owner/$Repo @ $Branch." -ForegroundColor Green
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "?" }
        Write-Host "  [3] FAIL $code — Cannot access $Owner/$Repo @ $Branch" -ForegroundColor Red
        if ($code -eq 404) {
            Write-Host "        >> 404: Either the repo is private and PAT lacks 'repo' scope," -ForegroundColor Yellow
            Write-Host "        >>       or the repo '$Repo' does not exist under '$Owner'." -ForegroundColor Yellow
            Write-Host "        >>       Classic PAT: check 'repo' scope (not just 'public_repo')." -ForegroundColor Yellow
            Write-Host "        >>       Fine-grained PAT: add '$Repo' with Contents=Read." -ForegroundColor Yellow
        } elseif ($code -eq 401) {
            Write-Host "        >> 401: Token rejected. Re-enroll with a valid PAT." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Read-Host "  Press [Enter] to return"
}

function Invoke-ModuleConfigEditor {
    try { _Invoke-ModuleConfigEditor } catch {
        Write-Host "`n[!] Error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "  Press [Enter] to return"
    }
}
function _Invoke-ModuleConfigEditor {
    # Use active session PAT, or authenticate inline
    $Pat = $global:ToolkitPAT
    if (-not $Pat) {
        $Cfg = Read-EmbeddedConfig
        if (-not $Cfg) {
            Write-Host "[!] No config — enroll a user via Option 2 first." -ForegroundColor Red
            Read-Host "Press [Enter] to return"; return
        }
        Write-Host "`n  No active session. Authenticate to reach the repo." -ForegroundColor Yellow
        try {
            $AuthResult = Get-DecodedToken -Config $Cfg
            $Pat        = $AuthResult.PAT
        } catch {
            Write-Host "[!] $($_.Exception.Message)" -ForegroundColor Red
            Read-Host "Press [Enter] to return"; return
        }
    }

    $Owner   = if ($global:ToolkitRepoOwner)  { $global:ToolkitRepoOwner  } else { "skrogman" }
    $Repo    = if ($global:ToolkitTargetRepo) { $global:ToolkitTargetRepo } else { "Toolkit_Modules" }
    $Branch  = if ($global:ToolkitBranch)     { $global:ToolkitBranch     } else { "main" }
    $PatSnip = if ($Pat.Length -ge 8) { $Pat.Substring(0,8) + "..." } else { "(short)" }

    Clear-Host
    Write-Host "=== EMBED MODULE CONFIG (.TOOLKIT_CONFIG) ===" -ForegroundColor Yellow
    Write-Host "  Writes a .TOOLKIT_CONFIG JSON block into a module's Entry.ps1.`n" -ForegroundColor DarkGray

    # Let admin confirm / correct the repo coordinates before the API call
    Write-Host "  Confirm repo settings (Enter to accept each):" -ForegroundColor Yellow
    $v = (Read-Host "  Owner  [$Owner]").Trim();  if ($v) { $Owner  = $v }
    $v = (Read-Host "  Repo   [$Repo]").Trim();   if ($v) { $Repo   = $v }
    $v = (Read-Host "  Branch [$Branch]").Trim(); if ($v) { $Branch = $v }
    Write-Host "  PAT    : $PatSnip" -ForegroundColor DarkGray

    $AuthHdr = @{ Authorization = "Bearer $Pat" }
    $ApiBase = "https://api.github.com/repos/$Owner/$Repo"
    $ListUrl = "$ApiBase/contents?ref=$Branch"
    Write-Host "  URL    : $ListUrl`n" -ForegroundColor DarkGray

    # Fetch module list
    try {
        $Items = Invoke-RestMethod -Uri $ListUrl -Headers $AuthHdr -UseBasicParsing -ErrorAction Stop
        $Dirs  = @($Items | Where-Object { $_.type -eq 'dir' -and $_.name -notmatch '^\.' } | Sort-Object name)
    } catch {
        Write-Host "[!] Could not fetch module list: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Common causes:" -ForegroundColor DarkGray
        Write-Host "    - Repo name or owner is wrong (check above URL)" -ForegroundColor DarkGray
        Write-Host "    - PAT lacks 'repo' scope for private repos" -ForegroundColor DarkGray
        Write-Host "    - Branch does not exist (try 'master' if 'main' fails)" -ForegroundColor DarkGray
        Write-Host "    - PAT was revoked — re-enroll via Option 2 with a fresh token" -ForegroundColor DarkGray
        Read-Host "`n  Press [Enter] to return"; return
    }

    if ($Dirs.Count -eq 0) {
        Write-Host "[!] No module directories found in $Owner/$Repo." -ForegroundColor Red
        Read-Host "Press [Enter] to return"; return
    }

    Write-Host "  Available modules:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Dirs.Count; $i++) { Write-Host "  $($i+1)) $($Dirs[$i].name)" -ForegroundColor Gray }
    Write-Host ""
    $Sel    = (Read-Host "  Select module [1-$($Dirs.Count)] or Enter to cancel").Trim()
    if ([string]::IsNullOrEmpty($Sel)) { return }
    $SelIdx = try { [int]$Sel - 1 } catch { -1 }
    if ($SelIdx -lt 0 -or $SelIdx -ge $Dirs.Count) {
        Write-Host "  [!] Invalid selection." -ForegroundColor Red; Start-Sleep 1; return
    }

    $ModDir    = $Dirs[$SelIdx]
    $EntryPath = "$($ModDir.name)/Entry.ps1"

    # Fetch current Entry.ps1 content and SHA
    Write-Host "`n  Fetching $EntryPath..." -ForegroundColor DarkGray
    try {
        $FileInfo       = Invoke-RestMethod -Uri "$ApiBase/contents/$EntryPath`?ref=$Branch" -Headers $AuthHdr -UseBasicParsing -ErrorAction Stop
        $CurrentContent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($FileInfo.content -replace '[\r\n\s]','')))
        $FileSha        = $FileInfo.sha
    } catch {
        Write-Host "  [!] Could not fetch Entry.ps1: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press [Enter] to return"; return
    }

    # Parse existing .TOOLKIT_CONFIG if present
    $Ex = $null
    if ($CurrentContent -match '(?ms)\.TOOLKIT_CONFIG\s*(\{.*?\})\s*(?=#>|\.[A-Z])') {
        try { $Ex = $Matches[1] | ConvertFrom-Json } catch { }
    }

    Clear-Host
    $verb = if ($Ex) { "UPDATING" } else { "ADDING" }
    Write-Host "=== $verb CONFIG: $($ModDir.name) ===" -ForegroundColor Yellow
    Write-Host "  Blank input keeps the value shown in [brackets].`n" -ForegroundColor DarkGray

    # Helper: prompt with current value hint
    $P = { param($Lbl,$Cur,$Default)
        $hint = if ($Cur) { " [$Cur]" } elseif ($Default) { " (e.g. $Default)" } else { "" }
        $v = (Read-Host "  $Lbl$hint").Trim()
        if ([string]::IsNullOrEmpty($v)) { if ($Cur) { $Cur } else { $Default } } else { $v }
    }

    $DisplayName = & $P "Display Name"            ($Ex.displayName)       $ModDir.name
    $Description = & $P "Description"             ($Ex.description)       "Describe what this module does."
    $Version     = & $P "Version"                 ($Ex.version)           "1.0.0"
    $Author      = & $P "Author"                  ($Ex.author)            ""

    $TagDef  = if ($Ex.tags) { $Ex.tags -join ', ' } else { "basic-access" }
    Write-Host "`n  Standard tags: basic-access  restricted-access  development-access  forensics  remediation" -ForegroundColor DarkGray
    $TagInput = (Read-Host "  Tags (comma-sep) [$TagDef]").Trim()
    $Tags     = if ($TagInput) { @($TagInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @($TagDef -split ',' | ForEach-Object { $_.Trim() }) }

    $Category  = & $P "Category (Storage/Network/Forensics/Remediation/Security/Diagnostic)" ($Ex.category) "Diagnostic"
    $Elevation = & $P "Required Elevation (none / local-admin / domain-admin)" ($Ex.requiredElevation) "none"
    $Danger    = & $P "Danger Level (safe / moderate / destructive)" ($Ex.dangerLevel) "safe"
    $OutType   = & $P "Output Type (report / remediation / collection / diagnostic)" ($Ex.outputType) "diagnostic"
    $Runtime   = & $P "Estimated Runtime"         ($Ex.estimatedRuntime)  "< 1 min"

    $ModesDef  = if ($Ex.modes) { $Ex.modes -join ', ' } else { "interactive" }
    Write-Host "`n  Supported run modes (comma-sep): interactive  silent" -ForegroundColor DarkGray
    $ModesInput = (Read-Host "  Modes [$ModesDef]").Trim()
    $Modes      = if ($ModesInput) { @($ModesInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @($ModesDef -split ',' | ForEach-Object { $_.Trim() }) }
    $DefModeDef = if ($Ex.defaultMode) { $Ex.defaultMode } elseif ($Modes.Count -gt 0) { $Modes[0] } else { "interactive" }
    $DefMode    = & $P "Default Mode" $DefModeDef $Modes[0]

    $DisStr    = & $P "Disabled? (true/false)"    (if ($null -ne $Ex.disabled) { "$($Ex.disabled)".ToLower() } else { $null }) "false"
    $Disabled  = ($DisStr -eq 'true')

    # Build JSON config block
    $CfgHash = [ordered]@{
        displayName       = $DisplayName
        description       = $Description
        version           = $Version
        author            = $Author
        tags              = $Tags
        category          = $Category
        requiredElevation = $Elevation
        dangerLevel       = $Danger
        outputType        = $OutType
        estimatedRuntime  = $Runtime
        modes             = $Modes
        defaultMode       = $DefMode
        disabled          = $Disabled
    }
    $Json = $CfgHash | ConvertTo-Json -Depth 5

    Write-Host "`n  .TOOLKIT_CONFIG to write:" -ForegroundColor Yellow
    Write-Host $Json -ForegroundColor DarkGray
    Write-Host ""
    if ((Read-Host "  Commit to $Owner/$Repo? [y/N]").Trim().ToLower() -ne 'y') {
        Write-Host "  Cancelled." -ForegroundColor Yellow; Start-Sleep 1; return
    }

    # Strip any existing .TOOLKIT_CONFIG block from the file content
    $Work = $CurrentContent -replace '(?ms)\.TOOLKIT_CONFIG[ \t]*\r?\n\{.*?\}[ \t]*(\r?\n)?', ''

    # Inject the new block before the first #> (end of opening comment block)
    $TkBlock  = "`r`n.TOOLKIT_CONFIG`r`n$Json`r`n"
    $closeIdx = $Work.IndexOf('#>')
    if ($closeIdx -ge 0) {
        $NewContent = $Work.Substring(0, $closeIdx) + $TkBlock + $Work.Substring($closeIdx)
    } else {
        # No comment block exists — prepend one
        $NewContent = "<#`r`n.SYNOPSIS`r`n    $DisplayName`r`n$TkBlock#>`r`n`r`n$Work"
    }

    # Base64-encode and commit via GitHub Contents API
    $Encoded    = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($NewContent))
    $CommitBody = [ordered]@{
        message = "config: embed .TOOLKIT_CONFIG in $($ModDir.name)/Entry.ps1"
        content = $Encoded
        sha     = $FileSha
        branch  = $Branch
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri "$ApiBase/contents/$EntryPath" `
            -Method Put -Headers $AuthHdr -ContentType 'application/json' `
            -Body $CommitBody -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "`n  [+] Committed! .TOOLKIT_CONFIG is live in $($ModDir.name)/Entry.ps1" -ForegroundColor Green
        Write-Host "  The toolkit picks up tags and metadata on next launch." -ForegroundColor DarkGray
    } catch {
        Write-Host "`n  [!] Commit failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Read-Host "`n  Press [Enter] to return"
}  # end _Invoke-ModuleConfigEditor

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
        Write-Host "  9) Embed Module Config (.TOOLKIT_CONFIG tags/metadata)" -ForegroundColor Cyan
        Write-Host "  0) Diagnose PAT / GitHub Connectivity" -ForegroundColor DarkYellow
        Write-Host "  P) Publish Config → Bootstrap.cmd (make it self-contained)" -ForegroundColor Yellow
        Write-Host "=====================================================================" -ForegroundColor Yellow

        $MenuChoice = Read-Host "Select an administration option [0-9/P]"

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
                $Data = Read-EmbeddedConfig
                if ($Data) {
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
                } else { Write-Host "[!] No configuration found — enroll via Option 2." -ForegroundColor Red }
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
                $Cfg = Read-EmbeddedConfig
                if (-not $Cfg) {
                    Write-Host "[!] Create a user via option 2 first." -ForegroundColor Red
                    Start-Sleep -Seconds 2; continue
                }
                try {
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
            "9" { Invoke-ModuleConfigEditor }
            "0" { Invoke-PATDiagnostic }
            "p" { Invoke-PublishToBootstrap }
        }
    }
}

# --- ADMIN PANEL ---
Show-ConfigMenu

# ===TOOLKIT_CONFIG_BEGIN===
# {
#   "Users": {},
#   "Roles": {
#     "admin": {
#       "tags": [
#         "*"
#       ]
#     },
#     "basic": {
#       "tags": [
#         "basic-access"
#       ]
#     }
#   },
#   "Settings": {
#     "PublicOwner": "skrogman",
#     "PublicRepo": "Toolkit_Modules",
#     "PublicBranch": "main",
#     "VerboseMode": "true",
#     "DefaultRole": "basic"
#   }
# }
# ===TOOLKIT_CONFIG_END===
