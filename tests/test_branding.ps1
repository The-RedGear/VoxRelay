param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing,WindowsFormsIntegration
$resourceRoot=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $resourceRoot 'YapLoq.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $fn.Extent.Text}
Initialize-RoundedChrome
$window=Load-Xaml (Join-Path $resourceRoot 'YapLoq.xaml')
Apply-AppFont $window;Initialize-AppBranding
if($window.FindName('AppVersionLabel').VerticalAlignment -ne 'Center'){throw 'Title version is not vertically aligned'}
if((Get-Content -LiteralPath (Join-Path $resourceRoot 'YapLoq.xaml') -Raw) -match 'Voice Automation|V O I C E   A U T O M A T I O N'){throw 'Header taglines should be removed'}
if($window.Icon.PixelWidth -ne 256){throw 'Window icon is not using the high-resolution artwork'}
foreach($name in @('TitleBrandLogo','SidebarBrandLogo','AboutBrandLogo')){
    $image=$window.FindName($name)
    if(-not $image.Source -or $image.Source.PixelWidth -lt 256){throw "Missing brand artwork: $name"}
}
$configDir=Join-Path $resourceRoot 'data/nonexistent-brand-test'
if((Get-TrayIconPath) -ne (Join-Path $resourceRoot 'assets\YapLoq-tray.ico')){throw 'Tray is using cached legacy artwork'}
foreach($name in @('YapLoq.ico','YapLoq-tray.ico')){
    $bytes=[IO.File]::ReadAllBytes((Join-Path $resourceRoot ('assets\'+$name)))
    if([BitConverter]::ToUInt16($bytes,2) -ne 1 -or [BitConverter]::ToUInt16($bytes,4) -ne 9){throw 'Missing icon resolutions'}
    for($i=0;$i -lt 9;$i++){
        $offset=[BitConverter]::ToUInt32($bytes,6+16*$i+12)
        $size=[BitConverter]::ToUInt32($bytes,6+16*$i+8)
        $stream=[IO.MemoryStream]::new($bytes,$offset,$size)
        try{
            $decoder=[Windows.Media.Imaging.PngBitmapDecoder]::new($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $frame=$decoder.Frames[0]
            $pixel=New-Object byte[] 4
            $frame.CopyPixels([Windows.Int32Rect]::new(0,0,1,1),$pixel,4,0)
            if($pixel[3] -ne 0){throw 'Icon corners should be transparent'}
        }finally{$stream.Dispose()}
    }
    $icon=[Drawing.Icon]::new((Join-Path $resourceRoot ('assets\'+$name)),32,32)
    if($icon.Width -ne 32){throw 'Windows cannot read the icon'};$icon.Dispose()
}
$window.WindowStartupLocation='Manual';$window.Left=-20000;$window.Top=-20000;$window.ShowInTaskbar=$false;$window.ShowActivated=$false
$window.Show()
foreach($width in @(980,1180,1600)){
    $window.Width=$width;$window.UpdateLayout()
    foreach($name in @('TitleBrandLogo','SidebarBrandLogo')){
        $image=$window.FindName($name)
        if($image.ActualHeight -lt 20 -or $image.ActualWidth -lt 20){throw "Brand is clipped at $width"}
    }
    if($OutputDirectory){
        [void][IO.Directory]::CreateDirectory($OutputDirectory)
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create((Join-Path $OutputDirectory "branding-$width.png"))
        try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
}
$window.Close()
'Brand logo placement, transparent icon frames, Windows ICO compatibility and tray source passed at three widths.'
