param(
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ((Split-Path -Leaf $scriptRoot) -eq 'scripts') {
    Split-Path -Parent $scriptRoot
} else {
    $scriptRoot
}
$nativeHostName = 'de.echoscribe.nativehost'
$firefoxExtensionId = 'echoscribe@wean.de'

function Write-ColorLine {
    param(
        [string]$Text = '',
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    if ($Text.Length -eq 0) {
        Write-Host ''
        return
    }

    Write-Host $Text -ForegroundColor $Color
}

function Test-PackageRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (
        (Test-Path -LiteralPath (Join-Path $Path 'native-host\EchoScribe.NativeHost.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'chrome-extension\manifest.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'firefox-extension\manifest.json') -PathType Leaf)
    )
}

function Resolve-BrowserAssets {
    if (Test-PackageRoot -Path $root) {
        return [pscustomobject]@{
            ChromiumExtensionDirectory = Join-Path $root 'chrome-extension'
            FirefoxExtensionDirectory = Join-Path $root 'firefox-extension'
            NativeHost = Join-Path $root 'native-host\EchoScribe.NativeHost.exe'
        }
    }

    $publishRoot = Join-Path $root 'publish'
    if (Test-PackageRoot -Path $publishRoot) {
        return [pscustomobject]@{
            ChromiumExtensionDirectory = Join-Path $publishRoot 'chrome-extension'
            FirefoxExtensionDirectory = Join-Path $publishRoot 'firefox-extension'
            NativeHost = Join-Path $publishRoot 'native-host\EchoScribe.NativeHost.exe'
        }
    }

    $desktopRoot = Split-Path -Parent $root
    $assets = [pscustomobject]@{
        ChromiumExtensionDirectory = Join-Path $desktopRoot 'browser-extension'
        FirefoxExtensionDirectory = Join-Path $desktopRoot 'firefox-extension'
        NativeHost = Join-Path $root 'native-host\bin\Release\net8.0\win-x64\publish\EchoScribe.NativeHost.exe'
    }

    if (
        (Test-Path -LiteralPath (Join-Path $assets.ChromiumExtensionDirectory 'manifest.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $assets.FirefoxExtensionDirectory 'manifest.json') -PathType Leaf) -and
        (Test-Path -LiteralPath $assets.NativeHost -PathType Leaf)
    ) {
        return $assets
    }

    throw 'EchoScribe browser assets were not found. Run .\install.cmd or .\scripts\publish-echoscribe.ps1 first.'
}

function Get-ChromeExtensionId {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    if (-not $manifest.key) {
        throw 'The Chromium extension manifest needs a key field for a stable extension id.'
    }

    $publicKey = [Convert]::FromBase64String($manifest.key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($publicKey)
    $builder = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 16; $i++) {
        [void]$builder.Append([char]([int][char]'a' + (($hash[$i] -shr 4) -band 0x0f)))
        [void]$builder.Append([char]([int][char]'a' + ($hash[$i] -band 0x0f)))
    }
    return $builder.ToString()
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Register-ChromiumNativeHost {
    param(
        [Parameter(Mandatory = $true)][string]$NativeHostExe,
        [Parameter(Mandatory = $true)][string]$ExtensionManifestPath
    )

    $extensionId = Get-ChromeExtensionId -ManifestPath $ExtensionManifestPath
    $manifestPath = Join-Path (Split-Path -Parent $NativeHostExe) "$nativeHostName.json"
    $hostManifest = [ordered]@{
        name = $nativeHostName
        description = 'EchoScribe Web Summary Native Host'
        path = $NativeHostExe
        type = 'stdio'
        allowed_origins = @("chrome-extension://$extensionId/")
    }
    Write-Utf8NoBom -Path $manifestPath -Value (($hostManifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine)

    $registryBases = @(
        'Software\Google\Chrome\NativeMessagingHosts',
        'Software\Chromium\NativeMessagingHosts',
        'Software\Microsoft\Edge\NativeMessagingHosts',
        'Software\BraveSoftware\Brave-Browser\NativeMessagingHosts'
    )
    $registered = @()
    foreach ($base in $registryBases) {
        $path = "$base\$nativeHostName"
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path, $true)
        if (-not $key) {
            throw "Registry key could not be created: HKCU:\$path"
        }
        $key.SetValue('', $manifestPath, [Microsoft.Win32.RegistryValueKind]::String)
        $key.Dispose()
        $registered += "HKCU:\$path"
    }

    return [pscustomobject]@{
        ExtensionId = $extensionId
        Manifest = $manifestPath
        Registry = $registered
    }
}

function Register-FirefoxNativeHost {
    param([Parameter(Mandatory = $true)][string]$NativeHostExe)

    $manifestPath = Join-Path (Split-Path -Parent $NativeHostExe) "$nativeHostName.firefox.json"
    $hostManifest = [ordered]@{
        name = $nativeHostName
        description = 'EchoScribe Web Summary Native Host'
        path = $NativeHostExe
        type = 'stdio'
        allowed_extensions = @($firefoxExtensionId)
    }
    Write-Utf8NoBom -Path $manifestPath -Value (($hostManifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine)

    $registryPath = "Software\Mozilla\NativeMessagingHosts\$nativeHostName"
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath, $true)
    if (-not $key) {
        throw "Registry key could not be created: HKCU:\$registryPath"
    }
    $key.SetValue('', $manifestPath, [Microsoft.Win32.RegistryValueKind]::String)
    $key.Dispose()

    return [pscustomobject]@{
        ExtensionId = $firefoxExtensionId
        Manifest = $manifestPath
        Registry = "HKCU:\$registryPath"
    }
}

function First-ExistingFile {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }
    return $null
}

function Browser-Target {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ExtensionPath,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    return [pscustomobject]@{
        Name = $Name
        Url = $Url
        ExtensionPath = $ExtensionPath
        Executable = First-ExistingFile -Paths $Paths
    }
}

function Get-BrowserSetupTargets {
    param(
        [Parameter(Mandatory = $true)][string]$ChromiumExtensionDirectory,
        [Parameter(Mandatory = $true)][string]$FirefoxExtensionDirectory
    )

    $programFilesX86 = ${env:ProgramFiles(x86)}
    return @(
        Browser-Target -Name 'Google Chrome' -Url 'chrome://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        ),
        Browser-Target -Name 'Microsoft Edge' -Url 'edge://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
        ),
        Browser-Target -Name 'Brave' -Url 'brave://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'BraveSoftware\Brave-Browser\Application\brave.exe' }),
            (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
        ),
        Browser-Target -Name 'Chromium' -Url 'chrome://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Chromium\Application\chrome.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Chromium\Application\chrome.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Chromium\Application\chrome.exe')
        ),
        Browser-Target -Name 'Firefox' -Url 'about:debugging#/runtime/this-firefox' -ExtensionPath $FirefoxExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Mozilla Firefox\firefox.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
        )
    )
}

