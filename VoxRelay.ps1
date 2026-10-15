Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VoxRelayTaskbarIdentity {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@
[void][VoxRelayTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('VoxRelay.Desktop')

$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# NotifyIcon requires STA. Relaunch ourselves if needed.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
    $psi.WorkingDirectory = $appRoot
    $psi.UseShellExecute = $false
    if ($env:VSB_EXTERNAL_BACKEND) { $psi.EnvironmentVariables['VSB_EXTERNAL_BACKEND'] = $env:VSB_EXTERNAL_BACKEND }
    [void][System.Diagnostics.Process]::Start($psi)
    exit 0
}
$configDir = if ($env:VOXRELAY_DATA_DIR) { $env:VOXRELAY_DATA_DIR } else { Join-Path $appRoot 'data' }
$legacyConfigDir = Join-Path $env:LOCALAPPDATA 'VoiceStudioSpeakerBridge'
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    if (Test-Path -LiteralPath (Join-Path $legacyConfigDir 'settings.json')) {
        Copy-Item -LiteralPath (Join-Path $legacyConfigDir 'settings.json') -Destination (Join-Path $configDir 'settings.json')
    }
}
$configPath = Join-Path $configDir 'settings.json'
$logPath = Join-Path $configDir 'bridge.log'
$python = Join-Path $appRoot '.venv\Scripts\python.exe'
$script:backend = $null
$script:profiles = @{}
$script:profileModels = @{}
$script:profileModelOptions = @{}
$script:httpPort = 7582
$script:backendOnline = $false
$script:backendFailUntil = [datetime]::MinValue

function Load-Xaml([string]$path) {
    # Load via XmlReader so UTF-8 markup is not corrupted by PowerShell's [xml] cast.
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($path, $settings)
    try {
        return [Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Dispose()
    }
}
function Set-ControlAccessibility($target) {
    if ($target -is [Windows.Controls.Control]) {
        if ($window) { $target.FocusVisualStyle=$window.TryFindResource('VoxFocusRing') }
        if ($target.Name) {
            [Windows.Automation.AutomationProperties]::SetAutomationId($target,$target.Name)
            if (-not [Windows.Automation.AutomationProperties]::GetName($target)) {
                $label = if ($target -is [Windows.Controls.ContentControl] -and $target.Content -is [string]) { [string]$target.Content } else { ([regex]::Replace($target.Name,'([a-z])([A-Z])','$1 $2') -replace '(Box|Button|Check|Slider)$','').Trim() }
                [Windows.Automation.AutomationProperties]::SetName($target,$label)
            }
        }
    }
    if ($target -is [Windows.DependencyObject]) {
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($target)) { if ($child -is [Windows.DependencyObject]) { Set-ControlAccessibility $child } }
    }
}
function Apply-AppFont($target) {
    $fontFolder = [Uri]::new(((Join-Path $appRoot 'assets') + [IO.Path]::DirectorySeparatorChar))
    $target.FontFamily = [Windows.Media.FontFamily]::new($fontFolder, './#Inter Variable')
    Set-ControlAccessibility $target
    if ($target -is [Windows.Window] -and $target -ne $window) {
        $target.MaxHeight = [Windows.SystemParameters]::WorkArea.Height - 24
        $target.Icon=$window.Icon
        $target.Add_KeyDown({param($sender,$e) if($e.Key -eq 'Escape'){$sender.Close()}})
    }
}
function Ensure-SettingsFile {
    if (Test-Path -LiteralPath $configPath) { return }
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null | Out-Null
    $legacyPath = Join-Path $legacyConfigDir 'settings.json'
    if (Test-Path -LiteralPath $legacyPath) {
        Copy-Item -LiteralPath $legacyPath -Destination $configPath -Force
        return
    }
    # Seed a minimal file so the UI never binds against a missing config.
    @{
        voice_studio_url='http://127.0.0.1:3900'; api_key='local'; request_timeout=120
        polly_enabled=$false; polly_region='us-east-1'; polly_profile=''; polly_access_key_encrypted=''; polly_secret_key_encrypted=''
        ws_address='127.0.0.1'; ws_port=7581; http_address='127.0.0.1'; http_port=7582
        udp_address='0.0.0.0'; udp_port=6670; enable_udp=$true
        streamerbot_playback_delay=0.0; streamerbot_finished_delay=0.0
        max_characters=500; max_queue=25; history_limit=200; minimize_to_tray=$false
        aliases=@{ EventVoice=@{ provider='voicestudio'; voice_id=''; model='tts-1'; speed=1.0; volume=1.0; language=''; instruct=''; group='' } }
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
}
function Read-Settings {
    Ensure-SettingsFile
    try {
        $value=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if($value -isnot [pscustomobject]){throw 'Settings must be an object'}
        return $value
    }
    catch {
        $backup = $configPath + '.bak'
        if (Test-Path -LiteralPath $backup) {
            $restored = Get-Content -LiteralPath $backup -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if($restored -isnot [pscustomobject]){throw 'Backup must be an object'}
            $script:settingsRecovered=$true
            if ($BottomStatus) { $BottomStatus.Text = 'Recovered settings from backup. Save to repair the settings file.' }
            return $restored
        }
        throw 'Settings could not be loaded. Restore a backup from Settings.'
    }
}
function Write-Settings($value) {
    Ensure-SettingsFile
    $temporary = $configPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = $value | ConvertTo-Json -Depth 24
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        $valid = $false
        try { $previous = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json -ErrorAction Stop; $valid = $previous -is [pscustomobject] } catch {}
        $backup = if ($valid) { $configPath + '.bak' } else { $null }
        [IO.File]::Replace($temporary, $configPath, $backup)
        $script:settingsRecovered=$false
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Protect-VoxRelaySecret([string]$value) {
    if ([string]::IsNullOrEmpty($value)) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}
function Get-HttpPort {
    try {
        $s = Read-Settings
        if ($null -ne $s.http_port -and [int]$s.http_port -ge 1) { return [int]$s.http_port }
    } catch {}
    return 7582
}
function Get-BridgeBaseUri {
    return ('http://127.0.0.1:' + $script:httpPort)
}
function Start-Backend {
    if ($env:VSB_EXTERNAL_BACKEND -eq '1') { return }
    if ($script:backend -and -not $script:backend.HasExited) {
        try { $script:backend.Kill() } catch {}
        try { $script:backend.WaitForExit(2000) | Out-Null } catch {}
    }
    # Start-Process -WorkingDirectory treats [brackets] as wildcards and fails on this install path.
    # ProcessStartInfo uses the path literally.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $python
    $psi.Arguments = '-m voice_studio_speaker_bridge --headless'
    $psi.WorkingDirectory = $appRoot
    $psi.UseShellExecute = $true
    $psi.CreateNoWindow = $false
    # .NET Framework uses EnvironmentVariables; .NET (Core) also exposes Environment.
    try { $psi.EnvironmentVariables['PYTHONPATH'] = (Join-Path $appRoot 'src') } catch {}
    try { $psi.Environment['PYTHONPATH'] = (Join-Path $appRoot 'src') } catch {}
    $script:backend = [System.Diagnostics.Process]::Start($psi)
}
function Wait-BackendReady([int]$timeoutMs = 8000) {
    $script:httpPort = Get-HttpPort
    $deadline = [datetime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            Invoke-RestMethod -Uri ((Get-BridgeBaseUri) + '/api/state') -TimeoutSec 1 | Out-Null
            $script:backendOnline = $true
            $script:backendFailUntil = [datetime]::MinValue
            return $true
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    $script:backendOnline = $false
    return $false
}
function Invoke-BridgeGet([string]$path, [int]$timeoutSec = 2) {
    if (-not $script:backendOnline -and [datetime]::UtcNow -lt $script:backendFailUntil) {
        throw 'Bridge offline'
    }
    try {
        $result = Invoke-RestMethod -Uri ((Get-BridgeBaseUri) + $path) -TimeoutSec $timeoutSec
        $script:backendOnline = $true
        $script:backendFailUntil = [datetime]::MinValue
        return $result
    } catch {
        $script:backendOnline = $false
        $script:backendFailUntil = [datetime]::UtcNow.AddSeconds(3)
        throw
    }
}
function Json-Escape([string]$value) {
    if ($null -eq $value) { return '' }
    return $value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n')
}


function Enable-RoundedClip {
    param($Element, [double]$Radius = 11)
    if (-not $Element) { return }
    $Element.Tag = $Radius
    $handler = {
        param($sender, $e)
        $rad = 11.0
        try { if ($null -ne $sender.Tag) { $rad = [double]$sender.Tag } } catch {}
        if ($sender.ActualWidth -le 0 -or $sender.ActualHeight -le 0) { return }
        $sender.Clip = [System.Windows.Media.RectangleGeometry]::new(
            [System.Windows.Rect]::new(0, 0, $sender.ActualWidth, $sender.ActualHeight),
            $rad,
            $rad
        )
    }
    $Element.Add_SizeChanged($handler)
    $Element.Add_Loaded($handler)
    & $handler $Element $null
}

$window = Load-Xaml (Join-Path $appRoot 'VoxRelay.xaml')
$window.MinWidth = [Math]::Min(980,[Windows.SystemParameters]::WorkArea.Width-24)
$window.Width = [Math]::Min(1180,[Windows.SystemParameters]::WorkArea.Width-24)
$window.MinHeight = [Math]::Min(640,[Windows.SystemParameters]::WorkArea.Height-24)
$window.Height = [Math]::Min(760,[Windows.SystemParameters]::WorkArea.Height-24)
$windowIconPath = Join-Path $appRoot 'assets\VoxRelay.ico'
if (Test-Path -LiteralPath $windowIconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($windowIconPath)) } catch {}
}
Apply-AppFont $window
# Keep custom scrollbar thumbs as grab-able pills (Track math otherwise shrinks them to ~width).
[EventManager]::RegisterClassHandler(
    [System.Windows.Controls.Primitives.ScrollBar],
    [System.Windows.FrameworkElement]::LoadedEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        try {
            $bar = [System.Windows.Controls.Primitives.ScrollBar]$sender
            $bar.ApplyTemplate() | Out-Null
            $track = $bar.Template.FindName('PART_Track', $bar)
            if (-not $track -or -not $track.Thumb) { return }
            if ($bar.Orientation -eq [System.Windows.Controls.Orientation]::Vertical) {
                $track.Orientation = [System.Windows.Controls.Orientation]::Vertical
                $track.Thumb.MinHeight = 56
            } else {
                $track.Orientation = [System.Windows.Controls.Orientation]::Horizontal
                $track.Thumb.MinWidth = 56
            }
        } catch {}
    })
$controlNames = @(
 'AppTitleBar','MinimizeButton','MaximizeButton','CloseButton','BridgeStatusButton','RefreshButton','PageTitle','PageSubtitle','SideStatus','BottomStatus',
 'VoicesNav','PlaygroundNav','QueueNav','HistoryNav','RulesNav','PronunciationNav','ServicesToggle','ServicesChevronPath','ServicesNavPanel',
 'StreamerBotNav','VoiceStudioNav','PollyNav','ElevenLabsNav','AzureNav','GoogleNav','WatsonNav','UberDuckNav','TtsMonsterNav','AcapelaNav','CereProcNav','ActivityNav','SettingsNav',
 'VoicesPage','PlaygroundPage','QueuePage','HistoryPage','RulesPage','PronunciationPage','StreamerBotPage','VoiceStudioPage','PollyPage','ElevenLabsPage','AzurePage','GooglePage','WatsonPage','UberDuckPage','TtsMonsterPage','AcapelaPage','CereProcPage','SettingsPage','ActivityPage',
 'AddButton','EditButton','RemoveButton','TestButton','AliasGrid','PlayVoiceList','PlaygroundText','PlaySpeedBox','PlayVolumeBox','PlayStyleBox','CharacterCount','PlayButton','PlayStopButton',
 'QueueGrid','PauseQueueButton','ResumeQueueButton','SkipQueueButton','RemoveQueueButton','QueueUpButton','QueueDownButton','ClearQueueButton',
 'HistoryGrid','ReplayHistoryButton','SaveHistoryAudioButton','ClearHistoryButton','BlockedWordsBox','ReplacementsBox','BlocklistBox','AllowlistBox','VoiceRulesGrid','VoiceRuleFieldBox','VoiceRuleValueBox','VoiceRuleAliasBox','AddVoiceRuleButton','UpdateVoiceRuleButton','RemoveVoiceRuleButton','TestVoiceRuleButton','MaxQueueBox','UserCooldownBox','GlobalCooldownBox','BlockLinksCheck','StripLinksCheck','BlockCapsCheck','CollapseRepeatsCheck','IgnoreCommandsCheck','IgnoreMentionsCheck','StripNonAsciiCheck','StripEmojiCheck','BlockAsciiArtCheck','SaveRulesButton',
 'PronunciationGrid','AddPronunciationButton','EditPronunciationButton','RemovePronunciationButton','PronunciationUpButton','PronunciationDownButton','PronunciationVoiceList','TestPronunciationButton','ActivityList',
 'UrlBox','KeyBox','RequestTimeoutBox','VoiceStudioStatus','SaveVoiceStudioButton','TestVoiceStudioButton',
 'PollyEnabledCheck','PollyRegionBox','PollyProfileBox','PollyAccessKeyBox','PollySecretKeyBox','PollyCredentialStatus','SavePollyButton','TestPollyButton','ClearPollyCredentialsButton',
 'ElevenLabsEnabledCheck','ElevenLabsApiKeyBox','ElevenLabsStatus','AzureEnabledCheck','AzureKeyBox','AzureRegionBox','AzureStatus','GoogleEnabledCheck','GoogleApiKeyBox','GoogleServiceAccountBox','GoogleStatus','WatsonEnabledCheck','WatsonApiKeyBox','WatsonServiceUrlBox','WatsonStatus','UberDuckEnabledCheck','UberDuckApiKeyBox','UberDuckStatus','TtsMonsterEnabledCheck','TtsMonsterOverlayBox','TtsMonsterTokenBox','TtsMonsterStatus','AcapelaEnabledCheck','AcapelaAccountBox','AcapelaPasswordBox','AcapelaAppNameBox','AcapelaStatus','CereProcEnabledCheck','CereProcUsernameBox','CereProcPasswordBox','CereProcStatus',
 'SaveElevenLabsButton','TestElevenLabsButton','ClearElevenLabsButton','SaveAzureButton','TestAzureButton','ClearAzureButton','SaveGoogleButton','TestGoogleButton','ClearGoogleButton','SaveWatsonButton','TestWatsonButton','ClearWatsonButton','SaveUberDuckButton','TestUberDuckButton','ClearUberDuckButton','SaveTtsMonsterButton','TestTtsMonsterButton','ClearTtsMonsterButton','SaveAcapelaButton','TestAcapelaButton','ClearAcapelaButton','SaveCereProcButton','TestCereProcButton','ClearCereProcButton',
 'UdpBox','HttpBox','WsBox','EnableUdpCheck','OutputDeviceBox','PreviewDeviceBox','VoiceSaveFolderBox','BrowseVoiceFolderButton','MaxCharactersSettingBox','MaxQueueSettingBox','HistoryLimitBox','StreamerPayloadBox',
 'EnableStreamerBotActionsCheck','StreamerBotHttpUrlBox','StreamerBotQueuedActionBox','StreamerBotQueueAddedActionBox','StreamerBotPlayingActionBox','StreamerBotFinishedActionBox','StreamerBotPlaybackDelaySlider','StreamerBotPlaybackDelayValue','StreamerBotFinishedDelaySlider','StreamerBotFinishedDelayValue',
 'TestStreamerBotQueuedButton','TestStreamerBotQueueAddedButton','TestStreamerBotPlayingButton','TestStreamerBotFinishedButton','SaveStreamerBotButton','QueueControlCommandBox','QueueControlPayloadBox','QueueControlHint','CopyQueueControlButton','TestQueueControlButton','SaveButton','CopyPayloadButton','TestConnectionButton','MinimizeToTrayCheck','BottomStatusDot'
)
$controlNames | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
$extraControls = @('PauseAfterQueueButton','ClearAllQueueButton','StreamVolumeSlider','PreviewVolumeSlider','NormalizeAudioCheck','FadeAudioCheck','PerUserQueueLimitBox','MessageAgeBox','DuplicateWindowBox','SetupWindowsButton','SetupVoiceStudioButton','SetupPollyButton','SetupElevenLabsButton','SetupAzureButton','SetupGoogleButton','SetupWatsonButton','SetupUberDuckButton','SetupTtsMonsterButton','SetupAcapelaButton','SetupCereProcButton','SetupOutputButton','SetupVoiceButton','SetupStreamerBotButton','BackupSettingsButton','ExportPresetsButton','ImportPresetsButton','ExportDiagnosticsButton','BackupListBox','RestoreBackupButton')
$extraControls | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
@('AliasSearchBox','AliasProviderFilter','FavoritesOnlyCheck','ToggleFavoriteButton','PersistQueueCheck','FinishSetupButton') | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
# Do NOT rounded-clip scrollable hosts — RectangleGeometry clips the scrollbar
# thumb into a "half circle" against the top-right corner. Border.CornerRadius
# still paints the chrome; only the geometry clip was cutting the thumb.
@('AliasGridHost','QueueGridHost','HistoryGridHost') | ForEach-Object {
    $hostBorder = $window.FindName($_)
    if ($hostBorder) {
        $hostBorder.ClipToBounds = $false
        $hostBorder.Clip = $null
    }
}

