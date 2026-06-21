param(
    [string]$TargetDirectory,
    [switch]$NoAutostart,
    [switch]$NoBrowserExtension,
    [switch]$NoStart,
    [switch]$NoOpenBrowser,
    [switch]$NoBuild,
    [switch]$ForceBuild,
    [switch]$NonInteractive,
    [switch]$InstallLocalWhisper,
    [switch]$UseWslWhisper,
    [switch]$ConfigureLocalOllama,
    [switch]$InstallOllama,
    [switch]$NoInstallOllama,
    [switch]$PullOllamaModel,
    [string]$LocalAiHost,
    [string]$LocalWhisperModel = 'auto',
    [string]$LocalOllamaModel = 'qwen2.5:7b'
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
$defaultLocalWhisperPort = 8000
$defaultLocalOllamaPort = 11434
$whisperCppReleaseApi = 'https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest'
$ollamaInstallScriptUrl = 'https://ollama.com/install.ps1'
$whisperModelBaseUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main'

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

function Clear-SetupProgress {
    Write-Progress -Activity 'Installing EchoScribe' -Completed
}

function Read-SetupInput {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    $value = Read-Host $Prompt
    if ($null -eq $value) {
        return ''
    }
    return [string]$value
}

function Read-SetupPath {
    param([Parameter(Mandatory = $true)][string]$DefaultValue)

    if ($NonInteractive) {
        return $DefaultValue
    }

    Clear-SetupProgress
    Write-ColorLine 'Install folder:' Yellow
    Write-ColorLine "  $DefaultValue" DarkGray
    $value = Read-SetupInput 'Press Enter to use this folder or type another path'
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

    Clear-SetupProgress
    $suffix = if ($DefaultValue) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = Read-SetupInput "$Prompt [$suffix]"
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

function Get-DefaultLocalAiHost {
    if (-not [string]::IsNullOrWhiteSpace($LocalAiHost)) {
        return $LocalAiHost.Trim()
    }

    return '127.0.0.1'
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

function Get-OllamaExecutable {
    $ollama = Get-CommandSource -Names @('ollama.exe', 'ollama')
    if ($ollama) {
        return $ollama
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\ollama.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Wait-OllamaExecutable {
    param([int]$TimeoutSeconds = 180)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $ollama = Get-OllamaExecutable
        if ($ollama) {
            return $ollama
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Test-OllamaApi {
    try {
        Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$defaultLocalOllamaPort/api/tags" -TimeoutSec 4 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Wait-OllamaApi {
    param([int]$TimeoutSeconds = 35)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaApi) {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Install-OllamaWindows {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("echoscribe-ollama-install-{0}.ps1" -f ([guid]::NewGuid().ToString("N")))
    Write-ColorLine 'Downloading the official Ollama Windows installer script...' Cyan
    Invoke-WebRequest -Uri $ollamaInstallScriptUrl -OutFile $temp -UseBasicParsing
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $temp
        if ($LASTEXITCODE -ne 0) {
            throw "Ollama installer exited with code $LASTEXITCODE."
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    if (-not (Wait-OllamaExecutable -TimeoutSeconds 180)) {
        throw 'Ollama installer finished, but ollama.exe was not found. Wait a moment and rerun setup, or install Ollama manually.'
    }
}

function Start-OllamaIfNeeded {
    if (Test-OllamaApi) {
        return
    }

    $ollama = Get-OllamaExecutable
    if (-not $ollama) {
        throw 'ollama.exe was not found after installation.'
    }

    Write-ColorLine 'Starting Ollama in the background...' Cyan
    Start-Process -FilePath $ollama -ArgumentList @('serve') -WindowStyle Hidden | Out-Null
    if (-not (Wait-OllamaApi -TimeoutSeconds 35)) {
        throw 'Ollama did not become reachable on http://127.0.0.1:11434.'
    }
}

function Ensure-OllamaWindows {
    param([Parameter(Mandatory = $true)][bool]$AllowInstall)

    if (Test-OllamaApi) {
        return
    }

    if (Get-OllamaExecutable) {
        Start-OllamaIfNeeded
        return
    }

    if (-not $AllowInstall) {
        throw 'Ollama was not found. Rerun setup, allow Ollama installation, or install Ollama manually.'
    }

    Install-OllamaWindows
    Start-OllamaIfNeeded
}

function Invoke-OllamaPull {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$HostNameOrIp
    )

    $ollama = Get-OllamaExecutable
    if ($ollama -and (Test-LocalAiHostIsLocal -HostNameOrIp $HostNameOrIp)) {
        & $ollama pull $Model
        if ($LASTEXITCODE -ne 0) {
            throw "Ollama could not pull/check model ${Model}. Exit code: $LASTEXITCODE"
        }
        return
    }

    try {
        $body = @{ name = $Model; stream = $false } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "http://${HostNameOrIp}:$defaultLocalOllamaPort/api/pull" -ContentType 'application/json' -Body $body | Out-Null
    } catch {
        throw "Ollama is not reachable at http://${HostNameOrIp}:$defaultLocalOllamaPort. Install/start Ollama first, then rerun setup or skip the model download. Details: $($_.Exception.Message)"
    }
}

function Get-CudaRuntimeStatus {
    $nvidiaSmi = Get-CommandSource -Names @('nvidia-smi.exe', 'nvidia-smi')
    if (-not $nvidiaSmi) {
        $candidate = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $nvidiaSmi = $candidate
        }
    }
    $gpuName = ''
    $driverCudaVersion = ''
    $driverAvailable = $false

    if ($nvidiaSmi) {
        try {
            $gpuName = (& $nvidiaSmi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1).Trim()
            $output = (& $nvidiaSmi 2>$null | Out-String)
            if ($output -match 'CUDA(?:\s+UMD)?\s+Version:\s*([0-9.]+)') {
                $driverCudaVersion = $Matches[1]
            }
            $driverAvailable = $true
        } catch {
            $driverAvailable = $false
        }
    }

    $cudaPath = $env:CUDA_PATH
    if ([string]::IsNullOrWhiteSpace($cudaPath)) {
        $cudaPath = (Get-ChildItem Env:CUDA_PATH_V* -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -First 1).Value
    }

    [pscustomobject]@{
        DriverAvailable = $driverAvailable
        DriverCudaVersion = $driverCudaVersion
        CudaPath = $cudaPath
        GpuName = $gpuName
    }
}

function Test-LocalAiHostIsLocal {
    param([Parameter(Mandatory = $true)][string]$HostNameOrIp)

    return $HostNameOrIp -in @('127.0.0.1', 'localhost', '::1')
}

function Convert-VersionOrNull {
    param([string]$Value)

    [version]$version = [version]'0.0'
    if ([version]::TryParse($Value, [ref]$version)) {
        return $version
    }
    return $null
}

function Get-WhisperCppCudaAssetName {
    param([Parameter(Mandatory = $true)][object]$CudaStatus)

    if (-not $CudaStatus.DriverAvailable) {
        return ''
    }

    $version = Convert-VersionOrNull -Value ([string]$CudaStatus.DriverCudaVersion)
    if (-not $version) {
        return ''
    }

    if ($version -ge [version]'12.4') {
        return 'whisper-cublas-12.4.0-bin-x64.zip'
    }
    if ($version -ge [version]'11.8') {
        return 'whisper-cublas-11.8.0-bin-x64.zip'
    }
    return ''
}

function Read-SetupValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$DefaultValue
    )

    if ($NonInteractive) {
        return $DefaultValue
    }

    Clear-SetupProgress
    $value = Read-SetupInput "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }
    return $value.Trim()
}

function Get-LocalHardwareProfile {
    $ramGb = 0
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $ramGb = [Math]::Round(($computer.TotalPhysicalMemory / 1GB), 1)
    } catch {
        # RAM detection is best effort only.
    }

    $gpuName = ''
    $vramGb = 0
    $gpuLine = $null
    $nvidia = Get-CommandSource -Names @('nvidia-smi.exe', 'nvidia-smi')
    if (-not $nvidia) {
        $candidate = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $nvidia = $candidate
        }
    }
    if ($nvidia) {
        $gpuLine = (& $nvidia --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    }

    if ($gpuLine -match '^\s*(.+?)\s*,\s*(\d+)\s*$') {
        $gpuName = $Matches[1].Trim()
        $vramGb = [Math]::Round(([double]$Matches[2] / 1024.0), 1)
    } else {
        try {
            $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.Name -match '(?i)nvidia' } |
                Select-Object -First 1
            if ($gpu) {
                $gpuName = [string]$gpu.Name
                if ($gpu.AdapterRAM -gt 0) {
                    $vramGb = [Math]::Round(($gpu.AdapterRAM / 1GB), 1)
                }
            }
        } catch {
            # GPU detection is best effort only.
        }
    }

    return [pscustomobject]@{
        RamGb = $ramGb
        GpuName = $gpuName
        VramGb = $vramGb
    }
}

function LocalSummaryModel {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][double]$VramGb,
        [Parameter(Mandatory = $true)][double]$RamGb,
        [Parameter(Mandatory = $true)][string]$Note
    )

    [pscustomobject]@{
        Model = $Model
        Label = $Label
        VramGb = $VramGb
        RamGb = $RamGb
        Note = $Note
    }
}

function Get-LocalSummaryModelOptions {
    return @(
        (LocalSummaryModel -Model 'llama3.1:8b' -Label 'Llama 3.1 8B' -VramGb 6 -RamGb 10 -Note 'Solid entry point for CPU-only use or smaller GPUs'),
        (LocalSummaryModel -Model 'qwen2.5:7b' -Label 'Qwen2.5 7B' -VramGb 6 -RamGb 10 -Note 'Recommended: very fast with strong summary quality'),
        (LocalSummaryModel -Model 'gemma4:e4b' -Label 'Gemma 4 E4B' -VramGb 4 -RamGb 8 -Note 'Very small and fast Gemma option for lightweight summaries'),
        (LocalSummaryModel -Model 'gemma4:12b' -Label 'Gemma 4 12B' -VramGb 9 -RamGb 14 -Note 'Good reasoning and summary quality'),
        (LocalSummaryModel -Model 'qwen2.5:14b' -Label 'Qwen2.5 14B' -VramGb 10 -RamGb 16 -Note 'Stronger quality with good speed'),
        (LocalSummaryModel -Model 'deepseek-r1:14b' -Label 'DeepSeek-R1 14B' -VramGb 10 -RamGb 16 -Note 'Strong reasoning, may answer more verbosely'),
        (LocalSummaryModel -Model 'gemma4:26b' -Label 'Gemma 4 26B' -VramGb 18 -RamGb 24 -Note 'High quality, noticeably heavier'),
        (LocalSummaryModel -Model 'qwen2.5:32b' -Label 'Qwen2.5 32B' -VramGb 22 -RamGb 32 -Note 'Very strong, tight on 24 GB VRAM'),
        (LocalSummaryModel -Model 'deepseek-r1:32b' -Label 'DeepSeek-R1 32B' -VramGb 22 -RamGb 32 -Note 'Very strong reasoning, tight and slower'),
        (LocalSummaryModel -Model 'gemma4:31b' -Label 'Gemma 4 31B' -VramGb 24 -RamGb 32 -Note 'Strongest Gemma 4 in this list, extremely tight'),
        (LocalSummaryModel -Model 'mixtral:8x7b' -Label 'Mixtral 8x7B' -VramGb 28 -RamGb 48 -Note 'MoE model, good quality, high RAM demand'),
        (LocalSummaryModel -Model 'llama3.3:70b' -Label 'Llama 3.3 70B' -VramGb 48 -RamGb 64 -Note 'Very strong, better suited for much more RAM/VRAM'),
        (LocalSummaryModel -Model 'qwen2.5:72b' -Label 'Qwen2.5 72B' -VramGb 48 -RamGb 64 -Note 'Strongest Qwen in this list, very high memory demand'),
        (LocalSummaryModel -Model 'deepseek-r1:70b' -Label 'DeepSeek-R1 70B' -VramGb 48 -RamGb 64 -Note 'Strongest reasoning in this list, very high memory demand')
    )
}

function LocalWhisperModel {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][double]$RamGb,
        [Parameter(Mandatory = $true)][double]$VramGb,
        [Parameter(Mandatory = $true)][string]$Note
    )

    [pscustomobject]@{
        Model = $Model
        Label = $Label
        RamGb = $RamGb
        VramGb = $VramGb
        Note = $Note
    }
}

