param(
    [string]$TargetDirectory,
    [switch]$NoAutostart,
    [switch]$NoBrowserExtension,
    [switch]$NoStart,
    [switch]$NoOpenBrowser,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = if ((Split-Path -Leaf $scriptRoot) -eq 'scripts') {
    Split-Path -Parent $scriptRoot
} else {
    $scriptRoot
}
$nativeHostName = 'de.echoscribe.nativehost'
$defaultTargetDirectory = Join-Path $env:LOCALAPPDATA 'EchoScribe'

function Write-Header {
    if (-not $NonInteractive) {
        Clear-Host
    }
    Write-Host ''
    Write-Host 'EchoScribe Windows Setup'
    Write-Host '========================'
    Write-Host ''
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][int]$Step,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $percent = [Math]::Min(100, [Math]::Round(($Step / [double]$Total) * 100))
    Write-Progress -Activity 'Installing EchoScribe' -Status $Status -PercentComplete $percent
    Write-Host ("[{0}/{1}] {2}" -f $Step, $Total, $Status)
}

function Read-SetupPath {
    param([Parameter(Mandatory = $true)][string]$DefaultValue)

    if ($NonInteractive) {
        return $DefaultValue
    }

    Write-Host "Install folder:"
    Write-Host "  $DefaultValue"
    $value = Read-Host 'Press Enter to use this folder or type another path'
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }
    return $value.Trim()
}

