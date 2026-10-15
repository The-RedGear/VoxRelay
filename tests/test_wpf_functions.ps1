$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing,System.Security
$appRoot=Split-Path -Parent $PSScriptRoot
$configDir=Join-Path $appRoot ('data/ui-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($configDir) | Out-Null
$configPath=Join-Path $configDir 'settings.json'
$legacyConfigDir=Join-Path $configDir 'no-legacy-data'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $appRoot 'VoxRelay.ps1'),[ref]$tokens,[ref]$errors)
foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    Invoke-Expression $definition.Extent.Text
}
$window=Load-Xaml (Join-Path $appRoot 'VoxRelay.xaml')
[xml]$markup=Get-Content -LiteralPath (Join-Path $appRoot 'VoxRelay.xaml') -Raw
foreach($node in $markup.SelectNodes('//*[@Name]')){Set-Variable -Name $node.GetAttribute('Name') -Value $window.FindName($node.GetAttribute('Name'))}
$script:profiles=@{};$script:profileModels=@{};$script:servicesExpanded=$true;$script:loadingSettings=$false
Apply-AppFont $window
Refresh-Grid
if($AliasGrid.Items.Count -ne 1){throw 'Default alias did not load'}
$value=[pscustomobject]@{Name='Test voice';Provider='polly';VoiceId='Brian';Model='neural';Speed=1;Volume=1;Group='Test';Language='en-GB';Instruct='';OutputDevice='Test output'}
Save-Alias $null $value
$saved=Read-Settings
if($saved.aliases.'Test voice'.output_device -ne 'Test output'){throw 'Per-alias output did not save'}
if(-not(Test-Path -LiteralPath ($configPath+'.bak'))){throw 'Settings backup missing'}
$AliasSearchBox.Text='Test voice';Filter-VoiceAliases
if($AliasGrid.Items.Count -ne 1){throw 'Voice search failed'}
$AliasSearchBox.Text='';Filter-VoiceAliases
$RouteValueBox.Text='subscriber';$RouteFieldBox.SelectedIndex=1;$RouteAliasBox.SelectedItem='Test voice';$RoutePrioritySlider.Value=25
Save-RouteEditor $false
Save-Rules
$saved=Read-Settings
if(@($saved.routing_rules).Count -ne 1 -or $saved.routing_rules[0].priority -ne 25){throw 'Routing rule did not persist'}
$script:backendOnline=$true
$script:testHistory=@([pscustomobject]@{id='stable';timestamp='2026-10-15T12:00:00Z';status='Finished';alias='Test voice';source='Test';user='';text='hello';audioPath=''})
function Invoke-BridgeGet([string]$path,[int]$timeoutSec=2){
    if($path -eq '/api/state'){return [pscustomobject]@{result=[pscustomobject]@{queue=@();current=$null;queueLength=0;estimatedWaitSeconds=0;paused=$false}}}
    if($path -eq '/api/history'){return [pscustomobject]@{result=[pscustomobject]@{history=$script:testHistory}}}
}
Refresh-ServiceState
$HistoryGrid.SelectedIndex=0
$originalSource=$HistoryGrid.ItemsSource
Refresh-ServiceState
if(-not[object]::ReferenceEquals($originalSource,$HistoryGrid.ItemsSource) -or $HistoryGrid.SelectedItem.Id -ne 'stable'){throw 'Unchanged history lost its selection or collection'}
$script:testHistory=@([pscustomobject]@{id='new';timestamp='2026-10-15T12:01:00Z';status='Finished';alias='Test voice';source='Test';user='';text='new';audioPath=''})+$script:testHistory
Refresh-ServiceState
if($HistoryGrid.SelectedItem.Id -ne 'stable'){throw 'New history entry deselected the existing selection'}
$PollyRegionBox.ApplyTemplate() | Out-Null
$editable=$PollyRegionBox.Template.FindName('PART_EditableTextBox',$PollyRegionBox)
if(-not $editable -or $editable.Visibility -ne 'Visible'){throw 'Editable dropdown has no editor'}
$editable.Text='eu-west-3'
$editable.GetBindingExpression([Windows.Controls.TextBox]::TextProperty).UpdateSource()
if($PollyRegionBox.Text -ne 'eu-west-3'){throw 'Typed dropdown value did not update'}
# Execute dialog initialization without opening a modal window.
$definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-AliasDialog'},$true)[0]
$testDialog=$definition.Extent.Text.Replace('function Show-AliasDialog','function Test-AliasDialog')
$testDialog=$testDialog.Replace('$d.Owner=$window','$d.Owner=$null')
$testDialog=$testDialog.Replace('[void]$d.ShowDialog()','$script:dialogResult=[pscustomobject]@{SelectedVoice=[string]$p.SelectedItem;SelectedModel=[string]$m.SelectedItem;Output=[string]$aliasOutput.SelectedItem};$d.Close()')
Invoke-Expression $testDialog
$script:profileModelOptions=@{}
$offline=Test-AliasDialog $value
if(-not $offline.SelectedVoice.EndsWith('[polly|Brian]') -or $offline.SelectedModel -ne 'neural' -or $offline.Output -ne 'Test output'){throw ('Offline alias editing lost voice, model or output: '+($offline | ConvertTo-Json -Compress))}
$script:profiles=@{'polly|Brian'='Brian - Amazon Polly'};$script:profileModels=@{'polly|Brian'='neural'};$script:profileModelOptions=@{'polly|Brian'=@('standard','neural')}
$online=Test-AliasDialog $null
if($online.SelectedModel -ne 'neural'){throw 'Provider-aware model picker did not choose a supported engine'}
# Validate every embedded dialog, including bindings and resource resolution.
$dialogCount=0
foreach($node in $ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.TrimStart().StartsWith('<Window ')},$true)){
    [xml]$dialogXml=$node.Value
    $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($dialogXml))
    $dialog.Resources.MergedDictionaries.Add($window.Resources)
    Apply-AppFont $dialog
    $dialog.Close();$dialogCount++
}
$import=Load-Xaml (Join-Path $appRoot 'ImportPreview.xaml');$import.Resources.MergedDictionaries.Add($window.Resources);Apply-AppFont $import;$import.Close()
$window.Close()
"WPF functions passed: alias save, atomic backup, search, routing, history stability, accessibility and $dialogCount embedded dialogs. Test data: $configDir"
