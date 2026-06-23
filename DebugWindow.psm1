$Global:DebugSync = [hashtable]::Synchronized(@{
    Queue              = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Running            = $false
    PowerShellInstance = $null
})

function Start-DebugWindow {
    if ($Global:DebugSync.Running) { Write-Warning "Debug window already running."; return }
    $Global:DebugSync.Running = $true

    $UiScript = {
        Param($sync)
        Add-Type -AssemblyName PresentationFramework, WindowsBase, System.Drawing

        [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2000/xaml/presentation"
        Title="Toolkit Live Debug Console" Height="550" Width="820" Topmost="True">
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

        $masterLog           = [System.Collections.Generic.List[string]]::new()
        $script:ActiveFilter = ""

        $UpdateDisplay = {
            if ([string]::IsNullOrWhiteSpace($script:ActiveFilter)) {
                $txtLogs.Text = [string]::Join("`r`n", $masterLog)
            } else {
                $filtered = $masterLog | Where-Object { $_ -like "*$script:ActiveFilter*" }
                $txtLogs.Text = [string]::Join("`r`n", $filtered)
            }
            $txtLogs.ScrollToEnd()
        }

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $timer.Add_Tick({
            $msg = $null; $dirty = $false
            while ($sync.Queue.TryDequeue([ref]$msg)) { $masterLog.Add($msg); $dirty = $true }
            if ($dirty) { $UpdateDisplay.Invoke() }
        })
        $timer.Start()

        $btnFilter.Add_Click({      $script:ActiveFilter = $txtSearch.Text; $UpdateDisplay.Invoke() })
        $btnClearFilter.Add_Click({ $txtSearch.Text = ""; $script:ActiveFilter = ""; $UpdateDisplay.Invoke() })
        $btnClear.Add_Click({       $masterLog.Clear(); $txtLogs.Clear() })

        $btnSave.Add_Click({
            $sfd = New-Object Microsoft.Win32.SaveFileDialog
            $sfd.Filter   = "Log Files (*.log)|*.log|Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
            $sfd.FileName = "ToolkitDebug_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            if ($sfd.ShowDialog() -eq $true) {
                try {
                    [System.IO.File]::WriteAllLines($sfd.FileName, $masterLog.ToArray())
                    [System.Windows.MessageBox]::Show("Saved:`n$($sfd.FileName)", "Saved", "OK", "Information")
                } catch {
                    [System.Windows.MessageBox]::Show("Save failed:`n$($_.Exception.Message)", "Error", "OK", "Error")
                }
            }
        })

        $window.Add_Closed({ $timer.Stop(); $sync.Running = $false })
        $window.ShowDialog() | Out-Null
    }

    $Global:DebugSync.PowerShellInstance = [PowerShell]::Create()
    $null = $Global:DebugSync.PowerShellInstance.AddScript($UiScript).AddArgument($Global:DebugSync)
    $null = $Global:DebugSync.PowerShellInstance.BeginInvoke()
    Write-Host "[+] Debug window launched (WPF background runspace)." -ForegroundColor Green
}

function Write-DebugWindow {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DEBUG")][string]$Level = "INFO"
    )
    if (-not $Global:DebugSync.Running) {
        Write-Host "[$Level] $Message" -ForegroundColor Gray
        return
    }
    $ts = Get-Date -Format "HH:mm:ss.fff"
    $Global:DebugSync.Queue.Enqueue("[$ts] [$($Level.PadRight(5))] $Message")
}

function Stop-DebugWindow {
    if ($Global:DebugSync.PowerShellInstance) {
        $Global:DebugSync.PowerShellInstance.Dispose()
        $Global:DebugSync.PowerShellInstance = $null
    }
    $Global:DebugSync.Running = $false
    Write-Host "Debug window torn down." -ForegroundColor Yellow
}

Export-ModuleMember -Function Start-DebugWindow, Write-DebugWindow, Stop-DebugWindow
