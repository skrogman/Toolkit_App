# ==================================================================
# Target Repo Asset: skrogman/Toolkit_App/contents/Entry.ps1
# ==================================================================

while ($true) {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "            SECURE IR & ADMIN TOOLKIT             " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "[+] Secure session context inherited successfully.`n" -ForegroundColor Green

    Write-Host "--- MODULE SELECTION ---" -ForegroundColor Yellow
    Write-Host "1. BEC"
    Write-Host "2. Groom PC"
    Write-Host "3. Onboard PC"
    Write-Host "4. Exit"
    Write-Host ""
    
    $Choice = (Read-Host "Select a module to load (1-4)").Trim()

    # --- Pre-configure Network & Auth for Modules ---
    $RepoOwner = "skrogman"
    
    $AuthHeader = @{
        'User-Agent' = 'PowerShellSecureLauncher'
        'Accept'     = 'application/vnd.github.v3.raw'
    }
    if ($global:GitHubToken) {
        $AuthHeader.Add('Authorization', "Bearer $global:GitHubToken")
    }

    $WebClient = New-Object System.Net.WebClient
    foreach ($Key in $AuthHeader.Keys) {
        $WebClient.Headers.Add($Key, $AuthHeader[$Key])
    }
    # ------------------------------------------------

    switch ($Choice) {
        "1" {
            Write-Host "`n[+] Dispatching BEC module pipeline..." -ForegroundColor Cyan
            try {
                $ModuleUrl = "https://api.github.com/repos/$RepoOwner/Toolkit_Modules/contents/BEC/Entry.ps1?ref=main"
                $Code = $WebClient.DownloadString($ModuleUrl)
                $ScriptBlock = [ScriptBlock]::Create($Code)
                
                # Execute module and pass the required parameters
                & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            } catch {
                Write-Host "[X] Execution Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-Host "`nPress Enter to return to module selection..."
        }
        "2" {
            Write-Host "`n[+] Dispatching Groom PC module pipeline..." -ForegroundColor Cyan
            try {
                $ModuleUrl = "https://api.github.com/repos/$RepoOwner/Toolkit_Modules/contents/Groom_PC/Entry.ps1?ref=main"
                $Code = $WebClient.DownloadString($ModuleUrl)
                $ScriptBlock = [ScriptBlock]::Create($Code)
                & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            } catch {
                Write-Host "[X] Execution Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-Host "`nPress Enter to return to module selection..."
        }
        "3" {
            Write-Host "`n[+] Dispatching Onboard PC module pipeline..." -ForegroundColor Cyan
            try {
                $ModuleUrl = "https://api.github.com/repos/$RepoOwner/Toolkit_Modules/contents/Onboard_PC/Entry.ps1?ref=main"
                $Code = $WebClient.DownloadString($ModuleUrl)
                $ScriptBlock = [ScriptBlock]::Create($Code)
                & $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner
            } catch {
                Write-Host "[X] Execution Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-Host "`nPress Enter to return to module selection..."
        }
        "4" {
            Write-Host "`n[-] Handing context control back to local initialization enclave..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 750
            return 
        }
        Default {
            Write-Host "`n[X] Invalid selection context. Please choose 1-4." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
