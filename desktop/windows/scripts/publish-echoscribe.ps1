param(
    [switch]$IncludeLocalSettings
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ((Split-Path -Leaf $scriptRoot) -eq 'scripts') {
    Split-Path -Parent $scriptRoot
} else {
    $scriptRoot
}
$localDotnet = Join-Path $root '.dotnet-sdk\dotnet.exe'
if (Test-Path -LiteralPath $localDotnet) {
    $dotnet = $localDotnet
} else {
    $dotnetCommand = Get-Command 'dotnet' -ErrorAction SilentlyContinue
    if (-not $dotnetCommand) {
        throw 'dotnet was not found. Run .\install.cmd first or .\scripts\install-dotnet-sdk.ps1 manually.'
    }
    $dotnet = $dotnetCommand.Source
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Assert-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected build artifact was not created: $Path"
    }
}

$publishDir = Join-Path $root 'publish'
$nativePublishDir = Join-Path $publishDir 'native-host'
$extensionPublishDir = Join-Path $publishDir 'chrome-extension'
$publishScriptsDir = Join-Path $publishDir 'scripts'
$extensionSourceDir = Join-Path (Split-Path -Parent $root) 'browser-extension'
$packagePath = Join-Path $root 'EchoScribe-Windows-x64.zip'

if (Test-Path -LiteralPath $publishDir) {
    Remove-Item -LiteralPath $publishDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
New-Item -ItemType Directory -Force -Path $nativePublishDir | Out-Null

Invoke-CheckedCommand -FilePath $dotnet -Arguments @(
    'publish',
    (Join-Path $root 'EchoScribe.Windows.csproj'),
    '-c',
    'Release',
    '-r',
    'win-x64',
    '--self-contained',
    'true',
    '/p:PublishSingleFile=true',
    '/p:EnableCompressionInSingleFile=true',
    '-o',
    $publishDir
)

Invoke-CheckedCommand -FilePath $dotnet -Arguments @(
    'publish',
    (Join-Path $root 'native-host\EchoScribe.NativeHost.csproj'),
    '-c',
    'Release',
    '-r',
    'win-x64',
    '--self-contained',
    'true',
    '/p:PublishSingleFile=true',
    '/p:EnableCompressionInSingleFile=true',
    '-o',
    $nativePublishDir
)

Assert-File (Join-Path $publishDir 'EchoScribe.exe')
Assert-File (Join-Path $nativePublishDir 'EchoScribe.NativeHost.exe')

if (Test-Path -LiteralPath $extensionPublishDir) {
    Remove-Item -LiteralPath $extensionPublishDir -Recurse -Force
}
Copy-Item -LiteralPath $extensionSourceDir -Destination $extensionPublishDir -Recurse

$appsettingsTemplate = Join-Path $root 'appsettings.template.json'
$appsettingsSource = $appsettingsTemplate
if ($IncludeLocalSettings) {
    $localAppsettings = Join-Path $root 'appsettings.json'
    if (Test-Path -LiteralPath $localAppsettings) {
        $appsettingsSource = $localAppsettings
        Write-Warning 'Including local appsettings.json. Do not upload this package to GitHub releases.'
    } else {
        Write-Warning 'IncludeLocalSettings was set, but appsettings.json was not found. Using appsettings.template.json.'
    }
}
Copy-Item -LiteralPath $appsettingsSource -Destination (Join-Path $publishDir 'appsettings.json') -Force
Copy-Item -LiteralPath $appsettingsTemplate -Destination (Join-Path $publishDir 'appsettings.template.json') -Force
New-Item -ItemType Directory -Force -Path $publishScriptsDir | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'install.cmd') -Destination (Join-Path $publishDir 'install.cmd') -Force
Copy-Item -LiteralPath (Join-Path $scriptRoot 'install-echoscribe.ps1') -Destination (Join-Path $publishScriptsDir 'install-echoscribe.ps1') -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $publishDir 'README-Windows.md') -Force

if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Force
}
Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $packagePath -Force

Get-ChildItem -LiteralPath $publishDir | Select-Object FullName, Length, LastWriteTime
Write-Host "Package: $packagePath"
