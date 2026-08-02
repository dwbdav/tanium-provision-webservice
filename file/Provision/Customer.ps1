# =========================
# CONFIG
# =========================
$Config = [ordered]@{
  ConfigJson             = 'C:\provision\config.json'
  LocalLogPath           = 'C:\provision\provision.log'
  DriversFolder          = 'C:\DRIVERS'
  ApplicationFolder      = 'C:\Provision\Apps'
  OtherFiles             = 'C:\_T\provision*.zip'
  OtherFilesFolder       = 'C:\provision\OtherFiles'
  OtherFilesListingPath  = 'C:\provision\t.log'

  LedgerPath             = 'C:\provision\installed_apps.txt'

  TaniumOSDModulePath    = 'C:\_T\TaniumOSD'
  TaniumClientModulePath = 'C:\_T\TaniumClient'

  RetryCount             = 15
  RetryDelaySec          = 5
  TimeoutSec             = 60
  DownloadConnectTimeoutSec = 60
  DownloadLowSpeedLimitBps  = 1024
  DownloadLowSpeedTimeSec   = 300
}
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $Config.LocalLogPath) -Force

$script:AppsRequireReboot = $false

# =========================
# Initial setup
# =========================
try {
  $logDir = Split-Path -Parent $Config.LocalLogPath
  if ($logDir) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }
} catch {}

# =========================
# Tanium modules
# =========================
if (Test-Path $Config.TaniumOSDModulePath) {
  try {
    Import-Module $Config.TaniumOSDModulePath -ErrorAction Stop
  } catch {}
}

