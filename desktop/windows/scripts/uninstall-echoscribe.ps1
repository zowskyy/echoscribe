param(
    [string]$TargetDirectory,
    [switch]$RemoveApp,
    [switch]$RemoveAutostart,
    [switch]$RemoveStartMenu,
    [switch]$RemoveBrowserHosts,
    [switch]$RemoveLocalWhisper,
    [switch]$RemoveWslLocalWhisper,
    [switch]$RemoveOllamaModels,
    [switch]$RemoveAllOllamaModels,
    [string[]]$OllamaModels = @(),
    [switch]$UninstallOllama,
    [switch]$All,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$nativeHostName = 'de.echoscribe.nativehost'
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

function Read-SetupValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$DefaultValue
    )

    if ($NonInteractive) {
        return $DefaultValue
    }

    $value = Read-Host "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }
    return $value.Trim()
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [System.IO.Path]::GetFullPath($expanded)
}

function Get-CommandSource {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }
    return $null
}

function Test-WslLinuxAvailable {
    $wsl = Get-CommandSource -Names @('wsl.exe', 'wsl')
    if (-not $wsl) {
        return $false
    }

    & $wsl -- bash -lc 'printf ok' *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-EchoScribeProcesses {
    return @(Get-Process -Name EchoScribe,EchoScribe.NativeHost -ErrorAction SilentlyContinue)
}

function Format-EchoScribeProcess {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    $path = ''
    try {
        $path = $Process.Path
    } catch {
        $path = '<path unavailable>'
    }
    return "{0} pid={1} session={2} path={3}" -f $Process.ProcessName, $Process.Id, $Process.SessionId, $path
}

function Stop-RunningEchoScribe {
    $processes = Get-EchoScribeProcesses
    if ($processes.Count -eq 0) {
        return
    }

    foreach ($process in $processes) {
        $description = Format-EchoScribeProcess -Process $process
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-ColorLine "Stopped $description" DarkGray
        } catch {
            Write-ColorLine "Could not stop $description with Stop-Process: $($_.Exception.Message)" Yellow
            $taskkill = Get-CommandSource -Names @('taskkill.exe', 'taskkill')
            if ($taskkill) {
                & $taskkill /PID $process.Id /T /F | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-ColorLine "Stopped $description with taskkill." DarkGray
                } else {
                    Write-ColorLine "taskkill could not stop $description. Exit code: $LASTEXITCODE" Yellow
                }
            }
        }
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $remaining = Get-EchoScribeProcesses
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    $remainingDetails = (Get-EchoScribeProcesses | ForEach-Object { Format-EchoScribeProcess -Process $_ }) -join '; '
    throw "EchoScribe is still running and uninstall cannot safely remove files. Close EchoScribe from the tray or Task Manager, then rerun uninstall. Remaining process(es): $remainingDetails"
}

function Remove-ShortcutGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $Directory -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Remove-EchoScribeRunEntries {
    $registryPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath, $true)
    if (-not $key) {
        return
    }

    try {
        foreach ($name in $key.GetValueNames()) {
            $value = [string]$key.GetValue($name, '')
            if ($name -like 'EchoScribe*' -or $value -match '(?i)EchoScribe') {
                $key.DeleteValue($name, $false)
            }
        }
    } finally {
        $key.Dispose()
    }
}

function Remove-AutostartEntries {
    $startupDir = [Environment]::GetFolderPath('Startup')
    Remove-ShortcutGroup -Directory $startupDir -Pattern 'EchoScribe*.lnk'
    Remove-EchoScribeRunEntries
}

function Remove-StartMenuEntries {
    $programsDir = [Environment]::GetFolderPath('Programs')
    $echoScribeDir = Join-Path $programsDir 'EchoScribe'
    Remove-ShortcutGroup -Directory $programsDir -Pattern 'EchoScribe*.lnk'
    Remove-ShortcutGroup -Directory $echoScribeDir -Pattern 'EchoScribe*.lnk'
    if ((Test-Path -LiteralPath $echoScribeDir -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $echoScribeDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Remove-Item -LiteralPath $echoScribeDir -Force -ErrorAction SilentlyContinue
    }
}

function Remove-RegistrySubKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Path, $false)
    } catch {
        Write-ColorLine "Could not remove HKCU:\${Path}: $($_.Exception.Message)" Yellow
    }
}

function Remove-BrowserNativeHosts {
    $registryPaths = @(
        "Software\Google\Chrome\NativeMessagingHosts\$nativeHostName",
        "Software\Chromium\NativeMessagingHosts\$nativeHostName",
        "Software\Microsoft\Edge\NativeMessagingHosts\$nativeHostName",
        "Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\$nativeHostName",
        "Software\Mozilla\NativeMessagingHosts\$nativeHostName"
    )

    foreach ($path in $registryPaths) {
        Remove-RegistrySubKey -Path $path
    }
}

