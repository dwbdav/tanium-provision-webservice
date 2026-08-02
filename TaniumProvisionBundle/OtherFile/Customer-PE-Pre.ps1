$ErrorActionPreference = 'Stop'

# Source of truth for wsBase used by all Customer*.ps1 scripts
$WsBase     = 'https://provision.infra-lab.fr/'
$WsBaseTrim = $WsBase.TrimEnd('/')

$ConfigJsonX  = 'x:\provision\config.json'
$LocalPath   = Join-Path $env:TEMP 'Customer-PE-Pre.ps1'
$TargetRoute = '/file/Provision/Customer-PE-Pre.ps1'
$RetryCount  = 10
$RetryDelay  = 3
$TimeoutSec  = 20

function Save-WsBaseToConfig {
    param(
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$BaseUrl
    )

    $dir = Split-Path -Parent $JsonPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $data = [ordered]@{}
    if (Test-Path -LiteralPath $JsonPath) {
        try {
            $ctx = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
            foreach ($prop in @($ctx.PSObject.Properties)) {
                $data[$prop.Name] = $prop.Value
            }
        } catch {
            $data = [ordered]@{}
        }
    }

    $data['wsBase'] = $BaseUrl
    [pscustomobject]$data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
    Write-Host ("Context saved to: {0}" -f $JsonPath)
}

function Download-WithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        Write-Host ("Downloading from {0} (attempt {1}/{2})..." -f $Url, $attempt, $RetryCount)
        try {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec $TimeoutSec

            if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -gt 0)) {
                try { Unblock-File -Path $Destination -ErrorAction SilentlyContinue } catch {}
                Write-Host ("Saved to: {0}" -f $Destination)
                return
            }

            throw "File missing or empty after download."
        }
        catch {
            Write-Host ("Download failed: {0}" -f $_.Exception.Message)
            if ($attempt -lt $RetryCount) { Start-Sleep -Seconds $RetryDelay }
        }
    }

    throw "File could not be downloaded after $RetryCount attempts."
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

try {
    Save-WsBaseToConfig -JsonPath $ConfigJsonX -BaseUrl $WsBaseTrim

    $url = "$WsBaseTrim$TargetRoute"
    Download-WithRetry -Url $url -Destination $LocalPath

    Write-Host ("Executing: {0}" -f $LocalPath)
    & $LocalPath
    exit $LASTEXITCODE
}
catch {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
