@echo off
setlocal
title EchoScribe Uninstall

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall-echoscribe.ps1" %*
set "exit_code=%ERRORLEVEL%"
echo.
if "%exit_code%"=="0" (
  echo EchoScribe uninstall completed.
) else (
  echo EchoScribe uninstall failed.
)
echo.
pause
exit /b %exit_code%