@('RoutingGrid','RouteFieldBox','RouteValueBox','RouteAliasBox','RoutePrioritySlider','AddRouteButton','UpdateRouteButton','RemoveRouteButton','RouteUpButton','RouteDownButton','EventTimelineGrid') | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
$PollySessionTokenBox = $window.FindName('PollySessionTokenBox')
$MigrateSpeakerBotButton = $window.FindName('MigrateSpeakerBotButton')
$TestStreamOutputButton=$window.FindName('TestStreamOutputButton');$TestPreviewOutputButton=$window.FindName('TestPreviewOutputButton')
$CheckUpdatesButton=$window.FindName('CheckUpdatesButton');$ResetSettingsButton=$window.FindName('ResetSettingsButton')
$CheckUpdatesOnStartupCheck=$window.FindName('CheckUpdatesOnStartupCheck')
@('ObsDuckingCheck','ObsUrlBox','ObsPasswordBox','ObsInputBox','ObsDuckVolumeSlider','TestObsButton') | ForEach-Object {Set-Variable -Name $_ -Value $window.FindName($_)}
@('ProfilePresetBox','SaveProfileButton','LoadProfileButton') | ForEach-Object {Set-Variable -Name $_ -Value $window.FindName($_)}
$QueueSummaryText=$window.FindName('QueueSummaryText')
$WindowsVoicesCheck=$window.FindName('WindowsVoicesCheck')
$PlaySsmlCheck=$window.FindName('PlaySsmlCheck')
$EventTestBox=$window.FindName('EventTestBox');$SimulateEventButton=$window.FindName('SimulateEventButton')
$ExportVoiceAliasBox=$window.FindName('ExportVoiceAliasBox');$ExportStreamerBotButton=$window.FindName('ExportStreamerBotButton')
$SavePageButton=$window.FindName('SavePageButton')
$script:streamerExtraControls=@{received=$window.FindName('StreamerReceivedActionBox');generating=$window.FindName('StreamerGeneratingActionBox');generated=$window.FindName('StreamerGeneratedActionBox');error=$window.FindName('StreamerErrorActionBox');cancelled=$window.FindName('StreamerCancelledActionBox')}
$script:servicesExpanded = $true
$script:minimizeToTray = $false
$script:allowClose = $false
$script:loadingSettings = $false
$script:trayIcon = $null
$script:trayOwnedIcon = $null
$script:trayBitmap = $null
$script:trayHost = $null
$script:hiddenInTray = $false
$script:allowHideToTray = $false

function Animate-In($element) {
    $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $element.Opacity = 1
}

function Set-ServicesExpanded([bool]$expanded) {
    $script:servicesExpanded = $expanded
    $ServicesNavPanel.Visibility = if ($expanded) { 'Visible' } else { 'Collapsed' }
    # Geometry chevron avoids Unicode encoding issues in the nav label.
    $ServicesChevronPath.Data = [Windows.Media.Geometry]::Parse($(if ($expanded) { 'M3,5 L13,5 L8,11 Z' } else { 'M5,3 L11,8 L5,13 Z' }))
}

function Update-BridgeStatus([bool]$online) {
    $script:backendOnline = [bool]$online
    $brush = [Windows.Media.BrushConverter]::new()
    $ok = $brush.ConvertFromString('#58DDA8')
    $bad = $brush.ConvertFromString('#FF7B72')
    if ($online) {
        $SideStatus.Text = 'Connected'
        $SideStatus.Foreground = $ok
        if ($BottomStatusDot) { $BottomStatusDot.Fill = $ok }
    } else {
        $SideStatus.Text = 'Offline'
        $SideStatus.Foreground = $bad
        if ($BottomStatusDot) { $BottomStatusDot.Fill = $bad }
    }
}

function Set-Page([string]$page) {
    $SavePageButton.Visibility=if($page -in @('settings','rules','streamerbot','voicestudio','polly','elevenlabs','azure','google','watson','uberduck','ttsmonster','acapela','cereproc')){'Visible'}else{'Collapsed'}
    $SavePageButton.Tag=$page
    $pages = @{
        voices=$VoicesPage; playground=$PlaygroundPage; queue=$QueuePage; history=$HistoryPage; rules=$RulesPage; pronunciation=$PronunciationPage;
        streamerbot=$StreamerBotPage; voicestudio=$VoiceStudioPage; polly=$PollyPage; elevenlabs=$ElevenLabsPage; azure=$AzurePage; google=$GooglePage; watson=$WatsonPage; uberduck=$UberDuckPage; ttsmonster=$TtsMonsterPage; acapela=$AcapelaPage; cereproc=$CereProcPage; settings=$SettingsPage; activity=$ActivityPage
    }
    foreach ($key in $pages.Keys) { $pages[$key].Visibility = if ($key -eq $page) {'Visible'} else {'Collapsed'} }
    $mainNav = @{voices=$VoicesNav;playground=$PlaygroundNav;queue=$QueueNav;history=$HistoryNav;rules=$RulesNav;pronunciation=$PronunciationNav;activity=$ActivityNav;settings=$SettingsNav}
    foreach ($key in $mainNav.Keys) { $mainNav[$key].Style = $window.FindResource($(if($key -eq $page){'SelectedNavButton'}else{'NavButton'})) }
    $serviceNav = @{streamerbot=$StreamerBotNav;voicestudio=$VoiceStudioNav;polly=$PollyNav; elevenlabs=$ElevenLabsNav; azure=$AzureNav; google=$GoogleNav; watson=$WatsonNav; uberduck=$UberDuckNav; ttsmonster=$TtsMonsterNav; acapela=$AcapelaNav; cereproc=$CereProcNav}
    foreach ($key in $serviceNav.Keys) { $serviceNav[$key].Style = $window.FindResource($(if($key -eq $page){'SelectedSubNavButton'}else{'SubNavButton'})) }
    if ($page -in @('streamerbot','voicestudio','polly','elevenlabs','azure','google','watson','uberduck','ttsmonster','acapela','cereproc')) { Set-ServicesExpanded $true }
    $titles = @{
        voices=@('Voices','Aliases and voice profiles'); playground=@('Playground','Try a line before it hits chat');
        queue=@('Queue','What is waiting to speak'); history=@('History','Recent speech jobs');
        rules=@('Rules','Filters, replacements, and cooldowns'); pronunciation=@('Pronunciation','Custom spoken forms');
        streamerbot=@('Streamer.bot','UDP, actions, and lifecycle hooks'); voicestudio=@('VoiceStudio','Local TTS connection');
        polly=@('Amazon Polly','Cloud voices'); elevenlabs=@('ElevenLabs','Cloud TTS credentials'); azure=@('Azure Speech','Cloud TTS credentials'); google=@('Google Cloud TTS','Cloud TTS credentials'); watson=@('IBM Watson','Cloud TTS credentials'); uberduck=@('UberDuck','Cloud TTS credentials'); ttsmonster=@('TTS.Monster','Cloud TTS credentials'); acapela=@('Acapela','Cloud TTS credentials'); cereproc=@('CereProc','Cloud TTS credentials'); settings=@('Settings','Ports, devices, and tray');
        activity=@('Activity','Speech events and application log')
    }
    if ($titles.ContainsKey($page)) { $PageTitle.Text = $titles[$page][0]; $PageSubtitle.Text = $titles[$page][1] }
    if ($page -eq 'activity') { Refresh-Activity }
    if ($page -in @('queue','history')) { Refresh-ServiceState }
    Animate-In $pages[$page]
}

function Get-PollyRegionText {
    $item = $PollyRegionBox.SelectedItem
    if ($item -is [Windows.Controls.ComboBoxItem]) { return [string]$item.Content }
    if ($PollyRegionBox.Text) { return [string]$PollyRegionBox.Text }
    return 'us-east-1'
}
function Set-PollyRegionText([string]$region) {
    if ([string]::IsNullOrWhiteSpace($region)) { $region = 'us-east-1' }
    $PollyRegionBox.Text = $region
    foreach ($item in $PollyRegionBox.Items) {
        $value = if ($item -is [Windows.Controls.ComboBoxItem]) { [string]$item.Content } else { [string]$item }
        if ($value -eq $region) { $PollyRegionBox.SelectedItem = $item; break }
    }
}

function ConvertTo-MappingText($object) {
    if ($null -eq $object) { return '' }
    return (($object.PSObject.Properties | ForEach-Object { $_.Name + ' => ' + [string]$_.Value }) -join "`r`n")
}
function ConvertFrom-MappingText([string]$text) {
    $result = [ordered]@{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim() -and $line.Contains('=>')) {
            $parts = $line.Split(@('=>'), 2, [System.StringSplitOptions]::None)
            $key = $parts[0].Trim()
            if ($key) { $result[$key] = $parts[1].Trim() }
        }
    }
    return [pscustomobject]$result
}
function ConvertFrom-Lines([string]$text) {
    # Always return a real string[] (including empty). Write-Output -NoEnumerate on an
    # empty [string[]] makes ConvertTo-Json emit {"value":[],"Count":0}, which Python
    # then treats as allowlist entries "value"/"Count" and rejects every real user.
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed) { [void]$list.Add($trimmed) }
    }
    return ,([string[]]$list.ToArray())
}
function Get-RandomPronunciation([string]$spoken) {
    $parts = @($spoken -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $parts.Count) { return '' }
    return Get-Random -InputObject $parts
}
function Set-JsonProperty($object, [string]$name, $value) {
    if ($object.PSObject.Properties[$name]) { $object.$name = $value }
    else { $object | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}

function Refresh-Grid([switch]$VoicesOnly) {
    $selectedAliasName=if($AliasGrid.SelectedItem){[string]$AliasGrid.SelectedItem.Name}else{''}
    $selectedEngine=[string]$AliasProviderFilter.SelectedItem
    $selectedPlayVoice=[string]$PlayVoiceList.SelectedItem
    $selectedPronunciationVoice=[string]$PronunciationVoiceList.SelectedItem
    $settings = Read-Settings
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($property in $settings.aliases.PSObject.Properties) {
        $a = $property.Value
        $provider = if ($a.provider) { [string]$a.provider } else { 'voicestudio' }
        $key = $provider + '|' + [string]$a.voice_id
        if ($script:profiles.ContainsKey($key)) {
            $pr = $script:profiles[$key]
            if ($pr -is [string]) { $profile = $pr }
            else {
                $bits = New-Object System.Collections.Generic.List[string]
                if ($pr.Name) { [void]$bits.Add([string]$pr.Name) }
                if ($pr.Language) { [void]$bits.Add([string]$pr.Language) }
                if ($pr.Engine) { [void]$bits.Add([string]$pr.Engine) }
                $profile = ($bits -join (' ' + [char]0x00B7 + ' '))
            }
        } else { $profile = [string]$a.voice_id }
        $rows.Add([pscustomobject]@{ Name=$property.Name; Provider=$provider; Profile=$profile; Group=[string]$a.group; Model=$a.model; Speed=$a.speed; VoiceId=$a.voice_id; Volume=$a.volume; Language=$a.language; Instruct=$a.instruct; OutputDevice=[string]$a.output_device; Favorite=[bool]$a.favorite })
    }
    $AliasGrid.ItemsSource = $rows
    $AliasProviderFilter.Items.Clear()
    [void]$AliasProviderFilter.Items.Add('All engines')
    foreach ($providerName in @($rows.Provider | Sort-Object -Unique)) { [void]$AliasProviderFilter.Items.Add($providerName) }
    $AliasProviderFilter.SelectedIndex = 0
    if($selectedEngine -and $AliasProviderFilter.Items.Contains($selectedEngine)){$AliasProviderFilter.SelectedItem=$selectedEngine}
    Filter-VoiceAliases
    if($selectedAliasName){$AliasGrid.SelectedItem=@($rows | Where-Object {$_.Name -eq $selectedAliasName})[0]}
    $PlayVoiceList.Items.Clear(); $PronunciationVoiceList.Items.Clear()
    foreach ($row in $rows) { [void]$PlayVoiceList.Items.Add($row.Name); [void]$PronunciationVoiceList.Items.Add($row.Name) }
    if($PlayVoiceList.Items.Contains($selectedPlayVoice)){$PlayVoiceList.SelectedItem=$selectedPlayVoice}
    if($PronunciationVoiceList.Items.Contains($selectedPronunciationVoice)){$PronunciationVoiceList.SelectedItem=$selectedPronunciationVoice}
    if ($PlayVoiceList.Items.Count -and $PlayVoiceList.SelectedIndex -lt 0) { $PlayVoiceList.SelectedIndex = 0 }
    if ($PronunciationVoiceList.Items.Count -and $PronunciationVoiceList.SelectedIndex -lt 0) { $PronunciationVoiceList.SelectedIndex = 0 }
    $RouteAliasBox.ItemsSource = @($rows.Name)
    $VoiceRuleAliasBox.ItemsSource = @($rows.Name)
    $exportAlias=[string]$ExportVoiceAliasBox.SelectedItem
    $ExportVoiceAliasBox.ItemsSource=@($rows.Name)
    if($exportAlias){$ExportVoiceAliasBox.SelectedItem=$exportAlias}
    if($ExportVoiceAliasBox.SelectedIndex -lt 0){$ExportVoiceAliasBox.SelectedIndex=0}
    if ($VoicesOnly) { return }
    $routingRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($rule in @($settings.routing_rules)) { if ($rule) { $routingRows.Add($rule) } }
    $RoutingGrid.ItemsSource = $routingRows
    $RouteFieldBox.SelectedIndex = 0
    $UrlBox.Text = [string]$settings.voice_studio_url
    $KeyBox.Text = [string]$settings.api_key
    $RequestTimeoutBox.Text = [string]$(if ($null -ne $settings.request_timeout) { $settings.request_timeout } else { 120 })
    $PollyEnabledCheck.IsChecked = [bool]$settings.polly_enabled
    $WindowsVoicesCheck.IsChecked = $null -eq $settings.windows_voices_enabled -or [bool]$settings.windows_voices_enabled

    $ElevenLabsEnabledCheck.IsChecked = [bool]$settings.elevenlabs_enabled
    $ElevenLabsApiKeyBox.Password = ''
    $ElevenLabsStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$settings.elevenlabs_api_key_encrypted)) { 'No key saved yet' } else { 'API key saved securely for this Windows account' }
    $AzureEnabledCheck.IsChecked = [bool]$settings.azure_enabled
    $AzureKeyBox.Password = ''
    $AzureRegionBox.Text = [string]$(if ($settings.azure_region) { $settings.azure_region } else { 'eastus' })
    $AzureStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$settings.azure_subscription_key_encrypted)) { 'No key saved yet' } else { 'Subscription key saved securely for this Windows account' }
    $GoogleEnabledCheck.IsChecked = [bool]$settings.google_enabled
    $GoogleApiKeyBox.Password = ''
    $GoogleServiceAccountBox.Text = [string]$settings.google_service_account_path
    $GoogleStatus.Text = if (-not [string]::IsNullOrWhiteSpace([string]$settings.google_api_key_encrypted)) { 'API key saved securely for this Windows account' } elseif ($settings.google_service_account_path) { 'Using service-account JSON path' } else { 'No credentials saved yet' }
    $WatsonEnabledCheck.IsChecked = [bool]$settings.watson_enabled
    $WatsonApiKeyBox.Password = ''
    $WatsonServiceUrlBox.Text = [string]$settings.watson_service_url
    $WatsonStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$settings.watson_api_key_encrypted)) { 'No key saved yet' } else { 'API key saved securely for this Windows account' }
    $UberDuckEnabledCheck.IsChecked = [bool]$settings.uberduck_enabled
    $UberDuckApiKeyBox.Password = ''
    $UberDuckStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$settings.uberduck_api_key_encrypted)) { 'No key saved yet' } else { 'API key saved securely for this Windows account' }
    $TtsMonsterEnabledCheck.IsChecked = [bool]$settings.ttsmonster_enabled
    $TtsMonsterOverlayBox.Text = [string]$settings.ttsmonster_overlay_url
    $TtsMonsterTokenBox.Password = ''
    $TtsMonsterStatus.Text = if (-not [string]::IsNullOrWhiteSpace([string]$settings.ttsmonster_api_token_encrypted)) { 'API token saved securely for this Windows account' } elseif ($settings.ttsmonster_overlay_url) { 'Using overlay URL' } else { 'No credentials saved yet' }
    $AcapelaEnabledCheck.IsChecked = [bool]$settings.acapela_enabled
    $AcapelaAccountBox.Text = [string]$settings.acapela_account
    $AcapelaPasswordBox.Password = ''
    $AcapelaAppNameBox.Text = [string]$(if ($settings.acapela_application_name) { $settings.acapela_application_name } else { 'VoxRelay' })
    $AcapelaStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$settings.acapela_password_encrypted)) { 'No password saved yet' } else { 'Password saved securely for this Windows account' }
    $CereProcEnabledCheck.IsChecked = [bool]$settings.cereproc_enabled
    $CereProcUsernameBox.Text = [string]$settings.cereproc_username
    $CereProcPasswordBox.Password = ''
    $CereProcStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$settings.cereproc_password_encrypted)) { 'No password saved yet' } else { 'Password saved securely for this Windows account' }

    Set-PollyRegionText ([string]$(if ($settings.polly_region) { $settings.polly_region } else { 'us-east-1' }))
    $PollyProfileBox.Text = [string]$settings.polly_profile
    $PollyAccessKeyBox.Password = ''
    $PollySecretKeyBox.Password = ''
    $hasPollyKeys = -not [string]::IsNullOrWhiteSpace([string]$settings.polly_access_key_encrypted) -and -not [string]::IsNullOrWhiteSpace([string]$settings.polly_secret_key_encrypted)
    $PollyCredentialStatus.Text = if ($hasPollyKeys) { 'Credentials saved securely for this Windows account' } elseif ($settings.polly_profile) { 'Using the AWS profile shown below' } else { 'No credentials saved yet' }
    $UdpBox.Text = [string]$settings.udp_port
    $HttpBox.Text = [string]$settings.http_port
    $WsBox.Text = [string]$settings.ws_port
    $EnableUdpCheck.IsChecked = if ($null -eq $settings.enable_udp) { $true } else { [bool]$settings.enable_udp }
    $VoiceSaveFolderBox.Text = [string]$settings.voice_save_folder
    $MaxCharactersSettingBox.Text = [string]$(if ($null -ne $settings.max_characters) { $settings.max_characters } else { 500 })
    $MaxQueueSettingBox.Text = [string]$(if ($null -ne $settings.max_queue) { $settings.max_queue } else { 25 })
    $HistoryLimitBox.Text = [string]$(if ($null -ne $settings.history_limit) { $settings.history_limit } else { 200 })
    $StreamVolumeSlider.Value = if ($null -ne $settings.stream_volume) { [double]$settings.stream_volume } else { 1 }
    $PreviewVolumeSlider.Value = if ($null -ne $settings.preview_volume) { [double]$settings.preview_volume } else { 1 }
    $NormalizeAudioCheck.IsChecked = [bool]$settings.normalize_audio
    $FadeAudioCheck.IsChecked = [bool]$settings.fade_audio
    $PersistQueueCheck.IsChecked = [bool]$settings.persist_queue
    $CheckUpdatesOnStartupCheck.IsChecked = [bool]$settings.check_updates_on_startup
    $ObsDuckingCheck.IsChecked = [bool]$settings.obs_ducking_enabled
    $ObsUrlBox.Text = if($settings.obs_url){[string]$settings.obs_url}else{'ws://127.0.0.1:4455'}
    $ObsInputBox.Text = [string]$settings.obs_input
    $ObsPasswordBox.Password=''
    $ObsDuckVolumeSlider.Value = if($null -ne $settings.obs_duck_volume){[double]$settings.obs_duck_volume}else{0.25}
    $PerUserQueueLimitBox.Text = [string]$(if ($settings.per_user_queue_limit) { $settings.per_user_queue_limit } else { 0 })
    $MessageAgeBox.Text = [string]$(if ($settings.max_message_age) { $settings.max_message_age } else { 0 })
    $DuplicateWindowBox.Text = [string]$(if ($settings.duplicate_window) { $settings.duplicate_window } else { 0 })
    $EnableStreamerBotActionsCheck.IsChecked = [bool]$settings.streamerbot_actions_enabled
    $StreamerBotHttpUrlBox.Text = [string]$(if ($settings.streamerbot_http_url) { $settings.streamerbot_http_url } else { 'http://127.0.0.1:7474' })
    $StreamerBotQueuedActionBox.Text = [string]$settings.streamerbot_queued_action
    $StreamerBotQueueAddedActionBox.Text = [string]$settings.streamerbot_queue_added_action
    $StreamerBotPlayingActionBox.Text = [string]$settings.streamerbot_playing_action
    $StreamerBotFinishedActionBox.Text = [string]$settings.streamerbot_finished_action
    foreach($state in $script:streamerExtraControls.Keys){$script:streamerExtraControls[$state].Text=[string]$settings.('streamerbot_'+$state+'_action')}
    $StreamerBotPlaybackDelaySlider.Value = [double]$(if ($null -ne $settings.streamerbot_playback_delay) { $settings.streamerbot_playback_delay } else { 0 })
    $StreamerBotPlaybackDelayValue.Text = ('{0:0.00} s' -f $StreamerBotPlaybackDelaySlider.Value)
    $StreamerBotFinishedDelaySlider.Value = [double]$(if ($null -ne $settings.streamerbot_finished_delay) { $settings.streamerbot_finished_delay } else { 0 })
    $StreamerBotFinishedDelayValue.Text = ('{0:0.00} s' -f $StreamerBotFinishedDelaySlider.Value)
    $BlockedWordsBox.Text = (@($settings.blocked_words) -join "`r`n")
    $BlocklistBox.Text = (@($settings.user_blocklist) -join "`r`n")
    $AllowlistBox.Text = (@($settings.user_allowlist) -join "`r`n")
    $ReplacementsBox.Text = ConvertTo-MappingText $settings.replacements
    $voiceRuleRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    if ($settings.user_voice_rules) {
        foreach ($entry in $settings.user_voice_rules.PSObject.Properties) {
            $voiceRuleRows.Add([pscustomobject]@{ field='user'; value=[string]$entry.Name; alias=[string]$entry.Value })
        }
    }
    if ($settings.role_voice_rules) {
        foreach ($entry in $settings.role_voice_rules.PSObject.Properties) {
            $voiceRuleRows.Add([pscustomobject]@{ field='role'; value=[string]$entry.Name; alias=[string]$entry.Value })
        }
    }
    $VoiceRulesGrid.ItemsSource = $voiceRuleRows
    if ($VoiceRuleFieldBox.SelectedIndex -lt 0) { $VoiceRuleFieldBox.SelectedIndex = 0 }
    $pronunciations = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $hidden = @($settings.hidden_pronunciations)
    if ($settings.pronunciations) {
        foreach ($entry in $settings.pronunciations.PSObject.Properties) {
            $isHidden = $hidden -contains $entry.Name
            $display = if ($isHidden) { '*' * [Math]::Max(4, $entry.Name.Length) } else { $entry.Name }
            $pronunciations.Add([pscustomobject]@{ Written=$entry.Name; DisplayWritten=$display; Spoken=[string]$entry.Value; Hidden=$isHidden })
        }
    }
    $PronunciationGrid.ItemsSource = $pronunciations
    $MaxQueueBox.Text = [string]$(if ($null -ne $settings.max_queue) { $settings.max_queue } else { 25 })
    $UserCooldownBox.Text = [string]$(if ($null -ne $settings.per_user_cooldown) { $settings.per_user_cooldown } else { 0 })
    $GlobalCooldownBox.Text = [string]$(if ($null -ne $settings.global_cooldown) { $settings.global_cooldown } else { 0 })
    $BlockLinksCheck.IsChecked = [bool]$settings.block_links
    $StripLinksCheck.IsChecked = [bool]$settings.strip_links
    $BlockCapsCheck.IsChecked = [bool]$settings.block_excess_caps
    $CollapseRepeatsCheck.IsChecked = if ($null -eq $settings.collapse_repeated_characters) { $true } else { [bool]$settings.collapse_repeated_characters }
    $IgnoreCommandsCheck.IsChecked = [bool]$settings.ignore_command_messages
    $IgnoreMentionsCheck.IsChecked = [bool]$settings.ignore_mention_messages
    $StripNonAsciiCheck.IsChecked = [bool]$settings.strip_non_ascii
    $StripEmojiCheck.IsChecked = [bool]$settings.strip_emojis
    $BlockAsciiArtCheck.IsChecked = [bool]$settings.block_ascii_art
    $script:loadingSettings = $true
    $script:minimizeToTray = [bool]$settings.minimize_to_tray
    $MinimizeToTrayCheck.IsChecked = $script:minimizeToTray
    $script:loadingSettings = $false
}

