Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName WindowsFormsIntegration
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class YapLoqTaskbarIdentity {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@
$script:isPreview = $env:YAPLOQ_PREVIEW -eq '1'
if (-not $env:YAPLOQ_DATA_DIR -and $env:VOXRELAY_DATA_DIR) { $env:YAPLOQ_DATA_DIR = $env:VOXRELAY_DATA_DIR }
$script:appIdentity = if ($script:isPreview) { 'YapLoq.Preview' } else { 'YapLoq' }
$script:appLabel = if ($script:isPreview) { 'YapLoq Preview' } else { 'YapLoq' }
[void][YapLoqTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID($script:appIdentity + '.Desktop')

# Bundled UI assets live next to this script (_internal when frozen).
# Portable data always lives beside the install root (parent of _internal).
$resourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = $resourceRoot
if ([IO.Path]::GetFileName($resourceRoot) -eq '_internal') {
    $appRoot = Split-Path -Parent $resourceRoot
}

# NotifyIcon requires STA. Relaunch ourselves if needed.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
    $psi.WorkingDirectory = $appRoot
    $psi.UseShellExecute = $false
    if ($env:VSB_EXTERNAL_BACKEND) { $psi.EnvironmentVariables['VSB_EXTERNAL_BACKEND'] = $env:VSB_EXTERNAL_BACKEND }
    if ($env:YAPLOQ_DATA_DIR) { $psi.EnvironmentVariables['YAPLOQ_DATA_DIR'] = $env:YAPLOQ_DATA_DIR }
    [void][System.Diagnostics.Process]::Start($psi)
    exit 0
}
if ($script:isPreview -and -not $env:YAPLOQ_PREVIEW_ROOT) { throw 'Start preview using its dedicated launcher.' }
$configDir = if ($script:isPreview) { Join-Path $env:YAPLOQ_PREVIEW_ROOT 'data-preview' } elseif ($env:YAPLOQ_DATA_DIR) { $env:YAPLOQ_DATA_DIR } else { Join-Path $appRoot 'data' }
# Keep UI + backend on the same portable data folder (beside the app).
$env:YAPLOQ_DATA_DIR = $configDir
$legacyConfigDir = Join-Path $env:LOCALAPPDATA 'VoiceStudioSpeakerBridge'
$legacyAppDir = Join-Path $env:LOCALAPPDATA 'YapLoq'
$legacyBrandDir = Join-Path $env:LOCALAPPDATA 'VoxRelay' # Read-only import compatibility.
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    foreach ($legacyPath in $(if ($script:isPreview) { @() } else { @(
        (Join-Path $legacyConfigDir 'settings.json'),
        (Join-Path $legacyBrandDir 'settings.json'),
        (Join-Path $legacyAppDir 'settings.json')
    ) })) {
        if (Test-Path -LiteralPath $legacyPath) {
            Copy-Item -LiteralPath $legacyPath -Destination (Join-Path $configDir 'settings.json')
            break
        }
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

function Initialize-RoundedChrome {
    if ('YapLoqRoundedChrome' -as [type]) { return }
    Add-Type -ReferencedAssemblies @('PresentationFramework','PresentationCore','WindowsBase','System.Xaml') -TypeDefinition @'
using System;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

public static class YapLoqMotion {
    private static bool initialized;
    public static void Initialize() {
        if (initialized) return;
        initialized = true;
        EventManager.RegisterClassHandler(typeof(Expander), Expander.ExpandedEvent, new RoutedEventHandler(Expanded), true);
        EventManager.RegisterClassHandler(typeof(CheckBox), ToggleButton.CheckedEvent, new RoutedEventHandler(Checked), true);
        EventManager.RegisterClassHandler(typeof(DataGridRow), Selector.SelectedEvent, new RoutedEventHandler(Selected), true);
        EventManager.RegisterClassHandler(typeof(ListBoxItem), Selector.SelectedEvent, new RoutedEventHandler(Selected), true);
        EventManager.RegisterClassHandler(typeof(ComboBoxItem), Selector.SelectedEvent, new RoutedEventHandler(Selected), true);
        EventManager.RegisterClassHandler(typeof(TextBox), Keyboard.GotKeyboardFocusEvent, new KeyboardFocusChangedEventHandler(Focused), true);
        EventManager.RegisterClassHandler(typeof(PasswordBox), Keyboard.GotKeyboardFocusEvent, new KeyboardFocusChangedEventHandler(Focused), true);
        EventManager.RegisterClassHandler(typeof(ToolTip), ToolTip.OpenedEvent, new RoutedEventHandler(Opened), true);
        EventManager.RegisterClassHandler(typeof(ContextMenu), ContextMenu.OpenedEvent, new RoutedEventHandler(Opened), true);
    }
    public static void Reveal(UIElement element, double start, int milliseconds) {
        if (element == null || !SystemParameters.ClientAreaAnimation) return;
        double opacity = (double)element.GetAnimationBaseValue(UIElement.OpacityProperty);
        double from = element.Opacity < opacity ? element.Opacity : opacity*start;
        DoubleAnimation fade = new DoubleAnimation(from, opacity, TimeSpan.FromMilliseconds(milliseconds));
        fade.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
        fade.FillBehavior = FillBehavior.Stop;
        element.BeginAnimation(UIElement.OpacityProperty, fade, HandoffBehavior.SnapshotAndReplace);
    }
    private static UIElement Part(Control control, params string[] names) {
        if (control.Template == null) return null;
        foreach(string name in names) { UIElement element=control.Template.FindName(name,control) as UIElement; if(element!=null) return element; }
        return null;
    }
    private static void Expanded(object sender, RoutedEventArgs args) {
        if (args.OriginalSource != sender) return;
        Reveal(Part((Control)sender,"ExpandedContent"),0.82,140);
    }
    private static void Checked(object sender, RoutedEventArgs args) {
        if (args.OriginalSource == sender) Reveal(Part((Control)sender,"Check"),0.45,110);
    }
    private static void Selected(object sender, RoutedEventArgs args) {
        if (args.OriginalSource == sender) Reveal(Part((Control)sender,"RowShell","ItemShell","Item"),0.7,120);
    }
    private static void Focused(object sender, KeyboardFocusChangedEventArgs args) {
        if (args.NewFocus == sender) Reveal(Part((Control)sender,"Field"),0.9,110);
    }
    private static void Opened(object sender, RoutedEventArgs args) { Reveal(sender as UIElement,0.9,110); }
}

public sealed class YapLoqMarkerPosition : IMultiValueConverter {
    public object Convert(object[] values, Type target, object parameter, CultureInfo culture) {
        if (values.Length < 2 || !(values[0] is double) || !(values[1] is double)) return new Thickness(0);
        double edge = (double)values[0], width = (double)values[1];
        return new Thickness(Math.Max(0, Math.Min(Math.Max(0, width - 8), edge - 4)), 0, 0, 0);
    }
    public object[] ConvertBack(object value, Type[] targets, object parameter, CultureInfo culture) { throw new NotSupportedException(); }
}

public static class YapLoqRoundedChrome {
    private static readonly ConditionalWeakTable<Window, object> windows = new ConditionalWeakTable<Window, object>();
    public static void Attach(Window window) {
        object existing;
        if (windows.TryGetValue(window, out existing)) return;
        windows.Add(window, new object());
        window.Loaded += delegate { Scan(window); };
        window.ContentRendered += delegate { Scan(window); };
        if (window.IsLoaded) Scan(window);
    }
    private static void Scan(DependencyObject node) {
        Border border = node as Border;
        if (border != null) Loaded(border, null);
        System.Windows.Controls.Primitives.Popup popup = node as System.Windows.Controls.Primitives.Popup;
        if (popup != null && popup.Child != null) Scan(popup.Child);
        int count = VisualTreeHelper.GetChildrenCount(node);
        for (int i=0; i<count; i++) Scan(VisualTreeHelper.GetChild(node,i));
    }
    private sealed class State {
        public Rect Bounds = Rect.Empty;
        public CornerRadius Radius;
        public UIElement Child;
        public FrameworkElement ObservedChild;
        public SizeChangedEventHandler ChildSizeHandler;
    }
    private static readonly ConditionalWeakTable<Border, State> states = new ConditionalWeakTable<Border, State>();
    private static bool initialized;
    public static void Initialize() {
        if (initialized) return;
        initialized = true;
        EventManager.RegisterClassHandler(typeof(Border), FrameworkElement.LoadedEvent, new RoutedEventHandler(Loaded), true);
    }
    private static void Loaded(object sender, RoutedEventArgs args) {
        Border border = sender as Border;
        if (border == null) return;
        CornerRadius radius = border.CornerRadius;
        if (border.Child == null || (radius.TopLeft == 0 && radius.TopRight == 0 && radius.BottomLeft == 0 && radius.BottomRight == 0)) return;
        State state;
        if (!states.TryGetValue(border, out state)) {
            state = new State(); states.Add(border, state);
            border.Loaded += Loaded;
            border.SizeChanged += delegate { Update(border, state); };
        }
        Update(border, state);
    }
    private static void Update(Border border, State state) {
        UIElement child = border.Child;
        FrameworkElement sizedChild = child as FrameworkElement;
        if (state.ObservedChild != sizedChild) {
            if (state.ObservedChild != null && state.ChildSizeHandler != null) state.ObservedChild.SizeChanged -= state.ChildSizeHandler;
            state.ObservedChild = sizedChild;
            state.ChildSizeHandler = delegate { Update(border,state); };
            if (sizedChild != null) sizedChild.SizeChanged += state.ChildSizeHandler;
        }
        CornerRadius r = border.CornerRadius;
        if (child == null || border.ActualWidth <= 0 || border.ActualHeight <= 0) return;
        if (r.TopLeft == 0 && r.TopRight == 0 && r.BottomLeft == 0 && r.BottomRight == 0) return;
        try {
            Point origin = child.TranslatePoint(new Point(0,0), border);
            Thickness t = border.BorderThickness;
            Rect bounds = new Rect(t.Left-origin.X, t.Top-origin.Y,
                Math.Max(0, border.ActualWidth-t.Left-t.Right), Math.Max(0, border.ActualHeight-t.Top-t.Bottom));
            if (state.Child == child && state.Bounds == bounds && state.Radius == r) return;
            double limit = Math.Min(bounds.Width, bounds.Height)/2;
            double tl = Math.Min(limit,Math.Max(0,r.TopLeft-Math.Max(t.Left,t.Top)));
            double tr = Math.Min(limit,Math.Max(0,r.TopRight-Math.Max(t.Right,t.Top)));
            double br = Math.Min(limit,Math.Max(0,r.BottomRight-Math.Max(t.Right,t.Bottom)));
            double bl = Math.Min(limit,Math.Max(0,r.BottomLeft-Math.Max(t.Left,t.Bottom)));
            double x=bounds.X, y=bounds.Y, right=bounds.Right, bottom=bounds.Bottom;
            StreamGeometry geometry = new StreamGeometry();
            using(StreamGeometryContext c = geometry.Open()) {
                c.BeginFigure(new Point(x+tl,y),true,true);
                c.LineTo(new Point(right-tr,y),true,false); Arc(c,new Point(right,y+tr),tr);
                c.LineTo(new Point(right,bottom-br),true,false); Arc(c,new Point(right-br,bottom),br);
                c.LineTo(new Point(x+bl,bottom),true,false); Arc(c,new Point(x,bottom-bl),bl);
                c.LineTo(new Point(x,y+tl),true,false); Arc(c,new Point(x+tl,y),tl);
            }
            geometry.Freeze(); child.SetCurrentValue(UIElement.ClipProperty,geometry);
            state.Child=child; state.Bounds=bounds; state.Radius=r;
        } catch (InvalidOperationException) { }
    }
    private static void Arc(StreamGeometryContext c, Point end, double radius) {
        if (radius > 0) c.ArcTo(end,new Size(radius,radius),0,false,SweepDirection.Clockwise,true,false);
        else c.LineTo(end,true,false);
    }
}
'@
    [YapLoqRoundedChrome]::Initialize()
    [YapLoqMotion]::Initialize()
}
Initialize-RoundedChrome

function Load-Xaml([string]$path) {
    # Load via XmlReader so UTF-8 markup is not corrupted by PowerShell's [xml] cast.
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($path, $settings)
    try {
        $loaded = [Windows.Markup.XamlReader]::Load($reader)
        if ($loaded -is [Windows.Window]) { [YapLoqRoundedChrome]::Attach($loaded) }
        return $loaded
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
function Get-DisplayText([string]$text) {
    if ($script:profanityMask -and -not $script:profanityShow.IsChecked) {
        return $script:profanityMask.Replace($text,[Text.RegularExpressions.MatchEvaluator]{param($m) '*' * [Math]::Max(4,$m.Length)})
    }
    return $text
}
function Initialize-AppBranding {
    $iconPath=Join-Path $resourceRoot 'assets\YapLoq.ico'
    if(Test-Path -LiteralPath $iconPath){
        $decoder=[Windows.Media.Imaging.BitmapDecoder]::Create([Uri]::new($iconPath),[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $window.Icon=$decoder.Frames[$decoder.Frames.Count-1]
    }
    $logoPath=Join-Path $resourceRoot 'assets\YapLoq-logo.png'
    if (-not (Test-Path -LiteralPath $logoPath)) { return }
    $logo=[Windows.Media.Imaging.BitmapImage]::new()
    $logo.BeginInit();$logo.CacheOption='OnLoad';$logo.UriSource=[Uri]::new($logoPath);$logo.EndInit();$logo.Freeze()
    foreach($name in @('TitleBrandLogo','SidebarBrandLogo','AboutBrandLogo')) {
        $image=$window.FindName($name)
        if($image){$image.Source=$logo}
    }
}
function Apply-AppFont($target) {
    if ($target -is [Windows.Window]) { [YapLoqRoundedChrome]::Attach($target) }
    if (-not $script:appFontFamily) {
        $fontFolder = [Uri]::new(((Join-Path $resourceRoot 'assets\fonts\Poppins') + [IO.Path]::DirectorySeparatorChar))
        $script:appFontFamily = [Windows.Media.FontFamily]::new($fontFolder, './#Poppins')
    }
    $target.FontFamily = $script:appFontFamily
    $target.Resources['AppFontFamily'] = $script:appFontFamily
    $target.Resources[[Windows.SystemFonts]::MessageFontFamilyKey] = $script:appFontFamily
    Set-ControlAccessibility $target
    if ($target -is [Windows.Window] -and $target -ne $window) {
        # Dialogs use the same rounded control states as the main window.
        foreach ($controlType in @([Windows.Controls.Button],[Windows.Controls.TextBox],[Windows.Controls.PasswordBox],[Windows.Controls.ComboBox],[Windows.Controls.ComboBoxItem],[Windows.Controls.ListBox],[Windows.Controls.ListBoxItem],[Windows.Controls.CheckBox],[Windows.Controls.Slider],[Windows.Controls.Primitives.ScrollBar],[Windows.Controls.Primitives.ResizeGrip],[Windows.Controls.ToolTip],[Windows.Controls.ContextMenu],[Windows.Controls.MenuItem],[Windows.Controls.Separator])) {
            $sharedStyle = $window.TryFindResource($controlType)
            if ($sharedStyle) { $target.Resources[$controlType] = $sharedStyle }
        }
        foreach ($name in @('Save','Speak','PreviewImport')) {
            $primary = $target.FindName($name)
            if ($primary -is [Windows.Controls.Button]) { $primary.Style = $window.FindResource('PrimaryButton') }
        }
        $target.UseLayoutRounding = $true
        $target.SnapsToDevicePixels = $true
        $target.Add_ContentRendered({param($sender,$e) [YapLoqMotion]::Reveal($sender.Content,0.96,130)})
        $target.MaxHeight = [Windows.SystemParameters]::WorkArea.Height - 24
        $target.Icon=$window.Icon
        $target.Add_KeyDown({param($sender,$e) if($e.Key -eq 'Escape'){$sender.Close()}})
    }
}
function Set-PreviewSettings($value) {
    if (-not $script:isPreview) { return }
    @{
        http_address='127.0.0.1';ws_address='127.0.0.1';udp_address='127.0.0.1'
        http_port=17582;ws_port=17581;udp_port=16670;enable_udp=$false
        streamerbot_actions_enabled=$false;obs_ducking_enabled=$false
        persist_queue=$false;check_updates_on_startup=$false
    }.GetEnumerator() | ForEach-Object { $value | Add-Member -NotePropertyName $_.Key -NotePropertyValue $_.Value -Force }
}

function Ensure-SettingsFile {
    if (Test-Path -LiteralPath $configPath) { return }
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null | Out-Null
    $legacyPath = Join-Path $legacyConfigDir 'settings.json'
    if (-not $script:isPreview -and (Test-Path -LiteralPath $legacyPath)) {
        Copy-Item -LiteralPath $legacyPath -Destination $configPath -Force
        return
    }
    # Seed a minimal file so the UI never binds against a missing config.
    @{
        voice_studio_url='http://127.0.0.1:3900'; api_key='local'; request_timeout=120
        voicestudio_enabled=$true
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
        Set-PreviewSettings $value
        return $value
    }
    catch {
        $backup = $configPath + '.bak'
        if (Test-Path -LiteralPath $backup) {
            $restored = Get-Content -LiteralPath $backup -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if($restored -isnot [pscustomobject]){throw 'Backup must be an object'}
            $script:settingsRecovered=$true
            if ($BottomStatus) { $BottomStatus.Text = 'Recovered settings from backup. Save to repair the settings file.' }
            Set-PreviewSettings $restored
            return $restored
        }
        throw 'Settings could not be loaded. Restore a backup from Settings.'
    }
}
function Write-Settings($value) {
    Ensure-SettingsFile
    Set-PreviewSettings $value
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
function Protect-YapLoqSecret([string]$value) {
    if ([string]::IsNullOrEmpty($value)) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}
function Get-HttpPort {
    if ($script:isPreview) { return 17582 }
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
    # UseShellExecute=false so PYTHONPATH / YAPLOQ_DATA_DIR reach the child.
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $srcPath = Join-Path $appRoot 'src'
    $env:PYTHONPATH = $srcPath
    $env:YAPLOQ_DATA_DIR = $configDir
    try { $psi.EnvironmentVariables['PYTHONPATH'] = $srcPath } catch {}
    try { $psi.Environment['PYTHONPATH'] = $srcPath } catch {}
    try { $psi.EnvironmentVariables['YAPLOQ_DATA_DIR'] = $configDir } catch {}
    try { $psi.Environment['YAPLOQ_DATA_DIR'] = $configDir } catch {}
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

function Install-UiErrorHandling {
    $window.Dispatcher.Add_UnhandledException({
        param($sender,$eventArgs)
        try {
            $errorDetail = $eventArgs.Exception.ToString()
            Add-Content -LiteralPath (Join-Path $configDir 'ui-crashes.log') -Encoding UTF8 -Value ("{0:o} Page={1}{2}{3}" -f [datetime]::UtcNow,$script:activePage,[Environment]::NewLine,$errorDetail)
            $cause = $eventArgs.Exception.GetBaseException()
            if ($cause -is [OutOfMemoryException] -or $cause -is [AccessViolationException] -or $cause -is [StackOverflowException] -or $window.Dispatcher.HasShutdownStarted) { return }
            $eventArgs.Handled = $true
            if ($BottomStatus) { $BottomStatus.Text = 'An interface action failed. Try again; details saved in ui-crashes.log.'; $BottomStatus.Visibility = 'Visible' }
        } catch { }
    })
}
$window = Load-Xaml (Join-Path $resourceRoot 'YapLoq.xaml')
Install-UiErrorHandling
$window.UseLayoutRounding = $true
$window.SnapsToDevicePixels = $true
$window.MinWidth = [Math]::Min(980,[Windows.SystemParameters]::WorkArea.Width-24)
$window.Width = [Math]::Min(1180,[Windows.SystemParameters]::WorkArea.Width-24)
$window.MinHeight = [Math]::Min(640,[Windows.SystemParameters]::WorkArea.Height-24)
$window.Height = [Math]::Min(760,[Windows.SystemParameters]::WorkArea.Height-24)
Apply-AppFont $window
Initialize-AppBranding
# Keep custom scrollbar thumbs as grab-able pills (Track math otherwise shrinks them to ~width).
[System.Windows.EventManager]::RegisterClassHandler(
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
 'AppTitleBar','AppVersionLabel','AboutVersionText','AboutGitHubButton','AboutTwitchButton','AboutYouTubeButton','AboutXButton','AboutInstagramButton','AboutFacebookButton','AboutTikTokButton','AboutDiscordButton','AboutLogoHost','AboutLogoImage','MinimizeButton','MaximizeButton','CloseButton','BridgeStatusButton','ServiceStatusPopup','ServiceStatusList','RefreshButton','PageTitle','PageSubtitle','SideStatus','BottomStatus','NowPlayingBar','NowPlayingTitle','NowPlayingSubtitle','NowPlayingHistoryButton','QuickHistoryPopup','QuickHistoryList','NowPlayingPrevButton','NowPlayingPlayPauseButton','NowPlayingPlayPauseGlyph','NowPlayingNoteHost','NowPlayingLoadingRotate','NowPlayingLoadingGlyph','NowPlayingLoadingHost','NowPlayingSkipButton','NowPlayingProgress','NowPlayingProgressFill','NowPlayingProgressTrack','NowPlayingElapsedText','NowPlayingRemainingText','NowPlayingClearButton','NowPlayingStopClearButton',
 'VoicesNav','PlaygroundNav','QueueNav','HistoryNav','RulesNav','PronunciationNav','ServicesToggle','ServicesChevronPath','ServicesNavPanel',
 'StreamerBotNav','VoiceStudioNav','PollyNav','ElevenLabsNav','AzureNav','GoogleNav','WatsonNav','UberDuckNav','TtsMonsterNav','AcapelaNav','CereProcNav','ActivityNav','SettingsNav',
 'VoicesPage','PlaygroundPage','QueuePage','HistoryPage','RulesPage','PronunciationPage','StreamerBotPage','VoiceStudioPage','PollyPage','ElevenLabsPage','AzurePage','GooglePage','WatsonPage','UberDuckPage','TtsMonsterPage','AcapelaPage','CereProcPage','SettingsPage','ActivityPage',
 'AddButton','EditButton','RemoveButton','TestButton','SaveVoicesButton','AliasGrid','PlayVoiceList','PlaygroundText','PlaySpeedBox','PlayVolumeBox','PlayStyleBox','CharacterCount','PlayButton','PlayStopButton',
 'QueueGrid','PauseQueueButton','ResumeQueueButton','SkipQueueButton','RemoveQueueButton','QueueUpButton','QueueDownButton','ClearQueueButton',
 'HistoryGrid','ReplayHistoryButton','ShowHistoryAudioButton','SaveHistoryAudioButton','ClearHistoryButton','BlockedWordsBox','ReplacementsBox','BlocklistBox','AllowlistBox','PlaylistGrid','AddPlaylistButton','EditPlaylistButton','RemovePlaylistButton','TestPlaylistButton','VoiceRulesGrid','VoiceRuleFieldBox','VoiceRuleValueBox','VoiceRuleAliasBox','AddVoiceRuleButton','UpdateVoiceRuleButton','RemoveVoiceRuleButton','TestVoiceRuleButton','MaxQueueBox','UserCooldownBox','GlobalCooldownBox','BlockLinksCheck','StripLinksCheck','BlockCapsCheck','CollapseRepeatsCheck','IgnoreCommandsCheck','IgnoreMentionsCheck','StripNonAsciiCheck','StripEmojiCheck','BlockAsciiArtCheck','SaveRulesButton',
 'PronunciationGrid','AddPronunciationButton','EditPronunciationButton','RemovePronunciationButton','PronunciationUpButton','PronunciationDownButton','PronunciationVoiceList','TestPronunciationButton','ActivityList',
 'UrlBox','KeyBox','RequestTimeoutBox','VoiceStudioEnabledCheck','VoiceStudioStatus','SaveVoiceStudioButton','TestVoiceStudioButton',
 'PollyEnabledCheck','PollyRegionBox','PollyProfileBox','PollyAccessKeyBox','PollySecretKeyBox','PollyCredentialStatus','SavePollyButton','TestPollyButton','ClearPollyCredentialsButton',
 'ElevenLabsEnabledCheck','ElevenLabsApiKeyBox','ElevenLabsStatus','AzureEnabledCheck','AzureKeyBox','AzureRegionBox','AzureStatus','GoogleEnabledCheck','GoogleApiKeyBox','GoogleServiceAccountBox','GoogleStatus','WatsonEnabledCheck','WatsonApiKeyBox','WatsonServiceUrlBox','WatsonStatus','UberDuckEnabledCheck','UberDuckApiKeyBox','UberDuckStatus','TtsMonsterEnabledCheck','TtsMonsterOverlayBox','TtsMonsterTokenBox','TtsMonsterStatus','AcapelaEnabledCheck','AcapelaAccountBox','AcapelaPasswordBox','AcapelaAppNameBox','AcapelaStatus','CereProcEnabledCheck','CereProcUsernameBox','CereProcPasswordBox','CereProcStatus',
 'SaveElevenLabsButton','TestElevenLabsButton','ClearElevenLabsButton','SaveAzureButton','TestAzureButton','ClearAzureButton','SaveGoogleButton','TestGoogleButton','ClearGoogleButton','SaveWatsonButton','TestWatsonButton','ClearWatsonButton','SaveUberDuckButton','TestUberDuckButton','ClearUberDuckButton','SaveTtsMonsterButton','TestTtsMonsterButton','ClearTtsMonsterButton','SaveAcapelaButton','TestAcapelaButton','ClearAcapelaButton','SaveCereProcButton','TestCereProcButton','ClearCereProcButton',
 'UdpBox','HttpBox','WsBox','EnableUdpCheck','OutputDeviceBox','PreviewDeviceBox','VoiceSaveFolderBox','BrowseVoiceFolderButton','MaxCharactersSettingBox','MaxQueueSettingBox','HistoryLimitBox','StreamerPayloadBox',
 'EnableStreamerBotActionsCheck','StreamerBotHttpUrlBox','StreamerBotQueuedActionBox','StreamerBotQueueAddedActionBox','StreamerBotPlayingActionBox','StreamerBotFinishedActionBox','StreamerBotPlaybackDelaySlider','StreamerBotPlaybackDelayValue','StreamerBotFinishedDelaySlider','StreamerBotFinishedDelayValue',
 'TestStreamerBotQueuedButton','TestStreamerBotQueueAddedButton','TestStreamerBotPlayingButton','TestStreamerBotFinishedButton','SaveStreamerBotButton','QueueControlCommandBox','QueueControlPayloadBox','QueueControlHint','CopyQueueControlButton','TestQueueControlButton','SaveButton','CopyPayloadButton','TestConnectionButton','MinimizeToTrayCheck','BottomStatusDot'
)
$controlNames | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
$NowPlayingSeekThumb = $window.FindName('NowPlayingSeekThumb')
if ($NowPlayingSeekThumb) {
    $markerBinding = [Windows.Data.MultiBinding]::new()
    $markerBinding.Converter = [YapLoqMarkerPosition]::new()
    $edgeBinding = [Windows.Data.Binding]::new('ActualWidth'); $edgeBinding.Source = $NowPlayingProgressFill
    $trackBinding = [Windows.Data.Binding]::new('ActualWidth'); $trackBinding.Source = $NowPlayingProgressTrack
    [void]$markerBinding.Bindings.Add($edgeBinding); [void]$markerBinding.Bindings.Add($trackBinding)
    [void][Windows.Data.BindingOperations]::SetBinding($NowPlayingSeekThumb,[Windows.FrameworkElement]::MarginProperty,$markerBinding)
}
$extraControls = @('PauseAfterQueueButton','ClearAllQueueButton','StreamVolumeSlider','PreviewVolumeSlider','NormalizeAudioCheck','FadeAudioCheck','PerUserQueueLimitBox','MessageAgeBox','DuplicateWindowBox','SetupWindowsButton','SetupVoiceStudioButton','SetupPollyButton','SetupElevenLabsButton','SetupAzureButton','SetupGoogleButton','SetupWatsonButton','SetupUberDuckButton','SetupTtsMonsterButton','SetupAcapelaButton','SetupCereProcButton','SetupOutputButton','SetupVoiceButton','SetupStreamerBotButton','BackupSettingsButton','ExportPresetsButton','ImportPresetsButton','ExportDiagnosticsButton','BackupListBox','RestoreBackupButton')
$extraControls | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
@('AliasSearchBox','AliasProviderFilter','FavoritesOnlyCheck','ToggleFavoriteButton','PersistQueueCheck','FinishSetupButton') | ForEach-Object { Set-Variable -Name $_ -Value $window.FindName($_) }
# Inset scrolling content so the rounded outline never cuts into scrollbar thumbs.
@('AliasGridHost','QueueGridHost','HistoryGridHost') | ForEach-Object {
    $hostBorder = $window.FindName($_)
    if ($hostBorder) {
        $hostBorder.Padding = [Windows.Thickness]::new(4)
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

function Get-YapLoqVersion {
    foreach ($candidate in @(
        (Join-Path $appRoot 'src\voice_studio_speaker_bridge\__init__.py'),
        (Join-Path $resourceRoot 'src\voice_studio_speaker_bridge\__init__.py'),
        (Join-Path (Split-Path -Parent $appRoot) 'YapLoq-src\src\voice_studio_speaker_bridge\__init__.py')
    )) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $match = Select-String -LiteralPath $candidate -Pattern '__version__\s*=\s*"([^"]+)"' | Select-Object -First 1
        if ($match) { return [string]$match.Matches[0].Groups[1].Value }
    }
    return '0.5.0'
}
$script:appVersion = Get-YapLoqVersion
if ($AppVersionLabel) { $AppVersionLabel.Text = $script:appVersion }
if ($AboutVersionText) { $AboutVersionText.Text = 'Developer' }

function Install-AboutLogo {
    $target = $AboutLogoImage
    if (-not $target) { return }

    $png = Join-Path $resourceRoot 'assets\redgear-logo.png'
    $gif = Join-Path $resourceRoot 'assets\redgear-logo.gif'
    $path = $(if (Test-Path -LiteralPath $png) { $png } elseif (Test-Path -LiteralPath $gif) { $gif } else { $null })
    if (-not $path) { return }

    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        $ms = [IO.MemoryStream]::new($bytes)
        $bmp = [Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = $ms
        $bmp.EndInit()
        $bmp.Freeze()
        $ms.Dispose()
        $target.Source = $bmp
        $target.Stretch = [Windows.Media.Stretch]::Uniform
    } catch {
        try { ("logo load failed: " + $_.Exception.Message + "`n" + $path) | Out-File -LiteralPath (Join-Path $configDir 'logo-error.txt') -Encoding utf8 } catch {}
    }
}
Install-AboutLogo

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

function New-EaseOut {
    $ease = [Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
    return $ease
}
function Ensure-TranslateTransform($element) {
    if (-not $element) { return $null }
    $current = $element.RenderTransform
    if ($current -is [Windows.Media.TranslateTransform]) { return $current }
    if ($current -is [Windows.Media.TransformGroup] -and $current.Children.Count -gt 0 -and $current.Children[0] -is [Windows.Media.TranslateTransform]) {
        return $current.Children[0]
    }
    $translate = [Windows.Media.TranslateTransform]::new(0, 0)
    $element.RenderTransform = $translate
    if (-not $element.RenderTransformOrigin -or ($element.RenderTransformOrigin.X -eq 0 -and $element.RenderTransformOrigin.Y -eq 0)) {
        $element.RenderTransformOrigin = [Windows.Point]::new(0, 0)
    }
    return $translate
}
function Animate-Opacity($element, [double]$from, [double]$to, [int]$ms, [bool]$forever = $false) {
    if (-not $element) { return }
    $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $anim = [Windows.Media.Animation.DoubleAnimation]::new($from, $to, [TimeSpan]::FromMilliseconds($ms))
    $anim.EasingFunction = New-EaseOut
    if ($forever) {
        $anim.AutoReverse = $true
        $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    }
    $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim)
}
function Animate-In($element) {
    if (-not $element) { return }
    if (-not [Windows.SystemParameters]::ClientAreaAnimation) { return }
    $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $translate = Ensure-TranslateTransform $element
    if ($translate) { $translate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null) }
    $ease = New-EaseOut
    $fade = [Windows.Media.Animation.DoubleAnimation]::new($(if($script:isPreview){0.82}else{0.94}), 1.0, [TimeSpan]::FromMilliseconds($(if($script:isPreview){160}else{130})))
    $fade.EasingFunction = $ease
    $element.Opacity = 1
    $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    if ($translate) {
        $slide = [Windows.Media.Animation.DoubleAnimation]::new($(if($script:isPreview){8.0}else{4.0}), 0.0, [TimeSpan]::FromMilliseconds($(if($script:isPreview){180}else{150})))
        $slide.EasingFunction = $ease
        $translate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    }
}
function Resolve-VoxDocsPath([string]$relative) {
    foreach ($root in @($appRoot, $resourceRoot)) {
        $candidate = Join-Path $root $relative
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}
function Open-VoxLink([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    try {
        if ($target.StartsWith('docs:', [StringComparison]::OrdinalIgnoreCase)) {
            $path = Resolve-VoxDocsPath ('docs\' + $target.Substring(5))
            if (-not $path) { throw "Could not find $target" }
            Start-Process -FilePath $path | Out-Null
        } else {
            Start-Process $target | Out-Null
        }
        $BottomStatus.Text = 'Opened help link'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function New-ServiceLinkButton([string]$label, [string]$target) {
    $btn = [Windows.Controls.Button]::new()
    $btn.Content = $label
    $btn.Tag = $target
    $btn.Margin = [Windows.Thickness]::new(0, 0, 10, 8)
    $btn.Padding = [Windows.Thickness]::new(12, 0, 12, 0)
    $btn.MinHeight = 34
    $btn.Cursor = [Windows.Input.Cursors]::Hand
    $btn.ToolTip = $target
    $btn.Add_Click({
        param($sender, $e)
        Open-VoxLink ([string]$sender.Tag)
    })
    return $btn
}
function New-ServiceGuideCard([string]$title, [string[]]$steps, $links) {
    $card = [Windows.Controls.Border]::new()
    $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#E6282231')
    $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#B6A3FF')
    $card.BorderThickness = [Windows.Thickness]::new(1)
    $card.CornerRadius = [Windows.CornerRadius]::new(12)
    $card.Padding = [Windows.Thickness]::new(14)
    $card.Margin = [Windows.Thickness]::new(0, 0, 0, 14)
    $card.Tag = 'ServiceGuideCard'

    $expander = [Windows.Controls.Expander]::new()
    $expander.Header = $title
    $expander.IsExpanded = $false
    $expander.HorizontalContentAlignment = 'Stretch'
    $expander.FontSize = 15
    [Windows.Automation.AutomationProperties]::SetName($expander, $title)

    $stack = [Windows.Controls.StackPanel]::new()
    $heading = [Windows.Controls.TextBlock]::new()
    $heading.Text = $title
    $heading.FontSize = 15
    $heading.FontWeight = [Windows.FontWeights]::SemiBold
    $heading.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F6F3FA')
    $stack.Margin = [Windows.Thickness]::new(22, 10, 0, 0)

    $intro = [Windows.Controls.TextBlock]::new()
    $intro.Text = if ($title -like 'Streamer.bot*') { 'Start with speech. Playback actions for avatars or scenes are optional and use a separate connection.' } else { 'Expand this guide whenever you need help. Your connection fields stay below it.' }
    $intro.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#B9B2C2')
    $intro.TextWrapping = 'Wrap'
    $intro.Margin = [Windows.Thickness]::new(0, 4, 0, 10)
    $intro.FontSize = 12
    [void]$stack.Children.Add($intro)

    $n = 1
    foreach ($step in @($steps)) {
        if ([string]::IsNullOrWhiteSpace($step)) { continue }
        $line = [Windows.Controls.TextBlock]::new()
        $line.Text = "$n. $step"
        $line.TextWrapping = 'Wrap'
        $line.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F6F3FA')
        $line.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
        $line.LineHeight = 21
        $line.FontSize = 13
        [void]$stack.Children.Add($line)
        $n++
    }

    if (@($links).Count -gt 0) {
        $linkLabel = [Windows.Controls.TextBlock]::new()
        $linkLabel.Text = 'Helpful links'
        $linkLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#B9B2C2')
        $linkLabel.Margin = [Windows.Thickness]::new(0, 8, 0, 8)
        $linkLabel.FontSize = 12
        $linkLabel.FontWeight = [Windows.FontWeights]::SemiBold
        [void]$stack.Children.Add($linkLabel)

        $linkRow = [Windows.Controls.WrapPanel]::new()
        foreach ($link in @($links)) {
            if (-not $link) { continue }
            [void]$linkRow.Children.Add((New-ServiceLinkButton $link.Label $link.Url))
        }
        [void]$stack.Children.Add($linkRow)
    }

    $expander.Content = $stack
    $card.Child = $expander
    return $card
}
function Add-StreamerBotGuideDetails($hostPanel) {
    $sections = [ordered]@{
        'Message sources: chat, !tts commands, and rewards' = @(
            'Twitch chat: use Twitch > Chat > Chat Message on YapLoq - Speak. Keep %message% on line 3 of its UDP Broadcast sub-action.',
            '!tts command: create a command named !tts with the Start match option. Add Core > Commands > Command Triggered to YapLoq - Speak and select that command. Change line 3 of the UDP payload to %rawInput% so !tts Hello speaks Hello.',
            'Channel points: create a reward with User Input Required enabled. Add its Twitch reward-redemption trigger to YapLoq - Speak. Change line 3 to %rawInput%.',
            'Use a separate copy of Speak for different message sources. Test with the actual chat command or redemption; a manual test does not automatically provide chat variables.'
        )
        'Optional: make an avatar or scene react to playback' = @(
            'This is YapLoq sending actions back to Streamer.bot. It is separate from incoming speech and is not needed to hear TTS.',
            'In Streamer.bot, open Servers/Clients > HTTP Server. Start it, enable Auto Start, and note its host and port. The usual local address is http://127.0.0.1:7474.',
            'Create Streamer.bot actions for the effects you want, such as Avatar Show and Avatar Hide. In YapLoq, enable playback actions, enter that HTTP address, and put the exact action names in the matching fields. Save, then use each Test button.',
            'Queued runs when the first audio is ready. Playing runs when the queue first starts speaking. Finished runs when the queue ends, after the end delay. Added while speaking handles another message joining an active session.',
            'For an avatar: put Avatar Show in Queued, set Delay before playback to give it time to appear, and put Avatar Hide in Finished. Use Delay after playback to keep it visible briefly afterward.'
        )
        'Troubleshooting: find where the message stops' = @(
            'Nothing appears in YapLoq Queue: check that the Streamer.bot action and trigger are enabled, the UDP listener is enabled in YapLoq, and the UDP Broadcast port matches YapLoq. Restart YapLoq after changing listener settings.',
            'The words %message% or %rawInput% are spoken: the trigger did not supply that variable. Use the matching message source above, or add a message argument to the Core > Test trigger.',
            'The queue advances but there is no sound: test the alias directly in Voices and check Settings > Audio output. A cloud engine may also need credentials or credits.',
            'Speech works but avatar actions do not: check Streamer.bot HTTP Server is running, the HTTP address matches it, playback actions are enabled, and action names match exactly. Port 7474 is for callbacks; the UDP port (usually 6670) is for incoming speech.',
            'A line is spoken twice: check for overlapping chat and command triggers, two UDP Broadcast sub-actions, or a second TTS action attached to the same event.'
        )
        'Manual setup and what the ports mean' = @(
            'The import is the easiest route. If building an action yourself, add Core > Network > UDP Broadcast in Streamer.bot, use YapLoq''s UDP port, and paste the speech payload from this page. Keep each payload field on its own line.',
            'You do not need to start Streamer.bot''s UDP server to send UDP Broadcast messages to YapLoq. You do not need a WebSocket connection for this setup either.',
            'The WebSocket port belongs to YapLoq and is only for custom integrations. The HTTP address on this page belongs to Streamer.bot and is only used for optional playback actions.',
            'The imported Pause, Resume, Skip, and Clear actions can use hotkeys, buttons, or commands. Remove item and Move item need a real %ttsId% argument; they do not select a row in YapLoq automatically.'
        )
    }
    foreach ($title in $sections.Keys) {
        $section = [Windows.Controls.Expander]::new()
        $section.Header = $title
        $section.IsExpanded = $false
        $section.Margin = [Windows.Thickness]::new(0,8,0,0)
        $section.FontSize = 13
        $body = [Windows.Controls.StackPanel]::new()
        $body.Margin = [Windows.Thickness]::new(22,10,0,0)
        foreach ($text in $sections[$title]) {
            $line = [Windows.Controls.TextBlock]::new()
            $line.Text = $text; $line.TextWrapping = 'Wrap'; $line.LineHeight = 21
            $line.Margin = [Windows.Thickness]::new(0,0,0,12)
            $body.Children.Add($line) | Out-Null
        }
        $section.Content = $body
        $hostPanel.Children.Add($section) | Out-Null
    }
}

function Organize-StreamerBotSetup {
    $connection = $UdpBox.Parent.Parent.Parent
    if ($connection.Tag -eq 'StreamerBotSetupOrganized') { return }
    $portGrid = $UdpBox.Parent.Parent
    $websocket = $WsBox.Parent
    $callbacks = $StreamerBotHttpUrlBox.Parent
    [void]$portGrid.Children.Remove($websocket)
    [void]$portGrid.Children.Remove($callbacks)
    [Windows.Controls.Grid]::SetColumn($websocket,0)
    [Windows.Controls.Grid]::SetColumn($callbacks,0)
    $portGrid.ColumnDefinitions.Clear()
    [void]$portGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $UdpBox.Parent.MaxWidth = 220
    $UdpBox.Parent.HorizontalAlignment = 'Left'
    $UdpBox.MinWidth = 200
    $callbackHost = $EnableStreamerBotActionsCheck.Parent
    $callbacks.Margin = [Windows.Thickness]::new(0,14,0,0)
    $callbacks.MaxWidth = 420
    $callbacks.HorizontalAlignment = 'Left'
    $StreamerBotHttpUrlBox.MinWidth = 300
    $callbackHost.Children.Insert(3,$callbacks)

    $manual = [Windows.Controls.StackPanel]::new()
    $manual.Margin = [Windows.Thickness]::new(22,10,0,0)
    $websocket.MaxWidth = 220
    $websocket.HorizontalAlignment = 'Left'
    $manual.Children.Add($websocket) | Out-Null
    $index = $connection.Children.IndexOf($StreamerPayloadBox) - 1
    $move = @($connection.Children[$index],$StreamerPayloadBox,$connection.Children[$index+2],$CopyPayloadButton)
    foreach ($element in $move) { [void]$connection.Children.Remove($element); $manual.Children.Add($element) | Out-Null }
    $advanced = [Windows.Controls.Expander]::new()
    $advanced.Header = 'Manual payload and advanced connection'
    $advanced.IsExpanded = $false
    $advanced.Margin = [Windows.Thickness]::new(0,16,0,0)
    $advanced.Content = $manual
    $connection.Children.Add($advanced) | Out-Null
    $connection.Tag = 'StreamerBotSetupOrganized'
}

function Install-ServiceGuides {
    Organize-StreamerBotSetup
    $guides = [ordered]@{
        streamerbot = @{
            Page = $StreamerBotPage
            Title = 'Streamer.bot setup - start here'
            Steps = @(
                'Check your voice first. In Voices, add an alias and use Test voice. Continue once you can hear it.',
                'Allow incoming speech below: check Listen for Streamer.bot UDP speak requests, leave UDP port at 6670 unless another app uses it, and click Save connection. Restart YapLoq if you changed the port or enabled the listener.',
                'In Send speech from Streamer.bot below, choose your voice and click Export actions (.sb). YapLoq copies the import code and also saves a file.',
                'In Streamer.bot, click Import on the top toolbar. Paste the copied code into Import String (or drag the .sb file into that box), review the YapLoq actions, and click Import. The actions do not run until you give them a trigger.',
                'For a first test, select YapLoq - Speak in Streamer.bot. Add a Core > Test trigger with a message argument such as Hello from Streamer.bot. Right-click that trigger and choose Test Trigger. Watch YapLoq Queue and listen for your chosen voice.',
                'Choose what should speak. For Twitch chat, add Twitch > Chat > Chat Message to YapLoq - Speak; it provides %message%. For a !tts command or channel-point reward, expand Message sources below for the correct text variable. Add only the trigger you want.'
            )
            Links = @(
                @{ Label = 'Import instructions'; Url = 'https://docs.streamer.bot/guide/core/import-export' }
                @{ Label = 'YapLoq Streamer.bot guide'; Url = 'docs:STREAMERBOT.md' }
                @{ Label = 'User guide'; Url = 'docs:USER_GUIDE.md' }
            )
        }
        voicestudio = @{
            Page = $VoiceStudioPage
            Title = 'VoiceStudio quick setup'
            Steps = @(
                'Start VoiceStudio locally and confirm its HTTP API is listening.',
                'Turn Enabled on, paste the base URL (often http://127.0.0.1:3900 or :7860) and optional API key.',
                'Save, then Test connection. Refresh Voices and add an alias on the Voices page.'
            )
            Links = @(
                @{ Label = 'User guide (providers)'; Url = 'docs:USER_GUIDE.md' }
                @{ Label = 'Provider notes'; Url = 'docs:PROVIDERS.md' }
            )
        }
        polly = @{
            Page = $PollyPage
            Title = 'Amazon Polly quick setup'
            Steps = @(
                'In AWS IAM, create an access key for a user/role that can call Amazon Polly.',
                'Paste Access Key ID + Secret below (session token only if using temporary credentials).',
                'Pick the AWS region where Polly is enabled, turn Enabled on, then Save and Test & load voices.'
            )
            Links = @(
                @{ Label = 'Create AWS access keys'; Url = 'https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html' }
                @{ Label = 'Amazon Polly console'; Url = 'https://console.aws.amazon.com/polly/home' }
                @{ Label = 'IAM console'; Url = 'https://console.aws.amazon.com/iam/home#/security_credentials' }
            )
        }
        elevenlabs = @{
            Page = $ElevenLabsPage
            Title = 'ElevenLabs quick setup'
            Steps = @(
                'Sign in at ElevenLabs and open your profile API key settings.',
                'Copy an API key, paste it below, enable the service, then Save and Test & load voices.',
                'Create a Voices alias that points at an ElevenLabs voice_id from the refreshed list.'
            )
            Links = @(
                @{ Label = 'ElevenLabs API keys'; Url = 'https://elevenlabs.io/app/settings/api-keys' }
                @{ Label = 'ElevenLabs docs'; Url = 'https://elevenlabs.io/docs/api-reference/introduction' }
            )
        }
        azure = @{
            Page = $AzurePage
            Title = 'Azure Speech quick setup'
            Steps = @(
                'In Azure Portal, create a Speech resource (Cognitive Services / AI Services).',
                'Copy the subscription key and region (for example eastus) into the fields below.',
                'Enable, Save, then Test & load voices and add a Voices alias.'
            )
            Links = @(
                @{ Label = 'Create Speech resource'; Url = 'https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices' }
                @{ Label = 'Azure Speech docs'; Url = 'https://learn.microsoft.com/azure/ai-services/speech-service/overview' }
                @{ Label = 'Azure Portal'; Url = 'https://portal.azure.com/' }
            )
        }
        google = @{
            Page = $GooglePage
            Title = 'Google Cloud TTS quick setup'
            Steps = @(
                'In Google Cloud Console, enable the Cloud Text-to-Speech API for your project.',
                'Create an API key or service-account JSON, then paste the values YapLoq asks for below.',
                'Enable, Save, Test & load voices, then add a Voices alias.'
            )
            Links = @(
                @{ Label = 'Enable Text-to-Speech API'; Url = 'https://console.cloud.google.com/apis/library/texttospeech.googleapis.com' }
                @{ Label = 'API credentials'; Url = 'https://console.cloud.google.com/apis/credentials' }
                @{ Label = 'Cloud TTS docs'; Url = 'https://cloud.google.com/text-to-speech/docs' }
            )
        }
        watson = @{
            Page = $WatsonPage
            Title = 'IBM Watson TTS quick setup'
            Steps = @(
                'Create an IBM Cloud Text to Speech service instance and open its credentials.',
                'Copy the API key and service URL into the fields below.',
                'Enable, Save, Test & load voices, then add a Voices alias.'
            )
            Links = @(
                @{ Label = 'IBM Text to Speech'; Url = 'https://cloud.ibm.com/catalog/services/text-to-speech' }
                @{ Label = 'Watson TTS docs'; Url = 'https://cloud.ibm.com/docs/text-to-speech' }
            )
        }
        uberduck = @{
            Page = $UberDuckPage
            Title = 'UberDuck quick setup'
            Steps = @(
                'Create an UberDuck account and generate an API key from the dashboard.',
                'Paste the key below, enable the service, Save, then Test & load voices.',
                'Add a Voices alias for the UberDuck voice you want in chat.'
            )
            Links = @(
                @{ Label = 'UberDuck'; Url = 'https://uberduck.ai/' }
                @{ Label = 'UberDuck API docs'; Url = 'https://docs.uberduck.ai/' }
            )
        }
        ttsmonster = @{
            Page = $TtsMonsterPage
            Title = 'TTS.Monster quick setup'
            Steps = @(
                'Sign in to TTS.Monster and open your overlay / developer token settings.',
                'Paste the overlay URL and token YapLoq asks for below.',
                'Enable, Save, Test & load voices, then create a Voices alias.'
            )
            Links = @(
                @{ Label = 'TTS.Monster'; Url = 'https://tts.monster/' }
                @{ Label = 'TTS.Monster dashboard'; Url = 'https://tts.monster/dashboard' }
            )
        }
        acapela = @{
            Page = $AcapelaPage
            Title = 'Acapela quick setup'
            Steps = @(
                'Get Acapela account credentials (and app name if your plan requires it).',
                'Enter them below, enable the service, Save, then Test & load voices.',
                'Add a Voices alias pointing at an Acapela voice from the list.'
            )
            Links = @(
                @{ Label = 'Acapela Group'; Url = 'https://www.acapela-group.com/' }
                @{ Label = 'Acapela Cloud'; Url = 'https://acapela-box.com/' }
            )
        }
        cereproc = @{
            Page = $CereProcPage
            Title = 'CereProc quick setup'
            Steps = @(
                'Create a CereProc account and note your username/password for the API.',
                'Enter credentials below, enable the service, Save, then Test & load voices.',
                'Add a Voices alias for the CereProc voice you want to use.'
            )
            Links = @(
                @{ Label = 'CereProc'; Url = 'https://www.cereproc.com/' }
                @{ Label = 'CereVoice Cloud'; Url = 'https://www.cereproc.com/en/products/cloud' }
            )
        }
    }

    foreach ($key in $guides.Keys) {
        $guide = $guides[$key]
        $page = $guide.Page
        if (-not $page) { continue }
        $hostPanel = $page.Content
        if ($hostPanel -isnot [Windows.Controls.Panel]) { continue }
        # Avoid double-insert on hot reload.
        $existing = @($hostPanel.Children | Where-Object { $_.Tag -eq 'ServiceGuideCard' })
        foreach ($old in $existing) { [void]$hostPanel.Children.Remove($old) }
        $card = New-ServiceGuideCard $guide.Title $guide.Steps $guide.Links
        if ($key -eq 'streamerbot') { Add-StreamerBotGuideDetails $card.Child.Content }
        $hostPanel.Children.Insert(0, $card)
        if ($key -eq 'streamerbot') {
            $exportCard = $window.FindName('StreamerExportCard')
            if ($exportCard) { [void]$hostPanel.Children.Remove($exportCard); $hostPanel.Children.Insert(2,$exportCard) }
        }
    }
}
try { Install-ServiceGuides } catch { if ($BottomStatus) { $BottomStatus.Text = 'Could not load service setup tips: ' + $_.Exception.Message } }
function Animate-PageHeading {
    $hostPanel = $window.FindName('PageHeadingHost')
    if (-not $hostPanel) { return }
    Animate-In $hostPanel
}
function Start-AmbientMotion {
    if ($script:ambientMotionStarted) { return }
    $script:ambientMotionStarted = $true
    $glowA = $window.FindName('AmbientGlowA')
    $glowB = $window.FindName('AmbientGlowB')
    if ($glowA) {
        Animate-Opacity $glowA 0.55 0.95 5200 $true
        $t = Ensure-TranslateTransform $glowA
        if ($t) {
            $drift = [Windows.Media.Animation.DoubleAnimation]::new(-18.0, 18.0, [TimeSpan]::FromSeconds(14))
            $drift.AutoReverse = $true
            $drift.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $t.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $drift)
        }
    }
    if ($glowB) {
        Animate-Opacity $glowB 0.4 0.85 6800 $true
        $t = Ensure-TranslateTransform $glowB
        if ($t) {
            $drift = [Windows.Media.Animation.DoubleAnimation]::new(14.0, -14.0, [TimeSpan]::FromSeconds(17))
            $drift.AutoReverse = $true
            $drift.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $t.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $drift)
        }
    }
}
function Set-StatusPulse([bool]$online, [string]$target = 'connection') {
    $ring = $window.FindName('SideStatusPulseRing')
    $core = $window.FindName('SideStatusPulseCore')
    $dot = $BottomStatusDot
    if (-not $script:pulseStates) { $script:pulseStates = @{} }
    $elements = if ($target -eq 'playback') { @($dot) } else { @($ring) }
    foreach ($el in $elements) {
        if (-not $el) { continue }
        if ($script:pulseStates.ContainsKey($el) -and $script:pulseStates[$el] -eq $online) { continue }
        $script:pulseStates[$el] = $online
        $scale = $el.RenderTransform
        if ($scale -isnot [Windows.Media.ScaleTransform]) {
            $scale = [Windows.Media.ScaleTransform]::new(1, 1)
            $el.RenderTransform = $scale
            $el.RenderTransformOrigin = [Windows.Point]::new(0.5, 0.5)
        }
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        if ($online) {
            $pulse = [Windows.Media.Animation.DoubleAnimation]::new(1.0, 1.35, [TimeSpan]::FromMilliseconds(1100))
            $pulse.AutoReverse = $true
            $pulse.EasingFunction = [Windows.Media.Animation.SineEase]::new()
            $pulse.EasingFunction.EasingMode = 'EaseInOut'
            $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $pulse)
            $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $pulse)
            Animate-Opacity $el 0.55 1.0 1100 $true
        } else {
            $scale.ScaleX = 1
            $scale.ScaleY = 1
            $el.Opacity = 1
        }
    }
    if ($target -ne 'playback' -and $core -and (-not $script:pulseStates.ContainsKey($core) -or $script:pulseStates[$core] -ne $online)) {
        $script:pulseStates[$core] = $online
        $core.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        if ($online) { Animate-Opacity $core 0.7 1.0 1100 $true } else { $core.Opacity = 1 }
    }
}

function Set-ServicesExpanded([bool]$expanded) {
    $script:servicesExpanded = $expanded
    $ServicesNavPanel.Visibility = if ($expanded) { 'Visible' } else { 'Collapsed' }
    # Geometry chevron avoids Unicode encoding issues in the nav label.
    $ServicesChevronPath.Data = [Windows.Media.Geometry]::Parse($(if ($expanded) { 'M3,5 L13,5 L8,11 Z' } else { 'M5,3 L11,8 L5,13 Z' }))
}

function Get-StatusBrush([string]$state) {
    $brush = [Windows.Media.BrushConverter]::new()
    switch ($state) {
        'ok' { return $brush.ConvertFromString('#4ADE80') }
        'warn' { return $brush.ConvertFromString('#FACC15') }
        default { return $brush.ConvertFromString('#F472B6') }
    }
}
function Get-ServicePageMap {
    return @{
        bridge = 'settings'
        streamerbot = 'streamerbot'
        voicestudio = 'voicestudio'
        windows = 'settings'
        polly = 'polly'
        elevenlabs = 'elevenlabs'
        azure = 'azure'
        google = 'google'
        watson = 'watson'
        uberduck = 'uberduck'
        ttsmonster = 'ttsmonster'
        acapela = 'acapela'
        cereproc = 'cereproc'
    }
}
function Get-ServiceStatusListPanel {
    if ($script:serviceStatusListRef -is [Windows.Controls.Panel]) { return $script:serviceStatusListRef }
    $popup = $window.FindName('ServiceStatusPopup')
    if (-not $popup) { $popup = $ServiceStatusPopup }
    if (-not $popup -or -not $popup.Child) { return $null }
    $node = $popup.Child
    # Walk: Border -> root StackPanel -> ServiceStatusList host
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($node)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($current -is [Windows.Controls.Panel] -and ([string]$current.Tag -eq 'ServiceStatusListHost' -or [string]$current.Name -eq 'ServiceStatusList')) {
            $script:serviceStatusListRef = $current
            return $current
        }
        if ($current -is [Windows.Controls.Decorator] -and $current.Child) { $queue.Enqueue($current.Child) }
        elseif ($current -is [Windows.Controls.Panel]) {
            foreach ($child in @($current.Children)) { $queue.Enqueue($child) }
        }
    }
    return $null
}
function Build-ServiceHealthRows([bool]$online, $voices, $errors) {
    $rows = New-Object System.Collections.Generic.List[object]
    $voiceProviders = @{}
    foreach ($v in @($voices)) {
        if ($null -eq $v) { continue }
        $key = [string]$v.provider
        if ($key) { $voiceProviders[$key] = $true }
    }
    $failed = @{}
    foreach ($err in @($errors)) {
        if ($null -eq $err) { continue }
        $text = [string]$err
        if ($text -match '^([^:]+):\s*') { $failed[$Matches[1].Trim()] = $true }
    }
    $pages = Get-ServicePageMap
    try { $s = Read-Settings } catch { $s = $null }

    # Core bridge always listed.
    $bridgeState = if ($online) { 'ok' } else { 'bad' }
    [void]$rows.Add([pscustomobject]@{ Id = 'bridge'; Name = 'YapLoq bridge'; State = $bridgeState; Page = 'settings'; Detail = $(if ($online) { 'HTTP / UDP ready' } else { 'Offline' }) })

    # Only enabled integrations / engines.
    $udpOn = $false
    if ($s -and $null -ne $s.enable_udp) { $udpOn = [bool]$s.enable_udp }
    if ($udpOn) {
        $sbState = if ($online) { 'ok' } else { 'bad' }
        [void]$rows.Add([pscustomobject]@{ Id = 'streamerbot'; Name = 'Streamer.bot'; State = $sbState; Page = 'streamerbot'; Detail = 'UDP speak' })
    }

    $providerMeta = @(
        @{ Id = 'voicestudio'; Name = 'VoiceStudio'; EnabledProp = 'voicestudio_enabled' }
        @{ Id = 'windows'; Name = 'Windows voices'; EnabledProp = 'windows_voices_enabled' }
        @{ Id = 'polly'; Name = 'Amazon Polly'; EnabledProp = 'polly_enabled' }
        @{ Id = 'elevenlabs'; Name = 'ElevenLabs'; EnabledProp = 'elevenlabs_enabled' }
        @{ Id = 'azure'; Name = 'Azure Speech'; EnabledProp = 'azure_enabled' }
        @{ Id = 'google'; Name = 'Google Cloud TTS'; EnabledProp = 'google_enabled' }
        @{ Id = 'watson'; Name = 'IBM Watson'; EnabledProp = 'watson_enabled' }
        @{ Id = 'uberduck'; Name = 'UberDuck'; EnabledProp = 'uberduck_enabled' }
        @{ Id = 'ttsmonster'; Name = 'TTS.Monster'; EnabledProp = 'ttsmonster_enabled' }
        @{ Id = 'acapela'; Name = 'Acapela'; EnabledProp = 'acapela_enabled' }
        @{ Id = 'cereproc'; Name = 'CereProc'; EnabledProp = 'cereproc_enabled' }
    )
    foreach ($meta in $providerMeta) {
        $enabled = $false
        if ($s -and $meta.EnabledProp) {
            try {
                $raw = $s.($meta.EnabledProp)
                # Missing key: VoiceStudio/Windows default on; cloud engines default off.
                if ($null -eq $raw) {
                    $enabled = $meta.EnabledProp -in @('voicestudio_enabled','windows_voices_enabled')
                } else { $enabled = [bool]$raw }
            } catch { $enabled = $false }
        }
        if (-not $enabled) { continue }
        $state = 'warn'
        $detail = 'No voices yet'
        if (-not $online) {
            $state = 'bad'
            $detail = 'Bridge offline'
        } elseif ($failed.ContainsKey([string]$meta.Name)) {
            $state = 'bad'
            $detail = 'Check credentials'
        } elseif ($voiceProviders.ContainsKey([string]$meta.Id)) {
            $state = 'ok'
            $detail = 'Voices available'
        }
        $page = [string]$pages[[string]$meta.Id]
        if (-not $page) { $page = 'settings' }
        [void]$rows.Add([pscustomobject]@{ Id = [string]$meta.Id; Name = [string]$meta.Name; State = $state; Page = $page; Detail = $detail })
    }
    return @($rows.ToArray())
}
function Apply-ServiceStatusSummary($rows) {
    $list = @($rows)
    if ($list.Count -eq 0) {
        if ($SideStatus) { $SideStatus.Text = 'No services' }
        return
    }
    $ok = @($list | Where-Object { $_.State -eq 'ok' }).Count
    $bad = @($list | Where-Object { $_.State -eq 'bad' }).Count
    $total = $list.Count
    $summaryState = if ($bad -eq 0 -and $ok -eq $total) { 'ok' } elseif ($ok -eq 0) { 'bad' } else { 'warn' }
    $label = switch ($summaryState) {
        'ok' { 'Connected' }
        'warn' { if ($script:statusFlyout) { 'Partial' } else { 'Partially Connected' } }
        default { 'Disconnected' }
    }
    $text = "$label ($ok/$total)"
    $brush = Get-StatusBrush $summaryState
    if ($SideStatus) {
        $SideStatus.Text = $text
        $SideStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F6F3FA')
    }
    $core = $window.FindName('SideStatusPulseCore')
    $ring = $window.FindName('SideStatusPulseRing')
    if ($core) { $core.Fill = $brush }
    if ($ring) {
        $ring.Fill = switch ($summaryState) {
            'ok' { [Windows.Media.BrushConverter]::new().ConvertFromString('#334ADE80') }
            'warn' { [Windows.Media.BrushConverter]::new().ConvertFromString('#33FACC15') }
            default { [Windows.Media.BrushConverter]::new().ConvertFromString('#33F472B6') }
        }
    }
    try { Set-StatusPulse ($summaryState -ne 'bad') } catch {}
    $script:serviceHealthRows = $list
    $script:serviceHealthSummary = $text
}
function New-ServiceStatusRow($item) {
    $row = [Windows.Controls.Border]::new()
    $row.Background = [Windows.Media.Brushes]::Transparent
    $row.CornerRadius = [Windows.CornerRadius]::new(6)
    $row.Padding = [Windows.Thickness]::new(10, 9, 10, 9)
    $row.Cursor = [Windows.Input.Cursors]::Hand
    $row.Tag = $item
    $row.ToolTip = [string]$item.Detail

    $grid = [Windows.Controls.Grid]::new()
    $colDot = [Windows.Controls.ColumnDefinition]::new(); $colDot.Width = [Windows.GridLength]::new(14)
    $colName = [Windows.Controls.ColumnDefinition]::new(); $colName.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colChevron = [Windows.Controls.ColumnDefinition]::new(); $colChevron.Width = [Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($colDot)
    [void]$grid.ColumnDefinitions.Add($colName)
    [void]$grid.ColumnDefinitions.Add($colChevron)

    $dot = [Windows.Shapes.Ellipse]::new()
    $dot.Width = 8
    $dot.Height = 8
    $dot.Fill = Get-StatusBrush ([string]$item.State)
    $dot.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $dot.IsHitTestVisible = $false
    [Windows.Controls.Grid]::SetColumn($dot, 0)
    [void]$grid.Children.Add($dot)

    $name = [Windows.Controls.TextBlock]::new()
    $name.Text = [string]$item.Name
    $name.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F6F3FA')
    $name.FontSize = 13
    $name.Margin = [Windows.Thickness]::new(10, 0, 8, 0)
    $name.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $name.IsHitTestVisible = $false
    [Windows.Controls.Grid]::SetColumn($name, 1)
    [void]$grid.Children.Add($name)

    $chevron = [Windows.Shapes.Path]::new()
    $chevron.Data = [Windows.Media.Geometry]::Parse('M10 6L8.59 7.41L13.17 12l-4.58 4.59L10 18l6-6z')
    $chevron.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#B9B2C2')
    $chevron.Stretch = [Windows.Media.Stretch]::Uniform
    $chevron.Width = 10
    $chevron.Height = 10
    $chevron.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $chevron.IsHitTestVisible = $false
    [Windows.Controls.Grid]::SetColumn($chevron, 2)
    [void]$grid.Children.Add($chevron)

    $row.Child = $grid
    $row.Add_MouseEnter({
        param($sender, $e)
        $sender.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#33282231')
    })
    $row.Add_MouseLeave({
        param($sender, $e)
        $sender.Background = [Windows.Media.Brushes]::Transparent
    })
    $row.Add_MouseLeftButtonUp({
        param($sender, $e)
        $data = $sender.Tag
        $popup = $window.FindName('ServiceStatusPopup')
        if (-not $popup) { $popup = $ServiceStatusPopup }
        if ($popup) { $popup.IsOpen = $false }
        if ($script:statusFlyout) { Close-YapLoqStatusMenu }
        if ($data -and $data.Page) {
            if ($data.Page -in @('streamerbot','voicestudio','polly','elevenlabs','azure','google','watson','uberduck','ttsmonster','acapela','cereproc')) {
                Set-ServicesExpanded $true
            }
            Set-Page ([string]$data.Page)
        }
        $e.Handled = $true
    })
    return $row
}
function Render-ServiceStatusMenu($rows) {
    $list = Get-ServiceStatusListPanel
    if (-not $list) { throw 'Status list host not found' }
    $list.Children.Clear()
    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        [void]$list.Children.Add((New-ServiceStatusRow $row))
    }
}
function Get-CachedServiceVoices {
    $voices = @()
    if ($script:profiles -and $script:profiles.Count -gt 0) {
        foreach ($key in @($script:profiles.Keys)) {
            $provider = ([string]$key).Split('|')[0]
            if ($provider) { $voices += [pscustomobject]@{ provider = $provider } }
        }
    }
    return $voices
}
function Refresh-ServiceHealth([bool]$probeBridge = $true) {
    $online = [bool]$script:backendOnline
    if ($probeBridge) {
        try {
            Invoke-RestMethod -Uri ((Get-BridgeBaseUri) + '/api/state') -TimeoutSec 1 | Out-Null
            $online = $true
            $script:backendOnline = $true
            $script:backendFailUntil = [datetime]::MinValue
        } catch {
            $online = $false
            $script:backendOnline = $false
        }
    }
    $voices = Get-CachedServiceVoices
    $errors = @($script:lastVoiceErrors)
    $rows = Build-ServiceHealthRows $online $voices $errors
    Apply-ServiceStatusSummary $rows
    return $rows
}
function Show-ServiceStatusMenu($placementTarget) {
    if ($script:statusFlyout) { Show-YapLoqStatusMenu; return }
    $popup = $window.FindName('ServiceStatusPopup')
    if (-not $popup) { $popup = $ServiceStatusPopup }
    if (-not $popup) { return }
    if ($popup.IsOpen -and $placementTarget -and [object]::ReferenceEquals($popup.PlacementTarget, $placementTarget)) {
        $popup.IsOpen = $false
        return
    }
    if ($placementTarget) {
        $popup.PlacementTarget = $placementTarget
        $popup.Placement = [Windows.Controls.Primitives.PlacementMode]::Top
    }
    # Open first so Popup visual tree exists, then fill from cache (no /api/voices stall).
    $popup.IsOpen = $true
    try {
        $rows = Refresh-ServiceHealth $false
        if (-not @($rows).Count) { $rows = Refresh-ServiceHealth $true }
        Render-ServiceStatusMenu $rows
    } catch {
        $list = Get-ServiceStatusListPanel
        if ($list) {
            $list.Children.Clear()
            $err = [Windows.Controls.TextBlock]::new()
            $err.Text = 'Could not build status list'
            $err.Foreground = Get-StatusBrush 'bad'
            $err.Margin = [Windows.Thickness]::new(10, 8, 10, 8)
            $err.TextWrapping = 'Wrap'
            [void]$list.Children.Add($err)
        }
        if ($BottomStatus) { $BottomStatus.Text = 'Status menu: ' + $_.Exception.Message }
    }
    $window.Dispatcher.BeginInvoke([Action]{
        try {
            if (-not $popup.IsOpen) { return }
            $rows = Refresh-ServiceHealth $true
            Render-ServiceStatusMenu $rows
        } catch {}
    }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
}
function Update-BridgeStatus([bool]$online) {
    $script:backendOnline = [bool]$online
    try {
        $voices = Get-CachedServiceVoices
        $errors = @($script:lastVoiceErrors)
        Apply-ServiceStatusSummary (Build-ServiceHealthRows $online $voices $errors)
    } catch {
        if ($SideStatus) { $SideStatus.Text = $(if ($online) { 'Connected' } else { 'Offline' }) }
        try { Set-StatusPulse $online } catch {}
    }
}

function Set-Page([string]$page) {
    if ($script:isPreview -and $page -eq 'voiceRules') { $page = 'rules' }
    if ($script:activePage -eq $page) { return }
    if ($script:isPreview -and $script:changingPage) { Request-YapLoqPage $page; return }
    $previousPage = $script:activePage
    $script:changingPage = $true
    try {
    $pages = @{
        voices=$VoicesPage; playground=$PlaygroundPage; queue=$QueuePage; history=$HistoryPage; rules=$RulesPage; pronunciation=$PronunciationPage;
        streamerbot=$StreamerBotPage; voicestudio=$VoiceStudioPage; polly=$PollyPage; elevenlabs=$ElevenLabsPage; azure=$AzurePage; google=$GooglePage; watson=$WatsonPage; uberduck=$UberDuckPage; ttsmonster=$TtsMonsterPage; acapela=$AcapelaPage; cereproc=$CereProcPage; settings=$SettingsPage; activity=$ActivityPage
    }
    if ($script:yaploqPages) { foreach ($key in $script:yaploqPages.Keys) { $pages[$key] = $script:yaploqPages[$key] } }
    if (-not $pages.ContainsKey($page) -or -not $pages[$page]) { throw "Unknown page: $page" }
    $SavePageButton.Visibility=if($page -in @('settings','rules','pronunciation','streamerbot','voicestudio','polly','elevenlabs','azure','google','watson','uberduck','ttsmonster','acapela','cereproc')){'Visible'}else{'Collapsed'}
    $SavePageButton.Tag=$page
    $script:activePage = $page
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
        streamerbot=@('Streamer.bot','Connect speech, then add optional playback actions.'); voicestudio=@('VoiceStudio','Local TTS connection');
        polly=@('Amazon Polly','Cloud voices'); elevenlabs=@('ElevenLabs','Cloud TTS credentials'); azure=@('Azure Speech','Cloud TTS credentials'); google=@('Google Cloud TTS','Cloud TTS credentials'); watson=@('IBM Watson','Cloud TTS credentials'); uberduck=@('UberDuck','Cloud TTS credentials'); ttsmonster=@('TTS.Monster','Cloud TTS credentials'); acapela=@('Acapela','Cloud TTS credentials'); cereproc=@('CereProc','Cloud TTS credentials'); settings=@('Settings','Ports, devices, and tray');
        activity=@('Activity','Speech events and application log')
    }
    if ($titles.ContainsKey($page)) { $PageTitle.Text = $titles[$page][0]; $PageSubtitle.Text = $titles[$page][1] }
    if ($script:yaploqNav) { Update-YapLoqNavigation $page }
    if ($page -eq 'activity') { Refresh-Activity }
    if ($page -in @('queue','history')) { $script:playerStateNext = 0; $script:playerHistoryNext = 0 }
    Animate-PageHeading
    Animate-In $pages[$page]
    } catch {
        if (-not $script:isPreview) { throw }
        $script:activePage = $previousPage
        if ($pages -and $previousPage -and $pages.ContainsKey($previousPage)) {
            foreach ($key in $pages.Keys) { $pages[$key].Visibility = if ($key -eq $previousPage) {'Visible'} else {'Collapsed'} }
            try { Update-YapLoqNavigation $previousPage } catch {}
        }
        Write-YapLoqUiError $_
    } finally { $script:changingPage = $false }
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
        $enabled = if ($null -eq $a.enabled) { $true } else { [bool]$a.enabled }
        $rows.Add([pscustomobject]@{ Name=$property.Name; Provider=$provider; Profile=$profile; Group=[string]$a.group; Model=$a.model; Speed=$a.speed; VoiceId=$a.voice_id; Volume=$a.volume; Language=$a.language; Instruct=$a.instruct; OutputDevice=[string]$a.output_device; Favorite=[bool]$a.favorite; Enabled=$enabled })
    }
    foreach($row in $rows){
        $accent=Get-VoiceAccent ([string]$settings.aliases.($row.Name).color)
        $resolvedIcon=Resolve-VoiceIcon ([string]$settings.aliases.($row.Name).icon_id) -Color $accent
        $row | Add-Member -NotePropertyName IconId -NotePropertyValue $resolvedIcon.Id -Force
        $row | Add-Member -NotePropertyName IconGeometry -NotePropertyValue $resolvedIcon.Geometry -Force
        $row | Add-Member -NotePropertyName Accent -NotePropertyValue $accent -Force
        $row | Add-Member -NotePropertyName Color -NotePropertyValue $accent -Force
        $row | Add-Member -NotePropertyName IconBrush -NotePropertyValue $(if($resolvedIcon.Brush){$resolvedIcon.Brush}else{[Windows.Media.BrushConverter]::new().ConvertFromString($accent)}) -Force
        $row | Add-Member -NotePropertyName AccentBackground -NotePropertyValue ('#33'+$accent.Substring(1)) -Force
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
    $script:ExportRandomLabel='Random (enabled voices)'
    $playlistLabels = @(Get-PlaylistSpeakLabels $settings)
    $voiceChoices = @($script:ExportRandomLabel) + @($playlistLabels) + @($rows.Name)
    $RouteAliasBox.ItemsSource = @($playlistLabels) + @($rows.Name)
    $VoiceRuleAliasBox.ItemsSource = @($playlistLabels) + @($rows.Name)
    $exportAlias=[string]$ExportVoiceAliasBox.SelectedItem
    $ExportVoiceAliasBox.ItemsSource=$voiceChoices
    if($exportAlias -and $ExportVoiceAliasBox.Items.Contains($exportAlias)){$ExportVoiceAliasBox.SelectedItem=$exportAlias}
    elseif($exportAlias -eq 'random'){$ExportVoiceAliasBox.SelectedItem=$script:ExportRandomLabel}
    elseif($exportAlias -like 'playlist:*'){
        $wanted='Playlist: '+$exportAlias.Substring(9)
        if($ExportVoiceAliasBox.Items.Contains($wanted)){$ExportVoiceAliasBox.SelectedItem=$wanted}
    }
    if($ExportVoiceAliasBox.SelectedIndex -lt 0){$ExportVoiceAliasBox.SelectedIndex=0}
    Refresh-PlaylistGrid $settings
    if ($VoicesOnly) { return }
    $routingRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($rule in @($settings.routing_rules)) { if ($rule) { $routingRows.Add($rule) } }
    $RoutingGrid.ItemsSource = $routingRows
    $RouteFieldBox.SelectedIndex = 0
    $UrlBox.Text = [string]$settings.voice_studio_url
    $KeyBox.Text = [string]$settings.api_key
    $RequestTimeoutBox.Text = [string]$(if ($null -ne $settings.request_timeout) { $settings.request_timeout } else { 120 })
    if ($VoiceStudioEnabledCheck) {
        $VoiceStudioEnabledCheck.IsChecked = $null -eq $settings.voicestudio_enabled -or [bool]$settings.voicestudio_enabled
    }
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
    $AcapelaAppNameBox.Text = [string]$(if ($settings.acapela_application_name) { $settings.acapela_application_name } else { 'YapLoq' })
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
    Load-ProfanityRules $settings
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
    $script:voiceWebClient.Proxy = $null
    $script:voiceRefreshTask = $script:voiceWebClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri) + '/api/voices'))
    $script:voiceDeviceClient = [Net.WebClient]::new()
    $script:voiceDeviceClient.Proxy = $null
    $script:voiceDeviceTask = $script:voiceDeviceClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri) + '/api/devices'))
    $script:voiceDeviceStarted = [datetime]::UtcNow
    $script:voiceRefreshTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:voiceRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:voiceRefreshTimer.Add_Tick({
        if (-not $script:voiceRefreshTask.IsCompleted) { return }
        if (-not $script:voiceDeviceTask.IsCompleted -and ([datetime]::UtcNow - $script:voiceDeviceStarted).TotalSeconds -lt 5) { return }
        $script:voiceRefreshTimer.Stop()
        try {
            $result = $script:voiceRefreshTask.GetAwaiter().GetResult() | ConvertFrom-Json
            $devices = $null
            if ($script:voiceDeviceTask.IsCompleted) { try { $devices = $script:voiceDeviceTask.GetAwaiter().GetResult() | ConvertFrom-Json } catch {} }
            Complete-VoiceRefresh $result $devices
        } catch { $BottomStatus.Text = 'Could not load voices. Check Services and try again.' }
        finally { $script:voiceWebClient.Dispose(); $script:voiceDeviceClient.CancelAsync(); $script:voiceDeviceClient.Dispose(); $RefreshButton.IsEnabled = $true }
    })
    $script:voiceRefreshTimer.Start()
}
function Complete-VoiceRefresh($result, $deviceResult = $null) {
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
        $currentOutput = [string]$OutputDeviceBox.SelectedItem
        $currentPreview = [string]$PreviewDeviceBox.SelectedItem
        $devices = if ($deviceResult) { @($deviceResult.devices | Sort-Object -Unique) } else { @($OutputDeviceBox.Items | Where-Object { $_ -ne '[Default]' }) }
        $OutputDeviceBox.Items.Clear(); $PreviewDeviceBox.Items.Clear()
        [void]$OutputDeviceBox.Items.Add('[Default]')
        [void]$PreviewDeviceBox.Items.Add('[Same as stream output]')
        [void]$PreviewDeviceBox.Items.Add('[Default]')
        try {
            foreach ($device in $devices) {
                [void]$OutputDeviceBox.Items.Add([string]$device)
                [void]$PreviewDeviceBox.Items.Add([string]$device)
            }
        } catch {}
        $selectedDevice = if ($currentOutput) { $currentOutput } elseif ([string]::IsNullOrWhiteSpace([string]$s.output_device)) { '[Default]' } else { [string]$s.output_device }
        if(-not$OutputDeviceBox.Items.Contains($selectedDevice)){[void]$OutputDeviceBox.Items.Add($selectedDevice)}
        $OutputDeviceBox.SelectedItem = $selectedDevice
        if ($OutputDeviceBox.SelectedIndex -lt 0) { $OutputDeviceBox.SelectedIndex = 0 }
        $selectedPreview = if ($currentPreview) { $currentPreview } elseif ([string]::IsNullOrWhiteSpace([string]$s.preview_output_device)) { '[Same as stream output]' } else { [string]$s.preview_output_device }
        if(-not$PreviewDeviceBox.Items.Contains($selectedPreview)){[void]$PreviewDeviceBox.Items.Add($selectedPreview)}
        $PreviewDeviceBox.SelectedItem = $selectedPreview
        if ($PreviewDeviceBox.SelectedIndex -lt 0) { $PreviewDeviceBox.SelectedIndex = 0 }
        $script:backendOnline = $true
        $script:serviceHealthAge = Get-Date
        $script:lastVoiceErrors = @($result.errors)
        try {
            Apply-ServiceStatusSummary (Build-ServiceHealthRows $true @($result.voices) @($script:lastVoiceErrors))
        } catch {
            try { Update-BridgeStatus $true } catch {}
        }
        $message = ($script:profiles.Count.ToString() + ' voices found')
        if (@($script:lastVoiceErrors).Count) { $message += '; ' + (@($script:lastVoiceErrors) -join ' | ') }
        if($script:settingsRecovered){$message += '; Settings recovered from backup. Save to repair.'}
        $BottomStatus.Text = $message
        Refresh-Grid -VoicesOnly
        if($script:setupWindowsPending){$script:setupWindowsPending=$false;Create-WindowsDefaultAlias}
    } catch {
        Update-BridgeStatus $false
        $BottomStatus.Text = 'Bridge offline. Restart YapLoq if this persists.'
    }
}
function Refresh-Activity {
    if ($script:activityTask -and -not $script:activityTask.IsCompleted) { return }
    if ($script:activityTask) { Complete-ActivityRefresh }
    $script:activityClient = [Net.WebClient]::new()
    $script:activityClient.Proxy = $null
    $script:activityStarted = [datetime]::UtcNow
    $script:activityTask = $script:activityClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri) + '/api/events'))
}
function Complete-ActivityRefresh {
    if (-not $script:activityTask -or -not $script:activityTask.IsCompleted) { return }
    try {
        $timeline = ($script:activityTask.GetAwaiter().GetResult() | ConvertFrom-Json).events
        $signature = @($timeline | ForEach-Object { $_.time + $_.event }) -join '|'
        if ($signature -ne $script:lastEventSignature) {
            $EventTimelineGrid.ItemsSource = @($timeline | ForEach-Object { [pscustomobject]@{Time=([datetime]$_.time).ToLocalTime().ToString('HH:mm:ss');Event=$_.source+'.'+$_.event;Alias=$(if($_.data.alias){$_.data.alias}else{$_.data.integration});Id=$_.data.id} })
            $script:lastEventSignature = $signature
        }
    } catch {}
    finally { $script:activityClient.Dispose(); $script:activityTask = $null }
    if (Test-Path -LiteralPath $logPath) {
        $modified = [IO.File]::GetLastWriteTimeUtc($logPath)
        if ($modified -ne $script:activityLogModified) {
            $ActivityList.ItemsSource = @(Get-Content -LiteralPath $logPath -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { Get-DisplayText $_ })
            $script:activityLogModified = $modified
        }
    }
}
$script:glyphPause = 'M6 19h4V5H6zm8-14v14h4V5z'
$script:glyphPlay = 'M8 5v14l11-7z'
$script:glyphMusicNote = 'M12 3v10.55c-.59-.34-1.27-.55-2-.55c-2.21 0-4 1.79-4 4s1.79 4 4 4s4-1.79 4-4V7h4V3h-6z'
$script:glyphLoading = 'M12 3c4.97 0 9 4.03 9 9'
$script:nowPlayingLoading = $false
$script:nowPlayingMode = 'idle'
$script:lastHistorySpeechId = ''
$script:recentHistoryItems = @()


