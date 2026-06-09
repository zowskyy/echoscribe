@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-dotnet-sdk.ps1"
if errorlevel 1 goto failed

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\publish-echoscribe.ps1"
if errorlevel 1 goto failed

echo.
echo EchoScribe Windows package created.
echo %~dp0EchoScribe-Windows-x64.zip
echo.
pause
exit /b 0

:failed
echo.
echo EchoScribe Windows build failed.
echo.
pause
exit /b 1
