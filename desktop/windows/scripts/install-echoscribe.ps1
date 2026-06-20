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
    [switch]$ConfigureLocalOllama,
    [switch]$PullOllamaModel,
    [string]$LocalAiHost,
    [string]$LocalWhisperModel = 'whisper-large-v3',
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

function Read-SetupPath {
    param([Parameter(Mandatory = $true)][string]$DefaultValue)

    if ($NonInteractive) {
        return $DefaultValue
    }

    Clear-SetupProgress
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

    Clear-SetupProgress
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

function Get-DefaultLocalAiHost {
    if (-not [string]::IsNullOrWhiteSpace($LocalAiHost)) {
        return $LocalAiHost.Trim()
    }

    return '127.0.0.1'
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
    $value = Read-Host "$Prompt [$DefaultValue]"
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
    $nvidia = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($nvidia) {
        $gpuLine = (& $nvidia.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    }

    $wsl = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
    if (-not $gpuLine -and $wsl) {
        $gpuLine = (& $wsl.Source -- bash -lc '/usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true' 2>$null | Select-Object -First 1)
    }

    if ($gpuLine -match '^\s*(.+?)\s*,\s*(\d+)\s*$') {
        $gpuName = $Matches[1].Trim()
        $vramGb = [Math]::Round(([double]$Matches[2] / 1024.0), 1)
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
        $value = Read-Host "Choose summary model number or name [$(($defaultIndex + 1))]"
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
        urlSummaryPrompt = Get-DefaultUrlSummaryPrompt
        appFetchUrl = $true
        hotkey = 'Alt+A'
    }
    Write-Utf8NoBom -Path $configPath -Value (($payload | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $configPath
}

function Update-LocalAiConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$HostNameOrIp,
        [Parameter(Mandatory = $true)][bool]$EnableWhisper,
        [Parameter(Mandatory = $true)][bool]$EnableOllama,
        [Parameter(Mandatory = $true)][string]$WhisperModel,
        [Parameter(Mandatory = $true)][string]$OllamaModel
    )

    if (-not ($EnableWhisper -or $EnableOllama)) {
        return
    }

    $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if ($EnableWhisper) {
        Ensure-ObjectProperty -Object $config -Name 'provider' -Value 'localai'
        Ensure-ObjectProperty -Object $config -Name 'model' -Value $WhisperModel
        Ensure-ObjectProperty -Object $config -Name 'localAiWhisperUrl' -Value "http://${HostNameOrIp}:$defaultLocalWhisperPort/v1/audio/transcriptions"
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
$localAiHostName = Get-DefaultLocalAiHost
$localHardware = Get-LocalHardwareProfile
$installLocalWhisper = [bool]$InstallLocalWhisper
$configureLocalOllama = [bool]$ConfigureLocalOllama
$pullLocalOllamaModel = [bool]$PullOllamaModel

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
$installLocalWhisper = Read-SetupYesNo -Prompt 'Install/start local Whisper Large (CUDA) in WSL and use it for dictation?' -DefaultValue $installLocalWhisper
$configureLocalOllama = Read-SetupYesNo -Prompt "Configure Local AI summaries with Ollama?" -DefaultValue $configureLocalOllama
if ($configureLocalOllama) {
    $LocalOllamaModel = Read-LocalSummaryModelSelection -DefaultModel $LocalOllamaModel -Hardware $localHardware
}
if ($installLocalWhisper -or $configureLocalOllama) {
    $localAiHostName = Read-SetupValue -Prompt 'Local AI host/IP for EchoScribe config' -DefaultValue $localAiHostName
}
if ($configureLocalOllama) {
    $pullLocalOllamaModel = Read-SetupYesNo -Prompt "Download/check Ollama model ${LocalOllamaModel} now?" -DefaultValue $pullLocalOllamaModel
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
    Write-ColorLine "  Local Ollama:      $configureLocalOllama" DarkGray
    if ($installLocalWhisper -or $configureLocalOllama) {
        Write-ColorLine "  Local AI host:     $localAiHostName" DarkGray
    }
    if ($configureLocalOllama) {
        Write-ColorLine "  Ollama model:      $LocalOllamaModel" DarkGray
    }
    Write-ColorLine "  Start after setup: $startAfterInstall" DarkGray
    Write-Host ''
    $continue = Read-Host 'Press Enter to install or type q to cancel'
    if ($continue.Trim().ToLowerInvariant() -eq 'q') {
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
if ($installLocalWhisper -or $pullLocalOllamaModel) {
    $localAiInstaller = Join-Path $scriptRoot 'install-local-ai-wsl.ps1'
    Assert-File $localAiInstaller
    $localAiArguments = @(
        '-WhisperModel',
        $LocalWhisperModel,
        '-WhisperPort',
        [string]$defaultLocalWhisperPort,
        '-OllamaModel',
        $LocalOllamaModel
    )
    if ($installLocalWhisper) {
        $localAiArguments += '-InstallWhisper'
    }
    if ($pullLocalOllamaModel) {
        $localAiArguments += '-PullOllamaModel'
    }
    Invoke-CheckedScript -Path $localAiInstaller -Arguments $localAiArguments
}
Update-LocalAiConfig -ConfigPath $appSettingsPath -HostNameOrIp $localAiHostName -EnableWhisper $installLocalWhisper -EnableOllama $configureLocalOllama -WhisperModel $LocalWhisperModel -OllamaModel $LocalOllamaModel

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
$startMenuShortcut = Join-Path $programsDir 'EchoScribe.lnk'
New-Shortcut -Path $startMenuShortcut -Target $appExe -WorkingDirectory $targetDir

$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDir 'EchoScribe.lnk'
if ($enableAutostart) {
    New-Shortcut -Path $startupShortcut -Target $appExe -WorkingDirectory $targetDir
} else {
    Remove-Shortcut -Path $startupShortcut
}

Write-Step 8 9 'Opening optional setup pages'
if ($openBrowserSetup) {
    Open-BrowserSetup -ChromiumExtensionDirectory $chromiumExtensionDir -FirefoxExtensionDirectory $firefoxExtensionDir
}
if ($startAfterInstall) {
    Start-Process -FilePath $appExe -WorkingDirectory $targetDir
}

Write-Step 9 9 'Setup complete'
Write-Progress -Activity 'Installing EchoScribe' -Completed

$result = [ordered]@{
    InstallDirectory = $targetDir
    App = $appExe
    Autostart = $enableAutostart
    StartupShortcut = $startupShortcut
    StartMenuShortcut = $startMenuShortcut
    BrowserExtension = $enableBrowserExtension
    LocalWhisper = $installLocalWhisper
    LocalOllama = $configureLocalOllama
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