function Get-LocalWhisperModelOptions {
    return @(
        (LocalWhisperModel -Model 'ggml-base.bin' -Label 'Base' -RamGb 4 -VramGb 0 -Note 'Small download, good default for CPU-only systems'),
        (LocalWhisperModel -Model 'ggml-small.bin' -Label 'Small' -RamGb 8 -VramGb 0 -Note 'Better quality, still reasonable on modern CPUs'),
        (LocalWhisperModel -Model 'ggml-medium.bin' -Label 'Medium' -RamGb 12 -VramGb 6 -Note 'Higher quality, slower without NVIDIA acceleration'),
        (LocalWhisperModel -Model 'ggml-large-v3-turbo.bin' -Label 'Large v3 Turbo' -RamGb 16 -VramGb 8 -Note 'Recommended for NVIDIA/CUDA systems'),
        (LocalWhisperModel -Model 'ggml-large-v3.bin' -Label 'Large v3' -RamGb 24 -VramGb 12 -Note 'Best quality, heavy download and slower startup')
    )
}

function Resolve-WhisperModelName {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][object]$Hardware,
        [Parameter(Mandatory = $true)][bool]$UseCuda
    )

    if ([string]::IsNullOrWhiteSpace($Model) -or $Model -ieq 'auto') {
        if ($UseCuda -and $Hardware.VramGb -ge 8) {
            return 'ggml-large-v3-turbo.bin'
        }
        if ($Hardware.RamGb -ge 10) {
            return 'ggml-small.bin'
        }
        return 'ggml-base.bin'
    }

    $normalized = $Model.Trim()
    switch ($normalized.ToLowerInvariant()) {
        'whisper-1' { return 'ggml-base.bin' }
        'base' { return 'ggml-base.bin' }
        'whisper-base' { return 'ggml-base.bin' }
        'small' { return 'ggml-small.bin' }
        'whisper-small' { return 'ggml-small.bin' }
        'medium' { return 'ggml-medium.bin' }
        'whisper-medium' { return 'ggml-medium.bin' }
        'large-v3-turbo' { return 'ggml-large-v3-turbo.bin' }
        'whisper-large-v3-turbo' { return 'ggml-large-v3-turbo.bin' }
        'large-v3' { return 'ggml-large-v3.bin' }
        'whisper-large-v3' { return 'ggml-large-v3.bin' }
        default { return $normalized }
    }
}

