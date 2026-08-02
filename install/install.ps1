<#
.SYNOPSIS
  Prepare Python virtual environment in C:\WebService\venv for C:\WebService.

.DESCRIPTION
  - Require Python 3.13 to be installed manually in C:\Program Files\Python313
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

Write-Host "Checking system Python..." -ForegroundColor Cyan
if (-not (Test-Path $PythonExe)) {
    throw "Python 3.13 is required. Install install\python-3.13.13-amd64.exe manually for all users in C:\Program Files\Python313, then run this script again."
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
