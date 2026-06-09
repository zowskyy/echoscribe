param(
    [string]$SdkVersion = '8.0.421'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ((Split-Path -Leaf $scriptRoot) -eq 'scripts') {
    Split-Path -Parent $scriptRoot
} else {
    $scriptRoot
}
$installDir = Join-Path $root '.dotnet-sdk'
$dotnet = Join-Path $installDir 'dotnet.exe'

if (Test-Path -LiteralPath $dotnet) {
    $installedVersion = & $dotnet --version
    if ($LASTEXITCODE -ne 0) {
        throw "Existing local dotnet failed: $dotnet"
    }
    Write-Host "Local .NET SDK already installed: $installedVersion"
    Write-Host $dotnet
    exit 0
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$installer = Join-Path $env:TEMP "echoscribe-dotnet-install.ps1"
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer

& powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
    -Version $SdkVersion `
    -InstallDir $installDir `
    -NoPath

if ($LASTEXITCODE -ne 0) {
    throw "dotnet-install.ps1 failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $dotnet)) {
    throw "dotnet.exe was not created at $dotnet"
}

$installedVersion = & $dotnet --version
if ($LASTEXITCODE -ne 0) {
    throw "Installed dotnet failed: $dotnet"
}

Write-Host "Installed local .NET SDK: $installedVersion"
Write-Host $dotnet
