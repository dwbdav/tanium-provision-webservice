

# =========================
# CONFIG
# =========================
$Config = [ordered]@{
	ConfigJson    = 'X:\provision\config.json'
    LocalLogPath  = 'X:\provision\provision.log'
    TargetConfigJson = 'C:\provision\config.json'
	TaniumServerIp       = '10.42.129.71'
	
	TaniumOSDModulePath    = 'C:\_T\TaniumOSD'
	TaniumClientModulePath = 'C:\_T\TaniumClient'
  
}
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $Config.LocalLogPath) -Force
# -------------------------
# Optional Tanium modules
# -------------------------
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


function Load-ContextJson {
  if (-not (Test-Path -LiteralPath $Config.ConfigJson)) {
    Write-Log "[WARN] Context JSON not found: $($Config.ConfigJson)"
    return [pscustomobject]@{
      ComputerName = ''
      Type         = ''
      Keyboard     = ''
      Country      = ''
      Language     = ''
      Timezone     = ''
    }
  }

  try {
    $js = Get-Content -LiteralPath $Config.ConfigJson -Raw | ConvertFrom-Json -ErrorAction Stop

    return [pscustomobject]@{
      ComputerName = ([string]$js.computerName).Trim()
      Type         = ([string]$js.type).Trim()
      Keyboard     = ([string]$js.keyboard).Trim()
      Country      = ([string]$js.country).Trim().ToUpperInvariant()
      Language     = ([string]$js.language).Trim()
      Timezone     = ([string]$js.timezone).Trim()
    }
  }
  catch {
    Write-Log ("[ERROR] Reading context JSON: {0}" -f $_.Exception.Message)

    return [pscustomobject]@{
      ComputerName = ''
      Type         = ''
      Keyboard     = ''
      Country      = ''
      Language     = ''
      Timezone     = ''
    }
  }
}