if (Test-Path $Config.TaniumClientModulePath) {
  try {
    Import-Module $Config.TaniumClientModulePath -ErrorAction Stop
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

$script:Serial = if ($script:Serial) {
  $script:Serial.Trim().ToUpper() -replace '\s',''
} else {
  'UNKNOWN'
}

# =========================
# WS base URL
# =========================
try {
  if (-not (Test-Path -LiteralPath $Config.ConfigJson)) {
    throw "Context JSON not found: $($Config.ConfigJson)"
  }

  $wsBase = ([string]((Get-Content -LiteralPath $Config.ConfigJson -Raw | ConvertFrom-Json -ErrorAction Stop).wsBase)).Trim()

  if ([string]::IsNullOrWhiteSpace($wsBase)) {
    throw "wsBase missing in context JSON: $($Config.ConfigJson)"
  }

  if (([uri]$wsBase).Scheme -notin @('http', 'https')) {
    throw "Invalid wsBase scheme: $wsBase"
  }

  $Config['WsBase'] = $wsBase.TrimEnd('/')
}
catch {
  Write-Host "[ERROR] $($_.Exception.Message)"
  try {
    "[ERROR] $($_.Exception.Message)" | Out-File -FilePath $Config.LocalLogPath -Append -Encoding UTF8
  } catch {}
  exit 1
}

# =========================
# API endpoints
# =========================
$script:GetAppsApi      = "$($Config.WsBase)/getapps"
$script:GetDriversApi   = "$($Config.WsBase)/getdrivers"
$script:EndProvisionUrl = "$($Config.WsBase)/file/raw/Provision/endprovisionning.ps1"

# =========================
# Other files
# =========================
function Write-TaniumRootListing {
  try {
    $targetDir = Split-Path -Parent $Config.OtherFilesListingPath
    if ($targetDir) {
      New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath 'C:\_T')) {
      "C:\_T not found" | Out-File -FilePath $Config.OtherFilesListingPath -Encoding UTF8
      Write-Log ("[WARN] C:\_T not found, listing written to: {0}" -f $Config.OtherFilesListingPath)
      return
    }

    Get-ChildItem -LiteralPath 'C:\_T' -Recurse -Force -ErrorAction SilentlyContinue |
      Select-Object FullName, Length, LastWriteTime |
      Format-Table -AutoSize |
      Out-String -Width 4096 |
      Out-File -FilePath $Config.OtherFilesListingPath -Encoding UTF8

    Write-Log ("[INFO] C:\_T listing written to: {0}" -f $Config.OtherFilesListingPath)
  }
  catch {
    Write-Log ("[WARN] C:\_T listing failed: {0}" -f $_.Exception.Message)
  }
}

function Expand-OtherFiles {
  if ([string]::IsNullOrWhiteSpace($Config.OtherFiles)) {
    return
  }

  $archivePattern = $Config.OtherFiles
  $archivePath = ''
  $tempFolder = "$($Config.OtherFilesFolder).tmp"

  try {
    if (Test-Path -LiteralPath $Config.OtherFilesFolder) {
      Write-Log ("[INFO] Other files folder already exists, skipping extraction: {0}" -f $Config.OtherFilesFolder)
      return
    }

    $archives = @(
      Get-ChildItem -Path $archivePattern -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ine 'provision_scripts.zip' } |
        Sort-Object Name
    )
    if ($archives.Count -gt 0) {
      Write-Log ("[INFO] Other files archive candidates: {0}" -f (($archives | ForEach-Object { $_.FullName }) -join '; ')) -LocalOnly
    }

    if ($archives.Count -eq 0) {
      Write-Log ("[INFO] Other files archive not found: {0}" -f $archivePattern)
      Write-TaniumRootListing
      return
    }

    $archivePath = $archives[0].FullName
    Write-Log ("[INFO] Other files archive selected: {0}" -f $archivePath)

    if ((Get-Item -LiteralPath $archivePath).Length -le 0) {
      throw "Archive is empty: $archivePath"
    }

    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    Expand-Archive -Path $archivePath -DestinationPath $tempFolder -Force
    Move-Item -LiteralPath $tempFolder -Destination $Config.OtherFilesFolder -Force
    Write-Log ("[OK] Other files extracted to: {0}" -f $Config.OtherFilesFolder)
  }
  catch {
    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log ("[ERROR] Other files extraction failed: {0}" -f $_.Exception.Message)
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
# HTTP
# =========================
function Invoke-ApiGetWithRetry {
  param(
    [Parameter(Mandatory)][string]$Url,
    [string]$Context = 'API GET'
  )

  for ($i = 1; $i -le $Config.RetryCount; $i++) {
    try {
      return Invoke-RestMethod -Uri $Url -Method GET -TimeoutSec $Config.TimeoutSec
    }
    catch {
      if ($i -ge $Config.RetryCount) {
        throw
      }

      Write-Log ("[WARN] {0} retry {1}/{2}: {3}" -f $Context, $i, $Config.RetryCount, $_.Exception.Message)
      Start-Sleep -Seconds $Config.RetryDelaySec
    }
  }
}

# =========================
# Reboot
# =========================
function Invoke-RebootNow {
  try {
    Set-OSDVariable -Name 'RebootAndRerun' -Value $true -ErrorAction Stop
    Write-Log '[OK] RebootAndRerun variable set'
  }
  catch {
    Write-Log ("[ERROR] RebootAndRerun variable failed: {0}" -f $_.Exception.Message)
    exit 1
  }

  exit 3010
}

# =========================
# Ledger
# =========================
function Normalize-Id {
  param([string]$Value)

  if ($null -eq $Value) {
    return ''
  }

  return (($Value -replace '\s+', ' ').Trim().ToUpper())
}

function Test-AppAlreadyExecuted {
  param(
    [Parameter(Mandatory)][string]$AppName
  )

  $appId = Normalize-Id $AppName

  if ([string]::IsNullOrWhiteSpace($appId)) {
    return $false
  }

  $doneApps = @(
    Get-Content -LiteralPath $Config.LedgerPath -ErrorAction SilentlyContinue |
      ForEach-Object { Normalize-Id $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  return ($doneApps -contains $appId)
}

function Add-AppToLedger {
  param(
    [Parameter(Mandatory)][string]$AppName
  )

  $appId = Normalize-Id $AppName

  if ([string]::IsNullOrWhiteSpace($appId)) {
    return
  }

  if (Test-AppAlreadyExecuted -AppName $appId) {
    return
  }

  try {
    $dir = Split-Path -Parent $Config.LedgerPath
    if ($dir) {
      $null = New-Item -ItemType Directory -Path $dir -Force
    }

    Add-Content -Path $Config.LedgerPath -Value $appId -Encoding UTF8
    Write-Log ("[OK] Ledger updated: {0}" -f $appId) -LocalOnly
  }
  catch {
    Write-Log ("[WARN] Ledger update failed for {0}: {1}" -f $appId, $_.Exception.Message)
  }
}

# =========================
# Progress
# =========================
function Show-Progress {
  param([string]$Message)

  try {
    Set-OSDProgressDisplay -Message $Message
    return
  } catch {
    Write-Log ("[WARN] OSD progress failed: {0}" -f $_.Exception.Message)
  }

  Write-Host $Message
}

function Set-ProvisionStep {
  param(
    [Parameter(Mandatory)][string]$Step,
    [Parameter(Mandatory)][string]$Label
  )

  Write-Log ("{0} - {1}" -f $Step, $Label)
}

# =========================
# Download
# =========================
function Download-File {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Destination,
    [switch]$AllowEmpty
  )

  $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
  if (-not $curl) {
    throw 'curl.exe not found'
  }

  $dir = Split-Path -Parent $Destination
  if ($dir) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  for ($i = 1; $i -le $Config.RetryCount; $i++) {
    $curlArgs = @(
      '-fSL',
      '-sS',
      '--retry', '0',
      '--connect-timeout', "$($Config.DownloadConnectTimeoutSec)",
      '--speed-limit', "$($Config.DownloadLowSpeedLimitBps)",
      '--speed-time', "$($Config.DownloadLowSpeedTimeSec)"
    )

    $resumeDownload = ((Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt 0)
    if ($resumeDownload) {
      $curlArgs += @('-C', '-')
    }

    $curlArgs += @(
      '-o', $Destination,
      $Url
    )

    & $curl.Source @curlArgs

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and (Test-Path -LiteralPath $Destination)) {
      if ($AllowEmpty -or (Get-Item -LiteralPath $Destination).Length -gt 0) {
        try { Unblock-File -Path $Destination -ErrorAction SilentlyContinue } catch {}
        return
      }
    }

    if ($resumeDownload -and $exitCode -ne 0) {
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    if ($i -lt $Config.RetryCount) {
      Write-Log ("[WARN] Download retry {0}/{1}: {2}" -f $i, $Config.RetryCount, $Url)
      Start-Sleep -Seconds $Config.RetryDelaySec
    }
  }

  throw "Download failed: $Url"
}

function Get-RemoteFolderEntries {
  param(
    [Parameter(Mandatory)]
    [string]$Url
  )

  $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
  if (-not $curl) {
    throw 'curl.exe not found'
  }

  $html = ''

  for ($i = 1; $i -le $Config.RetryCount; $i++) {
    $output = & $curl.Source -fSL -sS --connect-timeout "$($Config.TimeoutSec)" --max-time "$($Config.TimeoutSec)" $Url 2>&1

    if ($LASTEXITCODE -eq 0) {
      $html = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
      if (-not [string]::IsNullOrWhiteSpace($html)) {
        break
      }
    }

    if ($i -lt $Config.RetryCount) {
      Write-Log ("[WARN] Folder listing retry {0}/{1}: {2}" -f $i, $Config.RetryCount, $Url)
      Start-Sleep -Seconds $Config.RetryDelaySec
    }
  }

  if ([string]::IsNullOrWhiteSpace($html)) {
    throw "Folder listing failed: $Url"
  }

  $entries = @()
  $matches = [regex]::Matches(
    $html,
    '<tr\b[^>]*data-entry-href="(?<href>[^"]+)"[^>]*>(?<body>.*?)</tr>',
    'IgnoreCase,Singleline'
  )

  foreach ($match in $matches) {
    $href = [System.Net.WebUtility]::HtmlDecode($match.Groups['href'].Value)
    if ([string]::IsNullOrWhiteSpace($href)) {
      continue
    }

    $absoluteUrl = ([uri]::new([uri]$Url, $href)).AbsoluteUri
    $name = [uri]::UnescapeDataString([System.IO.Path]::GetFileName(([uri]$absoluteUrl).AbsolutePath))

    if ([string]::IsNullOrWhiteSpace($name) -or $name -ieq '@eaDir') {
      continue
    }

    $entries += [pscustomobject]@{
      Name  = $name
      Url   = $absoluteUrl
      IsDir = [bool]($match.Groups['body'].Value -match 'folder-link')
    }
  }

  return @($entries)
}

function Download-RemoteFolder {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Destination,
    [switch]$AllowEmpty
  )

  New-Item -ItemType Directory -Path $Destination -Force | Out-Null

  $entries = Get-RemoteFolderEntries -Url $Url

  if ($entries.Count -eq 0) {
    if ($AllowEmpty) {
      return
    }

    throw "Remote folder is empty or unreadable: $Url"
  }

  foreach ($entry in $entries) {
    $target = Join-Path $Destination $entry.Name

    if ($entry.IsDir) {
      Download-RemoteFolder -Url $entry.Url -Destination $target -AllowEmpty
    }
    else {
      Download-File -Url $entry.Url -Destination $target -AllowEmpty
    }
  }
}

function Get-InstallerExtensionFromPath {
  param([Parameter(Mandatory)][string]$Path)

  $extension = [System.IO.Path]::GetExtension($Path)
  if ([string]::IsNullOrWhiteSpace($extension)) {
    return '.ps1'
  }

  return $extension.ToLowerInvariant()
}

function Test-HttpUrl {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  try {
    $uri = [uri]$Value
    return ($uri.IsAbsoluteUri -and $uri.Scheme -in @('http', 'https'))
  }
  catch {
    return $false
  }
}

function Test-UncPath {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return $Value.Trim().StartsWith('\\')
}

function Expand-SystemEnvironmentVariables {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ''
  }

  return [regex]::Replace($Value, '%([A-Za-z_][A-Za-z0-9_]*)%', {
    param($Match)

    $name = $Match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($name)) {
      return $Match.Value
    }

    $machineValue = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Machine)
    if (-not [string]::IsNullOrWhiteSpace($machineValue)) {
      return $machineValue
    }

    $processValue = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
      return $processValue
    }

    return $Match.Value
  })
}

