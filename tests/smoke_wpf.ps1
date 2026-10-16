param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root = Split-Path -Parent $PSScriptRoot
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'VoxRelay.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$reader = [Xml.XmlReader]::Create((Join-Path $root 'VoxRelay.xaml'))
try { $window=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$visual=$window.Content
$visual.SetValue([Windows.Documents.TextElement]::ForegroundProperty,$window.Foreground)
$visual.SetValue([Windows.Documents.TextElement]::FontFamilyProperty,[Windows.Media.FontFamily]::new([Uri]::new((Join-Path $root 'assets/fonts/Poppins/')),'./#Poppins'))
$window.FindName('AliasGrid').ItemsSource=@([pscustomobject]@{Name='Windows voice';Profile='Microsoft David Desktop - Windows voices';Group='Favorites';Model='sapi';Speed='1.0'})
$window.FindName('AliasProviderFilter').ItemsSource=@('All engines','VoiceStudio','Amazon Polly','Windows voices')
$window.FindName('AliasProviderFilter').SelectedIndex=0
$window.FindName('QueueGrid').ItemsSource=@([pscustomobject]@{Status='Playing';Alias='Windows voice';User='viewer';Text='VoxRelay is ready.'})
$window.WindowStartupLocation='Manual';$window.Left=-20000;$window.Top=-20000
$window.ShowInTaskbar=$false;$window.ShowActivated=$false
$window.Show()
$pageNames=@('VoicesPage','PlaygroundPage','QueuePage','HistoryPage','RulesPage','PronunciationPage','StreamerBotPage','VoiceStudioPage','PollyPage','SettingsPage','ActivityPage')
foreach ($size in @(@(1180,760),@(980,640),@(936,516))) {
    foreach ($name in $pageNames) {
        foreach ($other in $pageNames) { $window.FindName($other).Visibility = if($name -eq $other){'Visible'}else{'Collapsed'} }
        $window.FindName('PageTitle').Text=$name.Replace('Page','')
        $window.FindName('SavePageButton').Visibility=if($name -in @('SettingsPage','RulesPage','StreamerBotPage','VoiceStudioPage','PollyPage')){'Visible'}else{'Collapsed'}
        $window.Width=$size[0];$window.Height=$size[1]
        $window.MinWidth=[Math]::Min(980,$size[0]);$window.MinHeight=[Math]::Min(640,$size[1])
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
        $visual.Measure([Windows.Size]::new($size[0],$size[1]))
        $visual.Arrange([Windows.Rect]::new(0,0,$size[0],$size[1]))
        $visual.UpdateLayout()
        if($OutputDirectory) {
            [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($size[0],$size[1],96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($visual)
            $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
            $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $path=Join-Path $OutputDirectory ($name+'-'+$size[0]+'.png')
            $stream=[IO.File]::Create($path)
            try{$encoder.Save($stream)}finally{$stream.Dispose()}
        }
    }
}
$window.Close()
'WPF markup, PowerShell syntax and 11 pages at three window sizes passed (including the space available at 200% on 1080p).'