$script:statusFlashUntil = [datetime]::MinValue
$script:lastFlashedStatus = ''
$script:quickHistoryListRef = $null

function Get-QuickHistoryListPanel {
    if ($script:quickHistoryListRef -is [Windows.Controls.Panel]) { return $script:quickHistoryListRef }
    $popup = $window.FindName('QuickHistoryPopup')
    if (-not $popup) { $popup = $QuickHistoryPopup }
    if ($popup -and $popup.Child) {
        $current = $popup.Child
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push($current)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            if ($current -is [Windows.Controls.Panel] -and ([string]$current.Tag -eq 'QuickHistoryListHost' -or [string]$current.Name -eq 'QuickHistoryList')) {
                $script:quickHistoryListRef = $current
                return $current
            }
            if ($current -is [Windows.Controls.Panel]) {
                foreach ($child in @($current.Children)) { $stack.Push($child) }
            } elseif ($current -is [Windows.Controls.Decorator] -and $current.Child) {
                $stack.Push($current.Child)
            } elseif ($current -is [Windows.Controls.ContentControl] -and $current.Content -is [Windows.DependencyObject]) {
                $stack.Push($current.Content)
            }
        }
    }
    if ($QuickHistoryList) { $script:quickHistoryListRef = $QuickHistoryList; return $QuickHistoryList }
    return $null
}

