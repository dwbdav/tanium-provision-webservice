<#
.SYNOPSIS
  Prepare Python virtual environment in C:\WebService\venv for C:\WebService.

.DESCRIPTION
  - Install the bundled Python 3.13 installer when the fixed Python path is missing
  - Verify the bundled installer SHA-256 before execution
  - Use fixed Python path: C:\Program Files\Python313\python.exe
  - Ensure C:\WebService exists
  - Create or reuse C:\WebService\venv
  - Upgrade pip/setuptools/wheel inside the venv
  - Install Flask, requests, fastapi, uvicorn, duckdb inside the venv
  - Write requirements.txt in C:\WebService
  - Validate imports with the venv Python
#>

$ErrorActionPreference = 'Stop'

$BasePath         = 'C:\WebService'
$VenvPath         = Join-Path $BasePath 'venv'
$VenvPython       = Join-Path $VenvPath 'Scripts\python.exe'
$RequirementsPath = Join-Path $BasePath 'requirements.txt'
$PythonExe        = 'C:\Program Files\Python313\python.exe'
$PythonInstaller  = Join-Path $PSScriptRoot 'python-3.13.13-amd64.exe'
$PythonInstallerSha256 = '3C9C81D80F91C002CED86D645422D81432C68C7D9B6B0E974768CA2E449A4D00'

Write-Host "Checking system Python..." -ForegroundColor Cyan
if (-not (Test-Path $PythonExe)) {
    Write-Host "Python 3.13 is not installed. Checking bundled installer..." -ForegroundColor Yellow
    if (-not (Test-Path $PythonInstaller)) {
        throw "Bundled Python installer not found: $PythonInstaller"
    }

    $ActualInstallerSha256 = (Get-FileHash -LiteralPath $PythonInstaller -Algorithm SHA256).Hash
    if ($ActualInstallerSha256 -ne $PythonInstallerSha256) {
        throw "Bundled Python installer checksum mismatch. Expected $PythonInstallerSha256, got $ActualInstallerSha256"
    }

    Write-Host "Installing bundled Python 3.13 for all users..." -ForegroundColor Cyan
    $InstallArguments = '/quiet InstallAllUsers=1 PrependPath=0 Include_test=0 TargetDir="C:\Program Files\Python313"'
    $InstallProcess = Start-Process -FilePath $PythonInstaller -ArgumentList $InstallArguments -Wait -PassThru
    if ($InstallProcess.ExitCode -notin @(0, 3010)) {
        throw "Python installer failed with exit code $($InstallProcess.ExitCode)"
    }

    if (-not (Test-Path $PythonExe)) {
        throw "Python installation completed but executable was not found: $PythonExe"
    }
}

Write-Host "Using Python executable: $PythonExe" -ForegroundColor Green

Write-Host "Checking project base path..." -ForegroundColor Cyan
if (-not (Test-Path $BasePath)) {
    throw "Base path not found: $BasePath"
}

Write-Host "Preparing virtual environment..." -ForegroundColor Cyan
if (-not (Test-Path $VenvPython)) {
    Write-Host "Creating virtual environment in $VenvPath ..." -ForegroundColor Cyan
    & $PythonExe -m venv $VenvPath
} else {
    Write-Host "Virtual environment already exists in $VenvPath, reusing it..." -ForegroundColor Yellow
}

if (-not (Test-Path $VenvPython)) {
    throw "Venv python not found after creation: $VenvPython"
}

Write-Host "Upgrading pip / setuptools / wheel in venv..." -ForegroundColor Cyan
& $VenvPython -m pip install --upgrade pip setuptools wheel

$Packages = @(
    'flask'
    'requests'
    'fastapi'
    'uvicorn'
    'duckdb'
)

Write-Host "Installing packages in venv: $($Packages -join ', ')" -ForegroundColor Cyan
& $VenvPython -m pip install @Packages

Write-Host "Writing requirements.txt to $RequirementsPath ..." -ForegroundColor Cyan
@'
flask
requests
fastapi
uvicorn
duckdb
'@ | Set-Content -Path $RequirementsPath -Encoding ascii

Write-Host "Validating imports from venv..." -ForegroundColor Cyan
& $VenvPython -c "import flask, requests, fastapi, uvicorn, duckdb; print('OK: all imports succeeded')"

Write-Host "Environment successfully prepared." -ForegroundColor Green
Write-Host "Venv Python: $VenvPython" -ForegroundColor Green