function Refresh-Voices {
    if ($script:voiceRefreshTask -and -not $script:voiceRefreshTask.IsCompleted) { return }
    $BottomStatus.Text = 'Loading voices...'
    $RefreshButton.IsEnabled = $false
    $script:voiceWebClient = [Net.WebClient]::new()
    $script:voiceRefreshTask = $script:voiceWebClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri) + '/api/voices'))
    $script:voiceRefreshTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:voiceRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:voiceRefreshTimer.Add_Tick({
        if (-not $script:voiceRefreshTask.IsCompleted) { return }
        $script:voiceRefreshTimer.Stop()
        try {
            $result = $script:voiceRefreshTask.GetAwaiter().GetResult() | ConvertFrom-Json
            Complete-VoiceRefresh $result
        } catch { $BottomStatus.Text = 'Could not load voices. Check Services and try again.' }
        finally { $script:voiceWebClient.Dispose(); $RefreshButton.IsEnabled = $true }
    })
    $script:voiceRefreshTimer.Start()
}
function Complete-VoiceRefresh($result) {
    try {
        $s = Read-Settings
        $voices = @($result.voices)
        $script:profiles = @{}; $script:profileModels = @{}; $script:profileModelOptions = @{}
        foreach ($v in $voices) {
            $provider = [string]$v.provider; $id = [string]$v.voice_id; $key = $provider + '|' + $id
            $source = switch($provider){'polly'{'Amazon Polly'}'windows'{'Windows voices'}'elevenlabs'{'ElevenLabs'}'azure'{'Azure Speech'}'google'{'Google Cloud TTS'}'watson'{'IBM Watson'}'uberduck'{'UberDuck'}'ttsmonster'{'TTS.Monster'}'acapela'{'Acapela'}'cereproc'{'CereProc'}default{'VoiceStudio'}}
            $languageName = [string]$v.language_name
            $script:profiles[$key] = [pscustomobject]@{
                Key = $key
                Name = [string]$v.name
                Language = $languageName
                Engine = $source
                SearchText = (([string]$v.name) + ' ' + $languageName + ' ' + $source + ' ' + $key)
            }
            $script:profileModels[$key] = [string]$v.model
            $script:profileModelOptions[$key] = if(@($v.engines).Count -and $v.engines){@($v.engines)}else{@([string]$v.model)}
        }
        $OutputDeviceBox.Items.Clear(); $PreviewDeviceBox.Items.Clear()
        [void]$OutputDeviceBox.Items.Add('[Default]')
        [void]$PreviewDeviceBox.Items.Add('[Same as stream output]')
        [void]$PreviewDeviceBox.Items.Add('[Default]')
        try {
            $deviceResult = Invoke-BridgeGet '/api/devices' 3
            foreach ($device in @($deviceResult.devices | Sort-Object -Unique)) {
                [void]$OutputDeviceBox.Items.Add([string]$device)
                [void]$PreviewDeviceBox.Items.Add([string]$device)
            }
        } catch {}
        $selectedDevice = if ([string]::IsNullOrWhiteSpace([string]$s.output_device)) { '[Default]' } else { [string]$s.output_device }
        if(-not$OutputDeviceBox.Items.Contains($selectedDevice)){[void]$OutputDeviceBox.Items.Add($selectedDevice)}
        $OutputDeviceBox.SelectedItem = $selectedDevice
        if ($OutputDeviceBox.SelectedIndex -lt 0) { $OutputDeviceBox.SelectedIndex = 0 }
        $selectedPreview = if ([string]::IsNullOrWhiteSpace([string]$s.preview_output_device)) { '[Same as stream output]' } else { [string]$s.preview_output_device }
        if(-not$PreviewDeviceBox.Items.Contains($selectedPreview)){[void]$PreviewDeviceBox.Items.Add($selectedPreview)}
        $PreviewDeviceBox.SelectedItem = $selectedPreview
        if ($PreviewDeviceBox.SelectedIndex -lt 0) { $PreviewDeviceBox.SelectedIndex = 0 }
        Update-BridgeStatus $true
        $message = ($script:profiles.Count.ToString() + ' voices found')
        if (@($result.errors).Count) { $message += '; ' + (@($result.errors) -join ' | ') }
        if($script:settingsRecovered){$message += '; Settings recovered from backup. Save to repair.'}
        $BottomStatus.Text = $message
        Refresh-Grid -VoicesOnly
        if($script:setupWindowsPending){$script:setupWindowsPending=$false;Create-WindowsDefaultAlias}
    } catch {
        Update-BridgeStatus $false
        $BottomStatus.Text = 'Bridge offline. Restart VoxRelay if this persists.'
    }
}
function Refresh-Activity {
    try {
        $timeline = (Invoke-BridgeGet '/api/events' 1).events
        $signature = @($timeline | ForEach-Object { $_.time + $_.event }) -join '|'
        if ($signature -ne $script:lastEventSignature) {
            $EventTimelineGrid.ItemsSource = @($timeline | ForEach-Object { [pscustomobject]@{Time=([datetime]$_.time).ToLocalTime().ToString('HH:mm:ss');Event=$_.source+'.'+$_.event;Alias=$(if($_.data.alias){$_.data.alias}else{$_.data.integration});Id=$_.data.id} })
            $script:lastEventSignature = $signature
        }
    } catch {}
    $ActivityList.Items.Clear()
    if (Test-Path -LiteralPath $logPath) {
        Get-Content -LiteralPath $logPath -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { [void]$ActivityList.Items.Add($_) }
    }
}
function Refresh-ServiceState {
    if ($script:queueDragging -or [Windows.Input.Mouse]::LeftButton -eq 'Pressed') { return }
    if (-not $script:backendOnline -and [datetime]::UtcNow -lt $script:backendFailUntil) { return }
    try {
        $selectedQueueId = if ($QueueGrid.SelectedItem) { [string]$QueueGrid.SelectedItem.Id } else { '' }
        $selectedHistoryId = if ($HistoryGrid.SelectedItem) { [string]$HistoryGrid.SelectedItem.Id } else { '' }
        $state = (Invoke-BridgeGet '/api/state' 1).result
        $QueueSummaryText.Text = ('{0} waiting / approx. {1:0}s' -f $state.queueLength,$state.estimatedWaitSeconds) + $(if($state.paused){' / Paused'}else{''})
        $queueRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        if ($state.current) { $queueRows.Add([pscustomobject]@{ Id=$state.current.id; Status=$state.current.status; Alias=$state.current.alias; User=$state.current.user; Text=$state.current.text }) }
        foreach ($item in @($state.queue)) { $queueRows.Add([pscustomobject]@{ Id=$item.id; Status=$item.status; Alias=$item.alias; User=$item.user; Text=$item.text }) }
        $queueSignature = $queueRows | ConvertTo-Json -Depth 5 -Compress
        if ($queueSignature -ne $script:lastQueueSignature) {
            $QueueGrid.ItemsSource = $queueRows
            if ($selectedQueueId) { $QueueGrid.SelectedItem = @($queueRows | Where-Object { $_.Id -eq $selectedQueueId })[0] }
            $script:lastQueueSignature = $queueSignature
        }
        if ($state.audioWarning) { $BottomStatus.Text = [string]$state.audioWarning }
        $history = (Invoke-BridgeGet '/api/history' 1).result.history
        $historyRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        foreach ($item in @($history)) {
            $time = ''
            try { $time = ([datetime]$item.timestamp).ToLocalTime().ToString('g') } catch { $time = [string]$item.timestamp }
            $historyRows.Add([pscustomobject]@{ Id=$item.id; Time=$time; Status=$item.status; Alias=$item.alias; Source=$item.source; User=$item.user; Text=$item.text; AudioPath=$item.audioPath })
        }
        $historySignature = $historyRows | ConvertTo-Json -Depth 5 -Compress
        if ($historySignature -ne $script:lastHistorySignature) {
            $HistoryGrid.ItemsSource = $historyRows
            if ($selectedHistoryId) { $HistoryGrid.SelectedItem = @($historyRows | Where-Object { $_.Id -eq $selectedHistoryId })[0] }
            $script:lastHistorySignature = $historySignature
        }
    } catch {}
}