function New-QuickHistoryRow($item) {
    $row = [Windows.Controls.Border]::new()
    $row.Background = [Windows.Media.Brushes]::Transparent
    $row.CornerRadius = [Windows.CornerRadius]::new(6)
    $row.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
    $row.Cursor = [Windows.Input.Cursors]::Hand
    $row.Tag = $item
    $tip = [string]$item.Text
    if (-not $tip) { $tip = [string]$item.Alias }
    $row.ToolTip = $tip

    $grid = [Windows.Controls.Grid]::new()
    $colMain = [Windows.Controls.ColumnDefinition]::new(); $colMain.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $colAction = [Windows.Controls.ColumnDefinition]::new(); $colAction.Width = [Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($colMain)
    [void]$grid.ColumnDefinitions.Add($colAction)

    $stack = [Windows.Controls.StackPanel]::new()
    $title = [Windows.Controls.TextBlock]::new()
    $alias = [string]$item.Alias
    if (-not $alias) { $alias = 'Voice' }
    $status = [string]$item.Status
    $title.Text = if ($status) { "$alias - $status" } else { $alias }
    $title.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F6F3FA')
    $title.FontSize = 13
    $title.FontWeight = [Windows.FontWeights]::SemiBold
    $title.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $title.IsHitTestVisible = $false
    [void]$stack.Children.Add($title)

    $sub = [Windows.Controls.TextBlock]::new()
    $msg = [string]$item.Text
    if ($msg.Length -gt 72) { $msg = $msg.Substring(0, 71) + '…' }
    if (-not $msg) { $msg = [string]$item.Time }
    $sub.Text = $msg
    $sub.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#B9B2C2')
    $sub.FontSize = 11
    $sub.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
    $sub.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $sub.IsHitTestVisible = $false
    [void]$stack.Children.Add($sub)
    [Windows.Controls.Grid]::SetColumn($stack, 0)
    [void]$grid.Children.Add($stack)

    $play = [Windows.Shapes.Path]::new()
    $play.Data = [Windows.Media.Geometry]::Parse('M8 5v14l11-7z')
    $play.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString('#B6A3FF')
    $play.Stretch = [Windows.Media.Stretch]::Uniform
    $play.Width = 11
    $play.Height = 11
    $play.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $play.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
    $play.IsHitTestVisible = $false
    [Windows.Controls.Grid]::SetColumn($play, 1)
    [void]$grid.Children.Add($play)

    $row.Child = $grid
    $row.Add_MouseEnter({
        param($sender, $e)
        $sender.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#33282231')
    })
    $row.Add_MouseLeave({
        param($sender, $e)
        $sender.Background = [Windows.Media.Brushes]::Transparent
    })
    $row.Add_MouseLeftButtonUp({
        param($sender, $e)
        $data = $sender.Tag
        $popup = $window.FindName('QuickHistoryPopup')
        if (-not $popup) { $popup = $QuickHistoryPopup }
        if ($popup) { $popup.IsOpen = $false }
        if ($data -and $data.Id) {
            try {
                Invoke-BridgePost '/api/history/replay' @{ speechId = [string]$data.Id } | Out-Null
                $BottomStatus.Text = 'Queued ' + $(if ($data.Alias) { [string]$data.Alias } else { 'history audio' })
                Refresh-ServiceState
            } catch { $BottomStatus.Text = $_.Exception.Message }
        }
        $e.Handled = $true
    })
    return $row
}

function Render-QuickHistoryMenu($items) {
    $list = Get-QuickHistoryListPanel
    if (-not $list) { throw 'Quick history list host not found' }
    $list.Children.Clear()
    $rows = @($items | Select-Object -First 10)
    if ($rows.Count -eq 0) {
        $empty = [Windows.Controls.TextBlock]::new()
        $empty.Text = 'No recent history yet'
        $empty.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#B9B2C2')
        $empty.Margin = [Windows.Thickness]::new(10, 8, 10, 8)
        [void]$list.Children.Add($empty)
    } else {
        foreach ($row in $rows) {
            if ($null -eq $row) { continue }
            [void]$list.Children.Add((New-QuickHistoryRow $row))
        }
    }
    $footer = [Windows.Controls.Border]::new()
    $footer.Background = [Windows.Media.Brushes]::Transparent
    $footer.CornerRadius = [Windows.CornerRadius]::new(6)
    $footer.Padding = [Windows.Thickness]::new(10, 10, 10, 8)
    $footer.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
    $footer.Cursor = [Windows.Input.Cursors]::Hand
    $footerText = [Windows.Controls.TextBlock]::new()
    $footerText.Text = 'Open History page'
    $footerText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#C9BCFF')
    $footerText.FontSize = 12
    $footerText.FontWeight = [Windows.FontWeights]::SemiBold
    $footerText.IsHitTestVisible = $false
    $footer.Child = $footerText
    $footer.Add_MouseEnter({ param($s,$e) $s.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#33282231') })
    $footer.Add_MouseLeave({ param($s,$e) $s.Background = [Windows.Media.Brushes]::Transparent })
    $footer.Add_MouseLeftButtonUp({
        param($s, $e)
        $popup = $window.FindName('QuickHistoryPopup')
        if (-not $popup) { $popup = $QuickHistoryPopup }
        if ($popup) { $popup.IsOpen = $false }
        Set-Page 'history'
        $e.Handled = $true
    })
    [void]$list.Children.Add($footer)
}

function Show-QuickHistoryMenu {
    $popup = $window.FindName('QuickHistoryPopup')
    if (-not $popup) { $popup = $QuickHistoryPopup }
    if (-not $popup -or -not $NowPlayingHistoryButton) { return }
    if ($popup.IsOpen) {
        $popup.IsOpen = $false
        return
    }
    $popup.PlacementTarget = $NowPlayingHistoryButton
    $popup.Placement = [Windows.Controls.Primitives.PlacementMode]::Top
    $popup.IsOpen = $true
    try {
        $items = @($script:recentHistoryItems)
        if ($items.Count -eq 0) {
            try {
                $history = (Invoke-BridgeGet '/api/history' 1).result.history
                $items = @($history | Select-Object -First 10 | ForEach-Object {
                    $time = ''
                    try { $time = ([datetime]$_.timestamp).ToLocalTime().ToString('g') } catch { $time = [string]$_.timestamp }
                    [pscustomobject]@{ Id=$_.id; Time=$time; Status=$_.status; Alias=$_.alias; Text=(Get-DisplayText $_.text) }
                })
                $script:recentHistoryItems = $items
            } catch {}
        }
        Render-QuickHistoryMenu $items
    } catch {
        $list = Get-QuickHistoryListPanel
        if ($list) {
            $list.Children.Clear()
            $err = [Windows.Controls.TextBlock]::new()
            $err.Text = 'Could not load history'
            $err.Foreground = Get-StatusBrush 'bad'
            $err.Margin = [Windows.Thickness]::new(10, 8, 10, 8)
            [void]$list.Children.Add($err)
        }
        if ($BottomStatus) { $BottomStatus.Text = 'History menu: ' + $_.Exception.Message }
    }
}


function Start-NowPlayingLoadingSpin {
    # Only start once - Refresh-ServiceState polls often and must not restart the storyboard.
    if ($script:nowPlayingLoading) { return }
    try {
        if ($NowPlayingNoteHost) { $NowPlayingNoteHost.Visibility = 'Collapsed' }
        elseif ($NowPlayingGlyph) { $NowPlayingGlyph.Visibility = 'Collapsed' }
        if ($NowPlayingLoadingHost) { $NowPlayingLoadingHost.Visibility = 'Visible' }
        $rotate = $NowPlayingLoadingRotate
        if (-not $rotate -and $NowPlayingLoadingHost) {
            try { $rotate = $NowPlayingLoadingHost.FindName('NowPlayingLoadingRotate') } catch {}
        }
        if ($rotate -is [Windows.Media.RotateTransform]) {
            $anim = [Windows.Media.Animation.DoubleAnimation]::new(0, 360, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.0)))
            $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $anim)
        }
        $script:nowPlayingLoading = $true
    } catch {
        $script:nowPlayingLoading = $false
    }
}

