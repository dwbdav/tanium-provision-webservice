@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "SOURCE_SCRIPT=%SCRIPT_DIR%Customer-TypeApps-GUI.ps1"
set "SOURCE_INI=%SCRIPT_DIR%Customer-TypeApps-GUI.ini"
set "PUBLIC_DESKTOP=%PUBLIC%\Desktop"
set "TARGET_SCRIPT=%PUBLIC_DESKTOP%\Customer-TypeApps-GUI.ps1"
set "TARGET_INI=%PUBLIC_DESKTOP%\Customer-TypeApps-GUI.ini"
set "LOG_DIR=C:\SysTools\Logs"
set "LOG_FILE=%LOG_DIR%\PostypeGUIstart.log"
set "EXITCODE=0"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
echo %DATE% %TIME% - Start PostypeGUIstart >> "%LOG_FILE%"

if not exist "%SOURCE_SCRIPT%" (
  echo %DATE% %TIME% - ERROR: source script not found: "%SOURCE_SCRIPT%" >> "%LOG_FILE%"
  set "EXITCODE=1"
  goto :END
)

if not exist "%SOURCE_INI%" (
  echo %DATE% %TIME% - ERROR: source INI not found: "%SOURCE_INI%" >> "%LOG_FILE%"
  set "EXITCODE=2"
  goto :END
)

if not exist "%PUBLIC_DESKTOP%" (
  echo %DATE% %TIME% - ERROR: public desktop not found: "%PUBLIC_DESKTOP%" >> "%LOG_FILE%"
  set "EXITCODE=3"
  goto :END
)

copy /Y "%SOURCE_SCRIPT%" "%TARGET_SCRIPT%" >nul
if errorlevel 1 (
  echo %DATE% %TIME% - ERROR: failed to copy script to public desktop. >> "%LOG_FILE%"
  set "EXITCODE=4"
  goto :END
)

copy /Y "%SOURCE_INI%" "%TARGET_INI%" >nul
if errorlevel 1 (
  echo %DATE% %TIME% - ERROR: failed to copy INI file to public desktop. >> "%LOG_FILE%"
  set "EXITCODE=5"
  goto :END
)

echo %DATE% %TIME% - Script copied to: "%TARGET_SCRIPT%" >> "%LOG_FILE%"
echo %DATE% %TIME% - INI copied to: "%TARGET_INI%" >> "%LOG_FILE%"
echo %DATE% %TIME% - End PostypeGUIstart OK >> "%LOG_FILE%"

:END
echo %DATE% %TIME% - ExitCode: %EXITCODE% >> "%LOG_FILE%"
exit /b %EXITCODE%