function Get-MissingSystemEnvironmentVariables {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return @()
  }

  $missing = [ordered]@{}
  foreach ($match in [regex]::Matches($Value, '%([A-Za-z_][A-Za-z0-9_]*)%')) {
    $name = $match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($name)) {
      continue
    }

    $machineValue = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Machine)
    $processValue = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace($machineValue) -and [string]::IsNullOrWhiteSpace($processValue)) {
      $missing[$name] = $true
    }
  }

  return @($missing.Keys)
}

function Invoke-RobocopyChecked {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [string]$FileName
  )

  $robocopy = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue
  if (-not $robocopy) {
    throw 'robocopy.exe not found'
  }

  New-Item -ItemType Directory -Path $Destination -Force | Out-Null

  $args = @($Source, $Destination)
  if (-not [string]::IsNullOrWhiteSpace($FileName)) {
    $args += $FileName
  }
  else {
    $args += '/E'
  }
  $args += @('/R:3', '/W:10')

  & $robocopy.Source @args | Out-Null
  $exitCode = [int]$LASTEXITCODE
  if ($exitCode -ge 8) {
    throw ("robocopy failed ExitCode={0}: {1} -> {2}" -f $exitCode, $Source, $Destination)
  }
}

function Copy-UncFolder {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "UNC source folder not found: $Source"
  }

  Invoke-RobocopyChecked -Source $Source -Destination $Destination
}