function Stop-NowPlayingLoadingSpin {
    if (-not $script:nowPlayingLoading) { return }
    try {
        if ($NowPlayingLoadingRotate -is [Windows.Media.RotateTransform]) {
            $NowPlayingLoadingRotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
            $NowPlayingLoadingRotate.Angle = 0
        }
    } catch {}
    try {
        if ($NowPlayingLoadingHost) { $NowPlayingLoadingHost.Visibility = 'Collapsed' }
        if ($NowPlayingNoteHost) { $NowPlayingNoteHost.Visibility = 'Visible' }
        elseif ($NowPlayingGlyph) { $NowPlayingGlyph.Visibility = 'Visible' }
    } catch {}
    $script:nowPlayingLoading = $false
}


function Update-NowPlayingBar($state, $lastHistory) {
    if (-not $NowPlayingTitle) { return }
    $script:lastPlaybackState = $state
    $selectedRecording = Get-HistoryPlaybackTarget
    if (-not $state.current -and $selectedRecording) { $lastHistory = $selectedRecording }
    $incomingKey = if ($state.current) { [string]$state.current.id } else { '' }
    if ($script:progressSeeking) {
        if ($incomingKey -eq $script:seekSpeechKey) { return }
        $script:progressSeeking = $false
        $NowPlayingProgressTrack.ReleaseMouseCapture()
    }
    if ($incomingKey -and $incomingKey -eq $script:progressSpeechKey -and [int]$state.seekRevision -lt [int]$script:progressSeekRevision) { return }
    $seekChanged = ([int]$state.seekRevision -ne [int]$script:progressSeekRevision)
    $script:progressSeekRevision = [int]$state.seekRevision
    $paused = $false
    try { $paused = [bool]$state.paused } catch {}
    $current = $null
    try { $current = $state.current } catch {}
    $waiting = 0
    try { $waiting = [int]$state.queueLength } catch {}

    $jobStatus = ''
    if ($current) {
        try { $jobStatus = [string]$current.status } catch {}
        if (-not $jobStatus) { try { $jobStatus = [string]$current.Status } catch {} }
    }

    # Spinner ONLY while this job is actively generating audio — not Waiting/Queued/Ready.
    $isGenerating = ($jobStatus -eq 'Generating')

    # Title = alias. Subtitle = spoken line. No status suffixes.
    if ($current) {
        $alias = ''
        try { $alias = [string]$current.alias } catch {}
        if (-not $alias) { $alias = 'Voice' }
        $msg = ''
        try { $msg = [string]$current.text } catch {}
        $NowPlayingTitle.Text = $alias
        $NowPlayingSubtitle.Text = $(if ($msg) { Get-DisplayText $msg } elseif ($isGenerating) { 'Generating…' } else { '' })
        if ($jobStatus -eq 'Playing') {
            $script:nowPlayingMode = if ($paused) { 'paused' } else { 'playing' }
        } elseif ($isGenerating) {
            $script:nowPlayingMode = 'generating'
        } elseif ($paused) {
            $script:nowPlayingMode = 'paused'
        } else {
            $script:nowPlayingMode = 'ready'
        }
    } elseif ($lastHistory) {
        $alias = ''
        try { $alias = [string]$lastHistory.Alias } catch {}
        if (-not $alias) { try { $alias = [string]$lastHistory.alias } catch {} }
        if (-not $alias) { $alias = 'Voice' }
        $msg = ''
        try { $msg = [string]$lastHistory.Text } catch {}
        if (-not $msg) { try { $msg = [string]$lastHistory.text } catch {} }
        $NowPlayingTitle.Text = $alias
        $NowPlayingSubtitle.Text = $(if ($msg) { Get-DisplayText $msg } else { '' })
        $script:nowPlayingMode = if ($paused) { 'paused' } else { 'idle' }
    } else {
        $NowPlayingTitle.Text = if ($paused) { 'Paused' } else { 'Nothing playing' }
        $NowPlayingSubtitle.Text = if ($waiting -gt 0) { '{0} waiting' -f $waiting } else { 'Queue empty' }
        $script:nowPlayingMode = if ($paused) { 'paused' } else { 'idle' }
    }
    $script:nowPlayingSubtitleText = [string]$NowPlayingSubtitle.Text
    $voiceRow=@($AliasGrid.ItemsSource|Where-Object{$_.Name -eq $NowPlayingTitle.Text})[0]
    $voiceAccent=if($voiceRow){Get-VoiceAccent ([string]$voiceRow.Accent)}else{'#B6A3FF'}
    $spinner=$window.FindName('NowPlayingLoadingGlyph')
    if($spinner){$spinner.Stroke=[Windows.Media.BrushConverter]::new().ConvertFromString($voiceAccent)}
    $glyph=$window.FindName('NowPlayingGlyph')
    if($glyph){
        $glyph.Fill=if($voiceRow){$voiceRow.IconBrush}else{[Windows.Media.BrushConverter]::new().ConvertFromString($voiceAccent)}
        $glyph.Data=if($voiceRow){$voiceRow.IconGeometry}else{(Resolve-VoiceIcon 'mdi:music-note').Geometry}
        $badge=$window.FindName('NowPlayingVoiceBadge')
        if($badge){$badge.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#33'+$voiceAccent.Substring(1));$badge.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString($voiceAccent)}
    }

    # Loading icon
    if ($isGenerating) {
        if (-not $script:nowPlayingLoading) { Start-NowPlayingLoadingSpin }
    } else {
        Stop-NowPlayingLoadingSpin
    }

    # Hide bottom flash over subtitle unless actively flashing
    try {
        $flashText = if ($BottomStatus) { [string]$BottomStatus.Text } else { '' }
        if ($flashText -and [datetime]::UtcNow -lt $script:statusFlashUntil) {
            if ($NowPlayingSubtitle) { $NowPlayingSubtitle.Visibility = 'Collapsed' }
            if ($BottomStatus) { $BottomStatus.Visibility = 'Visible' }
        } else {
            if ($BottomStatus) { $BottomStatus.Visibility = 'Collapsed' }
            if ($NowPlayingSubtitle) { $NowPlayingSubtitle.Visibility = 'Visible' }
        }
    } catch {}

    # Play/pause glyph
    $playPath = $script:glyphPlay
    $playTip = 'Play'
    $playEnabled = $true
    switch ($script:nowPlayingMode) {
        'playing' { $playPath = $script:glyphPause; $playTip = 'Pause' }
        'paused'  { $playPath = $script:glyphPlay;  $playTip = 'Resume' }
        'generating' { $playPath = $script:glyphPause; $playTip = 'Pause queue' }
        'ready' { $playPath = $script:glyphPause; $playTip = 'Pause queue' }
        default {
            if ($selectedRecording) { $playTip = 'Play selected recording' }
            elseif ($script:lastHistorySpeechId) { $playTip = 'Replay last audio' }
            else { $playEnabled = $false; $playTip = 'Nothing to play' }
        }
    }
    try {
        if ($NowPlayingPlayPauseGlyph -and $playPath -and $script:lastPlayerGlyph -ne $playPath) {
            $NowPlayingPlayPauseGlyph.Data = [Windows.Media.Geometry]::Parse([string]$playPath)
            $script:lastPlayerGlyph = $playPath
        }
    } catch {}
    if ($NowPlayingPlayPauseButton) {
        $NowPlayingPlayPauseButton.ToolTip = $playTip
        [Windows.Automation.AutomationProperties]::SetName($NowPlayingPlayPauseButton, $playTip)
        $NowPlayingPlayPauseButton.IsEnabled = $playEnabled
        $NowPlayingPlayPauseButton.Tag = $script:nowPlayingMode
    }

    # Progress
    $durationSec = 0.0
    $bridgeElapsed = 0.0
    try { $durationSec = [double]$state.durationSeconds } catch {}
    try { $bridgeElapsed = [double]$state.elapsedSeconds } catch {}
    if ($durationSec -le 0 -and $current) {
        try { $durationSec = [double]$current.duration / 1000.0 } catch {}
    }

    $currentPlaying = ($jobStatus -eq 'Playing')
    $playingNow = ($currentPlaying -and -not $paused)

    $speechKey = ''
    if ($current) {
        try {
            if ($current.id) { $speechKey = [string]$current.id }
            else { $speechKey = ([string]$current.alias) + '|' + ([string]$current.text) }
        } catch {}
    }
    $trackChanged = ($speechKey -ne [string]$script:progressSpeechKey)
    if ($trackChanged -and -not $current -and $script:progressSpeechKey) { $script:playerHistoryNext = 0 }
    $wasPlaying = [bool]$script:progressPlaying
    $script:progressSpeechKey = $speechKey

    # Every snapshot owns its duration, including zero while the next clip generates.
    $script:progressDurationSec = [Math]::Max(0.0, $durationSec)

    if ($trackChanged) {
        $script:progressAnchorElapsed = 0
        $script:progressAnchorUtc = [datetime]::UtcNow
        Set-NowPlayingProgressVisual 0
    }

    $localElapsed = Get-NowPlayingElapsed
    if ($trackChanged -or $seekChanged -or -not $playingNow -or -not $wasPlaying) {
        $script:progressAnchorElapsed = if ($currentPlaying) { [Math]::Max(0.0, $bridgeElapsed) } else { 0.0 }
        $script:progressCorrection = 0.0
    } else {
        # Preserve the displayed position at each poll, then gently correct clock drift.
        $script:progressAnchorElapsed = $localElapsed
        $script:progressCorrection = [Math]::Max(-0.4, [Math]::Min(0.4, $bridgeElapsed - $localElapsed))
    }
    $script:progressAnchorUtc = [datetime]::UtcNow
    $script:progressAnchorTicks = [Diagnostics.Stopwatch]::GetTimestamp()

    $script:progressPlaying = $playingNow
    $script:canSeekPlayback = ($currentPlaying -and $durationSec -gt 0)
    if ($NowPlayingProgressTrack) { $NowPlayingProgressTrack.IsEnabled = $script:canSeekPlayback }
    if ($NowPlayingSeekThumb) { $NowPlayingSeekThumb.Visibility = if ($script:canSeekPlayback) { 'Visible' } else { 'Collapsed' } }
    if (-not $script:progressSeeking) { Update-NowPlayingProgressUi }

    if ($NowPlayingPrevButton) { $NowPlayingPrevButton.IsEnabled = ([bool]$script:lastHistorySpeechId -and -not $current -and $waiting -eq 0) }
    if ($NowPlayingSkipButton) { $NowPlayingSkipButton.IsEnabled = [bool]$current }
    if ($NowPlayingClearButton) { $NowPlayingClearButton.IsEnabled = ($waiting -gt 0) }
    if ($NowPlayingStopClearButton) { $NowPlayingStopClearButton.IsEnabled = ([bool]$current -or $waiting -gt 0 -or $paused) }

    try {
        $dotBrush = switch ($script:nowPlayingMode) {
            'playing' { '#4ADE80' }
            'paused' { '#FACC15' }
            default { '#B9B2C2' }
        }
        if ($BottomStatusDot) { $BottomStatusDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($dotBrush) }
    } catch {}
    try { Set-StatusPulse ($script:nowPlayingMode -eq 'playing') 'playback' } catch {}
}


function Refresh-ServiceState($Snapshot = $null, [bool]$FromPoll = $false) {
    if (-not $Snapshot) { $script:playerStateNext = 0; $script:playerHistoryNext = 0; return }
    # Do not block the media bar on mouse-down / queue drag — only skip grid mutations.
    $skipGrids = $false
    try {
        if ($script:queueDragging -or [Windows.Input.Mouse]::LeftButton -eq 'Pressed') { $skipGrids = $true }
    } catch {}
    if (-not $script:backendOnline -and [datetime]::UtcNow -lt $script:backendFailUntil) { return }

    $state = $null
    $lastHistory = $null
    try {
        $state = if ($Snapshot) { $Snapshot } else { (Invoke-BridgeGet '/api/state' 1).result }
        $script:backendOnline = $true
    } catch {
        $script:backendOnline = $false
        $script:backendFailUntil = [datetime]::UtcNow.AddSeconds(2)
        return
    }

    # MEDIA BAR FIRST — never gated behind history/queue work.
    try {
        if ($script:recentHistoryItems -and @($script:recentHistoryItems).Count -gt 0) {
            $lastHistory = @($script:recentHistoryItems)[0]
        }
    } catch {}
    try {
        Update-NowPlayingBar $state $lastHistory
        if ($script:yaploqNav) { Update-YapLoqDashboard $state }
    } catch {
        try {
            if ($BottomStatus) { $BottomStatus.Text = 'Player UI: ' + $_.Exception.Message; $BottomStatus.Visibility = 'Visible' }
        } catch {}
    }

    if ($skipGrids) { return }

    try {
        if ($QueueSummaryText) {
            $QueueSummaryText.Text = ('{0} waiting / approx. {1:0}s' -f $state.queueLength,$state.estimatedWaitSeconds) + $(if($state.paused){' / Paused'}else{''})
        }
        if ($state.audioWarning -and $BottomStatus) { $BottomStatus.Text = [string]$state.audioWarning; $BottomStatus.Visibility = 'Visible' }
    } catch {}

    try {
        $selectedQueueId = if ($QueueGrid -and $QueueGrid.SelectedItem) { [string]$QueueGrid.SelectedItem.Id } else { '' }
        $queueRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        if ($state.current) {
            $queueRows.Add([pscustomobject]@{ Id=$state.current.id; Status=$state.current.status; Alias=$state.current.alias; User=$state.current.user; Text=(Get-DisplayText $state.current.text) })
        }
        foreach ($item in @($state.queue)) {
            $queueRows.Add([pscustomobject]@{ Id=$item.id; Status=$item.status; Alias=$item.alias; User=$item.user; Text=(Get-DisplayText $item.text) })
        }
        $queueSignature = ($queueRows | ForEach-Object { '{0}|{1}|{2}' -f $_.Id,$_.Status,$_.Text }) -join ';'
        if ($queueSignature -ne $script:lastQueueSignature) {
            if ($QueueGrid) {
                $QueueGrid.ItemsSource = $queueRows
                if ($selectedQueueId) { $QueueGrid.SelectedItem = @($queueRows | Where-Object { $_.Id -eq $selectedQueueId })[0] }
            }
            $script:lastQueueSignature = $queueSignature
        }
    } catch {}

    if ($FromPoll -and $script:playerHistoryRenderedRevision -eq $script:playerHistoryRevision) { return }
    try {
        $selectedHistoryId = if ($HistoryGrid -and $HistoryGrid.SelectedItem) { [string]$HistoryGrid.SelectedItem.Id } else { '' }
        $history = if ($FromPoll) { $script:playerHistorySnapshot } else { (Invoke-BridgeGet '/api/history' 1).result.history }
        $historyRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        $lastHistory = $null
        foreach ($item in @($history)) {
            if (-not $item) { continue }
            $time = ''
            try { $time = ([datetime]$item.timestamp).ToLocalTime().ToString('g') } catch { $time = [string]$item.timestamp }
            $audioPath = [string]$item.audioPath
            $savedPath = [string]$item.savedPath
            $savedExists = $false
            $cacheExists = $false
            try { if ($savedPath) { $savedExists = Test-Path -LiteralPath $savedPath } } catch {}
            try { if ($audioPath) { $cacheExists = Test-Path -LiteralPath $audioPath } } catch {}
            if (-not ($savedExists -or $cacheExists)) { continue }
            $audioLabel = if ($savedExists) { 'Saved' } elseif ($cacheExists) { 'Cached' } else { 'Gone' }
            $row = [pscustomobject]@{
                Id=$item.id; Time=$time; Status=$item.status; Alias=$item.alias; Source=$item.source
                User=$item.user; Text=(Get-DisplayText $item.text); AudioPath=$audioPath; SavedPath=$savedPath
                AudioLabel=$audioLabel; HasAudio=$true; DurationMs=$item.duration
            }
            [void]$historyRows.Add($row)
            if (-not $lastHistory) { $lastHistory = $row }
        }
        if ($lastHistory) { $script:lastHistorySpeechId = [string]$lastHistory.Id } else { $script:lastHistorySpeechId = '' }
        try { $script:recentHistoryItems = @($historyRows | Select-Object -First 10) } catch { $script:recentHistoryItems = @() }
        $historySignature = ($historyRows | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Id,$_.Status,$_.AudioLabel,$_.SavedPath }) -join ';'
        if ($historySignature -ne $script:lastHistorySignature) {
            if ($HistoryGrid) {
                $HistoryGrid.ItemsSource = $historyRows
                if ($selectedHistoryId) { $HistoryGrid.SelectedItem = @($historyRows | Where-Object { $_.Id -eq $selectedHistoryId })[0] }
            }
            $script:lastHistorySignature = $historySignature
        }
        Sync-HistoryAudioButton
        if ($FromPoll) { $script:playerHistoryRenderedRevision = $script:playerHistoryRevision }
        # Refresh bar again with real lastHistory (alias/line for idle state)
        try { Update-NowPlayingBar $state $lastHistory } catch {}
    } catch {}
}

