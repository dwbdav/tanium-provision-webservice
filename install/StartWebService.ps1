$ErrorActionPreference = 'Stop'

$BasePath   = 'C:\Webservice'
$VenvPython = 'c:\WebService\venv\Scripts\python.exe'
$AppPath    = Join-Path $BasePath 'app.py'

if (-not (Test-Path $BasePath)) {
    throw "Base path not found: $BasePath"
}
if (-not (Test-Path $VenvPython)) {
    throw "Venv python not found: $VenvPython"
}
if (-not (Test-Path $AppPath)) {
    throw "Application not found: $AppPath"
}

Set-Location $BasePath

# Accès en HTTP (pas de reverse proxy HTTPS ici) : le cookie de session
# ne doit PAS être 'Secure', sinon le navigateur le refuse et le login boucle.
#$env:WS_COOKIE_SECURE = '0'

while ($true) {
    Write-Host "Starting Web Service without GUI"
    Write-Host "Ready page: http://127.0.0.1:12176/"
    & $VenvPython $AppPath
    Start-Sleep -Seconds 3
}