function Invoke-BridgePost([string]$path, $body = @{}) {
    if (-not $script:backendOnline -and [datetime]::UtcNow -lt $script:backendFailUntil) { throw 'Bridge offline' }
    try {
        $json = $body | ConvertTo-Json -Depth 8 -Compress
        $result = Invoke-RestMethod -Method Post -Uri ((Get-BridgeBaseUri) + $path) -ContentType 'application/json' -Body $json -TimeoutSec 8
        $script:backendOnline = $true
        $script:backendFailUntil = [datetime]::MinValue
        return $result
    } catch {
        if ($_.Exception.Response) {
            $script:backendOnline = $true
            $detail=$null
            try { $detail=$_.ErrorDetails.Message | ConvertFrom-Json } catch {}
            if ($detail.error) { throw [string]$detail.error }
        } else {
            $script:backendOnline = $false
            $script:backendFailUntil = [datetime]::UtcNow.AddSeconds(3)
        }
        throw
    }
}
function Speak-Text([string]$alias, [string]$text, [string]$source = 'Playground') {
    if (-not $alias -or -not $text.Trim()) { return }
    try {
        Invoke-BridgePost '/speak' @{ voice = $alias; message = $text; source = $source } | Out-Null
        $BottomStatus.Text = 'Speech queued for ' + $alias
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function Save-Alias($oldName, $value) {
    $s = Read-Settings
    if ($value.Name -match '[\r\n]' -or $value.Name.StartsWith('group:',[StringComparison]::OrdinalIgnoreCase)) {
        $BottomStatus.Text='Use a single-line alias name that does not begin with group:.'
        return
    }
    if ($value.Name -ne $oldName -and $s.aliases.PSObject.Properties.Name -contains $value.Name) {
        $BottomStatus.Text = 'An alias with that name already exists. Choose another name.'
        return
    }
    $favorite = if ($oldName) { [bool]$s.aliases.$oldName.favorite } else { $false }
    if ($oldName -and $oldName -ne $value.Name) { $s.aliases.PSObject.Properties.Remove($oldName) }
    $alias = [pscustomobject]@{
        provider = $value.Provider; voice_id = $value.VoiceId; model = $value.Model; speed = [double]$value.Speed
        volume = [double]$value.Volume; language = [string]$value.Language; instruct = [string]$value.Instruct; group = [string]$value.Group
        output_device = [string]$value.OutputDevice; favorite = $favorite
    }
    Set-JsonProperty $s.aliases $value.Name $alias
    Write-Settings $s
    Refresh-Grid -VoicesOnly
}
function Save-Rules {
    try {
        $s = Read-Settings
        Set-JsonProperty $s 'blocked_words' (ConvertFrom-Lines $BlockedWordsBox.Text)
        Set-JsonProperty $s 'user_blocklist' (ConvertFrom-Lines $BlocklistBox.Text)
        Set-JsonProperty $s 'user_allowlist' (ConvertFrom-Lines $AllowlistBox.Text)
        Set-JsonProperty $s 'replacements' (ConvertFrom-MappingText $ReplacementsBox.Text)
        $userVoiceMap = [ordered]@{}
        $roleVoiceMap = [ordered]@{}
        foreach ($row in @($VoiceRulesGrid.ItemsSource)) {
            if (-not $row) { continue }
            $match = [string]$row.value
            $alias = [string]$row.alias
            if (-not $match.Trim() -or -not $alias.Trim()) { continue }
            if ([string]$row.field -eq 'role') { $roleVoiceMap[$match.Trim()] = $alias.Trim() }
            else { $userVoiceMap[$match.Trim()] = $alias.Trim() }
        }
        Set-JsonProperty $s 'user_voice_rules' ([pscustomobject]$userVoiceMap)
        Set-JsonProperty $s 'role_voice_rules' ([pscustomobject]$roleVoiceMap)
        Set-JsonProperty $s 'routing_rules' @($RoutingGrid.ItemsSource)
        Set-JsonProperty $s 'max_queue' ([int]$MaxQueueBox.Text)
        Set-JsonProperty $s 'per_user_cooldown' ([double]$UserCooldownBox.Text)
        Set-JsonProperty $s 'global_cooldown' ([double]$GlobalCooldownBox.Text)
        Set-JsonProperty $s 'block_links' ([bool]$BlockLinksCheck.IsChecked)
        Set-JsonProperty $s 'strip_links' ([bool]$StripLinksCheck.IsChecked)
        Set-JsonProperty $s 'block_excess_caps' ([bool]$BlockCapsCheck.IsChecked)
        Set-JsonProperty $s 'collapse_repeated_characters' ([bool]$CollapseRepeatsCheck.IsChecked)
        Set-JsonProperty $s 'ignore_command_messages' ([bool]$IgnoreCommandsCheck.IsChecked)
        Set-JsonProperty $s 'ignore_mention_messages' ([bool]$IgnoreMentionsCheck.IsChecked)
        Set-JsonProperty $s 'strip_non_ascii' ([bool]$StripNonAsciiCheck.IsChecked)
        Set-JsonProperty $s 'strip_emojis' ([bool]$StripEmojiCheck.IsChecked)
        Set-JsonProperty $s 'block_ascii_art' ([bool]$BlockAsciiArtCheck.IsChecked)
        Write-Settings $s
        $BottomStatus.Text = 'Rules saved'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function Save-Pronunciation($oldWritten, $value) {
    $s = Read-Settings
    if (-not $s.pronunciations) { Set-JsonProperty $s 'pronunciations' ([pscustomobject]@{}) }
    if ($oldWritten -and $oldWritten -ne $value.Written) { $s.pronunciations.PSObject.Properties.Remove($oldWritten) }
    Set-JsonProperty $s.pronunciations $value.Written $value.Spoken
    $hidden = @($s.hidden_pronunciations)
    if ($value.Hidden) { if ($hidden -notcontains $value.Written) { $hidden += $value.Written } }
    else { $hidden = @($hidden | Where-Object { $_ -ne $value.Written }) }
    Set-JsonProperty $s 'hidden_pronunciations' $hidden
    Write-Settings $s
    Refresh-Grid
}
function Save-StreamerBotSettings {
    try {
        $udp = [int]$UdpBox.Text; $ws = [int]$WsBox.Text
        if ($udp -lt 1 -or $udp -gt 65535 -or $ws -lt 1 -or $ws -gt 65535) { throw 'Ports must be between 1 and 65535' }
        $s = Read-Settings
        Set-JsonProperty $s 'enable_udp' ([bool]$EnableUdpCheck.IsChecked)
        Set-JsonProperty $s 'udp_port' $udp
        Set-JsonProperty $s 'ws_port' $ws
        Set-JsonProperty $s 'streamerbot_actions_enabled' ([bool]$EnableStreamerBotActionsCheck.IsChecked)
        Set-JsonProperty $s 'streamerbot_http_url' $StreamerBotHttpUrlBox.Text.TrimEnd('/')
        Set-JsonProperty $s 'streamerbot_queued_action' $StreamerBotQueuedActionBox.Text.Trim()
        Set-JsonProperty $s 'streamerbot_queue_added_action' $StreamerBotQueueAddedActionBox.Text.Trim()
        Set-JsonProperty $s 'streamerbot_playing_action' $StreamerBotPlayingActionBox.Text.Trim()
        Set-JsonProperty $s 'streamerbot_finished_action' $StreamerBotFinishedActionBox.Text.Trim()
        foreach($state in $script:streamerExtraControls.Keys){Set-JsonProperty $s ('streamerbot_'+$state+'_action') $script:streamerExtraControls[$state].Text.Trim()}
        Set-JsonProperty $s 'streamerbot_playback_delay' ([double]$StreamerBotPlaybackDelaySlider.Value)
        Set-JsonProperty $s 'streamerbot_finished_delay' ([double]$StreamerBotFinishedDelaySlider.Value)
        Write-Settings $s
        $BottomStatus.Text = 'Streamer.bot settings saved. Restart after changing ports.'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function Update-QueueControlPayload {
    $item = $QueueControlCommandBox.SelectedItem
    if (-not $item) { return }
    $action = [string]$item.Tag
    $needsId = $action -in @('remove','moveup','movedown')
    $QueueControlPayloadBox.Text = "VCONTROL`r`n$action" + $(if ($needsId) { "`r`n%ttsId%" } else { '' })
    $QueueControlHint.Text = if ($needsId) { 'Uses %ttsId% from a VoxRelay lifecycle action. You can also replace it with a queue speech ID.' } else { 'This action does not need a queue item ID.' }
}
function Test-QueueControl {
    $item = $QueueControlCommandBox.SelectedItem
    if (-not $item) { return }
    $action = [string]$item.Tag
    try {
        switch ($action) {
            'pause' { Invoke-BridgePost '/pause' | Out-Null }
            'pauseaftercurrent' { Invoke-BridgePost '/pause-after-current' | Out-Null }
            'resume' { Invoke-BridgePost '/resume' | Out-Null }
            'skip' { Invoke-BridgePost '/skip' | Out-Null }
            'clear' { Invoke-BridgePost '/clear' | Out-Null }
            'clearall' { Invoke-BridgePost '/clear-all' | Out-Null }
            default {
                $row = $QueueGrid.SelectedItem
                if (-not $row) { throw 'Select an item on the Queue page before testing this action.' }
                if ($action -eq 'remove') { Invoke-BridgePost '/api/queue/remove' @{ speechId=$row.Id } | Out-Null }
                else { Invoke-BridgePost '/api/queue/move' @{ speechId=$row.Id; direction=$(if ($action -eq 'moveup') {'up'} else {'down'}) } | Out-Null }
            }
        }
        $BottomStatus.Text = ([string]$item.Content) + ' command sent'
        Refresh-ServiceState
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function Save-VoiceStudioSettings {
    try {
        $s = Read-Settings
        Set-JsonProperty $s 'voice_studio_url' $UrlBox.Text.TrimEnd('/')
        Set-JsonProperty $s 'api_key' $KeyBox.Text
        Set-JsonProperty $s 'request_timeout' ([double]$RequestTimeoutBox.Text)
        Write-Settings $s
        $BottomStatus.Text = 'VoiceStudio settings saved'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}

function Save-ElevenLabsSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'elevenlabs_enabled' ([bool]$ElevenLabsEnabledCheck.IsChecked)
    if ($ElevenLabsApiKeyBox.Password) {
        Set-JsonProperty $s 'elevenlabs_api_key_encrypted' (Protect-VoxRelaySecret $ElevenLabsApiKeyBox.Password)
        $ElevenLabsApiKeyBox.Password = ''
        $ElevenLabsStatus.Text = 'API key saved securely for this Windows account'
    }
    Write-Settings $s
    $BottomStatus.Text = 'ElevenLabs credentials saved'
}
function Clear-ElevenLabsSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'elevenlabs_api_key_encrypted' ''
    Write-Settings $s
    $ElevenLabsApiKeyBox.Password = ''
    $ElevenLabsStatus.Text = 'No key saved yet'
    $BottomStatus.Text = 'ElevenLabs secrets cleared'
}

function Save-AzureSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'azure_enabled' ([bool]$AzureEnabledCheck.IsChecked)
    Set-JsonProperty $s 'azure_region' $AzureRegionBox.Text.Trim()
    if ($AzureKeyBox.Password) {
        Set-JsonProperty $s 'azure_subscription_key_encrypted' (Protect-VoxRelaySecret $AzureKeyBox.Password)
        $AzureKeyBox.Password = ''
        $AzureStatus.Text = 'Subscription key saved securely for this Windows account'
    }
    Write-Settings $s
    $BottomStatus.Text = 'Azure Speech credentials saved'
}
function Clear-AzureSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'azure_subscription_key_encrypted' ''
    Write-Settings $s
    $AzureKeyBox.Password = ''
    $AzureStatus.Text = 'No key saved yet'
    $BottomStatus.Text = 'Azure Speech secrets cleared'
}

function Save-GoogleSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'google_enabled' ([bool]$GoogleEnabledCheck.IsChecked)
    Set-JsonProperty $s 'google_service_account_path' $GoogleServiceAccountBox.Text.Trim()
    if ($GoogleApiKeyBox.Password) {
        Set-JsonProperty $s 'google_api_key_encrypted' (Protect-VoxRelaySecret $GoogleApiKeyBox.Password)
        $GoogleApiKeyBox.Password = ''
        $GoogleStatus.Text = 'API key saved securely for this Windows account'
    } elseif ($GoogleServiceAccountBox.Text.Trim()) {
        $GoogleStatus.Text = 'Using service-account JSON path'
    }
    Write-Settings $s
    $BottomStatus.Text = 'Google Cloud TTS credentials saved'
}
function Clear-GoogleSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'google_api_key_encrypted' ''
    Write-Settings $s
    $GoogleApiKeyBox.Password = ''
    $GoogleStatus.Text = if ($GoogleServiceAccountBox.Text.Trim()) { 'Using service-account JSON path' } else { 'No credentials saved yet' }
    $BottomStatus.Text = 'Google Cloud TTS secrets cleared'
}

function Save-WatsonSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'watson_enabled' ([bool]$WatsonEnabledCheck.IsChecked)
    Set-JsonProperty $s 'watson_service_url' $WatsonServiceUrlBox.Text.Trim().TrimEnd('/')
    if ($WatsonApiKeyBox.Password) {
        Set-JsonProperty $s 'watson_api_key_encrypted' (Protect-VoxRelaySecret $WatsonApiKeyBox.Password)
        $WatsonApiKeyBox.Password = ''
        $WatsonStatus.Text = 'API key saved securely for this Windows account'
    }
    Write-Settings $s
    $BottomStatus.Text = 'IBM Watson credentials saved'
}
function Clear-WatsonSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'watson_api_key_encrypted' ''
    Write-Settings $s
    $WatsonApiKeyBox.Password = ''
    $WatsonStatus.Text = 'No key saved yet'
    $BottomStatus.Text = 'IBM Watson secrets cleared'
}

function Save-UberDuckSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'uberduck_enabled' ([bool]$UberDuckEnabledCheck.IsChecked)
    if ($UberDuckApiKeyBox.Password) {
        Set-JsonProperty $s 'uberduck_api_key_encrypted' (Protect-VoxRelaySecret $UberDuckApiKeyBox.Password)
        $UberDuckApiKeyBox.Password = ''
        $UberDuckStatus.Text = 'API key saved securely for this Windows account'
    }
    Write-Settings $s
    $BottomStatus.Text = 'UberDuck credentials saved'
}
function Clear-UberDuckSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'uberduck_api_key_encrypted' ''
    Write-Settings $s
    $UberDuckApiKeyBox.Password = ''
    $UberDuckStatus.Text = 'No key saved yet'
    $BottomStatus.Text = 'UberDuck secrets cleared'
}

function Save-TtsMonsterSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'ttsmonster_enabled' ([bool]$TtsMonsterEnabledCheck.IsChecked)
    Set-JsonProperty $s 'ttsmonster_overlay_url' $TtsMonsterOverlayBox.Text.Trim()
    if ($TtsMonsterTokenBox.Password) {
        Set-JsonProperty $s 'ttsmonster_api_token_encrypted' (Protect-VoxRelaySecret $TtsMonsterTokenBox.Password)
        $TtsMonsterTokenBox.Password = ''
        $TtsMonsterStatus.Text = 'API token saved securely for this Windows account'
    } elseif ($TtsMonsterOverlayBox.Text.Trim()) {
        $TtsMonsterStatus.Text = 'Using overlay URL'
    }
    Write-Settings $s
    $BottomStatus.Text = 'TTS.Monster credentials saved'
}
function Clear-TtsMonsterSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'ttsmonster_api_token_encrypted' ''
    Write-Settings $s
    $TtsMonsterTokenBox.Password = ''
    $TtsMonsterStatus.Text = if ($TtsMonsterOverlayBox.Text.Trim()) { 'Using overlay URL' } else { 'No credentials saved yet' }
    $BottomStatus.Text = 'TTS.Monster secrets cleared'
}

function Save-AcapelaSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'acapela_enabled' ([bool]$AcapelaEnabledCheck.IsChecked)
    Set-JsonProperty $s 'acapela_account' $AcapelaAccountBox.Text.Trim()
    Set-JsonProperty $s 'acapela_application_name' $(if ($AcapelaAppNameBox.Text.Trim()) { $AcapelaAppNameBox.Text.Trim() } else { 'VoxRelay' })
    if ($AcapelaPasswordBox.Password) {
        Set-JsonProperty $s 'acapela_password_encrypted' (Protect-VoxRelaySecret $AcapelaPasswordBox.Password)
        $AcapelaPasswordBox.Password = ''
        $AcapelaStatus.Text = 'Password saved securely for this Windows account'
    }
    Write-Settings $s
    $BottomStatus.Text = 'Acapela credentials saved'
}
function Clear-AcapelaSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'acapela_password_encrypted' ''
    Write-Settings $s
    $AcapelaPasswordBox.Password = ''
    $AcapelaStatus.Text = 'No password saved yet'
    $BottomStatus.Text = 'Acapela secrets cleared'
}

function Save-CereProcSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'cereproc_enabled' ([bool]$CereProcEnabledCheck.IsChecked)
    Set-JsonProperty $s 'cereproc_username' $CereProcUsernameBox.Text.Trim()
    if ($CereProcPasswordBox.Password) {
        Set-JsonProperty $s 'cereproc_password_encrypted' (Protect-VoxRelaySecret $CereProcPasswordBox.Password)
        $CereProcPasswordBox.Password = ''
        $CereProcStatus.Text = 'Password saved securely for this Windows account'
    }
    Write-Settings $s
    $BottomStatus.Text = 'CereProc credentials saved'
}
function Clear-CereProcSecrets {
    $s = Read-Settings
    Set-JsonProperty $s 'cereproc_password_encrypted' ''
    Write-Settings $s
    $CereProcPasswordBox.Password = ''
    $CereProcStatus.Text = 'No password saved yet'
    $BottomStatus.Text = 'CereProc secrets cleared'
}