function Assert-SafeTargetDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Resolve-FullPath $Path
    if ($full -match '^[A-Za-z]:\\?$') {
        throw "Refusing to remove drive root: $full"
    }
    if ($full.Length -lt 12) {
        throw "Refusing to remove suspiciously short path: $full"
    }
    if ((Split-Path -Leaf $full) -notmatch '(?i)^EchoScribe$') {
        throw "Refusing to remove a directory not named EchoScribe: $full"
    }
    return $full
}

function Remove-AppDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $safePath = Assert-SafeTargetDirectory -Path $Path
    if (Test-Path -LiteralPath $safePath -PathType Container) {
        Remove-Item -LiteralPath $safePath -Recurse -Force
        Write-ColorLine "Removed app directory: $safePath" Green
    } else {
        Write-ColorLine "App directory not found: $safePath" Yellow
    }
}

function Remove-WhisperCppFiles {
    param([Parameter(Mandatory = $true)][string]$TargetDirectory)

    Get-Process whisper-cli,whisper-server -ErrorAction SilentlyContinue | Stop-Process -Force

    $paths = @(
        (Join-Path $TargetDirectory 'local-ai\whisper.cpp'),
        (Join-Path $TargetDirectory 'local-ai\whisper-models')
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-ColorLine "Removed Local Whisper files: $path" Green
        }
    }
}