function Read-SetupYesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][bool]$DefaultValue
    )

    if ($NonInteractive) {
        return $DefaultValue
    }

    $suffix = if ($DefaultValue) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-Host "$Prompt [$suffix]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }

        switch ($value.Trim().ToLowerInvariant()) {
            { $_ -in @('y', 'yes') } { return $true }
            { $_ -in @('n', 'no') } { return $false }
            default { Write-Host 'Please answer y or n.' }
        }
    }
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [System.IO.Path]::GetFullPath($expanded)
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftFull = (Resolve-FullPath $Left).TrimEnd('\', '/')
    $rightFull = (Resolve-FullPath $Right).TrimEnd('\', '/')
    return [string]::Equals($leftFull, $rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-PublishDirectory {
    if (
        (Test-Path -LiteralPath (Join-Path $packageRoot 'EchoScribe.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $packageRoot 'native-host\EchoScribe.NativeHost.exe') -PathType Leaf)
    ) {
        return $packageRoot
    }

    $candidate = Join-Path $packageRoot 'publish'
    if (
        (Test-Path -LiteralPath (Join-Path $candidate 'EchoScribe.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $candidate 'native-host\EchoScribe.NativeHost.exe') -PathType Leaf)
    ) {
        return $candidate
    }

    throw 'EchoScribe.exe and native-host\EchoScribe.NativeHost.exe were not found. Use a published EchoScribe Windows package or run build-release.cmd first.'
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

function Stop-RunningEchoScribe {
    Get-Process EchoScribe,EchoScribe.NativeHost -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Copy-PackageToTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    if (Test-SamePath $Source $Target) {
        return
    }

    $preserveConfig = Test-Path -LiteralPath (Join-Path $Target 'appsettings.json') -PathType Leaf
    New-Item -ItemType Directory -Force -Path $Target | Out-Null

    Get-ChildItem -LiteralPath $Target -Force | Where-Object {
        -not ($preserveConfig -and $_.Name -eq 'appsettings.json')
    } | Remove-Item -Recurse -Force

    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($preserveConfig -and $item.Name -eq 'appsettings.json') {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Target $item.Name) -Recurse -Force
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
        [Parameter(Mandatory = $true)][string]$NativeHostExe,
        [Parameter(Mandatory = $true)][string]$ExtensionManifestPath
    )

    $extensionId = Get-ChromeExtensionId -ManifestPath $ExtensionManifestPath
    $nativeHostManifestPath = Join-Path (Split-Path -Parent $NativeHostExe) "$nativeHostName.json"
    $hostManifest = [ordered]@{
        name = $nativeHostName
        description = 'EchoScribe Web Summary Native Host'
        path = $NativeHostExe
        type = 'stdio'
        allowed_origins = @("chrome-extension://$extensionId/")
    }
    Write-Utf8NoBom -Path $nativeHostManifestPath -Value (($hostManifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine)

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
        $key.SetValue('', $nativeHostManifestPath, [Microsoft.Win32.RegistryValueKind]::String)
        $key.Dispose()
        $registered += "HKCU:\$path"
    }

    return [pscustomobject]@{
        ExtensionId = $extensionId
        NativeHostManifest = $nativeHostManifestPath
        NativeHostRegistry = $registered
    }
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

function Remove-Shortcut {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

$publishDir = Resolve-PublishDirectory
$targetDir = Resolve-FullPath ($(if ($TargetDirectory) { $TargetDirectory } else { $defaultTargetDirectory }))
$enableAutostart = -not $NoAutostart
$enableBrowserExtension = -not $NoBrowserExtension
$startAfterInstall = -not $NoStart
$openBrowserSetup = (-not $NoOpenBrowser) -and $enableBrowserExtension

Write-Header
Write-Step 1 7 'Checking package'
Assert-File (Join-Path $publishDir 'EchoScribe.exe')
Assert-File (Join-Path $publishDir 'native-host\EchoScribe.NativeHost.exe')
Assert-Directory (Join-Path $publishDir 'chrome-extension')
Assert-File (Join-Path $publishDir 'chrome-extension\manifest.json')

$targetDir = Resolve-FullPath (Read-SetupPath -DefaultValue $targetDir)
$enableAutostart = Read-SetupYesNo -Prompt 'Start EchoScribe automatically when Windows starts?' -DefaultValue $enableAutostart
$enableBrowserExtension = Read-SetupYesNo -Prompt 'Register the browser extension native host?' -DefaultValue $enableBrowserExtension
if ($enableBrowserExtension) {
    $openBrowserSetup = Read-SetupYesNo -Prompt 'Open the extension folder and browser extension page after setup?' -DefaultValue $openBrowserSetup
} else {
    $openBrowserSetup = $false
}
$startAfterInstall = Read-SetupYesNo -Prompt 'Start EchoScribe after setup?' -DefaultValue $startAfterInstall

if (-not $NonInteractive) {
    Write-Host ''
    Write-Host 'Setup summary'
    Write-Host "  Source:            $publishDir"
    Write-Host "  Install folder:    $targetDir"
    Write-Host "  Autostart:         $enableAutostart"
    Write-Host "  Browser extension: $enableBrowserExtension"
    Write-Host "  Start after setup: $startAfterInstall"
    Write-Host ''
    $continue = Read-Host 'Press Enter to install or type q to cancel'
    if ($continue.Trim().ToLowerInvariant() -eq 'q') {
        Write-Host 'Setup canceled.'
        exit 0
    }
}

Write-Step 2 7 'Stopping running EchoScribe processes'
Stop-RunningEchoScribe

Write-Step 3 7 "Copying files to $targetDir"
Copy-PackageToTarget -Source $publishDir -Target $targetDir

$appExe = Join-Path $targetDir 'EchoScribe.exe'
$nativeHostExe = Join-Path $targetDir 'native-host\EchoScribe.NativeHost.exe'
$extensionDir = Join-Path $targetDir 'chrome-extension'
$manifestPath = Join-Path $extensionDir 'manifest.json'
Assert-File $appExe
Assert-File $nativeHostExe
Assert-Directory $extensionDir
Assert-File $manifestPath

Write-Step 4 7 'Registering browser native host'
$browserRegistration = $null
if ($enableBrowserExtension) {
    $browserRegistration = Register-NativeHost -NativeHostExe $nativeHostExe -ExtensionManifestPath $manifestPath
} else {
    Write-Host 'Browser native host registration skipped.'
}

Write-Step 5 7 'Creating shortcuts'
$programsDir = [Environment]::GetFolderPath('Programs')
$startMenuShortcut = Join-Path $programsDir 'EchoScribe.lnk'
New-Shortcut -Path $startMenuShortcut -Target $appExe -WorkingDirectory $targetDir

$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDir 'EchoScribe.lnk'
if ($enableAutostart) {
    New-Shortcut -Path $startupShortcut -Target $appExe -WorkingDirectory $targetDir
} else {
    Remove-Shortcut -Path $startupShortcut
}

Write-Step 6 7 'Opening optional setup pages'
if ($openBrowserSetup) {
    Start-Process $extensionDir
    Start-Process 'chrome://extensions' -ErrorAction SilentlyContinue
}
if ($startAfterInstall) {
    Start-Process -FilePath $appExe -WorkingDirectory $targetDir
}

Write-Step 7 7 'Setup complete'
Write-Progress -Activity 'Installing EchoScribe' -Completed

$result = [ordered]@{
    InstallDirectory = $targetDir
    App = $appExe
    Autostart = $enableAutostart
    StartupShortcut = $startupShortcut
    StartMenuShortcut = $startMenuShortcut
    BrowserExtension = $enableBrowserExtension
    ExtensionDirectory = $extensionDir
}
if ($browserRegistration) {
    $result.ExtensionId = $browserRegistration.ExtensionId
    $result.NativeHostManifest = $browserRegistration.NativeHostManifest
    $result.NativeHostRegistry = $browserRegistration.NativeHostRegistry
}

[pscustomobject]$result

Write-Host ''
if ($enableBrowserExtension) {
    Write-Host 'Next step: in chrome://extensions, enable developer mode and load this folder:'
    Write-Host "  $extensionDir"
}
Write-Host 'EchoScribe setup finished.'