function Get-HistoryPlaybackTarget {
    if ($HistoryPage -and $HistoryPage.Visibility -eq 'Visible' -and $HistoryGrid.SelectedItem -and $HistoryGrid.SelectedItem.HasAudio) { return $HistoryGrid.SelectedItem }
    return $null
}

function Sync-HistoryAudioButton {
    if (-not $ShowHistoryAudioButton) { return }
    $row = $HistoryGrid.SelectedItem
    if ($ReplayHistoryButton) { $ReplayHistoryButton.IsEnabled = [bool]($row -and $row.HasAudio) }
    $available = $false
    $tip = 'Select a history row with cached or saved audio'
    if ($row) {
        $savedPath = [string]$row.SavedPath
        $audioPath = [string]$row.AudioPath
        $savedFolder = if ($savedPath) { [IO.Path]::GetDirectoryName($savedPath) } else { '' }
        if ($savedFolder -and (Test-Path -LiteralPath $savedFolder)) {
            $available = $true
            $tip = 'Open the saved-audio folder'
        } elseif ($audioPath -and (Test-Path -LiteralPath $audioPath)) {
            $available = $true
            $tip = 'Reveal the cached WAV in Explorer'
        } else {
            $tip = 'Audio file is no longer on disk (cache expired or never recorded)'
        }
    }
    $ShowHistoryAudioButton.IsEnabled = $available
    $ShowHistoryAudioButton.ToolTip = $tip
}