function Save-PollySettings {
    try {
        $s = Read-Settings
        Set-JsonProperty $s 'polly_enabled' ([bool]$PollyEnabledCheck.IsChecked)
        Set-JsonProperty $s 'polly_region' (Get-PollyRegionText)
        Set-JsonProperty $s 'polly_profile' $PollyProfileBox.Text.Trim()
        if ($PollyAccessKeyBox.Password -or $PollySecretKeyBox.Password) {
            if (-not $PollyAccessKeyBox.Password -or -not $PollySecretKeyBox.Password) { throw 'Enter both the Access Key ID and Secret Access Key.' }
            Set-JsonProperty $s 'polly_access_key_encrypted' (Protect-VoxRelaySecret $PollyAccessKeyBox.Password)
            Set-JsonProperty $s 'polly_secret_key_encrypted' (Protect-VoxRelaySecret $PollySecretKeyBox.Password)
            Set-JsonProperty $s 'polly_session_token_encrypted' (Protect-VoxRelaySecret $PollySessionTokenBox.Password)
        }
        elseif ($PollySessionTokenBox.Password) { Set-JsonProperty $s 'polly_session_token_encrypted' (Protect-VoxRelaySecret $PollySessionTokenBox.Password) }
        Write-Settings $s
        $PollyAccessKeyBox.Password = ''; $PollySecretKeyBox.Password = ''
        $PollySessionTokenBox.Password = ''
        $PollyCredentialStatus.Text = 'Credentials saved securely for this Windows account'
        $BottomStatus.Text = 'Amazon Polly credentials saved'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}



function Show-AliasDialog($existing) {
    [xml]$dialogXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="620" Height="780" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F6F3FA">
 <Window.Resources>
  <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#B6A3FF"/><SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#15131D"/>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Background" Value="#1E1A27"/><Setter Property="BorderBrush" Value="#50485C"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Shell" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#F6F3FA"/><Setter TargetName="Shell" Property="BorderBrush" Value="#B6A3FF"/><Setter TargetName="Shell" Property="Background" Value="#50485C"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="Shell" Property="Opacity" Value="0.75"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="TextBox"><Setter Property="Background" Value="#1E1A27"/><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="BorderBrush" Value="#50485C"/><Setter Property="Padding" Value="11,9"/><Setter Property="CaretBrush" Value="#B6A3FF"/><Setter Property="SelectionBrush" Value="#B6A3FF"/><Setter Property="SelectionTextBrush" Value="#15131D"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border x:Name="Field" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Field" Property="BorderBrush" Value="#B6A3FF"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Field" Property="Opacity" Value="0.55"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ListBoxItem"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="10,7"/><Setter Property="Margin" Value="3,2"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="ItemShell" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="{TemplateBinding Margin}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ItemShell" Property="Background" Value="#33282231"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemShell" Property="Background" Value="#B6A3FF"/><Setter TargetName="ItemShell" Property="BorderBrush" Value="#B6A3FF"/><Setter Property="Foreground" Value="#15131D"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Border Background="#15131D" BorderBrush="#50485C" BorderThickness="1" CornerRadius="13"><Border.Effect><DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="7" Opacity="0.5"/></Border.Effect><Grid ClipToBounds="True"><Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="*"/></Grid.RowDefinitions>
  <Border Name="TitleBar" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="0,0,0,1" CornerRadius="13,13,0,0"><Grid><StackPanel Orientation="Horizontal" Margin="17,0" VerticalAlignment="Center"><Ellipse Width="7" Height="7" Fill="#B6A3FF" Margin="0,0,9,0"/><TextBlock Text="Voice alias" FontWeight="SemiBold"/></StackPanel><Button Name="Close" Content="X" HorizontalAlignment="Right" Width="46" Background="Transparent" BorderThickness="0"/></Grid></Border>
  <Grid Grid.Row="1"><Grid.RowDefinitions><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="24,20,14,0"><StackPanel Margin="0,0,10,18">
    <TextBlock Text="Alias name" Foreground="#B9B2C2"/><TextBox Name="NameBox" Margin="0,7,0,17"/>
    <TextBlock Text="Voice provider and profile" Foreground="#B9B2C2"/><TextBox Name="ProfileSearchBox" Margin="0,7,0,8" ToolTip="Search by voice, language, or engine"/><Border Name="ProfileListHost" Height="200" Margin="0,0,0,17" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="1" CornerRadius="8" ClipToBounds="False"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Border Grid.Row="0" Background="#9915131D" BorderBrush="#50485C" BorderThickness="0,0,0,1" Padding="14,8,14,7"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="1.25*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="0.95*"/></Grid.ColumnDefinitions><TextBlock Text="VOICE" Foreground="#B9B2C2" FontSize="10" FontWeight="Bold"/><TextBlock Grid.Column="1" Text="LANGUAGE" Foreground="#B9B2C2" FontSize="10" FontWeight="Bold"/><TextBlock Grid.Column="2" Text="ENGINE" Foreground="#B9B2C2" FontSize="10" FontWeight="Bold"/></Grid></Border><ListBox Name="ProfileBox" Grid.Row="1" Background="Transparent" BorderThickness="0" Padding="4" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto"><ListBox.ItemTemplate><DataTemplate><Grid Margin="2,0"><Grid.ColumnDefinitions><ColumnDefinition Width="1.25*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="0.95*"/></Grid.ColumnDefinitions><TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="{Binding Language}" Opacity="0.72" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/><TextBlock Grid.Column="2" Text="{Binding Engine}" Opacity="0.72" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/></Grid></DataTemplate></ListBox.ItemTemplate></ListBox></Grid></Border>
    <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Engine model" Foreground="#B9B2C2"/><ComboBox Name="ModelBox" Margin="0,7,0,0"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="Speed" Foreground="#B9B2C2"/><Slider Name="SpeedBox" Minimum="0.5" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True" Value="1" Margin="0,7,0,0" AutomationProperties.Name="Alias speed"/><TextBlock Text="{Binding ElementName=SpeedBox,Path=Value,StringFormat={}{0:0.00}x}"/></StackPanel></Grid>
    <Grid Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Group (optional)" Foreground="#B9B2C2"/><TextBox Name="GroupBox" Margin="0,7,0,0"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="Volume" Foreground="#B9B2C2"/><Slider Name="VolumeBox" Minimum="0" Maximum="2" TickFrequency="0.05" IsSnapToTickEnabled="True" Value="1" Margin="0,7,0,0" AutomationProperties.Name="Alias volume"/><TextBlock Text="{Binding ElementName=VolumeBox,Path=Value,StringFormat={}{0:P0}}"/></StackPanel></Grid>
    <TextBlock Text="Language code (optional)" Foreground="#B9B2C2" Margin="0,13,0,0"/><TextBox Name="LanguageBox" Margin="0,7,0,0"/>
    <TextBlock Text="Style instruction (optional)" Foreground="#B9B2C2" Margin="0,13,0,0"/><TextBox Name="StyleBox" Height="82" Margin="0,7,0,0" TextWrapping="Wrap" AcceptsReturn="True" VerticalContentAlignment="Top"/>
    <TextBlock Text="Audio output" Foreground="#B9B2C2" Margin="0,13,0,0"/><ComboBox Name="AliasOutputBox" Margin="0,7,0,0"/>
    <TextBlock Name="AliasValidationText" Foreground="#B6A3FF" TextWrapping="Wrap" Margin="0,12,0,0"/>
   </StackPanel></ScrollViewer>
   <Border Grid.Row="1" Background="#F215131D" BorderBrush="#50485C" BorderThickness="0,1,0,0" Padding="24,15"><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button Name="Cancel" Content="Cancel" Width="94" Margin="0,0,12,0"/><Button Name="Save" Content="Save alias" Width="112" Margin="0" Background="#B6A3FF" Foreground="#15131D" BorderBrush="#B6A3FF" FontWeight="SemiBold"/></StackPanel></Border>
  </Grid></Grid></Border>
</Window>
'@
    $d=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($dialogXaml));$d.Owner=$window
    Apply-AppFont $d
    $d.Resources.MergedDictionaries.Add($window.Resources)
    $d.MaxHeight = [Windows.SystemParameters]::WorkArea.Height - 30
    $n=$d.FindName('NameBox');$p=$d.FindName('ProfileBox');$m=$d.FindName('ModelBox');$sp=$d.FindName('SpeedBox');$g=$d.FindName('GroupBox');$vol=$d.FindName('VolumeBox');$lang=$d.FindName('LanguageBox');$style=$d.FindName('StyleBox')
    $profileSearch=$d.FindName('ProfileSearchBox');$aliasOutput=$d.FindName('AliasOutputBox');$aliasValidation=$d.FindName('AliasValidationText')
    [void]$aliasOutput.Items.Add('Use stream output')
    foreach ($device in @($OutputDeviceBox.Items)) { if ($device -ne '[Default]') { [void]$aliasOutput.Items.Add([string]$device) } }
    $aliasOutput.SelectedIndex=0
    if ($existing.OutputDevice) { if(-not$aliasOutput.Items.Contains([string]$existing.OutputDevice)){[void]$aliasOutput.Items.Add([string]$existing.OutputDevice)};$aliasOutput.SelectedItem=[string]$existing.OutputDevice }
    # Keep rounded border chrome, but never clip the voice list scrollbar.
    $profileHost = $d.FindName('ProfileListHost')
    if ($profileHost) { $profileHost.ClipToBounds = $false; $profileHost.Clip = $null }
    foreach($entry in $script:profiles.GetEnumerator()|Sort-Object { $_.Value.Name }, { $_.Value.Language }, { $_.Value.Engine }){
        $item = $entry.Value
        if ($item -is [string]) {
            $item = [pscustomobject]@{ Key=$entry.Key; Name=[string]$item; Language=''; Engine=''; SearchText=([string]$item + ' ' + $entry.Key) }
        }
        [void]$p.Items.Add($item)
    }
    $profileSearch.Add_TextChanged({
        $p.Items.Filter = [Predicate[object]]{
            param($item)
            $q = $profileSearch.Text
            if ([string]::IsNullOrWhiteSpace($q)) { return $true }
            $hay = if ($item.PSObject.Properties['SearchText']) { [string]$item.SearchText } else { [string]$item }
            return $hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
    })
    $p.Add_SelectionChanged({
        if($p.SelectedItem){
            $selectedKey = if ($p.SelectedItem.PSObject.Properties['Key']) { [string]$p.SelectedItem.Key } else { ([regex]::Match([string]$p.SelectedItem,'\[([^\]]+)\]$')).Groups[1].Value }
            if($script:profileModelOptions.ContainsKey($selectedKey)){$m.ItemsSource=@($script:profileModelOptions[$selectedKey]);$m.SelectedItem=[string]$script:profileModels[$selectedKey]}
            $style.IsEnabled=$selectedKey.StartsWith('voicestudio|')
        }
    })
    if($existing){
        $n.Text=$existing.Name;$sp.Value=[double]$existing.Speed;$g.Text=[string]$existing.Group;$vol.Value=[double]$existing.Volume;$lang.Text=[string]$existing.Language;$style.Text=[string]$existing.Instruct
        $provider=if($existing.Provider){[string]$existing.Provider}else{'voicestudio'};$wanted=$provider+'|'+$existing.VoiceId
        $match=$p.Items|Where-Object{ $_.Key -eq $wanted }|Select-Object -First 1
        if(-not$match){
            $label=if($existing.Profile){[string]$existing.Profile}else{[string]$existing.VoiceId}
            $match=[pscustomobject]@{ Key=$wanted; Name=$label; Language=''; Engine=$provider; SearchText=($label + ' ' + $wanted) }
            [void]$p.Items.Add($match)
        }
        $p.SelectedItem=$match
        if(@($m.ItemsSource) -notcontains [string]$existing.Model){$m.ItemsSource=@($m.ItemsSource)+@([string]$existing.Model)}
        $m.SelectedItem=[string]$existing.Model
    }
    else{$sp.Value=1;$vol.Value=1;if($p.Items.Count){$p.SelectedIndex=0}}
    $result=$null;$d.FindName('TitleBar').Add_MouseLeftButtonDown({$d.DragMove()});$d.FindName('Close').Add_Click({$d.Close()});$d.FindName('Cancel').Add_Click({$d.Close()});$d.FindName('Save').Add_Click({
        try {
            if (-not $n.Text.Trim() -or -not $p.SelectedItem) { throw 'Enter a name and choose a voice.' }
            if (-not $m.SelectedItem) { throw 'Choose an engine model.' }
            $speed=[double]$sp.Value;$volume=[double]$vol.Value
            if ($speed -lt 0.5 -or $speed -gt 2 -or $volume -lt 0 -or $volume -gt 2) { throw 'Speed must be 0.5 to 2; volume must be 0 to 2.' }
            $key = if ($p.SelectedItem.PSObject.Properties['Key']) { [string]$p.SelectedItem.Key } else { ([regex]::Match([string]$p.SelectedItem,'\[([^\]]+)\]$')).Groups[1].Value };$parts=$key.Split('|',2)
            $script:dialogResult=[pscustomobject]@{Name=$n.Text.Trim();Provider=$parts[0];VoiceId=$parts[1];Model=[string]$m.SelectedItem;Speed=$speed;Group=$g.Text.Trim();Volume=$volume;Language=$lang.Text.Trim();Instruct=$style.Text.Trim();OutputDevice=$(if($aliasOutput.SelectedIndex -gt 0){[string]$aliasOutput.SelectedItem}else{''})}
            $d.DialogResult=$true
        } catch { $aliasValidation.Text=$_.Exception.Message }
    })
    $script:dialogResult=$null;[void]$d.ShowDialog();return $script:dialogResult
}

function Show-TestDialog([string]$alias) {
    [xml]$testXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="540" Height="315" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F6F3FA">
 <Window.Resources>
  <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#B6A3FF"/><SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#15131D"/>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Background" Value="#1E1A27"/><Setter Property="BorderBrush" Value="#50485C"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Shell" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#F6F3FA"/><Setter TargetName="Shell" Property="BorderBrush" Value="#B6A3FF"/><Setter TargetName="Shell" Property="Background" Value="#50485C"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="Shell" Property="Opacity" Value="0.75"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Border Background="#15131D" BorderBrush="#50485C" BorderThickness="1" CornerRadius="13"><Border.Effect><DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="7" Opacity="0.5"/></Border.Effect><Grid ClipToBounds="True"><Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="*"/></Grid.RowDefinitions>
  <Border Name="TitleBar" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="0,0,0,1" CornerRadius="13,13,0,0"><Grid><StackPanel Orientation="Horizontal" Margin="17,0" VerticalAlignment="Center"><Ellipse Width="7" Height="7" Fill="#B6A3FF" Margin="0,0,9,0"/><TextBlock Text="Test voice" FontWeight="SemiBold"/></StackPanel><Button Name="Close" Content="X" HorizontalAlignment="Right" Width="46" Background="Transparent" BorderThickness="0"/></Grid></Border>
  <Grid Grid.Row="1" Margin="24,19,24,24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <TextBlock Name="Heading" FontSize="20" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="Enter the text you want this voice to speak." Foreground="#B9B2C2" Margin="0,5,0,14"/>
   <Border Grid.Row="2" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="1" CornerRadius="8"><TextBox Name="Text" Height="72" Padding="11,9" TextWrapping="Wrap" AcceptsReturn="True" VerticalContentAlignment="Top" Background="Transparent" Foreground="#F6F3FA" BorderThickness="0" CaretBrush="#B6A3FF" SelectionBrush="#B6A3FF" SelectionTextBrush="#15131D"/></Border>
   <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,17,0,0"><Button Name="Cancel" Content="Cancel" Width="94" Margin="0,0,9,0"/><Button Name="Speak" Content="Speak" Width="94" Background="#B6A3FF" Foreground="#15131D" BorderBrush="#B6A3FF" FontWeight="SemiBold"/></StackPanel>
  </Grid></Grid></Border>
</Window>
'@
    $d=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($testXaml));$d.Owner=$window
    Apply-AppFont $d
    $d.FindName('Heading').Text='Test '+$alias;$box=$d.FindName('Text');$box.Text='VoxRelay is ready.';$box.SelectAll()
    $script:testResult=$null;$d.FindName('TitleBar').Add_MouseLeftButtonDown({$d.DragMove()});$d.FindName('Close').Add_Click({$d.Close()});$d.FindName('Cancel').Add_Click({$d.Close()});$d.FindName('Speak').Add_Click({if($box.Text.Trim()){$script:testResult=$box.Text;$d.DialogResult=$true}})
    $d.Add_ContentRendered({$box.Focus()});[void]$d.ShowDialog();return $script:testResult
}

function Show-PronunciationDialog($existing) {
    [xml]$entryXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="560" Height="550" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F6F3FA">
 <Window.Resources>
  <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#B6A3FF"/><SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#15131D"/>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Background" Value="#1E1A27"/><Setter Property="BorderBrush" Value="#50485C"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Shell" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#F6F3FA"/><Setter TargetName="Shell" Property="BorderBrush" Value="#B6A3FF"/><Setter TargetName="Shell" Property="Background" Value="#50485C"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="Shell" Property="Opacity" Value="0.75"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="TextBox"><Setter Property="Background" Value="#1E1A27"/><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="BorderBrush" Value="#50485C"/><Setter Property="Padding" Value="11,9"/><Setter Property="CaretBrush" Value="#B6A3FF"/><Setter Property="SelectionBrush" Value="#B6A3FF"/><Setter Property="SelectionTextBrush" Value="#15131D"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border x:Name="Field" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Field" Property="BorderBrush" Value="#B6A3FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="18"/><ColumnDefinition/></Grid.ColumnDefinitions><Border x:Name="Box" Width="16" Height="16" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="1" CornerRadius="4"><Path x:Name="Check" Data="M3,8 L7,12 L14,4" Stroke="#15131D" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/></Border><ContentPresenter Grid.Column="1" Margin="9,0,0,0" VerticalAlignment="Center"/></Grid><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#B6A3FF"/></Trigger><Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="#B6A3FF"/><Setter TargetName="Box" Property="BorderBrush" Value="#B6A3FF"/><Setter TargetName="Check" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ListBoxItem"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Padding" Value="10,7"/><Setter Property="Margin" Value="2"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="Item" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Item" Property="Background" Value="#33282231"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="Item" Property="Background" Value="#B6A3FF"/><Setter TargetName="Item" Property="BorderBrush" Value="#B6A3FF"/><Setter Property="Foreground" Value="#15131D"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Padding" Value="12,9"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem"><Border x:Name="Item" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Item" Property="Background" Value="#33282231"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="Item" Property="Background" Value="#B6A3FF"/><Setter Property="Foreground" Value="#15131D"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ComboBox"><Setter Property="Foreground" Value="#F6F3FA"/><Setter Property="Background" Value="#1E1A27"/><Setter Property="BorderBrush" Value="#50485C"/><Setter Property="Height" Value="42"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid><ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen,RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border x:Name="Shell" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="1" CornerRadius="8"><Grid><ContentPresenter Content="{Binding SelectionBoxItem,RelativeSource={RelativeSource AncestorType=ComboBox}}" TextElement.Foreground="#F6F3FA" Margin="12,0,38,0" VerticalAlignment="Center"/><Path Data="M3,6 L8,11 L13,6" Stroke="#B6A3FF" StrokeThickness="1.7" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0"/></Grid></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Shell" Property="BorderBrush" Value="#B6A3FF"/></Trigger><Trigger Property="IsChecked" Value="True"><Setter TargetName="Shell" Property="BorderBrush" Value="#B6A3FF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template></ToggleButton><Popup Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"><Border Background="#1E1A27" BorderBrush="#B6A3FF" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0" MinWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="220"><ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer></Border></Popup></Grid></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Border Background="#15131D" BorderBrush="#50485C" BorderThickness="1" CornerRadius="13"><Border.Effect><DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="7" Opacity="0.5"/></Border.Effect><Grid ClipToBounds="True"><Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="*"/></Grid.RowDefinitions>
  <Border Name="TitleBar" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="0,0,0,1" CornerRadius="13,13,0,0"><Grid><StackPanel Orientation="Horizontal" Margin="17,0" VerticalAlignment="Center"><Ellipse Width="7" Height="7" Fill="#B6A3FF" Margin="0,0,9,0"/><TextBlock Name="WindowTitle" Text="Pronunciation entry" FontWeight="SemiBold"/></StackPanel><Button Name="Close" Content="X" HorizontalAlignment="Right" Width="46" Background="Transparent" BorderThickness="0"/></Grid></Border>
  <Grid Grid.Row="1" Margin="24,20,24,24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <TextBlock Text="Written text" Foreground="#B9B2C2"/><TextBox Name="WrittenBox" Grid.Row="1" Margin="0,7,0,17"/>
   <TextBlock Grid.Row="2" Text="Spoken as (separate random alternatives with commas)" Foreground="#B9B2C2"/><TextBox Name="SpokenBox" Grid.Row="3" Margin="0,7,0,0"/>
   <CheckBox Name="HideWrittenCheck" Grid.Row="4" Content="Censor the written text in the dictionary view" Margin="0,12,0,0"/>
   <TextBlock Grid.Row="5" Text="The real text remains stored locally. Example alternatives: hay-lo, hah-lo, halo" Foreground="#8F8998" Margin="27,5,0,16"/>
   <TextBlock Grid.Row="6" Text="Preview with alias" Foreground="#B9B2C2"/>
   <ComboBox Name="AliasList" Grid.Row="7" Margin="0,7,0,0"/>
   <TextBlock Name="PreviewStatus" Grid.Row="8" Text="Enter the spoken pronunciation, choose an alias, and test it before saving." Foreground="#8F8998" Margin="0,10,0,12" TextWrapping="Wrap"/>
   <StackPanel Grid.Row="9" Orientation="Horizontal" HorizontalAlignment="Right"><Button Name="Test" Content="Test audio" Width="104" Margin="0,0,12,0"/><Button Name="Cancel" Content="Cancel" Width="94" Margin="0,0,12,0"/><Button Name="Save" Content="Save entry" Width="112" Margin="0" Background="#B6A3FF" Foreground="#15131D" BorderBrush="#B6A3FF" FontWeight="SemiBold"/></StackPanel>
  </Grid></Grid></Border>
</Window>
'@
    $d=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($entryXaml));$d.Owner=$window;Apply-AppFont $d
    $written=$d.FindName('WrittenBox');$spoken=$d.FindName('SpokenBox');$hideWritten=$d.FindName('HideWrittenCheck');$aliases=$d.FindName('AliasList');$previewStatus=$d.FindName('PreviewStatus');foreach($item in @($PlayVoiceList.Items)){[void]$aliases.Items.Add([string]$item)};if($aliases.Items.Count){$aliases.SelectedIndex=0};if($existing){$written.Text=[string]$existing.Written;$spoken.Text=[string]$existing.Spoken;$hideWritten.IsChecked=[bool]$existing.Hidden;$d.FindName('WindowTitle').Text='Edit pronunciation'}
    $script:pronunciationResult=$null;$d.FindName('TitleBar').Add_MouseLeftButtonDown({$d.DragMove()});$d.FindName('Close').Add_Click({$d.Close()});$d.FindName('Cancel').Add_Click({$d.Close()});$d.FindName('Test').Add_Click({$alias=[string]$aliases.SelectedItem;$choice=Get-RandomPronunciation $spoken.Text;if(-not$choice){$previewStatus.Text='Enter at least one spoken pronunciation first.'}elseif(-not$alias){$previewStatus.Text='Choose an alias first.'}else{try{Invoke-BridgePost '/speak' @{voice=$alias;message=$choice;source='Pronunciation preview'}|Out-Null;$previewStatus.Text='Previewing "'+$choice+'" with '+$alias}catch{$previewStatus.Text=$_.Exception.Message}}});$saveAction={if($written.Text.Trim() -and (Get-RandomPronunciation $spoken.Text)){$isHidden=[bool]$hideWritten.IsChecked;$display=if($isHidden){'*' * [Math]::Max(4,$written.Text.Trim().Length)}else{$written.Text.Trim()};$script:pronunciationResult=[pscustomobject]@{Written=$written.Text.Trim();DisplayWritten=$display;Spoken=$spoken.Text.Trim();Hidden=$isHidden};$d.DialogResult=$true}};$d.FindName('Save').Add_Click($saveAction);$d.Add_KeyDown({if($_.Key -eq 'Escape'){$d.Close()}});$d.Add_ContentRendered({$written.Focus();$written.SelectAll()});[void]$d.ShowDialog();return $script:pronunciationResult
}

