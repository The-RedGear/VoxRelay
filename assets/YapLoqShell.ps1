# Incremental WPF shell. Existing controls and handlers retain their state and storage.
function New-YapLoqButton([string]$label, [string]$route, [string]$iconSource = 'VoicesNav') {
    $button = [Windows.Controls.Button]::new()
    $button.Style = $window.FindResource('NavButton')
    $button.Tag = $route
    $button.ToolTip = $label
    [Windows.Automation.AutomationProperties]::SetName($button, $label)
    $panel = [Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
    $node = $script:shellMarkup.SelectSingleNode("//*[@Name='$iconSource']//*[local-name()='Path'][@Data]")
    if ($node) {
        $path = [Windows.Shapes.Path]::new()
        $path.Data = [Windows.Media.Geometry]::Parse($node.GetAttribute('Data'))
        $path.Fill = $window.Foreground; $path.Stretch = 'Uniform'
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
        Set-Page $script:ownerLastPage[$owner]
    } else { Set-Page $route }
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
        $script:yaploqNav[$key].Style = $window.FindResource($(if($key -eq $owner){'SelectedNavButton'}else{'NavButton'}))
    }
    $script:sectionNav.Children.Clear()
    if ($owner -eq 'Services') {
        $overview = New-YapLoqButton 'Services' 'services' 'ServicesToggle'
        $overview.Margin = '0,0,10,10'; $overview.Padding = '12,8'
        [void]$script:sectionNav.Children.Add($overview)
        $picker = [Windows.Controls.ComboBox]::new(); $picker.Width = 220; $picker.Margin = '0,0,0,10'
        [Windows.Automation.AutomationProperties]::SetName($picker,'Configure provider')
        foreach ($entry in $script:providerRoutes) {
            $item = [Windows.Controls.ComboBoxItem]::new(); $item.Content = $entry[0]; $item.Tag = $entry[1]
            [void]$picker.Items.Add($item)
            if ($entry[1] -eq $page) { $picker.SelectedItem = $item }
        }
        $picker.Add_SelectionChanged({param($sender,$e) if($sender.SelectedItem){Set-Page ([string]$sender.SelectedItem.Tag)}})
        [void]$script:sectionNav.Children.Add($picker)
    } else {
        foreach ($entry in $script:ownerSections[$owner]) {
            $button = New-YapLoqButton $entry[0] $entry[1] $entry[2]
            $button.Margin = '0,0,8,10'; $button.Padding = '12,8'
            $button.Style = $window.FindResource($(if($entry[1] -eq $page){'SelectedNavButton'}else{'NavButton'}))
            [void]$script:sectionNav.Children.Add($button)
        }
    }
    $PageTitle.Text = $owner
    $PageSubtitle.Text = switch ($page) {
        'playground' {'Send speech and watch the next messages'}
        'rules' {'Message admission, filtering and moderation'}
        'voiceRules' {'Choose how messages sound; existing rule precedence is preserved'}
        'playlists' {'Reusable voice pools'}
        'services' {'Configure a provider; credentials stay here'}
        'activity' {'Events, logs and action diagnostics'}
        default {$PageSubtitle.Text}
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
    $editor.Padding = 14; $editor.VerticalAlignment = 'Top'
    $grid = $editor.Child
    $grid.RowDefinitions[1].Height = 'Auto'
    $PlaygroundText.Height = 64; $PlaygroundText.FontSize = 14; $PlaygroundText.Margin = '0,8,0,8'
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
    # Playback controls have one home in the persistent player.
    $PlayStopButton.Visibility = 'Collapsed'
    foreach ($text in $PlayButton.Content.Children) { if ($text -is [Windows.Controls.TextBlock]) { $text.Text = 'Send to queue' } }
    $PlayButton.ToolTip = 'Generate speech and add it to the live queue. Test voice also uses the current playback queue.'
    $next = [Windows.Controls.Border]::new(); $next.Margin = '0,14,0,0'; $next.Padding = 12
    $next.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#1E1A27'); $next.CornerRadius = 10
    [Windows.Controls.Grid]::SetRow($next,1)
    $panel = [Windows.Controls.StackPanel]::new(); $next.Child = $panel
    $open = New-YapLoqButton 'Upcoming - Open queue' 'queue' 'QueueNav'; $open.HorizontalAlignment = 'Left'; $open.Margin = '0,0,0,6'; $open.Padding = '8,6'
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

function Install-YapLoqShell {
    [xml]$script:shellMarkup = Get-Content -LiteralPath (Join-Path $resourceRoot 'VoxRelay.xaml') -Raw
    $window.Title = 'YapLoq Preview'
    foreach ($name in @('TitleBrandLogo','SidebarBrandLogo','AboutBrandLogo')) {
        $image = $window.FindName($name)
        if ($image -and $image.Parent -is [Windows.Controls.Panel]) {
            $label = [Windows.Controls.TextBlock]::new(); $label.Text = 'YapLoq'; $label.FontWeight = 'SemiBold'
            $label.FontSize = if ($name -eq 'TitleBrandLogo') { 16 } else { 25 }
            $label.Margin = $image.Margin; $label.VerticalAlignment = 'Center'; $label.Foreground = $window.Foreground
            [Windows.Controls.Grid]::SetRow($label,[Windows.Controls.Grid]::GetRow($image))
            $index = $image.Parent.Children.IndexOf($image)
            $image.Parent.Children.Insert($index,$label); $image.Visibility = 'Collapsed'
        }
    }
    $window.FindName('AppVersionLabel').Text = 'Preview'
    [Windows.Automation.AutomationProperties]::SetName($MinimizeButton,'Minimize YapLoq Preview')
    foreach ($name in @('AmbientGlowA','AmbientGlowB')) { $window.FindName($name).Visibility = 'Collapsed' }
    $script:providerRoutes = @(@('VoiceStudio','voicestudio'),@('Amazon Polly','polly'),@('ElevenLabs','elevenlabs'),@('Azure','azure'),@('Google','google'),@('Watson','watson'),@('UberDuck','uberduck'),@('TTS.Monster','ttsmonster'),@('Acapela','acapela'),@('CereProc','cereproc'))
    $script:ownerLastPage = @{Dashboard='playground';Voices='voices';Queue='queue';Services='services';Integrations='streamerbot';Settings='settings'}
    $script:ownerSections = @{
        Dashboard=@()
        Voices=@(@('Voices','voices','VoicesNav'),@('Playlists','playlists','RulesNav'),@('Rules','voiceRules','RulesNav'),@('Pronunciation','pronunciation','PronunciationNav'))
        Queue=@(@('Queue','queue','QueueNav'),@('History','history','HistoryNav'),@('Rules','rules','RulesNav'))
        Integrations=@()
        Settings=@(@('Settings','settings','SettingsNav'),@('Diagnostics','activity','ActivityNav'))
    }
    $script:routeOwners = @{playground='Dashboard';voices='Voices';playlists='Voices';voiceRules='Voices';pronunciation='Voices';queue='Queue';history='Queue';rules='Queue';services='Services';streamerbot='Integrations';settings='Settings';activity='Settings'}
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
    $voiceRules = New-YapLoqPage 'voiceRules'; Move-YapLoqRuleCard $VoiceRulesGrid $voiceRules; Move-YapLoqRuleCard $RoutingGrid $voiceRules
    foreach ($panel in @($playlists,$voiceRules)) {
        $save = [Windows.Controls.Button]::new(); $save.Content = 'Save rules'; $save.HorizontalAlignment = 'Left'
        $save.Style = $window.FindResource('PrimaryButton'); $save.Add_Click({Save-Rules})
        [void]$panel.Children.Add($save)
    }
    $services = New-YapLoqPage 'services'
    foreach ($entry in $script:providerRoutes) {
        $button = New-YapLoqButton ($entry[0] + ' - Configure') $entry[1] 'ServicesToggle'
        $button.Margin = '0,0,0,8'; [void]$services.Children.Add($button)
    }
    $windows = New-YapLoqButton 'Windows voices - Configure' 'settings' 'SettingsNav'
    $windows.ToolTip = 'Windows voice enablement is retained in Settings during the shell migration.'
    [void]$services.Children.Add($windows)
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
