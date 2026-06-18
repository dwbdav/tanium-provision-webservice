<#
End-of-provisioning summary UI (PowerShell 5.1 / WPF)
- Always fullscreen
- Stable layout on different resolutions
- Auto-close after 30s when no ERROR
- WARN lines are ignored by this final UI
#>

$ErrorActionPreference = 'Stop'

function Start-InStaIfNeeded {
  if ([System.Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') { return $true }
  if (-not $PSCommandPath) { return $false }

  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    return $false
  } catch {
    return $true
  }
}

function Hide-CurrentConsole {
  try {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ | Out-Null

    $hWnd = [Win32.NativeMethods]::GetConsoleWindow()
    if ($hWnd -ne [IntPtr]::Zero) {
      [Win32.NativeMethods]::ShowWindow($hWnd, 0) | Out-Null
    }
  } catch {}
}

function Get-ErrorSummary {
  param(
    [Parameter(Mandatory = $true)][string]$LogPath,
    [int]$MaxLines = 300
  )

  $issues = @()
  $seen = @{}
  if (-not [string]::IsNullOrWhiteSpace($LogPath) -and (Test-Path -LiteralPath $LogPath)) {
    try {
      $lines = Get-Content -LiteralPath $LogPath -ErrorAction Stop
      $matched = @($lines | Where-Object { $_ -match '\[ERROR\]' })
      foreach ($line in $matched) {
        $cleanLine = [string]$line
        $cleanLine = $cleanLine -replace '^\[[^\]]+\]\s+', ''
        if (-not $seen.ContainsKey($cleanLine)) {
          $seen[$cleanLine] = $true
          $issues += $cleanLine
        }
      }
    }
    catch {
      $cleanLine = ("[ERROR] Unable to read log: {0}" -f $_.Exception.Message)
      if (-not $seen.ContainsKey($cleanLine)) {
        $seen[$cleanLine] = $true
        $issues += $cleanLine
      }
    }
  }

  $errorCount = $issues.Count
  if ($issues.Count -eq 0) {
    return [pscustomobject]@{
      ErrorCount = 0
      Details    = ''
    }
  }

  $total = $issues.Count
  if ($total -gt $MaxLines) {
    $issues = @($issues | Select-Object -Last $MaxLines)
    $details = ("Showing last {0}/{1} issue lines" -f $MaxLines, $total) + "`r`n" + ($issues -join "`r`n")
  } else {
    $details = ($issues -join "`r`n")
  }

  return [pscustomobject]@{
    ErrorCount = $errorCount
    Details    = $details
  }
}

function New-Brush {
  param([byte]$R, [byte]$G, [byte]$B)
  return New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb($R, $G, $B))
}

function Show-FallbackPopup {
  param(
    [Parameter(Mandatory = $true)][int]$ErrorCount
  )

  try {
    $hasError = $ErrorCount -gt 0

    $status = 'OK'
    $title = 'Provisioning - Summary (OK)'
    $icon = 0x40
    if ($hasError) {
      $status = 'ERROR'
      $title = 'Provisioning - Summary (Errors)'
      $icon = 0x10
    }

    $text = "Status: $status`r`nErrors: $ErrorCount"
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.Popup($text, 0, $title, $icon)
  } catch {}
}

if (-not (Start-InStaIfNeeded)) { return }
Hide-CurrentConsole

$logPath = 'C:\provision\provision.log'
$summary = Get-ErrorSummary -LogPath $logPath
$errorCount = [int]$summary.ErrorCount
$hasError = $errorCount -gt 0
$issueDetails = [string]$summary.Details