function Toggle-Maximize {
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal'; return }
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $screen = [System.Windows.Forms.Screen]::FromHandle($handle)
    $source = [System.Windows.PresentationSource]::FromVisual($window)
    if ($source -and $source.CompositionTarget) {
        $topLeft = $source.CompositionTarget.TransformFromDevice.Transform([Windows.Point]::new($screen.WorkingArea.Left, $screen.WorkingArea.Top))
        $bottomRight = $source.CompositionTarget.TransformFromDevice.Transform([Windows.Point]::new($screen.WorkingArea.Right, $screen.WorkingArea.Bottom))
        $window.MaxWidth = $bottomRight.X - $topLeft.X
        $window.MaxHeight = $bottomRight.Y - $topLeft.Y
    } else {
        $window.MaxWidth = [Windows.SystemParameters]::WorkArea.Width
        $window.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
    }
    $window.WindowState = 'Maximized'
}

function Write-TrayLog([string]$message) {
    try { Add-Content -LiteralPath (Join-Path $configDir 'tray.log') -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $message) -Encoding UTF8 } catch {}
}
function Get-TrayIconPath {
    $icoPath = Join-Path $configDir 'tray.ico'
    if (Test-Path -LiteralPath $icoPath) { return $icoPath }
    $pngPath = Join-Path $appRoot 'assets\VoxRelay-icon.png'
    try {
        if (Test-Path -LiteralPath $pngPath) {
            $source = [System.Drawing.Bitmap]::FromFile($pngPath)
            $sized = New-Object System.Drawing.Bitmap 32, 32
            $g = [System.Drawing.Graphics]::FromImage($sized)
            $g.Clear([System.Drawing.Color]::FromArgb(182, 163, 255))
            $g.DrawImage($source, 2, 2, 28, 28)
            $g.Dispose(); $source.Dispose()
            $temp = [System.Drawing.Icon]::FromHandle($sized.GetHicon())
            $clone = [System.Drawing.Icon]::new($temp, 32, 32)
            $fs = [System.IO.File]::Create($icoPath); $clone.Save($fs); $fs.Close()
            $clone.Dispose(); $temp.Dispose(); $sized.Dispose()
        }
    } catch { Write-TrayLog ('icon build: ' + $_.Exception.Message) }
    return $icoPath
}
function Promote-TrayIconInRegistry {
    # Promote whatever process owns the NotifyIcon (powershell host).
    try {
        $root = 'HKCU:\Control Panel\NotifyIconSettings'
        if (-not (Test-Path -LiteralPath $root)) { return }
        $exeHint = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Get-ChildItem -LiteralPath $root | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $exe = [string]$props.ExecutablePath
            $tip = [string]$props.IconText
            $initial = [string]$props.InitialTooltip
            if (($tip -eq 'VoxRelay') -or ($initial -eq 'VoxRelay') -or ($exe -like '*powershell*') -or ($exe -like '*VoxRelay*')) {
                if ($tip -eq 'VoxRelay' -or $initial -eq 'VoxRelay' -or $exe -eq $exeHint -or $exe -like '*VoxRelay.Tray.exe*') {
                    New-ItemProperty -Path $_.PSPath -Name IsPromoted -PropertyType DWord -Value 1 -Force | Out-Null
                    New-ItemProperty -Path $_.PSPath -Name IconText -PropertyType String -Value 'VoxRelay' -Force | Out-Null
                }
            }
        }
    } catch {}
}
function Initialize-TrayIcon {
    if ($script:trayIcon) { return }
    # Speaker.bot style: NotifyIcon lives in THIS process so restore/click stay on the UI thread.
    Get-Process -Name 'VoxRelay.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $icoPath = Get-TrayIconPath
    try {
        if (Test-Path -LiteralPath $icoPath) { $script:trayOwnedIcon = [System.Drawing.Icon]::new($icoPath) }
        else { $script:trayOwnedIcon = [System.Drawing.SystemIcons]::Application.Clone() }
    } catch {
        $script:trayOwnedIcon = [System.Drawing.SystemIcons]::Application.Clone()
    }
    $script:trayIcon = [System.Windows.Forms.NotifyIcon]::new()
    $script:trayIcon.Text = 'VoxRelay'
    $script:trayIcon.Icon = $script:trayOwnedIcon
    $script:trayIcon.Visible = $false

    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $openItem = [System.Windows.Forms.ToolStripMenuItem]::new('Restore')
    $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')
    [void]$menu.Items.Add($openItem)
    [void]$menu.Items.Add($exitItem)
    $openItem.Add_Click({ Restore-FromTray })
    $exitItem.Add_Click({
        $script:allowClose = $true
        if ($window.Dispatcher.CheckAccess()) { $window.Close() }
        else { $window.Dispatcher.Invoke([action]{ $window.Close() }) }
    })
    $script:trayIcon.ContextMenuStrip = $menu
    $script:trayIcon.Add_DoubleClick({ Restore-FromTray })
    $script:trayIcon.Add_MouseUp({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-FromTray }
    })
    Write-TrayLog 'in-process NotifyIcon ready'
}
function Sync-TrayIconMode {
    $enabled = [bool]$script:minimizeToTray
    if ($MinimizeToTrayCheck) { $enabled = $enabled -or [bool]$MinimizeToTrayCheck.IsChecked }
    Initialize-TrayIcon
    if (-not $script:trayIcon) { return }
    if ($enabled -or $script:hiddenInTray) {
        $script:trayIcon.Visible = $true
        Start-Sleep -Milliseconds 200
        Promote-TrayIconInRegistry
    } elseif (-not $script:hiddenInTray) {
        $script:trayIcon.Visible = $false
    }
}
function Hide-ToTray {
    if (-not $script:allowHideToTray) {
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
        $window.ShowInTaskbar = $true
        $window.Visibility = 'Visible'
        return
    }
    Initialize-TrayIcon
    if (-not $script:trayIcon) { return }
    $script:hiddenInTray = $true
    $script:trayIcon.Visible = $true
    $script:trayIcon.Text = 'VoxRelay - Restore'
    Promote-TrayIconInRegistry
    # The main window runs on Dispatcher.Run(), so it can be genuinely hidden
    # without ending the application or leaving a borderless title-bar fragment.
    $window.ShowInTaskbar = $false
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Hide()
    Write-TrayLog 'Hide-ToTray (window hidden)'
}
function Restore-FromTray {
    $action = {
        $script:hiddenInTray = $false
        if (-not $window.IsVisible) { $window.Show() }
        $window.WindowState = 'Normal'
        $window.ShowInTaskbar = $true
        $window.Activate()
        try {
            $window.Topmost = $true
            $window.Topmost = $false
        } catch {}
        if ($script:trayIcon -and -not ($script:minimizeToTray -or [bool]$MinimizeToTrayCheck.IsChecked)) {
            $script:trayIcon.Visible = $false
        } elseif ($script:trayIcon) {
            $script:trayIcon.Text = 'VoxRelay'
            $script:trayIcon.Visible = $true
        }
        Write-TrayLog 'Restore-FromTray'
    }
    if ($window.Dispatcher.CheckAccess()) { & $action }
    else { $window.Dispatcher.Invoke([action]$action) }
}
function Dispose-TrayIcon {
    if ($script:trayIcon) {
        try { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } catch {}
        $script:trayIcon = $null
    }
    if ($script:trayOwnedIcon) {
        try { $script:trayOwnedIcon.Dispose() } catch {}
        $script:trayOwnedIcon = $null
    }
    Get-Process -Name 'VoxRelay.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-TrayLog 'Dispose-TrayIcon'
}

