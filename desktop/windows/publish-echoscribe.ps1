$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dotnet = Join-Path $root '.dotnet-sdk\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) {
    $dotnet = 'dotnet'
}

$publishDir = Join-Path $root 'publish'
$nativePublishDir = Join-Path $publishDir 'native-host'
$extensionPublishDir = Join-Path $publishDir 'chrome-extension'
$extensionSourceDir = Join-Path (Split-Path -Parent $root) 'browser-extension'

New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
New-Item -ItemType Directory -Force -Path $nativePublishDir | Out-Null

& $dotnet publish (Join-Path $root 'EchoScribe.Windows.csproj') `
    -c Release `
    -r win-x64 `
    --self-contained true `
    /p:PublishSingleFile=true `
    /p:EnableCompressionInSingleFile=true `
    -o $publishDir

& $dotnet publish (Join-Path $root 'native-host\EchoScribe.NativeHost.csproj') `
    -c Release `
    -r win-x64 `
    --self-contained true `
    /p:PublishSingleFile=true `
    /p:EnableCompressionInSingleFile=true `
    -o $nativePublishDir

if (Test-Path -LiteralPath $extensionPublishDir) {
    Remove-Item -LiteralPath $extensionPublishDir -Recurse -Force
}
Copy-Item -LiteralPath $extensionSourceDir -Destination $extensionPublishDir -Recurse

$appsettings = Join-Path $root 'appsettings.json'
if (-not (Test-Path -LiteralPath $appsettings)) {
    $appsettings = Join-Path $root 'appsettings.template.json'
}
Copy-Item -LiteralPath $appsettings -Destination (Join-Path $publishDir 'appsettings.json') -Force
Copy-Item -LiteralPath (Join-Path $root 'appsettings.template.json') -Destination (Join-Path $publishDir 'appsettings.template.json') -Force

Get-ChildItem -LiteralPath $publishDir | Select-Object FullName, Length, LastWriteTime