function Open-BrowserSetup {
    param(
        [Parameter(Mandatory = $true)][string]$ChromiumExtensionDirectory,
        [Parameter(Mandatory = $true)][string]$FirefoxExtensionDirectory
    )

    Start-Process $ChromiumExtensionDirectory
    Start-Process $FirefoxExtensionDirectory

    $opened = @()
    foreach ($target in (Get-BrowserSetupTargets -ChromiumExtensionDirectory $ChromiumExtensionDirectory -FirefoxExtensionDirectory $FirefoxExtensionDirectory)) {
        if ($target.Executable) {
            Start-Process -FilePath $target.Executable -ArgumentList $target.Url
            $opened += $target.Name
        }
    }

    if ($opened.Count -eq 0) {
        Write-ColorLine 'No supported browser executable was found for opening the extension setup page automatically.' Yellow
    } else {
        Write-ColorLine "Opened extension setup page for: $($opened -join ', ')" Cyan
    }
}

$assets = Resolve-BrowserAssets
$chromiumManifestPath = Join-Path $assets.ChromiumExtensionDirectory 'manifest.json'
$firefoxManifestPath = Join-Path $assets.FirefoxExtensionDirectory 'manifest.json'
if (-not (Test-Path -LiteralPath $chromiumManifestPath -PathType Leaf)) {
    throw "Chromium extension manifest not found: $chromiumManifestPath"
}
if (-not (Test-Path -LiteralPath $firefoxManifestPath -PathType Leaf)) {
    throw "Firefox extension manifest not found: $firefoxManifestPath"
}

Write-ColorLine 'Registering EchoScribe browser Native Messaging hosts...' Cyan
$chromium = Register-ChromiumNativeHost -NativeHostExe $assets.NativeHost -ExtensionManifestPath $chromiumManifestPath
$firefox = Register-FirefoxNativeHost -NativeHostExe $assets.NativeHost

$result = [ordered]@{
    ChromiumExtensionId = $chromium.ExtensionId
    ChromiumExtensionDirectory = $assets.ChromiumExtensionDirectory
    ChromiumNativeHostManifest = $chromium.Manifest
    ChromiumNativeHostRegistry = $chromium.Registry
    FirefoxExtensionId = $firefox.ExtensionId
    FirefoxExtensionManifest = $firefoxManifestPath
    FirefoxNativeHostManifest = $firefox.Manifest
    FirefoxNativeHostRegistry = $firefox.Registry
}

[pscustomobject]$result

Write-Host ''
Write-ColorLine 'Next steps:' Cyan
Write-ColorLine '  Chromium browsers: enable developer mode on the extensions page and load this folder:' Gray
Write-ColorLine "    $($assets.ChromiumExtensionDirectory)" DarkGray
Write-ColorLine '  Firefox: open about:debugging#/runtime/this-firefox and load this manifest as a temporary add-on:' Gray
Write-ColorLine "    $firefoxManifestPath" DarkGray

if (-not $NoOpen) {
    Open-BrowserSetup -ChromiumExtensionDirectory $assets.ChromiumExtensionDirectory -FirefoxExtensionDirectory $assets.FirefoxExtensionDirectory
}