function Copy-UncFile {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "UNC source file not found: $Source"
  }

  $sourceDir = Split-Path -Parent $Source
  $fileName = Split-Path -Leaf $Source
  $destDir = Split-Path -Parent $Destination
  Invoke-RobocopyChecked -Source $sourceDir -Destination $destDir -FileName $fileName

  $copiedPath = Join-Path $destDir $fileName
  if (-not (Test-Path -LiteralPath $copiedPath -PathType Leaf)) {
    throw "UNC file copy failed: $Source"
  }

  if ($copiedPath -ine $Destination) {
    Move-Item -LiteralPath $copiedPath -Destination $Destination -Force
  }
}

# =========================
# Installers
# =========================

function Invoke-InstallerProcess {
  param(
    [Parameter(Mandatory)][string]$Extension,
    [Parameter(Mandatory)][string]$LocalFile,
    [Parameter(Mandatory)][string]$WorkingDirectory
  )

  switch ($Extension) {
    '.ps1' {
      Write-Log ("[INFO] Installer command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{0}""; WorkingDirectory=""{1}""" -f $LocalFile, $WorkingDirectory) -LocalOnly
      return Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LocalFile) `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Minimized `
        -Wait `
        -PassThru
    }

    '.bat' {
      Write-Log ("[INFO] Installer command: cmd.exe /c ""{0}""; WorkingDirectory=""{1}""" -f $LocalFile, $WorkingDirectory) -LocalOnly
      return Start-Process -FilePath 'cmd.exe' `
        -ArgumentList @('/c', $LocalFile) `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Minimized `
        -Wait `
        -PassThru
    }

    '.cmd' {
      Write-Log ("[INFO] Installer command: cmd.exe /c ""{0}""; WorkingDirectory=""{1}""" -f $LocalFile, $WorkingDirectory) -LocalOnly
      return Start-Process -FilePath 'cmd.exe' `
        -ArgumentList @('/c', $LocalFile) `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Minimized `
        -Wait `
        -PassThru
    }

    '.msi' {
      Write-Log ("[INFO] Installer command: msiexec.exe /i ""{0}"" /qn REBOOT=ReallySuppress; WorkingDirectory=""{1}""" -f $LocalFile, $WorkingDirectory) -LocalOnly
      return Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList @('/i', $LocalFile, '/qn', 'REBOOT=ReallySuppress') `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Minimized `
        -Wait `
        -PassThru
    }

    default {
      Write-Log ("[INFO] Installer command: ""{0}"" /S; WorkingDirectory=""{1}""" -f $LocalFile, $WorkingDirectory) -LocalOnly
      return Start-Process -FilePath $LocalFile `
        -ArgumentList @('/S') `
        -WorkingDirectory $WorkingDirectory `
        -WindowStyle Minimized `
        -Wait `
        -PassThru
    }
  }
}

# =========================
# Context
# =========================
function Load-ContextJson {
  if (-not (Test-Path -LiteralPath $Config.ConfigJson)) {
    Write-Log "[ERROR] Context JSON not found: $($Config.ConfigJson)"
    return [pscustomobject]@{
      Type    = ''
      Country = ''
    }
  }

  try {
    $js = Get-Content -LiteralPath $Config.ConfigJson -Raw | ConvertFrom-Json -ErrorAction Stop

    return [pscustomobject]@{
      Type    = ([string]$js.type).Trim()
      Country = ([string]$js.country).Trim().ToUpperInvariant()
    }
  }
  catch {
    Write-Log ("[ERROR] Reading context JSON failed: {0}" -f $_.Exception.Message)

    return [pscustomobject]@{
      Type    = ''
      Country = ''
    }
  }
}

# =========================
# MAIN
# =========================
$pass = 1
$ctx = Load-ContextJson

try {
  $pass = [int](Get-OSDVariable -Name 'ExecutionPass')
  Write-Log ("[INFO] ExecutionPass: {0}" -f $pass) -LocalOnly
} catch {}

if ($pass -eq 1) {
  Set-ProvisionStep -Step 'STEP 007' -Label 'Init'
  Expand-OtherFiles

	powercfg.exe /setactive SCHEME_MIN | Out-Null

  Write-Log ("[INFO] Context: Type={0}; Country={1}" -f $ctx.Type, $ctx.Country) -LocalOnly

  try {
    $typeValue = if ([string]::IsNullOrWhiteSpace($ctx.Type)) { 'EMPTY' } else { $ctx.Type }
    $env:TYPE = $typeValue
    [Environment]::SetEnvironmentVariable('TYPE', $typeValue, 'Machine')
    Write-Log ("[OK] TYPE environment variable set: {0}" -f $typeValue) -LocalOnly
  }
  catch {
    Write-Log ("[ERROR] Setting TYPE environment variable failed: {0}" -f $_.Exception.Message)
  }

}

function Install-AppsForType {
  param(
    [Parameter(Mandatory)][string]$TypeName,
    [string]$Country
  )

  $encodedType = [uri]::EscapeDataString($TypeName)
  $countryParam = ''
  if (-not [string]::IsNullOrWhiteSpace($Country)) {
    $countryParam = "&country=$([uri]::EscapeDataString($Country.Trim().ToUpperInvariant()))"
  }
  $model = Get-ComputerModel
  $modelParam = ''
  if (-not [string]::IsNullOrWhiteSpace($model)) {
    $modelParam = "&model=$([uri]::EscapeDataString($model))"
  }

  $appsUrl = "$($script:GetAppsApi)?type=$encodedType$countryParam$modelParam"

  try {
    $appsResponse = Invoke-ApiGetWithRetry -Url $appsUrl -Context "getapps"
    $applications = @($appsResponse.applications) | Where-Object { $null -ne $_ }

    if ($applications.Count -eq 0) {
      Write-Log ("[INFO] [{0}] No applications" -f $TypeName)
      return
    }

    foreach ($app in $applications) {
      $appName   = ([string]$app.name).Trim()
      $appUrl    = ([string]$app.url).Trim()
      $appScript = ''

      if ($app.PSObject.Properties.Match('script').Count -gt 0) {
        $appScript = ([string]$app.script).Trim()
      }

      $appSource = Resolve-ProvisionUrl -Url $appUrl

      if ([string]::IsNullOrWhiteSpace($appName) -or
          [string]::IsNullOrWhiteSpace($appSource) -or
          [string]::IsNullOrWhiteSpace($appScript)) {
        Write-Log ("[WARN] [{0}] Invalid application entry skipped" -f $TypeName)
        continue
      }

      if ([System.IO.Path]::IsPathRooted($appScript) -or $appScript -match '(^|[\\/])\.\.([\\/]|$)') {
        Write-Log ("[ERROR] [{0}] Invalid script path skipped: {1}" -f $TypeName, $appScript)
        continue
      }

      if (Test-AppAlreadyExecuted -AppName $appName) {
        Write-Log ("[SKIP] [{0}] Application already executed: {1}" -f $TypeName, $appName) -LocalOnly
        continue
      }

      $needsReboot = $false
      if ($app.PSObject.Properties.Match('reboot').Count -gt 0) {
        $needsReboot = [bool]$app.reboot
      }

      Write-Log ("[INFO] [{0}] {1}" -f $TypeName, $appName)
      Show-Progress ("Installing APP {0}..." -f $appName)

      $safeName = ($appName -replace '[^\w\.-]', '_')
      $packageDir = Join-Path $Config.ApplicationFolder $safeName

      try {
        if (Test-HttpUrl -Value $appSource) {
          Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
          New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
          Write-Log ("[INFO] [{0}] Downloading source: {1}" -f $TypeName, $appSource)
          Download-RemoteFolder -Url $appSource -Destination $packageDir
        }
        elseif (Test-UncPath -Value $appSource) {
          Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
          New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
          Write-Log ("[INFO] [{0}] Copying UNC source: {1}" -f $TypeName, $appSource)
          Copy-UncFolder -Source $appSource -Destination $packageDir
        }
        else {
          $packageDir = $appSource
          Write-Log ("[INFO] [{0}] local Source: {1}" -f $TypeName, $packageDir)
          if (-not (Test-Path -LiteralPath $packageDir)) {
            throw "Source not found: $packageDir"
          }
        }

        $localFile = Join-Path $packageDir ($appScript -replace '/', '\')

        if (-not (Test-Path -LiteralPath $localFile)) {
          throw "downloaded launcher not found: source=$appSource; expectedLocal=$localFile"
        }

        Unblock-File -Path $localFile -ErrorAction SilentlyContinue

        $extension = Get-InstallerExtensionFromPath -Path $localFile
        $workDir = Split-Path -Parent $localFile

        $proc = Invoke-InstallerProcess `
          -Extension $extension `
          -LocalFile $localFile `
          -WorkingDirectory $workDir

        $exitCode = $proc.ExitCode
        $success = ($exitCode -eq 0 -or $exitCode -eq 3010 -or ($needsReboot -and $exitCode -in @(1, 255)))
        Add-AppToLedger -AppName $appName

        if ($success) {
          Write-Log ("[OK] [{0}] {1} installed successfully ExitCode={2}" -f $TypeName, $appName, $exitCode)

          if ($needsReboot) {
            $script:AppsRequireReboot = $true
            Write-Log ("[INFO] [{0}] Reboot requested by application: {1}" -f $TypeName, $appName) -LocalOnly
            Invoke-RebootNow -Reason ("Application requested reboot: {0}" -f $appName)
          }
        }
        else {
          Write-Log ("[ERROR] [{0}] {1} failed ExitCode={2}" -f $TypeName, $appName, $exitCode)
        }
      }
      catch {
        Write-Log ("[ERROR] [{0}] {1} failed: {2}" -f $TypeName, $appName, $_.Exception.Message)
        Add-AppToLedger -AppName $appName
      }
    }
  }
  catch {
    Write-Log ("[ERROR] [{0}] getapps failed: {1}" -f $TypeName, $_.Exception.Message)
  }
}

