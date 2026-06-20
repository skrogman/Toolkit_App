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

    switch ($Choice) {
        "1" {
            Write-Host "`n[+] Dispatching BEC module pipeline..." -ForegroundColor Cyan
            # Insert your BEC module code execution here
            Read-Host "Press Enter to return to module selection..."
        }
        "2" {
            Write-Host "`n[+] Dispatching Groom PC module pipeline..." -ForegroundColor Cyan
            # Insert your Groom PC module code execution here
            Read-Host "Press Enter to return to module selection..."
        }
        "3" {
            Write-Host "`n[+] Dispatching Onboard PC module pipeline..." -ForegroundColor Cyan
            # Insert your Onboard PC module code execution here
            Read-Host "Press Enter to return to module selection..."
        }
        "4" {
            Write-Host "`n[-] Handing context control back to local initialization enclave..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 750
            
            # CRITICAL MECHANISM: 
            # Using 'return' exits this script block payload cleanly, 
            # allowing start-toolkit.cmd's wrapper loop to catch it.
            return 
        }
        Default {
            Write-Host "`n[X] Invalid selection context. Please choose 1-4." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
