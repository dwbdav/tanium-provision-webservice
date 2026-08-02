@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "LOG_DIR=C:\SysTools\Logs"
set "LOG_FILE=%LOG_DIR%\GoogleChromeEnterprise.log"
set "MSI=%SCRIPT_DIR%GoogleChromeStandaloneEnterprise64.msi"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

echo %DATE% %TIME% - Start Google Chrome Enterprise install >> "%LOG_FILE%"
echo %DATE% %TIME% - WorkingDirectory="%CD%" >> "%LOG_FILE%"

if not exist "%MSI%" (
    echo %DATE% %TIME% - ERROR: MSI not found: "%MSI%" >> "%LOG_FILE%"
    exit /b 99
)

msiexec.exe /i "%MSI%" /qn /norestart /L*v "%LOG_DIR%\GoogleChromeEnterprise-msi.log"
set "EXITCODE=%ERRORLEVEL%"

echo %DATE% %TIME% - ExitCode=%EXITCODE% >> "%LOG_FILE%"
exit /b %EXITCODE%
