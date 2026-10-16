param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing,System.Security
$appRoot = Split-Path -Parent $PSScriptRoot
$resourceRoot = $appRoot
$configDir = Join-Path $appRoot ('data/ui-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($configDir)
$configPath = Join-Path $configDir 'settings.json'
$logPath = Join-Path $configDir 'bridge.log'
$legacyConfigDir = Join-Path $configDir 'no-legacy'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $appRoot 'VoxRelay.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) { Invoke-Expression $definition.Extent.Text }
Initialize-RoundedChrome
$window=Load-Xaml (Join-Path $appRoot 'VoxRelay.xaml')
[xml]$markup=Get-Content -LiteralPath (Join-Path $appRoot 'VoxRelay.xaml') -Raw
foreach($node in $markup.SelectNodes('//*[@Name]')){Set-Variable -Name $node.GetAttribute('Name') -Value $window.FindName($node.GetAttribute('Name'))}
$script:profiles=@{}; $script:profileModels=@{}; $script:profileModelOptions=@{}; $script:servicesExpanded=$true; $script:loadingSettings=$false
Apply-AppFont $window
. (Join-Path $resourceRoot 'assets/RuleEditors.ps1')
Install-NumericEditors
Install-ProfanityEditor
Refresh-Grid
$script:isPreview=$true
. (Join-Path $resourceRoot 'assets/YapLoqShell.ps1')
Install-YapLoqShell
if (($script:yaploqNav.Keys | Sort-Object) -join ',' -ne 'Dashboard,Integrations,Queue,Services,Settings,Voices') { throw 'Expected exactly six navigation entries' }
if ($VoicesNav.Parent) { throw 'Legacy navigation is still in the visible shell' }
if ($PlaylistGrid.Parent.Parent.Parent.Parent -eq $RulesPage.Content) { throw 'Playlist editor still belongs to message rules' }
if (-not $script:yaploqPages.playlists.Content.Children.Count) { throw 'Playlist editor was lost' }
if ($window.FindName('AutoVoiceRulesExpander').Parent.Parent -ne $RulesPage.Content) { throw 'Voice rules are not in the shared rules workspace' }
if ($PlayStopButton.Visibility -ne 'Collapsed') { throw 'Dashboard duplicates player stop' }
if ($PlayVoiceList.Items.Count -ne 1) { throw 'Dashboard lost voice selection' }
if ($HttpBox.IsEnabled -or $EnableUdpCheck.IsEnabled) { throw 'Preview connection boundaries are editable' }
$sample=[pscustomobject]@{queue=@([pscustomobject]@{id='one';alias='Windows';text='Test message'})}
Update-YapLoqDashboard $sample
if ($script:dashboardUpcoming.Children.Count -ne 1 -or $script:dashboardUpcoming.Children[0].Text -notlike '*Test message') { throw 'Dashboard queue preview lost canonical state' }
Update-YapLoqDashboard ([pscustomobject]@{queue=@()})
if ($script:dashboardUpcoming.Children[0].Text -ne 'Queue empty') { throw 'Queue empty state missing' }
function Invoke-BridgePost([string]$path,$body=@{}) { $script:recordedRequest=$path }
Open-YapLoqRoute 'emergency-stop'
if ($script:recordedRequest -ne '/clear-all') { throw 'Emergency stop is not wired to the real queue endpoint' }
$script:yaploqNav.Voices.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
if ($script:activePage -ne 'voices') { throw 'Sidebar click is not wired to navigation' }
$window.WindowStartupLocation='Manual';$window.Left=-20000;$window.Top=-20000
$window.ShowInTaskbar=$false;$window.ShowActivated=$false
$window.Show()
if ($OutputDirectory) { [void][IO.Directory]::CreateDirectory($OutputDirectory) }
foreach ($size in @(@(1180,760),@(980,640))) {
    $window.Width=$size[0];$window.Height=$size[1]
    foreach ($route in @('playground','voices','playlists','pronunciation','queue','history','rules','services','windowsService','voicestudio','polly','streamerbot','settings','activity')) {
        Set-Page $route
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
        Start-Sleep -Milliseconds 220
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
        $expected=$script:routeOwners[$route]
        if ($PageTitle.Text -ne $expected) { throw "Wrong canonical owner for $route" }
        if ($route -eq 'playlists' -and -not $PlaylistGrid.IsVisible) { throw 'Playlist editor is not visible' }
        if (-not $NowPlayingBar.IsVisible) { throw "Player hidden on $route" }
        if ($script:ownerLastPage[$expected] -ne $route) { throw 'Page state not retained' }
        if ($OutputDirectory -and $route -in @('playground','voices','queue','services','streamerbot','settings')) {
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($window)
            $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $file=[IO.File]::Create((Join-Path $OutputDirectory ($route+'-'+$size[0]+'.png')))
            try{$encoder.Save($file)}finally{$file.Dispose()}
        }
    }
}
Set-Page 'history'; Open-YapLoqRoute 'owner:Voices'; Open-YapLoqRoute 'owner:Queue'
$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
if ($script:activePage -ne 'history') { throw 'Queue subsection was not restored' }
Set-Page 'voiceRules'
if ($script:activePage -ne 'rules') { throw 'Legacy voice rule shortcut did not open the single rules workspace' }
Set-Page 'services'
$picker=$script:servicePicker
for ($cycle=0;$cycle -lt 12;$cycle++) {
    for ($index=1;$index -lt $picker.Items.Count;$index++) {
        $picker.SelectedIndex=$index
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
        if ($script:activePage -ne $picker.SelectedItem.Tag) { throw 'Dropdown navigation failed' }
        if (-not [object]::ReferenceEquals($picker,$script:servicePicker)) { throw 'Service dropdown was rebuilt during selection' }
        if ($script:serviceBack.Visibility -ne 'Visible') { throw 'Provider editor has no direct back action' }
    }
    Open-YapLoqRoute 'owner:Services'
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
    if ($script:activePage -ne 'services' -or $picker.SelectedIndex -ne 0) { throw 'Services did not return to setup overview' }
    foreach ($button in $script:yaploqNav.Values) {
        $enter=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount);$enter.RoutedEvent=[Windows.UIElement]::MouseEnterEvent
        $button.RaiseEvent($enter)
        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $leave=[Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount);$leave.RoutedEvent=[Windows.UIElement]::MouseLeaveEvent
        $button.RaiseEvent($leave)
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
    }
    Set-Page 'services'
}
if (Test-Path (Join-Path $configDir 'ui-errors.log')) { throw 'Navigation stress test logged an unexpected error' }
# A failed route must preserve the previous page and leave a diagnostic instead of terminating WPF.
$previous=$script:activePage
Set-Page 'unknown-test-route'
if ($script:activePage -ne $previous -or -not(Test-Path (Join-Path $configDir 'ui-errors.log'))) { throw 'Failed navigation did not preserve the current page and log details' }
$window.Close()
'YapLoq shell passed: six routes, unified rules, Dashboard state, 14 views at two sizes, 132 provider selections, repeated sidebar/hover events, direct service back navigation and failed-route recovery.'