function Open-InExplorer([string]$target, [switch]$SelectFile) {
    if ([string]::IsNullOrWhiteSpace($target)) { throw 'Missing file path' }
    if ($SelectFile) {
        if (-not (Test-Path -LiteralPath $target)) { throw 'File was not found' }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $target)
        return
    }
    if (-not (Test-Path -LiteralPath $target)) { throw 'Folder was not found' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $target)
}

function Show-HistoryAudioLocation {
    $row = $HistoryGrid.SelectedItem
    if (-not $row) { $BottomStatus.Text = 'Select a history item first'; return }
    $savedPath = [string]$row.SavedPath
    $audioPath = [string]$row.AudioPath
    try {
        # Saved exports open the destination folder (Settings → voice save folder).
        if ($savedPath) {
            $folder = [IO.Path]::GetDirectoryName($savedPath)
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                Open-InExplorer $folder
                $BottomStatus.Text = if (Test-Path -LiteralPath $savedPath) { 'Opened saved audio folder' } else { 'Opened saved audio folder (file missing)' }
                return
            }
        }
        $settings = Read-Settings
        $saveFolder = [string]$settings.voice_save_folder
        if ($saveFolder -and (Test-Path -LiteralPath $saveFolder)) {
            $idPrefix = ([string]$row.Id).Substring(0, [Math]::Min(8, ([string]$row.Id).Length))
            $match = Get-ChildItem -LiteralPath $saveFolder -Filter ("*_" + $idPrefix + ".wav") -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) {
                Open-InExplorer ([IO.Path]::GetDirectoryName($match.FullName))
                $BottomStatus.Text = 'Opened saved audio folder'
                return
            }
        }
        # Still-cached generations: reveal the WAV in Explorer.
        if ($audioPath -and (Test-Path -LiteralPath $audioPath)) {
            Open-InExplorer $audioPath -SelectFile
            $BottomStatus.Text = 'Opened cached audio file'
            return
        }
        $BottomStatus.Text = 'Audio file is no longer available for this history item'
    } catch {
        $BottomStatus.Text = $_.Exception.Message
    }
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
function Get-VoiceAccent([string]$color) {
    $palette=@('#E6A0B1','#E8AD91','#E4CA8B','#A9C98C','#87C9AF','#86C6CB','#91B4E4','#A4A4E8','#B6A3FF','#D3A0D5')
    if($color.ToUpperInvariant() -in $palette){return $color.ToUpperInvariant()}
    return '#B6A3FF'
}

