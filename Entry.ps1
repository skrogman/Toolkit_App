# ==================================================================
# MASTER ORCHESTRATOR: TUI Module Enclave
# Repository: Toolkit_App / Entry.ps1
# ==================================================================
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)][hashtable]$AuthHeader,
    [Parameter(Mandatory=$false)][string]$RepoOwner  = "skrogman",
    [Parameter(Mandatory=$false)][string]$TargetRepo = "Toolkit_Modules",
    [Parameter(Mandatory=$false)][string]$Branch     = "main",
    [Parameter(ValueFromRemainingArguments=$true)]$CatchAllParameters
)

$ErrorActionPreference = "Stop"

# Inherit token from Start-Toolkit globals when not passed as a param
if (-not $AuthHeader -and $global:ToolkitAuthHeader) { $AuthHeader  = $global:ToolkitAuthHeader }
if (-not $RepoOwner  -and $global:ToolkitRepoOwner)  { $RepoOwner   = $global:ToolkitRepoOwner  }
if (-not $TargetRepo -and $global:ToolkitTargetRepo) { $TargetRepo  = $global:ToolkitTargetRepo }
if (-not $Branch     -and $global:ToolkitBranch)     { $Branch      = $global:ToolkitBranch     }

function Write-Log { param($Level,$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" -ForegroundColor DarkGray
}

try {
    # ----------------------------------------------------------------
    # [1] DEPENDENCY BOOTSTRAPPER
    # ----------------------------------------------------------------
    $GuiVersion   = "1.14.1"
    $NStackVersion = "1.0.7"
    $TempDir      = Join-Path $env:TEMP "TerminalGui_Standalone_Master"
    $ExtractDir   = Join-Path $TempDir  "Assemblies"

    if (-not (Test-Path $ExtractDir)) {
        Write-Log "INFO" "First run — downloading Terminal.Gui framework..."
        $null = New-Item -Path $ExtractDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Terminal.Gui/$GuiVersion"    -OutFile "$TempDir\Terminal.Gui.zip"
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/NStack.Core/$NStackVersion" -OutFile "$TempDir\NStack.Core.zip"
        Expand-Archive -Path "$TempDir\Terminal.Gui.zip"    -DestinationPath $ExtractDir -Force
        Expand-Archive -Path "$TempDir\NStack.Core.zip"     -DestinationPath $ExtractDir -Force
    }

    $NStackDll = Get-ChildItem -Path $ExtractDir -Filter "NStack.dll"        -Recurse | Select-Object -First 1
    $GuiDll    = Get-ChildItem -Path $ExtractDir -Filter "Terminal.Gui.dll"  -Recurse | Select-Object -First 1

    try { Add-Type -Path $NStackDll.FullName -ErrorAction Stop } catch { }
    try { Add-Type -Path $GuiDll.FullName    -ErrorAction Stop } catch { }

    # ----------------------------------------------------------------
    # [2] DYNAMIC MODULE DISCOVERY  (with synopsis fetch)
    # ----------------------------------------------------------------
    Write-Log "INFO" "Querying GitHub API — $RepoOwner/$TargetRepo @ $Branch..."

    $global:Modules = [System.Collections.Generic.List[hashtable]]::new()

    $ApiParams = @{ Uri = "https://api.github.com/repos/$RepoOwner/$TargetRepo/contents?ref=$Branch"; ErrorAction = "Stop" }
    if ($AuthHeader) { $ApiParams.Headers = $AuthHeader }

    try {
        $Dirs = (Invoke-RestMethod @ApiParams) |
                Where-Object { $_.type -eq 'dir' -and $_.name -notmatch '^\.' } |
                Sort-Object name

        foreach ($Dir in $Dirs) {
            $Synopsis = "IR & Admin module — press Enter to launch."
            try {
                $RawParams = @{ Uri = "https://raw.githubusercontent.com/$RepoOwner/$TargetRepo/$Branch/$($Dir.name)/Entry.ps1"; UseBasicParsing = $true; ErrorAction = "Stop" }
                if ($AuthHeader) { $RawParams.Headers = $AuthHeader }
                $Raw = Invoke-RestMethod @RawParams
                if ($Raw -match '(?ms)<#.*?\.SYNOPSIS\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                    $s = ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                    if ($s) { $Synopsis = $s }
                }
            } catch { }

            $global:Modules.Add(@{ Name = $Dir.name; Synopsis = $Synopsis })
            Write-Log "INFO" "  Discovered: $($Dir.name)"
        }
    } catch {
        Write-Log "ERROR" "GitHub API error: $($_.Exception.Message)"
    }

    # Build the flat label list for Terminal.Gui's ListView
    $global:MenuLabels = [System.Collections.ArrayList]@()
    foreach ($m in $global:Modules) { [void]$global:MenuLabels.Add("  $($m.Name)") }
    [void]$global:MenuLabels.Add("  ─── Exit Toolkit ───")

    # ----------------------------------------------------------------
    # [3] TUI LOOP
    # ----------------------------------------------------------------
    $global:ExitMaster   = $false
    $global:TargetModule = $null

    while (-not $global:ExitMaster) {

        # Strip TERM vars so Terminal.Gui doesn't probe for Linux libc
        $BakTerm  = [Environment]::GetEnvironmentVariable("TERM",      "Process")
        $BakColor = [Environment]::GetEnvironmentVariable("COLORTERM", "Process")
        [Environment]::SetEnvironmentVariable("TERM",      $null, "Process")
        [Environment]::SetEnvironmentVariable("COLORTERM", $null, "Process")

        [Terminal.Gui.Application]::Init()
        $Top = [Terminal.Gui.Application]::Top

        if ($BakTerm)  { [Environment]::SetEnvironmentVariable("TERM",      $BakTerm,  "Process") }
        if ($BakColor) { [Environment]::SetEnvironmentVariable("COLORTERM", $BakColor, "Process") }

        # ── Color schemes ──────────────────────────────────────────
        $SchemeApp = New-Object Terminal.Gui.ColorScheme
        $SchemeApp.Normal    = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::White,        [Terminal.Gui.Color]::Blue)
        $SchemeApp.Focus     = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::Black,        [Terminal.Gui.Color]::Cyan)
        $SchemeApp.HotNormal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow, [Terminal.Gui.Color]::Blue)
        $SchemeApp.HotFocus  = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow, [Terminal.Gui.Color]::Cyan)

        $SchemeHeader = New-Object Terminal.Gui.ColorScheme
        $SchemeHeader.Normal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::Black, [Terminal.Gui.Color]::Cyan)

        $SchemeInfo = New-Object Terminal.Gui.ColorScheme
        $SchemeInfo.Normal    = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightCyan,  [Terminal.Gui.Color]::Blue)
        $SchemeInfo.HotNormal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow,[Terminal.Gui.Color]::Blue)

        # ── Root window ────────────────────────────────────────────
        $Win = New-Object Terminal.Gui.Window
        $Win.ColorScheme = $SchemeApp
        $Win.Height = [Terminal.Gui.Dim]::Fill() - 1
        $Top.Add($Win)

        # ── Header bar ─────────────────────────────────────────────
        $AuthTag     = if ($AuthHeader) { "Auth: Active" } else { "Auth: Anonymous" }
        $HeaderLabel = New-Object Terminal.Gui.Label("  CASSENA CARE IR TOOLKIT  |  Operator: $($env:USERNAME)  |  $AuthTag  |  [Shift+Boot] → Admin  ")
        $HeaderLabel.X           = 0
        $HeaderLabel.Y           = 0
        $HeaderLabel.Width       = [Terminal.Gui.Dim]::Fill()
        $HeaderLabel.ColorScheme = $SchemeHeader
        $Win.Add($HeaderLabel)

        # ── Left pane — module list ────────────────────────────────
        $ListFrame = New-Object Terminal.Gui.FrameView("  MODULES  ")
        $ListFrame.X           = 0
        $ListFrame.Y           = 2
        $ListFrame.Width       = [Terminal.Gui.Dim]::Percent(36)
        $ListFrame.Height      = [Terminal.Gui.Dim]::Fill()
        $ListFrame.ColorScheme = $SchemeApp
        $Win.Add($ListFrame)

        $ListView = New-Object Terminal.Gui.ListView
        [void]$ListView.SetSource($global:MenuLabels)
        $ListView.X           = 0
        $ListView.Y           = 0
        $ListView.Width       = [Terminal.Gui.Dim]::Fill()
        $ListView.Height      = [Terminal.Gui.Dim]::Fill()
        $ListView.ColorScheme = $SchemeApp
        $ListFrame.Add($ListView)

        # ── Right pane — module info ───────────────────────────────
        $InfoFrame = New-Object Terminal.Gui.FrameView("  MODULE INFO  ")
        $InfoFrame.X           = [Terminal.Gui.Pos]::Right($ListFrame) + 1
        $InfoFrame.Y           = 2
        $InfoFrame.Width       = [Terminal.Gui.Dim]::Fill()
        $InfoFrame.Height      = [Terminal.Gui.Dim]::Fill()
        $InfoFrame.ColorScheme = $SchemeApp
        $Win.Add($InfoFrame)

        $global:InfoView = New-Object Terminal.Gui.TextView
        $global:InfoView.X           = 0
        $global:InfoView.Y           = 0
        $global:InfoView.Width       = [Terminal.Gui.Dim]::Fill()
        $global:InfoView.Height      = [Terminal.Gui.Dim]::Fill()
        $global:InfoView.ReadOnly    = $true
        $global:InfoView.ColorScheme = $SchemeInfo
        $InfoFrame.Add($global:InfoView)

        # ── Right pane content builder ─────────────────────────────
        $global:BuildInfoPane = {
            param($Index)

            if ($Index -ge $global:Modules.Count) {
                # Exit row
                $t  = "`n  EXIT`n"
                $t += "  ══════════════════════════════`n`n"
                $t += "  Close the TUI and return`n"
                $t += "  to the terminal prompt.`n`n"
                $t += "  Press [Enter] to confirm."
            } else {
                $m  = $global:Modules[$Index]
                $t  = "`n  $($m.Name.ToUpper())`n"
                $t += "  ══════════════════════════════`n`n"
                # Word-wrap synopsis at ~34 chars
                $words = $m.Synopsis -split '\s+'
                $line  = "  "; $lines = @()
                foreach ($w in $words) {
                    if (($line + $w).Length -gt 36) { $lines += $line.TrimEnd(); $line = "  $w " }
                    else { $line += "$w " }
                }
                if ($line.Trim()) { $lines += $line.TrimEnd() }
                $t += ($lines -join "`n") + "`n`n"
                $t += "  ──────────────────────────────`n"
                $t += "  Vault  : $RepoOwner/$TargetRepo`n"
                $t += "  Branch : $Branch`n"
                $t += "  Path   : /$($m.Name)/Entry.ps1`n`n"
                $t += "  Press [Enter] to pull and`n"
                $t += "  inject into runspace."
            }

            $global:InfoView.Text = $t
            $global:InfoView.SetNeedsDisplay()
        }

        # Populate right pane on navigation
        $OnSelectionChanged = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e); & $global:BuildInfoPane -Index $e.Item
        }
        [void]$ListView.add_SelectedItemChanged($OnSelectionChanged)

        # Initial load
        & $global:BuildInfoPane -Index 0

        # Enter / open handler
        $OnItemOpened = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e)
            if ($e.Item -ge $global:Modules.Count) {
                $global:ExitMaster = $true
            } else {
                $global:TargetModule = $global:Modules[$e.Item].Name
            }
            [Terminal.Gui.Application]::RequestStop()
        }
        [void]$ListView.add_OpenSelectedItem($OnItemOpened)

        # ── Status bar ─────────────────────────────────────────────
        $Noop       = [System.Action]{ }
        $StatusBar  = New-Object Terminal.Gui.StatusBar([Terminal.Gui.StatusItem[]]@(
            (New-Object Terminal.Gui.StatusItem([Terminal.Gui.Key]::Null, "↑↓ Navigate",     $Noop)),
            (New-Object Terminal.Gui.StatusItem([Terminal.Gui.Key]::Null, "Enter: Launch",   $Noop)),
            (New-Object Terminal.Gui.StatusItem([Terminal.Gui.Key]::Null, "Vault: $RepoOwner/$TargetRepo [$Branch]", $Noop))
        ))
        $Top.Add($StatusBar)

        [Terminal.Gui.Application]::Run()
        [Terminal.Gui.Application]::Shutdown()

        # ----------------------------------------------------------------
        # [4] DYNAMIC MODULE INJECTION
        # ----------------------------------------------------------------
        if ($global:TargetModule) {
            Clear-Host
            Write-Log "INFO" "Fetching module: $global:TargetModule"

            $CacheBuster = [guid]::NewGuid().ToString()
            $FetchUrl    = "https://raw.githubusercontent.com/$RepoOwner/$TargetRepo/$Branch/$($global:TargetModule)/Entry.ps1?t=$CacheBuster"

            try {
                $FetchParams = @{ Uri = $FetchUrl; UseBasicParsing = $true; ErrorAction = "Stop" }
                if ($AuthHeader) { $FetchParams.Headers = $AuthHeader }
                $ModuleCode = Invoke-RestMethod @FetchParams

                $ScriptBlock = [scriptblock]::Create($ModuleCode)
                . $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner -RepoName $TargetRepo -Branch $Branch -AppName $global:TargetModule

            } catch {
                Write-Host "`n[!] CRASH fetching or running $($global:TargetModule): $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "Press [Enter] to continue..." -ForegroundColor Yellow
                Read-Host | Out-Null
            }

            $global:TargetModule = $null
        }
    }

} catch {
    Write-Host "`n[!] Master Enclave Crash: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n[+] Toolkit Enclave terminated. Returning to prompt." -ForegroundColor Green