# =========================
# Drivers
# =========================
function Resolve-ProvisionUrl {
  param([string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return ''
  }

  $value = $Url.Trim().Trim('"').Trim("'")
  if ($value.StartsWith('[baseurl]', [System.StringComparison]::OrdinalIgnoreCase)) {
    $value = $value -replace '^\[baseurl\]', $Config.WsBase
  }
  elseif ($value.StartsWith('/')) {
    $value = "$($Config.WsBase)$value"
  }

  if (Test-HttpUrl -Value $value) {
    return ($value -replace ' ', '%20')
  }

  $value = Expand-SystemEnvironmentVariables -Value $value
  return [uri]::UnescapeDataString($value)
}

function Get-ComputerModel {
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    try { return ([string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model).Trim() } catch {}
  }

  try { return ([string](Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).Model).Trim() } catch {}
  return ''
}

function Get-OperatingSystemName {
  $caption = ''
  if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
    try { $caption = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch {}
  }

  if ([string]::IsNullOrWhiteSpace($caption)) {
    try { $caption = [string](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).Caption } catch {}
  }

  return (($caption -replace 'Microsoft', '').Trim())
}

function Expand-Cabinet {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$DestinationPath
  )

  $process = Start-Process -FilePath 'expand.exe' -ArgumentList @('-F:*', $Path, $DestinationPath) -WorkingDirectory $DestinationPath -NoNewWindow -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Failed to expand CAB: $Path"
  }
}

