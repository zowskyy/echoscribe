@echo off
setlocal
title EchoScribe Setup

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-echoscribe.ps1" %*
set "exit_code=%ERRORLEVEL%"
echo.
if "%exit_code%"=="0" (
  echo EchoScribe installation completed.
) else (
  echo EchoScribe installation failed.
)
echo.
pause
exit /b %exit_code%