function Get-WhisperModelFit {
    param(
        [Parameter(Mandatory = $true)][object]$Model,
        [Parameter(Mandatory = $true)][object]$Hardware,
        [Parameter(Mandatory = $true)][bool]$UseCuda
    )

    if ($Hardware.RamGb -le 0) {
        return [pscustomobject]@{ Label = 'unknown'; Color = [ConsoleColor]::Yellow }
    }

    $ramRatio = $Hardware.RamGb / [double]$Model.RamGb
    if ($UseCuda -and $Model.VramGb -gt 0 -and $Hardware.VramGb -gt 0) {
        $ratio = [Math]::Min($ramRatio, ($Hardware.VramGb / [double]$Model.VramGb))
    } else {
        $ratio = $ramRatio
    }

    if ($ratio -ge 1.25) {
        return [pscustomobject]@{ Label = 'green'; Color = [ConsoleColor]::Green }
    }
    if ($ratio -ge 0.85) {
        return [pscustomobject]@{ Label = 'yellow'; Color = [ConsoleColor]::Yellow }
    }
    return [pscustomobject]@{ Label = 'red'; Color = [ConsoleColor]::Red }
}

function Read-LocalWhisperModelSelection {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultModel,
        [Parameter(Mandatory = $true)][object]$Hardware,
        [Parameter(Mandatory = $true)][bool]$UseCuda
    )

    $resolvedDefault = Resolve-WhisperModelName -Model $DefaultModel -Hardware $Hardware -UseCuda $UseCuda
    if ($NonInteractive) {
        return $resolvedDefault
    }

    Clear-SetupProgress
    $options = Get-LocalWhisperModelOptions
    $defaultIndex = 0
    for ($i = 0; $i -lt $options.Count; $i++) {
        if ($options[$i].Model -eq $resolvedDefault) {
            $defaultIndex = $i
            break
        }
    }

    Write-Host ''
    Write-ColorLine 'Local Whisper model:' Cyan
    if ($Hardware.GpuName) {
        Write-ColorLine ("  Hardware: {0}, {1} GB VRAM, {2} GB RAM" -f $Hardware.GpuName, $Hardware.VramGb, $Hardware.RamGb) DarkGray
    } else {
        Write-ColorLine ("  Hardware: no NVIDIA VRAM detected, {0} GB RAM" -f $Hardware.RamGb) DarkGray
    }
    Write-ColorLine '  Green = comfortable, yellow = tight, red = likely too slow/heavy.' DarkGray
    Write-ColorLine '  Windows setup downloads whisper.cpp and the selected ggml model.' DarkGray
    Write-Host ''

    for ($i = 0; $i -lt $options.Count; $i++) {
        $option = $options[$i]
        $fit = Get-WhisperModelFit -Model $option -Hardware $Hardware -UseCuda $UseCuda
        $marker = if ($i -eq $defaultIndex) { '*' } else { ' ' }
        $line = "{0}{1,2}. {2,-24} [{3}] needs about {4} GB RAM / {5} GB VRAM - {6}" -f $marker, ($i + 1), $option.Model, $fit.Label, $option.RamGb, $option.VramGb, $option.Note
        Write-ColorLine $line $fit.Color
    }

    while ($true) {
        $value = Read-SetupInput "Choose Whisper model number or file name [$(($defaultIndex + 1))]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $options[$defaultIndex].Model
        }

        $trimmed = $value.Trim()
        $number = 0
        if ([int]::TryParse($trimmed, [ref]$number) -and $number -ge 1 -and $number -le $options.Count) {
            $selected = $options[$number - 1]
        } else {
            $selected = $options | Where-Object { $_.Model -ieq $trimmed } | Select-Object -First 1
            if (-not $selected) {
                Write-ColorLine 'Please enter a listed number or exact ggml model filename.' Yellow
                continue
            }
        }

        $fit = Get-WhisperModelFit -Model $selected -Hardware $Hardware -UseCuda $UseCuda
        if ($fit.Label -eq 'red') {
            if (-not (Read-SetupYesNo -Prompt "Selected model $($selected.Model) is marked red for this hardware. Use it anyway?" -DefaultValue $false)) {
                continue
            }
        }
        return $selected.Model
    }
}