function Expand-7ZipArchive {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$DestinationPath
  )

  $candidates = @()
  $cmd7z = Get-Command '7z.exe' -ErrorAction SilentlyContinue
  if ($cmd7z) { $candidates += $cmd7z.Source }
  $candidates += @(
    (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
    (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    (Join-Path $env:ProgramW6432 '7-Zip\7z.exe')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $exe7z = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($exe7z)) {
    throw '7z.exe not found'
  }

  $process = Start-Process -FilePath $exe7z -ArgumentList @('x', '-y', "-o$DestinationPath", $Path) -WorkingDirectory $DestinationPath -NoNewWindow -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw ("Failed to extract 7z: {0} ExitCode={1}" -f $Path, $process.ExitCode)
  }
}

function Invoke-PnpUtilCapture {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $captured = @()
  try {
    $captured = @(& pnputil.exe @Arguments 2>&1)
    $exitCode = [int]$LASTEXITCODE
  }
  catch {
    $captured = @($_)
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
  }

  [pscustomobject]@{
    ExitCode = $exitCode
    Output   = (($captured | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  }
}

function Install-InfDriversFromFolder {
  param([Parameter(Mandatory)][string]$Folder)

  if (-not (Test-Path -LiteralPath $Folder)) {
    throw "Driver folder not found: $Folder"
  }

  $infFiles = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue)
  Write-Log ("[INFO] Driver injection: found {0} INF file(s)" -f $infFiles.Count) -LocalOnly

  if ($infFiles.Count -eq 0) {
    return $false
  }

  $installed = 0
  $failed = 0
  $needReboot = $false

  foreach ($inf in $infFiles) {
    $result = Invoke-PnpUtilCapture -Arguments @('/add-driver', $inf.FullName, '/install')
    $text = ([string]$result.Output).ToLowerInvariant()

    if ($result.ExitCode -eq 3010) { $needReboot = $true }
    if ($result.ExitCode -eq 0 -or $result.ExitCode -eq 3010 -or
        $text -match 'driver package added successfully' -or
        $text -match 'already exists' -or
        $text -match 'already installed') {
      $installed++
      Write-Log ("[OK] Driver INF installed: {0}" -f $inf.Name) -LocalOnly
    }
    else {
      $failed++
      Write-Log ("[WARN] Driver INF failed: {0} ExitCode={1}" -f $inf.Name, $result.ExitCode) -LocalOnly
    }
  }

  Write-Log ("[OK] Driver injection summary: installed={0}; failed={1}" -f $installed, $failed)
  if ($failed -gt 0 -and $installed -eq 0) {
    throw ("pnputil add-driver failed for {0} INF file(s)" -f $failed)
  }

  $scan = Invoke-PnpUtilCapture -Arguments @('/scan-devices')
  if ($scan.ExitCode -eq 3010) { $needReboot = $true }
  if ($scan.ExitCode -ne 0 -and $scan.ExitCode -ne 3010) {
    if ($installed -eq 0) {
      Write-Log ("[WARN] pnputil scan-devices failed ExitCode={0}" -f $scan.ExitCode)
    }
  }

  return $needReboot
}

function Install-DriverInstallModePackages {
  param([Parameter(Mandatory)][string]$Folder)

  $packagePath = Join-Path $Folder 'INSTALL.CMD'
  if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    return $false
  }

  $needReboot = $false
  $workDir = Split-Path -Parent $packagePath
  Write-Log ("[INFO] Driver install-mode package: {0}" -f $packagePath)

  $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $packagePath) -WorkingDirectory $workDir -WindowStyle Hidden -Wait -PassThru

  if ($process.ExitCode -eq 3010) {
    $needReboot = $true
  }
  elseif ($process.ExitCode -ne 0) {
    throw ("Driver install-mode package failed ExitCode={0}: {1}" -f $process.ExitCode, $packagePath)
  }

  return $needReboot
}

