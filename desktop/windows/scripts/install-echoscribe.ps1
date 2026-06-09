param(
    [string]$TargetDirectory,
    [switch]$NoAutostart,
    [switch]$NoBrowserExtension,
    [switch]$NoStart,
    [switch]$NoOpenBrowser,
    [switch]$NoBuild,
    [switch]$ForceBuild,
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
$firefoxExtensionId = 'echoscribe@wean.de'
$defaultTargetDirectory = Join-Path $env:LOCALAPPDATA 'EchoScribe'

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

function Write-Header {
    if (-not $NonInteractive) {
        Clear-Host
    }
    try {
        $host.UI.RawUI.WindowTitle = 'EchoScribe Setup'
    } catch {
        # Some hosts do not expose a writable console title.
    }
    Write-Host ''
    Write-ColorLine 'EchoScribe Windows Setup' Cyan
    Write-ColorLine '========================' DarkCyan
    Write-ColorLine 'App, autostart, browser extensions, and Native Messaging in one installer.' DarkGray
    Write-Host ''
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][int]$Step,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $percent = [Math]::Min(100, [Math]::Round(($Step / [double]$Total) * 100))
    $barWidth = 28
    $filled = [Math]::Min($barWidth, [Math]::Round(($percent / 100.0) * $barWidth))
    $bar = ('#' * $filled).PadRight($barWidth, '-')
    Write-Progress -Activity 'Installing EchoScribe' -Status $Status -PercentComplete $percent
    Write-Host '[' -NoNewline -ForegroundColor DarkGray
    Write-Host $bar -NoNewline -ForegroundColor Cyan
    Write-Host ("] {0,3}% " -f $percent) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0}/{1}] {2}" -f $Step, $Total, $Status) -ForegroundColor Green
}

function Read-SetupPath {
    param([Parameter(Mandatory = $true)][string]$DefaultValue)

    if ($NonInteractive) {
        return $DefaultValue
    }

    Write-ColorLine 'Install folder:' Yellow
    Write-ColorLine "  $DefaultValue" DarkGray
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
            default { Write-ColorLine 'Please answer y or n.' Yellow }
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

function Test-PackageDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (
        (Test-Path -LiteralPath (Join-Path $Path 'EchoScribe.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'native-host\EchoScribe.NativeHost.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'chrome-extension\manifest.json') -PathType Leaf)
    )
}

function Test-SourceDirectory {
    return (
        (Test-Path -LiteralPath (Join-Path $packageRoot 'EchoScribe.Windows.csproj') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $packageRoot 'native-host\EchoScribe.NativeHost.csproj') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $scriptRoot 'install-dotnet-sdk.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $scriptRoot 'publish-echoscribe.ps1') -PathType Leaf)
    )
}

function Invoke-CheckedScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @()
    )

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-Host $line
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $Path $($Arguments -join ' ')"
    }
}

function Build-Package {
    Write-Host ''
    Write-ColorLine 'Building EchoScribe Windows package...' Cyan
    Invoke-CheckedScript -Path (Join-Path $scriptRoot 'install-dotnet-sdk.ps1')
    Invoke-CheckedScript -Path (Join-Path $scriptRoot 'publish-echoscribe.ps1')
}

function Resolve-PublishDirectory {
    if (Test-PackageDirectory -Path $packageRoot) {
        return $packageRoot
    }

    $candidate = Join-Path $packageRoot 'publish'
    if (Test-PackageDirectory -Path $candidate) {
        return $candidate
    }

    throw 'EchoScribe package files were not found. Run install.cmd from a source checkout or a published EchoScribe Windows package.'
}

