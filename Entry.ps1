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
            
            # CRITICAL: This explicitly forces the script back to the menu to show the "Active" status.
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