function Install-Drivers {
  $driverLedgerId = 'DRIVERS'
  if (Test-AppAlreadyExecuted -AppName $driverLedgerId) {
    Write-Log '[SKIP] Driver package already installed' -LocalOnly
    return
  }

  $model = Get-ComputerModel
  $osName = Get-OperatingSystemName

  Write-Log ("[INFO] Driver model: {0}" -f $model)
  Write-Log ("[INFO] Driver OS: {0}" -f $osName)

  if ([string]::IsNullOrWhiteSpace($model)) {
    Write-Log '[WARN] No computer model detected: skipping drivers'
    return
  }

  $driverApiUrl = "{0}?name={1}&os={2}" -f $script:GetDriversApi, [uri]::EscapeDataString($model), [uri]::EscapeDataString($osName)
  $driverResponse = Invoke-ApiGetWithRetry -Url $driverApiUrl -Context 'getdrivers'

  if (-not $driverResponse.url) {
    Write-Log ("[INFO] No driver found for {0} / {1}" -f $model, $osName)
    return
  }

  $driverName = ([string]$driverResponse.name).Trim()
  if ([string]::IsNullOrWhiteSpace($driverName)) { $driverName = $model }

  $driverSourceUrl = ([string]$driverResponse.url)
  $driverUrl = Resolve-ProvisionUrl -Url $driverSourceUrl
  if ([string]::IsNullOrWhiteSpace($driverUrl)) {
    throw 'Driver URL returned by API is empty'
  }

  $missingDriverEnvVars = @(Get-MissingSystemEnvironmentVariables -Value $driverSourceUrl)
  if ($missingDriverEnvVars.Count -gt 0 -and -not (Test-HttpUrl -Value $driverUrl) -and -not (Test-UncPath -Value $driverUrl)) {
    Write-Log ("[INFO] Driver package skipped: unresolved environment variable(s) {0} in source: {1}" -f ($missingDriverEnvVars -join ', '), $driverSourceUrl)
    return
  }

  if (Test-Path -LiteralPath $Config.DriversFolder) {
    Remove-Item -LiteralPath $Config.DriversFolder -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Path $Config.DriversFolder -Force | Out-Null

  try {
    $driverUri = [uri]$driverUrl
    $extension = [System.IO.Path]::GetExtension($driverUri.AbsolutePath)
  }
  catch {
    $extension = [System.IO.Path]::GetExtension($driverUrl)
  }
  if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.ps1' }
  $extension = $extension.ToLowerInvariant()

  $safeDriverName = ($driverName -replace '[^\w\.-]', '_')
  if ([string]::IsNullOrWhiteSpace($safeDriverName)) { $safeDriverName = 'driver' }
  $packagePath = Join-Path $Config.DriversFolder ("{0}{1}" -f $safeDriverName, $extension)

  Write-Log ("[INFO] Downloading driver package: {0}" -f $driverName)
  Write-Log ("[INFO] Driver source: {0}" -f $driverUrl)
  if (Test-HttpUrl -Value $driverUrl) {
    Download-File -Url $driverUrl -Destination $packagePath
  }
  elseif (Test-UncPath -Value $driverUrl) {
    Copy-UncFile -Source $driverUrl -Destination $packagePath
    try { Unblock-File -Path $packagePath -ErrorAction SilentlyContinue } catch {}
  }
  else {
    if (-not (Test-Path -LiteralPath $driverUrl -PathType Leaf)) {
      throw "Driver local source not found: $driverUrl"
    }
    Copy-Item -LiteralPath $driverUrl -Destination $packagePath -Force
    try { Unblock-File -Path $packagePath -ErrorAction SilentlyContinue } catch {}
  }
  Write-Log ("[INFO] Driver package downloaded: {0}" -f $packagePath)

  $needReboot = $false
  switch ($extension) {
    '.zip' {
      Expand-Archive -Path $packagePath -DestinationPath $Config.DriversFolder -Force
      $needReboot = (Install-InfDriversFromFolder -Folder $Config.DriversFolder) -or $needReboot
      $needReboot = (Install-DriverInstallModePackages -Folder $Config.DriversFolder) -or $needReboot
    }
    '.cab' {
      Expand-Cabinet -Path $packagePath -DestinationPath $Config.DriversFolder
      $needReboot = (Install-InfDriversFromFolder -Folder $Config.DriversFolder) -or $needReboot
      $needReboot = (Install-DriverInstallModePackages -Folder $Config.DriversFolder) -or $needReboot
    }
    '.7z' {
      Expand-7ZipArchive -Path $packagePath -DestinationPath $Config.DriversFolder
      $needReboot = (Install-InfDriversFromFolder -Folder $Config.DriversFolder) -or $needReboot
      $needReboot = (Install-DriverInstallModePackages -Folder $Config.DriversFolder) -or $needReboot
    }
    '.exe' {
      $extractProc = Start-Process -FilePath $packagePath -ArgumentList @('-y', '-s', "-d=""$($Config.DriversFolder)""") -WorkingDirectory $Config.DriversFolder -WindowStyle Hidden -Wait -PassThru
      if ($extractProc.ExitCode -ne 0 -and $extractProc.ExitCode -ne 3010) {
        throw ("Driver SFX extraction failed ExitCode={0}" -f $extractProc.ExitCode)
      }
      $needReboot = ($extractProc.ExitCode -eq 3010) -or $needReboot
      $needReboot = (Install-InfDriversFromFolder -Folder $Config.DriversFolder) -or $needReboot
      $needReboot = (Install-DriverInstallModePackages -Folder $Config.DriversFolder) -or $needReboot
    }
    '.ps1' {
      $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packagePath) -WorkingDirectory $Config.DriversFolder -WindowStyle Hidden -Wait -PassThru
      if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ("Driver script failed ExitCode={0}" -f $process.ExitCode)
      }
      $needReboot = ($process.ExitCode -eq 3010) -or $needReboot
    }
    default {
      throw ("Unsupported driver package type: {0}" -f $extension)
    }
  }

  Add-AppToLedger -AppName $driverLedgerId
  [Environment]::SetEnvironmentVariable('DriversNeedReboot', 'YES', 'Machine')
  if ($needReboot) {
    Write-Log ("[INFO] Driver package installed with reboot request: {0}" -f $driverName)
  }
  else {
    Write-Log ("[OK] Driver package installed: {0}" -f $driverName)
  }
  Write-Log ("[INFO] Reboot requested after driver installation: {0}" -f $driverName)
  Invoke-RebootNow
}