function Resolve-VoiceIcon([string]$identifier, [switch]$Fetch, [string]$Color='#B6A3FF') {
    if (-not $script:mdiVoiceIcons) {
        $script:mdiVoiceIcons=Get-Content -LiteralPath (Join-Path $resourceRoot 'assets\mdi-icons.json') -Raw | ConvertFrom-Json
    }
    $id=$identifier.Trim().ToLowerInvariant()
    if($id.StartsWith('mdi-')){$id='mdi:'+$id.Substring(4)}elseif(-not$id.Contains(':')){$id='mdi:'+$id}
    if($id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*:[a-z0-9]+(?:-[a-z0-9]+)*$'){$id='mdi:music-note'}
    if(-not$id.StartsWith('mdi:')){
        $cache=Join-Path $configDir ('icon-cache\'+$id.Replace(':','--')+'.png')
        if($Fetch -and -not(Test-Path -LiteralPath $cache)){
            $runner=if($env:YAPLOQ_ICON_RUNNER){$env:YAPLOQ_ICON_RUNNER}else{Join-Path $appRoot 'YapLoq-preview.exe'}
            $process=[Diagnostics.ProcessStartInfo]::new();$process.FileName=$runner;$process.UseShellExecute=$false;$process.CreateNoWindow=$true
            $process.Arguments='--render-icon-output '+$id+' "'+$cache+'"'
            $child=[Diagnostics.Process]::Start($process)
            if(-not$child.WaitForExit(12000)){ $child.Kill() }
        }
        $brush=$null
        if(Test-Path -LiteralPath $cache){
            try{
                $bitmap=[Windows.Media.Imaging.BitmapImage]::new();$bitmap.BeginInit();$bitmap.CacheOption='OnLoad';$bitmap.UriSource=[Uri]::new($cache);$bitmap.EndInit();$bitmap.Freeze()
                $mask=[Windows.Media.ImageBrush]::new($bitmap);$mask.Stretch='Uniform';$mask.Freeze()
                $drawing=[Windows.Media.DrawingGroup]::new();$drawing.OpacityMask=$mask
                $paint=[Windows.Media.BrushConverter]::new().ConvertFromString((Get-VoiceAccent $Color))
                [void]$drawing.Children.Add([Windows.Media.GeometryDrawing]::new($paint,$null,[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,96,96))))
                $drawing.Freeze();$brush=[Windows.Media.DrawingBrush]::new($drawing);$brush.Stretch='Uniform';$brush.Freeze()
            }catch{}
        }
        $shape=if($brush){[Windows.Media.Geometry]::Parse('M0 0H24V24H0Z')}else{(Resolve-VoiceIcon 'mdi:music-note').Geometry}
        return [pscustomobject]@{Id=$id;Geometry=$shape;Brush=$brush;Loaded=($null -ne $brush)}
    }
    $name=$id.Substring(4)
    $entry=$script:mdiVoiceIcons.icons.PSObject.Properties[$name]
    if(-not$entry){$id='mdi:music-note';$entry=$script:mdiVoiceIcons.icons.PSObject.Properties['music-note']}
    # Only the trusted collection's geometry is read. User text is never parsed as markup.
    $match=[regex]::Match([string]$entry.Value.body,'\bd="([^"]+)"')
    try{$geometry=[Windows.Media.Geometry]::Parse($match.Groups[1].Value)}catch{$id='mdi:music-note';$geometry=[Windows.Media.Geometry]::Parse('M12 3V13.55A4 4 0 1 0 14 17V7H18V3Z')}
    return [pscustomobject]@{Id=$id;Geometry=$geometry;Brush=$null;Loaded=$true}
}

function Set-VoiceFavorite([string]$name,[bool]$favorite) {
    $settings=Read-Settings
    if(-not$settings.aliases.PSObject.Properties[$name]){return}
    # Change only this flag; retain color, icon and all provider-specific fields.
    Set-JsonProperty $settings.aliases.$name 'favorite' $favorite
    Write-Settings $settings
    Refresh-Grid -VoicesOnly
}

function Save-Alias($oldName, $value) {
    $s = Read-Settings
    $folded = $value.Name.Trim().ToLowerInvariant()
    if ($value.Name -match '[\r\n]' -or $folded.StartsWith('group:') -or $folded.StartsWith('playlist:') -or $folded -in @('random','*')) {
        $BottomStatus.Text='Use a single-line alias name that is not random/* and does not begin with group: or playlist:.'
        return
    }
    if ($value.Name -ne $oldName -and $s.aliases.PSObject.Properties.Name -contains $value.Name) {
        $BottomStatus.Text = 'An alias with that name already exists. Choose another name.'
        return
    }
    $favorite = if ($oldName) { [bool]$s.aliases.$oldName.favorite } else { $false }
    if ($null -ne $value.Favorite) { $favorite = [bool]$value.Favorite }
    $iconId=if($oldName){[string]$s.aliases.$oldName.icon_id}else{'mdi:music-note'}
    if($null -ne $value.IconId){$iconId=[string]$value.IconId}
    $iconId=(Resolve-VoiceIcon $iconId -Fetch).Id
    $color=if($oldName){[string]$s.aliases.$oldName.color}else{'#B6A3FF'}
    if($null -ne $value.Color){$color=[string]$value.Color}
    $color=Get-VoiceAccent $color
    $enabled = if ($oldName -and $null -ne $s.aliases.$oldName.enabled) { [bool]$s.aliases.$oldName.enabled } else { $true }
    if ($null -ne $value.Enabled) { $enabled = [bool]$value.Enabled }
    if ($oldName -and $oldName -ne $value.Name) { $s.aliases.PSObject.Properties.Remove($oldName) }
    $alias = [pscustomobject]@{
        provider = $value.Provider; voice_id = $value.VoiceId; model = $value.Model; speed = [double]$value.Speed
        volume = [double]$value.Volume; language = [string]$value.Language; instruct = [string]$value.Instruct; group = [string]$value.Group
        output_device = [string]$value.OutputDevice; favorite = $favorite; enabled = $enabled; icon_id = $iconId; color=$color
    }
    Set-JsonProperty $s.aliases $value.Name $alias
    Write-Settings $s
    Refresh-Grid -VoicesOnly
}
function Mark-VoicesDirty {
    $script:voicesDirty = $true
    if ($BottomStatus) { $BottomStatus.Text = 'ON/OFF changed - click Save voices to keep them' }
}
function Save-VoiceToggles {
    try {
        $s = Read-Settings
        if (-not $s.aliases) { throw 'No aliases in settings.' }
        $count = 0
        foreach ($row in @($AliasGrid.ItemsSource)) {
            if (-not $row -or -not $row.Name) { continue }
            if (-not $s.aliases.PSObject.Properties[[string]$row.Name]) { continue }
            Set-JsonProperty $s.aliases.([string]$row.Name) 'enabled' ([bool]$row.Enabled)
            $count++
        }
        Write-Settings $s
        $script:voicesDirty = $false
        $BottomStatus.Text = 'Saved ' + $count + ' voice ON/OFF state(s) to data\settings.json'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function Get-ExportSpeakAlias {
    $selected = [string]$ExportVoiceAliasBox.SelectedItem
    if (-not $selected) { return '' }
    if ($selected -eq $script:ExportRandomLabel -or $selected -eq 'random') { return 'random' }
    if ($selected.StartsWith('Playlist: ',[StringComparison]::OrdinalIgnoreCase)) {
        return 'playlist:' + $selected.Substring(10).Trim()
    }
    if ($selected.StartsWith('playlist:',[StringComparison]::OrdinalIgnoreCase)) { return $selected }
    return $selected
}
function Update-StreamerSpeakPayload {
    if (-not $StreamerPayloadBox -or -not $ExportVoiceAliasBox) { return }
    $alias = Get-ExportSpeakAlias
    if (-not $alias) { $alias = 'Your voice alias' }
    $StreamerPayloadBox.Text = "VSPEAK`r`n$alias`r`n%message%`r`n%displayName%`r`n%userName%"
}
function Export-StreamerBotActions {
    try {
        $alias = Get-ExportSpeakAlias
        if (-not $alias) { throw 'Add a voice in Voices first, then choose it here.' }
        $saved = Read-Settings
        if (-not $saved.enable_udp) { throw 'Enable the UDP listener and save the connection settings first. Restart YapLoq if you just enabled it.' }
        if ([int]$UdpBox.Text -ne [int]$saved.udp_port) { throw 'Save the UDP port and restart YapLoq before exporting actions.' }
        $result = Invoke-BridgePost '/api/maintenance/streamerbot-export' @{ alias=$alias }
        $path = [string]$result.result.path
        $code = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        [Windows.Clipboard]::SetText($code)
        $script:lastStreamerExportPath = $path
        $message = 'Import code copied. In Streamer.bot, click Import and paste into Import String. File: ' + $path
        $window.FindName('StreamerExportStatus').Text = $message
        $BottomStatus.Text = 'Streamer.bot import code copied'
    } catch {
        $window.FindName('StreamerExportStatus').Text = $_.Exception.Message
        $BottomStatus.Text = $_.Exception.Message
    }
}
function Get-PlaylistSpeakLabels($settings) {
    $labels = New-Object System.Collections.Generic.List[string]
    $map = $settings.voice_playlists
    if (-not $map) { return @() }
    foreach ($prop in @($map.PSObject.Properties | Sort-Object Name)) {
        [void]$labels.Add('Playlist: ' + [string]$prop.Name)
    }
    return @($labels)
}
function Refresh-PlaylistGrid($settings) {
    if (-not $PlaylistGrid) { return }
    if (-not $settings) { $settings = Read-Settings }
    $selected = if ($PlaylistGrid.SelectedItem) { [string]$PlaylistGrid.SelectedItem.Name } else { '' }
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $map = $settings.voice_playlists
    if ($map) {
        foreach ($prop in @($map.PSObject.Properties | Sort-Object Name)) {
            $voices = @($prop.Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
            $summary = if ($voices.Count) { ($voices -join ', ') } else { '(empty)' }
            $rows.Add([pscustomobject]@{ Name=[string]$prop.Name; Voices=$voices; Summary=$summary; Count=$voices.Count })
        }
    }
    $PlaylistGrid.ItemsSource = $rows
    if ($selected) {
        $hit = @($rows | Where-Object { $_.Name -eq $selected })[0]
        if ($hit) { $PlaylistGrid.SelectedItem = $hit }
    }
}
function Show-PlaylistDialog($existing) {
    [xml]$playlistXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="520" Height="560" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F6F3FA">
 <Border Background="#15131D" BorderBrush="#50485C" BorderThickness="1" CornerRadius="13">
  <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="7" Opacity="0.5"/></Border.Effect>
  <Grid ClipToBounds="True">
   <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Border Name="TitleBar" Background="#1E1A27" BorderBrush="#50485C" BorderThickness="0,0,0,1" CornerRadius="13,13,0,0">
    <Grid>
     <TextBlock Name="WindowTitle" Text="New playlist" FontWeight="SemiBold" Margin="18,0,0,0" VerticalAlignment="Center"/>
     <Button Name="Close" Content="X" HorizontalAlignment="Right" Width="46" Background="Transparent" BorderThickness="0"/>
    </Grid>
   </Border>
   <StackPanel Grid.Row="1" Margin="22,18,22,8">
    <TextBlock Text="Playlist name" Foreground="#B9B2C2"/>
    <TextBox Name="NameBox" Margin="0,7,0,14" Padding="12,10"/>
    <TextBlock Text="Voices in this playlist" Foreground="#B9B2C2" Margin="0,0,0,8"/>
    <Border Background="#1E1A27" BorderBrush="#50485C" BorderThickness="1" CornerRadius="8" Height="300">
     <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="10,8">
      <StackPanel Name="VoiceChecks"/>
     </ScrollViewer>
    </Border>
    <TextBlock Name="ValidationText" Foreground="#FF8E8E" TextWrapping="Wrap" Margin="0,10,0,0"/>
   </StackPanel>
   <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="22,0,22,18">
    <Button Name="Cancel" Content="Cancel" Width="100" Margin="0,0,10,0"/>
    <Button Name="Save" Content="Save playlist" Width="130" Background="#B6A3FF" Foreground="#15131D" BorderBrush="#B6A3FF" FontWeight="SemiBold"/>
   </StackPanel>
  </Grid>
 </Border>
</Window>
'@
    $d = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($playlistXaml))
    $d.Owner = $window
    Apply-AppFont $d
    $d.Resources.MergedDictionaries.Add($window.Resources)
    $nameBox = $d.FindName('NameBox')
    $checks = $d.FindName('VoiceChecks')
    $validation = $d.FindName('ValidationText')
    $aliasNames = @($AliasGrid.ItemsSource | ForEach-Object { [string]$_.Name } | Where-Object { $_ } | Sort-Object)
    if (-not $aliasNames.Count) {
        $aliasNames = @(Read-Settings).aliases.PSObject.Properties.Name | Sort-Object
    }
    $selected = @{}
    if ($existing) {
        $d.FindName('WindowTitle').Text = 'Edit playlist'
        $nameBox.Text = [string]$existing.Name
        foreach ($v in @($existing.Voices)) { $selected[[string]$v] = $true }
    }
    foreach ($aliasName in $aliasNames) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        $cb.Content = $aliasName
        $cb.Margin = [System.Windows.Thickness]::new(0,0,0,8)
        $cb.IsChecked = [bool]$selected[$aliasName]
        [void]$checks.Children.Add($cb)
    }
    $script:playlistDialogResult = $null
    $d.FindName('TitleBar').Add_MouseLeftButtonDown({ $d.DragMove() })
    $d.FindName('Close').Add_Click({ $d.Close() })
    $d.FindName('Cancel').Add_Click({ $d.Close() })
    $d.FindName('Save').Add_Click({
        try {
            $name = $nameBox.Text.Trim()
            $folded = $name.ToLowerInvariant()
            if (-not $name -or $name -match '[\r\n]' -or $folded.StartsWith('group:') -or $folded.StartsWith('playlist:') -or $folded -in @('random','*')) {
                throw 'Use a simple playlist name (not random/group:/playlist:).'
            }
            $picked = New-Object System.Collections.Generic.List[string]
            foreach ($child in @($checks.Children)) {
                if ($child -is [System.Windows.Controls.CheckBox] -and $child.IsChecked) {
                    [void]$picked.Add([string]$child.Content)
                }
            }
            if ($picked.Count -lt 1) { throw 'Check at least one voice.' }
            $script:playlistDialogResult = [pscustomobject]@{ Name=$name; Voices=@($picked) }
            $d.DialogResult = $true
        } catch { $validation.Text = $_.Exception.Message }
    })
    [void]$d.ShowDialog()
    return $script:playlistDialogResult
}
function Save-Playlist($oldName, $value) {
    $s = Read-Settings
    if (-not $s.voice_playlists) { Set-JsonProperty $s 'voice_playlists' ([pscustomobject]@{}) }
    $map = $s.voice_playlists
    $folded = $value.Name.ToLowerInvariant()
    foreach ($prop in @($map.PSObject.Properties)) {
        if ($prop.Name -ne $oldName -and $prop.Name.ToLowerInvariant() -eq $folded) {
            $BottomStatus.Text = 'A playlist with that name already exists.'
            return
        }
    }
    if ($oldName -and $oldName -ne $value.Name -and $map.PSObject.Properties[$oldName]) {
        $map.PSObject.Properties.Remove($oldName)
    }
    Set-JsonProperty $map $value.Name @($value.Voices)
    Set-JsonProperty $s 'voice_playlists' $map
    Write-Settings $s
    Refresh-Grid
    $BottomStatus.Text = 'Saved playlist "' + $value.Name + '"'
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
        Set-JsonProperty $s 'profanity_enabled' ([bool]$script:profanityEnabled.IsChecked)
        Set-JsonProperty $s 'profanity_hide_words' (-not [bool]$script:profanityShow.IsChecked)
        Set-JsonProperty $s 'profanity_rules' @(Get-ProfanityRules)
        Write-Settings $s
        $BottomStatus.Text = 'Rules saved to data\settings.json'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}
function Save-Pronunciations {
    try {
        $s = Read-Settings
        $map = [ordered]@{}
        $hidden = New-Object System.Collections.Generic.List[string]
        foreach ($row in @($PronunciationGrid.ItemsSource)) {
            if (-not $row -or -not [string]$row.Written) { continue }
            $written = [string]$row.Written
            $map[$written] = [string]$row.Spoken
            if ([bool]$row.Hidden) { [void]$hidden.Add($written) }
        }
        Set-JsonProperty $s 'pronunciations' ([pscustomobject]$map)
        Set-JsonProperty $s 'hidden_pronunciations' @($hidden)
        Write-Settings $s
        $BottomStatus.Text = 'Pronunciations saved to data\settings.json'
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
    $BottomStatus.Text = 'Pronunciation saved to data\settings.json'
}
function Move-Pronunciation([int]$delta) {
    $items = $PronunciationGrid.ItemsSource
    $row = $PronunciationGrid.SelectedItem
    if (-not $row -or -not $items) { return }
    $index = @($items).IndexOf($row)
    if ($index -lt 0) { return }
    $newIndex = $index + $delta
    if ($newIndex -lt 0 -or $newIndex -ge $items.Count) { return }
    $items.RemoveAt($index)
    $items.Insert($newIndex, $row)
    $PronunciationGrid.SelectedItem = $row
    Save-Pronunciations
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
    $QueueControlHint.Text = if ($needsId) { 'Uses %ttsId% from a YapLoq lifecycle action. You can also replace it with a queue speech ID.' } else { 'This action does not need a queue item ID.' }
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
        Set-JsonProperty $s 'voicestudio_enabled' ([bool]$(if ($VoiceStudioEnabledCheck) { $VoiceStudioEnabledCheck.IsChecked } else { $true }))
        Write-Settings $s
        $BottomStatus.Text = 'VoiceStudio settings saved to data\settings.json'
        try { Refresh-ServiceHealth $false | Out-Null } catch {}
    } catch { $BottomStatus.Text = $_.Exception.Message }
}

function Save-ElevenLabsSettings {
    $s = Read-Settings
    Set-JsonProperty $s 'elevenlabs_enabled' ([bool]$ElevenLabsEnabledCheck.IsChecked)
    if ($ElevenLabsApiKeyBox.Password) {
        Set-JsonProperty $s 'elevenlabs_api_key_encrypted' (Protect-YapLoqSecret $ElevenLabsApiKeyBox.Password)
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
        Set-JsonProperty $s 'azure_subscription_key_encrypted' (Protect-YapLoqSecret $AzureKeyBox.Password)
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
        Set-JsonProperty $s 'google_api_key_encrypted' (Protect-YapLoqSecret $GoogleApiKeyBox.Password)
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
        Set-JsonProperty $s 'watson_api_key_encrypted' (Protect-YapLoqSecret $WatsonApiKeyBox.Password)
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
        Set-JsonProperty $s 'uberduck_api_key_encrypted' (Protect-YapLoqSecret $UberDuckApiKeyBox.Password)
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
        Set-JsonProperty $s 'ttsmonster_api_token_encrypted' (Protect-YapLoqSecret $TtsMonsterTokenBox.Password)
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
    Set-JsonProperty $s 'acapela_application_name' $(if ($AcapelaAppNameBox.Text.Trim()) { $AcapelaAppNameBox.Text.Trim() } else { 'YapLoq' })
    if ($AcapelaPasswordBox.Password) {
        Set-JsonProperty $s 'acapela_password_encrypted' (Protect-YapLoqSecret $AcapelaPasswordBox.Password)
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
        Set-JsonProperty $s 'cereproc_password_encrypted' (Protect-YapLoqSecret $CereProcPasswordBox.Password)
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
            Set-JsonProperty $s 'polly_access_key_encrypted' (Protect-YapLoqSecret $PollyAccessKeyBox.Password)
            Set-JsonProperty $s 'polly_secret_key_encrypted' (Protect-YapLoqSecret $PollySecretKeyBox.Password)
            Set-JsonProperty $s 'polly_session_token_encrypted' (Protect-YapLoqSecret $PollySessionTokenBox.Password)
        }
        elseif ($PollySessionTokenBox.Password) { Set-JsonProperty $s 'polly_session_token_encrypted' (Protect-YapLoqSecret $PollySessionTokenBox.Password) }
        Write-Settings $s
        $PollyAccessKeyBox.Password = ''; $PollySecretKeyBox.Password = ''
        $PollySessionTokenBox.Password = ''
        $PollyCredentialStatus.Text = 'Credentials saved securely for this Windows account'
        $BottomStatus.Text = 'Amazon Polly credentials saved'
    } catch { $BottomStatus.Text = $_.Exception.Message }
}



function Show-AliasDialog($existing) {
    # Hydrate appearance from the persisted alias, not a potentially stale list row.
    $savedAppearance=$null
    if($existing -and $existing.Name){
        $editorSettings=Read-Settings
        $savedAppearance=$editorSettings.aliases.PSObject.Properties[[string]$existing.Name]
    }
    $editorColor=Get-VoiceAccent $(if($savedAppearance){[string]$savedAppearance.Value.color}else{[string]$existing.Color})
    $editorIconId=if($savedAppearance){[string]$savedAppearance.Value.icon_id}else{[string]$existing.IconId}
    $editorFavorite=if($savedAppearance){[bool]$savedAppearance.Value.favorite}else{[bool]$existing.Favorite}
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
    <CheckBox Name="AliasFavoriteCheck" Content="Favorite voice" Foreground="#F6F3FA" Margin="0,0,0,16" ToolTip="Include this voice in the favorites filter"/>
    <TextBlock Text="Voice icon" Foreground="#B9B2C2"/>
    <Grid Margin="0,7,0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Path Name="AliasIconPreview" Width="22" Height="22" Stretch="Uniform" Fill="#B6A3FF" VerticalAlignment="Center"/>
     <TextBox Name="AliasIconId" Grid.Column="1" Text="mdi:music-note" ToolTip="Paste any Icônes identifier, such as picon:alien, then leave the field to load it"/>
     <Button Name="BrowseVoiceIcons" Grid.Column="2" Content="Browse icons" Margin="10,0,0,0"/>
    </Grid>
    <TextBlock Name="AliasIconHint" Foreground="#B9B2C2" FontSize="11" Margin="0,0,0,16" Text="Paste collection:name from Icônes. New icons download once and are cached."/>
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
    $iconBox=$d.FindName('AliasIconId');$iconPreview=$d.FindName('AliasIconPreview');$iconHint=$d.FindName('AliasIconHint')
    $nameField=$d.FindName('NameBox');$editorPanel=$nameField.Parent
    $favoriteField=$d.FindName('AliasFavoriteCheck')
    $favoriteField.Template=$window.FindName('FavoritesOnlyCheck').Template
    $favoriteField.Content=$null;$favoriteField.ToolTip='Favorite voice';$favoriteField.Margin='10,0,0,0'
    [Windows.Automation.AutomationProperties]::SetName($favoriteField,'Favorite voice')
    $nameIndex=$editorPanel.Children.IndexOf($nameField)
    [void]$editorPanel.Children.Remove($nameField);[void]$editorPanel.Children.Remove($favoriteField)
    $oldIconRow=$iconPreview.Parent;[void]$oldIconRow.Children.Remove($iconPreview);$oldIconRow.ColumnDefinitions[0].Width=0
    $identityRow=[Windows.Controls.Grid]::new();$identityRow.Margin='0,7,0,12'
    foreach($width in @('52','*','Auto')){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width=$width;$identityRow.ColumnDefinitions.Add($column)}
    $iconBadge=[Windows.Controls.Border]::new();$iconBadge.Width=42;$iconBadge.Height=42;$iconBadge.CornerRadius=8;$iconBadge.BorderThickness=1;$iconBadge.Child=$iconPreview
    $nameField.Margin=0;[Windows.Controls.Grid]::SetColumn($nameField,1);[Windows.Controls.Grid]::SetColumn($favoriteField,2)
    [void]$identityRow.Children.Add($iconBadge);[void]$identityRow.Children.Add($nameField);[void]$identityRow.Children.Add($favoriteField);$editorPanel.Children.Insert($nameIndex,$identityRow)
    $paletteRow=[Windows.Controls.WrapPanel]::new();$paletteRow.Margin='0,0,0,16'
    $paletteRow.Tag=$editorColor
    $colorNames=@('Rose','Peach','Gold','Lime','Mint','Teal','Blue','Indigo','Violet','Orchid')
    $palette=@('#E6A0B1','#E8AD91','#E4CA8B','#A9C98C','#87C9AF','#86C6CB','#91B4E4','#A4A4E8','#B6A3FF','#D3A0D5')
    for($i=0;$i -lt $palette.Count;$i++){
        $swatch=[Windows.Controls.Button]::new();$swatch.Width=30;$swatch.Height=30;$swatch.Padding=4;$swatch.Margin='0,0,8,4';$swatch.Tag=$palette[$i];$swatch.ToolTip=$colorNames[$i]
        [Windows.Automation.AutomationProperties]::SetName($swatch,$colorNames[$i]+' voice color')
        $swatch.MinHeight=30;$swatch.MinWidth=30
        $dot=[Windows.Shapes.Ellipse]::new();$dot.Width=18;$dot.Height=18;$dot.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString($palette[$i]);$swatch.Content=$dot
        $swatch.Add_Click({param($sender,$e)
            $paletteRow.Tag=[string]$sender.Tag
            foreach($choice in $paletteRow.Children){$choice.BorderThickness=if($choice.Tag -eq $paletteRow.Tag){2}else{0};$choice.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString($paletteRow.Tag)}
            $brush=[Windows.Media.BrushConverter]::new().ConvertFromString($paletteRow.Tag);$iconPreview.Fill=$brush;$iconBadge.BorderBrush=$brush;$iconBadge.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#33'+$paletteRow.Tag.Substring(1));$nameField.BorderBrush=$brush
            $coloredIcon=Resolve-VoiceIcon $iconBox.Text -Color ([string]$paletteRow.Tag)
            $iconPreview.Data=$coloredIcon.Geometry
            if($coloredIcon.Brush){$iconPreview.Fill=$coloredIcon.Brush}
            $profileList=$d.FindName('ProfileBox')
            $profileStyleMarkup=[Windows.Markup.XamlWriter]::Save($d.FindResource([Windows.Controls.ListBoxItem]))
            $profileStyleMarkup=$profileStyleMarkup -replace '(?i)#(?:FF)?B6A3FF',([string]$paletteRow.Tag)
            $profileList.ItemContainerStyle=[Windows.Markup.XamlReader]::Parse($profileStyleMarkup)
            $saveVoiceButton=$d.FindName('Save');$saveVoiceButton.Background=$brush;$saveVoiceButton.BorderBrush=$brush
        })
        [void]$paletteRow.Children.Add($swatch)
    }
    $editorPanel.Children.Insert($nameIndex+1,$paletteRow)
    $selectedSwatch=@($paletteRow.Children|Where-Object{$_.Tag -eq $paletteRow.Tag})[0]
    $selectedSwatch.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    $updateIcon={
        $resolved=Resolve-VoiceIcon $iconBox.Text -Color ([string]$paletteRow.Tag)
        $iconPreview.Data=if($resolved.Loaded){$resolved.Geometry}else{(Resolve-VoiceIcon 'mdi:music-note').Geometry}
        $iconPreview.Fill=if($resolved.Brush){$resolved.Brush}else{[Windows.Media.BrushConverter]::new().ConvertFromString([string]$paletteRow.Tag)}
        $iconHint.Text=if(-not$resolved.Loaded){"Browse icons, copy an icon's code, and paste it here. Leave the field to load it."}elseif($resolved.Id -eq 'mdi:music-note' -and $iconBox.Text.Trim() -notin @('mdi:music-note','music-note','mdi-music-note')){'Icon not found. Browse icons and paste its collection:name code.'}else{"Browse icons, copy an icon's code, and paste it here."}
    }
    $iconBox.Add_TextChanged($updateIcon)
    $iconBox.Add_LostKeyboardFocus({[void](Resolve-VoiceIcon $iconBox.Text -Fetch);& $updateIcon})
    if($editorIconId){$iconBox.Text=$editorIconId}
    & $updateIcon
    $d.FindName('BrowseVoiceIcons').Add_Click({Open-VoxLink 'https://icones.js.org/'})
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
        $d.FindName('AliasFavoriteCheck').IsChecked = $editorFavorite
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
            $script:dialogResult | Add-Member -NotePropertyName Favorite -NotePropertyValue ([bool]$d.FindName('AliasFavoriteCheck').IsChecked) -Force
            $script:dialogResult | Add-Member -NotePropertyName IconId -NotePropertyValue ((Resolve-VoiceIcon $iconBox.Text).Id) -Force
            $script:dialogResult | Add-Member -NotePropertyName Color -NotePropertyValue ([string]$paletteRow.Tag) -Force
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
    $d.FindName('Heading').Text='Test '+$alias;$box=$d.FindName('Text');$box.Text='YapLoq is ready.';$box.SelectAll()
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
    # Use shipped artwork directly, never an outdated generated icon in data/.
    foreach($name in @('YapLoq-tray.ico','YapLoq.ico')) {
        $path=Join-Path $resourceRoot ('assets\'+$name)
        if(Test-Path -LiteralPath $path){return $path}
    }
    return (Join-Path $configDir 'tray.ico')
}
function Promote-TrayIconInRegistry {
    if ($script:isPreview) { return }
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
            if (($tip -eq 'YapLoq') -or ($initial -eq 'YapLoq') -or ($exe -like '*powershell*') -or ($exe -like '*YapLoq*')) {
                if ($tip -eq 'YapLoq' -or $initial -eq 'YapLoq' -or $exe -eq $exeHint -or $exe -like '*YapLoq.Tray.exe*') {
                    New-ItemProperty -Path $_.PSPath -Name IsPromoted -PropertyType DWord -Value 1 -Force | Out-Null
                    New-ItemProperty -Path $_.PSPath -Name IconText -PropertyType String -Value 'YapLoq' -Force | Out-Null
                }
            }
        }
    } catch {}
}
function Initialize-TrayIcon {
    if ($script:trayIcon) { return }
    # Speaker.bot style: NotifyIcon lives in THIS process so restore/click stay on the UI thread.
    if (-not $script:isPreview) { Get-Process -Name 'YapLoq.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    $icoPath = Get-TrayIconPath
    try {
        if (Test-Path -LiteralPath $icoPath) { $script:trayOwnedIcon = [System.Drawing.Icon]::new($icoPath) }
        else { $script:trayOwnedIcon = [System.Drawing.SystemIcons]::Application.Clone() }
    } catch {
        $script:trayOwnedIcon = [System.Drawing.SystemIcons]::Application.Clone()
    }
    $script:trayIcon = [System.Windows.Forms.NotifyIcon]::new()
    $script:trayIcon.Text = $script:appLabel
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
    $script:trayIcon.Text = $script:appLabel + ' - Restore'
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
            $script:trayIcon.Text = $script:appLabel
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
    if (-not $script:isPreview) { Get-Process -Name 'YapLoq.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
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
$ActivityNav.Add_Click({ Set-Page 'activity' }); $SettingsNav.Add_Click({ Set-Page 'settings' })
$BridgeStatusButton.Add_Click({ Show-ServiceStatusMenu $BridgeStatusButton })
@(
    $AboutGitHubButton, $AboutTwitchButton, $AboutYouTubeButton, $AboutXButton,
    $AboutInstagramButton, $AboutFacebookButton, $AboutTikTokButton, $AboutDiscordButton
) | Where-Object { $_ } | ForEach-Object {
    $_.Add_Click({ param($sender, $e) Open-VoxLink ([string]$sender.Tag) })
}
if ($NowPlayingHistoryButton) { $NowPlayingHistoryButton.Add_Click({ Show-QuickHistoryMenu }) }
if ($NowPlayingPrevButton) {
    $NowPlayingPrevButton.Add_Click({
        try {
            $id = $script:lastHistorySpeechId
            if (-not $id -and @($script:recentHistoryItems).Count -gt 0) { $id = [string]$script:recentHistoryItems[0].Id }
            if (-not $id) { throw 'No history audio to replay' }
            Invoke-BridgePost '/api/history/replay' @{ speechId = $id } | Out-Null
            $BottomStatus.Text = 'Previous audio queued'
            Refresh-ServiceState
        } catch { $BottomStatus.Text = $_.Exception.Message }
    })
}


if ($NowPlayingProgressTrack) {
    $NowPlayingProgressTrack.Add_SizeChanged({
        if (-not $script:progressSeeking) { Update-NowPlayingProgressUi }
    })
    $NowPlayingProgressTrack.Add_PreviewMouseLeftButtonDown({
        param($sender,$e)
        if (-not $script:canSeekPlayback) { return }
        $script:seekSpeechKey = $script:progressSpeechKey
        $script:progressSeeking = $true
        [void]$sender.Focus(); [void]$sender.CaptureMouse()
        Preview-PlaybackSeek ($e.GetPosition($sender).X)
        $e.Handled = $true
    })
    $NowPlayingProgressTrack.Add_PreviewMouseMove({
        param($sender,$e)
        if ($script:progressSeeking -and $sender.IsMouseCaptured) { Preview-PlaybackSeek ($e.GetPosition($sender).X) }
    })
    $NowPlayingProgressTrack.Add_PreviewMouseLeftButtonUp({
        param($sender,$e)
        if (-not $script:progressSeeking) { return }
        Preview-PlaybackSeek ($e.GetPosition($sender).X)
        Complete-PlaybackSeek
        $sender.ReleaseMouseCapture()
        $e.Handled = $true
    })
    $NowPlayingProgressTrack.Add_LostMouseCapture({
        if ($script:progressSeeking) { $script:progressSeeking = $false; Refresh-ServiceState }
    })
    $NowPlayingProgressTrack.Add_PreviewKeyDown({
        param($sender,$e)
        if (-not $script:canSeekPlayback) { return }
        $position = Get-NowPlayingElapsed
        switch ([string]$e.Key) {
            'Left' { $position -= 5 }
            'Right' { $position += 5 }
            'Home' { $position = 0 }
            'End' { $position = $script:progressDurationSec }
            default { return }
        }
        $script:seekSpeechKey = $script:progressSpeechKey
        $script:progressSeeking = $true
        Preview-PlaybackSeek ( $position / $script:progressDurationSec * $sender.ActualWidth )
        Complete-PlaybackSeek
        $e.Handled = $true
    })
}

if ($NowPlayingPlayPauseButton) {
    $NowPlayingPlayPauseButton.Add_Click({
        try {
            $mode = [string]$NowPlayingPlayPauseButton.Tag
            if (-not $mode) { $mode = [string]$script:nowPlayingMode }
            switch ($mode) {
                'playing' { Invoke-BridgePost '/pause' | Out-Null }
                'generating' { Invoke-BridgePost '/pause' | Out-Null }
                'ready' { Invoke-BridgePost '/pause' | Out-Null }
                'paused' { Invoke-BridgePost '/resume' | Out-Null }
                default {
                    $target = Get-HistoryPlaybackTarget
                    $id = if ($target) { [string]$target.Id } else { $script:lastHistorySpeechId }
                    if ($id) {
                        Invoke-BridgePost '/api/history/replay' @{ speechId = $id } | Out-Null
                        if ($BottomStatus) { $BottomStatus.Text = 'Last audio queued' }
                    }
                }
            }
            Refresh-ServiceState
        } catch {
            if ($BottomStatus) { $BottomStatus.Text = $_.Exception.Message }
        }
    })
}
if ($NowPlayingSkipButton) { $NowPlayingSkipButton.Add_Click({ try { Invoke-BridgePost '/skip' | Out-Null; Refresh-ServiceState } catch { $BottomStatus.Text = $_.Exception.Message } }) }

if ($NowPlayingClearButton) { $NowPlayingClearButton.Add_Click({ try { Invoke-BridgePost '/clear' | Out-Null; Refresh-ServiceState } catch { $BottomStatus.Text = $_.Exception.Message } }) }
if ($NowPlayingStopClearButton) { $NowPlayingStopClearButton.Add_Click({ try { Invoke-BridgePost '/clear-all' | Out-Null; Refresh-ServiceState } catch { $BottomStatus.Text = $_.Exception.Message } }) }
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
if ($ShowHistoryAudioButton) { $ShowHistoryAudioButton.Add_Click({ Show-HistoryAudioLocation }) }
$HistoryGrid.Add_SelectionChanged({
    Sync-HistoryAudioButton
    if ($script:lastPlaybackState) { Update-NowPlayingBar $script:lastPlaybackState @($script:recentHistoryItems)[0] }
})
$SaveHistoryAudioButton.Add_Click({
    $row = $HistoryGrid.SelectedItem
    if (-not $row) { $BottomStatus.Text = 'Select a history item first'; return }
    try {
        $result = Invoke-BridgePost '/api/history/save' @{ speechId = $row.Id }
        $path = [string]$result.result.path
        if (-not $path) { $path = [string]$result.path }
        $BottomStatus.Text = if ($path) { 'Saved audio to ' + $path } else { 'Audio saved' }
        $script:lastHistorySignature = ''
        Refresh-ServiceState
    } catch { $BottomStatus.Text = $_.Exception.Message }
})
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
    $BottomStatus.Text = 'Pronunciation removed from data\settings.json'
})
$PronunciationUpButton.Add_Click({ Move-Pronunciation -1 })
$PronunciationDownButton.Add_Click({ Move-Pronunciation 1 })
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
$CopyPayloadButton.Add_Click({ Update-StreamerSpeakPayload; [Windows.Clipboard]::SetText($StreamerPayloadBox.Text) })
$ExportVoiceAliasBox.Add_SelectionChanged({ Update-StreamerSpeakPayload })
$ExportStreamerBotButton.Add_Click({ Export-StreamerBotActions })
$window.FindName('SaveStreamerConnectionButton').Add_Click({ Save-StreamerBotSettings })
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
        $BottomStatus.Text = 'Settings saved to data\settings.json. Restart after changing the HTTP port.'
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

$script:progressDurationSec = 0.0
$script:progressAnchorElapsed = 0.0
$script:progressAnchorUtc = [datetime]::UtcNow
$script:progressPlaying = $false
$script:progressLastUiMs = 0

function Preview-PlaybackSeek([double]$x) {
    $width = [double]$NowPlayingProgressTrack.ActualWidth
    if ($width -le 0) { return }
    $script:progressAnchorElapsed = [Math]::Max(0.0, [Math]::Min(1.0, $x / $width)) * $script:progressDurationSec
    $script:progressPlaying = $false
    $script:progressCorrection = 0.0
    Update-NowPlayingProgressUi
    $NowPlayingProgressTrack.ToolTip = 'Seek to ' + (Format-PlayerTime $script:progressAnchorElapsed)
}

function Complete-PlaybackSeek {
    try {
        $result = (Invoke-BridgePost '/api/playback/seek' @{ seconds=[double]$script:progressAnchorElapsed; speechId=$script:seekSpeechKey }).result
        $script:progressSeekRevision = [int]$result.seekRevision
        $script:progressAnchorElapsed = [double]$result.elapsedSeconds
        $script:progressAnchorTicks = [Diagnostics.Stopwatch]::GetTimestamp()
        $script:progressCorrection = 0.0
        $script:progressPlaying = ($script:nowPlayingMode -eq 'playing')
    } catch { $BottomStatus.Text = $_.Exception.Message }
    finally {
        $script:progressSeeking = $false
        $NowPlayingProgressTrack.ToolTip = 'Click or drag to seek'
        Refresh-ServiceState
    }
}

function Format-PlayerTime([double]$seconds) {
    if ($seconds -lt 0) { $seconds = 0 }
    $total = [int][Math]::Floor($seconds + 0.0001)
    return ('{0}:{1:D2}' -f [int][Math]::Floor($total / 60), ($total % 60))
}

function Get-NowPlayingElapsed {
    $elapsed = [double]$script:progressAnchorElapsed
    if ($script:progressPlaying) {
        # Smooth only between snapshots. A lost backend must never run a phantom clock.
        try {
            $age = [Math]::Max(0.0, [Math]::Min(1.5, ([Diagnostics.Stopwatch]::GetTimestamp() - $script:progressAnchorTicks) / [double][Diagnostics.Stopwatch]::Frequency))
            $elapsed += $age + [double]$script:progressCorrection * (1 - [Math]::Exp(-$age / 0.6))
        } catch {}
    }
    if ($elapsed -lt 0) { $elapsed = 0 }
    $dur = [double]$script:progressDurationSec
    if ($dur -gt 0 -and $elapsed -gt $dur) { $elapsed = $dur }
    return $elapsed
}

function Set-NowPlayingProgressVisual([double]$pct) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    try { if ($NowPlayingProgress) { $NowPlayingProgress.Value = $pct } } catch {}
    try {
        if (-not $NowPlayingProgressFill) { return }
        $w = 0.0
        if ($NowPlayingProgressTrack) {
            $w = [double]$NowPlayingProgressTrack.ActualWidth
            if ($w -lt 2) { $w = [double]$NowPlayingProgressTrack.RenderSize.Width }
        }
        if ($w -lt 2 -and $NowPlayingProgressFill.Parent -is [Windows.FrameworkElement]) {
            $w = [double]$NowPlayingProgressFill.Parent.ActualWidth
        }
        if ($w -lt 2) { $w = 0.0 }
        $NowPlayingProgressFill.HorizontalAlignment = 'Left'
        $targetWidth = [Math]::Max(0.0, $w * ($pct / 100.0))
        if ($script:progressPlaying -and $pct -gt 0 -and $pct -lt 100) {
            # WPF renders between timer ticks instead of moving in 50 ms steps.
            $fromWidth = [double]$NowPlayingProgressFill.ActualWidth
            $NowPlayingProgressFill.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
            $NowPlayingProgressFill.Width = $targetWidth
            $animation = [Windows.Media.Animation.DoubleAnimation]::new($fromWidth, $targetWidth, [TimeSpan]::FromMilliseconds(70))
            $NowPlayingProgressFill.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $animation)
        } else {
            $NowPlayingProgressFill.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
            $NowPlayingProgressFill.Width = $targetWidth
        }
    } catch {}
}