function Set-ComputerNameInApi {
  param(
    [Parameter(Mandatory)]
    [psobject]$Context
  )

  if (-not $script:Serial -or $script:Serial -eq 'UNKNOWN') {
    Write-Log '[WARN] WS computer name update skipped: serial unknown'
    return
  }

  if ([string]::IsNullOrWhiteSpace($Context.ComputerName)) {
    Write-Log '[WARN] WS computer name update skipped: computer name empty'
    return
  }

  $setComputerUrl = "$($Config.WsBase)/setcomputer"
  $setComputerPayload = @{
    serial       = $script:Serial
    computerName = $Context.ComputerName
    type         = $Context.Type
    country      = $Context.Country
    language     = $Context.Language
    timezone     = $Context.Timezone
    keyboard     = $Context.Keyboard
  } | ConvertTo-Json -Compress

  try {
    Invoke-RestMethod `
      -Uri $setComputerUrl `
      -Method POST `
      -Body $setComputerPayload `
      -ContentType 'application/json' `
      -TimeoutSec 20 | Out-Null

    Write-Log ("[OK] WS computer name updated: {0}" -f $Context.ComputerName) -LocalOnly
  }
  catch {
    $responseBody = ''
    try {
      if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        if ($stream) {
          $reader = New-Object System.IO.StreamReader($stream)
          $responseBody = $reader.ReadToEnd()
          $reader.Close()
        }
      }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($responseBody)) {
      Write-Log ("[WARN] WS computer name update failed: {0}; Url={1}; Payload={2}" -f $_.Exception.Message, $setComputerUrl, $setComputerPayload)
    }
    else {
      Write-Log ("[WARN] WS computer name update failed: {0}; Body={1}; Url={2}; Payload={3}" -f $_.Exception.Message, $responseBody, $setComputerUrl, $setComputerPayload)
    }
  }
}

function Copy-ProvisionContextToC {
  $sourceDir = Split-Path -Parent $Config.ConfigJson
  $targetDir = Split-Path -Parent $Config.TargetConfigJson

  if (-not (Test-Path -LiteralPath $sourceDir)) {
    Write-Log "[WARN] Provision context source not found: $sourceDir"
    return
  }

  try {
    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $targetDir -Recurse -Force
    Write-Log "[OK] Provision context copied to: $targetDir" -LocalOnly
  }
  catch {
    Write-Log ("[WARN] Provision context copy failed: {0}" -f $_.Exception.Message)
  }
}

# =========================
# MAIN
# =========================
Write-Log 'STEP 003'

$ctx = Load-ContextJson

$countryDisplay = if ([string]::IsNullOrWhiteSpace($ctx.Country)) { '-' } else { $ctx.Country }
$langDisplay    = if ([string]::IsNullOrWhiteSpace($ctx.Language)) { '-' } else { $ctx.Language }
$tzDisplay      = if ([string]::IsNullOrWhiteSpace($ctx.Timezone)) { '-' } else { $ctx.Timezone }

Write-Log ("[INFO] Context: Name={0}; Type={1}; Kbd={2}; Country={3}; Lang={4}; Timezone={5}" -f `
  $ctx.ComputerName,$ctx.Type,$ctx.Keyboard,$countryDisplay,$langDisplay,$tzDisplay) -LocalOnly

Set-ComputerNameInApi -Context $ctx







# Patch unattend.xml
$xmlPath = 'C:\Windows\Panther\Unattend\unattend.xml'

if (-not (Test-Path -LiteralPath $xmlPath)) {
  Write-Log "[WARN] unattend.xml not found: $xmlPath"
}
else {
  try {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('ns', 'urn:schemas-microsoft-com:unattend')

    $changed = $false

    if (-not [string]::IsNullOrWhiteSpace($ctx.ComputerName)) {
      $node = $doc.SelectSingleNode("//ns:settings[@pass='specialize']/ns:component/ns:ComputerName", $ns)
      if ($node) {
        $node.InnerText = $ctx.ComputerName
        $changed = $true
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($ctx.Keyboard)) {
      $nodes = $doc.SelectNodes("//ns:InputLocale", $ns)
      foreach ($node in @($nodes)) {
        $node.InnerText = $ctx.Keyboard
        $changed = $true
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($ctx.Timezone)) {
      $nodes = $doc.SelectNodes("//ns:TimeZone", $ns)
      foreach ($node in @($nodes)) {
        $node.InnerText = $ctx.Timezone
        $changed = $true
      }
    }

    if ($changed) {
      $doc.Save($xmlPath)
      Write-Log "[OK] UNATTEND updated: $xmlPath"
    }
    else {
      Write-Log "[INFO] UNATTEND no change: $xmlPath"
    }
  }
  catch {
    Write-Log ("[ERROR] UNATTEND update failed: {0}" -f $_.Exception.Message)
  }
}















# Update Tanium install command in provision-os.ps1
$taniumServerIp = ([string]$Config.TaniumServerIp).Trim()

if ([string]::IsNullOrWhiteSpace($taniumServerIp)) {
  Write-Log '[INFO] TaniumServerIp empty - skipping Tanium command update'
}
else {
  $provisionPath = 'C:\_T\provision-os.ps1'

  if (-not (Test-Path $provisionPath)) {
    Write-Log "[WARN] provision-os.ps1 not found: $provisionPath"
  }
  else {
    try {
      $lines = @(Get-Content -Path $provisionPath)
      $targetIndex = -1

      for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like '*SetupClient.exe*' -and $lines[$i] -like '*KeyPath=$rootFolder\tanium-init.dat*') {
          $targetIndex = $i
          break
        }
      }

      if ($targetIndex -lt 0) {
        Write-Log "[WARN] Tanium command not found in $provisionPath"
      }
      else {
        $replacementLines = @(
          'New-Item -Path "C:\systools" -ItemType Directory -Force | Out-Null',
          '$process = Start-Process -FilePath "$rootFolder\SetupClient.exe" `',
          "    -ArgumentList @(`"/S`", `"/KeyPath=`$rootFolder\tanium-init.dat`", `"/ServerAddress=$taniumServerIp`", `"/D=C:\systools\tanium`") ``",
          '    -Wait -PassThru | Out-Null'
        )

        $updatedLines = for ($i = 0; $i -lt $lines.Count; $i++) {
          if ($i -eq $targetIndex) { $replacementLines } else { $lines[$i] }
        }

        Set-Content -Path $provisionPath -Value $updatedLines -Encoding UTF8
        Write-Log "[OK] Updated Tanium command in $provisionPath" -LocalOnly
      }
    }
    catch {
      Write-Log ("[ERROR] Update provision-os.ps1: {0}" -f $_.Exception.Message)
    }
  }
}

Write-Log 'STEP 004'
Copy-ProvisionContextToC
