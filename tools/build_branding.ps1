param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

# These supplied SVGs contain outlined paths and flat CSS fills. Render the
# original vectors, not screenshots; omit artboard backgrounds for UI assets.
function Read-BrandDrawing([string]$path) {
    [xml]$svg = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $colors = @{}
    foreach ($style in $svg.SelectNodes('//*[local-name()="style"]')) {
        foreach ($match in [regex]::Matches($style.InnerText, '\.([\w-]+)\s*\{[^}]*fill:\s*(#[\da-fA-F]{6})')) {
            $colors[$match.Groups[1].Value] = $match.Groups[2].Value
        }
    }
    $drawing = New-Object Windows.Media.DrawingGroup
    foreach ($pathNode in $svg.SelectNodes('//*[local-name()="path"]')) {
        if ($pathNode.HasAttribute('transform')) { throw 'Transformed paths need explicit SVG support.' }
        $fill = if ($pathNode.HasAttribute('fill')) { $pathNode.GetAttribute('fill') } else { $colors[$pathNode.GetAttribute('class')] }
        if (-not $fill) { throw 'A branding path is missing its fill.' }
        $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($fill)
        $geometry = [Windows.Media.Geometry]::Parse('F1 ' + $pathNode.GetAttribute('d'))
        $drawing.Children.Add([Windows.Media.GeometryDrawing]::new($brush,$null,$geometry))
    }
    if (-not $drawing.Children.Count) { throw 'No outlined artwork found.' }
    $drawing.Freeze()
    return $drawing
}

function Render-Brand($drawing, [int]$width, [int]$height, [double]$padding=0.09) {
    $bounds=$drawing.Bounds
    $scale=[Math]::Min($width*(1-2*$padding)/$bounds.Width,$height*(1-2*$padding)/$bounds.Height)
    $visual=New-Object Windows.Media.DrawingVisual
    $context=$visual.RenderOpen()
    $context.PushTransform([Windows.Media.TranslateTransform]::new(($width-$bounds.Width*$scale)/2,($height-$bounds.Height*$scale)/2))
    $context.PushTransform([Windows.Media.ScaleTransform]::new($scale,$scale))
    $context.PushTransform([Windows.Media.TranslateTransform]::new(-$bounds.X,-$bounds.Y))
    $context.DrawDrawing($drawing)
    $context.Pop();$context.Pop();$context.Pop();$context.Close()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual);$bitmap.Freeze()
    return $bitmap
}

function Get-PngBytes($bitmap) {
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=New-Object IO.MemoryStream
    try { $encoder.Save($stream); return ,$stream.ToArray() } finally { $stream.Dispose() }
}

function Write-BrandIcon($drawing,[string]$path) {
    $sizes=@(16,20,24,32,40,48,64,128,256)
    $frames=@(foreach($size in $sizes){ ,(Get-PngBytes (Render-Brand $drawing $size $size)) })
    $stream=[IO.File]::Create($path);$writer=[IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
        $offset=6+16*$sizes.Count
        for($i=0;$i -lt $sizes.Count;$i++) {
            $dimension=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
            $writer.Write([byte]$dimension);$writer.Write([byte]$dimension)
            $writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([uint16]1);$writer.Write([uint16]32)
            $writer.Write([uint32]$frames[$i].Length);$writer.Write([uint32]$offset)
            $offset+=$frames[$i].Length
        }
        foreach($frame in $frames){$writer.Write([byte[]]$frame)}
    } finally {$writer.Dispose();$stream.Dispose()}
}

$assets=Join-Path $Root 'assets'
$symbol=Read-BrandDrawing (Join-Path $assets 'branding\SVG\Logo Purple.svg')
[IO.File]::WriteAllBytes((Join-Path $assets 'YapLoq-symbol.png'),(Get-PngBytes (Render-Brand $symbol 1024 1024)))
[IO.File]::WriteAllBytes((Join-Path $assets 'YapLoq-icon.png'),(Get-PngBytes (Render-Brand $symbol 256 256)))
[IO.File]::WriteAllBytes((Join-Path $assets 'YapLoq-logo.png'),(Get-PngBytes (Render-Brand $symbol 1024 1024)))
Write-BrandIcon $symbol (Join-Path $assets 'YapLoq.ico')
Write-BrandIcon $symbol (Join-Path $assets 'YapLoq-tray.ico')
'Branding PNGs and multi-resolution Windows icons generated from the supplied SVGs.'
