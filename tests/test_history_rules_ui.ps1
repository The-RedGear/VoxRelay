$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,WindowsFormsIntegration
$root=Split-Path -Parent $PSScriptRoot;$resourceRoot=$root
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'VoxRelay.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $fn.Extent.Text}
Initialize-RoundedChrome
$window=Load-Xaml (Join-Path $root 'VoxRelay.xaml')
[xml]$xml=Get-Content -LiteralPath (Join-Path $root 'VoxRelay.xaml') -Raw
foreach($n in $xml.SelectNodes('//*[@Name]')){Set-Variable $n.GetAttribute('Name') $window.FindName($n.GetAttribute('Name'))}
Apply-AppFont $window
Initialize-AppBranding
. (Join-Path $root 'assets\RuleEditors.ps1')
Install-NumericEditors;Install-ProfanityEditor
$profanityPanel=$window.FindName('RulesStack').Children[1]
$profanityExpander=$profanityPanel.FindName('ProfanityExpander')
if(-not $profanityExpander -or $profanityExpander.IsExpanded){throw 'Profanity should start collapsed'}
if($profanityPanel.Margin.Top -lt 14){throw 'Missing space above Profanity'}
$profanityExpander.IsExpanded=$true
Load-ProfanityRules ([pscustomobject]@{})
if($script:profanityGrid.Items.Count -ne 10){throw 'Default words missing'}
$profanityExpander.IsExpanded=$false;$profanityExpander.IsExpanded=$true
if($script:profanityGrid.Items.Count -ne 10){throw 'Collapsing lost profanity rules'}
if((Get-DisplayText 'grass ASS asses') -ne 'grass **** *****'){throw 'Mask boundaries failed'}
$script:profanityShow.IsChecked=$true;Update-ProfanityDisplay
if((Get-DisplayText 'ass') -ne 'ass'){throw 'Show toggle failed'}
$script:profanityShow.IsChecked=$false;Update-ProfanityDisplay
$MaxQueueSettingBox.Text='57'
if($MaxQueueBox.Text -ne '57'){throw 'Shared queue limit failed'}
$script:numericEditors[$MaxQueueBox].Slider.Value=80
if($MaxQueueSettingBox.Text -ne '80'){throw 'Slider sync failed'}
$HistoryLimitBox.Text='2000'
if($script:numericEditors[$HistoryLimitBox].Slider.Value -ne 2000){throw 'Exact larger entry was clamped'}
$HistoryPage.Visibility='Visible';$HistoryGrid.ItemsSource=@([pscustomobject]@{Id='selected';HasAudio=$true;Text='Selected recording';Alias='Test'})
$HistoryGrid.SelectedIndex=0
if((Get-HistoryPlaybackTarget).Id -ne 'selected'){throw 'Selected history target failed'}
foreach($n in $xml.SelectNodes('//*[@Name]')){if($n.GetAttribute('Name') -match 'Page$'){$element=$window.FindName($n.GetAttribute('Name'));if($element){$element.Visibility='Collapsed'}}}
$RulesPage.Visibility='Visible';$PageTitle.Text='Rules';$PageSubtitle.Text='Control what is spoken.'
$window.WindowStartupLocation='Manual';$window.Left=-20000;$window.Top=-20000;$window.ShowInTaskbar=$false;$window.ShowActivated=$false
$window.Show();$window.UpdateLayout()
$frame=New-Object Windows.Threading.DispatcherFrame
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({$timer.Stop();$frame.Continue=$false});$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
$window.UpdateLayout()
$RulesPage.Visibility='Collapsed';$HistoryPage.Visibility='Visible';$window.UpdateLayout()
$row=[Windows.Controls.DataGridRow]$HistoryGrid.ItemContainerGenerator.ContainerFromIndex(0)
if(-not $row){throw 'History row not realized'}
function Find-Visual($parent,$type){if($parent -is $type){return $parent};for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);$i++){$found=Find-Visual ([Windows.Media.VisualTreeHelper]::GetChild($parent,$i)) $type;if($found){return $found}}}
$cell=Find-Visual $row ([Windows.Controls.DataGridCell])
$hit=$cell.InputHitTest([Windows.Point]::new($cell.ActualWidth-6,$cell.ActualHeight/2))
if(-not $hit){throw 'Blank cell space is not hit-testable'}
$HistoryGrid.SelectedIndex=-1
$mouse=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
$mouse.RoutedEvent=[Windows.Input.Mouse]::MouseDownEvent;$hit.RaiseEvent($mouse)
if($HistoryGrid.SelectedIndex -ne 0){throw 'Clicking cell whitespace did not select History row'}
$script:postBody=$null
function Invoke-BridgePost($path,$body){$script:postBody=$body}
function Refresh-ServiceState{}
foreach($node in $ast.EndBlock.Statements){if($node.Extent.Text -match '^if \(\$NowPlayingPlayPauseButton\)'){Invoke-Expression $node.Extent.Text}}
$NowPlayingPlayPauseButton.Tag='idle';$script:lastHistorySpeechId='not-selected'
$NowPlayingPlayPauseButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:postBody.speechId -ne 'selected'){throw 'Media play ignored the selected recording'}
$RulesPage.Visibility='Visible';$HistoryPage.Visibility='Collapsed';$window.UpdateLayout()
$window.Dispatcher.BeginInvoke([action]{
    $dialog=$window.OwnedWindows[0]
    $dialog.FindName('WordHidden').Password='custom'
    $dialog.FindName('VariantsHidden').Password='customs, customed'
    $dialog.FindName('ReplacementHidden').Password='one, two'
    $dialog.FindName('Save').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}) | Out-Null
$result=Show-ProfanityDialog $null
if($result.word -ne 'custom' -or $result.variants.Count -ne 2 -or $result.replacement -ne 'one, two'){throw 'Masked dialog save failed'}
$script:profanityGrid.BringIntoView();$window.UpdateLayout()
foreach($asset in @('ProfanityPanel.xaml','ProfanityDialog.xaml')){[void](Load-Xaml (Join-Path $root ('assets\'+$asset)))}
$PlaylistGrid.ItemsSource=@([pscustomobject]@{Name='A long playlist name that needs several lines';Summary=(('Voice name, ' * 35).TrimEnd(', '));Count=35})
$ancestor=$PlaylistGrid.Parent
while($ancestor -and $ancestor -ne $window){if($ancestor -is [Windows.Controls.Expander]){$ancestor.IsExpanded=$true};$ancestor=$ancestor.Parent}
foreach($width in @(980,1180,1600)){
    $window.Width=$width;$window.UpdateLayout();$PlaylistGrid.BringIntoView();$window.UpdateLayout()
    $playlistRow=[Windows.Controls.DataGridRow]$PlaylistGrid.ItemContainerGenerator.ContainerFromIndex(0)
    if(-not $playlistRow -or $playlistRow.ActualHeight -le 52){throw "Playlist did not grow for wrapped text at $width"}
    if($PlaylistGrid.Parent.CornerRadius.TopLeft -ne 10){throw 'Playlist frame is not rounded'}
}
$window.Close()
'Profanity masking/defaults, shared numeric sliders, exact values, History target, and new XAML passed.'
