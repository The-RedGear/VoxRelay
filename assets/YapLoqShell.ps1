# Incremental WPF shell. Existing controls and handlers retain their state and storage.
function Register-YapLoqControlMotion($root) {
    # Popup children have their own presentation source and cannot inherit a page transition.
    $selector = $root
    if ($selector -is [Windows.Controls.ComboBox] -and -not $selector.Resources.Contains('YapLoqMotionInstalled')) {
        $selector.Resources['YapLoqMotionInstalled'] = $true
        $selector.Add_DropDownOpened({
            param($control,$args)
            $popup = $control.Template.FindName('PART_Popup',$control)
            if ($popup -and $popup.Child) {
                $popup.PopupAnimation = 'None'
                # Dropdowns should open in their placement direction. The shared
                # page animation rises from below, which makes menus look reversed.
                $child = $popup.Child
                $child.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
                $translate = Ensure-TranslateTransform $child
                $fade = [Windows.Media.Animation.DoubleAnimation]::new(0.82,1.0,[TimeSpan]::FromMilliseconds(130))
                $child.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
                if ($translate) {
                    $slide = [Windows.Media.Animation.DoubleAnimation]::new(-7.0,0.0,[TimeSpan]::FromMilliseconds(150))
                    $slide.EasingFunction = New-EaseOut
                    $translate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$slide)
                }
            }
        })
    }
    if ($root -is [Windows.DependencyObject]) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($root)) {
            if ($child -is [Windows.DependencyObject]) { Register-YapLoqControlMotion $child }
        }
    }
}

function Hide-YapLoqCredential($entry) {
    $entry.Syncing=$true
    try{
        $entry.Plain.Visibility='Collapsed';$entry.Mask.Visibility='Visible';$entry.Toggle.Content='Show'
        if($entry.Original -is [Windows.Controls.PasswordBox]){$entry.Plain.Text=''}
    }finally{$entry.Syncing=$false}
}

function Sync-YapLoqCredentialFields($names=@(),[switch]$PreserveEdits) {
    if(-not $script:credentialFields){return}
    $settings=Read-Settings
    foreach($entry in $script:credentialFields.Values){
        if($names.Count -and $entry.Original.Name -notin $names){continue}
        $stored=[string]$settings.($entry.Key);$value='';$unavailable=$false
        try{$value=if($entry.Encrypted){Unprotect-YapLoqSecret $stored}else{$stored}}catch{$unavailable=[bool]$stored}
        if($PreserveEdits -and $entry.Mask.Password -and $entry.Mask.Password -ne $value){Hide-YapLoqCredential $entry;$value=$null;continue}
        $entry.Syncing=$true
        try{
            $entry.Mask.Password=$value
            if($entry.Original -is [Windows.Controls.TextBox]){$entry.Original.Text=$value}
            $entry.Unavailable=$unavailable
            $entry.Hint.Visibility=if($unavailable){'Visible'}else{'Collapsed'}
            $entry.Toggle.IsEnabled=(-not $unavailable -and [bool]$value)
            $entry.Mask.ToolTip=if($unavailable){'Saved credential cannot be read on this Windows account. Enter a replacement or use Clear secrets.'}else{'Saved values are masked. Use Show to reveal.'}
        }finally{$entry.Syncing=$false;$value=$null}
        Hide-YapLoqCredential $entry
    }
}

function Install-YapLoqCredentialFields {
    $script:credentialFields=@{}
    foreach($spec in @(
        @('KeyBox','api_key','VoiceStudio'),
        @('PollyAccessKeyBox','polly_access_key_encrypted','Polly'),@('PollySecretKeyBox','polly_secret_key_encrypted','Polly'),@('PollySessionTokenBox','polly_session_token_encrypted','Polly'),
        @('ElevenLabsApiKeyBox','elevenlabs_api_key_encrypted','ElevenLabs'),@('AzureKeyBox','azure_subscription_key_encrypted','Azure'),
        @('GoogleApiKeyBox','google_api_key_encrypted','Google'),@('WatsonApiKeyBox','watson_api_key_encrypted','Watson'),@('UberDuckApiKeyBox','uberduck_api_key_encrypted','UberDuck'),
        @('TtsMonsterTokenBox','ttsmonster_api_token_encrypted','TtsMonster'),@('AcapelaPasswordBox','acapela_password_encrypted','Acapela'),@('CereProcPasswordBox','cereproc_password_encrypted','CereProc'),@('ObsPasswordBox','obs_password_encrypted','Obs')
    )){
        $original=$window.FindName($spec[0]);if(-not $original -or $original.Parent -isnot [Windows.Controls.Panel]){continue}
        $parent=$original.Parent;$index=$parent.Children.IndexOf($original)
        $wrapper=[Windows.Controls.Grid]::new();$wrapper.Margin=$original.Margin
        foreach($property in @('Row','Column','RowSpan','ColumnSpan')){
            $getter='Get'+$property;$setter='Set'+$property
            [Windows.Controls.Grid]::$setter($wrapper,[Windows.Controls.Grid]::$getter($original))
        }
        [void]$parent.Children.Remove($original);$original.Margin=0
        [Windows.Controls.Grid]::SetRow($original,0);[Windows.Controls.Grid]::SetColumn($original,0);[Windows.Controls.Grid]::SetRowSpan($original,1);[Windows.Controls.Grid]::SetColumnSpan($original,1)
        $wrapper.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$auto=[Windows.Controls.ColumnDefinition]::new();$auto.Width='Auto';$wrapper.ColumnDefinitions.Add($auto)
        $mask=if($original -is [Windows.Controls.PasswordBox]){$original}else{[Windows.Controls.PasswordBox]::new()}
        $plain=if($original -is [Windows.Controls.TextBox]){$original}else{[Windows.Controls.TextBox]::new()}
        $mask.PasswordChar=[char]0x25CF;$plain.Visibility='Collapsed';$plain.Margin=0;$plain.IsUndoEnabled=$false
        [void]$wrapper.Children.Add($mask);[void]$wrapper.Children.Add($plain)
        $toggle=[Windows.Controls.Button]::new();$toggle.Content='Show';$toggle.MinWidth=62;$toggle.Margin='8,0,0,0';$toggle.Padding='10,0';$toggle.ToolTip='Show or hide this credential';[Windows.Automation.AutomationProperties]::SetName($toggle,'Show or hide '+$spec[0])
        [Windows.Controls.Grid]::SetColumn($toggle,1);[void]$wrapper.Children.Add($toggle)
        $hint=[Windows.Controls.TextBlock]::new();$hint.Text=[string][char]0x25CF*8;$hint.Margin='12,0';$hint.VerticalAlignment='Center';$hint.IsHitTestVisible=$false;$hint.Visibility='Collapsed';[void]$wrapper.Children.Add($hint)
        $entry=[pscustomobject]@{Original=$original;Mask=$mask;Plain=$plain;Toggle=$toggle;Hint=$hint;Key=$spec[1];Encrypted=($spec[0] -ne 'KeyBox');Provider=$spec[2];Syncing=$false;Unavailable=$false}
        $script:credentialFields[$spec[0]]=$entry
        foreach($control in @($mask,$plain,$toggle,$wrapper)){$control.Resources['YapLoqCredential']=$entry}
        $mask.Add_PasswordChanged({param($sender,$e)
            $entry=$sender.Resources['YapLoqCredential'];if($entry.Syncing){return}
            $entry.Syncing=$true
            try{
                if($entry.Original -is [Windows.Controls.TextBox] -or $entry.Plain.Visibility -eq 'Visible'){$entry.Plain.Text=$sender.Password}
                $entry.Hint.Visibility='Collapsed';$entry.Toggle.IsEnabled=[bool]$sender.Password;$entry.Unavailable=$false
            }finally{$entry.Syncing=$false}
        })
        $plain.Add_TextChanged({param($sender,$e)
            $entry=$sender.Resources['YapLoqCredential'];if($entry.Syncing){return}
            $entry.Syncing=$true
            try{$entry.Mask.Password=$sender.Text;$entry.Hint.Visibility='Collapsed';$entry.Toggle.IsEnabled=[bool]$sender.Text;$entry.Unavailable=$false}finally{$entry.Syncing=$false}
        })
        $toggle.Add_Click({param($sender,$e)
            $entry=$sender.Resources['YapLoqCredential']
            if($entry.Plain.Visibility -eq 'Visible'){Hide-YapLoqCredential $entry}else{
                $entry.Syncing=$true
                try{$entry.Plain.Text=$entry.Mask.Password;$entry.Mask.Visibility='Collapsed';$entry.Plain.Visibility='Visible';$sender.Content='Hide'}finally{$entry.Syncing=$false}
            }
        })
        $wrapper.Add_IsVisibleChanged({param($sender,$e)if(-not $sender.IsVisible){Hide-YapLoqCredential $sender.Resources['YapLoqCredential']}})
        $parent.Children.Insert($index,$wrapper)
    }
    # Run after the existing save/clear handlers, reloading only the affected service.
    foreach($provider in @($script:credentialFields.Values.Provider|Sort-Object -Unique)){
        $names=@($script:credentialFields.Values|Where-Object{$_.Provider -eq $provider}|ForEach-Object{$_.Original.Name})
        $buttonNames=@("Save${provider}Button","Test${provider}Button","Clear${provider}Button")
        if($provider -eq 'Polly'){$buttonNames+= 'ClearPollyCredentialsButton'}
        if($provider -eq 'Obs'){$buttonNames+= 'SaveButton'}
        foreach($buttonName in $buttonNames){$button=$window.FindName($buttonName);if($button){$button.Resources['YapLoqCredentialNames']=$names;$button.Add_Click({param($sender,$e)Sync-YapLoqCredentialFields $sender.Resources['YapLoqCredentialNames'] -PreserveEdits})}}
    }
    Sync-YapLoqCredentialFields
}

function Install-YapLoqStyles {
    foreach ($spec in @(@('YapLoqNavButton','NavButton'),@('YapLoqSelectedNavButton','SelectedNavButton'))) {
        $style = [Windows.Markup.XamlReader]::Parse(@'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
 <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
 <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1" ScaleY="1"/></Setter.Value></Setter>
 <Setter Property="FocusVisualStyle"><Setter.Value><Style TargetType="Control"><Setter Property="Template"><Setter.Value><ControlTemplate><Border BorderBrush="#C9BCFF" BorderThickness="2" CornerRadius="8" Margin="1"/></ControlTemplate></Setter.Value></Setter></Style></Setter.Value></Setter>
 <Style.Triggers>
  <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard>
   <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.025" Duration="0:0:0.12"/>
   <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.025" Duration="0:0:0.12"/>
  </Storyboard></BeginStoryboard></EventTrigger>
  <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard>
   <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.14"/>
   <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.14"/>
  </Storyboard></BeginStoryboard></EventTrigger>
 </Style.Triggers>
</Style>
'@)
        $style.BasedOn = $window.FindResource($spec[1])
        if (-not [Windows.SystemParameters]::ClientAreaAnimation) { $style.Triggers.Clear() }
        $window.Resources.Add($spec[0],$style)
    }
}

function New-YapLoqButton([string]$label, [string]$route, [string]$iconSource = 'VoicesNav') {
    $button = [Windows.Controls.Button]::new()
    $button.Style = $window.FindResource('YapLoqNavButton')
    $button.Tag = $route
    $button.ToolTip = $label
    [Windows.Automation.AutomationProperties]::SetName($button, $label)
    $panel = [Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
    $node = $script:shellMarkup.SelectSingleNode("//*[@Name='$iconSource']//*[local-name()='Path'][@Data]")
    if ($node) {
        $path = [Windows.Shapes.Path]::new()
        $path.Data = [Windows.Media.Geometry]::Parse($node.GetAttribute('Data'))
        $foreground = [Windows.Data.Binding]::new('Foreground')
        $foreground.RelativeSource = [Windows.Data.RelativeSource]::new([Windows.Data.RelativeSourceMode]::FindAncestor,[Windows.Controls.Button],1)
        [void]$path.SetBinding([Windows.Shapes.Shape]::FillProperty,$foreground)
        $path.Stretch = 'Uniform'
        $path.Width = 16; $path.Height = 16; $path.Margin = '0,0,10,0'
        [void]$panel.Children.Add($path)
    }
    $text = [Windows.Controls.TextBlock]::new(); $text.Text = $label; $text.VerticalAlignment = 'Center'
    if ($label -eq 'Playlists' -and $panel.Children.Count) {
        $panel.Children[0].Data = [Windows.Media.Geometry]::Parse('M3 4H17V6H3Z M3 9H17V11H3Z M3 14H11V16H3Z M15 13L22 17L15 21Z')
    }
    if ($label -eq 'Rules' -and $panel.Children.Count) {
        # Material Design Icons: tune.
        $panel.Children[0].Data = [Windows.Media.Geometry]::Parse('M3,17V19H9V17H3M3,5V7H13V5H3M13,21V19H21V17H13V15H11V21H13M7,9V11H3V13H7V15H9V9H7M21,13V11H11V13H21M15,9H17V7H21V5H17V3H15V9Z')
    }
    if ($label -eq 'Routing' -and $panel.Children.Count) {
        $panel.Children[0].Data=(Resolve-VoiceIcon 'mdi:call-split').Geometry
        $panel.Children[0].Tag='mdi:call-split'
    }
    [void]$panel.Children.Add($text); $button.Content = $panel
    $button.Add_Click({ param($sender,$e) if(-not $sender.Resources.Contains('SectionShortcut')){Open-YapLoqRoute ([string]$sender.Tag)} })
    return $button
}

function Open-YapLoqRoute([string]$route) {
    if ($route -eq 'toggle-sidebar') {
        Set-YapLoqSidebarCollapsed (-not $script:sidebarCollapsed)
    } elseif ($route -eq 'emergency-stop') {
        try { Invoke-BridgePost '/clear-all' | Out-Null; Refresh-ServiceState; $BottomStatus.Text = 'Playback stopped; waiting speech cleared.' }
        catch { $BottomStatus.Text = $_.Exception.Message }
    } elseif ($route.StartsWith('owner:')) {
        $owner = $route.Substring(6)
        $target = if ($owner -eq 'Services') { 'services' } else { $script:ownerLastPage[$owner] }
        Request-YapLoqPage $target
    } else { Request-YapLoqPage $route }
}

function Request-YapLoqPage([string]$route) {
    # Let the originating click/SelectionChanged event finish before changing its tree.
    $script:pendingRoute = $route
    if ($script:navigationQueued) { return }
    $script:navigationQueued = $true
    [void]$window.Dispatcher.BeginInvoke([action]{
        $script:navigationQueued = $false
        $target = $script:pendingRoute; $script:pendingRoute = $null
        Set-Page $target
    },[Windows.Threading.DispatcherPriority]::Background)
}

function Write-YapLoqUiError($failure) {
    try {
        $message = '{0:o} Navigation error: {1}{2}{3}' -f [datetime]::UtcNow,$failure.Exception.ToString(),[Environment]::NewLine,$failure.ScriptStackTrace
        Add-Content -LiteralPath (Join-Path $configDir 'ui-errors.log') -Value $message -Encoding UTF8
    } catch {}
    $BottomStatus.Text = 'This page could not open. Try again; details are in ui-errors.log.'
}

function New-YapLoqPage([string]$route) {
    $scroll = [Windows.Controls.ScrollViewer]::new()
    $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Visibility = 'Collapsed'; $scroll.Padding = '0,0,8,0'
    [Windows.Controls.Grid]::SetRow($scroll, 2)
    $panel = [Windows.Controls.StackPanel]::new(); $scroll.Content = $panel
    [void]$script:shellContent.Children.Add($scroll)
    $script:yaploqPages[$route] = $scroll
    return $panel
}

function Move-YapLoqRuleCard($control, $destination) {
    $card = $control
    while ($card -and $card.Parent -ne $RulesPage.Content) { $card = $card.Parent }
    if (-not $card) { throw 'Could not find the existing rule card.' }
    [void]$RulesPage.Content.Children.Remove($card)
    $card.Margin = '0,0,0,14'
    if ($card.Child -is [Windows.Controls.Expander]) { $card.Child.IsExpanded = $true }
    [void]$destination.Children.Add($card)
}

function Update-YapLoqNavigation([string]$page) {
    if (-not $script:yaploqNav) { return }
    Close-YapLoqStatusMenu
    $owner = $script:routeOwners[$page]
    if (-not $owner) { return }
    $script:headerControls.Parent.Visibility = if ($owner -in @('Dashboard','Integrations')) {'Collapsed'}else{'Visible'}
    $script:ownerLastPage[$owner] = $page
    foreach ($key in $script:yaploqNav.Keys) {
        $script:yaploqNav[$key].Style = $window.FindResource($(if($key -eq $owner){'YapLoqSelectedNavButton'}else{'YapLoqNavButton'}))
    }
    # Retain controls while switching within an owner, especially the service picker.
    if ($script:sectionOwner -ne $owner) {
        $script:sectionNav.Children.Clear()
        $script:sectionOwner = $owner
        if ($owner -eq 'Services') { [void]$script:sectionNav.Children.Add($script:serviceToolbar) }
        else {
            foreach ($entry in $script:ownerSections[$owner]) {
                $button = New-YapLoqButton $entry[0] $entry[1] $entry[2]
                $button.Margin = '0,0,8,0'; $button.Padding = '12,8'
                [void]$script:sectionNav.Children.Add($button)
            }
        }
    }
    if ($owner -eq 'Services') {
        $script:syncingServicePicker = $true
        try {
            foreach ($item in $script:servicePicker.Items) { if ($item.Tag -eq $page) { $script:servicePicker.SelectedItem = $item; break } }
        } finally { $script:syncingServicePicker = $false }
        $script:serviceBack.Visibility = if ($page -eq 'services') {'Collapsed'}else{'Visible'}
    } else {
        foreach ($button in $script:sectionNav.Children) {
            $button.Style = $window.FindResource($(if($button.Tag -eq $page){'YapLoqSelectedNavButton'}else{'YapLoqNavButton'}))
        }
    }
    # The service picker and section buttons persist within an owner, but still
    # participate whenever its page changes (for example Queue -> History).
    Animate-In $script:headerControls
    Register-YapLoqControlMotion $script:sectionNav
    $PageTitle.Text = if ($owner -eq 'Integrations') { 'Streamer.Bot' } else { $owner }
    $PageSubtitle.Text = switch ($page) {
        'playground' {'Your voice. Your stream.'}
        'rules' {'Message filters and queue limits'}
        'routing' {'Voice selection and routing priority'}
        'playlists' {'Reusable voice pools'}
        'services' {'Select a service to get started'}
        'activity' {'Events, logs and action diagnostics'}
        default {$PageSubtitle.Text}
    }
    if ($owner -eq 'Services' -and $page -ne 'services') {
        $PageSubtitle.Text = [string]$script:servicePicker.SelectedItem.Content + ' - connection and voice setup'
    }
    # Each editor retains its existing Save action; avoid a duplicate global save.
    $SavePageButton.Visibility = 'Collapsed'
}

function Get-YapLoqDashboardControls($root) {
    if ($root -is [Windows.Controls.Control] -and $root.Style) {
        [pscustomobject]@{ Control=$root; Style=$root.Style }
    }
    if ($root -is [Windows.DependencyObject]) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($root)) {
            if ($child -is [Windows.DependencyObject]) { Get-YapLoqDashboardControls $child }
        }
    }
}