try {
  Set-ProvisionStep -Step 'STEP 008' -Label 'Drivers'
  Show-Progress 'Drivers'
  Install-Drivers
}
catch {
  Write-Log ("[ERROR] Driver installation failed: {0}" -f $_.Exception.Message)
}

Set-ProvisionStep -Step 'STEP 009' -Label 'Applications'

if ([string]::IsNullOrWhiteSpace($ctx.Type)) {
  Write-Log '[WARN] No Type provided: skipping applications'
}
else {
  Install-AppsForType -TypeName $ctx.Type -Country $ctx.Country
}

# =========================
# Tanium tag
# =========================
Set-ProvisionStep -Step 'STEP 010' -Label 'Finalization'

if ([string]::IsNullOrWhiteSpace($ctx.Type)) {
  Write-Log '[WARN] Tanium tag skipped: missing Type'
}
else {
  try {
    Add-TaniumTag -Tag $ctx.Type
    Write-Log ("[OK] Tanium tag added: {0}" -f $ctx.Type) -LocalOnly
  }
  catch {
    Write-Log ("[ERROR] Tanium tag failed: {0}" -f $_.Exception.Message)
  }
}

Show-Progress 'End'

# =========================
# End-provisionning.ps1
# =========================
$endPath = Join-Path $env:TEMP 'endprovisionning.ps1'

try {
  Remove-Item -LiteralPath $endPath -Force -ErrorAction SilentlyContinue

  Download-File -Url $script:EndProvisionUrl -Destination $endPath

  if (-not (Test-Path -LiteralPath $endPath) -or (Get-Item -LiteralPath $endPath).Length -le 0) {
    throw "Downloaded file missing or empty: $endPath"
  }

  Unblock-File -Path $endPath -ErrorAction SilentlyContinue

  Set-ProvisionStep -Step 'STEP 011' -Label 'Endprovisionning'
  Show-Progress 'Endprovisionning'
  Write-Log '[INFO] Running endprovisionning.ps1' -LocalOnly

  $endProc = Start-Process `
    -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $endPath) `
    -WorkingDirectory (Split-Path -Parent $endPath) `
    -WindowStyle Normal `
    -Wait `
    -PassThru

  if ($endProc.ExitCode -eq 0) {
    Write-Log '[OK] endprovisionning.ps1 finished successfully'
  }
  else {
    Write-Log ("[ERROR] endprovisionning.ps1 failed ExitCode={0}" -f $endProc.ExitCode)
  }
}
catch {
  Write-Log ("[ERROR] Failed to run endprovisionning.ps1: {0}" -f $_.Exception.Message)
}

Write-Log 'END PROVISIONING'