function Update-NowPlayingProgressUi {
    $durationSec = [double]$script:progressDurationSec
    $elapsedSec = Get-NowPlayingElapsed
    if ($NowPlayingElapsedText) { $NowPlayingElapsedText.Text = Format-PlayerTime $elapsedSec }
    if ($durationSec -le 0) {
        if ($NowPlayingRemainingText) { $NowPlayingRemainingText.Text = $(if ($script:nowPlayingMode -eq 'generating') { '--:--' } else { '0:00' }) }
        Set-NowPlayingProgressVisual 0
        return
    }
    $remainingSec = [Math]::Max(0, $durationSec - $elapsedSec)
    if ($NowPlayingRemainingText) { $NowPlayingRemainingText.Text = Format-PlayerTime $durationSec }
    Set-NowPlayingProgressVisual (($elapsedSec / $durationSec) * 100.0)
}


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
    if($ObsPasswordBox.Password){Set-JsonProperty $settings 'obs_password_encrypted' (Protect-YapLoqSecret $ObsPasswordBox.Password)}
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
function ConvertTo-SpeakVoiceToken([string]$label) {
    if (-not $label) { return '' }
    if ($label -eq $script:ExportRandomLabel -or $label -eq 'random') { return 'random' }
    if ($label.StartsWith('Playlist: ', [StringComparison]::OrdinalIgnoreCase)) {
        return 'playlist:' + $label.Substring(10).Trim()
    }
    return $label
}
function ConvertFrom-SpeakVoiceToken([string]$token) {
    if (-not $token) { return '' }
    if ($token -eq 'random') { return $script:ExportRandomLabel }
    if ($token.StartsWith('playlist:', [StringComparison]::OrdinalIgnoreCase)) {
        return 'Playlist: ' + $token.Substring(9).Trim()
    }
    return $token
}
function Save-RouteEditor([bool]$replace) {
    if (-not $RouteValueBox.Text.Trim() -or -not $RouteAliasBox.SelectedItem) { $BottomStatus.Text = 'Enter a match and choose a voice.'; return }
    $aliasToken = ConvertTo-SpeakVoiceToken ([string]$RouteAliasBox.SelectedItem)
    $rule = [pscustomobject]@{field=[string]$RouteFieldBox.SelectedItem.Tag;value=$RouteValueBox.Text.Trim();alias=$aliasToken;priority=[int]$RoutePrioritySlider.Value;enabled=$true}
    $index = $RoutingGrid.SelectedIndex
    if ($replace) { if ($index -lt 0) { $BottomStatus.Text = 'Select a routing rule to update.'; return }; $RoutingGrid.ItemsSource[$index] = $rule }
    else { $RoutingGrid.ItemsSource.Add($rule) }
    $BottomStatus.Text = 'Routing changed. Save rules to apply.'
}

function Get-VoiceRuleDraft([switch]$RequireSelection) {
    $fieldItem = $VoiceRuleFieldBox.SelectedItem
    $field = if ($fieldItem -and $fieldItem.Tag) { [string]$fieldItem.Tag } else { 'user' }
    $value = $VoiceRuleValueBox.Text.Trim()
    $alias = ConvertTo-SpeakVoiceToken ([string]$VoiceRuleAliasBox.SelectedItem)
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
    $voiceLabel = ConvertFrom-SpeakVoiceToken ([string]$rule.alias)
    if ($VoiceRuleAliasBox.Items -contains $voiceLabel) { $VoiceRuleAliasBox.SelectedItem = $voiceLabel }
})

$AddPlaylistButton.Add_Click({
    $v = Show-PlaylistDialog $null
    if ($v) { Save-Playlist $null $v }
})
$EditPlaylistButton.Add_Click({
    $row = $PlaylistGrid.SelectedItem
    if (-not $row) { $BottomStatus.Text = 'Select a playlist to edit.'; return }
    $v = Show-PlaylistDialog $row
    if ($v) { Save-Playlist $row.Name $v }
})
$RemovePlaylistButton.Add_Click({
    $row = $PlaylistGrid.SelectedItem
    if (-not $row) { $BottomStatus.Text = 'Select a playlist to remove.'; return }
    $s = Read-Settings
    if ($s.voice_playlists -and $s.voice_playlists.PSObject.Properties[$row.Name]) {
        $s.voice_playlists.PSObject.Properties.Remove($row.Name)
        Write-Settings $s
        Refresh-Grid
        $BottomStatus.Text = 'Removed playlist "' + $row.Name + '"'
    }
})
$TestPlaylistButton.Add_Click({
    $row = $PlaylistGrid.SelectedItem
    if (-not $row) { $BottomStatus.Text = 'Select a playlist to test.'; return }
    $token = 'playlist:' + [string]$row.Name
    $text = Show-TestDialog $token
    if ($text) { Speak-Text $token $text 'Playlist test' }
})
$PlaylistGrid.Add_MouseDoubleClick({
    $row = $PlaylistGrid.SelectedItem
    if ($row) {
        $v = Show-PlaylistDialog $row
        if ($v) { Save-Playlist $row.Name $v }
    }
})

$AddRouteButton.Add_Click({ Save-RouteEditor $false })
$UpdateRouteButton.Add_Click({ Save-RouteEditor $true })
$RemoveRouteButton.Add_Click({ $index=$RoutingGrid.SelectedIndex;if($index -ge 0){$RoutingGrid.ItemsSource.RemoveAt($index)} })
$RouteUpButton.Add_Click({ $index=$RoutingGrid.SelectedIndex;if($index -gt 0){$RoutingGrid.ItemsSource.Move($index,$index-1);$RoutingGrid.SelectedIndex=$index-1} })
$RouteDownButton.Add_Click({ $index=$RoutingGrid.SelectedIndex;if($index -ge 0 -and $index -lt $RoutingGrid.Items.Count-1){$RoutingGrid.ItemsSource.Move($index,$index+1);$RoutingGrid.SelectedIndex=$index+1} })
$RoutingGrid.Add_SelectionChanged({
    $rule=$RoutingGrid.SelectedItem
    if($rule){
        foreach($item in $RouteFieldBox.Items){if($item.Tag -eq $rule.field){$RouteFieldBox.SelectedItem=$item;break}}
        $RouteValueBox.Text=$rule.value
        $RouteAliasBox.SelectedItem = ConvertFrom-SpeakVoiceToken ([string]$rule.alias)
        $RoutePrioritySlider.Value=[double]$rule.priority
    }
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
        Set-VoiceFavorite $row.Name (-not $row.Favorite)
        $BottomStatus.Text=if($row.Favorite){'Removed from favorites'}else{'Added to favorites'}
    }
})
$AliasGrid.Add_SelectionChanged({
    $row=$AliasGrid.SelectedItem;$ToggleFavoriteButton.IsEnabled=$null -ne $row
    $favLabel=$window.FindName('FavoriteButtonLabel'); if($favLabel){ $favLabel.Text=if($row -and $row.Favorite){'Unfavorite'}else{'Favorite'} } elseif($ToggleFavoriteButton){ $ToggleFavoriteButton.Content=if($row -and $row.Favorite){'Unfavorite'}else{'Favorite'} }
})
if (-not $script:ExportRandomLabel) { $script:ExportRandomLabel='Random (enabled voices)' }
$script:voicesDirty = $false
$AliasGrid.Add_PreviewMouseLeftButtonUp({
    param($sender, $e)
    try {
        $el = $e.OriginalSource
        while ($el -and -not ($el -is [System.Windows.Controls.CheckBox])) {
            $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
        }
        if (-not $el) { return }
        # Binding updates after click; mark dirty and require Save voices (avoids racing the old value to disk).
        $window.Dispatcher.BeginInvoke([Action]{ Mark-VoicesDirty }) | Out-Null
    } catch {}
})
if ($SaveVoicesButton) {
    $SaveVoicesButton.Add_Click({ Save-VoiceToggles })
}
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
    $picker = [Microsoft.Win32.OpenFileDialog]::new(); $picker.Filter = 'YapLoq presets (*.json)|*.json'
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
    $dialog = Load-Xaml (Join-Path $resourceRoot 'ImportPreview.xaml')
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
    $dialog=Load-Xaml (Join-Path $resourceRoot 'ImportPreview.xaml');$dialog.Owner=$window;$dialog.Resources.MergedDictionaries.Add($window.Resources);Apply-AppFont $dialog
    $dialog.FindName('PreviewTitle').Text='Reset settings'
    $dialog.FindName('PreviewNote').Text='Reset voices, rules, credentials and preferences to defaults? A backup is created first. History and saved audio are kept. Restart YapLoq afterward.'
    $dialog.FindName('PreviewList').Visibility='Collapsed'
    $dialog.FindName('PreviewImport').Content='Reset settings';$dialog.FindName('PreviewImport').Style=$window.FindResource('PrimaryButton')
    $dialog.FindName('PreviewTitleBar').Add_MouseLeftButtonDown({$dialog.DragMove()});$dialog.FindName('PreviewClose').Add_Click({$dialog.Close()});$dialog.FindName('PreviewCancel').Add_Click({$dialog.Close()});$dialog.FindName('PreviewImport').Add_Click({$dialog.DialogResult=$true})
    if($dialog.ShowDialog()){
        try { Invoke-BridgePost '/api/maintenance/reset' @{confirmation='RESET'} | Out-Null;Refresh-Grid;Refresh-BackupList;$BottomStatus.Text='Settings reset. Restart YapLoq to finish.' }
        catch { $BottomStatus.Text=$_.Exception.Message }
    }
})
$script:restoreSignal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, ('Local\' + $script:appIdentity + '.Restore'))
$script:playerPollClock = [Diagnostics.Stopwatch]::StartNew()
$script:playerStateNext = 0
$script:playerHistoryNext = 0
$script:stateTimer = [Windows.Threading.DispatcherTimer]::new()
$script:stateTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:stateTimer.Add_Tick({
    if ($script:restoreSignal.WaitOne(0)) { Restore-FromTray }
    # Fetch outside the dispatcher. A slow backend must not block clicks or animation.
    $now = $script:playerPollClock.ElapsedMilliseconds
    if ($script:activityTask) {
        if (-not $script:activityTask.IsCompleted -and ([datetime]::UtcNow - $script:activityStarted).TotalSeconds -gt 2) { $script:activityClient.CancelAsync() }
        Complete-ActivityRefresh
    }
    if ($script:playerStateTask -and -not $script:playerStateTask.IsCompleted -and ($now - $script:playerStateStarted) -gt 2000) { $script:playerStateClient.CancelAsync() }
    if ($script:playerHistoryTask -and -not $script:playerHistoryTask.IsCompleted -and ($now - $script:playerHistoryStarted) -gt 2000) { $script:playerHistoryClient.CancelAsync() }
    if ($script:playerStateTask -and $script:playerStateTask.IsCompleted) {
        try {
            $snapshot = ($script:playerStateTask.GetAwaiter().GetResult() | ConvertFrom-Json).result
            $script:backendOnline = $true
            $script:backendFailUntil = [datetime]::MinValue
            Refresh-ServiceState $snapshot $true
        } catch {
            $script:progressPlaying = $false
            $script:backendOnline = $false
            foreach ($button in @($NowPlayingPlayPauseButton,$NowPlayingPrevButton,$NowPlayingSkipButton,$NowPlayingClearButton,$NowPlayingStopClearButton)) { if ($button) { $button.IsEnabled = $false } }
            Stop-NowPlayingLoadingSpin
            $NowPlayingSubtitle.Text = 'Reconnecting to playback...'
        } finally {
            $script:playerStateClient.Dispose(); $script:playerStateTask = $null
        }
    }
    if ($script:playerHistoryTask -and $script:playerHistoryTask.IsCompleted) {
        try {
            $rawHistory = $script:playerHistoryTask.GetAwaiter().GetResult()
            if ($rawHistory -ne $script:playerHistoryRaw) {
                $script:playerHistorySnapshot = ($rawHistory | ConvertFrom-Json).result.history
                $script:playerHistoryRaw = $rawHistory
                $script:playerHistoryRevision++
            }
        } catch {}
        finally { $script:playerHistoryClient.Dispose(); $script:playerHistoryTask = $null }
    }
    if (-not $script:playerStateTask -and $now -ge $script:playerStateNext) {
        $script:playerStateClient = [Net.WebClient]::new()
        $script:playerStateClient.Proxy = $null
        $script:playerStateStarted = $now
        $script:playerStateTask = $script:playerStateClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri) + '/api/state'))
        $script:playerStateNext = $now + $(if ($window.IsVisible) { 250 } else { 1000 })
    }
    if (-not $script:playerHistoryTask -and $now -ge $script:playerHistoryNext) {
        $script:playerHistoryClient = [Net.WebClient]::new()
        $script:playerHistoryClient.Proxy = $null
        $script:playerHistoryStarted = $now
        $script:playerHistoryTask = $script:playerHistoryClient.DownloadStringTaskAsync([Uri]((Get-BridgeBaseUri) + '/api/history'))
        $script:playerHistoryNext = $now + $(if ($window.IsVisible) { 2000 } else { 5000 })
    }
    if ($window.IsVisible -and $ActivityPage.Visibility -eq 'Visible' -and $now -ge $script:activityNext) { Refresh-Activity; $script:activityNext = $now + 2000 }
})
$script:progressTimer = [Windows.Threading.DispatcherTimer]::new()
$script:progressTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$script:progressTimer.Add_Tick({
    try {
        if ($window.IsVisible -and $window.WindowState -ne 'Minimized' -and $script:progressPlaying -and -not $script:progressSeeking) {
            Update-NowPlayingProgressUi
        }
    } catch {}
})
$script:stateTimer.Start()
$script:progressTimer.Start()
$window.Add_Closed({
    $script:stateTimer.Stop()
    foreach ($client in @($script:playerStateClient,$script:playerHistoryClient,$script:activityClient)) { if ($client) { $client.CancelAsync(); $client.Dispose() } }
    if ($script:progressTimer) { $script:progressTimer.Stop() }
    if ($script:voiceRefreshTimer) { $script:voiceRefreshTimer.Stop() }
    if ($script:voiceWebClient) { $script:voiceWebClient.Dispose() }
    if ($script:voiceDeviceClient) { $script:voiceDeviceClient.CancelAsync(); $script:voiceDeviceClient.Dispose() }
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

. (Join-Path $resourceRoot 'assets\RuleEditors.ps1')
Install-NumericEditors
Install-ProfanityEditor
if ($script:isPreview) {
    . (Join-Path $resourceRoot 'assets\YapLoqShell.ps1')
    Install-YapLoqShell
}
try { Refresh-Grid } catch { $BottomStatus.Text = 'Could not load settings: ' + $_.Exception.Message }
Start-Backend

$window.Add_ContentRendered({
    $window.ShowInTaskbar = $true
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Activate()
    $script:allowHideToTray = $true
    Write-TrayLog 'allowHideToTray=true'
    Sync-TrayIconMode
    try { Start-AmbientMotion } catch {}
    $chrome = $window.Content
    if ($chrome) { Animate-In $chrome }
    $window.Dispatcher.BeginInvoke([action]{
        if (Wait-BackendReady 8000) { Update-BridgeStatus $true; $BottomStatus.Text = 'Bridge ready' }
        else { Update-BridgeStatus $false; $BottomStatus.Text = 'Bridge failed to start. Check Activity / bridge.log' }
        try { Refresh-Voices } catch {}
        Refresh-BackupList
        $initial = Read-Settings
        $getStarted = $window.FindName('GetStartedExpander')
        if ($getStarted) { $getStarted.IsExpanded = -not [bool]$initial.setup_completed }
        if ($script:isPreview) { Set-Page 'playground' } elseif ($initial.setup_completed) { Set-Page 'voices' } else { Set-Page 'settings' }
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