function Get-ModelFit {
    param(
        [Parameter(Mandatory = $true)][object]$Model,
        [Parameter(Mandatory = $true)][object]$Hardware
    )

    if ($Hardware.RamGb -le 0) {
        return [pscustomobject]@{ Label = 'unknown'; Color = [ConsoleColor]::Yellow }
    }

    $ramRatio = $Hardware.RamGb / [double]$Model.RamGb
    if ($Hardware.VramGb -gt 0) {
        $vramRatio = $Hardware.VramGb / [double]$Model.VramGb
        $ratio = [Math]::Min($vramRatio, $ramRatio)
    } else {
        $ratio = $ramRatio
    }

    if ($ratio -ge 1.25) {
        return [pscustomobject]@{ Label = 'green'; Color = [ConsoleColor]::Green }
    }
    if ($ratio -ge 0.85) {
        return [pscustomobject]@{ Label = 'yellow'; Color = [ConsoleColor]::Yellow }
    }
    return [pscustomobject]@{ Label = 'red'; Color = [ConsoleColor]::Red }
}

function Read-LocalSummaryModelSelection {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultModel,
        [Parameter(Mandatory = $true)][object]$Hardware
    )

    if ($NonInteractive) {
        return $DefaultModel
    }

    Clear-SetupProgress
    $options = Get-LocalSummaryModelOptions
    $defaultIndex = -1
    for ($i = 0; $i -lt $options.Count; $i++) {
        if ($options[$i].Model -eq $DefaultModel) {
            $defaultIndex = $i
            break
        }
    }
    if ($defaultIndex -lt 0) {
        for ($i = 0; $i -lt $options.Count; $i++) {
            if ($options[$i].Model -eq 'qwen2.5:7b') {
                $defaultIndex = $i
                break
            }
        }
    }

    Write-Host ''
    Write-ColorLine 'Local AI summary model:' Cyan
    if ($Hardware.GpuName) {
        Write-ColorLine ("  Hardware: {0}, {1} GB VRAM, {2} GB RAM" -f $Hardware.GpuName, $Hardware.VramGb, $Hardware.RamGb) DarkGray
    } else {
        Write-ColorLine ("  Hardware: no NVIDIA VRAM detected, {0} GB RAM" -f $Hardware.RamGb) DarkGray
    }
    Write-ColorLine '  Green = comfortable, yellow = tight, red = likely too large/slow.' DarkGray
    Write-ColorLine '  With NVIDIA VRAM, VRAM and RAM are considered. Without it, RAM-only CPU use is estimated.' DarkGray
    Write-ColorLine '  The list goes from smaller/faster 8B-class models to stronger/larger models.' DarkGray
    Write-Host ''

    for ($i = 0; $i -lt $options.Count; $i++) {
        $option = $options[$i]
        $fit = Get-ModelFit -Model $option -Hardware $Hardware
        $marker = if ($i -eq $defaultIndex) { '*' } else { ' ' }
        $line = "{0}{1,2}. {2,-18} [{3}] needs about {4} GB VRAM / {5} GB RAM - {6}" -f $marker, ($i + 1), $option.Model, $fit.Label, $option.VramGb, $option.RamGb, $option.Note
        Write-ColorLine $line $fit.Color
    }

    while ($true) {
        $value = Read-SetupInput "Choose summary model number or name [$(($defaultIndex + 1))]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $options[$defaultIndex].Model
        }

        $trimmed = $value.Trim()
        $number = 0
        if ([int]::TryParse($trimmed, [ref]$number) -and $number -ge 1 -and $number -le $options.Count) {
            $selected = $options[$number - 1]
        } else {
            $selected = $options | Where-Object { $_.Model -ieq $trimmed } | Select-Object -First 1
            if (-not $selected) {
                Write-ColorLine 'Please enter a listed number or exact model name.' Yellow
                continue
            }
        }

        $fit = Get-ModelFit -Model $selected -Hardware $Hardware
        if ($fit.Label -eq 'red') {
            if (-not (Read-SetupYesNo -Prompt "Selected model $($selected.Model) is marked red for this hardware. Use it anyway?" -DefaultValue $false)) {
                continue
            }
        }
        return $selected.Model
    }
}

function Ensure-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Get-DefaultUrlSummaryPrompt {
    return @'
Summarize the provided webpage content.

Rules:
- Use ONLY information present in the content.
- Never guess or invent missing details.
- Replace vague or clickbait headlines with the specific subject described in the text.
- Prefer concrete facts (names, numbers, results, ingredients, products).
- Remove filler and marketing language.
- Adapt to the content type automatically.

Structure:
- If the content contains multiple distinct aspects (e.g. results, ingredients, steps, features, findings), organize the summary into 2-4 short sections.
- Each section heading MUST be formatted as "## <emoji> <1-3 word title>".
- Do not write a section heading without an emoji.
- Keep section titles very short (1-3 words).
- Each section should contain one concise sentence.
- If the content is simple, write a short paragraph instead (1-3 sentences).

If the content is missing or insufficient, state the reason or describe why a summary cannot be created.
'@.Trim()
}

function Test-LegacyUrlSummaryPrompt {
    param([string]$Prompt)

    return [string]::IsNullOrWhiteSpace($Prompt) -or
        $Prompt.Contains('you MAY organize the summary into 2-4 short sections') -or
        $Prompt.Contains('Each section may have a short "##" heading and one fitting emoji')
}

