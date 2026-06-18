# =========================
# IMPORTANT: WS BASE URL
# =========================
# wsBase is defined only in Customer-PE-Pre.ps1 on the bundle.

# -------------------------
# Config
# -------------------------
$Config = [ordered]@{
    ConfigJson   = 'C:\provision\config.json'
    LocalLogPath = 'C:\provision\provision.log'
	
	TaniumOSDModulePath    = 'C:\_T\TaniumOSD'
	TaniumClientModulePath = 'C:\_T\TaniumClient'

}
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $Config.LocalLogPath) -Force

# -------------------------
# Optional Tanium modules
# -------------------------
$osdAvailable = $false

if (Test-Path $Config.TaniumOSDModulePath) {
  try {
    Import-Module $Config.TaniumOSDModulePath -ErrorAction Stop
    if (Get-Command Set-OSDProgressDisplay -ErrorAction SilentlyContinue) {
      $osdAvailable = $true
    }
  } catch {}
}

# Numéro de série (uniforme, simple)
$script:Serial = $null
try { $script:Serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch {}
if (-not $script:Serial) {
    try { $script:Serial = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).IdentifyingNumber } catch {}
}
if (-not $script:Serial) {
    try { $script:Serial = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch {}
}
$script:Serial = if ($script:Serial) { $script:Serial.Trim().ToUpper() -replace '\s','' } else { 'UNKNOWN' }

# wsbase 
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


# -------------------------
# Logger
# -------------------------
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
# -------------------------
# Active IPv4 address
# -------------------------
function Get-ActiveIPv4 {
  # 1) IPv4 bound to the interface carrying the default route (the active one)
  try {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
             Sort-Object RouteMetric, ifMetric | Select-Object -First 1
    if ($route) {
      $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex -ErrorAction Stop |
             Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
             Select-Object -First 1).IPAddress
      if ($ip) { return $ip }
    }
  } catch {}

  # 2) First non-loopback, non-APIPA IPv4
  try {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
           Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
           Select-Object -First 1).IPAddress
    if ($ip) { return $ip }
  } catch {}

  # 3) Fallback for environments without the Net* cmdlets
  try {
    $ip = (Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
           Where-Object { $_.IPEnabled -and $_.IPAddress } |
           ForEach-Object { $_.IPAddress } |
           Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^(127\.|169\.254\.)' } |
           Select-Object -First 1)
    if ($ip) { return $ip }
  } catch {}

  return $null
}

# -------------------------
# Example usage
# -------------------------
Write-Log 'STEP 005'

$activeIp = Get-ActiveIPv4
if ($activeIp) {
  Write-Log ("IP address : {0}" -f $activeIp)
} else {
  Write-Log '[WARN] Active IPv4 address not found'
}

Write-Log 'STEP 006'