$AppTitleBar.Add_MouseLeftButtonDown({ if ($_.ClickCount -eq 2) { Toggle-Maximize } else { $window.DragMove() } })
$MinimizeButton.Add_Click({
    $script:allowHideToTray = $true
    if ($script:minimizeToTray -or [bool]$MinimizeToTrayCheck.IsChecked) { Hide-ToTray } else { $window.WindowState = 'Minimized' }
})
$MaximizeButton.Add_Click({ Toggle-Maximize })
$CloseButton.Add_Click({ $script:allowClose = $true; $window.Close() })
$window.Add_StateChanged({
    if (-not $script:allowHideToTray) {
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal'; $window.ShowInTaskbar = $true; $window.Show() }
        return
    }
    if (($script:minimizeToTray -or [bool]$MinimizeToTrayCheck.IsChecked) -and $window.WindowState -eq 'Minimized' -and -not $script:hiddenInTray) { Hide-ToTray }
})
$VoicesNav.Add_Click({ Set-Page 'voices' }); $PlaygroundNav.Add_Click({ Set-Page 'playground' }); $QueueNav.Add_Click({ Set-Page 'queue' })
$HistoryNav.Add_Click({ Set-Page 'history' }); $RulesNav.Add_Click({ Set-Page 'rules' }); $PronunciationNav.Add_Click({ Set-Page 'pronunciation' })
$ServicesToggle.Add_Click({ Set-ServicesExpanded (-not $script:servicesExpanded) })
$StreamerBotNav.Add_Click({ Set-Page 'streamerbot' }); $VoiceStudioNav.Add_Click({ Set-Page 'voicestudio' }); $PollyNav.Add_Click({ Set-Page 'polly' }); $ElevenLabsNav.Add_Click({ Set-Page 'elevenlabs' }); $AzureNav.Add_Click({ Set-Page 'azure' }); $GoogleNav.Add_Click({ Set-Page 'google' }); $WatsonNav.Add_Click({ Set-Page 'watson' }); $UberDuckNav.Add_Click({ Set-Page 'uberduck' }); $TtsMonsterNav.Add_Click({ Set-Page 'ttsmonster' }); $AcapelaNav.Add_Click({ Set-Page 'acapela' }); $CereProcNav.Add_Click({ Set-Page 'cereproc' })
$ActivityNav.Add_Click({ Set-Page 'activity' }); $SettingsNav.Add_Click({ Set-Page 'settings' }); $BridgeStatusButton.Add_Click({ Set-Page 'settings' })
$RefreshButton.Add_Click({ Refresh-Voices })
$AddButton.Add_Click({ $v = Show-AliasDialog $null; if ($v) { Save-Alias $null $v } })
$EditButton.Add_Click({ $row = $AliasGrid.SelectedItem; if ($row) { $v = Show-AliasDialog $row; if ($v) { Save-Alias $row.Name $v } } })
$RemoveButton.Add_Click({ $row = $AliasGrid.SelectedItem; if ($row) { $s = Read-Settings; $s.aliases.PSObject.Properties.Remove($row.Name); Write-Settings $s; Refresh-Grid -VoicesOnly } })
$TestButton.Add_Click({ $row = $AliasGrid.SelectedItem; if ($row) { $text = Show-TestDialog $row.Name; if ($text) { Speak-Text $row.Name $text 'Test' } } })
$PlaygroundText.Add_TextChanged({ $CharacterCount.Text = ([string]$PlaygroundText.Text).Length.ToString() + ' characters' })
$PlayVoiceList.Add_SelectionChanged({
    $s=Read-Settings;$name=[string]$PlayVoiceList.SelectedItem
    if($name){$provider=[string]$s.aliases.$name.provider;$PlaySsmlCheck.IsEnabled=$provider -in @('polly','windows','azure','cereproc');if(-not $PlaySsmlCheck.IsEnabled){$PlaySsmlCheck.IsChecked=$false};$PlayStyleBox.IsEnabled=$provider -eq 'voicestudio'}
})
$PlaySsmlCheck.Add_Checked({$PlaySpeedBox.IsEnabled=$false})
$PlaySsmlCheck.Add_Unchecked({$PlaySpeedBox.IsEnabled=$true})
$PlayButton.Add_Click({
    $alias = [string]$PlayVoiceList.SelectedItem
    if ($alias -and $PlaygroundText.Text.Trim()) {
        try {
            Invoke-BridgePost '/speak' @{ voice=$alias; message=$PlaygroundText.Text; source='Playground'; speed=[double]$PlaySpeedBox.Value; volume=[double]$PlayVolumeBox.Value; instruct=$PlayStyleBox.Text;ssml=[bool]$PlaySsmlCheck.IsChecked } | Out-Null
            $BottomStatus.Text = 'Speech queued for ' + $alias
        } catch { $BottomStatus.Text = $_.Exception.Message }
    }
})
$PlayStopButton.Add_Click({ try { Invoke-BridgePost '/stop' | Out-Null } catch {} })
$PauseQueueButton.Add_Click({ try { Invoke-BridgePost '/pause' | Out-Null; Refresh-ServiceState } catch {} })
$ResumeQueueButton.Add_Click({ try { Invoke-BridgePost '/resume' | Out-Null; Refresh-ServiceState } catch {} })
$SkipQueueButton.Add_Click({ try { Invoke-BridgePost '/skip' | Out-Null; Refresh-ServiceState } catch {} })
$ClearQueueButton.Add_Click({ try { Invoke-BridgePost '/clear' | Out-Null; Refresh-ServiceState } catch {} })
$RemoveQueueButton.Add_Click({ $row = $QueueGrid.SelectedItem; if ($row) { try { Invoke-BridgePost '/api/queue/remove' @{ speechId=$row.Id } | Out-Null; Refresh-ServiceState } catch {} } })
$QueueUpButton.Add_Click({ $row = $QueueGrid.SelectedItem; if ($row) { try { Invoke-BridgePost '/api/queue/move' @{ speechId=$row.Id; direction='up' } | Out-Null; Refresh-ServiceState } catch {} } })
$QueueDownButton.Add_Click({ $row = $QueueGrid.SelectedItem; if ($row) { try { Invoke-BridgePost '/api/queue/move' @{ speechId=$row.Id; direction='down' } | Out-Null; Refresh-ServiceState } catch {} } })
$ReplayHistoryButton.Add_Click({ $row = $HistoryGrid.SelectedItem; if ($row) { try { Invoke-BridgePost '/api/history/replay' @{speechId=$row.Id} | Out-Null; $BottomStatus.Text='Recording queued' } catch { $BottomStatus.Text=$_.Exception.Message } } })
$SaveHistoryAudioButton.Add_Click({ $row = $HistoryGrid.SelectedItem; if ($row) { try { Invoke-BridgePost '/api/history/save' @{ speechId=$row.Id } | Out-Null } catch { $BottomStatus.Text = $_.Exception.Message } } })
$ClearHistoryButton.Add_Click({ try { Invoke-BridgePost '/api/history/clear' | Out-Null; Refresh-ServiceState } catch {} })
$SaveRulesButton.Add_Click({ Save-Rules })
$AddPronunciationButton.Add_Click({ $v = Show-PronunciationDialog $null; if ($v) { Save-Pronunciation $null $v } })
$EditPronunciationButton.Add_Click({ $row = $PronunciationGrid.SelectedItem; if ($row) { $v = Show-PronunciationDialog $row; if ($v) { Save-Pronunciation $row.Written $v } } })
$RemovePronunciationButton.Add_Click({
    $row = $PronunciationGrid.SelectedItem
    if (-not $row) { return }
    $s = Read-Settings
    $s.pronunciations.PSObject.Properties.Remove($row.Written)
    Set-JsonProperty $s 'hidden_pronunciations' @($s.hidden_pronunciations | Where-Object { $_ -ne $row.Written })
    Write-Settings $s; Refresh-Grid
})
$TestPronunciationButton.Add_Click({
    $row = $PronunciationGrid.SelectedItem; if (-not $row) { return }
    $alias = [string]$PronunciationVoiceList.SelectedItem
    if (-not $alias) { $BottomStatus.Text = 'Choose a voice alias first'; return }
    $choice = Get-RandomPronunciation ([string]$row.Spoken)
    if (-not $choice) { return }
    Speak-Text $alias $choice 'Pronunciation'
})
$SaveStreamerBotButton.Add_Click({ Save-StreamerBotSettings })
$StreamerBotPlaybackDelaySlider.Add_ValueChanged({ $StreamerBotPlaybackDelayValue.Text = ('{0:0.00} s' -f $StreamerBotPlaybackDelaySlider.Value) })
$StreamerBotFinishedDelaySlider.Add_ValueChanged({ $StreamerBotFinishedDelayValue.Text = ('{0:0.00} s' -f $StreamerBotFinishedDelaySlider.Value) })
$QueueControlCommandBox.SelectedIndex = 0
$QueueControlCommandBox.Add_SelectionChanged({ Update-QueueControlPayload })
Update-QueueControlPayload
$CopyQueueControlButton.Add_Click({ Update-QueueControlPayload; [Windows.Clipboard]::SetText($QueueControlPayloadBox.Text); $BottomStatus.Text = 'Queue control payload copied' })
$TestQueueControlButton.Add_Click({ Test-QueueControl })
$TestStreamerBotQueuedButton.Add_Click({ try { Invoke-BridgePost '/api/integrations/streamerbot/test' @{ state='queued' } | Out-Null } catch { $BottomStatus.Text = $_.Exception.Message } })
$TestStreamerBotQueueAddedButton.Add_Click({ try { Invoke-BridgePost '/api/integrations/streamerbot/test' @{ state='queueAdded' } | Out-Null } catch { $BottomStatus.Text = $_.Exception.Message } })
$TestStreamerBotPlayingButton.Add_Click({ try { Invoke-BridgePost '/api/integrations/streamerbot/test' @{ state='playing' } | Out-Null } catch { $BottomStatus.Text = $_.Exception.Message } })
$TestStreamerBotFinishedButton.Add_Click({ try { Invoke-BridgePost '/api/integrations/streamerbot/test' @{ state='finished' } | Out-Null } catch { $BottomStatus.Text = $_.Exception.Message } })
$SaveVoiceStudioButton.Add_Click({ Save-VoiceStudioSettings })
$TestVoiceStudioButton.Add_Click({ Save-VoiceStudioSettings; Refresh-Voices })
$SavePollyButton.Add_Click({ Save-PollySettings })
$SaveElevenLabsButton.Add_Click({ Save-ElevenLabsSettings })
$TestElevenLabsButton.Add_Click({ Save-ElevenLabsSettings; Refresh-Voices })
$ClearElevenLabsButton.Add_Click({ Clear-ElevenLabsSecrets })
$SaveAzureButton.Add_Click({ Save-AzureSettings })
$TestAzureButton.Add_Click({ Save-AzureSettings; Refresh-Voices })
$ClearAzureButton.Add_Click({ Clear-AzureSecrets })
$SaveGoogleButton.Add_Click({ Save-GoogleSettings })
$TestGoogleButton.Add_Click({ Save-GoogleSettings; Refresh-Voices })
$ClearGoogleButton.Add_Click({ Clear-GoogleSecrets })
$SaveWatsonButton.Add_Click({ Save-WatsonSettings })
$TestWatsonButton.Add_Click({ Save-WatsonSettings; Refresh-Voices })
$ClearWatsonButton.Add_Click({ Clear-WatsonSecrets })
$SaveUberDuckButton.Add_Click({ Save-UberDuckSettings })
$TestUberDuckButton.Add_Click({ Save-UberDuckSettings; Refresh-Voices })
$ClearUberDuckButton.Add_Click({ Clear-UberDuckSecrets })
$SaveTtsMonsterButton.Add_Click({ Save-TtsMonsterSettings })
$TestTtsMonsterButton.Add_Click({ Save-TtsMonsterSettings; Refresh-Voices })
$ClearTtsMonsterButton.Add_Click({ Clear-TtsMonsterSecrets })
$SaveAcapelaButton.Add_Click({ Save-AcapelaSettings })
$TestAcapelaButton.Add_Click({ Save-AcapelaSettings; Refresh-Voices })
$ClearAcapelaButton.Add_Click({ Clear-AcapelaSecrets })
$SaveCereProcButton.Add_Click({ Save-CereProcSettings })
$TestCereProcButton.Add_Click({ Save-CereProcSettings; Refresh-Voices })
$ClearCereProcButton.Add_Click({ Clear-CereProcSecrets })
$TestPollyButton.Add_Click({ Save-PollySettings; Refresh-Voices })
$ClearPollyCredentialsButton.Add_Click({
    try {
        $s = Read-Settings
        Set-JsonProperty $s 'polly_access_key_encrypted' ''
        Set-JsonProperty $s 'polly_secret_key_encrypted' ''
        Set-JsonProperty $s 'polly_session_token_encrypted' ''
        Write-Settings $s
        $PollyAccessKeyBox.Password = ''; $PollySecretKeyBox.Password = ''
        $PollySessionTokenBox.Password = ''
        $PollyCredentialStatus.Text = 'No credentials saved yet'
        $BottomStatus.Text = 'Amazon Polly keys cleared'
    } catch { $BottomStatus.Text = $_.Exception.Message }
})
$BrowseVoiceFolderButton.Add_Click({
    $picker = [System.Windows.Forms.FolderBrowserDialog]::new()
    $picker.Description = 'Choose where exported voice files are saved'
    $picker.ShowNewFolderButton = $true
    if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $VoiceSaveFolderBox.Text = $picker.SelectedPath }
    $picker.Dispose()
})
$CopyPayloadButton.Add_Click({ [Windows.Clipboard]::SetText($StreamerPayloadBox.Text) })
$TestConnectionButton.Add_Click({ Refresh-Voices })
$SaveButton.Add_Click({
    try {
        $http = [int]$HttpBox.Text
        if ($http -lt 1 -or $http -gt 65535) { throw 'HTTP port must be between 1 and 65535' }
        $s = Read-Settings
        $limits = @{ max_characters=[int]$MaxCharactersSettingBox.Text; max_queue=[int]$MaxQueueSettingBox.Text; history_limit=[int]$HistoryLimitBox.Text }
        foreach ($key in $limits.Keys) { if ($limits[$key] -lt 1) { throw 'Character, queue and history limits must be at least 1.' } }
        $userLimit = [int]$PerUserQueueLimitBox.Text
        $ageLimit = [double]$MessageAgeBox.Text
        $duplicateLimit = [double]$DuplicateWindowBox.Text
        if ($userLimit -lt 0 -or $ageLimit -lt 0 -or $duplicateLimit -lt 0) { throw 'Queue limits cannot be negative.' }
        Set-JsonProperty $s 'per_user_queue_limit' $userLimit
        Set-JsonProperty $s 'max_message_age' $ageLimit
        Set-JsonProperty $s 'duplicate_window' $duplicateLimit
        Set-JsonProperty $s 'stream_volume' ([double]$StreamVolumeSlider.Value)
        Set-JsonProperty $s 'preview_volume' ([double]$PreviewVolumeSlider.Value)
        Set-JsonProperty $s 'normalize_audio' ([bool]$NormalizeAudioCheck.IsChecked)
        Set-JsonProperty $s 'fade_audio' ([bool]$FadeAudioCheck.IsChecked)
        Set-JsonProperty $s 'persist_queue' ([bool]$PersistQueueCheck.IsChecked)
        Set-JsonProperty $s 'check_updates_on_startup' ([bool]$CheckUpdatesOnStartupCheck.IsChecked)
        Set-JsonProperty $s 'windows_voices_enabled' ([bool]$WindowsVoicesCheck.IsChecked)
        Set-ObsSettings $s
        Set-JsonProperty $s 'http_port' $http
        Set-JsonProperty $s 'voice_save_folder' $VoiceSaveFolderBox.Text.Trim()
        Set-JsonProperty $s 'max_characters' ([int]$MaxCharactersSettingBox.Text)
        Set-JsonProperty $s 'max_queue' ([int]$MaxQueueSettingBox.Text)
        Set-JsonProperty $s 'history_limit' ([int]$HistoryLimitBox.Text)
        Set-JsonProperty $s 'minimize_to_tray' ([bool]$MinimizeToTrayCheck.IsChecked)
        $script:minimizeToTray = [bool]$MinimizeToTrayCheck.IsChecked
        $device = [string]$OutputDeviceBox.SelectedItem
        $preview = [string]$PreviewDeviceBox.SelectedItem
        Set-JsonProperty $s 'output_device' $(if ($device -eq '[Default]') { '' } else { $device })
        Set-JsonProperty $s 'preview_output_device' $(if ($preview -in @('[Same as stream output]','[Default]')) { if ($preview -eq '[Default]') { '[Default]' } else { '' } } else { $preview })
        Write-Settings $s
        $MaxQueueBox.Text = $MaxQueueSettingBox.Text
        Sync-TrayIconMode
        $BottomStatus.Text = 'Settings saved. Restart after changing the HTTP port.'
    } catch { $BottomStatus.Text = $_.Exception.Message }
})
$MinimizeToTrayCheck.Add_Checked({
    if ($script:loadingSettings) { return }
    $script:minimizeToTray = $true
    try { $s = Read-Settings; Set-JsonProperty $s 'minimize_to_tray' $true; Write-Settings $s } catch {}
    Sync-TrayIconMode
})
$MinimizeToTrayCheck.Add_Unchecked({
    if ($script:loadingSettings) { return }
    $script:minimizeToTray = $false
    try { $s = Read-Settings; Set-JsonProperty $s 'minimize_to_tray' $false; Write-Settings $s } catch {}
    if (-not $script:hiddenInTray) { Sync-TrayIconMode }
})
$script:stateTimer = [Windows.Threading.DispatcherTimer]::new()
$PauseAfterQueueButton.Add_Click({ try { Invoke-BridgePost '/pause-after-current' | Out-Null; Refresh-ServiceState } catch { $BottomStatus.Text = $_.Exception.Message } })
$QueueGrid.AllowDrop = $true
$QueueGrid.Add_PreviewMouseLeftButtonDown({param($sender,$e) $script:queueDragPoint=$e.GetPosition($QueueGrid)})
$QueueGrid.Add_MouseMove({
    param($sender,$e)
    if ($e.LeftButton -ne 'Pressed' -or -not $QueueGrid.SelectedItem -or -not $script:queueDragPoint -or $script:queueDragging) { return }
    $point=$e.GetPosition($QueueGrid)
    if ([Math]::Abs($point.X-$script:queueDragPoint.X) -lt 6 -and [Math]::Abs($point.Y-$script:queueDragPoint.Y) -lt 6) { return }
    $script:queueDragging=$true
    try {
        $data=[Windows.DataObject]::new('VoxRelay.SpeechId',[string]$QueueGrid.SelectedItem.Id)
        [Windows.DragDrop]::DoDragDrop($QueueGrid,$data,[Windows.DragDropEffects]::Move) | Out-Null
    } finally { $script:queueDragging=$false;$script:queueDragPoint=$null }
})
$QueueGrid.Add_Drop({
    param($sender,$e)
    if (-not $e.Data.GetDataPresent('VoxRelay.SpeechId')) { return }
    $container=[Windows.Controls.ItemsControl]::ContainerFromElement($QueueGrid,[Windows.DependencyObject]$e.OriginalSource)
    if ($container -is [Windows.Controls.DataGridRow]) {
        try { Invoke-BridgePost '/api/queue/reorder' @{speechId=[string]$e.Data.GetData('VoxRelay.SpeechId');beforeId=[string]$container.Item.Id} | Out-Null }
        catch { $BottomStatus.Text=$_.Exception.Message }
    }
    $e.Handled=$true
})
$ClearAllQueueButton.Add_Click({ try { Invoke-BridgePost '/clear-all' | Out-Null; Refresh-ServiceState } catch { $BottomStatus.Text = $_.Exception.Message } })


$SavePageButton.Add_Click({
    switch([string]$SavePageButton.Tag){
        'settings'{$SaveButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
        'rules'{Save-Rules}
        'streamerbot'{Save-StreamerBotSettings}
        'voicestudio'{Save-VoiceStudioSettings}
        'polly'{Save-PollySettings}
  'elevenlabs'{Save-ElevenLabsSettings}
  'azure'{Save-AzureSettings}
  'google'{Save-GoogleSettings}
  'watson'{Save-WatsonSettings}
  'uberduck'{Save-UberDuckSettings}
  'ttsmonster'{Save-TtsMonsterSettings}
  'acapela'{Save-AcapelaSettings}
  'cereproc'{Save-CereProcSettings}
    }
})
$ExportStreamerBotButton.Add_Click({
    try {
        $s=Read-Settings
        if([int]$UdpBox.Text -ne [int]$s.udp_port){throw 'Save Streamer.bot settings before exporting actions.'}
        $result=Invoke-BridgePost '/api/maintenance/streamerbot-export' @{alias=[string]$ExportVoiceAliasBox.SelectedItem}
        $BottomStatus.Text='Ready to import: '+$result.result.path
    } catch {$BottomStatus.Text=$_.Exception.Message}
})
$EventTestBox.SelectedIndex=0
$SimulateEventButton.Add_Click({
    try{Invoke-BridgePost '/api/integrations/streamerbot/test' @{state=[string]$EventTestBox.SelectedItem.Tag} | Out-Null;Refresh-Activity;$BottomStatus.Text='Test event sent. The live queue was not changed.'}catch{$BottomStatus.Text=$_.Exception.Message}
})
function Create-WindowsDefaultAlias {
    $key=@($script:profiles.Keys | Where-Object { $_.StartsWith('windows|') } | Sort-Object)[0]
    if(-not $key){$BottomStatus.Text='No Windows voices found. Install a Windows speech voice or connect another engine.';return}
    $s=Read-Settings
    if($s.aliases.PSObject.Properties.Name -notcontains 'Windows voice'){
        Save-Alias $null ([pscustomobject]@{Name='Windows voice';Provider='windows';VoiceId=$key.Split('|',2)[1];Model='sapi';Speed=1;Volume=1;Group='';Language='';Instruct='';OutputDevice=''})
    }
    Set-Page 'voices';$BottomStatus.Text='Windows voice is ready. Select it and choose Test voice.'
}
function Set-ObsSettings($settings) {
    Set-JsonProperty $settings 'obs_ducking_enabled' ([bool]$ObsDuckingCheck.IsChecked)
    Set-JsonProperty $settings 'obs_url' $ObsUrlBox.Text.Trim()
    Set-JsonProperty $settings 'obs_input' $ObsInputBox.Text.Trim()
    Set-JsonProperty $settings 'obs_duck_volume' ([double]$ObsDuckVolumeSlider.Value)
    if($ObsPasswordBox.Password){Set-JsonProperty $settings 'obs_password_encrypted' (Protect-VoxRelaySecret $ObsPasswordBox.Password)}
}
$TestObsButton.Add_Click({
    try {
        $s=Read-Settings;Set-ObsSettings $s;Write-Settings $s;$ObsPasswordBox.Password=''
        $selected=$ObsInputBox.Text
        $result=(Invoke-BridgePost '/api/maintenance/obs-inputs').result
        $ObsInputBox.ItemsSource=@($result.inputs | ForEach-Object {$_.inputName} | Sort-Object)
        $ObsInputBox.Text=$selected;$BottomStatus.Text='OBS connected. Choose the audio input to lower.'
    } catch {$BottomStatus.Text=$_.Exception.Message}
})
$TestStreamOutputButton.Add_Click({ try { Invoke-BridgePost '/api/output/test' @{device=[string]$OutputDeviceBox.SelectedItem} | Out-Null;$BottomStatus.Text='Output test queued' } catch { $BottomStatus.Text=$_.Exception.Message } })
$TestPreviewOutputButton.Add_Click({
    $device=[string]$PreviewDeviceBox.SelectedItem
    if($device -eq '[Same as stream output]'){$device=[string]$OutputDeviceBox.SelectedItem}
    try { Invoke-BridgePost '/api/output/test' @{device=$device;preview=$true} | Out-Null;$BottomStatus.Text='Preview test queued' } catch { $BottomStatus.Text=$_.Exception.Message }
})

$SetupWindowsButton.Add_Click({
    $s = Read-Settings
    Set-JsonProperty $s 'windows_voices_enabled' $true
    Write-Settings $s
    $WindowsVoicesCheck.IsChecked = $true
    Set-ServicesExpanded $true
    Set-Page 'settings'
    if (@($script:profiles.Keys | Where-Object { $_.StartsWith('windows|') }).Count) {
        Create-WindowsDefaultAlias
    } else {
        $script:setupWindowsPending = $true
        Refresh-Voices
    }
    $BottomStatus.Text = 'Windows voices enabled. Continue with audio output or add a voice.'
})
$SetupVoiceStudioButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'voicestudio' })
$SetupPollyButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'polly' })
$SetupElevenLabsButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'elevenlabs' })
$SetupAzureButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'azure' })
$SetupGoogleButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'google' })
$SetupWatsonButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'watson' })
$SetupUberDuckButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'uberduck' })
$SetupTtsMonsterButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'ttsmonster' })
$SetupAcapelaButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'acapela' })
$SetupCereProcButton.Add_Click({ Set-ServicesExpanded $true; Set-Page 'cereproc' })

$SetupOutputButton.Add_Click({ $OutputDeviceBox.BringIntoView(); $OutputDeviceBox.Focus(); $OutputDeviceBox.IsDropDownOpen = $true })
$SetupVoiceButton.Add_Click({ Set-Page 'voices'; $v = Show-AliasDialog $null; if ($v) { Save-Alias $null $v } })
$SetupStreamerBotButton.Add_Click({ Set-Page 'streamerbot' })
function Save-RouteEditor([bool]$replace) {
    if (-not $RouteValueBox.Text.Trim() -or -not $RouteAliasBox.SelectedItem) { $BottomStatus.Text = 'Enter a match and choose a voice.'; return }
    $rule = [pscustomobject]@{field=[string]$RouteFieldBox.SelectedItem.Tag;value=$RouteValueBox.Text.Trim();alias=[string]$RouteAliasBox.SelectedItem;priority=[int]$RoutePrioritySlider.Value;enabled=$true}
    $index = $RoutingGrid.SelectedIndex
    if ($replace) { if ($index -lt 0) { $BottomStatus.Text = 'Select a routing rule to update.'; return }; $RoutingGrid.ItemsSource[$index] = $rule }
    else { $RoutingGrid.ItemsSource.Add($rule) }
    $BottomStatus.Text = 'Routing changed. Save rules to apply.'
}

