$ErrorActionPreference = 'Stop'

$ConfigJsonC  = 'C:\provision\config.json'
$LocalPath   = Join-Path $env:TEMP 'Customer-ext.ps1'
$TargetRoute = '/file/Provision/Customer.ps1'
$RetryCount  = 10
$RetryDelay  = 3
$TimeoutSec  = 20

function Get-WsBaseRequired {
    param([Parameter(Mandatory = $true)][string]$JsonPath)

    if (-not (Test-Path -LiteralPath $JsonPath)) {
        throw "Context JSON not found: $JsonPath"
    }

    try {
        $json = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to read context JSON: $($_.Exception.Message)"
    }

    $wsBase = [string]$json.wsBase
    if ([string]::IsNullOrWhiteSpace($wsBase)) {
        throw "wsBase missing in context JSON: $JsonPath"
    }

    return $wsBase.TrimEnd('/')
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
    $wsBase = Get-WsBaseRequired -JsonPath $ConfigJsonC
    $url = "$wsBase$TargetRoute"
    Download-WithRetry -Url $url -Destination $LocalPath

    Write-Host ("Executing: {0}" -f $LocalPath)
    & $LocalPath
    exit $LASTEXITCODE
}
catch {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

