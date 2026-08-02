# =========================
# CONFIG
# =========================
$Config = [ordered]@{
    WsBase                 = ''
    GetComputerEndpoint    = '/getcomputer'      # GET ?serial=<SERIAL>
    ListUsedEndpoint       = '/list_used'        # GET (types, countries, languages, timezones, keyboards)
    LocalLogPath           = 'X:\provision\provision.log'
    ConfigJson             = 'X:\provision\config.json'  # unique JSON file (read/write)
    RetryCount             = 10
    RetryDelay             = 3
    Timeout                = 20
	
	TaniumOSDModulePath    = 'C:\_T\TaniumOSD'
	TaniumClientModulePath = 'C:\_T\TaniumClient'
}
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $Config.LocalLogPath) -Force

# =========================
# Tanium modules
# =========================
if (Test-Path $Config.TaniumOSDModulePath) {
  try {
    Import-Module $Config.TaniumOSDModulePath -ErrorAction Stop
    if (Get-Command Set-OSDProgressDisplay -ErrorAction SilentlyContinue) {
      $osdAvailable = $true
    }
  } catch {}
}

# =========================
# Serial
# =========================
$script:Serial = $null
try { $script:Serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch {}
if (-not $script:Serial) {
    try { $script:Serial = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).IdentifyingNumber } catch {}
}
if (-not $script:Serial) {
    try { $script:Serial = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch {}
}
$script:Serial = if ($script:Serial) { $script:Serial.Trim().ToUpper() -replace '\s','' } else { 'UNKNOWN' }

# =========================
# WS base URL
# =========================
try {
    if (-not (Test-Path -LiteralPath $Config.ConfigJson)) { throw "Context JSON not found: $($Config.ConfigJson)" }
    $wsBase = ([string]((Get-Content -LiteralPath $Config.ConfigJson -Raw | ConvertFrom-Json -ErrorAction Stop).wsBase)).Trim()
    if ([string]::IsNullOrWhiteSpace($wsBase)) { throw "wsBase missing in context JSON: $($Config.ConfigJson)" }
    if (([uri]$wsBase).Scheme -notin @('http', 'https')) { throw "Invalid wsBase scheme: $wsBase" }
    $Config['WsBase'] = $wsBase.TrimEnd('/')
}
catch {
    $msg = "[ERROR] $($_.Exception.Message)"
    Write-Host $msg
    try { $msg | Out-File -FilePath $Config.LocalLogPath -Append -Encoding UTF8 } catch {}
    exit 1
}

# =========================
# API endpoints
# =========================
$script:GetComputerApi = "$($Config.WsBase)$($Config.GetComputerEndpoint)"
$script:ListUsedApi = "$($Config.WsBase)$($Config.ListUsedEndpoint)"
$script:CheckHardwareApi = "$($Config.WsBase)/checkhardware"
$script:ProgressBmpUrl = "$($Config.WsBase)/file/Provision/logo.bmp"
$script:ProgressBmpPath = 'C:\_T\TaniumOSD\logo.bmp'

# =========================
# STA
# =========================
try {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -and $PSCommandPath) {
        Start-Process -FilePath "$PSHOME\powershell.exe" `
          -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Sta','-File',"`"$PSCommandPath`"") `
          -WindowStyle Normal -Wait
        return
    }
} catch {}

# =========================
# HTTP
# =========================
function Invoke-RestWithRetry {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')] [string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body = $null,
        [string]$ContentType = 'application/json',
        [int]$Attempts = $Config.RetryCount,
        [int]$DelaySec = $Config.RetryDelay,
        [int]$TimeoutSec = $Config.Timeout
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if ($Method -eq 'GET') {
                return Invoke-RestMethod -Uri $Uri -Method GET -TimeoutSec $TimeoutSec
            } else {
                $payload = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Compress }
                return Invoke-RestMethod -Uri $Uri -Method POST -Body $payload -ContentType $ContentType -TimeoutSec $TimeoutSec
            }
        } catch {
            if ($i -ge $Attempts) { throw }
            Start-Sleep -Seconds $DelaySec
        }
    }
}

