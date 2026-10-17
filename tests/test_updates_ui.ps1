param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$resourceRoot=Split-Path -Parent $PSScriptRoot
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $resourceRoot 'YapLoq.ps1'),[ref]$tokens,[ref]$errors)
foreach($fn in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $fn.Extent.Text}
foreach($asset in @('Updates.ps1','ApplyUpdate.ps1')){
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $resourceRoot ('assets/'+$asset)),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
}
Initialize-RoundedChrome
$window=Load-Xaml (Join-Path $resourceRoot 'YapLoq.xaml')
$CheckUpdatesButton=$window.FindName('CheckUpdatesButton')
. (Join-Path $resourceRoot 'assets/Updates.ps1')
$script:updateInfo=[pscustomobject]@{state='available';available=$true;compatible=$true;currentVersion='0.5.0';version='v0.6.0';channel='stable';notes="## Better speech`n- Faster queues`n- Reliable updates";message='YapLoq v0.6.0 is available.';size=10485760}
$window.ShowInTaskbar=$false;$window.WindowStartupLocation='Manual';$window.Left=-20000;$window.Top=-20000
$window.Show();$window.UpdateLayout()
Show-YapLoqUpdates
$d=$script:updateDialog;$d.Left=-20000;$d.Top=-20000;$d.UpdateLayout()
if($window.FindName('TitleUpdateButton').Parent -ne $window.FindName('AppVersionLabel').Parent){throw 'Update icon is not beside the version'}
if($window.FindName('TitleUpdateButton').Foreground.Color.ToString() -ne '#FF87C9AF'){throw 'Update icon is not mint'}
if($d.FindName('UpdatePrimary').Content -ne 'Download update'){throw 'Available state lacks Download update'}
if($d.WindowStyle -ne 'None' -or -not $d.AllowsTransparency){throw 'Update window does not use YapLoq chrome'}
if($d.FindName('UpdatePrimary').Style -ne $window.FindResource('PrimaryButton')){throw 'Update action does not use the standard app primary style'}
if($d.FindName('UpdateDetails')){throw 'Obsolete details dropdown is still present'}
if($d.FindName('UpdateCheckAgain') -or $d.FindName('UpdateLater')){throw 'Update window has redundant check or close controls'}
if(-not $d.FindName('UpdateBrandLogo').Source){throw 'Update title bar is missing YapLoq branding'}
if($d.FindName('UpdateNotes').Text -notlike '*Faster queues*'){throw 'Release notes missing'}
$savedNotes=$script:updateInfo.notes;$script:updateInfo.notes='';$script:updateInfo.state='current';Update-YapLoqUpdateWindow
if($d.FindName('UpdateNotesCard').Visibility -ne 'Visible' -or $d.FindName('UpdateNotes').Text -notlike 'Patch notes*'){throw 'Patch-notes panel disappeared without a published release'}
$script:updateInfo.notes=$savedNotes
$script:updateInfo.state='downloading';$script:updateInfo|Add-Member NoteProperty progress 45 -Force
Update-YapLoqUpdateWindow
if($d.FindName('UpdatePrimary').Content -ne 'Cancel download' -or $d.FindName('UpdateProgress').Value -ne 45){throw 'Download progress state failed'}
$script:updateInfo.state='ready';Update-YapLoqUpdateWindow
if($d.FindName('UpdatePrimary').Content -ne 'Restart & update'){throw 'Ready state failed'}
$script:updateWhenIdle=$true;Update-YapLoqUpdateWindow
if($d.FindName('UpdatePrimary').Content -ne 'Cancel scheduled update'){throw 'Waiting update cannot be cancelled'}
$script:updateWhenIdle=$false;$script:updateInfo.state='available';Update-YapLoqUpdateWindow
function Start-YapLoqUpdateRequest($command){$script:requestedUpdate=$command}
Invoke-YapLoqUpdatePrimary
if($script:requestedUpdate -ne 'download'){throw 'Download button did not request background download'}
if($OutputDirectory){
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $d.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$d.ActualWidth,[int]$d.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($d)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $OutputDirectory 'updates-review.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
$closeButton=$d.FindName('UpdateClose');$closedDialog=$d
Remove-Variable d
$closeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
if($closedDialog.IsVisible -or $script:updateDialog){throw 'Title-bar close button did not close the updater'}
$window.Close()
Write-Output 'Update window states, app styling, placement, progress and primary actions passed.'