function Get-VoiceRuleDraft([switch]$RequireSelection) {
    $fieldItem = $VoiceRuleFieldBox.SelectedItem
    $field = if ($fieldItem -and $fieldItem.Tag) { [string]$fieldItem.Tag } else { 'user' }
    $value = $VoiceRuleValueBox.Text.Trim()
    $alias = [string]$VoiceRuleAliasBox.SelectedItem
    if (-not $value -or -not $alias) { throw 'Enter a match and choose a voice.' }
    return [pscustomobject]@{ field=$field; value=$value; alias=$alias }
}
function Find-VoiceRuleIndex([string]$field, [string]$value) {
    $items = @($VoiceRulesGrid.ItemsSource)
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string]$items[$i].field -eq $field -and [string]$items[$i].value -eq $value) { return $i }
        if ([string]$items[$i].field -eq $field -and ([string]$items[$i].value).Equals($value, [StringComparison]::OrdinalIgnoreCase)) { return $i }
    }
    return -1
}
function Upsert-VoiceRule([switch]$Replace) {
    try {
        $rule = Get-VoiceRuleDraft
        $index = Find-VoiceRuleIndex $rule.field $rule.value
        if ($Replace) {
            if ($VoiceRulesGrid.SelectedIndex -lt 0) { $BottomStatus.Text = 'Select a voice rule to update.'; return }
            $sel = $VoiceRulesGrid.SelectedItem
            # Allow renaming match: remove old key conflict if another row owns new match
            if ($index -ge 0 -and $index -ne $VoiceRulesGrid.SelectedIndex) { $BottomStatus.Text = 'Another entry already matches that viewer or role.'; return }
            $VoiceRulesGrid.ItemsSource[$VoiceRulesGrid.SelectedIndex] = $rule
        } else {
            if ($index -ge 0) { $BottomStatus.Text = 'That viewer or role already has a voice. Select it and use Update.'; return }
            $VoiceRulesGrid.ItemsSource.Add($rule)
        }
        $BottomStatus.Text = 'Voice rule changed. Save rules to apply.'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
$AddVoiceRuleButton.Add_Click({ Upsert-VoiceRule })
$UpdateVoiceRuleButton.Add_Click({ Upsert-VoiceRule -Replace })
$RemoveVoiceRuleButton.Add_Click({
    $index = $VoiceRulesGrid.SelectedIndex
    if ($index -ge 0) { $VoiceRulesGrid.ItemsSource.RemoveAt($index); $BottomStatus.Text = 'Voice rule removed. Save rules to apply.' }
})
$TestVoiceRuleButton.Add_Click({
    $row = $VoiceRulesGrid.SelectedItem
    if (-not $row) { $BottomStatus.Text = 'Select a voice rule to test.'; return }
    $text = Show-TestDialog ([string]$row.alias)
    if ($text) { Speak-Text ([string]$row.alias) $text 'Test' }
})
$VoiceRulesGrid.Add_SelectionChanged({
    $rule = $VoiceRulesGrid.SelectedItem
    if (-not $rule) { return }
    foreach ($item in $VoiceRuleFieldBox.Items) {
        if ($item.Tag -eq $rule.field) { $VoiceRuleFieldBox.SelectedItem = $item; break }
    }
    $VoiceRuleValueBox.Text = [string]$rule.value
    if ($VoiceRuleAliasBox.Items -contains [string]$rule.alias) { $VoiceRuleAliasBox.SelectedItem = [string]$rule.alias }
})

$AddRouteButton.Add_Click({ Save-RouteEditor $false })
$UpdateRouteButton.Add_Click({ Save-RouteEditor $true })
$RemoveRouteButton.Add_Click({ $index=$RoutingGrid.SelectedIndex;if($index -ge 0){$RoutingGrid.ItemsSource.RemoveAt($index)} })
$RouteUpButton.Add_Click({ $index=$RoutingGrid.SelectedIndex;if($index -gt 0){$RoutingGrid.ItemsSource.Move($index,$index-1);$RoutingGrid.SelectedIndex=$index-1} })
$RouteDownButton.Add_Click({ $index=$RoutingGrid.SelectedIndex;if($index -ge 0 -and $index -lt $RoutingGrid.Items.Count-1){$RoutingGrid.ItemsSource.Move($index,$index+1);$RoutingGrid.SelectedIndex=$index+1} })
$RoutingGrid.Add_SelectionChanged({
    $rule=$RoutingGrid.SelectedItem
    if($rule){foreach($item in $RouteFieldBox.Items){if($item.Tag -eq $rule.field){$RouteFieldBox.SelectedItem=$item;break}};$RouteValueBox.Text=$rule.value;$RouteAliasBox.SelectedItem=$rule.alias;$RoutePrioritySlider.Value=[double]$rule.priority}
})
$FinishSetupButton.Add_Click({
    $s = Read-Settings; Set-JsonProperty $s 'setup_completed' $true; Write-Settings $s
    $getStarted = $window.FindName('GetStartedExpander')
    if ($getStarted) { $getStarted.IsExpanded = $false }
    Set-Page 'voices'; $BottomStatus.Text = 'Ready. Add an alias, then use Test voice to check your output.'
})
function Filter-VoiceAliases {
    if (-not $AliasGrid.ItemsSource) { return }
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($AliasGrid.ItemsSource)
    $view.Filter = [Predicate[object]]{
        param($row)
        $query = $AliasSearchBox.Text.Trim()
        $engine = [string]$AliasProviderFilter.SelectedItem
        $matches = -not $query -or (($row.Name + ' ' + $row.Profile + ' ' + $row.Group).IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        return $matches -and ($engine -eq 'All engines' -or -not $engine -or $row.Provider -eq $engine) -and (-not $FavoritesOnlyCheck.IsChecked -or $row.Favorite)
    }
}
$AliasSearchBox.Add_TextChanged({ Filter-VoiceAliases })
$AliasProviderFilter.Add_SelectionChanged({ Filter-VoiceAliases })
$FavoritesOnlyCheck.Add_Checked({ Filter-VoiceAliases })
$FavoritesOnlyCheck.Add_Unchecked({ Filter-VoiceAliases })
$ToggleFavoriteButton.Add_Click({
    $row = $AliasGrid.SelectedItem
    if ($row) {
        $s = Read-Settings; Set-JsonProperty $s.aliases.($row.Name) 'favorite' (-not $row.Favorite)
        Write-Settings $s; Refresh-Grid -VoicesOnly
        $BottomStatus.Text=if($row.Favorite){'Removed from favorites'}else{'Added to favorites'}
    }
})
$AliasGrid.Add_SelectionChanged({
    $row=$AliasGrid.SelectedItem;$ToggleFavoriteButton.IsEnabled=$null -ne $row
    $favLabel=$window.FindName('FavoriteButtonLabel'); if($favLabel){ $favLabel.Text=if($row -and $row.Favorite){'Unfavorite'}else{'Favorite'} } elseif($ToggleFavoriteButton){ $ToggleFavoriteButton.Content=if($row -and $row.Favorite){'Unfavorite'}else{'Favorite'} }
})
function Refresh-BackupList {
    try { $BackupListBox.ItemsSource = @((Invoke-BridgeGet '/api/backups' 2).backups) } catch {}
    try { $ProfilePresetBox.ItemsSource = @((Invoke-BridgeGet '/api/profiles' 2).profiles) } catch {}
}
$SaveProfileButton.Add_Click({
    try{Invoke-BridgePost '/api/maintenance/save-profile' @{name=$ProfilePresetBox.Text.Trim()} | Out-Null;Refresh-BackupList;$BottomStatus.Text='Saved current settings as a profile.'}catch{$BottomStatus.Text=$_.Exception.Message}
})
$LoadProfileButton.Add_Click({
    try{Invoke-BridgePost '/api/profiles/load' @{profile=$ProfilePresetBox.Text.Trim()} | Out-Null;Refresh-Grid;$BottomStatus.Text='Profile loaded. New messages use these settings.'}catch{$BottomStatus.Text=$_.Exception.Message}
})
function Export-Maintenance([string]$action) {
    try {
        $result = Invoke-BridgePost ('/api/maintenance/' + $action)
        $BottomStatus.Text = 'Saved: ' + $result.result.path
        Refresh-BackupList
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
$BackupSettingsButton.Add_Click({ Export-Maintenance 'backup' })
$ExportPresetsButton.Add_Click({ Export-Maintenance 'export' })
$ExportDiagnosticsButton.Add_Click({ Export-Maintenance 'diagnostics' })
$RestoreBackupButton.Add_Click({
    if (-not $BackupListBox.SelectedItem) { $BottomStatus.Text = 'Choose a backup first.'; return }
    try {
        Invoke-BridgePost '/api/maintenance/restore' @{filename=[string]$BackupListBox.SelectedItem} | Out-Null
        Refresh-Grid; Refresh-BackupList
        $BottomStatus.Text = 'Backup restored. Previous settings were backed up. Restart if ports changed.'
    } catch { $BottomStatus.Text = $_.Exception.Message }
})
$ImportPresetsButton.Add_Click({
    $picker = [Microsoft.Win32.OpenFileDialog]::new(); $picker.Filter = 'VoxRelay presets (*.json)|*.json'
    if ($picker.ShowDialog($window)) {
        try {
            $payload = Get-Content -LiteralPath $picker.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            Invoke-BridgePost '/api/maintenance/import' $payload | Out-Null
            Refresh-Grid; Refresh-BackupList
            $BottomStatus.Text = 'Presets imported. Existing settings were backed up.'
        } catch { $BottomStatus.Text = $_.Exception.Message }
    }
})
function Show-ImportPreview($preview) {
    $dialog = Load-Xaml (Join-Path $appRoot 'ImportPreview.xaml')
    $dialog.Owner=$window; $dialog.Resources.MergedDictionaries.Add($window.Resources); Apply-AppFont $dialog
    $dialog.MaxHeight=[Windows.SystemParameters]::WorkArea.Height-30
    $dialog.FindName('PreviewNote').Text = [string]$preview.note
    $list=$dialog.FindName('PreviewList')
    $saved=Read-Settings
    foreach($alias in $preview.settings.aliases.PSObject.Properties) {
        $suffix=if($saved.aliases.PSObject.Properties.Name -contains $alias.Name){' (replaces existing)'}else{''}
        [void]$list.Items.Add('Import: '+$alias.Name+' / '+$alias.Value.voice_id+$suffix)
    }
    foreach($skipped in @($preview.skipped)){[void]$list.Items.Add('Skip: '+$skipped.name+' - '+$skipped.reason)}
    $dialog.FindName('PreviewImport').Style=$window.FindResource('PrimaryButton')
    $dialog.FindName('PreviewImport').IsEnabled=$preview.settings.aliases.PSObject.Properties.Count -gt 0
    $dialog.FindName('PreviewTitleBar').Add_MouseLeftButtonDown({$dialog.DragMove()})
    $dialog.FindName('PreviewClose').Add_Click({$dialog.Close()})
    $dialog.FindName('PreviewCancel').Add_Click({$dialog.Close()})
    $dialog.FindName('PreviewImport').Add_Click({$dialog.DialogResult=$true})
    return $dialog.ShowDialog()
}
$MigrateSpeakerBotButton.Add_Click({
    $picker=[Microsoft.Win32.OpenFileDialog]::new();$picker.Filter='Speaker.bot aliases (voicealiases.dat)|voicealiases.dat'
    if($picker.ShowDialog($window)){
        try{
            $source=Get-Content -LiteralPath $picker.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            $preview=(Invoke-BridgePost '/api/maintenance/speakerbot-preview' $source).result
            if(Show-ImportPreview $preview){Invoke-BridgePost '/api/maintenance/import' $preview | Out-Null;Refresh-Grid;Refresh-BackupList;$BottomStatus.Text='Aliases imported. Connect Amazon Polly, then test the imported voices.'}
        }catch{$BottomStatus.Text=$_.Exception.Message}
    }
})
function Start-UpdateCheck([bool]$showResult) {
    if($script:updateTask -and -not$script:updateTask.IsCompleted){return}
    $script:updateShowResult=$showResult;$CheckUpdatesButton.IsEnabled=$false
    $script:updateClient=[Net.WebClient]::new()
    $script:updateTask=$script:updateClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri)+'/api/updates'))
    $script:updateTimer=[Windows.Threading.DispatcherTimer]::new();$script:updateTimer.Interval=[TimeSpan]::FromMilliseconds(150)
    $script:updateTimer.Add_Tick({
        if(-not$script:updateTask.IsCompleted){return}
        $script:updateTimer.Stop()
        try{$result=($script:updateTask.GetAwaiter().GetResult() | ConvertFrom-Json).result;if($script:updateShowResult -or $result.available){$BottomStatus.Text=$result.message}}
        catch{if($script:updateShowResult){$BottomStatus.Text='Update check unavailable. Try again later.'}}
        finally{$CheckUpdatesButton.IsEnabled=$true;$script:updateClient.Dispose()}
    })
    $script:updateTimer.Start()
}
$CheckUpdatesButton.Add_Click({Start-UpdateCheck $true})
$ResetSettingsButton.Add_Click({
    $dialog=Load-Xaml (Join-Path $appRoot 'ImportPreview.xaml');$dialog.Owner=$window;$dialog.Resources.MergedDictionaries.Add($window.Resources);Apply-AppFont $dialog
    $dialog.FindName('PreviewTitle').Text='Reset settings'
    $dialog.FindName('PreviewNote').Text='Reset voices, rules, credentials and preferences to defaults? A backup is created first. History and saved audio are kept. Restart VoxRelay afterward.'
    $dialog.FindName('PreviewList').Visibility='Collapsed'
    $dialog.FindName('PreviewImport').Content='Reset settings';$dialog.FindName('PreviewImport').Style=$window.FindResource('PrimaryButton')
    $dialog.FindName('PreviewTitleBar').Add_MouseLeftButtonDown({$dialog.DragMove()});$dialog.FindName('PreviewClose').Add_Click({$dialog.Close()});$dialog.FindName('PreviewCancel').Add_Click({$dialog.Close()});$dialog.FindName('PreviewImport').Add_Click({$dialog.DialogResult=$true})
    if($dialog.ShowDialog()){
        try { Invoke-BridgePost '/api/maintenance/reset' @{confirmation='RESET'} | Out-Null;Refresh-Grid;Refresh-BackupList;$BottomStatus.Text='Settings reset. Restart VoxRelay to finish.' }
        catch { $BottomStatus.Text=$_.Exception.Message }
    }
})
$script:restoreSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'Local\VoxRelay.Restore')
$script:stateTimer.Interval = [TimeSpan]::FromSeconds(1.5)
$script:stateTimer.Add_Tick({
    if ($script:restoreSignal.WaitOne(0)) { Restore-FromTray }
    if ($QueuePage.Visibility -eq 'Visible' -or $HistoryPage.Visibility -eq 'Visible') { Refresh-ServiceState }
    if ($ActivityPage.Visibility -eq 'Visible') { Refresh-Activity }
})
$script:stateTimer.Start()
$window.Add_Closed({
    $script:stateTimer.Stop()
    if ($script:voiceRefreshTimer) { $script:voiceRefreshTimer.Stop() }
    if ($script:voiceWebClient) { $script:voiceWebClient.Dispose() }
    if ($script:updateTimer) { $script:updateTimer.Stop() }
    if ($script:updateClient) { $script:updateClient.Dispose() }
    $script:restoreSignal.Dispose()
    if ($script:trayEnableTimer) { $script:trayEnableTimer.Stop() }
    Dispose-TrayIcon
    if ($env:VSB_EXTERNAL_BACKEND -ne '1' -and $script:backend -and -not $script:backend.HasExited) { try { $script:backend.Kill() } catch {} }
    $window.Dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background)
})

Set-ServicesExpanded $true
$script:httpPort = Get-HttpPort
$script:allowHideToTray = $false
$window.ShowInTaskbar = $true
$window.WindowState = 'Normal'
Update-BridgeStatus $false
$SideStatus.Text = 'Starting...'
$SideStatus.Foreground = ([Windows.Media.BrushConverter]::new().ConvertFromString('#B9B2C2'))
if ($BottomStatusDot) { $BottomStatusDot.Fill = $SideStatus.Foreground }

try { Refresh-Grid } catch { $BottomStatus.Text = 'Could not load settings: ' + $_.Exception.Message }
Start-Backend

$window.Add_ContentRendered({
    $window.ShowInTaskbar = $true
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Activate()
    $script:allowHideToTray = $true
    Write-TrayLog 'allowHideToTray=true'
    Sync-TrayIconMode
    $window.Dispatcher.BeginInvoke([action]{
        if (Wait-BackendReady 8000) { Update-BridgeStatus $true; $BottomStatus.Text = 'Bridge ready' }
        else { Update-BridgeStatus $false; $BottomStatus.Text = 'Bridge failed to start. Check Activity / bridge.log' }
        try { Refresh-Voices } catch {}
        Refresh-BackupList
        $initial = Read-Settings
        $getStarted = $window.FindName('GetStartedExpander')
        if ($getStarted) { $getStarted.IsExpanded = -not [bool]$initial.setup_completed }
        if ($initial.setup_completed) { Set-Page 'voices' } else { Set-Page 'settings' }
        if ($initial.check_updates_on_startup) { Start-UpdateCheck $false }
    }) | Out-Null
})
$window.Add_StateChanged({
    # When restored from taskbar/tray minimize without our flag, clear hidden state.
    if ($window.WindowState -eq 'Normal' -and $script:hiddenInTray) {
        $script:hiddenInTray = $false
        $window.ShowInTaskbar = $true
    }
})
$window.Show()
[Windows.Threading.Dispatcher]::Run()
