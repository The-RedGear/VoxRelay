# Incremental WPF shell. Existing controls and handlers retain their state and storage.
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
    [void]$panel.Children.Add($text); $button.Content = $panel
    $button.Add_Click({ param($sender,$e) Open-YapLoqRoute ([string]$sender.Tag) })
    return $button
}

function Open-YapLoqRoute([string]$route) {
    if ($route -eq 'emergency-stop') {
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
    $owner = $script:routeOwners[$page]
    if (-not $owner) { return }
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
                $button.Margin = '0,0,8,10'; $button.Padding = '12,8'
                [void]$script:sectionNav.Children.Add($button)
            }
        }
        Animate-In $script:sectionNav
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
    $PageTitle.Text = $owner
    $PageSubtitle.Text = switch ($page) {
        'playground' {'Your voice. Your stream.'}
        'rules' {'All your rules in one place: voice selection, routing and message filters'}
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

function Update-YapLoqDashboard($state) {
    if (-not $script:dashboardUpcoming) { return }
    $script:dashboardUpcoming.Children.Clear()
    $items = @($state.queue | Where-Object { $_ } | Select-Object -First 3)
    if (-not $items.Count) {
        $empty = [Windows.Controls.TextBlock]::new(); $empty.Text = 'Queue empty'; $empty.Foreground = $window.FindResource('Muted')
        [void]$script:dashboardUpcoming.Children.Add($empty)
    }
    foreach ($item in $items) {
        $row = [Windows.Controls.TextBlock]::new(); $row.TextTrimming = 'CharacterEllipsis'; $row.Margin = '0,0,0,10'
        $row.Text = ([string]$item.alias + '  -  ' + (Get-DisplayText ([string]$item.text)))
        [void]$script:dashboardUpcoming.Children.Add($row)
    }
    if ($script:dashboardQueueSignature -ne ($items | ConvertTo-Json -Compress -Depth 4)) {
        Animate-In $script:dashboardUpcoming
        $script:dashboardQueueSignature = $items | ConvertTo-Json -Compress -Depth 4
    }
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
    $itemsBinding = [Windows.Data.Binding]::new('Items'); $itemsBinding.Source = $PlayVoiceList
    [void]$selector.SetBinding([Windows.Controls.ItemsControl]::ItemsSourceProperty,$itemsBinding)
    $selectionBinding = [Windows.Data.Binding]::new('SelectedItem'); $selectionBinding.Source = $PlayVoiceList; $selectionBinding.Mode = 'TwoWay'
    [void]$selector.SetBinding([Windows.Controls.Primitives.Selector]::SelectedItemProperty,$selectionBinding)
    $grid.Children[0].Visibility = 'Collapsed'
    [void]$grid.Children.Add($selector)
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
    $intro = [Windows.Controls.StackPanel]::new()
    $title = [Windows.Controls.TextBlock]::new(); $title.Text = 'Turn text into speech.'; $title.FontSize = 22; $title.FontWeight = 'SemiBold'
    $title.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#D9CCFF')
    [void]$intro.Children.Add($title)
    $hint = [Windows.Controls.TextBlock]::new(); $hint.Text = 'Choose a voice. Write a message. Press Speak.'; $hint.TextWrapping = 'Wrap'; $hint.Margin = '0,4,12,0'
    $hint.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#D1C8DF'); [void]$intro.Children.Add($hint)
    $hint.Visibility = 'Collapsed'
    [void]$headline.Children.Add($intro)
    $setup = New-YapLoqButton 'Connect a service' 'services' 'ServicesToggle'
    $setup.Style = $window.FindResource('PrimaryButton'); $setup.Padding = '12,8'; $setup.VerticalAlignment = 'Center'; $setup.Margin = '12,0,0,0'
    [Windows.Controls.Grid]::SetColumn($setup,1); [void]$headline.Children.Add($setup)
    foreach ($child in @($grid.Children)) { [Windows.Controls.Grid]::SetRow($child,([Windows.Controls.Grid]::GetRow($child)+1)) }
    $headRow = [Windows.Controls.RowDefinition]::new(); $headRow.Height = 'Auto'; $grid.RowDefinitions.Insert(0,$headRow)
    [void]$grid.Children.Add($headline)
    $script:dashboardPlaceholder = [Windows.Controls.TextBlock]::new()
    $script:dashboardPlaceholder.Text = 'Type a message to speak...'; $script:dashboardPlaceholder.Margin = '12,20,12,12'
    $script:dashboardPlaceholder.Foreground = $window.FindResource('Muted'); $script:dashboardPlaceholder.IsHitTestVisible = $false
    [Windows.Controls.Grid]::SetRow($script:dashboardPlaceholder,[Windows.Controls.Grid]::GetRow($PlaygroundText))
    [void]$grid.Children.Add($script:dashboardPlaceholder)
    $PlaygroundText.Add_TextChanged({$script:dashboardPlaceholder.Visibility=if($PlaygroundText.Text.Length){'Collapsed'}else{'Visible'}})
    # Playback controls have one home in the persistent player.
    $PlayStopButton.Visibility = 'Collapsed'
    foreach ($text in $PlayButton.Content.Children) { if ($text -is [Windows.Controls.TextBlock]) { $text.Text = 'Speak message' } }
    [Windows.Automation.AutomationProperties]::SetName($PlaygroundText,'Message to speak')
    $PlaygroundText.ToolTip = 'Write the message you want to hear. Speak message adds it to your queue.'
    $PlaygroundText.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#9580ED')
    $PlayButton.ToolTip = 'Generate speech and add it to the live queue. Test voice also uses the current playback queue.'
    $next = [Windows.Controls.Border]::new(); $next.Margin = '0,10,0,0'; $next.Padding = 10
    $next.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#1E1A27'); $next.CornerRadius = 10
    [Windows.Controls.Grid]::SetRow($next,1)
    $panel = [Windows.Controls.StackPanel]::new(); $next.Child = $panel
    $open = New-YapLoqButton 'Upcoming - Open queue' 'queue' 'QueueNav'; $open.HorizontalAlignment = 'Left'; $open.Margin = '0,0,0,6'; $open.Padding = '8,6'
    $open.MinHeight = 28
    [void]$panel.Children.Add($open)
    $script:dashboardUpcoming = [Windows.Controls.StackPanel]::new(); [void]$panel.Children.Add($script:dashboardUpcoming)
    [void]$PlaygroundPage.Children.Add($next)
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

function Install-YapLoqServices {
    $script:serviceToolbar = [Windows.Controls.WrapPanel]::new(); $script:serviceToolbar.Margin = '0,0,0,14'
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
        @('Pick one from the dropdown above. Its setup form will appear here.',14,'#F6F3FA'),
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
    $voices = New-YapLoqButton 'Open voices' 'voices' 'VoicesNav'; $voices.HorizontalAlignment = 'Left'; $voices.Style = $window.FindResource('PrimaryButton')
    [void]$content.Children.Add($voices); [void]$services.Children.Add($card)
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

function Install-YapLoqShell {
    Install-YapLoqStyles
    [xml]$script:shellMarkup = Get-Content -LiteralPath (Join-Path $resourceRoot 'VoxRelay.xaml') -Raw
    $window.Title = 'YapLoq Preview'
    Initialize-AppBranding
    foreach ($name in @('TitleBrandLogo','SidebarBrandLogo','AboutBrandLogo')) {
        $image = $window.FindName($name)
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
    $window.FindName('AppVersionLabel').Text = 'Preview'
    [Windows.Automation.AutomationProperties]::SetName($MinimizeButton,'Minimize YapLoq Preview')
    foreach ($name in @('AmbientGlowA','AmbientGlowB')) { $window.FindName($name).Visibility = 'Collapsed' }
    $script:providerRoutes = @(@('Windows voices','windowsService'),@('VoiceStudio','voicestudio'),@('Amazon Polly','polly'),@('ElevenLabs','elevenlabs'),@('Azure','azure'),@('Google','google'),@('Watson','watson'),@('UberDuck','uberduck'),@('TTS.Monster','ttsmonster'),@('Acapela','acapela'),@('CereProc','cereproc'))
    $script:ownerLastPage = @{Dashboard='playground';Voices='voices';Queue='queue';Services='services';Integrations='streamerbot';Settings='settings'}
    $script:ownerSections = @{
        Dashboard=@()
        Voices=@(@('Voices','voices','VoicesNav'),@('Playlists','playlists','RulesNav'),@('Pronunciation','pronunciation','PronunciationNav'))
        Queue=@(@('Queue','queue','QueueNav'),@('History','history','HistoryNav'),@('Rules','rules','RulesNav'))
        Integrations=@()
        Settings=@(@('Settings','settings','SettingsNav'),@('Diagnostics','activity','ActivityNav'))
    }
    $script:routeOwners = @{playground='Dashboard';voices='Voices';playlists='Voices';voiceRules='Queue';pronunciation='Voices';queue='Queue';history='Queue';rules='Queue';services='Services';streamerbot='Integrations';settings='Settings';activity='Settings'}
    foreach ($entry in $script:providerRoutes) { $script:routeOwners[$entry[1]] = 'Services' }
    $script:shellContent = $VoicesPage.Parent
    $row = [Windows.Controls.RowDefinition]::new(); $row.Height = 'Auto'
    $script:shellContent.RowDefinitions.Insert(1,$row)
    foreach ($child in $script:shellContent.Children) {
        $index = [Windows.Controls.Grid]::GetRow($child)
        if ($index -ge 1) { [Windows.Controls.Grid]::SetRow($child,($index+1)) }
    }
    $script:sectionNav = [Windows.Controls.WrapPanel]::new(); [Windows.Controls.Grid]::SetRow($script:sectionNav,1)
    [void]$script:shellContent.Children.Add($script:sectionNav)
    $script:yaploqPages = @{}
    $playlists = New-YapLoqPage 'playlists'; Move-YapLoqRuleCard $PlaylistGrid $playlists
    # One canonical rules workspace. Preserve handlers, values and current precedence.
    $window.FindName('AutoVoiceRulesExpander').Header = 'Voice selection - viewers and roles'
    $window.FindName('RoutingExpander').Header = 'Routing - voice and priority'
    $window.FindName('MessageModerationExpander').Header = 'Message filters - words, links and text'
    $window.FindName('LimitsViewersExpander').Header = 'Queue limits - viewers and cooldowns'
    $rulePanel = $RulesPage.Content
    $voiceCard = $window.FindName('AutoVoiceRulesExpander').Parent
    $routingCard = $window.FindName('RoutingExpander').Parent
    [void]$rulePanel.Children.Remove($voiceCard); [void]$rulePanel.Children.Remove($routingCard)
    $rulePanel.Children.Insert(0,$voiceCard); $rulePanel.Children.Insert(1,$routingCard)
    foreach ($panel in @($playlists)) {
        $save = [Windows.Controls.Button]::new(); $save.Content = 'Save rules'; $save.HorizontalAlignment = 'Left'
        $save.Style = $window.FindResource('PrimaryButton'); $save.Add_Click({Save-Rules})
        [void]$panel.Children.Add($save)
    }
    Install-YapLoqServices
    $navigation = $VoicesNav.Parent; $navigation.Children.Clear()
    $script:yaploqNav = @{}
    foreach ($entry in @(@('Dashboard','PlaygroundNav'),@('Voices','VoicesNav'),@('Queue','QueueNav'),@('Services','ServicesToggle'),@('Integrations','StreamerBotNav'),@('Settings','SettingsNav'))) {
        $button = New-YapLoqButton $entry[0] ('owner:'+$entry[0]) $entry[1]
        $script:yaploqNav[$entry[0]] = $button; [void]$navigation.Children.Add($button)
    }
    Install-YapLoqDashboard
    Install-YapLoqQueue
    # Global queue and audio shortcuts remain alongside the existing player controls.
    $tools = $NowPlayingHistoryButton.Parent
    $queueShortcut = New-YapLoqButton 'Queue' 'queue' 'QueueNav'; $queueShortcut.Padding = '8,6'; $queueShortcut.Margin = '4,0,0,0'
    [void]$tools.Children.Add($queueShortcut)
    $audioShortcut = New-YapLoqButton 'Audio' 'settings' 'SettingsNav'; $audioShortcut.Padding = '8,6'; $audioShortcut.Margin = '4,0,0,0'
    [void]$tools.Children.Add($audioShortcut)
    $window.Add_PreviewKeyDown({param($sender,$e)
        if ($e.Key -eq 'S' -and [Windows.Input.Keyboard]::Modifiers -eq ([Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift)) {
            Open-YapLoqRoute 'emergency-stop'; $e.Handled = $true
        }
    })
    $NowPlayingStopClearButton.ToolTip = 'Stop playback and clear waiting speech (Ctrl+Shift+S)'
    foreach ($name in @('HttpBox','WsBox','UdpBox','EnableUdpCheck','EnableStreamerBotActionsCheck','ObsDuckingCheck','PersistQueueCheck','CheckUpdatesOnStartupCheck','CheckUpdatesButton')) {
        $control = $window.FindName($name)
        if ($control) { $control.IsEnabled = $false; $control.ToolTip = 'Isolated preview: production connections, recovery and updates are disabled.' }
    }
    $PageHeadingHost.Margin = '0'; $PageHeadingHost.Parent.Margin = '0,0,0,12'
    Set-Page 'playground'
}