function Get-YapLoqDashboardAccentStyle($style, [string]$accent) {
    # Clone sealed styles; never mutate the shared purple resources or per-voice icons.
    if (-not $script:dashboardAccentStyles) { $script:dashboardAccentStyles=@{} }
    $key=$accent+'|'+$style.GetHashCode()
    if (-not $script:dashboardAccentStyles.ContainsKey($key)) {
        $color=[Windows.Media.ColorConverter]::ConvertFromString($accent)
        $light='#{0:X2}{1:X2}{2:X2}' -f [int]($color.R+(255-$color.R)*0.28),[int]($color.G+(255-$color.G)*0.28),[int]($color.B+(255-$color.B)*0.28)
        $dark='#{0:X2}{1:X2}{2:X2}' -f [int]($color.R*0.86),[int]($color.G*0.86),[int]($color.B*0.86)
        $resourceKey=$null
        foreach($candidate in $window.Resources.Keys){
            if([object]::ReferenceEquals($window.Resources[$candidate],$style)){$resourceKey=$candidate;break}
        }
        if (-not $script:dashboardAccentDictionaries) { $script:dashboardAccentDictionaries=@{} }
        # Parse original markup rather than serializing live templates: TemplateBinding
        # values such as an empty TextBox watermark must not become UnsetValue.
        $useResources=$null -ne $resourceKey -and $resourceKey -notlike 'YapLoq*'
        if($useResources -and $script:dashboardAccentDictionaries.ContainsKey($accent)){
            $script:dashboardAccentStyles[$key]=$script:dashboardAccentDictionaries[$accent][$resourceKey]
            return $script:dashboardAccentStyles[$key]
        }
        $markup=if($useResources){
            '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'+$script:shellMarkup.DocumentElement.SelectSingleNode('*[local-name()="Window.Resources"]').InnerXml+'</ResourceDictionary>'
        }else{[Windows.Markup.XamlWriter]::Save($style)}
        foreach ($pair in @(@('B6A3FF',$accent.Substring(1)),@('C9BCFF',$light.Substring(1)),@('C9BBFF',$light.Substring(1)),@('A690FF',$dark.Substring(1)),@('9580ED',$dark.Substring(1)))) {
            $markup=[regex]::Replace($markup,'(?i)(#[0-9a-f]{2}|#)'+$pair[0]+'\b',('${1}'+$pair[1]))
        }
        if($useResources){
            [xml]$scopedMarkup=$markup
            # Keep each alias icon readable against its own selected-row tint.
            foreach($setter in $scopedMarkup.SelectNodes('//*[local-name()="Style"][@TargetType="ComboBoxItem"]//*[local-name()="Trigger"][@Property="IsSelected"]/*[local-name()="Setter"]')){
                if($setter.GetAttribute('Property') -eq 'Background'){$setter.SetAttribute('Value','#33'+$accent.Substring(1))}
                if($setter.GetAttribute('Property') -eq 'Foreground'){$setter.SetAttribute('Value','#F6F3FA')}
            }
            $markup=$scopedMarkup.OuterXml
        }
        $parsed=[Windows.Markup.XamlReader]::Parse($markup)
        if($useResources){
            $script:dashboardAccentDictionaries[$accent]=$parsed
            $script:dashboardAccentStyles[$key]=$parsed[$resourceKey]
        }else{$script:dashboardAccentStyles[$key]=$parsed}
    }
    return $script:dashboardAccentStyles[$key]
}

function Update-YapLoqDashboardAppearance {
    if (-not $script:dashboardEditor) { return }
    $voice = @($PlayVoiceList.Tag | Where-Object { $_.Name -eq [string]$PlayVoiceList.SelectedItem })[0]
    $accent = Get-VoiceAccent ([string]$voice.Accent)
    $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($accent)
    $script:dashboardEditor.BorderBrush = $brush
    $script:dashboardEditor.Background = [Windows.Media.LinearGradientBrush]::new(
        [Windows.Media.ColorConverter]::ConvertFromString('#33'+$accent.Substring(1)),
        [Windows.Media.ColorConverter]::ConvertFromString('#111A1722'),90)
    $script:dashboardTitle.Foreground = $brush
    $PlaygroundText.BorderBrush = $brush
    if ($script:dashboardStyledAccent -ne $accent -and $script:dashboardControlStyles) {
        foreach ($entry in $script:dashboardControlStyles) {
            $style=$entry.Style
            if ($entry.Control -eq $script:dashboardHelpButton) {
                $style=if($script:dashboardHelpHighlighted){$window.FindResource('PrimaryButton')}else{$window.FindResource([Windows.Controls.Button])}
            }
            try { $entry.Control.Style=Get-YapLoqDashboardAccentStyle $style $accent }
            catch { throw ('Dashboard style failed for '+$entry.Control.GetType().Name+' '+$entry.Control.Name+': '+$_) }
        }
        $script:dashboardHelpDefaultStyle=Get-YapLoqDashboardAccentStyle ($window.FindResource([Windows.Controls.Button])) $accent
        foreach ($picker in @($script:dashboardControlStyles.Control | Where-Object { $_ -is [Windows.Controls.ComboBox] })) {
            $picker.ItemContainerStyle=Get-YapLoqDashboardAccentStyle ($window.FindResource([Windows.Controls.ComboBoxItem])) $accent
            $picker.Resources[[Windows.Controls.Primitives.ScrollBar]]=Get-YapLoqDashboardAccentStyle ($window.FindResource([Windows.Controls.Primitives.ScrollBar])) $accent
        }
        $script:dashboardStyledAccent=$accent
    }
}

function Invoke-YapLoqPreviewAction([string]$action,$recording) {
    try{
        switch($action){
            'replay'{if($recording.HasAudio){Invoke-BridgePost '/api/history/replay' @{speechId=[string]$recording.Id}|Out-Null;$BottomStatus.Text='Recording queued';Refresh-ServiceState}}
            'save'{Save-SpeechRecording ([string]$recording.Id)}
            'show'{Show-HistoryAudioLocation $recording}
            'copy'{if($recording.Text){[Windows.Clipboard]::SetText([string]$recording.Text)}}
            'edit'{$alias=@($PlayVoiceList.Tag|Where-Object{$_.Name -eq $recording.Alias})[0];if($alias){$value=Show-AliasDialog $alias;if($value){Save-Alias $alias.Name $value}}}
            'queue'{Request-YapLoqPage 'queue'}
            'remove'{Invoke-BridgePost '/api/queue/remove' @{speechId=[string]$recording.Id}|Out-Null;Refresh-ServiceState}
            'up'{Invoke-BridgePost '/api/queue/move' @{speechId=[string]$recording.Id;direction='up'}|Out-Null;Refresh-ServiceState}
            'down'{Invoke-BridgePost '/api/queue/move' @{speechId=[string]$recording.Id;direction='down'}|Out-Null;Refresh-ServiceState}
        }
    }catch{$BottomStatus.Text=$_.Exception.Message}
}

function Sort-YapLoqSpeechRows($rows) {
    # Admission time alone determines position; playback state never promotes a row.
    $index=0
    $entries=@(foreach($row in $rows){
        $ticks=try { if($row.Timestamp){([datetimeoffset]$row.Timestamp).UtcDateTime.Ticks}else{0L} } catch {0L}
        [pscustomobject]@{Row=$row;Ticks=$ticks;Index=$index};$index++
    })
    $entries | Sort-Object @{Expression='Ticks';Descending=$true},Index | ForEach-Object{$_.Row}
}

