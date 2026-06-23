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
if (-not $AuthHeader) {
    if     ($global:ToolkitAuthHeader)              { $AuthHeader = $global:ToolkitAuthHeader }
    elseif ($global:ToolkitPAT)                     { $AuthHeader = @{ Authorization = "Bearer $global:ToolkitPAT" } }
    elseif ($env:GITHUB_TOKEN)                      { $AuthHeader = @{ Authorization = "Bearer $env:GITHUB_TOKEN"  } }
}
if ($global:ToolkitRepoOwner)  { $RepoOwner  = $global:ToolkitRepoOwner  }
if ($global:ToolkitTargetRepo) { $TargetRepo = $global:ToolkitTargetRepo }
if ($global:ToolkitBranch)     { $Branch     = $global:ToolkitBranch     }

function Write-Log { param($Level,$Message)
    if ($Global:DebugSync -and $Global:DebugSync.Running -and (Get-Command Write-DebugWindow -EA SilentlyContinue)) {
        $safeLevel = if ($Level -in @('INFO','WARN','ERROR','DEBUG')) { $Level } else { 'INFO' }
        Write-DebugWindow -Message "[$Level] $Message" -Level $safeLevel
    } else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" -ForegroundColor DarkGray
    }
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

    # Assembly::LoadFrom skips .NET CLS compliance checks that Add-Type triggers on Terminal.Gui.Key
    try { [System.Reflection.Assembly]::LoadFrom($NStackDll.FullName) | Out-Null } catch { }
    try { [System.Reflection.Assembly]::LoadFrom($GuiDll.FullName)    | Out-Null } catch { }

    # ----------------------------------------------------------------
    # [2] DYNAMIC MODULE DISCOVERY  (full inventory per module)
    # ----------------------------------------------------------------
    Write-Log "INFO" "Auth: $(if ($AuthHeader) { 'Active (token present)' } else { 'None — private repo will 404' })"
    Write-Log "INFO" "Querying GitHub API — $RepoOwner/$TargetRepo @ $Branch..."

    $global:Modules = [System.Collections.Generic.List[hashtable]]::new()

    $ApiBase   = "https://api.github.com/repos/$RepoOwner/$TargetRepo"
    $RootParams = @{ Uri = "$ApiBase/contents?ref=$Branch"; ErrorAction = "Stop" }
    if ($AuthHeader) { $RootParams.Headers = $AuthHeader }

    try {
        $Dirs = (Invoke-RestMethod @RootParams) |
                Where-Object { $_.type -eq 'dir' -and $_.name -notmatch '^\.' } |
                Sort-Object name

        foreach ($Dir in $Dirs) {
            Write-Log "INFO" "  Inventorying: $($Dir.name)"
            $Synopsis  = "IR & Admin module."
            $Scripts   = [System.Collections.Generic.List[hashtable]]::new()

            try {
                # Get full directory listing
                $DirParams = @{ Uri = "$ApiBase/contents/$($Dir.name)?ref=$Branch"; ErrorAction = "Stop" }
                if ($AuthHeader) { $DirParams.Headers = $AuthHeader }
                $DirItems = Invoke-RestMethod @DirParams

                $Ps1Files = $DirItems | Where-Object { $_.type -eq 'file' -and $_.name -like '*.ps1' } | Sort-Object name

                foreach ($File in $Ps1Files) {
                    $Desc = ""
                    try {
                        $FetchParams = @{ Uri = $File.download_url; UseBasicParsing = $true; ErrorAction = "Stop" }
                        if ($AuthHeader) { $FetchParams.Headers = $AuthHeader }
                        $Raw = Invoke-RestMethod @FetchParams

                        # Prefer .SYNOPSIS, fall back to .DESCRIPTION
                        if ($Raw -match '(?ms)<#.*?\.SYNOPSIS\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                            $Desc = ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                        } elseif ($Raw -match '(?ms)<#.*?\.DESCRIPTION\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                            $Desc = ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                        }
                    } catch { }

                    if ($File.name -eq 'Entry.ps1') {
                        if ($Desc) { $Synopsis = $Desc }
                    } else {
                        $Scripts.Add(@{ Name = ($File.name -replace '\.ps1$', ''); Desc = $Desc })
                    }
                }

                # Also discover subdirectories (e.g. PoC has phase files)
                $SubDirs = $DirItems | Where-Object { $_.type -eq 'dir' -and $_.name -notmatch '^\.' }
                foreach ($Sub in $SubDirs) {
                    try {
                        $SubParams = @{ Uri = "$ApiBase/contents/$($Dir.name)/$($Sub.name)?ref=$Branch"; ErrorAction = "Stop" }
                        if ($AuthHeader) { $SubParams.Headers = $AuthHeader }
                        $SubItems = Invoke-RestMethod @SubParams
                        $SubPs1   = $SubItems | Where-Object { $_.type -eq 'file' -and $_.name -like '*.ps1' } | Sort-Object name
                        foreach ($SF in $SubPs1) {
                            $Desc = ""
                            try {
                                $SFParams = @{ Uri = $SF.download_url; UseBasicParsing = $true; ErrorAction = "Stop" }
                                if ($AuthHeader) { $SFParams.Headers = $AuthHeader }
                                $Raw = Invoke-RestMethod @SFParams
                                if ($Raw -match '(?ms)<#.*?\.SYNOPSIS\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                                    $Desc = ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                                } elseif ($Raw -match '(?ms)<#.*?\.DESCRIPTION\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                                    $Desc = ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                                }
                            } catch { }
                            $Scripts.Add(@{ Name = "$($Sub.name)/$($SF.name -replace '\.ps1$','')"; Desc = $Desc })
                        }
                    } catch { }
                }

            } catch {
                Write-Log "WARN" "    Could not inventory $($Dir.name): $($_.Exception.Message)"
            }

            $global:Modules.Add(@{
                Name      = $Dir.name
                Synopsis  = $Synopsis
                Scripts   = $Scripts
            })
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
        $Win.Height = [Terminal.Gui.Dim]::Fill()
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
        $ListFrame.Height      = [Terminal.Gui.Dim]::Fill() - 1
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
        $InfoFrame.Height      = [Terminal.Gui.Dim]::Fill() - 1
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
                $t  = "`n  EXIT`n"
                $t += "  ══════════════════════════════`n`n"
                $t += "  Close the TUI and return`n"
                $t += "  to the terminal prompt.`n`n"
                $t += "  Press [Enter] to confirm."
            } else {
                $m  = $global:Modules[$Index]

                $t  = "`n  $($m.Name.ToUpper())`n"
                $t += "  ══════════════════════════════`n`n"

                # Word-wrap synopsis at ~38 chars
                $words = $m.Synopsis -split '\s+'
                $line  = "  "; $wrapped = @()
                foreach ($w in $words) {
                    if (($line + $w).Length -gt 40) { $wrapped += $line.TrimEnd(); $line = "  $w " }
                    else { $line += "$w " }
                }
                if ($line.Trim()) { $wrapped += $line.TrimEnd() }
                $t += ($wrapped -join "`n") + "`n"

                # Script inventory
                $t += "`n  ── SCRIPTS ($($m.Scripts.Count + 1) files) ──────────`n"
                $t += "  ◆ Entry.ps1`n"
                foreach ($s in $m.Scripts) {
                    $label = "  ◇ $($s.Name)"
                    if ($s.Desc) {
                        $maxDesc = 38 - $label.Length
                        $descTrim = if ($s.Desc.Length -gt $maxDesc -and $maxDesc -gt 3) {
                            $s.Desc.Substring(0, $maxDesc - 3) + "..."
                        } else { $s.Desc }
                        $t += "$label  $descTrim`n"
                    } else {
                        $t += "$label`n"
                    }
                }

                $t += "`n  ──────────────────────────────`n"
                $t += "  Vault  : $RepoOwner/$TargetRepo`n"
                $t += "  Branch : $Branch`n"
                $t += "  Path   : /$($m.Name)/Entry.ps1`n`n"
                $t += "  Press [Enter] to launch."
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

        # ── Nav hint label (replaces StatusBar — avoids Terminal.Gui.Key CLS crash) ──
        $NavLabel = New-Object Terminal.Gui.Label("  ↑↓ Navigate   Enter: Launch Module   Vault: $RepoOwner/$TargetRepo [$Branch]  ")
        $NavLabel.X           = 0
        $NavLabel.Y           = [Terminal.Gui.Pos]::AnchorEnd(1)
        $NavLabel.Width       = [Terminal.Gui.Dim]::Fill()
        $NavLabel.ColorScheme = $SchemeHeader
        $Win.Add($NavLabel)

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
                $errMsg = "[!] CRASH in $($global:TargetModule): $($_.Exception.Message)"
                Write-Host "`n$errMsg" -ForegroundColor Red
                if ($Global:DebugSync -and $Global:DebugSync.Running -and (Get-Command Write-DebugWindow -EA SilentlyContinue)) {
                    Write-DebugWindow $errMsg -Level ERROR
                }
            }

            Write-Host "`n─────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host "  Press [Enter] to return to the Toolkit..." -ForegroundColor Gray
            Read-Host | Out-Null

            $global:TargetModule = $null
        }
    }

} catch {
    Write-Host "`n[!] Master Enclave Crash: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n[+] Toolkit Enclave terminated. Returning to prompt." -ForegroundColor Green
