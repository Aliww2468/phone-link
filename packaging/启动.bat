@echo off
setlocal
cd /d "%~dp0"
title PhoneLink

set "NODE=%~dp0node\node.exe"
if not exist "%NODE%" set "NODE="
if not defined NODE (
  where node >nul 2>nul
  if errorlevel 1 (
    echo.
    echo   Node.js runtime was not found.
    echo   Please run the installer first:  install.bat
    echo.
    pause
    exit /b 1
  )
  set "NODE=node"
)

echo.
echo   PhoneLink receiver is starting...
echo   Close this window to stop it.  Ctrl+C also works.
echo.
"%NODE%" "%~dp0pc\server.js"
echo.
echo   Receiver stopped.
pause
