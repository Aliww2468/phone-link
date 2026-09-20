@echo off
setlocal
cd /d "%~dp0"
title PhoneLink - phone message receiver

set "NODE=node"
where node >nul 2>nul
if errorlevel 1 (
  if exist "C:\Program Files\nodejs\node.exe" (
    set "NODE=C:\Program Files\nodejs\node.exe"
  ) else (
    echo.
    echo   Node.js was not found.
    echo   Install it from https://nodejs.org/ and run this again.
    echo.
    pause
    exit /b 1
  )
)

"%NODE%" "%~dp0server.js"
set "CODE=%ERRORLEVEL%"
echo.
if not "%CODE%"=="0" echo   PhoneLink exited with code %CODE%.
pause
