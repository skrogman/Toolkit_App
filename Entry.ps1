# ==================================================================
# MASTER ORCHESTRATOR: TUI Module Enclave
# Repository: Toolkit_App / Entry.ps1
# ==================================================================
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)][hashtable]$AuthHeader,
    [Parameter(Mandatory=$false)][string]$RepoOwner = "skrogman",
    [Parameter(Mandatory=$false)][string]$TargetRepo = "Toolkit_Modules", 
    [Parameter(Mandatory=$false)][string]$Branch = "main",
    [Parameter(ValueFromRemainingArguments=$true)]$CatchAllParameters
)

$ErrorActionPreference = "Stop"

function Write-OrchestratorLog {
    param($Level, $Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] [ORCHESTRATOR] $Message" -ForegroundColor DarkGray
}

try {
    Write-OrchestratorLog "INFO" "Bootstrapping Master TUI Enclave..."
    
    # --- [1] DEPENDENCY BOOTSTRAPPER ---
    $GuiVersion = "1.14.1" 
    $NStackVersion = "1.0.7"
    $TempDir = Join-Path $env:TEMP "TerminalGui_Standalone_Master"
    $ExtractDir = Join-Path $TempDir "Assemblies"

    if (-not (Test-Path $ExtractDir)) {
        $null = New-Item -Path $ExtractDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Terminal.Gui/$GuiVersion" -OutFile "$TempDir\Terminal.Gui.zip"
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/NStack.Core/$NStackVersion" -OutFile "$TempDir\NStack.Core.zip"
        Expand-Archive -Path "$TempDir\Terminal.Gui.zip" -DestinationPath $ExtractDir -Force
        Expand-Archive -Path "$TempDir\NStack.Core.zip" -DestinationPath $ExtractDir -Force
    }

    $NStackDll = Get-ChildItem -Path $ExtractDir -Filter "NStack.dll" -Recurse | Select-Object -First 1
    $GuiDll = Get-ChildItem -Path $ExtractDir -Filter "Terminal.Gui.dll" -Recurse | Select-Object -First 1

    try { Add-Type -Path $NStackDll.FullName -ErrorAction Stop } catch { }
    try { Add-Type -Path $GuiDll.FullName -ErrorAction Stop } catch { }

    # --- [2] DYNAMIC GITHUB API ENUMERATION ---
    Write-OrchestratorLog "INFO" "Querying GitHub API for available modules in $TargetRepo..."
    
    $global:MasterMenuItems = @()
    $global:MasterModulePaths = @()

    $ApiUrl = "https://api.github.com/repos/$RepoOwner/$TargetRepo/contents?ref=$Branch"
    
    try {
        if ($AuthHeader) {
            $ApiResponse = Invoke-RestMethod -Uri $ApiUrl -Headers $AuthHeader -ErrorAction Stop
        } else {
            $ApiResponse = Invoke-RestMethod -Uri $ApiUrl -ErrorAction Stop
        }

        $DiscoveredDirs = $ApiResponse | Where-Object { $_.type -eq 'dir' -and $_.name -notmatch '^\.' } | Sort-Object name

        foreach ($Dir in $DiscoveredDirs) {
            $global:MasterModulePaths += $Dir.name
            $global:MasterMenuItems += "Launch Module: $($Dir.name)"
        }
    } catch {
        $global:MasterMenuItems += "ERROR: Could not load modules"
        Write-OrchestratorLog "ERROR" "GitHub API returned an error: $($_.Exception.Message)"
    }

    $global:MasterMenuItems += "Exit Toolkit Enclave"

    # --- [3] MASTER TUI EXECUTION LOOP ---
    $global:ExitMaster = $false
    $global:TargetModule = $null

    while (-not $global:ExitMaster) {
        
        $global:UpdateMasterRightPane = {
            param($ItemIndex)
            
            $SelectionName = $global:MasterMenuItems[$ItemIndex]
            $TargetDir = if ($ItemIndex -lt $global:MasterModulePaths.Count) { $global:MasterModulePaths[$ItemIndex] } else { "N/A" }

            $PanelText  = "SECURE IR & ADMIN TOOLKIT`n"
            $PanelText += "=========================================`n"
            $PanelText += " Operator   : $($env:USERNAME)`n"
            $PanelText += " Repository : $RepoOwner/$TargetRepo`n"
            $PanelText += " Branch     : $Branch`n`n"
            $PanelText += "--- MODULE INFO ---`n"
            $PanelText += " Selection  : $SelectionName`n"
            $PanelText += " Cloud Path : /$TargetDir/Entry.ps1`n`n"
            
            if ($TargetDir -ne "N/A") {
                $PanelText += "Press [Enter] to pull payload and inject `ninto execution runspace."
            } else {
                $PanelText += "Press [Enter] to securely terminate session."
            }
            
            $global:MasterDescView.Text = $PanelText
            $global:MasterDescView.SetNeedsDisplay()
        }

        # --- RAW .NET ENVIRONMENT BYPASS ---
        # Completely scrub these variables from the process memory so Terminal.Gui doesn't look for Linux 'libc'
        $BackupTerm = [Environment]::GetEnvironmentVariable("TERM", "Process")
        $BackupColorTerm = [Environment]::GetEnvironmentVariable("COLORTERM", "Process")
        [Environment]::SetEnvironmentVariable("TERM", $null, "Process")
        [Environment]::SetEnvironmentVariable("COLORTERM", $null, "Process")

        [Terminal.Gui.Application]::Init()
        $Top = [Terminal.Gui.Application]::Top
        
        # Restore them immediately after init
        if ($BackupTerm) { [Environment]::SetEnvironmentVariable("TERM", $BackupTerm, "Process") }
        if ($BackupColorTerm) { [Environment]::SetEnvironmentVariable("COLORTERM", $BackupColorTerm, "Process") }
        # -----------------------------------

        $ColorSetup = New-Object Terminal.Gui.ColorScheme
        $ColorSetup.Normal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::White, [Terminal.Gui.Color]::Blue)
        $ColorSetup.Focus = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::Black, [Terminal.Gui.Color]::Cyan)
        $ColorSetup.HotNormal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow, [Terminal.Gui.Color]::Blue)
        
        $MainWindow = New-Object Terminal.Gui.Window("=== MASTER ORCHESTRATOR ENCLAVE ===")
        $MainWindow.ColorScheme = $ColorSetup
        # Leave room at the bottom for the status bar
        $MainWindow.Height = [Terminal.Gui.Dim]::Fill() - 1 
        $Top.Add($MainWindow)

        $HelpText = New-Object Terminal.Gui.Label("Use [Up/Down] arrows. Press [Enter] to inject module.")
        $HelpText.X = 0; $HelpText.Y = 0
        $MainWindow.Add($HelpText)
        
        $ListView = New-Object Terminal.Gui.ListView
        [void]$ListView.SetSource($global:MasterMenuItems) 
        $ListView.X = 0; $ListView.Y = 2
        $ListView.Width = [Terminal.Gui.Dim]::Percent(45) 
        $ListView.Height = [Terminal.Gui.Dim]::Fill()
        $MainWindow.Add($ListView)

        $global:MasterDescView = New-Object Terminal.Gui.TextView
        $global:MasterDescView.X = [Terminal.Gui.Pos]::Right($ListView) + 1; $global:MasterDescView.Y = 2
        $global:MasterDescView.Width = [Terminal.Gui.Dim]::Fill()
        $global:MasterDescView.Height = [Terminal.Gui.Dim]::Fill()
        $global:MasterDescView.ReadOnly = $true
        $MainWindow.Add($global:MasterDescView)

        $SelectedItemChangedAction = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e)
            & $global:UpdateMasterRightPane -ItemIndex $e.Item
        }
        [void]$ListView.add_SelectedItemChanged($SelectedItemChangedAction)

        & $global:UpdateMasterRightPane -ItemIndex 0

        $ItemOpenedAction = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e)
            if ($e.Item -eq ($global:MasterMenuItems.Count - 1)) { 
                $global:ExitMaster = $true
            } elseif ($global:MasterModulePaths.Count -gt 0) {
                $global:TargetModule = $global:MasterModulePaths[$e.Item]
            }
            [Terminal.Gui.Application]::RequestStop()
        }
        [void]$ListView.add_OpenSelectedItem($ItemOpenedAction)

        # --- BOTTOM STATUS BAR ---
        $DummyAction = [System.Action]{ }
        $StatusArray = [Terminal.Gui.StatusItem[]]@(
            (New-Object Terminal.Gui.StatusItem([Terminal.Gui.Key]::Null, "Operating Environment: $TargetRepo", $DummyAction))
        )
        $StatusBar = New-Object Terminal.Gui.StatusBar($StatusArray)
        $Top.Add($StatusBar)

        [Terminal.Gui.Application]::Run()
        [Terminal.Gui.Application]::Shutdown()

        # --- [4] DYNAMIC MODULE INJECTION ---
        if ($global:TargetModule) {
            Clear-Host
            $CacheBuster = [guid]::NewGuid().ToString()
            $FetchUrl = "https://raw.githubusercontent.com/$RepoOwner/$TargetRepo/$Branch/$($global:TargetModule)/Entry.ps1?t=$CacheBuster"
            
            try {
                if ($AuthHeader) {
                    $ModuleCode = Invoke-RestMethod -Uri $FetchUrl -Headers $AuthHeader -UseBasicParsing
                } else {
                    $ModuleCode = Invoke-RestMethod -Uri $FetchUrl -UseBasicParsing
                }
                
                $ScriptBlock = [scriptblock]::Create($ModuleCode)
                . $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner -RepoName $TargetRepo -Branch $Branch -AppName $global:TargetModule

            } catch {
                Write-Host "`n[!] CRASH fetching or running $($global:TargetModule) Orchestrator: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Press [Enter] to continue..." -ForegroundColor Yellow
                Read-Host | Out-Null
            }
            
            $global:TargetModule = $null 
        }
    }
} catch {
    Write-Host "`n[!] Master Enclave Crash: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n[+] Master Enclave Terminated. Returning to prompt." -ForegroundColor Green
