# ==================================================================
# MASTER ORCHESTRATOR: TUI Module Enclave — MC Edition
# Repository: Toolkit_App / Entry-MC.ps1
# Midnight Commander navigation + full module metadata + lazy loading
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

$AllowedTags = if ($global:ToolkitAllowedTags -and $global:ToolkitAllowedTags.Count -gt 0) {
    @($global:ToolkitAllowedTags)
} else { $null }
if ($AllowedTags -and ($AllowedTags -contains "*")) { $AllowedTags = $null }
if ($global:ToolkitGodMode) { $AllowedTags = $null }

function Write-Log { param($Level,$Message)
    if (Get-Command Write-DebugWindow -EA SilentlyContinue) {
        $safeLevel = if ($Level -in @('INFO','WARN','ERROR','DEBUG')) { $Level } else { 'INFO' }
        Write-DebugWindow -Message "[$Level] $Message" -Level $safeLevel
    }
}

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
    # [2] API + CONTENT CACHE LAYER
    # ----------------------------------------------------------------
    $ApiBase             = "https://api.github.com/repos/$RepoOwner/$TargetRepo"
    $global:DirCache     = @{}  # path → raw API item array (GitHub dir listing)
    $global:ContentCache = @{}  # download_url → raw text content

    function Get-DirListing {
        param([string]$Path)
        if (-not $global:DirCache.ContainsKey($Path)) {
            $uri = if ($Path -eq "") { "$ApiBase/contents?ref=$Branch" }
                   else              { "$ApiBase/contents/$Path`?ref=$Branch" }
            try {
                $p = @{ Uri = $uri; ErrorAction = "Stop" }
                if ($AuthHeader) { $p.Headers = $AuthHeader }
                $global:DirCache[$Path] = @(Invoke-RestMethod @p)
            } catch { $global:DirCache[$Path] = @() }
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
            } catch { $global:ContentCache[$DownloadUrl] = $null }
        }
        return $global:ContentCache[$DownloadUrl]
    }

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
                if     ($t -match '^::\s*(.+)')    { $result.Add($Matches[1].Trim()); $started = $true }
                elseif ($t -match '^@?REM\s+(.+)') { $result.Add($Matches[1].Trim()); $started = $true }
                elseif ($started -and $t -ne '' -and $t -notmatch '^@?(?:echo|setlocal|pushd)') { break }
            }
            return ($result | Select-Object -First 6 | Where-Object { $_ }) -join '  |  '
        }
        return ""
    }

    function Format-Wrapped {
        param([string]$Text, [int]$Width = 40, [string]$Indent = "  ")
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
    # [3] LAZY LOAD — fetches Entry.ps1 and reads .TOOLKIT_CONFIG
    # ----------------------------------------------------------------
    function Invoke-LazyLoad {
        param([hashtable]$m)
        if ($m.Loaded -or -not $m.EntryUrl) { $m.Loaded = $true; return }
        try {
            $Raw = Get-FileContent $m.EntryUrl
            if (-not $Raw) { $m.Loaded = $true; return }

            if ($Raw -match '(?ms)<#.*?\.SYNOPSIS\s+(.*?)(?:\r?\n\s*\.[A-Z]|\r?\n\s*#>)') {
                $m.Synopsis = ($Matches[1] -replace '\r?\n',' ' -replace '\s+',' ').Trim()
            }
            if ($Raw -match '(?ms)\.TOOLKIT_CONFIG\s*(\{.*?\})\s*(?=#>|\.[A-Z])') {
                try {
                    $cfg = $Matches[1] | ConvertFrom-Json
                    if ($cfg.displayName)       { $m.DisplayName  = $cfg.displayName }
                    if ($cfg.description)       { $m.Synopsis     = $cfg.description }
                    if ($cfg.tags)              { $m.Tags         = @($cfg.tags) }
                    if ($cfg.dangerLevel)       { $m.DangerLevel  = $cfg.dangerLevel }
                    if ($cfg.category)          { $m.Category     = $cfg.category }
                    if ($cfg.version)           { $m.Version      = $cfg.version }
                    if ($cfg.author)            { $m.Author       = $cfg.author }
                    if ($cfg.estimatedRuntime)  { $m.EstRuntime   = $cfg.estimatedRuntime }
                    if ($cfg.outputType)        { $m.OutputType   = $cfg.outputType }
                    if ($cfg.modes)             { $m.Modes        = @($cfg.modes) }
                    if ($cfg.defaultMode)       { $m.DefaultMode  = $cfg.defaultMode }
                    if ($null -ne $cfg.disabled){ $m.Disabled     = [bool]$cfg.disabled }
                    if ($cfg.requiredElevation -and $cfg.requiredElevation -ne 'none') {
                        $m.RequiredElev = $cfg.requiredElevation
                        $m.ElevLocked   = (-not $IsElevated)
                    }
                } catch { }
            }
        } catch { }
        $m.Loaded = $true
    }

    # ----------------------------------------------------------------
    # [4] MODULE DISCOVERY (directory listings only, no content fetches)
    # ----------------------------------------------------------------
    Write-Log "INFO" "Auth: $(if ($AuthHeader) { 'Active' } else { 'None' })"
    Write-Log "INFO" "Querying GitHub API — $RepoOwner/$TargetRepo @ $Branch..."

    $global:Modules = [System.Collections.Generic.List[hashtable]]::new()

    try {
        $RootParams = @{ Uri = "$ApiBase/contents?ref=$Branch"; ErrorAction = "Stop" }
        if ($AuthHeader) { $RootParams.Headers = $AuthHeader }
        $global:DirCache[""] = @(Invoke-RestMethod @RootParams)

        $Dirs = @($global:DirCache[""] |
                  Where-Object { $_.type -eq 'dir' -and $_.name -notmatch '^\.' } |
                  Sort-Object name)

        foreach ($Dir in $Dirs) {
            Write-Log "INFO" "  Inventorying: $($Dir.name)"
            $Scripts          = [System.Collections.Generic.List[hashtable]]::new()
            $HasEntryPoint    = $false
            $EntryDownloadUrl = $null

            try {
                $listing = Get-DirListing $Dir.name
                $Ps1Files = @($listing | Where-Object { $_.type -eq 'file' -and $_.name -like '*.ps1' } | Sort-Object name)
                $EntryFile = $Ps1Files | Where-Object { $_.name -eq 'Entry.ps1' } | Select-Object -First 1

                if ($EntryFile) {
                    $HasEntryPoint    = $true
                    $EntryDownloadUrl = $EntryFile.download_url
                }
                foreach ($f in ($Ps1Files | Where-Object { $_.name -ne 'Entry.ps1' })) {
                    $Scripts.Add(@{ Name = ($f.name -replace '\.ps1$',''); Desc = ""; DownloadUrl = $f.download_url })
                }
            } catch {
                Write-Log "WARN" "    Could not inventory $($Dir.name): $($_.Exception.Message)"
            }

            $global:Modules.Add(@{
                Name          = $Dir.name
                DisplayName   = $Dir.name
                Synopsis      = if ($HasEntryPoint) { "(hover to load)" } else { "$($Scripts.Count) script(s)" }
                Scripts       = $Scripts
                Tags          = @("basic-access")
                Disabled      = $false
                RequiredElev  = $null
                ElevLocked    = $false
                DangerLevel   = $null
                Category      = $null
                Version       = $null
                EstRuntime    = $null
                OutputType    = $null
                Author        = $null
                Modes         = @("interactive")
                DefaultMode   = "interactive"
                HasEntryPoint = $HasEntryPoint
                IsFolder      = (-not $HasEntryPoint)
                EntryUrl      = $EntryDownloadUrl
                Loaded        = $false
            })
        }
    } catch {
        $apiErr = $_.Exception.Message
        Write-Log "ERROR" "GitHub API error: $apiErr"
        Write-Host "`n[!] Module discovery failed: $apiErr" -ForegroundColor Red
        Write-Host "    Repo  : $RepoOwner/$TargetRepo @ $Branch" -ForegroundColor DarkGray
        Write-Host "    Auth  : $(if ($AuthHeader) { 'token present' } else { 'NO AUTH HEADER' })" -ForegroundColor DarkGray
        if ($apiErr -match '404')          { Write-Host "`n    >> PAT needs Contents=Read scope on $TargetRepo.`n" -ForegroundColor Yellow }
        elseif ($apiErr -match '401|Unauthorized') { Write-Host "`n    >> PAT is invalid or revoked.`n" -ForegroundColor Yellow }
        Start-Sleep -Seconds 5
    }

    # Remove disabled modules
    $global:Modules = [System.Collections.Generic.List[hashtable]](
        $global:Modules | Where-Object { -not $_.Disabled }
    )

    # Tag-based access control
    if ($null -ne $AllowedTags) {
        $global:Modules = [System.Collections.Generic.List[hashtable]](
            $global:Modules | Where-Object {
                $modTags = $_.Tags
                $AllowedTags | Where-Object {
                    $pat = $_; $modTags | Where-Object { $_ -like $pat } | Select-Object -First 1
                } | Select-Object -First 1
            }
        )
        Write-Log "INFO" "Tag filter applied: $($AllowedTags -join ', ') — $($global:Modules.Count) module(s) visible"
    }

    if ($global:Modules.Count -eq 0) {
        Write-Host "`n[!] No modules loaded." -ForegroundColor Yellow
        Write-Host "    Check PAT scope and repo name. Auth: $(if ($AuthHeader) { 'present' } else { 'NONE' })`n" -ForegroundColor DarkGray
        Start-Sleep -Seconds 4
    }

    # ----------------------------------------------------------------
    # [5] NAVIGATION STATE
    # ----------------------------------------------------------------
    $global:ExitMaster      = $false
    $global:TargetModule    = $null          # module name → execute Entry.ps1
    $global:TargetModeModes = @("interactive")
    $global:TargetModeDefault = "interactive"
    $global:TargetExec      = $null          # file item hashtable → execute specific file
    $global:NavDepth        = 0              # 0=root module list, 1=inside a folder module
    $global:NavFolder       = $null          # the IsFolder module we drilled into
    $global:NavItems        = [System.Collections.Generic.List[hashtable]]::new()  # depth-1 file items
    $global:SelectedIndex   = 0
    $global:LastModuleRun   = $null
    $global:LastModuleOutput = $null

    function Build-NavItemsForFolder {
        param([hashtable]$FolderMod)
        $items    = [System.Collections.Generic.List[hashtable]]::new()
        $children = Get-DirListing $FolderMod.Name
        $files    = @($children | Where-Object { $_.type -eq 'file' } | Sort-Object name)
        $entryF   = $files | Where-Object { $_.name -eq 'Entry.ps1' } | Select-Object -First 1
        $otherF   = @($files | Where-Object { $_.name -ne 'Entry.ps1' })

        if ($entryF) {
            $items.Add(@{ Type='entry'; Name='Entry.ps1'; Label="  [►] Entry.ps1";
                          DownloadUrl=$entryF.download_url; Extension='ps1'; Size=$entryF.size; Path=$FolderMod.Name })
        }
        foreach ($f in $otherF) {
            $ext  = if ($f.name -match '\.([^.]+)$') { $Matches[1].ToLower() } else { '' }
            $icon = switch ($ext) {
                'ps1'  { '[S]' }; 'psm1' { '[M]' }; 'cmd' { '[C]' }; 'bat' { '[B]' }
                'exe'  { '[E]' }; 'msi'  { '[I]' }; default { '[?]' }
            }
            $isBin = $ext -in @('exe','msi','dll','bin')
            $items.Add(@{
                Type        = if ($isBin) { 'executable' } else { 'file' }
                Name        = $f.name
                Label       = "  $icon $($f.name)"
                DownloadUrl = $f.download_url
                Extension   = $ext
                Size        = $f.size
                Path        = $FolderMod.Name
            })
        }
        return $items
    }

    # ----------------------------------------------------------------
    # [6] TUI LOOP
    # ----------------------------------------------------------------
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
        $GodTag  = if ($global:ToolkitGodMode) { "  ★ GOD MODE ★  |" } else { "" }
        $AuthTag = if ($AuthHeader) { "Auth:Active" } else { "Auth:Anon" }
        $ElevTag = if ($IsElevated) { "  ★ ADMIN" } else { "" }
        $PathDisp = if ($global:NavDepth -eq 1 -and $global:NavFolder) { "/$($global:NavFolder.Name)" } else { "/[root]" }
        $global:HeaderLabel = New-Object Terminal.Gui.Label("$GodTag  CASSENA CARE TOOLKIT  |  $PathDisp  |  $AuthTag$ElevTag  |  Operator: $($env:USERNAME)  ")
        $global:HeaderLabel.X           = 0
        $global:HeaderLabel.Y           = 0
        $global:HeaderLabel.Width       = [Terminal.Gui.Dim]::Fill()
        $global:HeaderLabel.ColorScheme = $SchemeHeader
        $Win.Add($global:HeaderLabel)

        # ── Left pane ──────────────────────────────────────────────────
        $LeftTitle = if ($global:NavDepth -eq 1 -and $global:NavFolder) {
            "  $($global:NavFolder.DisplayName)/  "
        } else {
            "  MODULES  "
        }
        $ListFrame = New-Object Terminal.Gui.FrameView($LeftTitle)
        $ListFrame.X           = 0
        $ListFrame.Y           = 2
        $ListFrame.Width       = [Terminal.Gui.Dim]::Percent(36)
        $ListFrame.Height      = [Terminal.Gui.Dim]::Fill() - 1
        $ListFrame.ColorScheme = $SchemeApp
        $Win.Add($ListFrame)

        # Rebuild MenuLabels for current navigation state
        $global:MenuLabels = [System.Collections.ArrayList]@()
        if ($global:NavDepth -eq 1) {
            [void]$global:MenuLabels.Add("  [↑] ..")
            foreach ($ni in $global:NavItems) { [void]$global:MenuLabels.Add($ni.Label) }
        } else {
            foreach ($m in $global:Modules) {
                $prefix = if ($m.ElevLocked) { "  [ADMIN] " } elseif ($m.IsFolder) { "  [/] " } else { "  " }
                $suffix = if ($m.IsFolder) { "/" } else { "" }
                [void]$global:MenuLabels.Add("$prefix$($m.DisplayName)$suffix")
            }
            [void]$global:MenuLabels.Add("  ─── Exit Toolkit ───")
        }

        $ListView = New-Object Terminal.Gui.ListView
        [void]$ListView.SetSource($global:MenuLabels)
        $ListView.X           = 0
        $ListView.Y           = 0
        $ListView.Width       = [Terminal.Gui.Dim]::Fill()
        $ListView.Height      = [Terminal.Gui.Dim]::Fill()
        $ListView.ColorScheme = $SchemeApp
        $ListFrame.Add($ListView)

        # Restore selection position
        if ($global:SelectedIndex -lt $global:MenuLabels.Count) {
            $ListView.SelectedItem = $global:SelectedIndex
        }

        # ── Right pane ─────────────────────────────────────────────────
        $global:InfoFrame = New-Object Terminal.Gui.FrameView("  MODULE INFO  ")
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

        # ── Right pane content builder (lazy, handles both depth levels) ─
        $global:BuildInfoPane = {
            param($Index)

            # ── DEPTH 1: inside a folder module ─────────────────────────
            if ($global:NavDepth -eq 1) {
                if ($Index -eq 0) {
                    $t  = "`n  [↑] BACK TO MODULES`n"
                    $t += "  ══════════════════════════════`n`n"
                    $t += "  Return to: $RepoOwner/$TargetRepo`n`n"
                    $t += "  Press [Enter] to go back."
                } elseif ($Index -le $global:NavItems.Count) {
                    $item = $global:NavItems[$Index - 1]
                    if ($item.Type -eq 'executable') {
                        $t  = "`n  $($item.Name.ToUpper())`n"
                        $t += "  ══════════════════════════════`n`n"
                        $t += "  Executable / binary file`n"
                        $t += "`n  ── FILE INFO ───────────────────`n"
                        $t += "  Type  : .$($item.Extension)`n"
                        $t += "  Size  : $($item.Size) bytes`n"
                        $t += "  Path  : /$($item.Path)/$($item.Name)`n`n"
                        $t += "  [!] Executable launch support`n"
                        $t += "  not yet implemented."
                    } elseif ($item.Type -eq 'entry') {
                        $content = Get-FileContent $item.DownloadUrl
                        $desc    = Get-FileDescription $content 'ps1'
                        $t  = "`n  [►] ENTRY.PS1`n"
                        $t += "  ══════════════════════════════`n`n"
                        if ($desc) { $t += (Format-Wrapped $desc) + "`n" }
                        else       { $t += "  (no description found)`n" }
                        $t += "`n  ── LAUNCHER INFO ───────────────`n"
                        $t += "  Type  : PowerShell Script`n"
                        $t += "  Size  : $($item.Size) bytes`n"
                        $t += "  Path  : /$($item.Path)/Entry.ps1`n`n"
                        $t += "  Press [Enter] to execute."
                    } else {
                        $content = Get-FileContent $item.DownloadUrl
                        $desc    = Get-FileDescription $content $item.Extension
                        $t  = "`n  $($item.Name.ToUpper())`n"
                        $t += "  ══════════════════════════════`n`n"
                        if ($desc) { $t += (Format-Wrapped $desc) + "`n" }
                        else       { $t += "  (no description found)`n" }
                        $t += "`n  ── FILE INFO ───────────────────`n"
                        $t += "  Type  : .$($item.Extension)`n"
                        $t += "  Size  : $($item.Size) bytes`n"
                        $t += "  Path  : /$($item.Path)/$($item.Name)`n`n"
                        $t += "  Press [Enter] to execute."
                    }
                } else {
                    $t = "`n  (select an item)"
                }
                $global:InfoView.Text = $t
                $global:InfoView.SetNeedsDisplay()
                return
            }

            # ── DEPTH 0: root module list ────────────────────────────────
            if ($Index -ge $global:Modules.Count) {
                $t  = "`n  EXIT`n"
                $t += "  ══════════════════════════════`n`n"
                $t += "  Close the TUI and return`n"
                $t += "  to the terminal prompt.`n`n"
                $t += "  Press [Enter] to confirm."
            } else {
                $m = $global:Modules[$Index]

                if ($m.IsFolder) {
                    # Folder module — show directory contents preview
                    $children = Get-DirListing $m.Name
                    $nDirs    = @($children | Where-Object { $_.type -eq 'dir'  }).Count
                    $nFiles   = @($children | Where-Object { $_.type -eq 'file' }).Count
                    $t  = "`n  [/] $($m.DisplayName.ToUpper())/`n"
                    $t += "  ══════════════════════════════`n`n"
                    $t += "  Multi-file module — no single`n  entry point.`n"
                    $t += "  $nDirs folder(s)   $nFiles file(s)`n"
                    $t += "`n  ── CONTENTS ────────────────────`n"
                    $preview = @($children | Sort-Object { if ($_.type -eq 'dir') { 0 } else { 1 } }, name | Select-Object -First 20)
                    foreach ($c in $preview) {
                        $pfx = if ($c.type -eq 'dir') { '[/]' } else {
                            $cext = if ($c.name -match '\.([^.]+)$') { $Matches[1].ToLower() } else { '' }
                            switch ($cext) {
                                'ps1' { '[S]' }; 'psm1' { '[M]' }; 'cmd' { '[C]' }; 'bat' { '[B]' }
                                'exe' { '[E]' }; 'msi'  { '[I]' }; default { '[?]' }
                            }
                        }
                        $t += "  $pfx $($c.name)`n"
                    }
                    if ($children.Count -gt 20) { $t += "  ... ($($children.Count - 20) more)`n" }
                    $t += "`n  ──────────────────────────────`n"
                    $t += "  Vault  : $RepoOwner/$TargetRepo`n"
                    $t += "  Path   : /$($m.Name)/`n`n"
                    $t += "  Press [Enter] to browse."
                } else {
                    # Module with Entry.ps1 — full metadata display
                    $t  = "`n  $($m.DisplayName.ToUpper())`n"
                    $t += "  ══════════════════════════════`n`n"
                    $t += (Format-Wrapped $m.Synopsis) + "`n"

                    if ($m.ElevLocked) {
                        $t += "`n  ⚠ REQUIRES ADMINISTRATOR`n"
                        $t += "  This module cannot run in the`n"
                        $t += "  current session.`n"
                    }

                    $hasMeta = $m.Category -or $m.RequiredElev -or $m.DangerLevel -or $m.EstRuntime -or $m.OutputType -or $m.Version -or ($m.Modes -and $m.Modes.Count -gt 0)
                    if ($hasMeta) {
                        $t += "`n  ── MODULE DETAILS ─────────────`n"
                        if ($m.Category)     { $t += "  Category  : $($m.Category)`n" }
                        if ($m.RequiredElev) { $t += "  Elevation : $($m.RequiredElev)`n" }
                        if ($m.DangerLevel)  { $t += "  Risk      : $($m.DangerLevel)`n" }
                        if ($m.EstRuntime)   { $t += "  Runtime   : $($m.EstRuntime)`n" }
                        if ($m.OutputType)   { $t += "  Output    : $($m.OutputType)`n" }
                        if ($m.Modes)        { $t += "  Modes     : $($m.Modes -join ' / ')`n" }
                        if ($m.Version) {
                            $verLine = "  Version   : $($m.Version)"
                            if ($m.Author) { $verLine += "   by $($m.Author)" }
                            $t += "$verLine`n"
                        } elseif ($m.Author) {
                            $t += "  Author    : $($m.Author)`n"
                        }
                    }

                    $scriptCount = $m.Scripts.Count + 1
                    $t += "`n  ── SCRIPTS ($scriptCount file(s)) ─────────`n"
                    $t += "  [►] Entry.ps1`n"
                    foreach ($s in $m.Scripts) { $t += "  [S] $($s.Name).ps1`n" }

                    $t += "`n  ──────────────────────────────`n"
                    $t += "  Vault  : $RepoOwner/$TargetRepo`n"
                    $t += "  Path   : /$($m.Name)/Entry.ps1`n`n"
                    if ($m.ElevLocked) {
                        $t += "  [ADMIN] Cannot launch — elevation`n  required."
                    } elseif ($m.Modes.Count -gt 1) {
                        $t += "  Press [Enter] — prompted for mode."
                    } else {
                        $t += "  Press [Enter] to launch ($($m.DefaultMode) mode)."
                    }
                }
            }

            $global:InfoView.Text = $t
            $global:InfoView.SetNeedsDisplay()
        }

        # ── Selection handler: triggers lazy load and right-pane update ──
        $OnSelectionChanged = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e)
            $global:SelectedIndex = $e.Item

            # At root: lazy-load module metadata on first hover
            if ($global:NavDepth -eq 0 -and $e.Item -lt $global:Modules.Count) {
                $m = $global:Modules[$e.Item]
                if (-not $m.Loaded -and -not $m.IsFolder) {
                    Invoke-LazyLoad $m
                    $prefix = if ($m.ElevLocked) { "  [ADMIN] " } else { "  " }
                    $global:MenuLabels[$e.Item] = "$prefix$($m.DisplayName)"
                    $ListView.SetSource($global:MenuLabels)
                }
            }

            & $global:BuildInfoPane -Index $e.Item
        }
        [void]$ListView.add_SelectedItemChanged($OnSelectionChanged)

        # ── Open handler: navigate into folders or launch modules/files ──
        $OnItemOpened = [System.Action[Terminal.Gui.ListViewItemEventArgs]]{
            param($e)
            $idx = $e.Item

            # ── Inside a folder ────────────────────────────────────────
            if ($global:NavDepth -eq 1) {
                if ($idx -eq 0) {
                    # Navigate back to root
                    $global:NavDepth  = 0
                    $global:NavFolder = $null
                    $global:NavItems  = [System.Collections.Generic.List[hashtable]]::new()

                    $global:MenuLabels.Clear()
                    foreach ($m in $global:Modules) {
                        $prefix = if ($m.ElevLocked) { "  [ADMIN] " } elseif ($m.IsFolder) { "  [/] " } else { "  " }
                        $suffix = if ($m.IsFolder) { "/" } else { "" }
                        [void]$global:MenuLabels.Add("$prefix$($m.DisplayName)$suffix")
                    }
                    [void]$global:MenuLabels.Add("  ─── Exit Toolkit ───")
                    $ListView.SetSource($global:MenuLabels)
                    $ListFrame.Title = "  MODULES  "
                    $global:HeaderLabel.Text = "$GodTag  CASSENA CARE TOOLKIT  |  /[root]  |  $AuthTag$ElevTag  |  Operator: $($env:USERNAME)  "
                    $global:HeaderLabel.SetNeedsDisplay()
                    $ListView.SelectedItem = 0
                    $global:SelectedIndex = 0
                    & $global:BuildInfoPane -Index 0
                } elseif ($idx -le $global:NavItems.Count) {
                    $item = $global:NavItems[$idx - 1]
                    if ($item.Type -in @('entry','file')) {
                        $global:TargetExec = $item
                        [Terminal.Gui.Application]::RequestStop()
                    }
                    # 'executable' type: show info only (no launch)
                }
                return
            }

            # ── At root ────────────────────────────────────────────────
            if ($idx -ge $global:Modules.Count) {
                $global:ExitMaster = $true
                [Terminal.Gui.Application]::RequestStop()
                return
            }

            $mod = $global:Modules[$idx]
            if ($mod.ElevLocked) { & $global:BuildInfoPane -Index $idx; return }

            if ($mod.IsFolder) {
                # Drill into multi-file folder
                $global:NavItems  = Build-NavItemsForFolder $mod
                $global:NavDepth  = 1
                $global:NavFolder = $mod

                $global:MenuLabels.Clear()
                [void]$global:MenuLabels.Add("  [↑] ..")
                foreach ($ni in $global:NavItems) { [void]$global:MenuLabels.Add($ni.Label) }
                $ListView.SetSource($global:MenuLabels)
                $ListFrame.Title = "  $($mod.DisplayName)/  "
                $global:HeaderLabel.Text = "$GodTag  CASSENA CARE TOOLKIT  |  /$($mod.Name)  |  $AuthTag$ElevTag  |  Operator: $($env:USERNAME)  "
                $global:HeaderLabel.SetNeedsDisplay()
                $ListView.SelectedItem = 0
                $global:SelectedIndex = 0
                & $global:BuildInfoPane -Index 0
            } else {
                # Launch module with Entry.ps1
                $global:TargetModule      = $mod.Name
                $global:TargetModeModes   = $mod.Modes
                $global:TargetModeDefault = $mod.DefaultMode
                [Terminal.Gui.Application]::RequestStop()
            }
        }
        [void]$ListView.add_OpenSelectedItem($OnItemOpened)

        # ── Nav hint ────────────────────────────────────────────────────
        $hintDepth0 = "  ↑↓ Navigate   Enter: Launch/Open   [/]=Folder  [►]=Launcher  [S]=PS1  [M]=PSM1  [C/B]=Cmd/Bat  [E]=Exe  "
        $hintDepth1 = "  ↑↓ Navigate   Enter: Execute/Up   [↑]=Back to Modules   Vault: $RepoOwner/$TargetRepo [$Branch]  "
        $NavLabel   = New-Object Terminal.Gui.Label($(if ($global:NavDepth -eq 1) { $hintDepth1 } else { $hintDepth0 }))
        $NavLabel.X           = 0
        $NavLabel.Y           = [Terminal.Gui.Pos]::AnchorEnd(1)
        $NavLabel.Width       = [Terminal.Gui.Dim]::Fill()
        $NavLabel.ColorScheme = $SchemeHeader
        $Win.Add($NavLabel)

        # Initial right-pane load (show last run output if captured)
        if ($global:LastModuleOutput) {
            $runName = if ($global:LastModuleRun) { $global:LastModuleRun.ToUpper() } else { "LAST RUN" }
            $global:InfoFrame.Title   = "  $runName — OUTPUT  "
            $global:InfoView.Text     = "`n  $runName`n  ══════════════════════════════`n`n$global:LastModuleOutput"
            $global:InfoView.SetNeedsDisplay()
            $global:LastModuleOutput  = $null
        } else {
            & $global:BuildInfoPane -Index $global:SelectedIndex
        }

        [Terminal.Gui.Application]::Run()
        [Terminal.Gui.Application]::Shutdown()

        # ----------------------------------------------------------------
        # [7] EXECUTION — module Entry.ps1 (root-level launch)
        # ----------------------------------------------------------------
        if ($global:TargetModule) {
            Clear-Host

            $ExecMode = $global:TargetModeDefault
            if ($global:TargetModeModes -and $global:TargetModeModes.Count -gt 1) {
                $modePrompt = ($global:TargetModeModes | ForEach-Object { "[$($_.Substring(0,1).ToUpper())]$($_.Substring(1))" }) -join " / "
                $def    = $global:TargetModeDefault.Substring(0,1).ToUpper()
                $choice = (Read-Host "`n  Run mode: $modePrompt  [$def]").Trim().ToLower()
                if ($choice -eq 's' -or $choice -eq 'silent')       { $ExecMode = 'silent' }
                elseif ($choice -eq 'i' -or $choice -eq 'interactive') { $ExecMode = 'interactive' }
            }

            Write-Log "INFO" "Fetching module: $global:TargetModule (mode: $ExecMode)"
            $CacheBuster    = [guid]::NewGuid().ToString()
            $FetchUrl       = "https://raw.githubusercontent.com/$RepoOwner/$TargetRepo/$Branch/$($global:TargetModule)/Entry.ps1?t=$CacheBuster"
            $transcriptFile = Join-Path $env:TEMP "toolkit_run_$($CacheBuster.Replace('-','')).log"

            try {
                $p = @{ Uri = $FetchUrl; UseBasicParsing = $true; ErrorAction = "Stop" }
                if ($AuthHeader) { $p.Headers = $AuthHeader }
                $ModuleCode  = Invoke-RestMethod @p
                $ScriptBlock = [scriptblock]::Create($ModuleCode)

                try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
                Start-Transcript -Path $transcriptFile -Force | Out-Null
                try {
                    . $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner -RepoName $TargetRepo -Branch $Branch -AppName $global:TargetModule -ExecutionMode $ExecMode
                } finally {
                    try { Stop-Transcript | Out-Null } catch {}
                }
            } catch {
                try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
                $errMsg = "[!] CRASH in $($global:TargetModule): $($_.Exception.Message)"
                Write-Host "`n$errMsg" -ForegroundColor Red
                Write-Log "ERROR" $errMsg
            }

            $global:LastModuleRun    = $global:TargetModule
            $global:LastModuleOutput = $null
            $global:TargetModule     = $null
            $global:SelectedIndex    = 0
        }

        # ----------------------------------------------------------------
        # [8] EXECUTION — specific file inside a folder module
        # ----------------------------------------------------------------
        if ($global:TargetExec) {
            Clear-Host
            $item        = $global:TargetExec
            $CacheBuster = [guid]::NewGuid().ToString()
            $ext         = $item.Extension.ToLower()
            $transcriptFile = Join-Path $env:TEMP "toolkit_run_$($CacheBuster.Replace('-','')).log"

            Write-Host ""
            Write-Host "  Launching : $($item.Name)" -ForegroundColor Cyan
            Write-Host "  Path      : /$($item.Path)/$($item.Name)" -ForegroundColor DarkGray
            Write-Host ""

            try {
                $p = @{ Uri = $item.DownloadUrl; UseBasicParsing = $true; ErrorAction = "Stop" }
                if ($AuthHeader) { $p.Headers = $AuthHeader }
                $Code = Invoke-RestMethod @p

                if ($ext -in @('ps1','psm1')) {
                    $ScriptBlock = [scriptblock]::Create($Code)
                    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
                    Start-Transcript -Path $transcriptFile -Force | Out-Null
                    try {
                        . $ScriptBlock -AuthHeader $AuthHeader -RepoOwner $RepoOwner -RepoName $TargetRepo -Branch $Branch -AppName $item.Name -ExecutionMode "interactive"
                    } finally {
                        try { Stop-Transcript | Out-Null } catch {}
                    }
                } elseif ($ext -in @('cmd','bat')) {
                    $tmpFile = Join-Path $env:TEMP "toolkit_run_$CacheBuster.$ext"
                    Set-Content -Path $tmpFile -Value $Code -Encoding ASCII
                    try { Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tmpFile`"" -Wait -NoNewWindow }
                    finally { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
                } else {
                    Write-Host "  [!] Execution not supported for .$ext files." -ForegroundColor Yellow
                }
            } catch {
                try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
                Write-Host "`n[!] Error: $($_.Exception.Message)" -ForegroundColor Red
            }

            $global:LastModuleRun    = $item.Name
            $global:LastModuleOutput = $null
            $global:TargetExec       = $null
        }

        # Parse transcript into right-pane content for next iteration
        if (Test-Path $transcriptFile -ErrorAction SilentlyContinue) {
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
                    $global:LastModuleOutput = ($cleaned -join "`n").Trim()
                }
            } catch { }
            Remove-Item $transcriptFile -Force -ErrorAction SilentlyContinue
        }

        Write-Host "`n─────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Press [Enter] to return to the Toolkit..." -ForegroundColor Gray
        Read-Host | Out-Null
    }

} catch {
    Write-Host "`n[!] Master Enclave Crash: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}

Write-Host "`n[+] Toolkit terminated. Returning to prompt." -ForegroundColor Green