try {
  Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

  [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Provisioning - Summary"
        WindowStartupLocation="Manual"
        WindowStyle="None"
        ResizeMode="NoResize"
        ShowInTaskbar="False"
        Topmost="True"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True"
        Background="#0A1222">
  <Grid Margin="24">
    <Border Name="Root" Background="#FFFDF7" CornerRadius="12" Padding="28">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Name="Banner" Grid.Row="0" Padding="18" CornerRadius="10" Margin="0,0,0,18" Background="#EEEEEE">
          <StackPanel>
            <TextBlock Name="Hdr" FontFamily="Segoe UI Semibold" FontSize="42" FontWeight="Bold"/>
            <TextBlock Name="Sub" FontFamily="Segoe UI" FontSize="20" Margin="0,6,0,0"/>
          </StackPanel>
        </Border>

        <Grid Name="DetailsPanel" Grid.Row="1">
          <StackPanel>
            <TextBlock Text="Error details" FontFamily="Segoe UI Semibold" FontSize="26" Margin="0,2,0,8"/>
            <TextBox Name="IssueDetailsBox"
                     Height="320"
                     IsReadOnly="True"
                     TextWrapping="NoWrap"
                     AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Auto"
                     FontFamily="Consolas"
                     FontSize="16"
                     Padding="10"
                     BorderThickness="1"
                     Margin="0,0,0,10"/>

            <TextBlock Name="Msg" FontFamily="Segoe UI" FontSize="24" Margin="0,16,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="2" Margin="0,18,0,0">
          <Button Name="OkBtn"
                  Content="OK"
                  Width="280"
                  Height="76"
                  HorizontalAlignment="Center"
                  FontFamily="Segoe UI"
                  FontWeight="SemiBold"
                  FontSize="30"
                  IsDefault="True"/>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

  $reader = New-Object System.Xml.XmlNodeReader $xaml
  $window = [Windows.Markup.XamlReader]::Load($reader)

  $root = $window.FindName('Root')
  $banner = $window.FindName('Banner')
  $hdr = $window.FindName('Hdr')
  $sub = $window.FindName('Sub')
  $detailsPanel = $window.FindName('DetailsPanel')
  $issueDetailsBox = $window.FindName('IssueDetailsBox')
  $msg = $window.FindName('Msg')
  $okBtn = $window.FindName('OkBtn')

  $issueDetailsBox.Text = $issueDetails

  if ($hasError) {
    $root.Background = New-Brush 255 235 235
    $banner.Background = New-Brush 220 38 38
    $hdr.Text = 'Provisioning finished - ERROR'
    $hdr.Foreground = New-Brush 255 255 255
    $sub.Text = 'Please review the log before closing.'
    $sub.Foreground = New-Brush 255 255 255
    $issueDetailsBox.Background = New-Brush 255 244 244
    $issueDetailsBox.BorderBrush = New-Brush 220 38 38
    $msg.Text = ''
  } else {
    $detailsPanel.Visibility = 'Collapsed'
    $root.Background = New-Brush 232 255 236
    $banner.Background = New-Brush 22 163 74
    $hdr.Text = 'Provisioning finished - OK'
    $hdr.Foreground = New-Brush 255 255 255
    $sub.Text = 'Provisioning completed successfully.'
    $sub.Foreground = New-Brush 255 255 255
    $issueDetailsBox.Background = New-Brush 243 255 246
    $issueDetailsBox.BorderBrush = New-Brush 22 163 74
    $msg.Text = 'Auto-close in 30 seconds, or click OK now.'
  }

  $script:IsClosing = $false
  $script:CloseTimer = $null
  function Close-EndProvisionWindow {
    if ($script:IsClosing -and -not $window.IsVisible) { return }
    try {
      if ($script:CloseTimer) {
        $script:CloseTimer.Stop()
        $script:CloseTimer = $null
      }
    } catch {}
    try {
      if ($window.IsVisible) {
        try { $window.DialogResult = $true } catch {}
        if ($window.IsVisible) { $window.Close() }
      }
    } catch {}
    $script:IsClosing = -not $window.IsVisible
  }

  $window.WindowState = 'Maximized'
  $window.Topmost = $true
  $null = $window.Add_Loaded({ $okBtn.Focus() | Out-Null })
  $null = $window.Add_KeyDown({
    if ($_.Key -in 'Escape', 'Enter', 'Return') {
      Close-EndProvisionWindow
    }
  })
  $null = $window.Add_SourceInitialized({ [System.Media.SystemSounds]::Asterisk.Play() })
  $null = $okBtn.Add_Click({ Close-EndProvisionWindow })
  $null = $okBtn.Add_KeyDown({
    if ($_.Key -in 'Space', 'Enter', 'Return') {
      Close-EndProvisionWindow
    }
  })

  if (-not $hasError) {
    $script:Countdown = 30
    $okBtn.Content = "OK ($script:Countdown)"

    $script:CloseTimer = New-Object Windows.Threading.DispatcherTimer
    $script:CloseTimer.Interval = [TimeSpan]::FromSeconds(1)
    $null = $script:CloseTimer.Add_Tick({
      $script:Countdown--
      if ($script:Countdown -le 0) {
        $script:CloseTimer.Stop()
        $script:CloseTimer = $null
        Close-EndProvisionWindow
        return
      }
      $okBtn.Content = "OK ($script:Countdown)"
    })
    $script:CloseTimer.Start()
  }

  [void]$window.ShowDialog()
}
catch {
  if (-not $hasError) {
    return
  }
  Show-FallbackPopup -ErrorCount $errorCount
}
