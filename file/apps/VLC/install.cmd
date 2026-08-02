@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "LOG_DIR=C:\SysTools\Logs"
set "LOG_FILE=%LOG_DIR%\VLC.log"
set "SETUP=%SCRIPT_DIR%vlc-3.0.23-win64.exe"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

echo %DATE% %TIME% - Start VLC install >> "%LOG_FILE%"
echo %DATE% %TIME% - WorkingDirectory="%CD%" >> "%LOG_FILE%"

if not exist "%SETUP%" (
    echo %DATE% %TIME% - ERROR: installer not found: "%SETUP%" >> "%LOG_FILE%"
    exit /b 99
)

"%SETUP%" /S >> "%LOG_FILE%" 2>&1
set "EXITCODE=%ERRORLEVEL%"

echo %DATE% %TIME% - ExitCode=%EXITCODE% >> "%LOG_FILE%"
exit /b %EXITCODE%
