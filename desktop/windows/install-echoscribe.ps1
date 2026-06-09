param(
    [switch]$NoStart,
    [switch]$NoOpenBrowser
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$nativeHostName = 'de.echoscribe.nativehost'

function Resolve-PublishDirectory {
    if (
        (Test-Path -LiteralPath (Join-Path $scriptRoot 'EchoScribe.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $scriptRoot 'native-host\EchoScribe.NativeHost.exe') -PathType Leaf)
    ) {
        return $scriptRoot
    }

    $candidate = Join-Path $scriptRoot 'publish'
    if (
        (Test-Path -LiteralPath (Join-Path $candidate 'EchoScribe.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $candidate 'native-host\EchoScribe.NativeHost.exe') -PathType Leaf)
    ) {
        return $candidate
    }

    throw 'EchoScribe.exe and native-host\EchoScribe.NativeHost.exe were not found. Use a published EchoScribe Windows package or run publish-echoscribe.ps1 first.'
}

function Assert-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing file: $Path"
    }
}

function Assert-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Missing directory: $Path"
    }
}

function Get-ChromeExtensionId {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    if (-not $manifest.key) {
        throw 'The browser extension manifest needs a key field for a stable extension id.'
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

function Register-NativeHost {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

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
        $key.SetValue('', $ManifestPath, [Microsoft.Win32.RegistryValueKind]::String)
        $key.Dispose()
        $registered += "HKCU:\$path"
    }

    return $registered
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = $Target
    $shortcut.Save()
}

$publishDir = Resolve-PublishDirectory
$appExe = Join-Path $publishDir 'EchoScribe.exe'
$nativeHostExe = Join-Path $publishDir 'native-host\EchoScribe.NativeHost.exe'
$extensionDir = Join-Path $publishDir 'chrome-extension'
$manifestPath = Join-Path $extensionDir 'manifest.json'

Assert-File $appExe
Assert-File $nativeHostExe
Assert-Directory $extensionDir
Assert-File $manifestPath

$extensionId = Get-ChromeExtensionId -ManifestPath $manifestPath
$nativeHostManifestPath = Join-Path (Split-Path -Parent $nativeHostExe) "$nativeHostName.json"
$hostManifest = [ordered]@{
    name = $nativeHostName
    description = 'EchoScribe Web Summary Native Host'
    path = $nativeHostExe
    type = 'stdio'
    allowed_origins = @("chrome-extension://$extensionId/")
}
Write-Utf8NoBom -Path $nativeHostManifestPath -Value (($hostManifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine)

$registeredPaths = Register-NativeHost -ManifestPath $nativeHostManifestPath

$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDir 'EchoScribe.lnk'
New-Shortcut -Path $startupShortcut -Target $appExe -WorkingDirectory $publishDir

$programsDir = [Environment]::GetFolderPath('Programs')
$startMenuShortcut = Join-Path $programsDir 'EchoScribe.lnk'
New-Shortcut -Path $startMenuShortcut -Target $appExe -WorkingDirectory $publishDir

if (-not $NoStart) {
    Start-Process -FilePath $appExe -WorkingDirectory $publishDir
}

if (-not $NoOpenBrowser) {
    Start-Process $extensionDir
    Start-Process 'chrome://extensions' -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    PublishDirectory = $publishDir
    App = $appExe
    StartupShortcut = $startupShortcut
    StartMenuShortcut = $startMenuShortcut
    ExtensionId = $extensionId
    ExtensionDirectory = $extensionDir
    NativeHostManifest = $nativeHostManifestPath
    NativeHostRegistry = $registeredPaths
}

Write-Host ''
Write-Host 'Next step: in chrome://extensions, enable developer mode and load the chrome-extension folder shown above.'