function Ensure-AppSettings {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][string]$SourceDirectory
    )

    $configPath = Join-Path $TargetDirectory 'appsettings.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        return $configPath
    }

    $templatePath = Join-Path $SourceDirectory 'appsettings.template.json'
    if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
        Copy-Item -LiteralPath $templatePath -Destination $configPath -Force
        return $configPath
    }

    $payload = [ordered]@{
        provider = 'openai'
        model = 'gpt-4o-mini-transcribe'
        language = 'auto'
        apiKey = ''
        apiKeys = [ordered]@{
            openai = ''
            elevenlabs = ''
            gemini = ''
            anthropic = ''
            xai = ''
        }
        openAiAdminKey = ''
        summaryProvider = 'openai'
        summaryModels = [ordered]@{
            openai = 'gpt-5.4-mini'
            gemini = 'gemini-3.5-flash'
            anthropic = 'claude-sonnet-4-6'
            xai = 'grok-4.3'
            localai = 'qwen2.5:7b'
        }
        localAiLlmUrl = 'http://127.0.0.1:11434/api/chat'
        localAiWhisperUrl = 'http://127.0.0.1:8000/v1/audio/transcriptions'
        localWhisperCppExe = ''
        localWhisperCppModelPath = ''
        urlSummaryPrompt = Get-DefaultUrlSummaryPrompt
        appFetchUrl = $true
        hotkey = 'Alt+A'
    }
    Write-Utf8NoBom -Path $configPath -Value (($payload | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $configPath
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    $partialFile = "$OutFile.part"
    if (Test-Path -LiteralPath $partialFile -PathType Leaf) {
        Remove-Item -LiteralPath $partialFile -Force
    }

    $curl = Get-CommandSource -Names @('curl.exe', 'curl')
    if ($curl) {
        & $curl @(
            '--location',
            '--fail',
            '--show-error',
            '--connect-timeout',
            '30',
            '--max-time',
            '7200',
            '--retry',
            '5',
            '--retry-delay',
            '5',
            '--retry-all-errors',
            '--output',
            $partialFile,
            $Uri
        )
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed with exit code ${LASTEXITCODE}: $Uri"
        }
    } else {
        Invoke-WebRequest -Uri $Uri -OutFile $partialFile -UseBasicParsing -TimeoutSec 7200
    }

    $downloaded = Get-Item -LiteralPath $partialFile -ErrorAction Stop
    if ($downloaded.Length -le 0) {
        Remove-Item -LiteralPath $partialFile -Force -ErrorAction SilentlyContinue
        throw "Downloaded file is empty: $Uri"
    }

    Move-Item -LiteralPath $partialFile -Destination $OutFile -Force
}

function Get-WhisperCppAssetName {
    param(
        [Parameter(Mandatory = $true)][bool]$UseCuda,
        [Parameter(Mandatory = $true)][object]$CudaStatus
    )

    if (-not $UseCuda) {
        return 'whisper-bin-x64.zip'
    }

    $cudaAsset = Get-WhisperCppCudaAssetName -CudaStatus $CudaStatus
    if ([string]::IsNullOrWhiteSpace($cudaAsset)) {
        throw 'No compatible whisper.cpp CUDA build is available for the detected NVIDIA/CUDA driver. Use CPU mode or install/update NVIDIA CUDA support manually.'
    }
    return $cudaAsset
}

function Install-WhisperCppWindows {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDirectory,
        [Parameter(Mandatory = $true)][string]$ModelFileName,
        [Parameter(Mandatory = $true)][bool]$UseCuda,
        [Parameter(Mandatory = $true)][object]$CudaStatus
    )

    $release = Invoke-RestMethod -Method Get -Uri $whisperCppReleaseApi
    $assetName = Get-WhisperCppAssetName -UseCuda $UseCuda -CudaStatus $CudaStatus
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) {
        throw "whisper.cpp release $($release.tag_name) does not contain asset $assetName."
    }

    $localAiRoot = Join-Path $TargetDirectory 'local-ai'
    $runtimeRoot = Join-Path $localAiRoot 'whisper.cpp'
    $runtimeDir = Join-Path $runtimeRoot 'runtime'
    $modelsDir = Join-Path $localAiRoot 'whisper-models'
    $downloadDir = Join-Path $runtimeRoot 'downloads'
    New-Item -ItemType Directory -Force -Path $runtimeRoot, $modelsDir, $downloadDir | Out-Null

    $zipPath = Join-Path $downloadDir $assetName
    Write-ColorLine "Downloading whisper.cpp $($release.tag_name) asset $assetName..." Cyan
    Invoke-DownloadFile -Uri $asset.browser_download_url -OutFile $zipPath

    if (Test-Path -LiteralPath $runtimeDir -PathType Container) {
        Remove-Item -LiteralPath $runtimeDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $runtimeDir -Force

    $whisperExe = Get-ChildItem -LiteralPath $runtimeDir -Recurse -Filter 'whisper-cli.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $whisperExe) {
        throw "whisper-cli.exe was not found after extracting $assetName."
    }

    $modelPath = Join-Path $modelsDir $ModelFileName
    $downloadModel = $true
    if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
        $existingModel = Get-Item -LiteralPath $modelPath
        if ($existingModel.Length -gt 0) {
            $downloadModel = $false
            Write-ColorLine "Whisper model already exists: $modelPath" DarkGray
        } else {
            Write-ColorLine "Removing incomplete Whisper model: $modelPath" Yellow
            Remove-Item -LiteralPath $modelPath -Force
        }
    }
    if ($downloadModel) {
        $modelUrl = "$whisperModelBaseUrl/$ModelFileName"
        Write-ColorLine "Downloading Whisper model $ModelFileName..." Cyan
        Invoke-DownloadFile -Uri $modelUrl -OutFile $modelPath
    }

    $manifest = [ordered]@{
        backend = if ($UseCuda) { 'cuda' } else { 'cpu' }
        whisperCppRelease = [string]$release.tag_name
        whisperCppAsset = $assetName
        whisperCppExe = $whisperExe.FullName
        whisperModelPath = $modelPath
        installedAt = (Get-Date).ToString('o')
    }
    Write-Utf8NoBom -Path (Join-Path $runtimeRoot 'echoscribe-whispercpp.json') -Value (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

    return [pscustomobject]@{
        Exe = $whisperExe.FullName
        ModelPath = $modelPath
        Backend = $manifest.backend
        Release = $manifest.whisperCppRelease
        Asset = $assetName
    }
}

