$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ((Split-Path -Leaf $scriptRoot) -eq 'scripts') {
    Split-Path -Parent $scriptRoot
} else {
    $scriptRoot
}
$publishDir = Join-Path $root 'publish'
$extensionDir = Join-Path $publishDir 'chrome-extension'
$nativeHost = Join-Path $publishDir 'native-host\EchoScribe.NativeHost.exe'
$nativeHostName = 'de.echoscribe.nativehost'

if (-not (Test-Path -LiteralPath $extensionDir)) {
    $extensionDir = Join-Path (Split-Path -Parent $root) 'browser-extension'
}
if (-not (Test-Path -LiteralPath $nativeHost)) {
    $nativeHost = Join-Path $root 'native-host\bin\Release\net8.0\win-x64\publish\EchoScribe.NativeHost.exe'
}
if (-not (Test-Path -LiteralPath $nativeHost)) {
    throw 'EchoScribe.NativeHost.exe not found. Run .\install.cmd or .\scripts\publish-echoscribe.ps1 first.'
}

$manifestPath = Join-Path $extensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw 'Chrome extension manifest not found.'
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$publicKey = [Convert]::FromBase64String($manifest.key)
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash($publicKey)
$builder = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt 16; $i++) {
    [void]$builder.Append([char]([int][char]'a' + (($hash[$i] -shr 4) -band 0x0f)))
    [void]$builder.Append([char]([int][char]'a' + ($hash[$i] -band 0x0f)))
}
$extensionId = $builder.ToString()

$hostManifestPath = Join-Path (Split-Path -Parent $nativeHost) "$nativeHostName.json"
$hostManifest = [ordered]@{
    name = $nativeHostName
    description = 'EchoScribe Web Summary Native Host'
    path = $nativeHost
    type = 'stdio'
    allowed_origins = @("chrome-extension://$extensionId/")
}
$hostManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $hostManifestPath -Encoding UTF8

$registryPath = "Software\Google\Chrome\NativeMessagingHosts\$nativeHostName"
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath, $true)
$key.SetValue('', $hostManifestPath, [Microsoft.Win32.RegistryValueKind]::String)
$key.Dispose()

[pscustomobject]@{
    ExtensionId = $extensionId
    ExtensionDirectory = $extensionDir
    NativeHostManifest = $hostManifestPath
    Registry = "HKCU:\$registryPath"
}

Start-Process 'chrome://extensions'
Start-Process $extensionDir