function Invoke-WslScript {
    param([Parameter(Mandatory = $true)][string]$Script)

    $wsl = Get-CommandSource -Names @('wsl.exe', 'wsl')
    if (-not $wsl) {
        Write-ColorLine 'wsl.exe was not found; skipping WSL cleanup.' Yellow
        return
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("echoscribe-uninstall-{0}.sh" -f ([guid]::NewGuid().ToString("N")))
    [System.IO.File]::WriteAllText($temp, $Script, [System.Text.UTF8Encoding]::new($false))
    try {
        if ($temp -notmatch '^([A-Za-z]):\\(.*)$') {
            throw "Could not map Windows temp script into WSL: $temp"
        }
        $drive = $Matches[1].ToLowerInvariant()
        $relativePath = $Matches[2].Replace('\', '/')
        $wslScriptPath = "/mnt/$drive/$relativePath"
    & $wsl -- bash $wslScriptPath
        if ($LASTEXITCODE -ne 0) {
            throw "WSL cleanup failed with exit code $LASTEXITCODE."
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Remove-WslLocalWhisper {
    Invoke-WslScript -Script @'
set -euo pipefail

ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/echoscribe/local-ai"
PID_FILE="$ROOT/whisper-server.pid"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
fi

pkill -f 'uvicorn server:app.*echoscribe/local-ai' 2>/dev/null || true
rm -rf "$ROOT"
echo "Removed WSL Local Whisper files: $ROOT"
'@
}

function Remove-LocalWhisper {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory
    )

    Remove-WhisperCppFiles -TargetDirectory $TargetDirectory
}

function Get-OllamaModelNames {
    $ollama = Get-CommandSource -Names @('ollama.exe', 'ollama')
    if ($ollama) {
        $lines = & $ollama list 2>$null
        if ($LASTEXITCODE -eq 0) {
            return @(
                $lines |
                    Select-Object -Skip 1 |
                    ForEach-Object { ($_ -split '\s+')[0] } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }
    }

    try {
        $response = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/tags'
        return @($response.models | ForEach-Object { $_.name } | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Invoke-OllamaRemoveModel {
    param([Parameter(Mandatory = $true)][string]$Model)

    $ollama = Get-CommandSource -Names @('ollama.exe', 'ollama')
    if ($ollama) {
        & $ollama rm $Model
        if ($LASTEXITCODE -ne 0) {
            Write-ColorLine "Ollama could not remove model ${Model}. Exit code: $LASTEXITCODE" Yellow
        }
        return
    }

    try {
        $body = @{ name = $Model } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Delete -Uri 'http://127.0.0.1:11434/api/delete' -ContentType 'application/json' -Body $body | Out-Null
    } catch {
        Write-ColorLine "Ollama model removal failed for ${Model}: $($_.Exception.Message)" Yellow
    }
}

function Remove-OllamaModels {
    param([Parameter(Mandatory = $true)][string[]]$Models)

    if ($Models.Count -eq 0) {
        Write-ColorLine 'No Ollama models were specified; skipping model removal.' Yellow
        return
    }

    $modelList = ($Models | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }) -join '|'
    if ([string]::IsNullOrWhiteSpace($modelList)) {
        Write-ColorLine 'No Ollama models were specified; skipping model removal.' Yellow
        return
    }

    foreach ($model in ($modelList.Split('|') | Where-Object { $_ })) {
        Write-ColorLine "Removing Ollama model: $model" Cyan
        Invoke-OllamaRemoveModel -Model $model
    }
}

function Remove-AllOllamaModels {
    $models = @(Get-OllamaModelNames)
    if ($models.Count -eq 0) {
        Write-ColorLine 'No local Ollama models were found through ollama.exe or http://127.0.0.1:11434.' Yellow
        return
    }

    foreach ($model in $models) {
        Write-ColorLine "Removing Ollama model: $model" Cyan
        Invoke-OllamaRemoveModel -Model $model
    }
}

function Uninstall-OllamaWindows {
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-ColorLine 'winget.exe was not found; uninstall Ollama manually if needed.' Yellow
        return
    }

    & $winget.Source uninstall --id Ollama.Ollama --silent --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-ColorLine "winget could not uninstall Ollama automatically. Exit code: $LASTEXITCODE" Yellow
    }
}

if ($All) {
    $RemoveApp = $true
    $RemoveAutostart = $true
    $RemoveStartMenu = $true
    $RemoveBrowserHosts = $true
    $RemoveLocalWhisper = $true
    $RemoveWslLocalWhisper = $true
    $RemoveAllOllamaModels = $true
}

$targetDir = Resolve-FullPath ($(if ($TargetDirectory) { $TargetDirectory } else { $defaultTargetDirectory }))
$wslLinuxAvailable = Test-WslLinuxAvailable

Write-Host ''
Write-ColorLine 'EchoScribe Windows Uninstall' Cyan
Write-ColorLine '============================' DarkCyan
Write-Host ''

if (-not $NonInteractive) {
    $targetDir = Resolve-FullPath (Read-SetupValue -Prompt 'Installed EchoScribe folder' -DefaultValue $targetDir)
    $RemoveApp = Read-SetupYesNo -Prompt 'Remove EchoScribe app files?' -DefaultValue $true
    $RemoveAutostart = Read-SetupYesNo -Prompt 'Remove EchoScribe autostart entries?' -DefaultValue $true
    $RemoveStartMenu = Read-SetupYesNo -Prompt 'Remove EchoScribe Start Menu entries?' -DefaultValue $true
    $RemoveBrowserHosts = Read-SetupYesNo -Prompt 'Remove browser Native Messaging registrations?' -DefaultValue $true
    $RemoveLocalWhisper = Read-SetupYesNo -Prompt 'Remove EchoScribe Windows whisper.cpp Local Whisper files?' -DefaultValue $true
    if ($wslLinuxAvailable) {
        $RemoveWslLocalWhisper = Read-SetupYesNo -Prompt 'Remove optional legacy WSL Local Whisper files?' -DefaultValue $false
    }
    $RemoveAllOllamaModels = Read-SetupYesNo -Prompt 'Remove all local Ollama models? Only choose this if no other app needs them.' -DefaultValue $false
    $UninstallOllama = Read-SetupYesNo -Prompt 'Uninstall Ollama itself? Only choose this if no other app uses Ollama.' -DefaultValue $false

    Write-Host ''
    Write-ColorLine 'Uninstall summary' Cyan
    Write-ColorLine "  App folder:           $targetDir" DarkGray
    Write-ColorLine "  App files:            $RemoveApp" DarkGray
    Write-ColorLine "  Autostart:            $RemoveAutostart" DarkGray
    Write-ColorLine "  Start Menu:           $RemoveStartMenu" DarkGray
    Write-ColorLine "  Browser native hosts: $RemoveBrowserHosts" DarkGray
    Write-ColorLine "  WSL Linux found:      $wslLinuxAvailable" DarkGray
    Write-ColorLine "  Windows whisper.cpp:  $RemoveLocalWhisper" DarkGray
    Write-ColorLine "  Legacy WSL Whisper:   $RemoveWslLocalWhisper" DarkGray
    Write-ColorLine "  All Ollama models:    $RemoveAllOllamaModels" DarkGray
    Write-ColorLine "  Ollama app:           $UninstallOllama" DarkGray
    Write-Host ''
    $continue = Read-Host 'Press Enter to uninstall or type q to cancel'
    if ($continue.Trim().ToLowerInvariant() -eq 'q') {
        Write-ColorLine 'Uninstall canceled.' Yellow
        exit 0
    }
}

Stop-RunningEchoScribe

if ($RemoveBrowserHosts) {
    Remove-BrowserNativeHosts
    Write-ColorLine 'Removed browser Native Messaging registrations.' Green
}

if ($RemoveAutostart) {
    Remove-AutostartEntries
    Write-ColorLine 'Removed autostart entries.' Green
}

if ($RemoveStartMenu) {
    Remove-StartMenuEntries
    Write-ColorLine 'Removed Start Menu entries.' Green
}

if ($RemoveLocalWhisper) {
    Remove-LocalWhisper -TargetDirectory $targetDir
}

if ($RemoveWslLocalWhisper) {
    Remove-WslLocalWhisper
}

if ($RemoveOllamaModels) {
    Remove-OllamaModels -Models $OllamaModels
}

if ($RemoveAllOllamaModels) {
    Remove-AllOllamaModels
}

if ($UninstallOllama) {
    Uninstall-OllamaWindows
}

if ($RemoveApp) {
    Remove-AppDirectory -Path $targetDir
}

Write-ColorLine 'EchoScribe uninstall finished.' Green
