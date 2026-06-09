$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ((Split-Path -Leaf $scriptRoot) -eq 'scripts') {
    Split-Path -Parent $scriptRoot
} else {
    $scriptRoot
}
$repoRoot = Split-Path -Parent (Split-Path -Parent $root)
$source = Join-Path $repoRoot 'assets\images\logo.png'
$out = Join-Path $root 'app.ico'
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngs = New-Object System.Collections.Generic.List[object]
$browserIconDir = Join-Path (Split-Path -Parent $root) 'browser-extension\icons'
New-Item -ItemType Directory -Force -Path $browserIconDir | Out-Null

if (-not (Test-Path -LiteralPath $source)) {
    throw "EchoScribe logo not found: $source"
}

$logo = [System.Drawing.Image]::FromFile($source)
try {
    foreach ($size in $sizes) {
        $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $scale = [Math]::Min($size / $logo.Width, $size / $logo.Height)
        $width = [int][Math]::Round($logo.Width * $scale)
        $height = [int][Math]::Round($logo.Height * $scale)
        $x = [int][Math]::Round(($size - $width) / 2)
        $y = [int][Math]::Round(($size - $height) / 2)
        $graphics.DrawImage($logo, $x, $y, $width, $height)

        $ms = [System.IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $pngs.Add([pscustomobject]@{ Size = $size; Bytes = $bytes }) | Out-Null

        if ($size -in @(16, 32, 48, 128)) {
            [System.IO.File]::WriteAllBytes((Join-Path $browserIconDir "icon-$size.png"), $bytes)
        }

        $graphics.Dispose()
        $bmp.Dispose()
        $ms.Dispose()
    }
}
finally {
    $logo.Dispose()
}

$fs = [System.IO.File]::Create($out)
$writer = [System.IO.BinaryWriter]::new($fs)
$writer.Write([UInt16]0)
$writer.Write([UInt16]1)
$writer.Write([UInt16]$pngs.Count)
$offset = 6 + (16 * $pngs.Count)

foreach ($png in $pngs) {
    $dimension = if ($png.Size -eq 256) { 0 } else { $png.Size }
    $writer.Write([byte]$dimension)
    $writer.Write([byte]$dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]32)
    $writer.Write([UInt32]$png.Bytes.Length)
    $writer.Write([UInt32]$offset)
    $offset += $png.Bytes.Length
}

foreach ($png in $pngs) {
    $writer.Write([byte[]]$png.Bytes)
}

$writer.Dispose()
$fs.Dispose()

Write-Host "Wrote $out"
Write-Host "Wrote browser icons to $browserIconDir"