# =========================
# Logging
# =========================
function Write-Log {
  param(
    [Parameter(Mandatory)]
    [string]$Message,
    [switch]$LocalOnly
  )

  $full = "[$($script:Serial)] $Message"

  Write-Host $full

  try {
    $full | Out-File -FilePath $Config.LocalLogPath -Append -Encoding UTF8
  } catch {}

  if ($LocalOnly) { return }

  try {
    Invoke-RestMethod `
      -Uri "$($Config.WsBase)/message" `
      -Method POST `
      -Body (@{ message = $full } | ConvertTo-Json -Compress) `
      -ContentType 'application/json' `
      -TimeoutSec 10 | Out-Null
  } catch {}
}

# =========================
# Hardware compatibility
# =========================
function Convert-BytesToDecimalGb {
    param([Nullable[Int64]]$Bytes)

    if ($null -eq $Bytes -or $Bytes -le 0) {
        return ''
    }

    return [int][Math]::Floor(([double]$Bytes / 1000000000))
}

function Get-HardwareInventory {
    $model = ''
    $ramGb = ''
    $diskGb = ''
    $cpuCount = ''

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $model = ([string]$cs.Model).Trim()
        $ramGb = Convert-BytesToDecimalGb -Bytes ([Nullable[Int64]]$cs.TotalPhysicalMemory)
        if ($cs.NumberOfLogicalProcessors) {
            $cpuCount = [string][int]$cs.NumberOfLogicalProcessors
        }
    } catch {}

    try {
        $disk = Get-CimInstance Win32_DiskDrive -ErrorAction Stop |
            Where-Object { $_.Size -and $_.Size -gt 0 } |
            Sort-Object -Property Size -Descending |
            Select-Object -First 1

        if ($disk) {
            $diskGb = Convert-BytesToDecimalGb -Bytes ([Nullable[Int64]]$disk.Size)
        }
    } catch {}

    [pscustomobject]@{
        Model    = $model
        RamGb    = $ramGb
        DiskGb   = $diskGb
        CpuCount = $cpuCount
    }
}

function New-Brush {
    param([byte]$R, [byte]$G, [byte]$B)
    return New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb($R, $G, $B))
}

function Show-HardwareIncompatiblePopup {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$Model = '',
        [string]$RamGb = '',
        [string]$DiskGb = '',
        [string]$CpuCount = ''
    )

    try {
        Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

        [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Provisioning - Hardware warning"
        WindowStartupLocation="Manual"
        WindowStyle="None"
        ResizeMode="NoResize"
        ShowInTaskbar="False"
        Topmost="True"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True"
        Background="#0A1222">
  <Grid Margin="24">
    <Border Name="Root" Background="#FFEBEB" CornerRadius="12" Padding="28">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Name="Banner" Grid.Row="0" Padding="18" CornerRadius="10" Margin="0,0,0,18" Background="#DC2626">
          <StackPanel>
            <TextBlock Name="Hdr" Text="Hardware requirements not met" FontFamily="Segoe UI Semibold" FontSize="42" FontWeight="Bold" Foreground="White"/>
            <TextBlock Name="Sub" Text="Review the details below. Provisioning will continue after confirmation." FontFamily="Segoe UI" FontSize="20" Margin="0,6,0,0" Foreground="White"/>
          </StackPanel>
        </Border>

        <Grid Grid.Row="1">
          <StackPanel>
            <TextBlock Text="Compatibility details" FontFamily="Segoe UI Semibold" FontSize="26" Margin="0,2,0,8"/>
            <TextBox Name="IssueDetailsBox"
                     Height="320"
                     IsReadOnly="True"
                     TextWrapping="NoWrap"
                     AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto"
                     HorizontalScrollBarVisibility="Auto"
                     FontFamily="Consolas"
                     FontSize="18"
                     Padding="10"
                     BorderThickness="1"
                     Margin="0,0,0,10"/>
            <TextBlock Text="Click OK to continue the deployment." FontFamily="Segoe UI" FontSize="24" Margin="0,16,0,0" TextWrapping="Wrap"/>
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
        $details = $window.FindName('IssueDetailsBox')
        $okBtn = $window.FindName('OkBtn')

        $details.Background = New-Brush 255 244 244
        $details.BorderBrush = New-Brush 220 38 38
        $reasonLines = @([string]$Reason -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $detailLines = New-Object System.Collections.Generic.List[string]
        if ($reasonLines.Count -gt 0) {
            [void]$detailLines.Add(("Reason : {0}" -f $reasonLines[0]))
            if ($reasonLines.Count -gt 1) {
                [void]$detailLines.Add("")
                [void]$detailLines.Add("Details:")
                foreach ($line in @($reasonLines | Select-Object -Skip 1)) {
                    [void]$detailLines.Add((" - {0}" -f $line))
                }
            }
        }
        else {
            [void]$detailLines.Add("Reason : hardware incompatible")
        }
        [void]$detailLines.Add("")
        [void]$detailLines.Add(("Model  : {0}" -f $Model))
        [void]$detailLines.Add(("RAM    : {0} GB" -f $RamGb))
        [void]$detailLines.Add(("Disk   : {0} GB" -f $DiskGb))
        [void]$detailLines.Add(("CPU    : {0}" -f $CpuCount))
        $details.Text = $detailLines -join "`r`n"

        function Close-HardwareWindow {
            try {
                if ($window.IsVisible) {
                    try { $window.DialogResult = $true } catch {}
                    if ($window.IsVisible) { $window.Close() }
                }
            } catch {}
        }

        $window.WindowState = 'Maximized'
        $window.Topmost = $true
        $null = $window.Add_Loaded({ $okBtn.Focus() | Out-Null })
        $null = $window.Add_KeyDown({
            if ($_.Key -in 'Escape', 'Enter', 'Return') {
                Close-HardwareWindow
            }
        })
        $null = $window.Add_SourceInitialized({ [System.Media.SystemSounds]::Hand.Play() })
        $null = $okBtn.Add_Click({ Close-HardwareWindow })
        $null = $okBtn.Add_KeyDown({
            if ($_.Key -in 'Space', 'Enter', 'Return') {
                Close-HardwareWindow
            }
        })

        [void]$window.ShowDialog()
    }
    catch {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $null = $ws.Popup("Hardware requirements not met`r`n$Reason`r`nModel: $Model`r`n`r`nProvisioning will continue after confirmation.", 0, 'Provisioning warning', 0x30)
        } catch {}
    }
}

function Get-HardwareFailureDetails {
    param([object]$Result)

    $details = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Result -or $Result.PSObject.Properties.Name -notcontains 'failures') {
        return @()
    }

    foreach ($failure in @($Result.failures)) {
        if ($null -eq $failure -or $failure.PSObject.Properties.Name -notcontains 'failed') {
            continue
        }

        $failed = $failure.failed
        foreach ($name in @('ram_gb', 'disk_gb', 'cpu_count')) {
            if ($failed.PSObject.Properties.Name -notcontains $name) {
                continue
            }

            $item = $failed.$name
            if ($null -eq $item) {
                continue
            }

            $reasonText = if ($item.PSObject.Properties.Name -contains 'reason') { [string]$item.reason } else { $name }
            $actual = if ($item.PSObject.Properties.Name -contains 'actual' -and $null -ne $item.actual) { [string]$item.actual } else { 'missing' }
            $minimum = if ($item.PSObject.Properties.Name -contains 'minimum' -and $null -ne $item.minimum) { [string]$item.minimum } else { 'unknown' }

            switch ($name) {
                'ram_gb' {
                    [void]$details.Add(("RAM below minimum: actual={0} GB, required={1} GB" -f $actual, $minimum))
                }
                'disk_gb' {
                    [void]$details.Add(("Disk below minimum: actual={0} GB, required={1} GB" -f $actual, $minimum))
                }
                'cpu_count' {
                    [void]$details.Add(("CPU count below minimum: actual={0}, required={1}" -f $actual, $minimum))
                }
                default {
                    [void]$details.Add($reasonText)
                }
            }
        }
    }

    return @($details.ToArray() | Select-Object -Unique)
}

function Invoke-HardwareCompatibilityCheck {
    $hw = Get-HardwareInventory

    Write-Log ("[INFO] Hardware inventory: Model={0}; RAM={1}GB; Disk={2}GB; CPU={3}" -f `
        $hw.Model, $hw.RamGb, $hw.DiskGb, $hw.CpuCount)

    $query = @(
        "serial=$([System.Uri]::EscapeDataString($script:Serial))",
        "model=$([System.Uri]::EscapeDataString($hw.Model))",
        "ram_gb=$([System.Uri]::EscapeDataString([string]$hw.RamGb))",
        "disk_gb=$([System.Uri]::EscapeDataString([string]$hw.DiskGb))",
        "cpu_count=$([System.Uri]::EscapeDataString([string]$hw.CpuCount))"
    ) -join '&'

    $url = "$($script:CheckHardwareApi)?$query"

    try {
        $result = Invoke-RestWithRetry -Method 'GET' -Uri $url -TimeoutSec $Config.Timeout
    }
    catch {
        Write-Log ("[ERROR] Hardware compatibility check failed: {0}" -f $_.Exception.Message)
        exit 1
    }

    if ($null -eq $result -or $result.PSObject.Properties.Name -notcontains 'allowed') {
        Write-Log '[ERROR] Hardware compatibility check returned an invalid response'
        exit 1
    }

    if ([bool]$result.allowed) {
        $matched = ''
        if ($result.PSObject.Properties.Name -contains 'matched_model_regex') {
            $matched = [string]$result.matched_model_regex
        }
        Write-Log ("[OK] Hardware compatible: Model={0}; Matched={1}; RAM={2}GB; Disk={3}GB; CPU={4}" -f `
            $hw.Model, $matched, $hw.RamGb, $hw.DiskGb, $hw.CpuCount)
        return
    }

    $reason = 'hardware incompatible'
    if ($result.PSObject.Properties.Name -contains 'reason' -and $result.reason) {
        $reason = [string]$result.reason
    }
    $failureDetails = @(Get-HardwareFailureDetails -Result $result)
    $popupReason = $reason
    if ($failureDetails.Count -gt 0) {
        $popupReason = $reason + "`r`n" + ($failureDetails -join "`r`n")
    }

    Write-Log ("[WARN] Hardware requirements not met: {0}; Model={1}; RAM={2}GB; Disk={3}GB; CPU={4}" -f `
        $popupReason, $hw.Model, $hw.RamGb, $hw.DiskGb, $hw.CpuCount)
    Show-HardwareIncompatiblePopup -Reason $popupReason -Model $hw.Model -RamGb $hw.RamGb -DiskGb $hw.DiskGb -CpuCount $hw.CpuCount
    Write-Log '[INFO] Hardware warning acknowledged; provisioning continues'
    return
}

# =========================
# Progress image
# =========================
function Update-ProgressBitmap {
    $targetDir = Split-Path -Path $script:ProgressBmpPath -Parent
    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    $tempPath = "$($script:ProgressBmpPath).tmp"
    try {
        $client = New-Object System.Net.WebClient
        try {
            $client.Headers['User-Agent'] = 'Tanium-Web-service-Provision/1.0'
            $client.DownloadFile($script:ProgressBmpUrl, $tempPath)
        } finally {
            $client.Dispose()
        }

        if (-not (Test-Path -LiteralPath $tempPath) -or (Get-Item -LiteralPath $tempPath).Length -le 0) {
            throw "Downloaded file missing or empty: $tempPath"
        }

        Move-Item -LiteralPath $tempPath -Destination $script:ProgressBmpPath -Force
        Write-Log ("[OK] Progress image updated: {0}" -f $script:ProgressBmpPath) -LocalOnly
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Write-Log ("[WARN] Progress image update failed: {0}" -f $_.Exception.Message)
    }
}

# =========================
# Prefill from API
# =========================
function Get-PrefillFromApi {
    $pref = [pscustomobject]@{
        ComputerName = ''
        Type         = ''
        Keyboard     = ''
        Country      = ''
        Language     = ''
        Timezone     = ''
        _Complete    = $false
    }

    if (-not $script:Serial -or $script:Serial -eq 'UNKNOWN') {
        Write-Log '[WARN] Serial unknown -> WS prefill unavailable'
        return $pref
    }

    try {
        $serialParam = [System.Uri]::EscapeDataString($script:Serial)
        $r = Invoke-RestWithRetry -Method 'GET' -Uri "$($script:GetComputerApi)?serial=$serialParam" -TimeoutSec $Config.Timeout
        if ($r) {
            if ($r.PSObject.Properties.Name -contains 'computerName' -and $r.computerName) { $pref.ComputerName = [string]$r.computerName }

            $pt = $null
            if     ($r.PSObject.Properties.Name -contains 'type')    { $pt = $r.type }
            elseif ($r.PSObject.Properties.Name -contains 'postype') { $pt = $r.postype }
            elseif ($r.PSObject.Properties.Name -contains 'posType') { $pt = $r.posType }
            if ($pt) { $pref.Type = [string]$pt }

            if ($r.PSObject.Properties.Name -contains 'keyboard' -and $r.keyboard) { $pref.Keyboard = [string]$r.keyboard }
            if ($r.PSObject.Properties.Name -contains 'country'  -and $r.country)  { $pref.Country  = [string]$r.country  }
            if ($r.PSObject.Properties.Name -contains 'language' -and $r.language) { $pref.Language = [string]$r.language }
            if ($r.PSObject.Properties.Name -contains 'timezone' -and $r.timezone) { $pref.Timezone = [string]$r.timezone }

            $pref.ComputerName = $pref.ComputerName.Trim()
            $pref.Type         = $pref.Type.Trim()
            $pref.Keyboard     = $pref.Keyboard.Trim()
            $pref.Country      = $pref.Country.Trim().ToUpperInvariant()
            $pref.Language     = $pref.Language.Trim()
            $pref.Timezone     = $pref.Timezone.Trim()

            # Complete prefill: name, keyboard, and country are mandatory. Type remains optional.
            $pref._Complete = (
                -not [string]::IsNullOrWhiteSpace($pref.ComputerName) -and
                -not [string]::IsNullOrWhiteSpace($pref.Keyboard)     -and
                -not [string]::IsNullOrWhiteSpace($pref.Country)
            )

            if ($pref._Complete) {
                Write-Log ("[INFO] Prefill (WS COMPLETE): name='{0}', type='{1}', kbd='{2}', country='{3}', lang='{4}', tz='{5}'" -f `
                    $pref.ComputerName,$pref.Type,$pref.Keyboard,$pref.Country,$pref.Language,$pref.Timezone)
            } else {
                Write-Log ("[INFO] Prefill (WS PARTIAL) -> UI: name='{0}', type='{1}', kbd='{2}', country='{3}', lang='{4}', tz='{5}'" -f `
                    $pref.ComputerName,$pref.Type,$pref.Keyboard,$pref.Country,$pref.Language,$pref.Timezone)
            }
        } else {
            Write-Log '[INFO] WS response empty (no prefill data)'
        }
    } catch {
        Write-Log ("[WARN] Prefill API error: {0}" -f $_.Exception.Message)
    }

    return $pref
}

# =========================
# Used lists from API
# =========================
function Get-UsedLists {
    $url = "$($script:ListUsedApi)?lower=0"
    try {
        $raw = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ Accept='application/json' } -TimeoutSec $Config.Timeout
        $j   = $raw.Content | ConvertFrom-Json

        $t = New-Object System.Collections.Generic.List[string]
        $k = New-Object System.Collections.Generic.List[string]
        $c = New-Object System.Collections.Generic.List[string]
        $l = New-Object System.Collections.Generic.List[string]
        $tz = New-Object System.Collections.Generic.List[string]

        foreach ($x in @($j.types)) {
            if ($null -ne $x) {
                $u = ("$x").Trim().ToUpperInvariant()
                if ($u -ne '' -and -not $t.Contains($u)) { [void]$t.Add($u) }
            }
        }
        foreach ($x in @($j.keyboards)) {
            if ($null -ne $x) {
                $u = ("$x").Trim().ToUpperInvariant()
                if ($u -ne '' -and -not $k.Contains($u)) { [void]$k.Add($u) }
            }
        }
        foreach ($x in @($j.countries)) {
            if ($null -ne $x) {
                $u = ("$x").Trim().ToUpperInvariant()
                if ($u -ne '' -and -not $c.Contains($u)) { [void]$c.Add($u) }
            }
        }
        foreach ($x in @($j.languages)) {
            if ($null -ne $x) {
                $u = ("$x").Trim()
                if ($u -ne '' -and -not $l.Contains($u)) { [void]$l.Add($u) }
            }
        }
        foreach ($x in @($j.timezones)) {
            if ($null -ne $x) {
                $u = ("$x").Trim()
                if ($u -ne '' -and -not $tz.Contains($u)) { [void]$tz.Add($u) }
            }
        }

        $tArr = $t.ToArray()
        $kArr = $k.ToArray()
        $cArr = $c.ToArray()
        $lArr = $l.ToArray()
        $tzArr = $tz.ToArray()

        [System.Array]::Sort($tArr, [System.StringComparer]::Ordinal)
        [System.Array]::Sort($kArr, [System.StringComparer]::Ordinal)
        [System.Array]::Sort($cArr, [System.StringComparer]::Ordinal)
        [System.Array]::Sort($lArr, [System.StringComparer]::Ordinal)
        [System.Array]::Sort($tzArr, [System.StringComparer]::Ordinal)

        Write-Log ("[INFO] list_used: {0} type(s), {1} keyboard(s), {2} country(ies), {3} language(s), {4} timezone(s)" -f `
            $tArr.Length, $kArr.Length, $cArr.Length, $lArr.Length, $tzArr.Length) -LocalOnly

        [pscustomobject]@{
            Types     = $tArr
            Keyboards = $kArr
            Countries = $cArr
            Languages = $lArr
            Timezones = $tzArr
        }
    }
    catch {
        Write-Log ("[WARN] list_used API failed: {0}" -f $_.Exception.Message)
        [pscustomobject]@{
            Types     = @()
            Keyboards = @()
            Countries = @()
            Languages = @()
            Timezones = @()
        }
    }
}

function Add-DefaultLocaleOptions {
    param([Parameter(Mandatory)][psobject]$Lists)

    $Lists.Keyboards = @(@($Lists.Keyboards) + @('FR-FR', 'EN-US') |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)
    $Lists.Countries = @(@($Lists.Countries) + @('FR', 'US') |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)
    $Lists.Languages = @(@($Lists.Languages) + @('fr-FR', 'en-US') |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)
    $Lists.Timezones = @(@($Lists.Timezones) + @('Romance Standard Time', 'Eastern Standard Time') |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)

    return $Lists
}

# =========================
# Context JSON
# =========================
function Write-ContextJson([psobject]$res) {
    try {
        $dir = Split-Path -Parent $Config.ConfigJson
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

        ([ordered]@{
            computerName = $res.ComputerName
            type         = $res.Type
            country      = $res.Country
            language     = $res.Language
            timezone     = $res.Timezone
            keyboard     = $res.Keyboard
            serial       = $script:Serial
            wsBase       = $Config.WsBase.TrimEnd('/')
        } | ConvertTo-Json -Depth 3) | Set-Content -Path $Config.ConfigJson -Encoding UTF8

        Write-Log "[OK] Context written: $($Config.ConfigJson)" -LocalOnly
    } catch {
        Write-Log ("[ERROR] writing context JSON: {0}" -f $_.Exception.Message)
    }
}

# =========================
# GUI (Type, Country, Language, Timezone, Keyboard)
# =========================
function Show-ValidateDialog {
    param(
        [string]  $DefaultName,
        [string]  $DefaultType,
        [string]  $DefaultKeyboard,
        [string]  $DefaultCountry,
        [string]  $DefaultLanguage,
        [string]  $DefaultTimezone,
        [string[]]$TypeOptions,
        [string[]]$KeyboardOptions,
        [string[]]$CountryOptions,
        [string[]]$LanguageOptions,
        [string[]]$TimezoneOptions,
        [bool]    $EnableAutoValidate = $false,
        [int]     $AutoValidateSeconds = 300
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [void][System.Windows.Forms.Application]::EnableVisualStyles()

    $form                        = New-Object System.Windows.Forms.Form
    $form.Text                   = 'Validate Computer Info'
    $form.StartPosition          = 'CenterScreen'
    $form.FormBorderStyle        = 'FixedDialog'
    $form.MinimizeBox            = $false
    $form.MaximizeBox            = $false
    $form.ShowInTaskbar          = $true
    $form.TopMost                = $true
    $form.ClientSize             = [System.Drawing.Size]::new(820,520)
    $form.ControlBox             = $false
    $form.AutoScaleMode          = 'None'
    $form.BackColor              = [System.Drawing.Color]::FromArgb(241, 245, 249)

    $fontLbl = [System.Drawing.Font]::new('Segoe UI',10)
    $fontTb  = [System.Drawing.Font]::new('Segoe UI',10)
    $fontTitle = [System.Drawing.Font]::new('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
    $fontSub   = [System.Drawing.Font]::new('Segoe UI',9)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.Padding = [System.Windows.Forms.Padding]::new(16)
    $root.ColumnCount = 1
    $root.RowCount = 2
    $root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 82)))
    $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = 'Fill'
    $headerPanel.BackColor = $form.BackColor

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.AutoSize = $true
    $titleLabel.Text = 'Validate Computer Info'
    $titleLabel.Font = $fontTitle
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 52, 88)
    $titleLabel.Location = [System.Drawing.Point]::new(0, 0)

    $headerPanel.Controls.Add($titleLabel)
    $root.Controls.Add($headerPanel, 0, 0)

    $contentPanel = New-Object System.Windows.Forms.Panel
    $contentPanel.Dock = 'Fill'
    $contentPanel.BorderStyle = 'FixedSingle'
    $contentPanel.Padding = [System.Windows.Forms.Padding]::new(18, 16, 18, 18)
    $contentPanel.BackColor = [System.Drawing.Color]::White
    $root.Controls.Add($contentPanel, 0, 1)
    $form.Controls.Add($root)

    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = 'Fill'
    $tbl.Padding = [System.Windows.Forms.Padding]::new(0)
    $tbl.ColumnCount = 2
    $tbl.RowCount = 7
    $tbl.AutoSize = $false
    $tbl.ColumnStyles.Add( (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 35)) )
    $tbl.ColumnStyles.Add( (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 65)) )
    0..5 | ForEach-Object { $tbl.RowStyles.Add( (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)) ) }
    $tbl.RowStyles.Add( (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 58)) )

    # --- Name ---
    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = 'Computer name:'
    $lblName.Font = $fontLbl
    $lblName.TextAlign = 'MiddleLeft'
    $lblName.Dock = 'Fill'
    $lblName.ForeColor = [System.Drawing.Color]::FromArgb(42, 60, 80)
    $lblName.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)

    $tbName = New-Object System.Windows.Forms.TextBox
    $tbName.Font = $fontTb
    $tbName.Dock = 'Fill'
    $tbName.BorderStyle = 'FixedSingle'
    $tbName.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 255)
    $tbName.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 7)
    if ([string]::IsNullOrWhiteSpace($DefaultName)) { $tbName.Text='' } else { $tbName.Text=$DefaultName.Trim() }

    # --- Type (Combo) ---
    $lblType = New-Object System.Windows.Forms.Label
    $lblType.Text = 'Type (optional):'
    $lblType.Font = $fontLbl
    $lblType.TextAlign = 'MiddleLeft'
    $lblType.Dock = 'Fill'
    $lblType.ForeColor = [System.Drawing.Color]::FromArgb(42, 60, 80)
    $lblType.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)

    $cbType = New-Object System.Windows.Forms.ComboBox
    $cbType.Font = $fontTb
    $cbType.Dock = 'Fill'
    $cbType.DropDownStyle = 'DropDown'
    $cbType.AutoCompleteMode = 'SuggestAppend'
    $cbType.AutoCompleteSource = 'ListItems'
    $cbType.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 255)
    $cbType.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 7)

    $cbType.BeginUpdate()
    foreach ($v in @($TypeOptions)) {
        if ($null -ne $v -and $v -ne '') { [void]$cbType.Items.Add([string]$v) }
    }
    $cbType.EndUpdate()
    $cbType.Sorted = $true
    Write-Host ("UI add Types -> {0} items" -f $cbType.Items.Count)

    $defType = ''
    if ($DefaultType) { $defType = $DefaultType.Trim().ToUpperInvariant() }
    if ($defType) {
        if ($cbType.Items -notcontains $defType) { [void]$cbType.Items.Add($defType) }
        $cbType.Text = $defType
    }

    # --- Country (Combo) ---
    $lblCountry = New-Object System.Windows.Forms.Label
    $lblCountry.Text = 'Country:'
    $lblCountry.Font = $fontLbl
    $lblCountry.TextAlign = 'MiddleLeft'
    $lblCountry.Dock = 'Fill'
    $lblCountry.ForeColor = [System.Drawing.Color]::FromArgb(42, 60, 80)
    $lblCountry.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)

    $cbCountry = New-Object System.Windows.Forms.ComboBox
    $cbCountry.Font = $fontTb
    $cbCountry.Dock = 'Fill'
    $cbCountry.DropDownStyle = 'DropDown'
    $cbCountry.AutoCompleteMode = 'SuggestAppend'
    $cbCountry.AutoCompleteSource = 'ListItems'
    $cbCountry.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 255)
    $cbCountry.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 7)

    $cbCountry.BeginUpdate()
    foreach ($v in @($CountryOptions)) {
        if ($null -ne $v -and $v -ne '') { [void]$cbCountry.Items.Add([string]$v) }
    }
    $cbCountry.EndUpdate()
    $cbCountry.Sorted = $true
    Write-Host ("UI add Countries -> {0} items" -f $cbCountry.Items.Count)

    $defCountry = ''
    if ($DefaultCountry) { $defCountry = $DefaultCountry.Trim().ToUpperInvariant() }
    if ($defCountry) {
        if ($cbCountry.Items -notcontains $defCountry) { [void]$cbCountry.Items.Add($defCountry) }
        $cbCountry.Text = $defCountry
    }
    $cbCountry.Add_Leave({ if ($cbCountry.Text) { $cbCountry.Text = $cbCountry.Text.Trim().ToUpperInvariant() } })

    # --- Language (Combo) ---
    $lblLang = New-Object System.Windows.Forms.Label
    $lblLang.Text = 'Language:'
    $lblLang.Font = $fontLbl
    $lblLang.TextAlign = 'MiddleLeft'
    $lblLang.Dock = 'Fill'
    $lblLang.ForeColor = [System.Drawing.Color]::FromArgb(42, 60, 80)
    $lblLang.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)

    $cbLang = New-Object System.Windows.Forms.ComboBox
    $cbLang.Font = $fontTb
    $cbLang.Dock = 'Fill'
    $cbLang.DropDownStyle = 'DropDown'
    $cbLang.AutoCompleteMode = 'SuggestAppend'
    $cbLang.AutoCompleteSource = 'ListItems'
    $cbLang.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 255)
    $cbLang.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 7)

    $cbLang.BeginUpdate()
    foreach ($v in @($LanguageOptions)) {
        if ($null -ne $v -and $v -ne '') { [void]$cbLang.Items.Add([string]$v) }
    }
    $cbLang.EndUpdate()
    $cbLang.Sorted = $true
    Write-Host ("UI add Languages -> {0} items" -f $cbLang.Items.Count)

    if ($DefaultLanguage) {
        $defLang = $DefaultLanguage.Trim()
        if ($cbLang.Items -notcontains $defLang) { [void]$cbLang.Items.Add($defLang) }
        $cbLang.Text = $defLang
    }

    # --- Timezone (Combo) ---
    $lblTimezone = New-Object System.Windows.Forms.Label
    $lblTimezone.Text = 'Timezone:'
    $lblTimezone.Font = $fontLbl
    $lblTimezone.TextAlign = 'MiddleLeft'
    $lblTimezone.Dock = 'Fill'
    $lblTimezone.ForeColor = [System.Drawing.Color]::FromArgb(42, 60, 80)
    $lblTimezone.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)

    $cbTimezone = New-Object System.Windows.Forms.ComboBox
    $cbTimezone.Font = $fontTb
    $cbTimezone.Dock = 'Fill'
    $cbTimezone.DropDownStyle = 'DropDown'
    $cbTimezone.AutoCompleteMode = 'SuggestAppend'
    $cbTimezone.AutoCompleteSource = 'ListItems'
    $cbTimezone.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 255)
    $cbTimezone.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 7)

    $cbTimezone.BeginUpdate()
    foreach ($v in @($TimezoneOptions)) {
        if ($null -ne $v -and $v -ne '') { [void]$cbTimezone.Items.Add([string]$v) }
    }
    $cbTimezone.EndUpdate()
    $cbTimezone.Sorted = $true
    Write-Host ("UI add Timezones -> {0} items" -f $cbTimezone.Items.Count)

    if ($DefaultTimezone) {
        $defTimezone = $DefaultTimezone.Trim()
        if ($cbTimezone.Items -notcontains $defTimezone) { [void]$cbTimezone.Items.Add($defTimezone) }
        $cbTimezone.Text = $defTimezone
    }

    # --- Keyboard (Combo) ---
    $lblKbd = New-Object System.Windows.Forms.Label
    $lblKbd.Text = 'Keyboard:'
    $lblKbd.Font = $fontLbl
    $lblKbd.TextAlign = 'MiddleLeft'
    $lblKbd.Dock = 'Fill'
    $lblKbd.ForeColor = [System.Drawing.Color]::FromArgb(42, 60, 80)
    $lblKbd.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)

    $cbKbd = New-Object System.Windows.Forms.ComboBox
    $cbKbd.Font = $fontTb
    $cbKbd.Dock = 'Fill'
    $cbKbd.DropDownStyle = 'DropDown'
    $cbKbd.AutoCompleteMode = 'SuggestAppend'
    $cbKbd.AutoCompleteSource = 'ListItems'
    $cbKbd.BackColor = [System.Drawing.Color]::FromArgb(252, 253, 255)
    $cbKbd.Margin = [System.Windows.Forms.Padding]::new(0, 7, 0, 7)

    $cbKbd.BeginUpdate()
    foreach ($v in @($KeyboardOptions)) {
        if ($null -ne $v -and $v -ne '') { [void]$cbKbd.Items.Add([string]$v) }
    }
    $cbKbd.EndUpdate()
    $cbKbd.Sorted = $true
    Write-Host ("UI add Keyboards -> {0} items" -f $cbKbd.Items.Count)

    $defKbd = ''
    if ($DefaultKeyboard) { $defKbd = $DefaultKeyboard.Trim().ToUpperInvariant() }
    if ($defKbd) {
        if ($cbKbd.Items -notcontains $defKbd) { [void]$cbKbd.Items.Add($defKbd) }
        $cbKbd.Text = $defKbd
    }

    $cbType.Add_Leave({ if ($cbType.Text)    { $cbType.Text    = $cbType.Text.ToUpperInvariant()    } })
    $cbKbd.Add_Leave({ if ($cbKbd.Text)      { $cbKbd.Text     = $cbKbd.Text.ToUpperInvariant()     } })

    # --- Buttons ---
    $spacer = New-Object System.Windows.Forms.Label
    $spacer.Dock = 'Fill'
    $spacer.TextAlign = 'MiddleLeft'
    $spacer.ForeColor = [System.Drawing.Color]::FromArgb(96, 112, 128)
    $spacer.Font = [System.Drawing.Font]::new('Segoe UI',9)
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Validate'
    $btnOk.Font = [System.Drawing.Font]::new('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
    $btnOk.Anchor = 'Right'
    $btnOk.Width = 132
    $btnOk.Height = 38
    $btnOk.TextAlign = 'MiddleCenter'
    $btnOk.Enabled = $false
    $btnOk.FlatStyle = 'Flat'
    $btnOk.FlatAppearance.BorderSize = 0
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(20, 114, 196)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.Cursor = [System.Windows.Forms.Cursors]::Hand
    $state = @{
        AutoValidateCancelled = $false
        AutoSubmitted         = $false
        RemainingSeconds      = [Math]::Max(0, [int]$AutoValidateSeconds)
        CancelArmAt           = [DateTime]::MinValue
    }
    $countdownTimer = New-Object System.Windows.Forms.Timer
    $countdownTimer.Interval = 1000

    $UpdateCountdownText = {
        if (-not $EnableAutoValidate) {
            $spacer.Text = ''
            return
        }
        if ($state.AutoValidateCancelled) {
            $spacer.Text = 'Auto-validate cancelled (manual Validate required)'
            return
        }
        if ($state.RemainingSeconds -lt 0) { $state.RemainingSeconds = 0 }
        $spacer.Text = ("Auto-validate in {0}s" -f $state.RemainingSeconds)
    }

    $CancelAutoValidate = {
        if (-not $EnableAutoValidate) { return }
        if ($state.AutoValidateCancelled) { return }
        if ([DateTime]::UtcNow -lt $state.CancelArmAt) { return }
        $state.AutoValidateCancelled = $true
        try { $countdownTimer.Stop() } catch {}
        & $UpdateCountdownText
    }

    # Layout
    $tbl.Controls.Add($lblName,    0,0); $tbl.Controls.Add($tbName,    1,0)
    $tbl.Controls.Add($lblType,    0,1); $tbl.Controls.Add($cbType,    1,1)
    $tbl.Controls.Add($lblCountry, 0,2); $tbl.Controls.Add($cbCountry, 1,2)
    $tbl.Controls.Add($lblLang,    0,3); $tbl.Controls.Add($cbLang,    1,3)
    $tbl.Controls.Add($lblTimezone,0,4); $tbl.Controls.Add($cbTimezone,1,4)
    $tbl.Controls.Add($lblKbd,     0,5); $tbl.Controls.Add($cbKbd,     1,5)
    $tbl.Controls.Add($spacer,     0,6)
    $tbl.Controls.Add($btnOk,      1,6)
    $contentPanel.Controls.Add($tbl)

    $updateBtn = {
        $btnOk.Enabled = -not [string]::IsNullOrWhiteSpace($tbName.Text)     -and
                         -not [string]::IsNullOrWhiteSpace($cbCountry.Text)  -and
                         -not [string]::IsNullOrWhiteSpace($cbKbd.Text)
    }
    $tbName.Add_TextChanged($updateBtn)
    $cbType.Add_TextChanged($updateBtn)
    $cbType.Add_SelectedIndexChanged($updateBtn)
    $cbCountry.Add_TextChanged($updateBtn)
    $cbCountry.Add_SelectedIndexChanged($updateBtn)
    $cbLang.Add_TextChanged($updateBtn)
    $cbLang.Add_SelectedIndexChanged($updateBtn)
    $cbTimezone.Add_TextChanged($updateBtn)
    $cbTimezone.Add_SelectedIndexChanged($updateBtn)
    $cbKbd.Add_TextChanged($updateBtn)
    $cbKbd.Add_SelectedIndexChanged($updateBtn)
    & $updateBtn

    if ($EnableAutoValidate) {
        $form.KeyPreview = $true
        $form.Add_MouseClick($CancelAutoValidate)
        $form.Add_KeyPress($CancelAutoValidate)
        $tbName.Add_MouseClick($CancelAutoValidate)
        $tbName.Add_KeyPress($CancelAutoValidate)
        $cbType.Add_MouseClick($CancelAutoValidate)
        $cbType.Add_KeyPress($CancelAutoValidate)
        $cbCountry.Add_MouseClick($CancelAutoValidate)
        $cbCountry.Add_KeyPress($CancelAutoValidate)
        $cbLang.Add_MouseClick($CancelAutoValidate)
        $cbLang.Add_KeyPress($CancelAutoValidate)
        $cbTimezone.Add_MouseClick($CancelAutoValidate)
        $cbTimezone.Add_KeyPress($CancelAutoValidate)
        $cbKbd.Add_MouseClick($CancelAutoValidate)
        $cbKbd.Add_KeyPress($CancelAutoValidate)
    }

    $btnOk.Add_Click({
        try { $countdownTimer.Stop() } catch {}
        $name    = $tbName.Text.Trim()
        $type    = if ($cbType.Text)    { $cbType.Text.Trim().ToUpperInvariant()    } else { '' }
        $country = if ($cbCountry.Text) { $cbCountry.Text.Trim().ToUpperInvariant() } else { '' }
        $lang    = if ($cbLang.Text)    { $cbLang.Text.Trim()                        } else { '' }
        $timezone = if ($cbTimezone.Text) { $cbTimezone.Text.Trim()                   } else { '' }
        $kbd     = if ($cbKbd.Text)     { $cbKbd.Text.Trim().ToUpperInvariant()     } else { '' }

        if ([string]::IsNullOrWhiteSpace($name) -or
            [string]::IsNullOrWhiteSpace($country) -or
            [string]::IsNullOrWhiteSpace($kbd)) {
            [System.Windows.Forms.MessageBox]::Show('Please fill all mandatory fields (Computer name, Country, Keyboard).','Validation',
                [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($name.Length -gt 15 -or $name -match '[\\/:*?"<>|]') {
            [System.Windows.Forms.MessageBox]::Show('Invalid computer name (NetBIOS rules).','Validation',
                [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $form.Tag = [pscustomobject]@{
            ComputerName = $name
            Type         = $type
            Country      = $country
            Language     = $lang
            Timezone     = $timezone
            Keyboard     = $kbd
            AutoSubmit   = [bool]$state.AutoSubmitted
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.AcceptButton = $btnOk
    $countdownTimer.Add_Tick({
        if (-not $EnableAutoValidate) { return }
        if ($state.AutoValidateCancelled) { return }
        if ($state.RemainingSeconds -le 0) {
            try { $countdownTimer.Stop() } catch {}
            if ($btnOk.Enabled) {
                $state.AutoSubmitted = $true
                $btnOk.PerformClick()
            } else {
                $state.AutoValidateCancelled = $true
                & $UpdateCountdownText
            }
            return
        }
        $state.RemainingSeconds--
        & $UpdateCountdownText
    })
    $form.Add_FormClosing({ try { $countdownTimer.Stop() } catch {} })
    $form.Add_Shown({
        $form.Activate()
        $tbName.Focus()
        $state.CancelArmAt = [DateTime]::UtcNow.AddSeconds(2)
        & $UpdateCountdownText
        if ($EnableAutoValidate -and -not $state.AutoValidateCancelled) {
            try { $countdownTimer.Start() } catch {}
        }
    })

    return $form.ShowDialog(), $form.Tag
}

# =========================
# MAIN
# =========================
Remove-Item -Path $Config.LocalLogPath -Force -ErrorAction SilentlyContinue
Write-Log 'START PROVISIONING'

Update-ProgressBitmap
Write-Log 'STEP 001'

Invoke-HardwareCompatibilityCheck

# Load current computer values from the API.
$prefill = Get-PrefillFromApi
$lists = $null

if ([string]::IsNullOrWhiteSpace($prefill.Type)) {
    $lists = Get-UsedLists
    if ($lists -and $lists.Types -and @($lists.Types).Count -eq 1) {
        $prefill.Type = ([string]@($lists.Types)[0]).Trim().ToUpperInvariant()
        Write-Log ("[INFO] Type auto-filled from /list_used: {0}" -f $prefill.Type)
    }
}

if (-not $lists) { $lists = Get-UsedLists }
$lists = Add-DefaultLocaleOptions -Lists $lists

if ($prefill._Complete -eq $true) {
    Write-Log '[INFO] WS complete data available -> showing validation dialog with 300s auto-validate timer' -LocalOnly

    $defType     = if ($prefill.Type)     { $prefill.Type.ToUpperInvariant()     } else { '' }
    $defKbd      = if ($prefill.Keyboard) { $prefill.Keyboard.ToUpperInvariant() } else { 'FR-FR' }
    $defCountry  = if ($prefill.Country)  { $prefill.Country.ToUpperInvariant()  } else { 'FR' }
    $defLanguage = if ($prefill.Language) { $prefill.Language                    } else { 'fr-FR' }
    $defTimezone = if ($prefill.Timezone) { $prefill.Timezone                    } else { 'Romance Standard Time' }

    $dlgResult, $res = Show-ValidateDialog `
        -DefaultName      $prefill.ComputerName `
        -DefaultType      $defType `
        -DefaultKeyboard  $defKbd `
        -DefaultCountry   $defCountry `
        -DefaultLanguage  $defLanguage `
        -DefaultTimezone  $defTimezone `
        -TypeOptions      $lists.Types `
        -KeyboardOptions  $lists.Keyboards `
        -CountryOptions   $lists.Countries `
        -LanguageOptions  $lists.Languages `
        -TimezoneOptions  $lists.Timezones `
        -EnableAutoValidate $true `
        -AutoValidateSeconds 300

    if ($res -and
        -not [string]::IsNullOrWhiteSpace($res.ComputerName) -and
        -not [string]::IsNullOrWhiteSpace($res.Country)      -and
        -not [string]::IsNullOrWhiteSpace($res.Keyboard)) {

        if ($res.PSObject.Properties.Name -contains 'AutoSubmit' -and [bool]$res.AutoSubmit) {
            Write-Log ("[OK] WS AUTO-VALIDATE (timer) Name={0}; Type={1}; Country={2}; Lang={3}; Timezone={4}; Keyboard={5}; Serial={6}" -f `
                $res.ComputerName,$res.Type,$res.Country,$res.Language,$res.Timezone,$res.Keyboard,$script:Serial)
        } else {
            Write-Log ("[OK] WS MANUAL VALIDATE Name={0}; Type={1}; Country={2}; Lang={3}; Timezone={4}; Keyboard={5}; Serial={6}" -f `
                $res.ComputerName,$res.Type,$res.Country,$res.Language,$res.Timezone,$res.Keyboard,$script:Serial)
        }
        Write-ContextJson -res $res
        Write-Log '[INFO] WS computer registration disabled' -LocalOnly
    } else {
        Write-Log '[WARN] WS validation dialog closed or missing required fields'
    }
}
else {
    Write-Log ("[DBG] Types: {0}"      -f (($lists.Types)     -join ', ')) -LocalOnly
    Write-Log ("[DBG] Keyboards: {0}"  -f (($lists.Keyboards) -join ', ')) -LocalOnly
    Write-Log ("[DBG] Countries: {0}"  -f (($lists.Countries) -join ', ')) -LocalOnly
    Write-Log ("[DBG] Languages: {0}"  -f (($lists.Languages) -join ', ')) -LocalOnly
    Write-Log ("[DBG] Timezones: {0}"  -f (($lists.Timezones) -join ', ')) -LocalOnly

    $defType     = if ($prefill.Type)     { $prefill.Type.ToUpperInvariant()     } else { '' }
    $defKbd      = if ($prefill.Keyboard) { $prefill.Keyboard.ToUpperInvariant() } else { 'FR-FR' }
    $defCountry  = if ($prefill.Country)  { $prefill.Country.ToUpperInvariant()  } else { 'FR' }
    $defLanguage = if ($prefill.Language) { $prefill.Language                    } else { 'fr-FR' }
    $defTimezone = if ($prefill.Timezone) { $prefill.Timezone                    } else { 'Romance Standard Time' }

    $dlgResult, $res = Show-ValidateDialog `
        -DefaultName      $prefill.ComputerName `
        -DefaultType      $defType `
        -DefaultKeyboard  $defKbd `
        -DefaultCountry   $defCountry `
        -DefaultLanguage  $defLanguage `
        -DefaultTimezone  $defTimezone `
        -TypeOptions      $lists.Types `
        -KeyboardOptions  $lists.Keyboards `
        -CountryOptions   $lists.Countries `
        -LanguageOptions  $lists.Languages `
        -TimezoneOptions  $lists.Timezones

    if ($res -and
        -not [string]::IsNullOrWhiteSpace($res.ComputerName) -and
        -not [string]::IsNullOrWhiteSpace($res.Country)      -and
        -not [string]::IsNullOrWhiteSpace($res.Keyboard)) {

        Write-Log ("[OK] VALIDATE Name={0}; Type={1}; Country={2}; Lang={3}; Timezone={4}; Keyboard={5}; Serial={6}" -f `
            $res.ComputerName,$res.Type,$res.Country,$res.Language,$res.Timezone,$res.Keyboard,$script:Serial)
        Write-ContextJson -res $res
        Write-Log '[INFO] WS computer registration disabled' -LocalOnly
    } else {
        Write-Log '[WARN] VALIDATE cancelled by user or missing required fields'
    }
}

Write-Log 'STEP 002'
