# ==============================================================================
# PowerShell Live Asynchronous Debug Window Module
# ==============================================================================

# Global thread-safe synchronization state
$Global:DebugSync = [hashtable]::Synchronized(@{
    Queue   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Running = $false
    PowerShellInstance = $null
})

function Start-DebugWindow {
    <#
    .SYNOPSIS
        Launches the separate, asynchronous WPF Debug Window.
    #>
    if ($Global:DebugSync.Running) {
        Write-Warning "Debug window is already running."
        return
    }

    $Global:DebugSync.Running = $true

    # Code block that runs inside the separate UI thread
    $UiScript = {
        Param($sync)

        Add-Type -AssemblyName PresentationFramework, WindowsBase, System.Drawing

        # XAML Layout for the GUI Window
        [xml]$xaml = @"
        <Window xmlns="http://schemas.microsoft.com/winfx/2000/xaml/presentation"
                Title="PowerShell Live Debug Console" Height="550" Width="750" Topmost="True">
            <Grid Background="#F4F4F5">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <ToolBar Grid.Row="0" Background="#E4E4E7" ToolBarTray.IsLocked="True">
                    <Label Content="Filter Logs:" VerticalAlignment="Center" FontWeight="Bold" Margin="5,0"/>
                    <TextBox Name="txtSearch" Width="250" VerticalAlignment="Center" Margin="5,2" Padding="3"/>
                    <Button Name="btnFilter" Content=" Apply Filter " Margin="5,2" Padding="5,2" Background="#0EA5E9" Foreground="White" BorderThickness="0"/>
                    <Button Name="btnClearFilter" Content=" Reset " Margin="2" Padding="5,2"/>
                </ToolBar>

                <TextBox Name="txtLogs" Grid.Row="1" FontFamily="Consolas" FontSize="12"
                         AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                         IsReadOnly="True" Background="#18181B" Foreground="#A1A1AA" Padding="10"/>

                <StatusBar Grid.Row="2" Background="#E4E4E7">
                    <StatusBarItem HorizontalAlignment="Right">
                        <StackPanel Orientation="Horizontal">
                            <Button Name="btnClear" Content="Clear Screen" Width="100" Margin="2" Padding="3"/>
                            <Button Name="btnSave" Content="Save Logs As..." Width="110" Margin="5,2" Padding="3" Background="#22C55E" Foreground="White" BorderThickness="0"/>
                        </StackPanel>
                    </StatusBarItem>
                </StatusBar>
            </Grid>
        </Window>
"@

        # Load the window
        $reader = New-Object System.Xml.XmlNodeReader $xaml
        $window = [Windows.Markup.XamlReader]::Load($reader)

        # Connect to GUI elements
        $txtSearch       = $window.FindName("txtSearch")
        $btnFilter       = $window.FindName("btnFilter")
        $btnClearFilter  = $window.FindName("btnClearFilter")
        $txtLogs         = $window.FindName("txtLogs")
        $btnSave         = $window.FindName("btnSave")
        $btnClear        = $window.FindName("btnClear")

        # Internal storage array keeping track of logs for filtering/saving
        $masterLogList = [System.Collections.Generic.List[string]]::new()
        $script:ActiveFilter = ""

        # Update function to handle filtering logic cleanly
        $UpdateDisplay = {
            if ([string]::IsNullOrWhiteSpace($script:ActiveFilter)) {
                $txtLogs.Text = [string]::Join("`r`n", $masterLogList)
            } else {
                $filtered = $masterLogList | Where-Object { $_ -like "*$script:ActiveFilter*" }
                $txtLogs.Text = [string]::Join("`r`n", $filtered)
            }
            $txtLogs.ScrollToEnd()
        }

        # WPF Dispatcher Timer to safely pull data from the background queue every 100ms
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $timer.Add_Tick({
            $incomingMsg = $null
            $hasNewData = $false
            while ($sync.Queue.TryDequeue([ref]$incomingMsg)) {
                $masterLogList.Add($incomingMsg)
                $hasNewData = $true
            }
            if ($hasNewData) {
                $UpdateDisplay.Invoke()
            }
        })
        $timer.Start()

        # Event: Apply Filter Click
        $btnFilter.Add_Click({
            $script:ActiveFilter = $txtSearch.Text
            $UpdateDisplay.Invoke()
        })

        # Event: Reset Filter Click
        $btnClearFilter.Add_Click({
            $txtSearch.Text = ""
            $script:ActiveFilter = ""
            $UpdateDisplay.Invoke()
        })

        # Event: Clear Display Log
        $btnClear.Add_Click({
            $masterLogList.Clear()
            $txtLogs.Clear()
        })

        # Event: Native Windows Save Dialog
        $btnSave.Add_Click({
            $sfd = New-Object Microsoft.Win32.SaveFileDialog
            $sfd.Filter = "Log Files (*.log)|*.log|Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
            $sfd.Title = "Export Debug Logs"
            $sfd.FileName = "Debug_Export_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

            if ($sfd.ShowDialog() -eq $true) {
                try {
                    [System.IO.File]::WriteAllLines($sfd.FileName, $masterLogList.ToArray())
                    [System.Windows.MessageBox]::Show("Logs successfully saved to:`n$($sfd.FileName)", "Success", "OK", "Information")
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to save file:`n$($_.Exception.Message)", "Error", "OK", "Error")
                }
            }
        })

        # Event: Cleanup when window is closed
        $window.Add_Closed({
            $timer.Stop()
            $sync.Running = $false
        })

        # Open window
        $window.ShowDialog() | Out-Null
    }

    # WPF requires STA threading — PowerShell 7 defaults to MTA, so create an explicit STA runspace
    $sta = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $sta.ApartmentState = [System.Threading.ApartmentState]::STA
    $sta.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $sta.Open()

    $Global:DebugSync.PowerShellInstance = [PowerShell]::Create()
    $Global:DebugSync.PowerShellInstance.Runspace = $sta
    $null = $Global:DebugSync.PowerShellInstance.AddScript($UiScript).AddArgument($Global:DebugSync)
    $null = $Global:DebugSync.PowerShellInstance.BeginInvoke()

    Write-Host "Debug window launched (STA/WPF background runspace)." -ForegroundColor Green
}

function Write-DebugWindow {
    <#
    .SYNOPSIS
        Sends a message string to the external tracking window.
    #>
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )

    if (-not $Global:DebugSync.Running) {
        # Fallback to standard console output if debug window isn't active
        Write-Host "[Background Window Closed] [$Level] $Message" -ForegroundColor Gray
        return
    }

    # Format the message nicely with a timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $formattedMessage = "[$timestamp] [$($Level.PadRight(5))] $Message"

    # Enqueue the data for the UI thread to harvest
    $Global:DebugSync.Queue.Enqueue($formattedMessage)
}

function Stop-DebugWindow {
    <#
    .SYNOPSIS
        Forcefully disposes and shuts down the background debugging instance.
    #>
    if ($Global:DebugSync.PowerShellInstance -ne $null) {
        $rs = $Global:DebugSync.PowerShellInstance.Runspace
        $Global:DebugSync.PowerShellInstance.Dispose()
        if ($rs) { try { $rs.Dispose() } catch {} }
        $Global:DebugSync.PowerShellInstance = $null
    }
    $Global:DebugSync.Running = $false
    Write-Host "Debug environment torn down." -ForegroundColor Yellow
}


Export-ModuleMember -Function Start-DebugWindow, Write-DebugWindow, Stop-DebugWindow