function Update-YapLoqDashboard($state) {
    Update-YapLoqDashboardAppearance
    if (-not $script:dashboardUpcoming) { return }
    $live=@()
    if($state.current -and $state.current.status -notin @('Finished','Error','Cancelled','Skipped','Removed')){$live+=New-QueueSpeechRow $state.current ([bool]$state.paused)}
    foreach($item in @($state.queue|Where-Object{$_})){$live+=New-QueueSpeechRow $item}
    $replayStatuses=@{}
    $historyLookup=@($HistoryGrid.ItemsSource|Where-Object{$_})+@($script:recentHistoryItems|Where-Object{$_})
    foreach($job in @($live|Where-Object{$_.Source -eq 'History recording'})){
        $original=if($job.AudioPath){@($historyLookup|Where-Object{$_.AudioPath -eq $job.AudioPath -or $_.SavedPath -eq $job.AudioPath})[0]}else{$null}
        if($original -and -not $replayStatuses.ContainsKey([string]$original.Id)){$replayStatuses[[string]$original.Id]=$job.Status}
    }
    # Replays belong to their existing history slot, never the new-speech prefix.
    $live=@($live|Where-Object{$_.Source -ne 'History recording'})
    $items=@($live)
    foreach($item in $items){$item|Add-Member NoteProperty PreviewKind 'Live' -Force}
    $liveIds=@($live.Id)
    $recent=@($script:recentHistoryItems|Where-Object{$_ -and $_.Id -notin $liveIds})
    foreach($recording in $recent){$display=$recording|Select-Object *;if($replayStatuses.ContainsKey([string]$recording.Id)){$display.Status=$replayStatuses[[string]$recording.Id]};Add-SpeechRowAppearance $display;$display|Add-Member NoteProperty PreviewKind 'History' -Force;$items+= $display}
    $items=@(Sort-YapLoqSpeechRows $items | Select-Object -First 6)
    # Compare displayed fields only. Do not serialize brush objects or rebuild/restart
    # entry animations on every playback poll (elapsed time is not preview content).
    $signature=([string]$live.Count)+'|'+(@($items|ForEach-Object{'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $_.Id,$_.Status,$_.Text,$_.Accent,$_.IconGeometry,$_.HasAudio,$_.SavedPath,$_.PreviewKind}) -join ';')
    if($signature -eq $script:dashboardQueueSignature){return}
    $script:dashboardQueueSignature=$signature
    $script:dashboardUpcoming.Children.Clear()
    $script:dashboardQueueHeading.Text=if($recent.Count){'Queue & recent speech'}else{'Queue ('+$live.Count+')'}
    if (-not $items.Count) {
        $empty = [Windows.Controls.TextBlock]::new(); $empty.Text = 'No speech yet';$empty.Height=30;$empty.VerticalAlignment='Center';$empty.Foreground = $window.FindResource('Muted')
        [void]$script:dashboardUpcoming.Children.Add($empty)
    }
    foreach ($item in $items) {
        $row=[Windows.Controls.Grid]::new();$row.Height=34;$row.Tag=$item;$row.DataContext=$item;$row.ToolTip=$item.Text
        foreach($width in @('170','*','85','30')){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width=$width;$row.ColumnDefinitions.Add($column)}
        $voice=[Windows.Controls.ContentPresenter]::new();$voice.Content=$item;$voice.ContentTemplate=$window.FindResource('SpeechAliasCell');[void]$row.Children.Add($voice)
        $message=[Windows.Controls.TextBlock]::new();$message.Text=$item.Text;$message.TextTrimming='CharacterEllipsis';$message.VerticalAlignment='Center';$message.Margin='8,0';[Windows.Controls.Grid]::SetColumn($message,1);[void]$row.Children.Add($message)
        $status=[Windows.Controls.TextBlock]::new();$status.Text=$item.Status;$status.Foreground=$window.FindResource('Muted');$status.VerticalAlignment='Center';$status.HorizontalAlignment='Right';[Windows.Controls.Grid]::SetColumn($status,2);[void]$row.Children.Add($status)
        if($item.PreviewKind -eq 'History'){
            $replay=[Windows.Controls.Button]::new();$replay.Style=$window.FindResource('PlayerTransportButton');$replay.Margin=0;$replay.ToolTip='Replay '+$item.Alias;$replay.Tag=$item;$replay.IsEnabled=$item.HasAudio -and $item.Status -notin @('Queued','Playing','Paused','Generating','Waiting for action');[Windows.Automation.AutomationProperties]::SetName($replay,'Replay '+$item.Alias)
            $icon=[Windows.Shapes.Path]::new();$icon.Data=(Resolve-VoiceIcon 'mdi:replay').Geometry;$icon.Width=14;$icon.Height=14;$icon.Stretch='Uniform';$icon.Fill=$window.FindResource('Accent');$replay.Content=$icon
            $replay.Add_Click({param($sender,$e)Invoke-YapLoqPreviewAction 'replay' $sender.Tag;$e.Handled=$true});[Windows.Controls.Grid]::SetColumn($replay,3);[void]$row.Children.Add($replay)
        }
        $menu=[Windows.Controls.ContextMenu]::new();$menu.Tag=$item
        $actions=if($item.PreviewKind -eq 'History'){@(@('Replay','replay'),@('Save audio','save'),@('Show audio file','show'),@('Copy message','copy'),@('Edit voice','edit'),@('Open Queue','queue'))}else{@(@('Move up','up'),@('Move down','down'),@('Remove','remove'),@('Copy message','copy'),@('Edit voice','edit'),@('Open Queue','queue'))}
        foreach($action in $actions){$option=[Windows.Controls.MenuItem]::new();$option.Header=$action[0];$option.Tag=[pscustomobject]@{Action=$action[1];Recording=$item};$option.Add_Click({param($sender,$e)Invoke-YapLoqPreviewAction $sender.Tag.Action $sender.Tag.Recording});[void]$menu.Items.Add($option)}
        $menu.Add_Opened({param($sender,$e)foreach($option in $sender.Items){$recording=$option.Tag.Recording;$option.IsEnabled=if($option.Tag.Action -in @('replay','save','show')){[bool]$recording.HasAudio}elseif($option.Tag.Action -in @('up','down','remove')){$recording.Id -ne $script:lastPlaybackState.current.id}elseif($option.Tag.Action -eq 'edit'){@($PlayVoiceList.Tag|Where-Object{$_.Name -eq $recording.Alias}).Count -gt 0}else{$true}}})
        $row.ContextMenu=$menu
        [void]$script:dashboardUpcoming.Children.Add($row)
    }
}

function New-YapLoqRefreshButton {
    $button=[Windows.Controls.Button]::new();$button.VerticalAlignment='Center';$button.Margin=0
    $content=[Windows.Controls.StackPanel]::new();$content.Orientation='Horizontal'
    $iconNode=$script:shellMarkup.SelectSingleNode("//*[@Name='RefreshButton']//*[local-name()='Path'][@Data]")
    $icon=[Windows.Shapes.Path]::new();$icon.Data=[Windows.Media.Geometry]::Parse($iconNode.GetAttribute('Data'));$icon.Width=14;$icon.Height=14;$icon.Stretch='Uniform';$icon.Margin='0,0,8,0';$icon.VerticalAlignment='Center';$icon.Fill=$window.Foreground
    $label=[Windows.Controls.TextBlock]::new();$label.Text='Refresh';$label.VerticalAlignment='Center'
    [void]$content.Children.Add($icon);[void]$content.Children.Add($label);$button.Content=$content
    $button.ToolTip='Refresh voices and service status';[Windows.Automation.AutomationProperties]::SetName($button,'Refresh voices and service status')
    $button.Add_Click({param($sender,$e) $RefreshButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$e.Handled=$true})
    return $button
}

function Install-YapLoqDashboard {
    # Preserve the existing voice selector and its handlers as the canonical state.
    $PlaygroundPage.ColumnDefinitions.Clear()
    $PlaygroundPage.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $PlaygroundPage.RowDefinitions[0].Height = 'Auto'
    $PlaygroundPage.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $PlaygroundPage.RowDefinitions[1].Height = 'Auto'
    $left = $PlaygroundPage.Children[0]; $left.Visibility = 'Collapsed'
    $editor = $PlaygroundPage.Children[1]; [Windows.Controls.Grid]::SetColumn($editor,0)
    $editor.Padding = 16; $editor.VerticalAlignment = 'Top'
    $editor.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#B6A3FF')
    $editor.Background = [Windows.Media.LinearGradientBrush]::new(
        [Windows.Media.ColorConverter]::ConvertFromString('#35264F'),
        [Windows.Media.ColorConverter]::ConvertFromString('#201A2E'),90)
    $grid = $editor.Child
    $grid.RowDefinitions[1].Height = 'Auto'
    $PlaygroundText.Height = 56; $PlaygroundText.FontSize = 14; $PlaygroundText.Margin = '0,8,0,8'
    [Windows.Controls.Grid]::SetRow($CharacterCount.Parent,3)
    $CharacterCount.Parent.Margin = '0,8,0,0'
    $selector = [Windows.Controls.ComboBox]::new(); $selector.MinWidth = 180; $selector.HorizontalAlignment = 'Left'
    [Windows.Automation.AutomationProperties]::SetName($selector,'Voice for test speech')
    $itemsBinding = [Windows.Data.Binding]::new('Tag'); $itemsBinding.Source = $PlayVoiceList
    [void]$selector.SetBinding([Windows.Controls.ItemsControl]::ItemsSourceProperty,$itemsBinding)
    $selectionBinding = [Windows.Data.Binding]::new('SelectedItem'); $selectionBinding.Source = $PlayVoiceList; $selectionBinding.Mode = 'TwoWay'
    $selector.SelectedValuePath = 'Name'
    [void]$selector.SetBinding([Windows.Controls.Primitives.Selector]::SelectedValueProperty,$selectionBinding)
    $selector.ItemTemplate = [Windows.Markup.XamlReader]::Parse('<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel Orientation="Horizontal"><Path Data="{Binding IconGeometry}" Fill="{Binding IconBrush}" Width="18" Height="18" Stretch="Uniform" Margin="0,0,10,0"/><TextBlock Text="{Binding Name}" VerticalAlignment="Center"/></StackPanel></DataTemplate>')
    $script:dashboardVoicePicker = $selector
    $selector.Add_SelectionChanged({Update-YapLoqDashboardAppearance})
    $grid.Children[0].Visibility = 'Collapsed'
    [void]$grid.Children.Add($selector)
    [void]$grid.Children.Remove($selector)
    $voicePickerRow=[Windows.Controls.StackPanel]::new();$voicePickerRow.Orientation='Horizontal'
    [void]$voicePickerRow.Children.Add($selector)
    $addVoice=[Windows.Controls.Button]::new();$addVoice.Style=$window.FindResource('PlayerIconButton');$addVoice.Width=42;$addVoice.Height=42;$addVoice.Margin='8,0,0,0';$addVoice.Padding=10
    $plus=[Windows.Shapes.Path]::new();$plus.Data=[Windows.Media.Geometry]::Parse('M19,13H13V19H11V13H5V11H11V5H13V11H19V13Z');$plus.Fill=$window.FindResource('Muted');$plus.Stretch='Uniform';$plus.Width=17;$plus.Height=17;$addVoice.Content=$plus
    $addVoice.ToolTip='Add voice';[Windows.Automation.AutomationProperties]::SetName($addVoice,'Add voice')
    $addVoice.Add_Click({$AddButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})
    [void]$voicePickerRow.Children.Add($addVoice);[void]$grid.Children.Add($voicePickerRow)
    $PlaySsmlCheck.Visibility = 'Collapsed'
    $advancedGrid = @($grid.Children | Where-Object { $_ -is [Windows.Controls.Grid] -and [Windows.Controls.Grid]::GetRow($_) -eq 2 })[0]
    [void]$grid.Children.Remove($advancedGrid)
    $advanced = [Windows.Controls.Expander]::new(); $advanced.Header = 'Speech options'; $advanced.Margin = '0,0,0,6'
    [Windows.Controls.Grid]::SetRow($advanced,2)
    $options = [Windows.Controls.StackPanel]::new()
    [void]$grid.Children.Remove($PlaySsmlCheck); $PlaySsmlCheck.Visibility = 'Visible'; $PlaySsmlCheck.HorizontalAlignment = 'Left'
    [void]$options.Children.Add($PlaySsmlCheck); [void]$options.Children.Add($advancedGrid)
    $advanced.Content = $options; [void]$grid.Children.Add($advanced)
    $headline = [Windows.Controls.Grid]::new(); $headline.Margin = '0,0,0,8'
    $headline.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $column = [Windows.Controls.ColumnDefinition]::new(); $column.Width = 'Auto'; $headline.ColumnDefinitions.Add($column)
    $helpColumn = [Windows.Controls.ColumnDefinition]::new(); $helpColumn.Width = 'Auto'; $headline.ColumnDefinitions.Add($helpColumn)
    $refreshColumn=[Windows.Controls.ColumnDefinition]::new();$refreshColumn.Width='Auto';$headline.ColumnDefinitions.Insert(2,$refreshColumn)
    $intro = [Windows.Controls.StackPanel]::new()
    $title = [Windows.Controls.TextBlock]::new(); $title.Text = 'Turn text into speech.'; $title.FontSize = 22; $title.FontWeight = 'SemiBold'
    $title.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#D9CCFF')
    $script:dashboardEditor=$editor; $script:dashboardTitle=$title
    [void]$intro.Children.Add($title)
    $hint = [Windows.Controls.TextBlock]::new(); $hint.Text = 'Choose a voice. Write a message. Press Speak.'; $hint.TextWrapping = 'Wrap'; $hint.Margin = '0,4,12,0'
    $hint.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#D1C8DF'); [void]$intro.Children.Add($hint)
    $hint.Visibility = 'Collapsed'
    [void]$headline.Children.Add($intro)
    $setup = New-YapLoqButton 'Connect a service' 'services' 'ServicesToggle'
    $setup.Style = $window.FindResource('PrimaryButton'); $setup.Padding = '12,8'; $setup.VerticalAlignment = 'Center'; $setup.Margin = '12,0,0,0'
    [Windows.Controls.Grid]::SetColumn($setup,1); [void]$headline.Children.Add($setup)
    $script:dashboardHelpButton = [Windows.Controls.Button]::new()
    $script:dashboardHelpButton.Content = '?'; $script:dashboardHelpButton.Width = 34; $script:dashboardHelpButton.Height = 34
    $script:dashboardHelpButton.Padding = 0; $script:dashboardHelpButton.Margin = '8,0,0,0'; $script:dashboardHelpButton.FontWeight = 'Bold'
    $script:dashboardHelpButton.ToolTip = 'Quick start help'; [Windows.Automation.AutomationProperties]::SetName($script:dashboardHelpButton,'Quick start help')
    $script:dashboardHelpDefaultStyle = $script:dashboardHelpButton.Style
    if (-not $script:dashboardHelpDefaultStyle) { try { $script:dashboardHelpDefaultStyle = $window.FindResource([Windows.Controls.Button]) } catch {} }
    [Windows.Controls.Grid]::SetColumn($script:dashboardHelpButton,3); [void]$headline.Children.Add($script:dashboardHelpButton)
    $dashboardRefresh=New-YapLoqRefreshButton;$dashboardRefresh.Margin='8,0,0,0'
    [Windows.Controls.Grid]::SetColumn($dashboardRefresh,2);[void]$headline.Children.Add($dashboardRefresh)
    foreach ($child in @($grid.Children)) { [Windows.Controls.Grid]::SetRow($child,([Windows.Controls.Grid]::GetRow($child)+1)) }
    $headRow = [Windows.Controls.RowDefinition]::new(); $headRow.Height = 'Auto'; $grid.RowDefinitions.Insert(0,$headRow)
    [void]$grid.Children.Add($headline)
    $script:dashboardPlaceholder = [Windows.Controls.TextBlock]::new()
    $script:dashboardPlaceholder.Text = 'Type a message to speak...'; $script:dashboardPlaceholder.Margin = '12,18,12,12'
    $script:dashboardPlaceholder.Foreground = $window.FindResource('Muted'); $script:dashboardPlaceholder.IsHitTestVisible = $false
    [Windows.Controls.Grid]::SetRow($script:dashboardPlaceholder,[Windows.Controls.Grid]::GetRow($PlaygroundText))
    [void]$grid.Children.Add($script:dashboardPlaceholder)
    $PlaygroundText.Add_TextChanged({$script:dashboardPlaceholder.Visibility=if($PlaygroundText.Text.Length){'Collapsed'}else{'Visible'}})
    $PlaygroundText.Add_GotKeyboardFocus({$script:dashboardPlaceholder.Visibility='Collapsed'})
    $PlaygroundText.Add_LostKeyboardFocus({if(-not$PlaygroundText.Text.Length){$script:dashboardPlaceholder.Visibility='Visible'}})
    # Playback controls have one home in the persistent player.
    $PlayStopButton.Visibility = 'Collapsed'
    foreach ($text in $PlayButton.Content.Children) { if ($text -is [Windows.Controls.TextBlock]) { $text.Text = 'Speak message' } }
    [Windows.Automation.AutomationProperties]::SetName($PlaygroundText,'Message to speak')
    $PlaygroundText.ToolTip = 'Write the message you want to hear. Speak message adds it to your queue.'
    $PlaygroundText.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#9580ED')
    $script:dashboardHelp = [Windows.Controls.Border]::new(); $script:dashboardHelp.Visibility = 'Collapsed'
    $script:dashboardHelp.Margin = '0,2,0,10'; $script:dashboardHelp.Padding = 14; $script:dashboardHelp.CornerRadius = 10
    $script:dashboardHelp.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#282035')
    $script:dashboardHelp.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#66548F'); $script:dashboardHelp.BorderThickness = 1
    $helpPanel = [Windows.Controls.StackPanel]::new(); $script:dashboardHelp.Child = $helpPanel
    $helpTitle = [Windows.Controls.TextBlock]::new(); $helpTitle.Text = 'Quick start'; $helpTitle.FontSize = 16; $helpTitle.FontWeight = 'SemiBold'
    $helpCopy = [Windows.Controls.TextBlock]::new(); $helpCopy.Text = 'Set up YapLoq in three short steps. You can come back here any time.'
    $helpCopy.TextWrapping = 'Wrap'; $helpCopy.Margin = '0,6,0,12'; $helpCopy.Foreground = $window.FindResource('Muted')
    [void]$helpPanel.Children.Add($helpTitle); [void]$helpPanel.Children.Add($helpCopy)
    foreach ($step in @(
        @('1','Choose a speech service','Connect an account you already use, or follow the provider link to create credentials.','Open Services','services','ServicesToggle'),
        @('2','Create a voice','Load provider voices and give one a friendly alias for Dashboard and Streamer.bot.','Open Voices','voices','VoicesNav'),
        @('3','Send your first message','Return to Dashboard, choose the voice, type a message, and press Speak.','Back to Dashboard','playground','PlaygroundNav'),
        @('Optional','Connect Streamer.bot','Import ready-made actions when you want chat, rewards, or automation to speak.','Open Streamer.Bot','streamerbot','StreamerBotNav')
    )) {
        $row = [Windows.Controls.Grid]::new(); $row.Margin = '0,0,0,10'; $row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $actionColumn = [Windows.Controls.ColumnDefinition]::new(); $actionColumn.Width='Auto'; $row.ColumnDefinitions.Add($actionColumn)
        $copyPanel = [Windows.Controls.StackPanel]::new()
        $stepTitle = [Windows.Controls.TextBlock]::new(); $stepTitle.Text = "$($step[0]).  $($step[1])"; $stepTitle.FontWeight='SemiBold'
        $stepBody = [Windows.Controls.TextBlock]::new(); $stepBody.Text=$step[2]; $stepBody.TextWrapping='Wrap'; $stepBody.Foreground=$window.FindResource('Muted'); $stepBody.Margin='0,3,12,0'
        [void]$copyPanel.Children.Add($stepTitle);[void]$copyPanel.Children.Add($stepBody);[void]$row.Children.Add($copyPanel)
        $stepButton=New-YapLoqButton $step[3] $step[4] $step[5];$stepButton.Padding='10,7';$stepButton.VerticalAlignment='Center';$stepButton.Margin=0
        [Windows.Controls.Grid]::SetColumn($stepButton,1);[void]$row.Children.Add($stepButton);[void]$helpPanel.Children.Add($row)
    }
    foreach ($child in @($grid.Children)) { if ($child -ne $headline) { [Windows.Controls.Grid]::SetRow($child,([Windows.Controls.Grid]::GetRow($child)+1)) } }
    $helpRow = [Windows.Controls.RowDefinition]::new(); $helpRow.Height = 'Auto'; $grid.RowDefinitions.Insert(1,$helpRow)
    [Windows.Controls.Grid]::SetRow($script:dashboardHelp,1); [void]$grid.Children.Add($script:dashboardHelp)
    $helpSeen = $false
    try { $helpSeen = [bool](Get-Content -LiteralPath (Join-Path $configDir 'ui-state.json') -Raw -ErrorAction Stop | ConvertFrom-Json).dashboardHelpSeen } catch {}
    if (-not $helpSeen) { $script:dashboardHelpButton.Style = $window.FindResource('PrimaryButton'); $script:dashboardHelpButton.ToolTip = 'New here? Open quick start help' }
    $script:dashboardHelpHighlighted = -not $helpSeen
    $script:dashboardHelpButton.Add_Click({
        $script:dashboardHelp.Visibility = if ($script:dashboardHelp.Visibility -eq 'Visible') {'Collapsed'}else{'Visible'}
        if ($script:dashboardHelp.Visibility -eq 'Visible') { Animate-In $script:dashboardHelp }
        $script:dashboardHelpButton.Style = $script:dashboardHelpDefaultStyle
        $script:dashboardHelpHighlighted=$false
        $path = Join-Path $configDir 'ui-state.json'
        try { $state=if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}else{[pscustomobject]@{}};$state|Add-Member -NotePropertyName dashboardHelpSeen -NotePropertyValue $true -Force;[IO.File]::WriteAllText($path,($state|ConvertTo-Json),[Text.UTF8Encoding]::new($false)) } catch {}
    })
    $PlayButton.ToolTip = 'Generate speech and add it to the live queue. Test voice also uses the current playback queue.'
    $next = [Windows.Controls.Border]::new(); $next.Margin = '0,10,0,0'; $next.Padding = 10
    $next.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#1E1A27'); $next.CornerRadius = 10
    [Windows.Controls.Grid]::SetRow($next,1)
    $panel = [Windows.Controls.StackPanel]::new(); $next.Child = $panel
    $header=[Windows.Controls.Grid]::new();$header.Margin='0,0,0,4';$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$auto=[Windows.Controls.ColumnDefinition]::new();$auto.Width='Auto';$header.ColumnDefinitions.Add($auto)
    $script:dashboardQueueHeading=[Windows.Controls.TextBlock]::new();$script:dashboardQueueHeading.Text='Queue';$script:dashboardQueueHeading.FontWeight='SemiBold';$script:dashboardQueueHeading.VerticalAlignment='Center';[void]$header.Children.Add($script:dashboardQueueHeading)
    $open = New-YapLoqButton 'Open Queue' 'queue' 'QueueNav'; $open.HorizontalAlignment = 'Right'; $open.Margin = 0; $open.Padding = '8,4'
    $open.MinHeight = 28
    $script:dashboardActivityLink=$open
    [Windows.Controls.Grid]::SetColumn($open,1);[void]$header.Children.Add($open);[void]$panel.Children.Add($header)
    $script:dashboardUpcoming = [Windows.Controls.StackPanel]::new(); [void]$panel.Children.Add($script:dashboardUpcoming)
    [void]$PlaygroundPage.Children.Add($next)
    $script:dashboardControlStyles=@(Get-YapLoqDashboardControls $editor)
    Update-YapLoqDashboard $null
    # Advanced speech options can grow without hiding the always-visible player.
    [void]$script:shellContent.Children.Remove($PlaygroundPage)
    $wrapper = [Windows.Controls.ScrollViewer]::new(); $wrapper.VerticalScrollBarVisibility = 'Auto'
    $wrapper.HorizontalScrollBarVisibility = 'Disabled'; $wrapper.Padding = '0,0,6,0'; $wrapper.Visibility = 'Collapsed'
    [Windows.Controls.Grid]::SetRow($wrapper,2)
    $PlaygroundPage.Visibility = 'Visible'; $wrapper.Content = $PlaygroundPage
    [void]$script:shellContent.Children.Add($wrapper)
    $script:yaploqPages.playground = $wrapper
}

function Install-YapLoqVoiceContextMenu {
    $menu=[Windows.Controls.ContextMenu]::new()
    foreach($action in @(@('Edit voice','EditButton'),@('Test voice','TestButton'),@('Favorite','ToggleFavoriteButton'),@('Duplicate voice','duplicate'),@('Remove voice','RemoveButton'))) {
        $item=[Windows.Controls.MenuItem]::new();$item.Header=$action[0];$item.Tag=$action[1]
        $item.Add_Click({param($sender,$e)
            $row=$AliasGrid.SelectedItem;if(-not$row){return}
            if($sender.Tag -eq 'duplicate') {
                try {
                    $settings=Read-Settings
                    $baseName=$row.Name+' copy';$name=$baseName;$number=2
                    while($settings.aliases.PSObject.Properties.Name -contains $name){$name=$baseName+' '+$number;$number++}
                    $copy=$settings.aliases.($row.Name)|ConvertTo-Json -Depth 30|ConvertFrom-Json
                    Set-JsonProperty $settings.aliases $name $copy;Write-Settings $settings;Refresh-Grid -VoicesOnly
                    $AliasGrid.SelectedItem=@($AliasGrid.Items|Where-Object{$_.Name -eq $name})[0]
                    $BottomStatus.Text='Duplicated voice as '+$name
                } catch {$BottomStatus.Text=$_.Exception.Message}
            } else {
                $target=$window.FindName([string]$sender.Tag)
                $target.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            }
        })
        [void]$menu.Items.Add($item)
    }
    $menu.Add_Opened({
        $row=$AliasGrid.SelectedItem
        foreach($item in $AliasGrid.ContextMenu.Items){$item.IsEnabled=$null -ne $row;if($item.Tag -eq 'ToggleFavoriteButton'){$item.Header=if($row -and $row.Favorite){'Unfavorite'}else{'Favorite'}}}
    })
    $AliasGrid.ContextMenu=$menu
    $AliasGrid.Add_PreviewMouseRightButtonDown({param($sender,$e)
        $node=$e.OriginalSource
        while($node -and $node -isnot [Windows.Controls.DataGridRow]){
            if($node -is [Windows.Media.Visual]){$node=[Windows.Media.VisualTreeHelper]::GetParent($node)}else{$node=$null}
        }
        if($node){$node.IsSelected=$true}else{$AliasGrid.SelectedItem=$null}
    })
}

function Install-YapLoqQueue {
    $toolbar = $QueuePage.Children[0]
    $toolbar.Children.Clear(); $toolbar.ColumnDefinitions.Clear()
    $panel = [Windows.Controls.WrapPanel]::new()
    foreach ($name in @('PauseAfterQueueButton','RemoveQueueButton','QueueUpButton','QueueDownButton','ClearQueueButton')) {
        $button = $window.FindName($name)
        if ($button.Parent -is [Windows.Controls.Panel]) { [void]$button.Parent.Children.Remove($button) }
        $button.Margin = '0,0,8,8'; $button.Padding = '10,8'
        [void]$panel.Children.Add($button)
    }
    $toolbar.Margin = '0,0,0,6'; [void]$toolbar.Children.Add($panel)
    $queueMenu = [Windows.Controls.ContextMenu]::new()
    foreach ($entry in @(@('Remove','RemoveQueueButton'),@('Move up','QueueUpButton'),@('Move down','QueueDownButton'))) {
        $item = [Windows.Controls.MenuItem]::new(); $item.Header = $entry[0]; $item.Tag = $entry[1]
        $item.Add_Click({param($sender,$e) $target=$window.FindName([string]$sender.Tag);$target.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})
        [void]$queueMenu.Items.Add($item)
    }
    $copy = [Windows.Controls.MenuItem]::new(); $copy.Header = 'Copy message'
    $copy.Add_Click({if($QueueGrid.SelectedItem){[Windows.Clipboard]::SetText([string]$QueueGrid.SelectedItem.Text)}})
    [void]$queueMenu.Items.Add($copy); $QueueGrid.ContextMenu = $queueMenu
    $QueueGrid.Add_PreviewMouseRightButtonDown({param($sender,$e)
        $node = $e.OriginalSource
        while ($node -and $node -isnot [Windows.Controls.DataGridRow]) {
            if ($node -is [Windows.Media.Visual]) { $node = [Windows.Media.VisualTreeHelper]::GetParent($node) } else { $node = $null }
        }
        if ($node) { $node.IsSelected = $true }
    })
}

function Install-YapLoqCombinedQueue {
    # Keep the original grids as command/selection adapters, with one visible table.
    $QueuePage.Children.Clear();$QueuePage.RowDefinitions.Clear()
    foreach($height in @('Auto','*')){$row=[Windows.Controls.RowDefinition]::new();$row.Height=$height;$QueuePage.RowDefinitions.Add($row)}
    $toolbar=[Windows.Controls.Grid]::new();$toolbar.Margin='0,0,0,8';$toolbar.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$auto=[Windows.Controls.ColumnDefinition]::new();$auto.Width='Auto';$toolbar.ColumnDefinitions.Add($auto)
    $script:queueSelectionActions=[Windows.Controls.WrapPanel]::new()
    $script:queueSelectionHint=[Windows.Controls.TextBlock]::new();$script:queueSelectionHint.Text='Select a message for actions';$script:queueSelectionHint.Foreground=$window.FindResource('Muted');$script:queueSelectionHint.VerticalAlignment='Center';$script:queueSelectionHint.Margin='0,8,0,8';[void]$script:queueSelectionActions.Children.Add($script:queueSelectionHint)
    foreach($name in @('RemoveQueueButton','QueueUpButton','QueueDownButton','ReplayHistoryButton','SaveHistoryAudioButton','ShowHistoryAudioButton')){
        $button=$window.FindName($name);if($button.Parent -is [Windows.Controls.Panel]){[void]$button.Parent.Children.Remove($button)}
        $button.MinHeight=32;$button.Height=32;$button.Padding='10,0';$button.Margin='0,0,6,0';$button.Visibility='Collapsed';[void]$script:queueSelectionActions.Children.Add($button)
    }
    [void]$toolbar.Children.Add($script:queueSelectionActions)
    $more=[Windows.Controls.Button]::new();$more.Content='More';$more.MinHeight=32;$more.Height=32;$more.Margin=0;$more.ToolTip='Queue and history options'
    $more.ContextMenu=[Windows.Controls.ContextMenu]::new()
    foreach($spec in @(@('Clear waiting queue','ClearQueueButton'),@('Clear recent history','ClearHistoryButton'))){
        $item=[Windows.Controls.MenuItem]::new();$item.Header=$spec[0];$item.Tag=$spec[1]
        $item.Add_Click({param($sender,$e)$button=$window.FindName([string]$sender.Tag);if($button.IsEnabled){$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}});[void]$more.ContextMenu.Items.Add($item)
    }
    $more.ContextMenu.Add_Opened({param($sender,$e)foreach($item in $sender.Items){$item.IsEnabled=if($item.Tag -eq 'ClearQueueButton'){@($QueueGrid.ItemsSource|Where-Object{$_.Id -ne $script:lastPlaybackState.current.id}).Count -gt 0}else{$HistoryGrid.Items.Count -gt 0}}})
    $more.Add_Click({param($sender,$e)$sender.ContextMenu.PlacementTarget=$sender;$sender.ContextMenu.Placement='Bottom';$sender.ContextMenu.IsOpen=$true})
    [Windows.Controls.Grid]::SetColumn($more,1);[void]$toolbar.Children.Add($more);[void]$QueuePage.Children.Add($toolbar)
    $script:unifiedQueueGrid=[Windows.Controls.DataGrid]::new();$table=$script:unifiedQueueGrid
    $table.AutoGenerateColumns=$false;$table.IsReadOnly=$true;$table.SelectionMode='Single';$table.CanUserSortColumns=$false;$table.CanUserAddRows=$false;$table.BorderThickness=0
    # Sorting is intentionally disabled so live jobs cannot mix with history.
    foreach($column in @($QueueGrid.Columns)){[void]$QueueGrid.Columns.Remove($column);$table.Columns.Add($column)}
    $table.RowStyle=$window.FindResource('SpeechGridRow')
    $table.Add_SelectionChanged({Sync-YapLoqQueueSelection $true})
    $table.Add_ContextMenuOpening({param($sender,$e)if(-not $sender.SelectedItem -or $sender.SelectedItem.IsDivider){$e.Handled=$true}})
    $table.Add_MouseDoubleClick({$row=$script:unifiedQueueGrid.SelectedItem;if($row -and $row.RowKind -eq 'History' -and $row.HasAudio){$ReplayHistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}})
    $border=[Windows.Controls.Border]::new();$border.CornerRadius=10;$border.BorderThickness=1;$border.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#50485C');$border.Child=$table
    [Windows.Controls.Grid]::SetRow($border,1);[void]$QueuePage.Children.Add($border)
    $pause=$PauseAfterQueueButton;if($pause.Parent -is [Windows.Controls.Panel]){[void]$pause.Parent.Children.Remove($pause)}
    $pause.Style=$window.FindResource('PlayerTransportButton');$pause.Width=28;$pause.Height=28;$pause.MinHeight=28;$pause.Padding=0;$pause.Margin='2,0';$pause.VerticalAlignment='Center';$pause.ToolTip='Pause after current message';[Windows.Automation.AutomationProperties]::SetName($pause,'Pause after current message')
    $pauseIcon=[Windows.Shapes.Path]::new();$pauseIcon.Data=(Resolve-VoiceIcon 'mdi:stop').Geometry;$pauseIcon.Tag='mdi:stop';$pauseIcon.Width=12;$pauseIcon.Height=12;$pauseIcon.Stretch='Uniform'
    $pauseFill=[Windows.Data.Binding]::new('Foreground');$pauseFill.RelativeSource=[Windows.Data.RelativeSource]::new([Windows.Data.RelativeSourceMode]::FindAncestor,[Windows.Controls.Button],1);[void]$pauseIcon.SetBinding([Windows.Shapes.Shape]::FillProperty,$pauseFill);$pause.Content=$pauseIcon
    [void]$NowPlayingSkipButton.Parent.Children.Add($pause)
    $script:mediaSaveAudioButton=[Windows.Controls.Button]::new();$save=$script:mediaSaveAudioButton;$save.Style=$window.FindResource('PlayerTransportButton');$save.VerticalAlignment='Center';$save.ToolTip='Save the audio shown in the player';[Windows.Automation.AutomationProperties]::SetName($save,'Save player audio')
    $saveIcon=[Windows.Shapes.Path]::new();$saveIcon.Data=[Windows.Media.Geometry]::Parse($script:shellMarkup.SelectSingleNode("//*[@Name='SaveHistoryAudioButton']//*[local-name()='Path'][@Data]").GetAttribute('Data'));$saveIcon.Width=12;$saveIcon.Height=12;$saveIcon.Stretch='Uniform'
    $fill=[Windows.Data.Binding]::new('Foreground');$fill.RelativeSource=[Windows.Data.RelativeSource]::new([Windows.Data.RelativeSourceMode]::FindAncestor,[Windows.Controls.Button],1);[void]$saveIcon.SetBinding([Windows.Shapes.Shape]::FillProperty,$fill);$save.Content=$saveIcon
    $save.Add_Click({$recording=Get-MediaRecordingTarget;if($recording){Save-SpeechRecording ([string]$recording.Id)}})
    $NowPlayingSkipButton.Parent.Children.Insert(0,$save)
    $pause.Add_Click({try{Invoke-BridgePost $(if($script:lastPlaybackState.pauseAfterCurrent){'/resume'}else{'/pause-after-current'})|Out-Null;Refresh-ServiceState}catch{$BottomStatus.Text=$_.Exception.Message}})
    Update-YapLoqUnifiedQueue
}

function Sync-YapLoqQueueSelection([bool]$UserSelection=$false) {
    if($script:syncingUnifiedQueue){return}
    $row=$script:unifiedQueueGrid.SelectedItem
    if($UserSelection){$script:unifiedSelectionId=[string]$row.Id}
    $QueueGrid.SelectedItem=if($row.RowKind -eq 'Live'){@($QueueGrid.ItemsSource|Where-Object{$_.Id -eq $row.Id})[0]}else{$null}
    $HistoryGrid.SelectedItem=if($row.RowKind -eq 'History'){@($HistoryGrid.ItemsSource|Where-Object{$_.Id -eq $row.Id})[0]}else{$null}
    Sync-HistoryAudioButton
    $isCurrent=$row.RowKind -eq 'Live' -and $row.Id -eq $script:lastPlaybackState.current.id
    $script:queueSelectionHint.Visibility=if($row -and -not $row.IsDivider -and -not $isCurrent){'Collapsed'}else{'Visible'}
    $script:queueSelectionHint.Text=if($isCurrent){'Current speech - playback controls below'}elseif($QueueGrid.Items.Count){[string]$QueueGrid.Items.Count+' live - '+[string]$HistoryGrid.Items.Count+' recent'}else{'Nothing queued - '+[string]$HistoryGrid.Items.Count+' recent'}
    foreach($button in $script:queueSelectionActions.Children|Where-Object{$_ -is [Windows.Controls.Button]}){
        $isLive=$button.Name -in @('RemoveQueueButton','QueueUpButton','QueueDownButton')
        $button.Visibility=if(($isLive -and $row.RowKind -eq 'Live' -and -not $isCurrent) -or (-not $isLive -and $row.RowKind -eq 'History')){'Visible'}else{'Collapsed'}
        $button.IsEnabled=if($isLive){$row.Id -and $row.Id -ne $script:lastPlaybackState.current.id}elseif($button -eq $ShowHistoryAudioButton){$button.IsEnabled}elseif($button -eq $ReplayHistoryButton){$row.HasAudio -and $row.Status -notin @('Queued','Playing','Paused','Generating','Waiting for action')}else{[bool]$row.HasAudio}
    }
}

function Show-YapLoqQueueHistory {
    if($script:unifiedQueueGrid -and $script:queueHistoryTarget){$script:unifiedQueueGrid.ScrollIntoView($script:queueHistoryTarget)}
}

function Update-YapLoqUnifiedQueue {
    if(-not $script:unifiedQueueGrid){return}
    $table=$script:unifiedQueueGrid
    if($table.ContextMenu -and $table.ContextMenu.IsOpen){return}
    $queued=@($QueueGrid.ItemsSource|Where-Object{$_});$liveIds=@($queued.Id)
    $history=@($HistoryGrid.ItemsSource|Where-Object{$_ -and $_.Id -notin $liveIds})
    $visibleLive=[Collections.Generic.List[object]]::new();$replayStatuses=@{}
    foreach($job in $queued){
        $original=if($job.Source -eq 'History recording' -and $job.AudioPath){@($history|Where-Object{$_.AudioPath -eq $job.AudioPath -or $_.SavedPath -eq $job.AudioPath})[0]}else{$null}
        if($original){
            # The first matching job is the active replay; retain the recording's
            # original position, timestamp and source instead of showing a duplicate.
            if(-not $replayStatuses.ContainsKey([string]$original.Id)){$replayStatuses[[string]$original.Id]=$job.Status}
        }else{$visibleLive.Add($job)}
    }
    $live=@($visibleLive|ForEach-Object{$_})
    $past=@(foreach($recording in $history){
        $display=$recording|Select-Object *
        if($replayStatuses.ContainsKey([string]$recording.Id)){$display.Status=$replayStatuses[[string]$recording.Id]}
        $display
    })
    foreach($row in $live){$row|Add-Member NoteProperty RowKind 'Live' -Force}
    foreach($row in $past){$row|Add-Member NoteProperty RowKind 'History' -Force}
    $incoming=@($live+$past)
    # A job can leave the live snapshot one poll before history catches up.
    # Retain that row through the handoff instead of removing/reinserting it.
    $incomingIds=@($incoming.Id)
    foreach($old in @($table.ItemsSource)){
        if(($old.RowKind -eq 'Live' -or $old.PendingHistory) -and $old.Id -notin $incomingIds){
            $handoff=$old|Select-Object *;$handoff.Status='Finished';$handoff.RowKind='History'
            $handoff|Add-Member NoteProperty PendingHistory $true -Force
            $incoming+=$handoff
        }
    }
    $available=@{};foreach($row in $incoming){$available[[string]$row.Id]=$row}
    $previous=@($script:queueDisplayOrder|Where-Object{$available.ContainsKey([string]$_)})
    $newRows=@(Sort-YapLoqSpeechRows @($incoming|Where-Object{$_.Id -notin $previous}))
    $script:queueDisplayOrder=@(@($newRows|ForEach-Object{$_.Id})+$previous|Where-Object{$_})
    $ordered=@(foreach($id in $script:queueDisplayOrder){$available[[string]$id]})
    $signature=(@($ordered|ForEach-Object{'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $_.Id,$_.Status,$_.Accent,$_.IconGeometry,$_.AudioLabel,$_.Text,$_.SavedPath,$_.HasAudio,$_.RowKind,$_.PendingHistory}) -join ';')+'|live='+$live.Count
    if($signature -ne $script:unifiedQueueSignature){
        $selectedId=if($table.SelectedItem.Id){[string]$table.SelectedItem.Id}else{$script:unifiedSelectionId}
        $items=$table.ItemsSource
        if($items -isnot [Collections.ObjectModel.ObservableCollection[object]]){$items=[Collections.ObjectModel.ObservableCollection[object]]::new();$table.ItemsSource=$items}
        $scroll=if($table.Template){$table.Template.FindName('DG_ScrollViewer',$table)}else{$null};$offset=if($scroll){$scroll.VerticalOffset}else{0}
        $script:queueHistoryTarget=@($past)[0]
        $script:syncingUnifiedQueue=$true
        try{
            for($index=$items.Count-1;$index -ge 0;$index--){if($items[$index].Id -notin @($ordered.Id)){$items.RemoveAt($index)}}
            for($index=0;$index -lt $ordered.Count;$index++){
                $row=$ordered[$index];$row|Add-Member NoteProperty IsDivider $false -Force
                if($index -ge $items.Count){$items.Add($row)}
                elseif($items[$index].Id -ne $row.Id){
                    $found=-1;for($scan=$index+1;$scan -lt $items.Count;$scan++){if($items[$scan].Id -eq $row.Id){$found=$scan;break}}
                    if($found -ge 0){$items.Move($found,$index)}else{$items.Insert($index,$row)}
                }
                $old=$items[$index]
                $before=(@('Status','Text','Alias','Accent','IconGeometry','AudioLabel','SavedPath','HasAudio','RowKind','PendingHistory')|ForEach-Object{[string]$old.$_}) -join '|'
                $after=(@('Status','Text','Alias','Accent','IconGeometry','AudioLabel','SavedPath','HasAudio','RowKind','PendingHistory')|ForEach-Object{[string]$row.$_}) -join '|'
                if($before -ne $after){$items[$index]=$row}
            }
            if($selectedId){$table.SelectedItem=@($items|Where-Object{$_.Id -eq $selectedId})[0]}
            if($scroll){$scroll.ScrollToVerticalOffset($offset)}
        }finally{$script:syncingUnifiedQueue=$false}
        $script:unifiedQueueSignature=$signature
    }
    Sync-YapLoqQueueSelection
    $PauseAfterQueueButton.Foreground=if($script:lastPlaybackState.pauseAfterCurrent){$window.FindResource('Accent')}else{$window.Foreground}
    $PauseAfterQueueButton.ToolTip=if($script:lastPlaybackState.pauseAfterCurrent){'Pause after current message is on'}else{'Pause after current message'}
    if($script:mediaSaveAudioButton){$script:mediaSaveAudioButton.IsEnabled=$null -ne (Get-MediaRecordingTarget)}
}

function Move-YapLoqDisplayedSpeech($id,$direction){
    $order=@($script:queueDisplayOrder);$index=[array]::IndexOf($order,[string]$id)
    $target=if($direction -eq 'up'){$index-1}else{$index+1}
    if($index -ge 0 -and $target -ge 0 -and $target -lt $order.Count){
        $swap=$order[$target];$order[$target]=$order[$index];$order[$index]=$swap
        $script:queueDisplayOrder=$order;$script:unifiedQueueSignature=$null
    }
}

function Install-YapLoqItemMenu($control, $actions, [bool]$PageActions=$false) {
    if(-not $control){return}
    $menu=[Windows.Controls.ContextMenu]::new();$menu.Tag=$control
    foreach($action in $actions){
        $item=[Windows.Controls.MenuItem]::new();$item.Header=$action[0]
        $item.Tag=[pscustomobject]@{Control=$control;Command=$action[1];RequiresRow=($action[2] -ne 'global')}
        $item.Add_Click({param($sender,$e)
            $command=$sender.Tag;$control=$command.Control;$row=$control.SelectedItem
            if($command.RequiresRow -and -not $row){return}
            try{
                if($command.Command -like 'copy:*'){
                    $property=$command.Command.Substring(5);$text=[string]$row.$property
                    if($text){[Windows.Clipboard]::SetText($text)}
                }elseif($command.Command -in @('edit-alias','test-alias','favorite-alias')){
                    $name=if($row.Alias){$row.Alias}else{$row.Name}
                    $alias=@($PlayVoiceList.Tag|Where-Object{$_.Name -eq $name})[0]
                    if($alias){
                        switch($command.Command){
                            'edit-alias'{$value=Show-AliasDialog $alias;if($value){Save-Alias $alias.Name $value}}
                            'test-alias'{$text=Show-TestDialog $alias.Name;if($text){Speak-Text $alias.Name $text 'Test'}}
                            'favorite-alias'{Set-VoiceFavorite $alias.Name (-not $alias.Favorite)}
                        }
                    }
                }else{
                    $button=if($command.Command -is [Windows.Controls.Button]){$command.Command}else{$window.FindName([string]$command.Command)}
                    if($button -and $button.IsEnabled){$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
                }
            }catch{$BottomStatus.Text=$_.Exception.Message}
        })
        [void]$menu.Items.Add($item)
    }
    $menu.Add_Opened({param($sender,$e)
        foreach($item in $sender.Items){
            $command=$item.Tag;$control=$command.Control;$row=$control.SelectedItem
            $enabled=(-not $command.RequiresRow -or $null -ne $row)
            if($command.Command -in @('edit-alias','test-alias','favorite-alias')){
                $name=if($row.Alias){$row.Alias}else{$row.Name}
                $alias=@($PlayVoiceList.Tag|Where-Object{$_.Name -eq $name})[0];$enabled=$enabled -and $null -ne $alias
                if($command.Command -eq 'favorite-alias'){$item.Header=if($alias.Favorite){'Unfavorite voice'}else{'Favorite voice'}}
            }
            if($command.Command -notlike 'copy:*' -and $command.Command -notin @('edit-alias','test-alias','favorite-alias')){
                $button=if($command.Command -is [Windows.Controls.Button]){$command.Command}else{$window.FindName([string]$command.Command)}
                $enabled=$enabled -and $button -and $button.IsEnabled
                if($control -eq $QueueGrid -and $command.Command -in @('RemoveQueueButton','QueueUpButton','QueueDownButton')){
                    $enabled=$enabled -and $row.Id -ne $script:lastPlaybackState.current.id
                }
            }
            if($control -eq $script:unifiedQueueGrid){
                $historyCommand=$command.Command -in @('ReplayHistoryButton','SaveHistoryAudioButton','ShowHistoryAudioButton')
                $liveCommand=$command.Command -in @('RemoveQueueButton','QueueUpButton','QueueDownButton')
                $moveCommand=$command.Command -in @('QueueUpButton','QueueDownButton')
                $item.Visibility=if(($historyCommand -and $row.RowKind -ne 'History') -or ($liveCommand -and -not $moveCommand -and $row.RowKind -ne 'Live')){'Collapsed'}else{'Visible'}
                if($liveCommand){$enabled=$enabled -and $row.RowKind -eq 'Live' -and $row.Id -ne $script:lastPlaybackState.current.id}
                if($historyCommand){$enabled=$enabled -and $row.HasAudio}
                $enabled=$enabled -and -not $row.IsDivider
            }
            $item.IsEnabled=[bool]$enabled
        }
    })
    $control.ContextMenu=$menu
    if($PageActions){return}
    $control.Add_PreviewMouseRightButtonDown({param($sender,$e)
        $node=$e.OriginalSource
        $containerType=if($sender -is [Windows.Controls.DataGrid]){[Windows.Controls.DataGridRow]}elseif($sender -is [Windows.Controls.ComboBox]){[Windows.Controls.ComboBoxItem]}else{[Windows.Controls.ListBoxItem]}
        while($node -and -not $containerType.IsInstanceOfType($node)){
            if($node -is [Windows.Media.Visual]){$node=[Windows.Media.VisualTreeHelper]::GetParent($node)}else{$node=$null}
        }
        if($node){$node.IsSelected=$true}
        elseif($sender -isnot [Windows.Controls.ComboBox]){$sender.SelectedItem=$null}
    })
}

function Install-YapLoqPageContextMenus {
    Install-YapLoqItemMenu $script:unifiedQueueGrid @(@('Replay','ReplayHistoryButton'),@('Save audio','SaveHistoryAudioButton'),@('Show audio file','ShowHistoryAudioButton'),@('Remove','RemoveQueueButton'),@('Move up','QueueUpButton'),@('Move down','QueueDownButton'),@('Copy message','copy:Text'),@('Edit voice','edit-alias'))
    Install-YapLoqItemMenu $QueueGrid @(@('Remove','RemoveQueueButton'),@('Move up','QueueUpButton'),@('Move down','QueueDownButton'),@('Copy message','copy:Text'),@('Edit voice','edit-alias'),@('Pause after current','PauseAfterQueueButton','global'))
    Install-YapLoqItemMenu $HistoryGrid @(@('Replay','ReplayHistoryButton'),@('Save audio','SaveHistoryAudioButton'),@('Show audio file','ShowHistoryAudioButton'),@('Copy message','copy:Text'),@('Edit voice','edit-alias'))
    Install-YapLoqItemMenu $PlaylistGrid @(@('Add playlist','AddPlaylistButton','global'),@('Edit playlist','EditPlaylistButton'),@('Test playlist','TestPlaylistButton'),@('Remove playlist','RemovePlaylistButton'),@('Copy name','copy:Name'))
    Install-YapLoqItemMenu $PronunciationGrid @(@('Add pronunciation','AddPronunciationButton','global'),@('Edit pronunciation','EditPronunciationButton'),@('Remove pronunciation','RemovePronunciationButton'),@('Move up','PronunciationUpButton'),@('Move down','PronunciationDownButton'),@('Copy written text','copy:DisplayWritten'),@('Copy spoken text','copy:Spoken'))
    Install-YapLoqItemMenu $VoiceRulesGrid @(@('Add rule','AddVoiceRuleButton','global'),@('Update from editor','UpdateVoiceRuleButton'),@('Test voice','TestVoiceRuleButton'),@('Remove rule','RemoveVoiceRuleButton'),@('Copy match','copy:value'))
    Install-YapLoqItemMenu $RoutingGrid @(@('Add route','AddRouteButton','global'),@('Update from editor','UpdateRouteButton'),@('Remove route','RemoveRouteButton'),@('Move up','RouteUpButton'),@('Move down','RouteDownButton'),@('Copy match','copy:value'))
    if($script:profanityGrid){
        $panel=$script:profanityGrid.Parent
        while($panel -and -not $panel.FindName('SaveProfanity')){$panel=$panel.Parent}
        if($panel){Install-YapLoqItemMenu $script:profanityGrid @(@('Add censor rule',$panel.FindName('Add'),'global'),@('Edit censor rule',$panel.FindName('Edit')),@('Remove censor rule',$panel.FindName('Remove')))}
    }
    Install-YapLoqItemMenu $EventTimelineGrid @(@('Copy event','copy:Event'),@('Copy speech ID','copy:Id'),@('Copy alias','copy:Alias'))
    Install-YapLoqItemMenu $ActivityList @(@('Copy log entry','copy:PSObject'))
    Install-YapLoqItemMenu $script:dashboardVoicePicker @(@('Edit voice','edit-alias'),@('Test voice','test-alias'),@('Favorite voice','favorite-alias'),@('Add voice','AddButton','global'))
    Install-YapLoqItemMenu ($window.FindName('StreamerExportCard')) @(@('Export actions','ExportStreamerBotButton','global'),@('Copy speech payload','CopyPayloadButton','global')) $true
    foreach($spec in @(@('VoiceStudioPage','VoiceStudio'),@('PollyPage','Polly'),@('ElevenLabsPage','ElevenLabs'),@('AzurePage','Azure'),@('GooglePage','Google'),@('WatsonPage','Watson'),@('UberDuckPage','UberDuck'),@('TtsMonsterPage','TtsMonster'),@('AcapelaPage','Acapela'),@('CereProcPage','CereProc'))){
        $page=$window.FindName($spec[0]);$save=$window.FindName('Save'+$spec[1]+'Button');$test=$window.FindName('Test'+$spec[1]+'Button')
        if($page -and $save -and $test){Install-YapLoqItemMenu $page @(@('Save service settings',$save,'global'),@('Test and load voices',$test,'global')) $true}
    }
}

function Install-YapLoqServices {
    $script:serviceToolbar = [Windows.Controls.WrapPanel]::new(); $script:serviceToolbar.Margin = '0'
    $script:serviceBack = New-YapLoqButton 'Back to setup' 'services' 'ServicesToggle'
    $script:serviceBack.Padding = '12,8'; $script:serviceBack.Margin = '0,0,12,0'
    [void]$script:serviceToolbar.Children.Add($script:serviceBack)
    $script:servicePicker = [Windows.Controls.ComboBox]::new(); $script:servicePicker.Width = 260
    $script:servicePicker.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#B6A3FF')
    [Windows.Automation.AutomationProperties]::SetName($script:servicePicker,'Choose a speech service')
    $script:servicePicker.ToolTip = 'Choose a service to open its connection settings.'
    $placeholder = [Windows.Controls.ComboBoxItem]::new(); $placeholder.Content = 'Choose a service...'; $placeholder.Tag = 'services'
    [void]$script:servicePicker.Items.Add($placeholder)
    foreach ($entry in $script:providerRoutes) {
        $item = [Windows.Controls.ComboBoxItem]::new(); $item.Content = $entry[0]; $item.Tag = $entry[1]
        [void]$script:servicePicker.Items.Add($item)
    }
    $script:servicePicker.SelectedIndex = 0
    $script:servicePicker.Add_SelectionChanged({param($sender,$e)
        if ($script:syncingServicePicker -or $e.OriginalSource -ne $sender -or -not $sender.SelectedItem) { return }
        Request-YapLoqPage ([string]$sender.SelectedItem.Tag)
    })
    [void]$script:serviceToolbar.Children.Add($script:servicePicker)
    $services = New-YapLoqPage 'services'
    $card = [Windows.Controls.Border]::new(); $card.Padding = 20; $card.CornerRadius = 12
    $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#282035')
    $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#9580ED'); $card.BorderThickness = 1
    $content = [Windows.Controls.StackPanel]::new(); $card.Child = $content
    foreach ($entry in @(
        @('Start with a speech service.',24,'#D9CCFF'),
        @('Choose a service below to open its setup page.',14,'#F6F3FA'),
        @('1   Choose your service',17,'#B6A3FF'),
        @('Use Windows voices for a quick start, or choose a provider you already use.',13,'#B9B2C2'),
        @('2   Connect and load voices',17,'#B6A3FF'),
        @('Follow the service guide, save your settings, then test the connection.',13,'#B9B2C2'),
        @('3   Make it yours',17,'#B6A3FF'),
        @('Open Voices to create a voice, then return to Dashboard to speak.',13,'#B9B2C2')
    )) {
        $text = [Windows.Controls.TextBlock]::new(); $text.Text = $entry[0]; $text.FontSize = $entry[1]
        $text.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($entry[2]); $text.TextWrapping = 'Wrap'; $text.Margin = '0,0,0,7'
        [void]$content.Children.Add($text)
    }
    $script:serviceTiles = [Windows.Controls.WrapPanel]::new(); $script:serviceTiles.Margin = '0,10,0,20'
    # Reuse the existing provider icon geometries from the app's icon set.
    $serviceIconSources = @{windowsService='SetupWindowsButton';voicestudio='VoiceStudioNav';polly='PollyNav';elevenlabs='ElevenLabsNav';azure='AzureNav';google='GoogleNav';watson='WatsonNav';uberduck='UberDuckNav';ttsmonster='TtsMonsterNav';acapela='AcapelaNav';cereproc='CereProcNav'}
    foreach ($provider in $script:providerRoutes) {
        $tile = [Windows.Controls.Button]::new(); $tile.Style=$window.FindResource('YapLoqNavButton')
        $tile.Tag=$provider[1];$tile.Width=112;$tile.Height=122;$tile.Padding='6,10';$tile.Margin='0,0,10,10';$tile.HorizontalContentAlignment='Center';$tile.VerticalContentAlignment='Top'
        $tile.ToolTip='Open '+$provider[0]+' setup';[Windows.Automation.AutomationProperties]::SetName($tile,$tile.ToolTip)
        $tileContent=[Windows.Controls.StackPanel]::new();$tileContent.Width=98
        $square=[Windows.Controls.Border]::new();$square.Width=58;$square.Height=58;$square.CornerRadius=12;$square.HorizontalAlignment='Center';$square.Margin='0,0,0,9'
        $square.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#332B43');$square.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#66548E');$square.BorderThickness=1
        $iconSource = $serviceIconSources[$provider[1]]
        $iconNode = $script:shellMarkup.SelectSingleNode("//*[@Name='$iconSource']//*[local-name()='Path'][@Data]")
        if ($iconNode) {
            $glyph=[Windows.Shapes.Path]::new();$glyph.Data=[Windows.Media.Geometry]::Parse($iconNode.GetAttribute('Data'));$glyph.Stretch='Uniform';$glyph.Width=27;$glyph.Height=27
            $glyph.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#C8B6FF');$square.Child=$glyph
        }
        $caption=[Windows.Controls.TextBlock]::new();$caption.Text=$provider[0];$caption.TextAlignment='Center';$caption.TextWrapping='Wrap';$caption.FontSize=12
        [void]$tileContent.Children.Add($square);[void]$tileContent.Children.Add($caption);$tile.Content=$tileContent
        $tile.Add_Click({param($sender,$e) Request-YapLoqPage ([string]$sender.Tag)})
        [void]$script:serviceTiles.Children.Add($tile)
    }
    $voices = New-YapLoqButton 'Open voices' 'voices' 'VoicesNav'; $voices.HorizontalAlignment = 'Left'; $voices.Style = $window.FindResource('PrimaryButton')
    [void]$content.Children.Add($voices); [void]$services.Children.Add($card)
    $existing = [Windows.Controls.TextBlock]::new(); $existing.Text = 'Already have credentials? Choose the provider above, paste the key or account details you already use, then save and test. Each provider page includes an official link for finding or creating credentials.'
    $existing.TextWrapping = 'Wrap'; $existing.Foreground = $window.FindResource('Muted'); $existing.Margin = '0,14,0,0'
    [void]$content.Children.Add($existing)
    [void]$services.Children.Add($script:serviceTiles)
    $windows = New-YapLoqPage 'windowsService'
    $title = [Windows.Controls.TextBlock]::new(); $title.Text = 'Windows voices'; $title.FontSize = 22; $title.Margin = '0,0,0,14'
    [void]$windows.Children.Add($title)
    $help = [Windows.Controls.TextBlock]::new(); $help.Text = 'Use the voices installed on this PC. No account or API key is needed.'; $help.TextWrapping = 'Wrap'; $help.Margin = '0,0,0,20'
    [void]$windows.Children.Add($help)
    [void]$WindowsVoicesCheck.Parent.Children.Remove($WindowsVoicesCheck); $WindowsVoicesCheck.Margin = '0,0,0,20'
    [void]$windows.Children.Add($WindowsVoicesCheck)
    $save = [Windows.Controls.Button]::new(); $save.Content = 'Save and load voices'; $save.HorizontalAlignment = 'Left'; $save.Style = $window.FindResource('PrimaryButton')
    $save.Add_Click({
        try { $settings=Read-Settings;Set-JsonProperty $settings 'windows_voices_enabled' ([bool]$WindowsVoicesCheck.IsChecked);Write-Settings $settings;Refresh-Voices }
        catch { $BottomStatus.Text=$_.Exception.Message }
    })
    [void]$windows.Children.Add($save)
}

function Add-YapLoqServiceHelp($page, [string]$text, [string]$url) {
    if (-not $page -or -not $url) { return }
    $panel = if ($page -is [Windows.Controls.ScrollViewer]) { $page.Content } else { $page }
    if (-not ($panel -is [Windows.Controls.Panel])) { return }
    $row = [Windows.Controls.Grid]::new(); $row.Margin = '0,0,0,14'
    $buttonColumn=[Windows.Controls.ColumnDefinition]::new();$buttonColumn.Width='Auto';$row.ColumnDefinitions.Add($buttonColumn)
    $row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $copy = [Windows.Controls.TextBlock]::new(); $copy.Text = $text; $copy.TextWrapping = 'Wrap'; $copy.VerticalAlignment = 'Center'; $copy.Foreground = $window.FindResource('Muted'); $copy.Margin = '0,0,12,0'; $copy.MaxWidth = 470
    $link = [Windows.Controls.Button]::new(); $link.Content = 'Open official setup'; $link.Tag = $url; $link.Padding = '10,7'; $link.Margin = 0
    $link.Add_Click({param($sender,$e) Open-VoxLink ([string]$sender.Tag)})
    $copy.Margin='14,0,0,0';$copy.MaxWidth=[double]::PositiveInfinity
    [Windows.Controls.Grid]::SetColumn($copy,1)
    [void]$row.Children.Add($link); [void]$row.Children.Add($copy); $panel.Children.Insert(0,$row)
}

function Update-YapLoqPendingServiceStatus([string]$id,[string]$name,[string]$page,[bool]$enabled) {
    $rows = [Collections.ArrayList]::new()
    foreach ($row in @($script:serviceHealthRows)) { if ($row.Id -ne $id) { [void]$rows.Add($row) } }
    if ($enabled) { [void]$rows.Add([pscustomobject]@{Id=$id;Name=$name;State='warn';Page=$page;Detail='Enabled - save to apply'}) }
    Apply-ServiceStatusSummary @($rows)
    if ($script:statusFlyout -and $script:statusFlyout.Visibility -eq 'Visible') { Render-ServiceStatusMenu @($rows) }
}

function Install-YapLoqServiceEnablePreview {
    foreach ($entry in @(
        @($WindowsVoicesCheck,'windows','Windows voices','windowsService'),@($VoiceStudioEnabledCheck,'voicestudio','VoiceStudio','voicestudio'),
        @($PollyEnabledCheck,'polly','Amazon Polly','polly'),@($ElevenLabsEnabledCheck,'elevenlabs','ElevenLabs','elevenlabs'),
        @($AzureEnabledCheck,'azure','Azure Speech','azure'),@($GoogleEnabledCheck,'google','Google Cloud TTS','google'),
        @($WatsonEnabledCheck,'watson','IBM Watson','watson'),@($UberDuckEnabledCheck,'uberduck','UberDuck','uberduck'),
        @($TtsMonsterEnabledCheck,'ttsmonster','TTS.Monster','ttsmonster'),@($AcapelaEnabledCheck,'acapela','Acapela','acapela'),
        @($CereProcEnabledCheck,'cereproc','CereProc','cereproc')
    )) {
        if (-not $entry[0]) { continue }
        $entry[0].Tag = [pscustomobject]@{Id=$entry[1];Name=$entry[2];Page=$entry[3]}
        $entry[0].Add_Click({param($sender,$e) $m=$sender.Tag;Update-YapLoqPendingServiceStatus $m.Id $m.Name $m.Page ([bool]$sender.IsChecked)})
    }
}

function Set-YapLoqAccordionWidths($root) {
    if ($root -is [Windows.Controls.ScrollViewer] -and $root.Content -is [Windows.Controls.Panel]) {
        $panel = $root.Content
        $panel.HorizontalAlignment = 'Stretch'
        $panel.MaxWidth = [double]::PositiveInfinity
        # Let the scroll content presenter subtract padding and panel margins.
        [Windows.Data.BindingOperations]::ClearBinding($panel,[Windows.FrameworkElement]::WidthProperty)
        $panel.Width=[double]::NaN
        $root.HorizontalScrollBarVisibility='Disabled';$root.HorizontalContentAlignment='Stretch'
    }
    if ($root -is [Windows.Controls.Expander]) {
        $root.HorizontalAlignment = 'Stretch'; $root.HorizontalContentAlignment = 'Stretch'
    }
    if ($root -is [Windows.DependencyObject]) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($root)) {
            if ($child -is [Windows.DependencyObject]) { Set-YapLoqAccordionWidths $child }
        }
    }
}

function Install-YapLoqStreamerExpanders {
    $streamerPanel = $StreamerBotPage.Content
    $index = 0
    foreach ($card in @($streamerPanel.Children | Where-Object { $_ -is [Windows.Controls.Border] })) {
        $content = $card.Child
        if ($content -is [Windows.Controls.Expander] -and $card.Tag -eq 'ServiceGuideCard') {
            $card.Child=$null
            $container=[Windows.Controls.StackPanel]::new();$card.Child=$container
            $toolbar=[Windows.Controls.Grid]::new();$toolbar.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
            foreach($unused in 1..2){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width='Auto';$toolbar.ColumnDefinitions.Add($column)}
            $heading=[Windows.Controls.TextBlock]::new();$heading.Text='Connect Streamer.Bot';$heading.FontSize=22;$heading.FontWeight='SemiBold';$heading.VerticalAlignment='Center';$heading.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#D9CCFF');[void]$toolbar.Children.Add($heading)
            $refresh=New-YapLoqRefreshButton;[Windows.Controls.Grid]::SetColumn($refresh,1);[void]$toolbar.Children.Add($refresh)
            $help=[Windows.Controls.Button]::new();$help.Content='?';$help.Width=34;$help.Height=42;$help.Padding=0;$help.Margin='8,0,0,0';$help.FontWeight='Bold';$help.ToolTip='Streamer.Bot quick start';[Windows.Automation.AutomationProperties]::SetName($help,'Streamer.Bot quick start')
            [Windows.Controls.Grid]::SetColumn($help,2);[void]$toolbar.Children.Add($help);[void]$container.Children.Add($toolbar)
            $script:streamerQuickHelp=[Windows.Controls.Border]::new();$script:streamerQuickHelp.Visibility='Collapsed';$script:streamerQuickHelp.Margin='0,12,0,0';$script:streamerQuickHelp.Padding=14;$script:streamerQuickHelp.CornerRadius=10;$script:streamerQuickHelp.BorderThickness=1
            $script:streamerQuickHelp.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#282035');$script:streamerQuickHelp.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#66548F')
            $steps=[Windows.Controls.StackPanel]::new();$script:streamerQuickHelp.Child=$steps
            $title=[Windows.Controls.TextBlock]::new();$title.Text='Streamer.Bot setup';$title.FontSize=16;$title.FontWeight='SemiBold';[void]$steps.Children.Add($title)
            $intro=[Windows.Controls.TextBlock]::new();$intro.Text='Send messages from Streamer.Bot to YapLoq.';$intro.TextWrapping='Wrap';$intro.Foreground=$window.FindResource('Muted');$intro.Margin='0,6,0,12';[void]$steps.Children.Add($intro)
            foreach($step in @(
                @('1. Enable the listener','In Connection, enable incoming UDP speech and save. Restart YapLoq after changing listener settings.','Open Connection','connection','mdi:lan-connect'),
                @('2. Import the speech actions','Choose a voice in Action export and export. In Streamer.Bot, click Import, paste the copied code into Import String, then import.','Open Action export','export','mdi:package-variant-closed'),
                @('3. Test from Streamer.Bot','On YapLoq - Speak, add a Core > Test trigger with a message argument, then run Test Trigger. Check YapLoq Queue for the message.','Open Queue','queue','mdi:playlist-play')
            )) {
                $row=[Windows.Controls.Grid]::new();$row.Margin='0,0,0,10';$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$column=[Windows.Controls.ColumnDefinition]::new();$column.Width='Auto';$row.ColumnDefinitions.Add($column)
                $copy=[Windows.Controls.StackPanel]::new();$copy.Margin='0,0,12,0'
                $label=[Windows.Controls.TextBlock]::new();$label.Text=$step[0];$label.FontWeight='SemiBold';[void]$copy.Children.Add($label)
                $body=[Windows.Controls.TextBlock]::new();$body.Text=$step[1];$body.TextWrapping='Wrap';$body.Foreground=$window.FindResource('Muted');$body.Margin='0,3,0,0';[void]$copy.Children.Add($body);[void]$row.Children.Add($copy)
                $button=New-YapLoqButton $step[2] 'streamerbot' 'QueueNav';$button.Padding='10,7';$button.Margin=0;$button.VerticalAlignment='Center';$button.Tag=$step[3]
                $button.Content.Children[0].Data=(Resolve-VoiceIcon $step[4]).Geometry
                $button.Resources['SectionShortcut']=$true
                $button.Add_Click({param($sender,$e)
                    if($sender.Tag -eq 'queue'){Request-YapLoqPage 'queue';return}
                    $target=switch($sender.Tag){'connection'{$UdpBox};'export'{$ExportVoiceAliasBox};'playback'{$EnableStreamerBotActionsCheck}}
                    $ancestor=$target
                    while($ancestor){if($ancestor -is [Windows.Controls.Expander]){$ancestor.IsExpanded=$true};$ancestor=$ancestor.Parent}
                    $target.BringIntoView();[void]$target.Focus()
                })
                [Windows.Controls.Grid]::SetColumn($button,1);[void]$row.Children.Add($button);[void]$steps.Children.Add($row)
            }
            $help.Add_Click({$script:streamerQuickHelp.Visibility=if($script:streamerQuickHelp.Visibility -eq 'Visible'){'Collapsed'}else{'Visible'};if($script:streamerQuickHelp.Visibility -eq 'Visible'){Animate-In $script:streamerQuickHelp}})
            [void]$container.Children.Add($script:streamerQuickHelp)
            continue
        }
        if (-not ($content -is [Windows.Controls.StackPanel])) { continue }
        $title = @($content.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] })[0]
        $rawTitle = [string]$title.Text
        $label = switch -Wildcard ($rawTitle) {
            '*Receive speech*' { 'Connection' }
            '*Send speech*' { 'Action export' }
            '*react to playback*' { 'Playback actions' }
            '*Queue controls*' { 'Queue controls' }
            default { $rawTitle -replace '^\d+\.\s*','' -replace '^Optional:\s*','' }
        }
        # Official MDI icons from Icônes, distinct from the navigation icons.
        $sectionIcon = switch ($label) {
            'Connection' { @('mdi:lan-connect','M4 1c-1.11 0-2 .89-2 2v4c0 1.11.89 2 2 2H1v2h12V9h-3c1.11 0 2-.89 2-2V3c0-1.11-.89-2-2-2zm0 2h6v4H4zM3 13v7h7v-2H5v-5zm11 0c-1.11 0-2 .89-2 2v4c0 1.11.89 2 2 2h-3v2h12v-2h-3c1.11 0 2-.89 2-2v-4c0-1.11-.89-2-2-2zm0 2h6v4h-6z') }
            'Action export' { @('mdi:package-variant-closed','M21 16.5c0 .38-.21.71-.53.88l-7.9 4.44c-.16.12-.36.18-.57.18s-.41-.06-.57-.18l-7.9-4.44A.99.99 0 0 1 3 16.5v-9c0-.38.21-.71.53-.88l7.9-4.44c.16-.12.36-.18.57-.18s.41.06.57.18l7.9 4.44c.32.17.53.5.53.88zM12 4.15l-1.89 1.07L16 8.61l1.96-1.11zM6.04 7.5L12 10.85l1.96-1.1l-5.88-3.4zM5 15.91l6 3.38v-6.71L5 9.21zm14 0v-6.7l-6 3.37v6.71z') }
            'Playback actions' { @('mdi:lightning-bolt','M11 15H6l7-14v8h5l-7 14z') }
            default { @('mdi:playlist-play','M3 10h11v2H3zm0-4h11v2H3zm0 8h7v2H3zm13-1v8l6-4z') }
        }
        $header = [Windows.Controls.StackPanel]::new(); $header.Orientation = 'Horizontal'
        if ($sectionIcon) {
            $icon = [Windows.Shapes.Path]::new(); $icon.Data = [Windows.Media.Geometry]::Parse($sectionIcon[1]);$icon.Tag=$sectionIcon[0]
            $icon.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#B6A3FF'); $icon.Stretch = 'Uniform'; $icon.Width = 16; $icon.Height = 16; $icon.Margin = '0,0,10,0'
            [void]$header.Children.Add($icon)
        }
        $headerText = [Windows.Controls.TextBlock]::new(); $headerText.Text = $label; $headerText.VerticalAlignment = 'Center'; $headerText.FontWeight = 'SemiBold'
        [void]$header.Children.Add($headerText)
        $expander = [Windows.Controls.Expander]::new(); $expander.Header = $header; $expander.IsExpanded = ($index -eq 0)
        try { $expander.Style = $window.FindResource('SettingsExpander') } catch {}
        $title.Visibility = 'Collapsed'; $card.Child = $expander; $expander.Content = $content; $index++
    }
}

function Set-YapLoqSidebarCollapsed([bool]$collapsed, [bool]$persist = $true) {
    $script:sidebarCollapsed = $collapsed
    $script:sidebarColumn.Width = if ($collapsed) { 72 } else { 232 }
    foreach ($button in @($script:yaploqNav.Values) + @($script:sidebarToggle)) {
        $label = $button.Content.Children[1]
        $icon = $button.Content.Children[0]
        $label.Visibility = if ($collapsed) { 'Collapsed' } else { 'Visible' }
        $icon.Margin = if ($collapsed) { '0' } else { '0,0,10,0' }
        $button.Width = if ($collapsed) { 48 } else { [double]::NaN }
        $button.Margin = if ($collapsed) { '12,3' } else { '10,3' }
        $button.Padding = if ($collapsed) { '12,12' } else { '16,12' }
        $button.HorizontalContentAlignment = if ($collapsed) { 'Center' } else { 'Left' }
    }
    $script:sidebarToggle.ToolTip = if ($collapsed) { 'Expand menu' } else { 'Collapse menu' }
    $script:sidebarToggle.Content.Children[0].Data = [Windows.Media.Geometry]::Parse($(if ($collapsed) {
        'M3 4h2v16H3z M10 6l6 6-6 6-1.4-1.4 4.6-4.6-4.6-4.6z'
    } else {
        'M3 4h2v16H3z M15 6l-6 6 6 6 1.4-1.4L11.8 12l4.6-4.6z'
    }))
    [Windows.Automation.AutomationProperties]::SetName($script:sidebarToggle,[string]$script:sidebarToggle.ToolTip)
    if (-not $collapsed) { Animate-In $script:sidebarNavigation }
    if ($persist) {
        $path = Join-Path $configDir 'ui-state.json'
        $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            $state = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
            $state | Add-Member -NotePropertyName sidebarCollapsed -NotePropertyValue $collapsed -Force
            [IO.File]::WriteAllText($temporary,($state | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,$null) } else { [IO.File]::Move($temporary,$path) }
        } catch { $BottomStatus.Text = 'Layout changed, but the menu preference could not be saved.' }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
}

function Update-YapLoqPlayerLayout {
    $grid = $NowPlayingBar.Child
    if ($grid.ActualWidth -le 0) { return }
    # Equal side columns keep transport centered regardless of track text or tools.
    $compact = $grid.ActualWidth -lt 940
    foreach ($button in @($script:playerQueueShortcut,$script:playerAudioShortcut)) {
        $button.Content.Children[1].Visibility = if ($compact) { 'Collapsed' } else { 'Visible' }
        $button.Content.Children[0].Margin = if ($compact) { '0' } else { '0,0,10,0' }
    }
    $tools = $NowPlayingHistoryButton.Parent
    $tools.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
    $grid.ColumnDefinitions[0].Width = '*'
    $grid.ColumnDefinitions[2].Width = '*'
    $grid.ColumnDefinitions[1].Width = [Math]::Min(300,[Math]::Max(160,$grid.ActualWidth - 2*($tools.DesiredSize.Width+12)))
}

function Position-YapLoqStatusMenu {
    if (-not $script:statusFlyout -or -not $BridgeStatusButton.IsLoaded) { return }
    $point = $BridgeStatusButton.TranslatePoint([Windows.Point]::new(0,0),$script:chromeRoot)
    $right = [Math]::Max(8,$script:chromeRoot.ActualWidth - $point.X - $BridgeStatusButton.ActualWidth)
    $script:statusFlyout.Margin = [Windows.Thickness]::new(0,4,$right,8)
    $height = $script:chromeRoot.ActualHeight - $script:chromeRoot.RowDefinitions[0].ActualHeight - 12
    $script:statusFlyout.MaxHeight = [Math]::Max(60,$height)
}

function Close-YapLoqStatusMenu {
    if ($script:statusFlyout) { $script:statusFlyout.Visibility = 'Collapsed' }
}

function Show-YapLoqStatusMenu {
    if ($script:statusFlyout.Visibility -eq 'Visible') { Close-YapLoqStatusMenu; return }
    try { Render-ServiceStatusMenu (Refresh-ServiceHealth $false) }
    catch { $BottomStatus.Text = 'Could not refresh service status.' }
    Position-YapLoqStatusMenu
    $script:statusFlyout.Visibility = 'Visible'
    Animate-In $script:statusFlyout
}

function Install-YapLoqChrome {
    # Keep all player shortcuts visible as the available page width changes.
    $NowPlayingBar.Child.ColumnDefinitions[2].Width = 'Auto'
    $script:sidebarNavigation = $script:yaploqNav.Dashboard.Parent
    $sidebar = $script:sidebarNavigation.Parent.Parent
    $script:sidebarColumn = $sidebar.Parent.Parent.ColumnDefinitions[0]
    $sidebar.RowDefinitions[0].Height = 56
    $script:sidebarToggle = New-YapLoqButton 'Collapse menu' 'toggle-sidebar' 'QueueNav'
    $script:sidebarToggle.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8F879A')
    [void]$sidebar.Children.Add($script:sidebarToggle)

    # Reparent the existing status text/dot/chevron so health polling stays canonical.
    $footer = $BridgeStatusButton.Parent
    [void]$footer.Children.Remove($BridgeStatusButton); $footer.Visibility = 'Collapsed'
    $buttons = $MinimizeButton.Parent
    $buttons.Children.Insert(0,$BridgeStatusButton)
    $BridgeStatusButton.Margin = '0,4,8,4'; $BridgeStatusButton.Padding = 0
    $BridgeStatusButton.MinHeight = 0; $BridgeStatusButton.Height = 30
    $BridgeStatusButton.MinWidth = 120; $BridgeStatusButton.MaxWidth = 220
    $shell = $BridgeStatusButton.Content; $shell.Padding = '10,3'; $shell.CornerRadius = 6
    $SideStatus.Parent.Children[0].Visibility = 'Collapsed'
    $SideStatus.Margin = 0; $SideStatus.TextWrapping = 'NoWrap'; $SideStatus.TextTrimming = 'CharacterEllipsis'; $SideStatus.FontSize = 12
    $tip = [Windows.Data.Binding]::new('Text'); $tip.Source = $SideStatus
    [void]$BridgeStatusButton.SetBinding([Windows.FrameworkElement]::ToolTipProperty,$tip)
    # The menu is a bounded visual inside the app, not a top-level Popup window.
    $script:serviceStatusListRef = Get-ServiceStatusListPanel
    $script:statusFlyout = $ServiceStatusPopup.Child; $ServiceStatusPopup.Child = $null
    $script:statusFlyout.Visibility = 'Collapsed'; $script:statusFlyout.MinWidth = 0; $script:statusFlyout.Width = 300
    $script:statusFlyout.HorizontalAlignment = 'Right'; $script:statusFlyout.VerticalAlignment = 'Top'
    $content = $script:statusFlyout.Child; $script:statusFlyout.Child = $null
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Content = $content; $script:statusFlyout.Child = $scroll
    $script:chromeRoot = $AppTitleBar.Parent
    [Windows.Controls.Grid]::SetRow($script:statusFlyout,1); [Windows.Controls.Panel]::SetZIndex($script:statusFlyout,100)
    [void]$script:chromeRoot.Children.Add($script:statusFlyout)
    $window.Add_SizeChanged({Position-YapLoqStatusMenu})
    $window.Add_Deactivated({Close-YapLoqStatusMenu})
    $window.Add_PreviewMouseDown({
        if ($script:statusFlyout.Visibility -eq 'Visible' -and -not $script:statusFlyout.IsMouseOver -and -not $BridgeStatusButton.IsMouseOver) { Close-YapLoqStatusMenu }
    })
    $window.Add_PreviewKeyDown({param($sender,$e) if($e.Key -eq 'Escape' -and $script:statusFlyout.Visibility -eq 'Visible'){Close-YapLoqStatusMenu;$e.Handled=$true}})
    $collapsed = $false
    try { $collapsed = [bool](Get-Content -LiteralPath (Join-Path $configDir 'ui-state.json') -Raw -ErrorAction Stop | ConvertFrom-Json).sidebarCollapsed } catch {}
    Set-YapLoqSidebarCollapsed $collapsed $false
}

function Install-YapLoqShell {
    # Resolve these explicitly: production startup exports only selected controls.
    $PageHeadingHost = $window.FindName('PageHeadingHost')
    $GetStartedExpander = $window.FindName('GetStartedExpander')
    Install-YapLoqStyles
    [xml]$script:shellMarkup = Get-Content -LiteralPath (Join-Path $resourceRoot 'YapLoq.xaml') -Raw
    $window.Title = 'YapLoq Preview'
    Initialize-AppBranding
    foreach ($name in @('TitleBrandLogo','SidebarBrandLogo','AboutBrandLogo')) {
        $image = $window.FindName($name)
        if ($name -eq 'SidebarBrandLogo') { $image.Visibility = 'Collapsed'; continue }
        if ($image -and $image.Parent -is [Windows.Controls.Panel]) {
            $parent = $image.Parent; $index = $parent.Children.IndexOf($image)
            $branding = [Windows.Controls.StackPanel]::new(); $branding.Orientation = 'Horizontal'
            $branding.Margin = $image.Margin; $branding.VerticalAlignment = 'Center'; $branding.HorizontalAlignment = 'Left'
            [Windows.Controls.Grid]::SetRow($branding,[Windows.Controls.Grid]::GetRow($image))
            [void]$parent.Children.Remove($image)
            # Reuse the original transparent microphone mark, also used by the app/tray icons.
            $image.Source = $window.Icon; $image.Margin = '0,0,8,0'
            $image.Width = $image.Height = if ($name -eq 'TitleBrandLogo') { 24 } elseif ($name -eq 'AboutBrandLogo') { 48 } else { 36 }
            $image.Visibility = 'Visible'
            [Windows.Automation.AutomationProperties]::SetName($image,'YapLoq logo mark')
            [void]$branding.Children.Add($image)
            $label = [Windows.Controls.TextBlock]::new(); $label.Text = 'YapLoq'; $label.FontWeight = 'SemiBold'
            $label.FontSize = if ($name -eq 'TitleBrandLogo') { 16 } else { 25 }
            $label.VerticalAlignment = 'Center'; $label.Foreground = $window.Foreground
            [void]$branding.Children.Add($label); $parent.Children.Insert($index,$branding)
        }
    }
    $aboutLogo = $window.FindName('AboutLogoImage')
    $redGearLogoPath = Join-Path $resourceRoot 'assets\redgear-logo.png'
    if ($aboutLogo -and (Test-Path -LiteralPath $redGearLogoPath)) {
        $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit(); $bitmap.CacheOption = 'OnLoad'; $bitmap.UriSource = [Uri]::new($redGearLogoPath); $bitmap.EndInit(); $bitmap.Freeze()
        $aboutLogo.Source = $bitmap
        [Windows.Automation.AutomationProperties]::SetName($aboutLogo,'RedGear logo')
    }
    $window.FindName('AppVersionLabel').Text = 'Preview'
    [Windows.Automation.AutomationProperties]::SetName($MinimizeButton,'Minimize YapLoq Preview')
    foreach ($name in @('AmbientGlowA','AmbientGlowB')) { $window.FindName($name).Visibility = 'Collapsed' }
    $script:providerRoutes = @(@('Windows voices','windowsService'),@('VoiceStudio','voicestudio'),@('Amazon Polly','polly'),@('ElevenLabs','elevenlabs'),@('Azure','azure'),@('Google','google'),@('Watson','watson'),@('UberDuck','uberduck'),@('TTS.Monster','ttsmonster'),@('Acapela','acapela'),@('CereProc','cereproc'))
    $script:ownerLastPage = @{Dashboard='playground';Voices='voices';Queue='queue';Services='services';Integrations='streamerbot';Settings='settings'}
    $script:ownerSections = @{
        Dashboard=@()
        Voices=@(@('Voices','voices','VoicesNav'),@('Playlists','playlists','RulesNav'),@('Routing','routing','RulesNav'),@('Pronunciation','pronunciation','PronunciationNav'),@('Censor','censor','RulesNav'))
        Queue=@(@('Queue','queue','QueueNav'),@('Rules','rules','RulesNav'))
        Integrations=@()
        Settings=@(@('Settings','settings','SettingsNav'),@('Diagnostics','activity','ActivityNav'))
    }
    $script:routeOwners = @{playground='Dashboard';voices='Voices';playlists='Voices';routing='Voices';voiceRules='Voices';pronunciation='Voices';queue='Queue';history='Queue';rules='Queue';services='Services';streamerbot='Integrations';settings='Settings';activity='Settings'}
    foreach ($entry in $script:providerRoutes) { $script:routeOwners[$entry[1]] = 'Services' }
    $script:routeOwners['censor'] = 'Voices'
    $script:shellContent = $VoicesPage.Parent
    $row = [Windows.Controls.RowDefinition]::new(); $row.Height = 0
    $script:shellContent.RowDefinitions.Insert(1,$row)
    foreach ($child in $script:shellContent.Children) {
        $index = [Windows.Controls.Grid]::GetRow($child)
        if ($index -ge 1) { [Windows.Controls.Grid]::SetRow($child,($index+1)) }
    }
    $script:sectionNav = [Windows.Controls.WrapPanel]::new(); $script:sectionNav.VerticalAlignment = 'Center'; $script:sectionNav.HorizontalAlignment = 'Right'; $script:sectionNav.Margin = 0
    $headingGrid = $PageHeadingHost.Parent
    [Windows.Controls.Grid]::SetColumn($script:sectionNav,0)
    [Windows.Controls.Panel]::SetZIndex($script:sectionNav,2)
    $headerActions = $RefreshButton.Parent
    [void]$headingGrid.Children.Remove($headerActions)
    $PageHeadingHost.Visibility = 'Collapsed'
    $headerControls = [Windows.Controls.Grid]::new();$headerControls.VerticalAlignment='Center'
    $headerControls.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $refreshColumn=[Windows.Controls.ColumnDefinition]::new();$refreshColumn.Width='Auto';$headerControls.ColumnDefinitions.Add($refreshColumn)
    $script:headerControls = $headerControls
    [Windows.Controls.Grid]::SetColumn($headerControls,0)
    [Windows.Controls.Grid]::SetColumnSpan($headerControls,2)
    $script:sectionNav.HorizontalAlignment='Left'
    [Windows.Controls.Grid]::SetColumn($headerActions,1)
    [void]$headerControls.Children.Add($script:sectionNav);[void]$headerControls.Children.Add($headerActions)
    [void]$headingGrid.Children.Add($headerControls)
    $RefreshButton.VerticalAlignment = 'Center'
    $RefreshButton.Margin = 0
    $RefreshButton.Parent.VerticalAlignment = 'Center'
    $RefreshButton.Parent.Margin = '16,0,0,0'
    $script:yaploqPages = @{}
    $censorPage = New-YapLoqPage 'censor'
    $censorCard = $script:profanityGrid
    while ($censorCard.Parent -and $censorCard.Parent -ne $window.FindName('RulesStack')) { $censorCard = $censorCard.Parent }
    if ($censorCard.Parent -is [Windows.Controls.Panel]) {
        [void]$censorCard.Parent.Children.Remove($censorCard)
        [void]$censorPage.Children.Add($censorCard)
        if ($censorCard.Child -is [Windows.Controls.Expander]) { $censorCard.Child.IsExpanded = $true; $censorCard.Child.Header = 'Censor text' }
    }
    $playlists = New-YapLoqPage 'playlists'; Move-YapLoqRuleCard $PlaylistGrid $playlists
    $routing = New-YapLoqPage 'routing'
    # Preserve the original editors, handlers, values and precedence when regrouping.
    foreach($ruleHeader in @(
        @('AutoVoiceRulesExpander','Voice selection','mdi:account-voice','M9 5a4 4 0 0 1 4 4a4 4 0 0 1-4 4a4 4 0 0 1-4-4a4 4 0 0 1 4-4m0 10c2.67 0 8 1.34 8 4v2H1v-2c0-2.66 5.33-4 8-4m7.76-9.64c2.02 2.2 2.02 5.25 0 7.27l-1.68-1.69c.84-1.18.84-2.71 0-3.89zM20.07 2c3.93 4.05 3.9 10.11 0 14l-1.63-1.63c2.77-3.18 2.77-7.72 0-10.74z'),
        @('RoutingExpander','Routing','mdi:call-split',''),
        @('MessageModerationExpander','Filters','mdi:filter-variant','M6 13h12v-2H6M3 6v2h18V6M10 18h4v-2h-4z'),
        @('LimitsViewersExpander','Limits','mdi:timer-sand','M6 2h12v6l-4 4l4 4v6H6v-6l4-4l-4-4zm10 14.5l-4-4l-4 4V20h8zm-4-5l4-4V4H8v3.5zM10 6h4v.75l-2 2l-2-2z')
    )) {
        $expander=$window.FindName($ruleHeader[0])
        $header=[Windows.Controls.StackPanel]::new();$header.Orientation='Horizontal'
        # Official MDI paths from the Icônes/Iconify collection; no reused navigation symbols.
        $icon=[Windows.Shapes.Path]::new();$icon.Data=if($ruleHeader[2] -eq 'mdi:call-split'){(Resolve-VoiceIcon $ruleHeader[2]).Geometry}else{[Windows.Media.Geometry]::Parse($ruleHeader[3])};$icon.Tag=$ruleHeader[2];$icon.Width=16;$icon.Height=16;$icon.Stretch='Uniform';$icon.VerticalAlignment='Center';$icon.Margin='0,0,10,0';$icon.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#B6A3FF')
        $label=[Windows.Controls.TextBlock]::new();$label.Text=$ruleHeader[1];$label.VerticalAlignment='Center';$label.FontWeight='SemiBold'
        [void]$header.Children.Add($icon);[void]$header.Children.Add($label);$expander.Header=$header
        [Windows.Automation.AutomationProperties]::SetName($expander,$ruleHeader[1])
    }
    $rulePanel = $RulesPage.Content
    $voiceCard = $window.FindName('AutoVoiceRulesExpander').Parent
    $routingCard = $window.FindName('RoutingExpander').Parent
    [void]$rulePanel.Children.Remove($voiceCard); [void]$rulePanel.Children.Remove($routingCard)
    [void]$routing.Children.Add($routingCard); [void]$routing.Children.Add($voiceCard)
    foreach ($ruleCard in @($rulePanel.Children)+@($routing.Children)) {
        if ($ruleCard -is [Windows.Controls.Border]) { $ruleCard.Margin = '0,0,0,14' }
    }
    foreach ($panel in @($playlists,$routing)) {
        $save = [Windows.Controls.Button]::new(); $save.Content = if($panel -eq $routing){'Save routing'}else{'Save rules'}; $save.HorizontalAlignment = 'Left'
        $save.Style = $window.FindResource('PrimaryButton'); $save.Add_Click({Save-Rules})
        [void]$panel.Children.Add($save)
    }
    Install-YapLoqServices
    $navigation = $VoicesNav.Parent; $navigation.Children.Clear()
    $script:yaploqNav = @{}
    foreach ($entry in @(@('Dashboard','PlaygroundNav'),@('Voices','VoicesNav'),@('Queue','QueueNav'),@('Services','ServicesToggle'),@('Integrations','StreamerBotNav'),@('Settings','SettingsNav'))) {
        $button = New-YapLoqButton $entry[0] ('owner:'+$entry[0]) $entry[1]
        if ($entry[0] -eq 'Integrations') { $button.Content.Children[1].Text='Streamer.Bot';$button.ToolTip='Streamer.Bot';[Windows.Automation.AutomationProperties]::SetName($button,'Streamer.Bot') }
        $script:yaploqNav[$entry[0]] = $button; [void]$navigation.Children.Add($button)
    }
    Install-YapLoqChrome
    Install-YapLoqDashboard
    Install-YapLoqQueue
    Install-YapLoqCombinedQueue
    # Favorite membership belongs to Add/Edit Voice; the list only filters it.
    $window.FindName('ToggleFavoriteButton').Visibility = 'Collapsed'
    $favoritesFilter = $window.FindName('FavoritesOnlyCheck')
    $favoritesFilter.Template = [Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="CheckBox">
 <Border Name="Shell" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="1" CornerRadius="8" Width="42" Height="42">
  <Path Name="Heart" Width="19" Height="19" Stretch="Uniform" Fill="#B6A3FF" Data="M12,21.35L10.55,20.03C5.4,15.36 2,12.28 2,8.5C2,5.42 4.42,3 7.5,3C9.24,3 10.91,3.81 12,5.09C13.09,3.81 14.76,3 16.5,3C19.58,3 22,5.42 22,8.5C22,12.28 18.6,15.36 13.45,20.03L12,21.35M7.5,5C5.5,5 4,6.5 4,8.5C4,11.4 7.2,14.3 12,18.6C16.8,14.3 20,11.4 20,8.5C20,6.5 18.5,5 16.5,5C14.9,5 13.3,6 12,7.5C10.7,6 9.1,5 7.5,5Z"/>
 </Border>
 <ControlTemplate.Triggers>
  <Trigger Property="IsChecked" Value="True"><Setter TargetName="Heart" Property="Data" Value="M12,21.35L10.55,20.03C5.4,15.36 2,12.28 2,8.5C2,5.42 4.42,3 7.5,3C9.24,3 10.91,3.81 12,5.09C13.09,3.81 14.76,3 16.5,3C19.58,3 22,5.42 22,8.5C22,12.28 18.6,15.36 13.45,20.03L12,21.35Z"/><Setter TargetName="Shell" Property="BorderBrush" Value="#B6A3FF"/></Trigger>
  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Shell" Property="Background" Value="#332B43"/></Trigger>
  <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Shell" Property="BorderBrush" Value="#C9BCFF"/></Trigger>
 </ControlTemplate.Triggers>
</ControlTemplate>
'@)
    $favoritesFilter.ToolTip='Show favorite voices only'
    [Windows.Automation.AutomationProperties]::SetName($favoritesFilter,'Show favorite voices only')
    Install-YapLoqVoiceContextMenu
    Install-YapLoqPageContextMenus
    Install-YapLoqStreamerExpanders
    foreach ($spec in @(@('AudioSettingsExpander','mdi:speaker'),@('LocalApiSettingsExpander','mdi:api'),@('LimitsSettingsExpander','mdi:speedometer'),@('WindowSettingsExpander','mdi:window-maximize'),@('DataSupportSettingsExpander','mdi:database-cog'))) {
        $section=$window.FindName($spec[0]); if(-not $section){continue}
        $header=[Windows.Controls.StackPanel]::new(); $header.Orientation='Horizontal'
        $resolved=Resolve-VoiceIcon $spec[1]
        $icon=[Windows.Shapes.Path]::new();$icon.Data=$resolved.Geometry;$icon.Fill=$window.FindResource('Accent');$icon.Width=16;$icon.Height=16;$icon.Stretch='Uniform';$icon.Margin='0,0,10,0';$icon.Tag=$spec[1]
        $label=[Windows.Controls.TextBlock]::new();$label.Text=[string]$section.Header;$label.VerticalAlignment='Center'
        [void]$header.Children.Add($icon);[void]$header.Children.Add($label);$section.Header=$header
    }
    Install-YapLoqServiceEnablePreview
    Install-YapLoqCredentialFields
    $aboutMark = $window.FindName('AboutBrandLogo')
    if ($aboutMark -and $aboutMark.Parent) { $aboutMark.Parent.Visibility = 'Collapsed' }
    Set-YapLoqAccordionWidths $window
    Add-YapLoqServiceHelp $PollyPage 'Already have AWS keys? Paste them below. Otherwise use the official IAM guide to create or manage an access key.' 'https://docs.aws.amazon.com/IAM/latest/UserGuide/access-keys-admin-managed.html'
    Add-YapLoqServiceHelp $ElevenLabsPage 'Paste an existing ElevenLabs API key below, or open the official API page to create one.' 'https://elevenlabs.io/api'
    Add-YapLoqServiceHelp $AzurePage 'Use an existing Speech resource key and region, or open the Azure portal to create or manage the resource.' 'https://portal.azure.com/#view/Microsoft_Azure_ProjectOxford/CognitiveServicesHub/~/SpeechServices'
    Add-YapLoqServiceHelp $GooglePage 'Use an existing API key or service-account JSON file. The official authentication guide explains both options.' 'https://cloud.google.com/text-to-speech/docs/authentication'
    Add-YapLoqServiceHelp $WatsonPage 'Use your existing IBM Cloud Text to Speech key and service URL, or open the service catalog.' 'https://cloud.ibm.com/catalog/services/text-to-speech'
    if ($GetStartedExpander -and $GetStartedExpander.Parent) {
        $getStartedCard = $GetStartedExpander.Parent
        $settingsHost = $getStartedCard.Parent
        if ($settingsHost -is [Windows.Controls.Panel]) { [void]$settingsHost.Children.Remove($getStartedCard) }
    }
    # Global queue and audio shortcuts remain alongside the existing player controls.
    $tools = $NowPlayingHistoryButton.Parent
    $queueShortcut = New-YapLoqButton 'Queue' 'queue' 'QueueNav'; $queueShortcut.Padding = '8,6'; $queueShortcut.Margin = '4,0,0,0'
    [void]$tools.Children.Add($queueShortcut)
    $audioShortcut = New-YapLoqButton 'Audio' 'settings' 'SettingsNav'; $audioShortcut.Padding = '8,6'; $audioShortcut.Margin = '4,0,0,0'
    [void]$tools.Children.Add($audioShortcut)
    $script:playerQueueShortcut = $queueShortcut; $script:playerAudioShortcut = $audioShortcut
    # Reserve equal timestamp slots, so longer elapsed/remaining text cannot move the track.
    $progress = $NowPlayingProgressTrack.Parent
    $progress.ColumnDefinitions[0].Width = 36; $progress.ColumnDefinitions[2].Width = 36
    $NowPlayingBar.Child.Add_SizeChanged({ Update-YapLoqPlayerLayout })
    $window.Add_PreviewKeyDown({param($sender,$e)
        if ($e.Key -eq 'S' -and [Windows.Input.Keyboard]::Modifiers -eq ([Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift)) {
            Open-YapLoqRoute 'emergency-stop'; $e.Handled = $true
        }
    })
    $NowPlayingStopClearButton.ToolTip = 'Stop playback and clear waiting speech (Ctrl+Shift+S)'
    foreach ($name in @('HttpBox','WsBox','PersistQueueCheck','CheckUpdatesOnStartupCheck','CheckUpdatesButton')) {
        $control = $window.FindName($name)
        if ($control) { $control.IsEnabled = $false; $control.ToolTip = 'Preview keeps desktop ports isolated; recovery and automatic updates are disabled.' }
    }
    $PageHeadingHost.Margin = '0'; $PageHeadingHost.Parent.Margin = '0,0,0,12'
    Set-Page 'playground'
    Register-YapLoqControlMotion $window
}
