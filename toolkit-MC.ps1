# ==================================================================
# TOOLKIT MC — Midnight Commander-style Navigator
# Repository: Toolkit_App / toolkit-MC.ps1
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

if (-not $AuthHeader) {
    if     ($global:ToolkitAuthHeader) { $AuthHeader = $global:ToolkitAuthHeader }
    elseif ($global:ToolkitPAT)        { $AuthHeader = @{ Authorization = "Bearer $global:ToolkitPAT" } }
    elseif ($env:GITHUB_TOKEN)         { $AuthHeader = @{ Authorization = "Bearer $env:GITHUB_TOKEN"  } }
}
if ($global:ToolkitRepoOwner)  { $RepoOwner  = $global:ToolkitRepoOwner  }
if ($global:ToolkitTargetRepo) { $TargetRepo = $global:ToolkitTargetRepo }
if ($global:ToolkitBranch)     { $Branch     = $global:ToolkitBranch     }

$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

try {
    # ----------------------------------------------------------------
    # [1] DEPENDENCY BOOTSTRAPPER (Terminal.Gui)
    # ----------------------------------------------------------------
    $GuiVersion    = "1.14.1"
    $NStackVersion = "1.0.7"
    $TempDir       = Join-Path $env:TEMP "TerminalGui_Standalone_Master"
    $ExtractDir    = Join-Path $TempDir  "Assemblies"

    if (-not (Test-Path $ExtractDir)) {
        Write-Host "First run — downloading Terminal.Gui framework..." -ForegroundColor Cyan
        $null = New-Item -Path $ExtractDir -ItemType Directory -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Terminal.Gui/$GuiVersion"    -OutFile "$TempDir\Terminal.Gui.zip"
        Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/NStack.Core/$NStackVersion" -OutFile "$TempDir\NStack.Core.zip"
        Expand-Archive -Path "$TempDir\Terminal.Gui.zip"    -DestinationPath $ExtractDir -Force
        Expand-Archive -Path "$TempDir\NStack.Core.zip"     -DestinationPath $ExtractDir -Force
    }

    $NStackDll = Get-ChildItem -Path $ExtractDir -Filter "NStack.dll"       -Recurse | Select-Object -First 1
    $GuiDll    = Get-ChildItem -Path $ExtractDir -Filter "Terminal.Gui.dll" -Recurse | Select-Object -First 1
    try { [System.Reflection.Assembly]::LoadFrom($NStackDll.FullName) | Out-Null } catch { }
    try { [System.Reflection.Assembly]::LoadFrom($GuiDll.FullName)    | Out-Null } catch { }

    # ----------------------------------------------------------------
    # [2] API + CACHE LAYER
    # ----------------------------------------------------------------
    $ApiBase             = "https://api.github.com/repos/$RepoOwner/$TargetRepo"
    $global:DirCache     = @{}   # path → raw API item array
    $global:ContentCache = @{}   # download_url → raw text content

    function Get-DirListing {
        param([string]$Path)
        if (-not $global:DirCache.ContainsKey($Path)) {
            $uri = if ($Path -eq "") { "$ApiBase/contents?ref=$Branch" }
                   else              { "$ApiBase/contents/$Path`?ref=$Branch" }
            try {
                $p = @{ Uri = $uri; ErrorAction = "Stop" }
                if ($AuthHeader) { $p.Headers = $AuthHeader }
                $global:DirCache[$Path] = @(Invoke-RestMethod @p)
            } catch {
                $global:DirCache[$Path] = @()
            }
        }
        return $global:DirCache[$Path]
    }

    function Get-FileContent {
        param([string]$DownloadUrl)
        if (-not $global:ContentCache.ContainsKey($DownloadUrl)) {
            try {
                $p = @{ Uri = $DownloadUrl; UseBasicParsing = $true; ErrorAction = "Stop" }
                if ($AuthHeader) { $p.Headers = $AuthHeader }
                $global:ContentCache[$DownloadUrl] = Invoke-RestMethod @p
            } catch {
                $global:ContentCache[$DownloadUrl] = $null
            }
        }
        return $global:ContentCache[$DownloadUrl]
    }

    # Extract human-readable description from file content based on type
    function Get-FileDescription {
        param([string]$Content, [string]$Extension)
        if (-not $Content) { return "" }
        $ext = $Extension.ToLower().TrimStart('.')

        if ($ext -in @('ps1','psm1')) {
            if ($Content -match '(?ms)<#.*?\.SYNOPSIS\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                return ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
            }
            if ($Content -match '(?ms)<#.*?\.DESCRIPTION\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                return ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
            }
            # Fall back to leading # comment lines
            $comments = @($Content -split '\r?\n' | Select-Object -First 30 |
                          Where-Object { $_ -match '^\s*#\s*(.+)' } |
                          ForEach-Object { ($_ -replace '^\s*#+\s*','').Trim() } |
                          Where-Object { $_ -and $_ -notmatch '^={3,}$' -and $_ -notmatch '^-{3,}$' } |
                          Select-Object -First 4)
            return $comments -join '  —  '
        }

        if ($ext -in @('cmd','bat')) {
            $lines  = @($Content -split '\r?\n' | Select-Object -First 50)
            $result = [System.Collections.Generic.List[string]]::new()
            $started = $false
            foreach ($l in $lines) {
                $t = $l.TrimStart()
                if     ($t -match '^::\s*(.+)')         { $result.Add($Matches[1].Trim()); $started = $true }
                elseif ($t -match '^@?REM\s+(.+)')      { $result.Add($Matches[1].Trim()); $started = $true }
                elseif ($started -and $t -ne '' -and $t -notmatch '^@?(?:echo|setlocal|pushd)') { break }
            }
            return ($result | Select-Object -First 6 | Where-Object { $_ }) -join '  |  '
        }

        return ""
    }

    # Word-wrap text at ~$Width chars, prefixed with $Indent on each line
    function Format-Wrapped {
        param([string]$Text, [int]$Width = 38, [string]$Indent = "  ")
        if (-not $Text) { return "" }
        $words   = $Text -split '\s+'
        $line    = $Indent
        $wrapped = [System.Collections.Generic.List[string]]::new()
        foreach ($w in $words) {
            if (($line + $w).Length -gt $Width) { $wrapped.Add($line.TrimEnd()); $line = "$Indent$w " }
            else { $line += "$w " }
        }
        if ($line.Trim()) { $wrapped.Add($line.TrimEnd()) }
        return $wrapped -join "`n"
    }

    # ----------------------------------------------------------------
    # [3] NAVIGATOR ITEM BUILDER
    # ----------------------------------------------------------------
    # Item types:  parent | dir | entry | file | executable | exit
    # Icons:  [↑] parent   [/] dir   [►] Entry.ps1
    #         [S] .ps1     [M] .psm1  [C] .cmd  [B] .bat
    #         [E] .exe     [I] .msi   [?] unknown
    function Get-NavItems {
        param([string]$Path)
        $raw    = Get-DirListing $Path
        $result = [System.Collections.Generic.List[hashtable]]::new()

        # [↑] parent — only when not at root
        if ($Path -ne "") {
            $parentPath = if ($Path -match '^[^/]+$') { "" } else { $Path -replace '/[^/]+$','' }
            $result.Add(@{
                Type='parent'; Name='..'; Label="  [↑] ..";
                DownloadUrl=$null; Extension=''; Size=0; Path=$parentPath
            })
        }

        # Dirs first, then files; Entry.ps1 floated to top of files
        $dirs       = @($raw | Where-Object { $_.type -eq 'dir'  -and $_.name -notmatch '^\.' } | Sort-Object name)
        $files      = @($raw | Where-Object { $_.type -eq 'file' } | Sort-Object name)
        $entryFile  = $files | Where-Object { $_.name -eq 'Entry.ps1' } | Select-Object -First 1
        $otherFiles = @($files | Where-Object { $_.name -ne 'Entry.ps1' })

        foreach ($d in $dirs) {
            $childPath = if ($Path -eq "") { $d.name } else { "$Path/$($d.name)" }
            $result.Add(@{
                Type='dir'; Name=$d.name; Label="  [/] $($d.name)/";
                DownloadUrl=$null; Extension=''; Size=0; Path=$childPath
            })
        }

        if ($entryFile) {
            $result.Add(@{
                Type='entry'; Name='Entry.ps1'; Label="  [►] Entry.ps1";
                DownloadUrl=$entryFile.download_url; Extension='ps1';
                Size=$entryFile.size; Path=$Path
            })
        }

        foreach ($f in $otherFiles) {
            $ext  = if ($f.name -match '\.([^.]+)$') { $Matches[1].ToLower() } else { '' }
            $icon = switch ($ext) {
                'ps1'   { '[S]' }
                'psm1'  { '[M]' }
                'cmd'   { '[C]' }
                'bat'   { '[B]' }
                'exe'   { '[E]' }
                'msi'   { '[I]' }
                default { '[?]' }
            }
            $isBin = $ext -in @('exe','msi','dll','bin')
            $result.Add(@{
                Type        = if ($isBin) { 'executable' } else { 'file' }
                Name        = $f.name
                Label       = "  $icon $($f.name)"
                DownloadUrl = $f.download_url
                Extension   = $ext
                Size        = $f.size
                Path        = $Path
            })
        }

        # [─] exit — only at root
        if ($Path -eq "") {
            $result.Add(@{
                Type='exit'; Name='Exit'; Label="  ─── Exit Toolkit ───";
                DownloadUrl=$null; Extension=''; Size=0; Path=''
            })
        }

        return $result
    }

    # ----------------------------------------------------------------
    # [4] TUI LOOP
    # ----------------------------------------------------------------
    $global:ExitMaster    = $false
    $global:TargetExec    = $null
    $global:CurrentPath   = ""
    $global:CurrentItems  = Get-NavItems ""
    $global:LastRunOutput = $null
    $global:LastRunName   = $null

    while (-not $global:ExitMaster) {

        $BakTerm  = [Environment]::GetEnvironmentVariable("TERM",      "Process")
        $BakColor = [Environment]::GetEnvironmentVariable("COLORTERM", "Process")
        [Environment]::SetEnvironmentVariable("TERM",      $null, "Process")
        [Environment]::SetEnvironmentVariable("COLORTERM", $null, "Process")

        [Terminal.Gui.Application]::Init()
        $Top = [Terminal.Gui.Application]::Top

        if ($BakTerm)  { [Environment]::SetEnvironmentVariable("TERM",      $BakTerm,  "Process") }
        if ($BakColor) { [Environment]::SetEnvironmentVariable("COLORTERM", $BakColor, "Process") }

        # ── Color schemes ──────────────────────────────────────────────
        $SchemeApp = New-Object Terminal.Gui.ColorScheme
        $SchemeApp.Normal    = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::White,        [Terminal.Gui.Color]::Blue)
        $SchemeApp.Focus     = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::Black,        [Terminal.Gui.Color]::Cyan)
        $SchemeApp.HotNormal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow, [Terminal.Gui.Color]::Blue)
        $SchemeApp.HotFocus  = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow, [Terminal.Gui.Color]::Cyan)

        $SchemeHeader = New-Object Terminal.Gui.ColorScheme
        $SchemeHeader.Normal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::Black, [Terminal.Gui.Color]::Cyan)

        $SchemeInfo = New-Object Terminal.Gui.ColorScheme
        $SchemeInfo.Normal    = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightCyan,   [Terminal.Gui.Color]::Blue)
        $SchemeInfo.HotNormal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::BrightYellow, [Terminal.Gui.Color]::Blue)

        # ── Root window ────────────────────────────────────────────────
        $Win = New-Object Terminal.Gui.Window
        $Win.ColorScheme = $SchemeApp
        $Win.Height = [Terminal.Gui.Dim]::Fill()
        $Top.Add($Win)

        # ── Header ─────────────────────────────────────────────────────
        $AuthTag    = if ($AuthHeader) { "Auth:Active" } else { "Auth:Anon" }
        $ElevTag    = if ($IsElevated) { "  ★ ADMIN" } else { "" }
        $PathDisp   = if ($global:CurrentPath) { $global:CurrentPath } else { "[root]" }
        $global:HeaderLabel = New-Object Terminal.Gui.Label("  TOOLKIT MC  |  $RepoOwner/$TargetRepo  |  /$PathDisp  |  $AuthTag$ElevTag  |  $($env:USERNAME)  ")
        $global:HeaderLabel.X           = 0
        $global:HeaderLabel.Y           = 0
        $global:HeaderLabel.Width       = [Terminal.Gui.Dim]::Fill()
        $global:HeaderLabel.ColorScheme = $SchemeHeader
        $Win.Add($global:HeaderLabel)

        # ── Left pane — MC navigator ───────────────────────────────────
        $LeftTitle = if ($global:CurrentPath) {
            "  $($global:CurrentPath.Split('/')[-1])/  "
        } else {
            "  $TargetRepo/  "
        }
        $ListFrame = New-Object Terminal.Gui.FrameView($LeftTitle)
        $ListFrame.X           = 0
        $ListFrame.Y           = 2
        $ListFrame.Width       = [Terminal.Gui.Dim]::Percent(38)
        $ListFrame.Height      = [Terminal.Gui.Dim]::Fill() - 1
        $ListFrame.ColorScheme = $SchemeApp
        $Win.Add($ListFrame)

        $MenuLabels = [System.Collections.ArrayList]@()
        foreach ($item in $global:CurrentItems) { [void]$MenuLabels.Add($item.Label) }

        $ListView = New-Object Terminal.Gui.ListView
        [void]$ListView.SetSource($MenuLabels)
        $ListView.X           = 0
        $ListView.Y           = 0
        $ListView.Width       = [Terminal.Gui.Dim]::Fill()
        $ListView.Height      = [Terminal.Gui.Dim]::Fill()
        $ListView.ColorScheme = $SchemeApp
        $ListFrame.Add($ListView)

        # ── Right pane — info ───────────────────────────────────────────
        $global:InfoFrame = New-Object Terminal.Gui.FrameView("  INFO  ")
        $global:InfoFrame.X           = [Terminal.Gui.Pos]::Right($ListFrame) + 1
        $global:InfoFrame.Y           = 2
        $global:InfoFrame.Width       = [Terminal.Gui.Dim]::Fill()
        $global:InfoFrame.Height      = [Terminal.Gui.Dim]::Fill() - 1
        $global:InfoFrame.ColorScheme = $SchemeApp
        $Win.Add($global:InfoFrame)

        $global:InfoView = New-Object Terminal.Gui.TextView
        $global:InfoView.X           = 0
        $global:InfoView.Y           = 0
        $global:InfoView.Width       = [Terminal.Gui.Dim]::Fill()
        $global:InfoView.Height      = [Terminal.Gui.Dim]::Fill()
        $global:InfoView.ReadOnly    = $true
        $global:InfoView.ColorScheme = $SchemeInfo
        $global:InfoFrame.Add($global:InfoView)

        # ── Right pane builder (lazy — fetches content on demand) ───────
        $global:BuildInfoPane = {
            param($Index)
            if ($Index -lt 0 -or $Index -ge $global:CurrentItems.Count) { return }
            $item = $global:CurrentItems[$Index]

            if ($item.Type -eq 'exit') {
                $t  = "`n  EXIT`n"
                $t += "  ══════════════════════════════`n`n"
                $t += "  Close the navigator and return`n"
                $t += "  to the terminal prompt.`n`n"
                $t += "  Press [Enter] to confirm."

            } elseif ($item.Type -eq 'parent') {
                $parentDisp = if ($item.Path -eq "") { "[root]" } else { $item.Path }
                $t  = "`n  ← UP`n"
                $t += "  ══════════════════════════════`n`n"
                $t += "  Navigate to: /$parentDisp`n`n"
                $t += "  Press [Enter] to go up."

            } elseif ($item.Type -eq 'dir') {
                # Lazy-fetch directory listing for preview
                $children = Get-DirListing $item.Path
                $nDirs    = @($children | Where-Object { $_.type -eq 'dir'  }).Count
                $nFiles   = @($children | Where-Object { $_.type -eq 'file' }).Count
                $hasEntry = $null -ne ($children | Where-Object { $_.name -eq 'Entry.ps1' } | Select-Object -First 1)

                $t  = "`n  $($item.Name.ToUpper())/`n"
                $t += "  ══════════════════════════════`n`n"
                if ($hasEntry) { $t += "  [►] Has Entry.ps1 (launchable)`n" }
                $t += "  $nDirs folder(s)   $nFiles file(s)`n"
                $t += "`n  ── CONTENTS ────────────────────`n"
                $preview = @($children | Sort-Object { if ($_.type -eq 'dir') { 0 } else { 1 } }, name | Select-Object -First 24)
                foreach ($c in $preview) {
                    $pfx = if ($c.type -eq 'dir') { '[/]' } else {
                        $cext = if ($c.name -match '\.([^.]+)$') { $Matches[1].ToLower() } else { '' }
                        switch ($cext) {
                            'ps1'  { '[S]' }; 'psm1' { '[M]' }; 'cmd' { '[C]' }
                            'bat'  { '[B]' }; 'exe'  { '[E]' }; 'msi' { '[I]' }
                            default{ '[?]' }
                        }
                    }
                    $t += "  $pfx $($c.name)`n"
                }
                if ($children.Count -gt 24) { $t += "  ... ($($children.Count - 24) more)`n" }
                $t += "`n  Path : /$($item.Path)`n`n"
                $t += "  Press [Enter] to open."

            } elseif ($item.Type -eq 'entry') {
                $content = Get-FileContent $item.DownloadUrl
                $desc    = Get-FileDescription $content 'ps1'
                $t  = "`n  ► ENTRY.PS1`n"
                $t += "  ══════════════════════════════`n`n"
                if ($desc) { $t += (Format-Wrapped $desc) + "`n" }
                else       { $t += "  (no description found)`n" }
                $t += "`n  ── LAUNCHER INFO ───────────────`n"
                $t += "  Default script for this folder.`n"
                $t += "  Size  : $($item.Size) bytes`n"
                $t += "  Vault : $RepoOwner/$TargetRepo`n"
                $t += "  Path  : /$($item.Path)/Entry.ps1`n`n"
                $t += "  Press [Enter] to execute."

            } elseif ($item.Type -eq 'file') {
                $content = Get-FileContent $item.DownloadUrl
                $desc    = Get-FileDescription $content $item.Extension
                $t  = "`n  $($item.Name.ToUpper())`n"
                $t += "  ══════════════════════════════`n`n"
                if ($desc) { $t += (Format-Wrapped $desc) + "`n" }
                else       { $t += "  (no description found)`n" }
                $t += "`n  ── FILE INFO ───────────────────`n"
                $t += "  Type  : .$($item.Extension)`n"
                $t += "  Size  : $($item.Size) bytes`n"
                $t += "  Vault : $RepoOwner/$TargetRepo`n"
                $t += "  Path  : /$($item.Path)/$($item.Name)`n`n"
                $t += "  Press [Enter] to execute."

            } elseif ($item.Type -eq 'executable') {
                $t  = "`n  $($item.Name.ToUpper())`n"
                $t += "  ══════════════════════════════`n`n"
                $t += "  Executable / binary file`n"
                $t += "`n  ── FILE INFO ───────────────────`n"
                $t += "  Type  : .$($item.Extension)`n"
                $t += "  Size  : $($item.Size) bytes`n"
                $t += "  Vault : $RepoOwner/$TargetRepo`n"
                $t += "  Path  : /$($item.Path)/$($item.Name)`n`n"
                $t += "  [!] Executable launch support`n"
                $t += "  is not yet implemented."

            } else {
                $t = "`n  $($item.Name)`n  ══════════════════════════════`n`n  (unknown item type)"
            }

            $global:InfoView.Text = $t
            $global:InfoView.SetNeedsDisplay()
        }

        # ── Selection handler: triggers lazy right-pane load ────────────
        $OnSelectionChanged = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e); & $global:BuildInfoPane -Index $e.Item
        }
        [void]$ListView.add_SelectedItemChanged($OnSelectionChanged)

        # ── Open handler: navigate folders or execute files ─────────────
        $OnItemOpened = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e)
            $item = $global:CurrentItems[$e.Item]

            if ($item.Type -eq 'exit') {
                $global:ExitMaster = $true
                [Terminal.Gui.Application]::RequestStop()
                return
            }

            if ($item.Type -eq 'parent') {
                $global:CurrentPath  = $item.Path
                $global:CurrentItems = Get-NavItems $item.Path
                $MenuLabels.Clear()
                foreach ($i in $global:CurrentItems) { [void]$MenuLabels.Add($i.Label) }
                $ListView.SetSource($MenuLabels)
                $newTitle = if ($item.Path) { "  $($item.Path.Split('/')[-1])/  " } else { "  $TargetRepo/  " }
                $ListFrame.Title = $newTitle
                $pathD = if ($item.Path) { $item.Path } else { "[root]" }
                $global:HeaderLabel.Text = "  TOOLKIT MC  |  $RepoOwner/$TargetRepo  |  /$pathD  |  $AuthTag$ElevTag  |  $($env:USERNAME)  "
                $global:HeaderLabel.SetNeedsDisplay()
                $ListView.SelectedItem = 0
                & $global:BuildInfoPane -Index 0
                return
            }

            if ($item.Type -eq 'dir') {
                $global:CurrentPath  = $item.Path
                $global:CurrentItems = Get-NavItems $item.Path
                $MenuLabels.Clear()
                foreach ($i in $global:CurrentItems) { [void]$MenuLabels.Add($i.Label) }
                $ListView.SetSource($MenuLabels)
                $ListFrame.Title = "  $($item.Name)/  "
                $global:HeaderLabel.Text = "  TOOLKIT MC  |  $RepoOwner/$TargetRepo  |  /$($item.Path)  |  $AuthTag$ElevTag  |  $($env:USERNAME)  "
                $global:HeaderLabel.SetNeedsDisplay()
                $ListView.SelectedItem = 0
                & $global:BuildInfoPane -Index 0
                return
            }

            if ($item.Type -in @('entry','file')) {
                $global:TargetExec = $item
                [Terminal.Gui.Application]::RequestStop()
                return
            }

            if ($item.Type -eq 'executable') {
                # Not yet implemented — show info only
                & $global:BuildInfoPane -Index $e.Item
                return
            }
        }
        [void]$ListView.add_OpenSelectedItem($OnItemOpened)

        # ── Nav hint ────────────────────────────────────────────────────
        $NavLabel = New-Object Terminal.Gui.Label("  ↑↓ Navigate   Enter: Open/Launch   [/]=Folder  [►]=Launcher  [S]=PS1  [M]=PSM1  [C/B]=Cmd/Bat  [E]=Exe  ")
        $NavLabel.X           = 0
        $NavLabel.Y           = [Terminal.Gui.Pos]::AnchorEnd(1)
        $NavLabel.Width       = [Terminal.Gui.Dim]::Fill()
        $NavLabel.ColorScheme = $SchemeHeader
        $Win.Add($NavLabel)

        # Initial right-pane load (show last run output if available)
        if ($global:LastRunOutput) {
            $global:InfoFrame.Title = "  $($global:LastRunName) — OUTPUT  "
            $global:InfoView.Text   = "`n  $($global:LastRunName.ToUpper())`n  ══════════════════════════════`n`n$global:LastRunOutput"
            $global:InfoView.SetNeedsDisplay()
            $global:LastRunOutput = $null
        } else {
            & $global:BuildInfoPane -Index 0
        }

        [Terminal.Gui.Application]::Run()
        [Terminal.Gui.Application]::Shutdown()

        # ----------------------------------------------------------------
        # [5] EXECUTE SELECTED SCRIPT
        # ----------------------------------------------------------------
        if ($global:TargetExec) {
            Clear-Host
            $item        = $global:TargetExec
            $CacheBuster = [guid]::NewGuid().ToString()
            $transcriptFile = Join-Path $env:TEMP "toolkit_mc_$($CacheBuster.Replace('-','')).log"
            $ext = $item.Extension.ToLower()

            Write-Host ""
            Write-Host "  Launching : $($item.Name)" -ForegroundColor Cyan
            Write-Host "  Path      : /$($item.Path)/$($item.Name)" -ForegroundColor DarkGray
            Write-Host "  Type      : .$ext" -ForegroundColor DarkGray
            Write-Host ""

            try {
                if ($ext -in @('ps1','psm1')) {
                    $p = @{ Uri = $item.DownloadUrl; UseBasicParsing = $true; ErrorAction = "Stop" }
                    if ($AuthHeader) { $p.Headers = $AuthHeader }
                    $Code        = Invoke-RestMethod @p
                    $ScriptBlock = [scriptblock]::Create($Code)

                    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
                    Start-Transcript -Path $transcriptFile -Force | Out-Null
                    try {
                        . $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner -RepoName $TargetRepo -Branch $Branch -AppName $item.Name -ExecutionMode "interactive"
                    } finally {
                        try { Stop-Transcript | Out-Null } catch {}
                    }

                } elseif ($ext -in @('cmd','bat')) {
                    $p = @{ Uri = $item.DownloadUrl; UseBasicParsing = $true; ErrorAction = "Stop" }
                    if ($AuthHeader) { $p.Headers = $AuthHeader }
                    $Code    = Invoke-RestMethod @p
                    $tmpFile = Join-Path $env:TEMP "toolkit_mc_$CacheBuster.$ext"
                    Set-Content -Path $tmpFile -Value $Code -Encoding ASCII
                    try {
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tmpFile`"" -Wait -NoNewWindow
                    } finally {
                        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                    }

                } else {
                    Write-Host "  [!] Execution not supported for .$ext files." -ForegroundColor Yellow
                }

            } catch {
                try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
                $errMsg = "[!] Error launching $($item.Name): $($_.Exception.Message)"
                Write-Host "`n$errMsg" -ForegroundColor Red
            }

            # Parse transcript into right-pane content for next loop iteration
            $global:LastRunOutput = $null
            $global:LastRunName   = $item.Name
            if (Test-Path $transcriptFile) {
                try {
                    $rawLines = Get-Content $transcriptFile -Encoding UTF8
                    $startIdx = 0
                    for ($i = 0; $i -lt $rawLines.Count; $i++) {
                        if ($rawLines[$i] -match '^Transcript started') { $startIdx = $i + 1; break }
                    }
                    $endIdx = $rawLines.Count
                    for ($i = $rawLines.Count - 1; $i -ge 0; $i--) {
                        if ($rawLines[$i] -match '^\*{4,}') { $endIdx = $i; break }
                    }
                    if ($endIdx -gt $startIdx) {
                        $bodyLines = $rawLines[$startIdx..($endIdx - 1)]
                        $cleaned   = $bodyLines | ForEach-Object { $_ -replace '\x1B\[[0-9;]*[mGKHFABCDsuJnphfABCDR]', '' }
                        $global:LastRunOutput = ($cleaned -join "`n").Trim()
                    }
                } catch { }
                Remove-Item $transcriptFile -Force -ErrorAction SilentlyContinue
            }

            Write-Host "`n─────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host "  Press [Enter] to return to the navigator..." -ForegroundColor Gray
            Read-Host | Out-Null

            $global:TargetExec = $null
        }
    }

} catch {
    Write-Host "`n[!] Toolkit MC crash: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Write-Host "`n[+] Toolkit MC terminated. Returning to prompt." -ForegroundColor Green