function Update-LocalAiConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$HostNameOrIp,
        [Parameter(Mandatory = $true)][bool]$EnableWhisper,
        [Parameter(Mandatory = $true)][bool]$EnableOllama,
        [Parameter(Mandatory = $true)][string]$WhisperModel,
        [Parameter(Mandatory = $true)][string]$OllamaModel,
        [string]$WhisperCppExe = '',
        [string]$WhisperCppModelPath = '',
        [bool]$UseWslWhisper = $false
    )

    if (-not ($EnableWhisper -or $EnableOllama)) {
        return
    }

    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if ($EnableWhisper) {
        Ensure-ObjectProperty -Object $config -Name 'provider' -Value 'localai'
        Ensure-ObjectProperty -Object $config -Name 'model' -Value $WhisperModel
        if ($UseWslWhisper) {
            Ensure-ObjectProperty -Object $config -Name 'localAiWhisperUrl' -Value "http://${HostNameOrIp}:$defaultLocalWhisperPort/v1/audio/transcriptions"
            Ensure-ObjectProperty -Object $config -Name 'localWhisperCppExe' -Value ''
            Ensure-ObjectProperty -Object $config -Name 'localWhisperCppModelPath' -Value ''
        } else {
            Ensure-ObjectProperty -Object $config -Name 'localAiWhisperUrl' -Value 'http://127.0.0.1:8000/v1/audio/transcriptions'
            Ensure-ObjectProperty -Object $config -Name 'localWhisperCppExe' -Value $WhisperCppExe
            Ensure-ObjectProperty -Object $config -Name 'localWhisperCppModelPath' -Value $WhisperCppModelPath
        }
    }

    if ($EnableOllama) {
        Ensure-ObjectProperty -Object $config -Name 'summaryProvider' -Value 'localai'
        Ensure-ObjectProperty -Object $config -Name 'localAiLlmUrl' -Value "http://${HostNameOrIp}:$defaultLocalOllamaPort/api/chat"
        if (-not $config.summaryModels) {
            Ensure-ObjectProperty -Object $config -Name 'summaryModels' -Value ([pscustomobject]@{})
        }
        Ensure-ObjectProperty -Object $config.summaryModels -Name 'localai' -Value $OllamaModel
        if (Test-LegacyUrlSummaryPrompt -Prompt ([string]$config.urlSummaryPrompt)) {
            Ensure-ObjectProperty -Object $config -Name 'urlSummaryPrompt' -Value (Get-DefaultUrlSummaryPrompt)
        }
    }

    Write-Utf8NoBom -Path $ConfigPath -Value (($config | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
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

    Clear-SetupProgress
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    $exitCode = $LASTEXITCODE
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

function Test-DesktopLaunchAvailable {
    if (-not [Environment]::UserInteractive) {
        return $false
    }

    try {
        return ((Get-Process -Id $PID).SessionId -ne 0)
    } catch {
        return $false
    }
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
    throw "EchoScribe is still running and setup cannot safely replace files. Close EchoScribe from the tray or Task Manager, then rerun setup. Remaining process(es): $remainingDetails"
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

    $shortcutDirectory = Split-Path -Parent $Path
    if ($shortcutDirectory) {
        New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.IconLocation = $Target
    $shortcut.Description = 'EchoScribe desktop companion'
    $shortcut.Save()
}

function Remove-Shortcut {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
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

function Remove-EchoScribeStartupEntries {
    param([Parameter(Mandatory = $true)][string]$StartupDirectory)

    Remove-ShortcutGroup -Directory $StartupDirectory -Pattern 'EchoScribe*.lnk'
    Remove-EchoScribeRunEntries
}

function Remove-EchoScribeStartMenuEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ProgramsDirectory,
        [Parameter(Mandatory = $true)][string]$EchoScribeProgramsDirectory
    )

    Remove-ShortcutGroup -Directory $ProgramsDirectory -Pattern 'EchoScribe*.lnk'
    if (Test-Path -LiteralPath $EchoScribeProgramsDirectory -PathType Container) {
        Remove-ShortcutGroup -Directory $EchoScribeProgramsDirectory -Pattern 'EchoScribe*.lnk'
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
        (Browser-Target -Name 'Google Chrome' -Url 'chrome://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        )),
        (Browser-Target -Name 'Microsoft Edge' -Url 'edge://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
        )),
        (Browser-Target -Name 'Brave' -Url 'brave://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'BraveSoftware\Brave-Browser\Application\brave.exe' }),
            (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
        )),
        (Browser-Target -Name 'Chromium' -Url 'chrome://extensions' -ExtensionPath $ChromiumExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Chromium\Application\chrome.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Chromium\Application\chrome.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Chromium\Application\chrome.exe')
        )),
        (Browser-Target -Name 'Firefox' -Url 'about:debugging#/runtime/this-firefox' -ExtensionPath $FirefoxExtensionDirectory -Paths @(
            (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Mozilla Firefox\firefox.exe' }),
            (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
        ))
    )
}

function Start-OptionalProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = ''
    )

    try {
        $parameters = @{
            FilePath = $FilePath
            ErrorAction = 'Stop'
        }
        if ($ArgumentList.Count -gt 0) {
            $parameters.ArgumentList = $ArgumentList
        }
        if ($WorkingDirectory) {
            $parameters.WorkingDirectory = $WorkingDirectory
        }
        Start-Process @parameters | Out-Null
        return $true
    } catch {
        Write-ColorLine "Could not open $Description automatically: $($_.Exception.Message)" Yellow
        return $false
    }
}

function Open-BrowserSetup {
    param(
        [Parameter(Mandatory = $true)][string]$ChromiumExtensionDirectory,
        [Parameter(Mandatory = $true)][string]$FirefoxExtensionDirectory
    )

    $null = Start-OptionalProcess -Description 'Chromium extension folder' -FilePath $ChromiumExtensionDirectory
    if (Test-Path -LiteralPath $FirefoxExtensionDirectory -PathType Container) {
        $null = Start-OptionalProcess -Description 'Firefox extension folder' -FilePath $FirefoxExtensionDirectory
    }

    $targets = Get-BrowserSetupTargets -ChromiumExtensionDirectory $ChromiumExtensionDirectory -FirefoxExtensionDirectory $FirefoxExtensionDirectory
    $opened = @()
    foreach ($target in $targets) {
        if ($target.Executable -and (Start-OptionalProcess -Description "$($target.Name) extension page" -FilePath $target.Executable -ArgumentList @($target.Url))) {
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
$localAiHostName = Get-DefaultLocalAiHost
$localHardware = Get-LocalHardwareProfile
$wslLinuxAvailable = Test-WslLinuxAvailable
$cudaStatus = Get-CudaRuntimeStatus
$installLocalWhisper = [bool]$InstallLocalWhisper
$useWslWhisper = [bool]$UseWslWhisper
$configureLocalOllama = [bool]$ConfigureLocalOllama
$pullLocalOllamaModel = [bool]$PullOllamaModel
$installOllamaWindows = [bool]$InstallOllama
$useWhisperCuda = $false
$whisperCppInstall = $null

if ($NoInstallOllama) {
    $installOllamaWindows = $false
}
if ($useWslWhisper) {
    $installLocalWhisper = $true
}
if ($useWslWhisper -and -not $wslLinuxAvailable) {
    throw 'WSL Local Whisper was requested, but no usable WSL Linux distribution was detected. Use Windows whisper.cpp or install WSL manually first.'
}

Write-Header
Write-Step 1 9 'Preparing package'
$publishDir = Resolve-Or-BuildPackage

Write-Step 2 9 'Checking package'
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
$installLocalWhisper = Read-SetupYesNo -Prompt 'Optional: install local speech-to-text with Windows whisper.cpp?' -DefaultValue $installLocalWhisper
if ($installLocalWhisper -and $wslLinuxAvailable) {
    $useWslWhisper = Read-SetupYesNo -Prompt 'Advanced: use existing WSL Local Whisper instead of Windows whisper.cpp?' -DefaultValue $useWslWhisper
}
if ($installLocalWhisper -and $useWslWhisper -and ([string]::IsNullOrWhiteSpace($LocalWhisperModel) -or $LocalWhisperModel -ieq 'auto')) {
    $LocalWhisperModel = 'whisper-large-v3'
}
if ($installLocalWhisper -and -not $useWslWhisper) {
    $cudaAsset = Get-WhisperCppCudaAssetName -CudaStatus $cudaStatus
    if ($cudaAsset) {
        Write-ColorLine "NVIDIA detected: $($localHardware.GpuName). EchoScribe will not install NVIDIA CUDA drivers or toolkit." DarkGray
        Write-ColorLine "Compatible whisper.cpp CUDA asset: $cudaAsset" DarkGray
        $useWhisperCuda = Read-SetupYesNo -Prompt 'Use the whisper.cpp CUDA build for Local Whisper?' -DefaultValue $true
    } elseif ($localHardware.GpuName -match '(?i)nvidia' -or $cudaStatus.DriverAvailable) {
        $cudaVersionText = if ($cudaStatus.DriverCudaVersion) { $cudaStatus.DriverCudaVersion } else { 'unknown' }
        Write-ColorLine "NVIDIA hardware was detected, but the CUDA driver level ($cudaVersionText) does not match a packaged whisper.cpp CUDA build. Using CPU whisper.cpp unless CUDA support is installed/updated manually and setup is rerun." Yellow
        $useWhisperCuda = $false
    }
    $LocalWhisperModel = Read-LocalWhisperModelSelection -DefaultModel $LocalWhisperModel -Hardware $localHardware -UseCuda $useWhisperCuda
}
$configureLocalOllama = Read-SetupYesNo -Prompt 'Optional: configure Local AI summaries with Ollama for Windows?' -DefaultValue $configureLocalOllama
if ($configureLocalOllama) {
    $localAiHostName = Read-SetupValue -Prompt 'Local AI Ollama host/IP for EchoScribe config' -DefaultValue $localAiHostName
}
if ($configureLocalOllama) {
    $LocalOllamaModel = Read-LocalSummaryModelSelection -DefaultModel $LocalOllamaModel -Hardware $localHardware
}
if ($configureLocalOllama -and (Test-LocalAiHostIsLocal -HostNameOrIp $localAiHostName)) {
    $ollamaFound = [bool](Get-OllamaExecutable) -or (Test-OllamaApi)
    if (-not $ollamaFound -and -not $NoInstallOllama) {
        $installOllamaWindows = Read-SetupYesNo -Prompt 'Ollama was not found. Install Ollama for Windows now?' -DefaultValue $true
    }
}
if ($configureLocalOllama) {
    $pullDefault = $true
    if ($NonInteractive) {
        $pullDefault = $pullLocalOllamaModel
    }
    $pullLocalOllamaModel = Read-SetupYesNo -Prompt "Download/check Ollama model ${LocalOllamaModel} now?" -DefaultValue $pullDefault
}
$startAfterInstall = Read-SetupYesNo -Prompt 'Start EchoScribe after setup?' -DefaultValue $startAfterInstall

if (-not $NonInteractive) {
    Write-Host ''
    Write-ColorLine 'Setup summary' Cyan
    Write-ColorLine "  Source:            $publishDir" DarkGray
    Write-ColorLine "  Install folder:    $targetDir" DarkGray
    Write-ColorLine "  Autostart:         $enableAutostart" DarkGray
    Write-ColorLine "  Browser extension: $enableBrowserExtension" DarkGray
    Write-ColorLine "  Local Whisper:     $installLocalWhisper" DarkGray
    if ($installLocalWhisper) {
        $whisperModeLabel = if ($useWslWhisper) { 'advanced WSL' } else { 'Windows whisper.cpp' }
        Write-ColorLine "  Whisper mode:      $whisperModeLabel" DarkGray
        Write-ColorLine "  Whisper model:     $LocalWhisperModel" DarkGray
        if (-not $useWslWhisper) {
            Write-ColorLine "  Whisper CUDA:      $useWhisperCuda" DarkGray
        }
    }
    Write-ColorLine "  Local Ollama:      $configureLocalOllama" DarkGray
    if ($configureLocalOllama) {
        Write-ColorLine "  Ollama host:       $localAiHostName" DarkGray
        Write-ColorLine "  Install Ollama:    $installOllamaWindows" DarkGray
        Write-ColorLine "  Ollama model:      $LocalOllamaModel" DarkGray
        Write-ColorLine "  Pull model:        $pullLocalOllamaModel" DarkGray
    }
    Write-ColorLine "  Start after setup: $startAfterInstall" DarkGray
    Write-Host ''
    $continue = Read-SetupInput 'Press Enter to install or type q to cancel'
    $continueChoice = $continue.Trim().ToLowerInvariant()
    if ($continueChoice -eq 'q') {
        Write-ColorLine 'Setup canceled.' Yellow
        exit 0
    }
}

Write-Step 3 9 'Stopping running EchoScribe processes'
Stop-RunningEchoScribe

Write-Step 4 9 "Copying files to $targetDir"
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

Write-Step 5 9 'Configuring local AI'
$appSettingsPath = Ensure-AppSettings -TargetDirectory $targetDir -SourceDirectory $publishDir
if ($installLocalWhisper -and $useWslWhisper) {
    $localAiInstaller = Join-Path $scriptRoot 'install-local-ai-wsl.ps1'
    Assert-File $localAiInstaller
    $localAiArguments = @(
        '-WhisperModel',
        $LocalWhisperModel,
        '-WhisperPort',
        [string]$defaultLocalWhisperPort,
        '-OllamaModel',
        $LocalOllamaModel,
        '-InstallWhisper'
    )
    Invoke-CheckedScript -Path $localAiInstaller -Arguments $localAiArguments
}
if ($installLocalWhisper -and -not $useWslWhisper) {
    $whisperCppInstall = Install-WhisperCppWindows -TargetDirectory $targetDir -ModelFileName $LocalWhisperModel -UseCuda $useWhisperCuda -CudaStatus $cudaStatus
}
if ($configureLocalOllama -and (Test-LocalAiHostIsLocal -HostNameOrIp $localAiHostName)) {
    Ensure-OllamaWindows -AllowInstall $installOllamaWindows
}
if ($pullLocalOllamaModel) {
    Invoke-OllamaPull -Model $LocalOllamaModel -HostNameOrIp $localAiHostName
}
$whisperCppExe = if ($whisperCppInstall) { [string]$whisperCppInstall.Exe } else { '' }
$whisperCppModelPath = if ($whisperCppInstall) { [string]$whisperCppInstall.ModelPath } else { '' }
Update-LocalAiConfig -ConfigPath $appSettingsPath -HostNameOrIp $localAiHostName -EnableWhisper $installLocalWhisper -EnableOllama $configureLocalOllama -WhisperModel $LocalWhisperModel -OllamaModel $LocalOllamaModel -WhisperCppExe $whisperCppExe -WhisperCppModelPath $whisperCppModelPath -UseWslWhisper $useWslWhisper

Write-Step 6 9 'Registering browser native hosts'
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

Write-Step 7 9 'Creating shortcuts'
$programsDir = [Environment]::GetFolderPath('Programs')
$startMenuDir = Join-Path $programsDir 'EchoScribe'
$startMenuShortcut = Join-Path $startMenuDir 'EchoScribe.lnk'
Remove-EchoScribeStartMenuEntries -ProgramsDirectory $programsDir -EchoScribeProgramsDirectory $startMenuDir
New-Shortcut -Path $startMenuShortcut -Target $appExe -WorkingDirectory $targetDir

$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDir 'EchoScribe.lnk'
Remove-EchoScribeStartupEntries -StartupDirectory $startupDir
if ($enableAutostart) {
    New-Shortcut -Path $startupShortcut -Target $appExe -WorkingDirectory $targetDir
} else {
    Remove-Shortcut -Path $startupShortcut
}

Write-Step 8 9 'Opening optional setup pages'
if ($openBrowserSetup) {
    if (Test-DesktopLaunchAvailable) {
        Open-BrowserSetup -ChromiumExtensionDirectory $chromiumExtensionDir -FirefoxExtensionDirectory $firefoxExtensionDir
    } else {
        Write-ColorLine 'Skipping optional browser setup pages because setup is running without an interactive Windows desktop session.' Yellow
    }
}
if ($startAfterInstall) {
    if (Test-DesktopLaunchAvailable) {
        $null = Start-OptionalProcess -Description 'EchoScribe' -FilePath $appExe -WorkingDirectory $targetDir
    } else {
        Write-ColorLine 'Skipping EchoScribe start because setup is running without an interactive Windows desktop session.' Yellow
    }
}

Write-Step 9 9 'Setup complete'
Write-Progress -Activity 'Installing EchoScribe' -Completed

$localWhisperMode = if ($installLocalWhisper) {
    if ($useWslWhisper) { 'wsl' } else { 'windows-whisper.cpp' }
} else {
    'disabled'
}
$result = [ordered]@{
    InstallDirectory = $targetDir
    App = $appExe
    Autostart = $enableAutostart
    StartupShortcut = $startupShortcut
    StartMenuShortcut = $startMenuShortcut
    BrowserExtension = $enableBrowserExtension
    LocalWhisper = $installLocalWhisper
    LocalWhisperMode = $localWhisperMode
    LocalWhisperCuda = $useWhisperCuda
    LocalOllama = $configureLocalOllama
    OllamaInstalledBySetup = $installOllamaWindows
    LocalAiHost = $localAiHostName
    LocalAiConfig = $appSettingsPath
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
