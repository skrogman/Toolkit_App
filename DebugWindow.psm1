$Global:DebugSync = [hashtable]::Synchronized(@{
    LogFile = $null
    Running = $false
    WpfProc = $null
})

function Start-DebugWindow {
    param([int]$X = -1, [int]$Y = -1)
    $sharedDir = Join-Path $env:ProgramData "CassenaCareToolkit"
    if (-not (Test-Path $sharedDir)) { $null = New-Item -Path $sharedDir -ItemType Directory -Force -ErrorAction SilentlyContinue }
    $logFile  = Join-Path $sharedDir "toolkit_debug_active.log"
    $pidFile  = Join-Path $sharedDir "toolkit_debug_active.pid"
    $uiScript = Join-Path $env:TEMP  "toolkit_debug_ui.ps1"

    # Check if an existing window process is still alive (survives elevation relaunch)
    if (Test-Path $pidFile) {
        $savedPid = [int](Get-Content $pidFile -Raw).Trim()
        $existing = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
        if ($existing -and -not $existing.HasExited) {
            $Global:DebugSync.LogFile = $logFile
            $Global:DebugSync.WpfProc = $existing
            $Global:DebugSync.Running = $true
            Write-Host "Reconnected to existing debug console (PID $savedPid)." -ForegroundColor Green
            return
        }
    }

    # Fresh launch — clear log file and write the WPF UI script
    [System.IO.File]::WriteAllText($logFile, "", [System.Text.Encoding]::UTF8)

    $wpfCode = @'
param([string]$LogFile, [int]$X = -1, [int]$Y = -1)
Add-Type -AssemblyName PresentationFramework, WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Toolkit Live Debug Console" Height="550" Width="820">
    <Grid Background="#F4F4F5">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <ToolBar Grid.Row="0" Background="#E4E4E7" ToolBarTray.IsLocked="True">
            <Label Content="Filter:" VerticalAlignment="Center" FontWeight="Bold" Margin="5,0"/>
            <TextBox Name="txtSearch" Width="260" VerticalAlignment="Center" Margin="5,2" Padding="3"/>
            <Button Name="btnFilter" Content=" Apply " Margin="5,2" Padding="5,2" Background="#0EA5E9" Foreground="White" BorderThickness="0"/>
            <Button Name="btnClearFilter" Content=" Reset " Margin="2" Padding="5,2"/>
        </ToolBar>
        <TextBox Name="txtLogs" Grid.Row="1" FontFamily="Consolas" FontSize="12"
                 AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 IsReadOnly="True" Background="#18181B" Foreground="#A1A1AA" Padding="10"/>
        <StatusBar Grid.Row="2" Background="#E4E4E7">
            <StatusBarItem HorizontalAlignment="Right">
                <StackPanel Orientation="Horizontal">
                    <Button Name="btnClear" Content="Clear"    Width="80"  Margin="2"   Padding="3"/>
                    <Button Name="btnSave"  Content="Save As..." Width="100" Margin="5,2" Padding="3" Background="#22C55E" Foreground="White" BorderThickness="0"/>
                </StackPanel>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtSearch      = $window.FindName("txtSearch")
$btnFilter      = $window.FindName("btnFilter")
$btnClearFilter = $window.FindName("btnClearFilter")
$txtLogs        = $window.FindName("txtLogs")
$btnSave        = $window.FindName("btnSave")
$btnClear       = $window.FindName("btnClear")

$allLines            = [System.Collections.Generic.List[string]]::new()
$script:ActiveFilter = ""
$script:LastPos      = 0L

$UpdateDisplay = {
    if ([string]::IsNullOrWhiteSpace($script:ActiveFilter)) {
        $txtLogs.Text = [string]::Join("`r`n", $allLines)
    } else {
        $filtered = $allLines | Where-Object { $_ -like "*$script:ActiveFilter*" }
        $txtLogs.Text = [string]::Join("`r`n", $filtered)
    }
    $txtLogs.ScrollToEnd()
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    try {
        $fs = [System.IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
        if ($fs.Length -gt $script:LastPos) {
            $fs.Seek($script:LastPos, 'Begin') | Out-Null
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            $script:LastPos = $fs.Position
            $sr.Dispose()
            $newLines = $chunk -split "`r?`n" | Where-Object { $_ -ne "" }
            foreach ($l in $newLines) { $allLines.Add($l) }
            if ($newLines.Count -gt 0) { $UpdateDisplay.Invoke() }
        }
        $fs.Dispose()
    } catch {}
})
$timer.Start()

$btnFilter.Add_Click({     $script:ActiveFilter = $txtSearch.Text; $UpdateDisplay.Invoke() })
$btnClearFilter.Add_Click({ $txtSearch.Text = ""; $script:ActiveFilter = ""; $UpdateDisplay.Invoke() })
$btnClear.Add_Click({      $allLines.Clear(); $txtLogs.Clear(); $script:LastPos = 0L })
$btnSave.Add_Click({
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = "Log Files (*.log)|*.log|Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $sfd.FileName = "toolkit_debug_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    if ($sfd.ShowDialog() -eq $true) {
        try   { [System.IO.File]::WriteAllLines($sfd.FileName, $allLines.ToArray()) }
        catch { [System.Windows.MessageBox]::Show($_.Exception.Message, "Save Error") }
    }
})
$window.Add_Closed({
    $timer.Stop()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
if ($X -ge 0 -and $Y -ge 0) {
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $window.Left = $X
    $window.Top  = $Y
}
$window.ShowActivated = $false
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
'@

    [System.IO.File]::WriteAllText($uiScript, $wpfCode, [System.Text.Encoding]::UTF8)

    $proc = Start-Process pwsh -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-Sta",
        "-File", $uiScript, $logFile, $X, $Y
    ) -WindowStyle Hidden -PassThru

    [System.IO.File]::WriteAllText($pidFile, "$($proc.Id)", [System.Text.Encoding]::UTF8)

    $Global:DebugSync.LogFile = $logFile
    $Global:DebugSync.WpfProc = $proc
    $Global:DebugSync.Running = $true

    Write-Host "Debug console launched (PID $($proc.Id))." -ForegroundColor Green
}

function Write-DebugWindow {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DEBUG")][string]$Level = "INFO"
    )
    $logFile = Join-Path $env:ProgramData "CassenaCareToolkit\toolkit_debug_active.log"
    $pidFile = Join-Path $env:ProgramData "CassenaCareToolkit\toolkit_debug_active.pid"
    $ts      = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line    = "[$ts] [$($Level.PadRight(5))] $Message"
    $wrote   = $false
    if ((Test-Path $logFile) -and (Test-Path $pidFile)) {
        $dpid = try { [int](Get-Content $pidFile -Raw).Trim() } catch { -1 }
        if ($dpid -gt 0) {
            $proc = Get-Process -Id $dpid -EA SilentlyContinue
            if ($proc -and -not $proc.HasExited) {
                try { [System.IO.File]::AppendAllText($logFile, "$line`r`n", [System.Text.Encoding]::UTF8); $wrote = $true } catch {}
            }
        }
    }
    if (-not $wrote) { Write-Host $line -ForegroundColor DarkGray }
}

function Stop-DebugWindow {
    if ($Global:DebugSync.WpfProc -and -not $Global:DebugSync.WpfProc.HasExited) {
        try { $Global:DebugSync.WpfProc.CloseMainWindow() | Out-Null } catch {}
    }
    $Global:DebugSync.Running = $false
    Write-Host "Debug console stopped." -ForegroundColor Yellow
}

Export-ModuleMember -Function Start-DebugWindow, Write-DebugWindow, Stop-DebugWindow