function Resolve-Or-BuildPackage {
    if (Test-PackageDirectory -Path $packageRoot) {
        return $packageRoot
    }

    $candidate = Join-Path $packageRoot 'publish'
    $hasPublish = Test-PackageDirectory -Path $candidate
    $hasSource = Test-SourceDirectory

    if ($ForceBuild -and $NoBuild) {
        throw 'ForceBuild and NoBuild cannot be used together.'
    }

    if ($hasSource -and -not $NoBuild) {
        $shouldBuild = $ForceBuild
        if (-not $shouldBuild) {
            if (-not $hasPublish) {
                $shouldBuild = Read-SetupYesNo -Prompt 'No built package was found. Build EchoScribe now?' -DefaultValue $true
            } else {
                $shouldBuild = Read-SetupYesNo -Prompt 'A built package already exists. Rebuild before installing?' -DefaultValue $false
            }
        }

        if ($shouldBuild) {
            Build-Package
            $hasPublish = Test-PackageDirectory -Path $candidate
        }
    }

    if ($hasPublish) {
        return $candidate
    }

    if ($NoBuild) {
        throw 'No built package was found and build was disabled.'
    }

    throw 'No built package was found. Run install.cmd from a source checkout or a published EchoScribe Windows package.'
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

function Register-ChromiumNativeHost {
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

function Register-FirefoxNativeHost {
    param([Parameter(Mandatory = $true)][string]$NativeHostExe)

    $nativeHostManifestPath = Join-Path (Split-Path -Parent $NativeHostExe) "$nativeHostName.firefox.json"
    $hostManifest = [ordered]@{
        name = $nativeHostName
        description = 'EchoScribe Web Summary Native Host'
        path = $NativeHostExe
        type = 'stdio'
        allowed_extensions = @($firefoxExtensionId)
    }
    Write-Utf8NoBom -Path $nativeHostManifestPath -Value (($hostManifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine)

    $registryPath = "Software\Mozilla\NativeMessagingHosts\$nativeHostName"
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath, $true)
    if (-not $key) {
        throw "Registry key could not be created: HKCU:\$registryPath"
    }
    $key.SetValue('', $nativeHostManifestPath, [Microsoft.Win32.RegistryValueKind]::String)
    $key.Dispose()

    return [pscustomobject]@{
        ExtensionId = $firefoxExtensionId
        NativeHostManifest = $nativeHostManifestPath
        NativeHostRegistry = "HKCU:\$registryPath"
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
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$ExtensionPath
    )

    [pscustomobject]@{
        Name = $Name
        Url = $Url
        Executable = First-ExistingFile -Paths $Paths
        ExtensionPath = $ExtensionPath
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
    if (Test-Path -LiteralPath $FirefoxExtensionDirectory -PathType Container) {
        Start-Process $FirefoxExtensionDirectory
    }

    $targets = Get-BrowserSetupTargets -ChromiumExtensionDirectory $ChromiumExtensionDirectory -FirefoxExtensionDirectory $FirefoxExtensionDirectory
    $opened = @()
    foreach ($target in $targets) {
        if ($target.Executable) {
            Start-Process -FilePath $target.Executable -ArgumentList $target.Url
            $opened += $target.Name
        }
    }

    if ($opened.Count -eq 0) {
        Write-ColorLine 'No supported browser executable was found for opening the extension page automatically.' Yellow
    } else {
        Write-ColorLine "Opened extension setup page for: $($opened -join ', ')" Cyan
    }
}

$targetDir = Resolve-FullPath ($(if ($TargetDirectory) { $TargetDirectory } else { $defaultTargetDirectory }))
$enableAutostart = -not $NoAutostart
$enableBrowserExtension = -not $NoBrowserExtension
$startAfterInstall = -not $NoStart
$openBrowserSetup = (-not $NoOpenBrowser) -and $enableBrowserExtension

Write-Header
Write-Step 1 8 'Preparing package'
$publishDir = Resolve-Or-BuildPackage

Write-Step 2 8 'Checking package'
Assert-File (Join-Path $publishDir 'EchoScribe.exe')
Assert-File (Join-Path $publishDir 'native-host\EchoScribe.NativeHost.exe')
Assert-Directory (Join-Path $publishDir 'chrome-extension')
Assert-File (Join-Path $publishDir 'chrome-extension\manifest.json')
Assert-Directory (Join-Path $publishDir 'firefox-extension')
Assert-File (Join-Path $publishDir 'firefox-extension\manifest.json')

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
    Write-ColorLine 'Setup summary' Cyan
    Write-ColorLine "  Source:            $publishDir" DarkGray
    Write-ColorLine "  Install folder:    $targetDir" DarkGray
    Write-ColorLine "  Autostart:         $enableAutostart" DarkGray
    Write-ColorLine "  Browser extension: $enableBrowserExtension" DarkGray
    Write-ColorLine "  Start after setup: $startAfterInstall" DarkGray
    Write-Host ''
    $continue = Read-Host 'Press Enter to install or type q to cancel'
    if ($continue.Trim().ToLowerInvariant() -eq 'q') {
        Write-ColorLine 'Setup canceled.' Yellow
        exit 0
    }
}

Write-Step 3 8 'Stopping running EchoScribe processes'
Stop-RunningEchoScribe

Write-Step 4 8 "Copying files to $targetDir"
Copy-PackageToTarget -Source $publishDir -Target $targetDir

$appExe = Join-Path $targetDir 'EchoScribe.exe'
$nativeHostExe = Join-Path $targetDir 'native-host\EchoScribe.NativeHost.exe'
$chromiumExtensionDir = Join-Path $targetDir 'chrome-extension'
$firefoxExtensionDir = Join-Path $targetDir 'firefox-extension'
$chromiumManifestPath = Join-Path $chromiumExtensionDir 'manifest.json'
Assert-File $appExe
Assert-File $nativeHostExe
Assert-Directory $chromiumExtensionDir
Assert-File $chromiumManifestPath
Assert-Directory $firefoxExtensionDir
Assert-File (Join-Path $firefoxExtensionDir 'manifest.json')

Write-Step 5 8 'Registering browser native hosts'
$browserRegistration = $null
if ($enableBrowserExtension) {
    $chromiumRegistration = Register-ChromiumNativeHost -NativeHostExe $nativeHostExe -ExtensionManifestPath $chromiumManifestPath
    $firefoxRegistration = Register-FirefoxNativeHost -NativeHostExe $nativeHostExe
    $browserRegistration = [pscustomobject]@{
        Chromium = $chromiumRegistration
        Firefox = $firefoxRegistration
    }
} else {
    Write-ColorLine 'Browser native host registration skipped.' Yellow
}

Write-Step 6 8 'Creating shortcuts'
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

Write-Step 7 8 'Opening optional setup pages'
if ($openBrowserSetup) {
    Open-BrowserSetup -ChromiumExtensionDirectory $chromiumExtensionDir -FirefoxExtensionDirectory $firefoxExtensionDir
}
if ($startAfterInstall) {
    Start-Process -FilePath $appExe -WorkingDirectory $targetDir
}

Write-Step 8 8 'Setup complete'
Write-Progress -Activity 'Installing EchoScribe' -Completed

$result = [ordered]@{
    InstallDirectory = $targetDir
    App = $appExe
    Autostart = $enableAutostart
    StartupShortcut = $startupShortcut
    StartMenuShortcut = $startMenuShortcut
    BrowserExtension = $enableBrowserExtension
    ChromiumExtensionDirectory = $chromiumExtensionDir
    FirefoxExtensionDirectory = $firefoxExtensionDir
}
if ($browserRegistration) {
    $result.ChromiumExtensionId = $browserRegistration.Chromium.ExtensionId
    $result.ChromiumNativeHostManifest = $browserRegistration.Chromium.NativeHostManifest
    $result.ChromiumNativeHostRegistry = $browserRegistration.Chromium.NativeHostRegistry
    $result.FirefoxExtensionId = $browserRegistration.Firefox.ExtensionId
    $result.FirefoxNativeHostManifest = $browserRegistration.Firefox.NativeHostManifest
    $result.FirefoxNativeHostRegistry = $browserRegistration.Firefox.NativeHostRegistry
}

[pscustomobject]$result

Write-Host ''
if ($enableBrowserExtension) {
    Write-ColorLine 'Next steps:' Cyan
    Write-ColorLine '  Chromium browsers: enable developer mode on the extensions page and load this folder:' Gray
    Write-ColorLine "    $chromiumExtensionDir" DarkGray
    Write-ColorLine '  Firefox: open about:debugging#/runtime/this-firefox and load this manifest as a temporary add-on:' Gray
    Write-ColorLine "    $(Join-Path $firefoxExtensionDir 'manifest.json')" DarkGray
}
Write-ColorLine 'EchoScribe setup finished.' Green
