# Requires -Version 5.1
# PSRPM Marketing & Documentation Screenshot Generator
# Generates ultra-high-DPI 2x Retina screenshots of PSRPM in Clean Light Mode
# Strict 7-bit ASCII, 100% in-memory WPF RenderTargetBitmap, zero csc.exe.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
$outDir    = Join-Path $repoRoot "screenshots"
$docsOut   = Join-Path $repoRoot "docs\screenshots"

if (-not (Test-Path $outDir))  { [void](New-Item -ItemType Directory -Path $outDir) }
if (-not (Test-Path $docsOut)) { [void](New-Item -ItemType Directory -Path $docsOut) }

# Clean old screenshots to ensure only fresh Light Mode assets exist
Get-ChildItem -Path $outDir -Filter "*.png" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $docsOut -Filter "*.png" | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " PSRPM Light Mode Ultra-HD (2x Scaling) Screenshot Generator" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# Load Required Assemblies
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Xaml -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue

# Dot-source Module Components
$privDir = Join-Path $repoRoot "PSRPM\Private"
. (Join-Path $privDir "ViewModelClasses.ps1")
. (Join-Path $privDir "DataCollector.ps1")
. (Join-Path $privDir "DeepInspector.ps1")
. (Join-Path $privDir "ProcessActions.ps1")
. (Join-Path $privDir "RunspaceEngine.ps1")

$uiDir = Join-Path $repoRoot "PSRPM\UI"
$iconPath = Join-Path $repoRoot "PSRPM\Assets\psrpm_24.png"
if (-not (Test-Path $iconPath)) {
    $iconPath = Join-Path $repoRoot "PSRPM\Assets\psrpm.png"
}
$iconFrame = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($iconPath))

$brushConv = [System.Windows.Media.BrushConverter]::new()

function Get-Brush([string]$hex) {
    $b = $brushConv.ConvertFromString($hex)
    if ($b.CanFreeze) { $b.Freeze() }
    return $b
}

# Helper: Wrap Content in a Clean Modern Light-Themed Window Frame
function New-ModernWindowFrame {
    param(
        [System.Windows.FrameworkElement]$content,
        [string]$title,
        [double]$width,
        [double]$height
    )

    # Disconnect from parent window if attached
    if ($content.Parent) {
        if ($content.Parent -is [System.Windows.Window]) {
            $content.Parent.Content = $null
        } elseif ($content.Parent -is [System.Windows.Controls.Panel]) {
            $content.Parent.Children.Remove($content)
        } elseif ($content.Parent -is [System.Windows.Controls.ContentControl]) {
            $content.Parent.Content = $null
        }
    }

    $bgWindow = "#F8FAFC"
    $bgTitle  = "#E2E8F0"
    $fgTitle  = "#0F172A"
    $brdColor = "#CBD5E1"
    $btnFg    = "#475569"

    $outerBorder = [System.Windows.Controls.Border]::new()
    if ($content.DataContext) { $outerBorder.DataContext = $content.DataContext }
    $outerBorder.Width = $width
    $outerBorder.Height = $height
    $outerBorder.Background = Get-Brush $bgWindow
    $outerBorder.BorderBrush = Get-Brush $brdColor
    $outerBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $outerBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $outerBorder.ClipToBounds = $true
    $outerBorder.SnapsToDevicePixels = $true

    $rootGrid = [System.Windows.Controls.Grid]::new()
    $rowTitle = [System.Windows.Controls.RowDefinition]::new()
    $rowTitle.Height = [System.Windows.GridLength]::new(32)
    $rowBody  = [System.Windows.Controls.RowDefinition]::new()
    $rowBody.Height  = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $rootGrid.RowDefinitions.Add($rowTitle)
    $rootGrid.RowDefinitions.Add($rowBody)

    # Title Bar
    $titleGrid = [System.Windows.Controls.Grid]::new()
    $titleGrid.Background = Get-Brush $bgTitle
    [System.Windows.Controls.Grid]::SetRow($titleGrid, 0)

    $colLeft = [System.Windows.Controls.ColumnDefinition]::new()
    $colLeft.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $colRight = [System.Windows.Controls.ColumnDefinition]::new()
    $colRight.Width = [System.Windows.GridLength]::Auto
    $titleGrid.ColumnDefinitions.Add($colLeft)
    $titleGrid.ColumnDefinitions.Add($colRight)

    # Left: Icon & Title
    $leftStack = [System.Windows.Controls.StackPanel]::new()
    $leftStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $leftStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $leftStack.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
    [System.Windows.Controls.Grid]::SetColumn($leftStack, 0)

    $img = [System.Windows.Controls.Image]::new()
    $img.Source = $iconFrame
    $img.Width  = 16
    $img.Height = 16
    $img.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $leftStack.Children.Add($img) | Out-Null

    $txtTitle = [System.Windows.Controls.TextBlock]::new()
    $txtTitle.Text = $title
    $txtTitle.Foreground = Get-Brush $fgTitle
    $txtTitle.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")
    $txtTitle.FontSize = 12.0
    $txtTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $txtTitle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $leftStack.Children.Add($txtTitle) | Out-Null

    $titleGrid.Children.Add($leftStack) | Out-Null

    # Right: Windows 11 Caption Buttons
    $btnStack = [System.Windows.Controls.StackPanel]::new()
    $btnStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnStack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    [System.Windows.Controls.Grid]::SetColumn($btnStack, 1)

    foreach ($btnChar in @("_", "[ ]", "X")) {
        $btnTb = [System.Windows.Controls.TextBlock]::new()
        $btnTb.Text = $btnChar
        $btnTb.Foreground = Get-Brush $btnFg
        $btnTb.FontSize = if ($btnChar -eq "[ ]") { 9.0 } else { 11.0 }
        $btnTb.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI")
        $btnTb.FontWeight = [System.Windows.FontWeights]::Normal
        $btnTb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $btnTb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $btnTb.Margin = [System.Windows.Thickness]::new(12, 0, 12, 0)
        $btnStack.Children.Add($btnTb) | Out-Null
    }
    $titleGrid.Children.Add($btnStack) | Out-Null

    $rootGrid.Children.Add($titleGrid) | Out-Null

    # Body
    [System.Windows.Controls.Grid]::SetRow($content, 1)
    $rootGrid.Children.Add($content) | Out-Null

    $outerBorder.Child = $rootGrid
    return $outerBorder
}

# Helper: Save FrameworkElement to PNG at 192 DPI (Double Scaling / 2x Retina)
function Export-ElementToPng {
    param(
        [System.Windows.FrameworkElement]$element,
        [string]$fileName,
        [double]$width,
        [double]$height,
        [double]$dpi = 192.0
    )

    $element.Width = $width
    $element.Height = $height

    $size = [System.Windows.Size]::new($width, $height)
    $element.Measure($size)
    $element.Arrange([System.Windows.Rect]::new(0, 0, $width, $height))
    $element.UpdateLayout()

    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Render,
        [Action]{}
    )

    $scale = $dpi / 96.0
    $pxW = [int]($width * $scale)
    $pxH = [int]($height * $scale)

    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $pxW, $pxH, $dpi, $dpi, [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $rtb.Render($element)

    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))

    $target1 = Join-Path $outDir $fileName
    $target2 = Join-Path $docsOut $fileName

    $fs1 = [System.IO.FileStream]::new($target1, [System.IO.FileMode]::Create)
    $enc.Save($fs1)
    $fs1.Close()

    [System.IO.File]::Copy($target1, $target2, $true)

    $sizeKB = [Math]::Round((Get-Item $target1).Length / 1024.0, 1)
    Write-Host "  [SAVED] $fileName ($sizeKB KB, ${pxW}x${pxH} @ 2x DPI)" -ForegroundColor Green
}

# Helper: Apply Light Theme to Window Resources
function Apply-WindowThemeLight {
    param([System.Windows.FrameworkElement]$win)

    $setBrush = {
        param($k, $hex)
        $b = Get-Brush $hex
        $win.Resources[$k] = $b
    }

    &$setBrush "BrushWindowBg"       "#F8FAFC"
    &$setBrush "BrushToolbarBg"      "#F1F5F9"
    &$setBrush "BrushSurfaceBg"      "#FFFFFF"
    &$setBrush "BrushHeaderBg"       "#E2E8F0"
    &$setBrush "BrushBorderSubtle"   "#CBD5E1"
    &$setBrush "BrushTreeLine"       "#64748B"
    &$setBrush "BrushTextPrimary"    "#0F172A"
    &$setBrush "BrushTextSecondary"  "#334155"
    &$setBrush "BrushTextMuted"      "#64748B"
    &$setBrush "BrushRowHover"       "#220284C7"
    &$setBrush "BrushRowSelectedBg"  "#006CBE"
    &$setBrush "BrushRowSelectedFg"  "#FFFFFF"
    &$setBrush "BrushSparkBg"        "#FFFFFF"
    &$setBrush "BrushSparkBorder"    "#94A3B8"
    &$setBrush "ColTint_CPU"          "#2222C55E"
    &$setBrush "ColTint_PrivateBytes" "#28EAB308"
    &$setBrush "ColTint_WorkingSet"   "#22F97316"
    &$setBrush "BrushMenuBg"         "#FFFFFF"
    &$setBrush "BrushMenuBorder"     "#CBD5E1"
    &$setBrush "BrushMenuHover"      "#F1F5F9"
}

# ------------------------------------------------------------------
# Build Authentic Enterprise Contoso Dataset (Zero Local Machine Info)
# ------------------------------------------------------------------
Write-Host "`n[STEP 1] Generating Contoso Remote Telemetry Dataset..." -ForegroundColor Yellow

$procsRaw = @(
    @{ id = 4;     p = 0;     ct = 1000; n = "System";        u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "System";                                                                 cmd = "System";                                                    desc = "NT Kernel & System";                        comp = "Microsoft Corporation"; prio = 8;  cat = "System";    ws = 14800000;  pb = 240000;     th = 194; hnd = 4820; cpu = 0.35 }
    @{ id = 112;   p = 4;     ct = 1050; n = "Registry";      u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "Registry";                                                               cmd = "Registry";                                                  desc = "Registry System Process";                   comp = "Microsoft Corporation"; prio = 8;  cat = "System";    ws = 62000000;  pb = 41000000;   th = 4;   hnd = 0;    cpu = 0.00 }
    @{ id = 468;   p = 4;     ct = 1100; n = "smss.exe";      u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\smss.exe";                                           cmd = "smss.exe";                                                  desc = "Session Manager Subsystem";                 comp = "Microsoft Corporation"; prio = 11; cat = "System";    ws = 1420000;   pb = 480000;     th = 3;   hnd = 48;   cpu = 0.00 }
    @{ id = 632;   p = 468;   ct = 1200; n = "csrss.exe";     u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\csrss.exe";                                          cmd = "csrss.exe ObjectDirectory=\Windows SharedSection=1024,20480"; desc = "Client Server Runtime Process";             comp = "Microsoft Corporation"; prio = 13; cat = "System";    ws = 5840000;   pb = 2840000;    th = 12;  hnd = 482;  cpu = 0.05 }
    @{ id = 724;   p = 468;   ct = 1300; n = "wininit.exe";   u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\wininit.exe";                                        cmd = "wininit.exe";                                               desc = "Windows Start-Up Application";              comp = "Microsoft Corporation"; prio = 13; cat = "System";    ws = 4920000;   pb = 1840000;    th = 4;   hnd = 184;  cpu = 0.00 }
    @{ id = 836;   p = 724;   ct = 1400; n = "services.exe";  u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\services.exe";                                       cmd = "C:\Windows\System32\services.exe";                          desc = "Services and Controller app";               comp = "Microsoft Corporation"; prio = 9;  cat = "Service";   ws = 12480000;  pb = 8920000;    th = 11;  hnd = 642;  cpu = 0.12 }
    @{ id = 1024;  p = 836;   ct = 1500; n = "svchost.exe";   u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\svchost.exe";                                        cmd = "svchost.exe -k DcomLaunch -p";                              desc = "Host Process for Windows Services (Dcom)";  comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 28400000;  pb = 14200000;   th = 38;  hnd = 840;  cpu = 0.08 }
    @{ id = 1240;  p = 836;   ct = 1600; n = "svchost.exe";   u = "NT AUTHORITY\NETWORK SERVICE";  arch = "x64"; path = "C:\Windows\System32\svchost.exe";                                        cmd = "svchost.exe -k RPCSS -p";                                   desc = "Host Process for Windows Services (RPCSS)"; comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 22100000;  pb = 11400000;   th = 24;  hnd = 512;  cpu = 0.04 }
    @{ id = 1488;  p = 836;   ct = 1700; n = "svchost.exe";   u = "NT AUTHORITY\LOCAL SERVICE";    arch = "x64"; path = "C:\Windows\System32\svchost.exe";                                        cmd = "svchost.exe -k LocalServiceNetworkRestricted -p";           desc = "Host Process (LocalService)";               comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 18900000;  pb = 9840000;    th = 18;  hnd = 394;  cpu = 0.02 }
    @{ id = 1620;  p = 836;   ct = 1800; n = "svchost.exe";   u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\svchost.exe";                                        cmd = "svchost.exe -k netsvcs -p";                                 desc = "Host Process (netsvcs, Windows Update)";    comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 46200000;  pb = 32800000;   th = 42;  hnd = 920;  cpu = 0.15 }
    @{ id = 2108;  p = 836;   ct = 1900; n = "spoolsv.exe";   u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\spoolsv.exe";                                        cmd = "C:\Windows\System32\spoolsv.exe";                           desc = "Spooler SubSystem App";                     comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 14200000;  pb = 6840000;    th = 8;   hnd = 284;  cpu = 0.00 }
    @{ id = 2840;  p = 836;   ct = 2000; n = "MsMpEng.exe";   u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Program Files\Windows Defender\MsMpEng.exe";                          cmd = "MsMpEng.exe";                                               desc = "Antimalware Service Executable";            comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 168400000; pb = 142000000;  th = 32;  hnd = 1240; cpu = 0.42 }
    @{ id = 3680;  p = 836;   ct = 2100; n = "sqlservr.exe";  u = "NT SERVICE\MSSQLSERVER";        arch = "x64"; path = "C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\Binn\sqlservr.exe"; cmd = "sqlservr.exe -sMSSQLSERVER";                            desc = "SQL Server Windows NT - 64 Bit";            comp = "Microsoft Corporation"; prio = 9;  cat = "Service";   ws = 948000000; pb = 1420000000; th = 118; hnd = 3420; cpu = 1.84 }
    @{ id = 5410;  p = 836;   ct = 2200; n = "w3wp.exe";      u = "IIS APPPOOL\DefaultAppPool";    arch = "x64"; path = "C:\Windows\System32\inetsrv\w3wp.exe";                                   cmd = "w3wp.exe -ap DefaultAppPool -v v4.0 -l webengine4.dll";     desc = "IIS Worker Process (API Gateway)";          comp = "Microsoft Corporation"; prio = 8;  cat = "Service";   ws = 342000000; pb = 312000000;  th = 48;  hnd = 1140; cpu = 0.65 }
    @{ id = 848;   p = 724;   ct = 2300; n = "lsass.exe";     u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\lsass.exe";                                          cmd = "C:\Windows\System32\lsass.exe";                             desc = "Local Security Authority Process";          comp = "Microsoft Corporation"; prio = 9;  cat = "System";    ws = 38400000;  pb = 22100000;   th = 14;  hnd = 890;  cpu = 0.06 }
    @{ id = 912;   p = 468;   ct = 2400; n = "winlogon.exe";  u = "NT AUTHORITY\SYSTEM";           arch = "x64"; path = "C:\Windows\System32\winlogon.exe";                                       cmd = "winlogon.exe";                                              desc = "Windows Logon Application";                 comp = "Microsoft Corporation"; prio = 13; cat = "System";    ws = 11200000;  pb = 5400000;    th = 6;   hnd = 240;  cpu = 0.00 }
    @{ id = 1184;  p = 912;   ct = 2500; n = "dwm.exe";       u = "Window Manager\DWM-1";          arch = "x64"; path = "C:\Windows\System32\dwm.exe";                                           cmd = "dwm.exe";                                                   desc = "Desktop Window Manager";                    comp = "Microsoft Corporation"; prio = 13; cat = "System";    ws = 88400000;  pb = 54200000;   th = 19;  hnd = 680;  cpu = 0.95 }
    @{ id = 3400;  p = 912;   ct = 2600; n = "userinit.exe";  u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Windows\System32\userinit.exe";                                      cmd = "userinit.exe";                                              desc = "Userinit Logon Application";                comp = "Microsoft Corporation"; prio = 8;  cat = "System";    ws = 7400000;   pb = 3200000;    th = 3;   hnd = 92;   cpu = 0.00 }
    @{ id = 4820;  p = 3400;  ct = 2700; n = "explorer.exe";  u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Windows\explorer.exe";                                               cmd = "C:\Windows\explorer.exe";                                   desc = "Windows Explorer";                          comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 124000000; pb = 88000000;   th = 74;  hnd = 3120; cpu = 0.72 }
    @{ id = 6812;  p = 4820;  ct = 2800; n = "msedge.exe";    u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe";         cmd = "msedge.exe --profile-directory=Default";                    desc = "Microsoft Edge Browser";                    comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 198000000; pb = 142000000;  th = 58;  hnd = 2410; cpu = 1.45 }
    @{ id = 7120;  p = 6812;  ct = 2850; n = "msedge.exe";    u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe";         cmd = "msedge.exe --type=gpu-process";                             desc = "Microsoft Edge (GPU Process)";              comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 94000000;  pb = 68000000;   th = 22;  hnd = 640;  cpu = 0.65 }
    @{ id = 7450;  p = 6812;  ct = 2900; n = "msedge.exe";    u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe";         cmd = "msedge.exe --type=renderer --site=github.com/exh555/psrpm";  desc = "Microsoft Edge (GitHub / exh555/psrpm)";    comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 138000000; pb = 94000000;   th = 18;  hnd = 420;  cpu = 0.32 }
    @{ id = 7892;  p = 6812;  ct = 2950; n = "msedge.exe";    u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe";         cmd = "msedge.exe --type=renderer --site=reddit.com/r/PowerShell"; desc = "Microsoft Edge (Reddit r/PowerShell)";     comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 126000000; pb = 88000000;   th = 16;  hnd = 380;  cpu = 0.28 }
    @{ id = 9450;  p = 4820;  ct = 3000; n = "Code.exe";      u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files\Microsoft VS Code\Code.exe";                           cmd = "Code.exe C:\Projects\Production\PSRPM";                     desc = "Visual Studio Code";                        comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 214000000; pb = 164000000;  th = 44;  hnd = 1820; cpu = 0.55 }
    @{ id = 9680;  p = 9450;  ct = 3050; n = "Code.exe";      u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files\Microsoft VS Code\Code.exe";                           cmd = "Code.exe --type=utility --utility-sub-type=node.mojom";     desc = "VS Code (Extension Host: PSScriptAnalyzer)"; comp = "Microsoft Corporation"; prio = 8; cat = "Own";       ws = 82000000;  pb = 54000000;   th = 12;  hnd = 410;  cpu = 0.18 }
    @{ id = 10840; p = 9450;  ct = 3100; n = "powershell.exe"; u = "CONTOSO\svc-monitor";          arch = "x64"; path = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";              cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass";         desc = "Windows PowerShell (VS Code Terminal)";     comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 64200000;  pb = 42100000;   th = 14;  hnd = 580;  cpu = 0.15 }
    @{ id = 11200; p = 4820;  ct = 3200; n = "WindowsTerminal.exe"; u = "CONTOSO\svc-monitor";     arch = "x64"; path = "C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.19.10573.0_x64__8wekyb3d8bbwe\WindowsTerminal.exe"; cmd = "WindowsTerminal.exe"; desc = "Windows Terminal"; comp = "Microsoft Corporation"; prio = 8; cat = "Packaged";  ws = 78400000;  pb = 48200000;   th = 28;  hnd = 920;  cpu = 0.12 }
    @{ id = 11680; p = 11200; ct = 3250; n = "pwsh.exe";      u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Program Files\PowerShell\7\pwsh.exe";                                cmd = "pwsh.exe -NoLogo";                                          desc = "PowerShell 7.4 Core Terminal";              comp = "Microsoft Corporation"; prio = 8;  cat = "Own";       ws = 72100000;  pb = 52400000;   th = 16;  hnd = 610;  cpu = 0.18 }
    @{ id = 12260; p = 11200; ct = 3300; n = "powershell.exe"; u = "CONTOSO\svc-monitor";          arch = "x64"; path = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";              cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Monitor.ps1"; desc = "Windows PowerShell Remote Target Engine"; comp = "Microsoft Corporation"; prio = 8; cat = "Own"; ws = 56800000; pb = 38400000; th = 15; hnd = 520; cpu = 0.12 }
    @{ id = 12940; p = 12260; ct = 3350; n = "conhost.exe";   u = "CONTOSO\svc-monitor";           arch = "x64"; path = "C:\Windows\System32\conhost.exe";                                        cmd = "conhost.exe 0xffffffff -ForceV1";                           desc = "Console Window Host";                       comp = "Microsoft Corporation"; prio = 8;  cat = "System";    ws = 18400000;  pb = 9200000;    th = 5;   hnd = 190;  cpu = 0.02 }
)

# Populate Summary ViewModel
$sumVm = [SystemSummaryViewModel]::new()
$sumVm.HwMachine           = "Dell PowerEdge R750 Enterprise Cloud Node"
$sumVm.HwHost              = "SRV-PROD-01.contoso.corp"
$sumVm.HwOS                = "Windows Server 2022 Datacenter (Build 20348.2405)"
$sumVm.HwCpuName           = "Intel(R) Xeon(R) Gold 6348 CPU @ 2.60GHz"
$sumVm.HwArch              = "x64"
$sumVm.HwCoresCount        = "16"
$sumVm.HwSocketsCount      = "2"
$sumVm.HwLogicalCount      = "32"
$sumVm.HwCoresText         = "16 physical / 32 logical"
$sumVm.HwMemoryGBText      = "64.0 GB"
$sumVm.HwCommitLimitGBText = "81.2 GB"
$sumVm.HwBootDrive         = "C:\"
$sumVm.HwDriveType         = "NVMe SSD"
$sumVm.HwCapacityGBText    = "1,862.0 GB"
$sumVm.HwAvailableGBText   = "1,248.5 GB"
$sumVm.HwFileSystem        = "NTFS"

# ------------------------------------------------------------------
# Clear queues and populate rich, authentic performance history
# ------------------------------------------------------------------
# 1. Mini Sparklines (30 Samples) for Main Window Toolbar
$sumVm.CpuHistory.Clear()
$sumVm.CommitHistory.Clear()
$sumVm.RamHistory.Clear()

for ($i = 0; $i -lt 30; $i++) {
    $cpuVal = [Math]::Sin($i * 0.3) * 22.0 + 44.0  # Range 22% - 66%
    $comVal = [Math]::Sin($i * 0.2) * 7.0 + 35.0   # Range 28% - 42%
    $ramVal = [Math]::Cos($i * 0.2) * 4.0 + 52.0   # Range 48% - 56%
    $sumVm.CpuHistory.Enqueue($cpuVal)
    $sumVm.CommitHistory.Enqueue($comVal)
    $sumVm.RamHistory.Enqueue($ramVal)
}

$spCpu = $sumVm.BuildSparkline($sumVm.CpuHistory.ToArray(), 86.0, 26.0)
$sumVm.CpuPoints     = $spCpu[0]
$sumVm.CpuFillPoints = $spCpu[1]

$spCom = $sumVm.BuildSparkline($sumVm.CommitHistory.ToArray(), 90.0, 26.0)
$sumVm.CommitPoints     = $spCom[0]
$sumVm.CommitFillPoints = $spCom[1]

$spRam = $sumVm.BuildSparkline($sumVm.RamHistory.ToArray(), 96.0, 26.0)
$sumVm.RamPoints     = $spRam[0]
$sumVm.RamFillPoints = $spRam[1]

# 2. System Information Charts (240 Samples) for 4-Quadrant Dashboard
$sumVm.CpuHistory240.Clear()
$sumVm.KernelHistory240.Clear()
$sumVm.CommitHistory240.Clear()
$sumVm.RamHistory240.Clear()
$sumVm.IoTotalHistory240.Clear()
$sumVm.IoWriteHistory240.Clear()

for ($i = 0; $i -lt 240; $i++) {
    $cVal   = [Math]::Sin($i * 0.12) * 28.0 + [Math]::Cos($i * 0.28) * 12.0 + 45.0
    $cVal   = [Math]::Max(6.0, [Math]::Min(94.0, $cVal))
    $kVal   = $cVal * 0.26
    $comVal = [Math]::Sin($i * 0.08) * 10.0 + 38.0
    $ramVal = [Math]::Cos($i * 0.05) * 5.0 + 52.0
    $ioTot  = ([Math]::Abs([Math]::Sin($i * 0.14)) * 28.0 + [Math]::Cos($i * 0.3) * 8.0 + 12.0) * 1048576.0
    $ioWrt  = $ioTot * 0.42

    $sumVm.CpuHistory240.Enqueue($cVal)
    $sumVm.KernelHistory240.Enqueue($kVal)
    $sumVm.CommitHistory240.Enqueue($comVal)
    $sumVm.RamHistory240.Enqueue($ramVal)
    $sumVm.IoTotalHistory240.Enqueue($ioTot)
    $sumVm.IoWriteHistory240.Enqueue($ioWrt)
}

# 3. Multi-Core CPU ViewModels (16 Cores) for CPU Tab
while ($sumVm.CoreGraphs.Count -lt 16) {
    $sumVm.CoreGraphs.Add([CpuCoreGraphViewModel]::new($sumVm.CoreGraphs.Count))
}

for ($c = 0; $c -lt 16; $c++) {
    $cg = $sumVm.CoreGraphs[$c]
    $cg.TotalHistory.Clear()
    $cg.KernelHistory.Clear()
    $phase = $c * 0.45
    for ($s = 0; $s -lt 60; $s++) {
        $cLoad = [Math]::Sin(($s * 0.16) + $phase) * 32.0 + [Math]::Cos(($s * 0.38) + $phase) * 14.0 + 48.0
        $cLoad = [Math]::Max(4.0, [Math]::Min(96.0, $cLoad))
        $kLoad = $cLoad * 0.24
        $cg.EnqueueSample($cLoad, $kLoad, $false)
    }
    $cg.BuildCoreGeometry()
}

$sumVm.UpdateSummary(
    48.2,                     # CPU %
    34078L,                   # RAM Used MB (52.0% of 65536 MB)
    65536L,                   # RAM Total MB (64.0 GB)
    78,                       # Processes
    1840,                     # Threads
    42850,                    # Handles
    30856L,                   # Commit Used MB (38.0% of 81200 MB)
    81200L                    # Commit Limit MB (81.2 GB)
)

# Re-apply sparkline points to ensure pristine waveform curves
$sumVm.CpuPoints        = $spCpu[0]
$sumVm.CpuFillPoints    = $spCpu[1]
$sumVm.CommitPoints     = $spCom[0]
$sumVm.CommitFillPoints = $spCom[1]
$sumVm.RamPoints        = $spRam[0]
$sumVm.RamFillPoints    = $spRam[1]

# Extended Telemetry Values for Detail Cards & Gauges
$sysExtended = @(
    48.2,       # 0: sysCpu
    34078,      # 1: ramUsedMB
    65536,      # 2: ramTotalMB
    78,         # 3: totalProcs
    1840,       # 4: totalThreads
    42850,      # 5: totalHandles
    30856,      # 6: commitUsedMB
    81200,      # 7: commitLimitMB
    12.5,       # 8: kernCpu
    31596544,   # 9: commitCurKB
    83148800,   # 10: commitLimKB
    42400000,   # 11: commitPeakKB
    67108864,   # 12: physTotalKB
    32213760,   # 13: physAvailKB
    14840000,   # 14: sysCacheKB
    421888,     # 15: kernelPagedKB
    290816,     # 16: kernelNonPagedKB
    1240,       # 17: pfDelta
    184,        # 18: prDelta
    42,         # 19: pfwDelta
    12,         # 20: mfwDelta
    14820,      # 21: csDelta (Context Switches / sec)
    4180,       # 22: intrDelta (Interrupts / sec)
    32450,      # 23: scDelta (System Calls / sec)
    24800000,   # 24: ioReadDelta (Bytes/s)
    12400000,   # 25: ioWriteDelta (Bytes/s)
    1200000     # 26: ioOtherDelta (Bytes/s)
)

$sumVm.UpdateExtendedTelemetry($sysExtended, $null)

# Generate large 240-point chart geometry and gauge heights
$sumVm.IsSysInfoOpen = $true
$sumVm.RefreshSysInfoGraphs()

# Populate Multi-Host Contoso Tabs (Zero Local Machine)
$hostTabs = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()

$tab1 = [HostTabItemViewModel]::new("tab_1", "SRV-PROD-01", "SRV-PROD-01.contoso.corp", "WINRM-SSL", $false, $sumVm)
$tab1.UpdateVisualState($true, $false, $false, "Connected", $false, 5)
$hostTabs.Add($tab1)

$tab2 = [HostTabItemViewModel]::new("tab_2", "SRV-DB-02", "SRV-DB-02.contoso.corp", "WINRM-SSL", $false, $null)
$tab2.UpdateVisualState($false, $false, $false, "Connected", $false, 7)
$hostTabs.Add($tab2)

$tab3 = [HostTabItemViewModel]::new("tab_3", "SRV-APP-03", "SRV-APP-03.contoso.corp", "WINRM", $false, $null)
$tab3.UpdateVisualState($false, $false, $false, "Connected", $false, 9)
$hostTabs.Add($tab3)

# Helper: Build Process Map & ViewModels (Light Theme Only)
function Build-ProcessMapLight {
    $pMap = [System.Collections.Generic.Dictionary[int, Object]]::new()
    foreach ($raw in $procsRaw) {
        $vm = [ProcessItemViewModel]::new()
        $vm.SetStaticMetadata($raw, $false)
        $vm.UpdateDynamic(
            [double]$raw['cpu'],
            [long]$raw['ws'],
            [long]$raw['pb'],
            [int]$raw['th'],
            [int]$raw['hnd'],
            0
        )
        if ($raw['n'] -eq "powershell.exe" -and $raw['id'] -eq 12260) {
            $vm.NameFontWeight = "Bold"
        }
        $pMap[$raw['id']] = $vm
    }
    foreach ($kvp in $pMap.GetEnumerator()) {
        $kvp.Value.PendingTreeCPU = $kvp.Value.CPU
    }
    foreach ($kvp in $pMap.GetEnumerator()) {
        $vm = $kvp.Value
        if ($vm.CPU -le 0.0) { continue }
        $curr = $vm
        $guard = 0
        while ($curr.ParentPID -gt 0 -and $curr.ParentPID -ne $curr.PID -and $pMap.ContainsKey($curr.ParentPID) -and $guard -lt 64) {
            $parentVm = $pMap[$curr.ParentPID]
            $parentVm.PendingTreeCPU += $vm.CPU
            $curr = $parentVm
            $guard++
        }
    }
    foreach ($kvp in $pMap.GetEnumerator()) {
        $kvp.Value.UpdateTreeCpu($kvp.Value.PendingTreeCPU)
    }
    return $pMap
}

# Helper: Build Tree Structure & ObservableCollection
function Build-ObservableTree {
    param(
        [System.Collections.Generic.Dictionary[int, Object]]$pMap,
        [string]$filter = "",
        [bool]$isTree = $true
    )

    $col = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()

    foreach ($v in $pMap.Values) {
        $v.Children.Clear()
        $v.HasChildren = $false
    }

    $roots = [System.Collections.Generic.List[Object]]::new()
    foreach ($v in $pMap.Values) {
        if ($v.ParentPID -gt 0 -and $pMap.ContainsKey($v.ParentPID) -and $v.ParentPID -ne $v.PID) {
            $parent = $pMap[$v.ParentPID]
            $parent.Children.Add($v)
            $parent.HasChildren = $true
        } else {
            $roots.Add($v)
        }
    }

    $directMatches = [System.Collections.Generic.HashSet[int]]::new()
    $ancestorSet   = [System.Collections.Generic.HashSet[int]]::new()

    if ($filter) {
        foreach ($v in $pMap.Values) {
            if ($v.Name.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $v.PID.ToString() -eq $filter) {
                [void]$directMatches.Add($v.PID)
                $curPid = $v.ParentPID
                while ($curPid -gt 0 -and $pMap.ContainsKey($curPid) -and -not $ancestorSet.Contains($curPid)) {
                    [void]$ancestorSet.Add($curPid)
                    $curPid = $pMap[$curPid].ParentPID
                }
            }
        }
    }

    if (-not $isTree) {
        foreach ($v in $pMap.Values) {
            if (-not $filter -or $directMatches.Contains($v.PID)) {
                $v.UpdateTreeState(0, $false, $false, "", 1.0)
                $col.Add($v)
            }
        }
        return $col
    }

    $traverse = {
        param($node, $depth, $isLastArr)

        $isMatch = ($directMatches.Contains($node.PID))
        $isAnc   = ($ancestorSet.Contains($node.PID))

        if ($filter -and -not $isMatch -and -not $isAnc) {
            return
        }

        $opacity = if ($filter -and $isAnc -and -not $isMatch) { 0.62 } else { 1.0 }

        $geom = [System.Text.StringBuilder]::new()
        for ($k = 0; $k -lt $depth; $k++) {
            $bx = 7.5 + ($k * 16.0)
            if ($k -eq ($depth - 1)) {
                $isLast = $isLastArr[$k]
                if ($isLast) {
                    [void]$geom.Append("M $bx,0 L $bx,11.5 L $($bx + 7.5),11.5 ")
                } else {
                    [void]$geom.Append("M $bx,0 L $bx,23 M $bx,11.5 L $($bx + 7.5),11.5 ")
                }
            } else {
                if (-not $isLastArr[$k]) {
                    [void]$geom.Append("M $bx,0 L $bx,23 ")
                }
            }
        }

        $node.UpdateTreeState($depth, $true, ($node.Children.Count -gt 0), $geom.ToString().Trim(), $opacity)
        $col.Add($node)

        $children = @($node.Children)
        for ($c = 0; $c -lt $children.Count; $c++) {
            $childLastArr = [bool[]]::new($depth + 1)
            for ($x = 0; $x -lt $depth; $x++) { $childLastArr[$x] = $isLastArr[$x] }
            $childLastArr[$depth] = ($c -eq ($children.Count - 1))
            &$traverse $children[$c] ($depth + 1) $childLastArr
        }
    }

    for ($r = 0; $r -lt $roots.Count; $r++) {
        $rootLastArr = @($r -eq ($roots.Count - 1))
        &$traverse $roots[$r] 0 $rootLastArr
    }

    return $col
}

$mainXamlBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "MainWindow.xaml"))

# ------------------------------------------------------------------
# SCREENSHOT 1: Main Window (Light Mode Hero - Wide 1520x840 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 1] Capturing Main Window (Wide Light Mode, 192 DPI)..." -ForegroundColor Yellow

$ms1 = [System.IO.MemoryStream]::new($mainXamlBytes)
$win1 = [System.Windows.Markup.XamlReader]::Load($ms1)
$ms1.Close()

Apply-WindowThemeLight $win1
$pMap1 = Build-ProcessMapLight
$tree1 = Build-ObservableTree $pMap1 "" $true

$grid1 = $win1.FindName("GridProcesses")
$grid1.ItemsSource = $tree1

$sumBar1 = $win1.FindName("SummaryBar")
$sumBar1.DataContext = $sumVm

$tabs1 = $win1.FindName("HostTabsList")
if ($tabs1) { $tabs1.ItemsSource = $hostTabs }

$statText1 = $win1.FindName("StatusText")
if ($statText1) {
    $statText1.Text = "CPU Usage: 48.2% (K: 12.5%) | Commit Charge: 38.0% 30.8/81.2 GB | Processes: 78 | Physical Usage: 52.0% | Wire: 1.18 KB (5 ms)"
}
$txtTelem1 = $win1.FindName("TxtTelemTransport")
if ($txtTelem1) { $txtTelem1.Text = "WINRM-SSL | RTT: 5ms (avg 5.2ms)" }
$txtWire1 = $win1.FindName("TxtTelemPayload")
if ($txtWire1) { $txtWire1.Text = "Wire: 1.18 KB (87% GZIP)" }
$txtBw1 = $win1.FindName("TxtTelemNetwork")
if ($txtBw1) { $txtBw1.Text = "BW: 1.18 KB/s | RX: 24.8 KB" }
$txtSeq1 = $win1.FindName("TxtTelemDelta")
if ($txtSeq1) { $txtSeq1.Text = "Seq #0042 | Dyn: 14 (+0/-0)" }

$frame1 = New-ModernWindowFrame $win1.Content "PSRPM - PowerShell Remote Process Manager [SRV-PROD-01.contoso.corp (WINRM-SSL)]" 1520 840
Export-ElementToPng $frame1 "01_process_tree_light.png" 1520 840 192.0

# ------------------------------------------------------------------
# SCREENSHOT 2: Ancestor-Preserving Search Filter (Wide 1520x840 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 2] Capturing Ancestor-Preserving Search Filter (192 DPI)..." -ForegroundColor Yellow

$ms2 = [System.IO.MemoryStream]::new($mainXamlBytes)
$win2 = [System.Windows.Markup.XamlReader]::Load($ms2)
$ms2.Close()

Apply-WindowThemeLight $win2
$pMap2 = Build-ProcessMapLight
$tree2 = Build-ObservableTree $pMap2 "powershell" $true

$grid2 = $win2.FindName("GridProcesses")
$grid2.ItemsSource = $tree2

$sumBar2 = $win2.FindName("SummaryBar")
$sumBar2.DataContext = $sumVm

$tabs2 = $win2.FindName("HostTabsList")
if ($tabs2) { $tabs2.ItemsSource = $hostTabs }

$txtSearch2 = $win2.FindName("TxtSearch")
if ($txtSearch2) { $txtSearch2.Text = "powershell" }

$badge2 = $win2.FindName("TxtSearchCount")
if ($badge2) {
    $badge2.Text = "Matches: 2 found (4 ancestors preserved)"
    $badge2.Visibility = "Visible"
}

$statText2 = $win2.FindName("StatusText")
if ($statText2) {
    $statText2.Text = "Filter active: 'powershell' (Showing 2 matching processes with ancestor context preserved)"
}
$txtTelem2 = $win2.FindName("TxtTelemTransport")
if ($txtTelem2) { $txtTelem2.Text = "WINRM-SSL | RTT: 5ms" }
$txtWire2 = $win2.FindName("TxtTelemPayload")
if ($txtWire2) { $txtWire2.Text = "Wire: 1.18 KB" }

$frame2 = New-ModernWindowFrame $win2.Content "PSRPM - PowerShell Remote Process Manager [SRV-PROD-01.contoso.corp] - Filter: 'powershell'" 1520 840
Export-ElementToPng $frame2 "02_ancestor_search_filter.png" 1520 840 192.0

# ------------------------------------------------------------------
# SCREENSHOT 3: System Information Dashboard - Summary Tab (920x700 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 3] Capturing System Information (Summary Tab, 192 DPI)..." -ForegroundColor Yellow

$sumVm.SetPerCpuMode($false)
$sysBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "SystemInfoWindow.xaml"))
$msSys = [System.IO.MemoryStream]::new($sysBytes)
$winSys = [System.Windows.Markup.XamlReader]::Load($msSys)
$msSys.Close()

$winSys.DataContext = $sumVm
$winSys.Content.DataContext = $sumVm
$tcSys = $winSys.FindName("SysInfoTabControl")
if ($tcSys) { $tcSys.SelectedIndex = 0 } # Summary Tab

$frame3 = New-ModernWindowFrame $winSys.Content "System Information [SRV-PROD-01.contoso.corp]" 920 700
$frame3.DataContext = $sumVm
Export-ElementToPng $frame3 "03_system_information_dashboard.png" 920 700 192.0

# ------------------------------------------------------------------
# SCREENSHOT 4: System Information - Multi-Core CPU Tab (920x700 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 4] Capturing System Information (Multi-Core CPU Tab, 192 DPI)..." -ForegroundColor Yellow

$sumVm.SetPerCpuMode($true)
$msSys2 = [System.IO.MemoryStream]::new($sysBytes)
$winSys2 = [System.Windows.Markup.XamlReader]::Load($msSys2)
$msSys2.Close()

$winSys2.DataContext = $sumVm
$winSys2.Content.DataContext = $sumVm
$tcSys2 = $winSys2.FindName("SysInfoTabControl")
if ($tcSys2) { $tcSys2.SelectedIndex = 1 } # CPU Tab

$chkPerCpu = $winSys2.FindName("ChkPerCpuGraph")
if ($chkPerCpu) { $chkPerCpu.IsChecked = $true }

$frame4 = New-ModernWindowFrame $winSys2.Content "System Information [SRV-PROD-01.contoso.corp] - Multi-Core CPU (16 Cores)" 920 700
$frame4.DataContext = $sumVm
Export-ElementToPng $frame4 "04_system_information_cpu.png" 920 700 192.0

# ------------------------------------------------------------------
# SCREENSHOT 5: Process Properties Inspector - Image Tab (860x680 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 5] Capturing Process Properties (Image Tab, 192 DPI)..." -ForegroundColor Yellow

$propBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "PropertiesWindow.xaml"))
$msProp = [System.IO.MemoryStream]::new($propBytes)
$winProp = [System.Windows.Markup.XamlReader]::Load($msProp)
$msProp.Close()

$winProp.FindName("PropHeaderName").Text   = "powershell.exe"
$winProp.FindName("PropHeaderPid").Text    = "PID: 12260"
$winProp.FindName("PropDescription").Text  = "Windows PowerShell Remote Target Engine"
$winProp.FindName("PropCompany").Text      = "Microsoft Corporation"
$winProp.FindName("PropVersion").Text      = "10.0.20348.2405"
$winProp.FindName("PropBuildTime").Text    = "2024-03-12 18:24:10"
$winProp.FindName("PropPath").Text         = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$winProp.FindName("PropCmdLine").Text      = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Monitor.ps1"
$winProp.FindName("PropWorkDir").Text      = "C:\Scripts\"
$winProp.FindName("PropAutostart").Text    = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run (TelemetryWorker)"
$winProp.FindName("PropParentPid").Text    = "WindowsTerminal.exe (11200)"
$winProp.FindName("PropUser").Text         = "CONTOSO\svc-monitor (S-1-5-21-34829104-2849102-1001)"
$winProp.FindName("PropStartTime").Text    = "2026-11-07 14:22:18 (Uptime: 04:31:52)"
$winProp.FindName("PropArch").Text         = "64-bit (x64)"
$winProp.FindName("PropSignature").Text    = "Verified: Microsoft Windows (Authenticode Valid)"
$winProp.FindName("PropIcon").Source       = $iconFrame

$frame5 = New-ModernWindowFrame $winProp.Content "powershell.exe:12260 Properties [SRV-PROD-01.contoso.corp]" 860 680
Export-ElementToPng $frame5 "05_process_properties_image.png" 860 680 192.0

# ------------------------------------------------------------------
# SCREENSHOT 6: Process Properties Inspector - Performance & Ancestry (860x680 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 6] Capturing Process Properties (Performance & Ancestry, 192 DPI)..." -ForegroundColor Yellow

$msPropPerf = [System.IO.MemoryStream]::new($propBytes)
$winPropPerf = [System.Windows.Markup.XamlReader]::Load($msPropPerf)
$msPropPerf.Close()

$winPropPerf.FindName("PropHeaderName").Text  = "powershell.exe"
$winPropPerf.FindName("PropHeaderPid").Text   = "PID: 12260"
$winPropPerf.FindName("PropDescription").Text = "Windows PowerShell Remote Target Engine"
$winPropPerf.FindName("PropCompany").Text     = "Microsoft Corporation"
$winPropPerf.FindName("PropIcon").Source      = $iconFrame

# Switch to Performance Tab (Index 1)
$tcPropPerf = $winPropPerf.FindName("PropTabControl")
if ($tcPropPerf) { $tcPropPerf.SelectedIndex = 1 }

$winPropPerf.FindName("PropCpu").Text                = "CPU Usage: 0.15% (Normalized)"
$winPropPerf.FindName("PropTotalCpuTime").Text        = "Total Processor Time: 00:03:42.184"
$winPropPerf.FindName("PropKernelUserTime").Text      = "Kernel: 00:01:12.450 | User: 00:02:29.734"
$winPropPerf.FindName("PropCycles").Text              = "Cycles: 8,492,108,440"
$winPropPerf.FindName("PropThreadsHandles").Text      = "Threads: 15 | Handles: 520 (USER: 4, GDI: 8)"
$winPropPerf.FindName("PropPrivateBytes").Text        = "Private Bytes: 38,400 K (Peak: 44,200 K)"
$winPropPerf.FindName("PropRam").Text                 = "Working Set: 56,800 K (Peak: 62,400 K, WS Private: 38,400 K)"
$winPropPerf.FindName("PropVirtualPageFaults").Text   = "Virtual Size: 412 MB | Page Faults: 24,180"
$winPropPerf.FindName("PropPools").Text               = "Paged Pool: 480 K | Non-Paged Pool: 38 K"
$winPropPerf.FindName("PropIoCounters").Text          = "Reads: 1,420 (24.8 MB) | Writes: 680 (8.4 MB) | Other: 4,120"

# Populate focused parent-child process tree in the dialog
$propTree = [System.Collections.Generic.List[Object]]::new()
$parentTreeItem = [PSCustomObject]@{
    Name                  = "WindowsTerminal.exe"
    PID                   = 11200
    CPUFormatted          = "0.12"
    PrivateBytesFormatted = "48,200 K"
    MemoryFormatted       = "78,400 K"
    IsNodeExpanded        = $true
    IsTargetNode          = $false
    TargetBadgeVisibility = "Collapsed"
    NodeFontWeight        = "SemiBold"
    NodeBackground        = "Transparent"
    NodeBorderBrush       = "Transparent"
    Children              = [System.Collections.Generic.List[Object]]::new()
}
$targetTreeItem = [PSCustomObject]@{
    Name                  = "powershell.exe"
    PID                   = 12260
    CPUFormatted          = "0.15"
    PrivateBytesFormatted = "38,400 K"
    MemoryFormatted       = "56,800 K"
    IsNodeExpanded        = $true
    IsTargetNode          = $true
    TargetBadgeVisibility = "Visible"
    NodeFontWeight        = "Bold"
    NodeBackground        = "#E0F2FE"
    NodeBorderBrush       = "#0284C7"
    Children              = [System.Collections.Generic.List[Object]]::new()
}
$childTreeItem = [PSCustomObject]@{
    Name                  = "conhost.exe"
    PID                   = 12940
    CPUFormatted          = "0.02"
    PrivateBytesFormatted = "9,200 K"
    MemoryFormatted       = "18,400 K"
    IsNodeExpanded        = $true
    IsTargetNode          = $false
    TargetBadgeVisibility = "Collapsed"
    NodeFontWeight        = "Normal"
    NodeBackground        = "Transparent"
    NodeBorderBrush       = "Transparent"
    Children              = [System.Collections.Generic.List[Object]]::new()
}
$targetTreeItem.Children.Add($childTreeItem)
$parentTreeItem.Children.Add($targetTreeItem)
$propTree.Add($parentTreeItem)

$tvProp = $winPropPerf.FindName("PropProcessTree")
if ($tvProp) { $tvProp.ItemsSource = $propTree }

$frame6 = New-ModernWindowFrame $winPropPerf.Content "powershell.exe:12260 Properties [SRV-PROD-01.contoso.corp] - Performance & Tree" 860 680
Export-ElementToPng $frame6 "06_process_properties_performance.png" 860 680 192.0

# ------------------------------------------------------------------
# SCREENSHOT 7: Process Properties Inspector - Loaded DLLs (860x680 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 7] Capturing Process Properties (DLLs Tab, 192 DPI)..." -ForegroundColor Yellow

$msProp2 = [System.IO.MemoryStream]::new($propBytes)
$winProp2 = [System.Windows.Markup.XamlReader]::Load($msProp2)
$msProp2.Close()

$winProp2.FindName("PropHeaderName").Text  = "powershell.exe"
$winProp2.FindName("PropHeaderPid").Text   = "PID: 12260"
$winProp2.FindName("PropDescription").Text = "Windows PowerShell Remote Target Engine"
$winProp2.FindName("PropCompany").Text     = "Microsoft Corporation"
$winProp2.FindName("PropIcon").Source      = $iconFrame

# Switch to DLLs Tab (Index 2)
$tcProp2 = $winProp2.FindName("PropTabControl")
if ($tcProp2) { $tcProp2.SelectedIndex = 2 }

$gridDlls = $winProp2.FindName("GridPropDlls")
if ($gridDlls) {
    $dllList = [System.Collections.Generic.List[Object]]::new()
    $dllList.Add([PSCustomObject]@{ Name = "powershell.exe";                  Description = "Windows PowerShell";                CompanyName = "Microsoft Corporation"; Version = "10.0.20348.2405"; Size = "448 KB";  BaseAddress = "0x00007FF7B1200000"; Path = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" })
    $dllList.Add([PSCustomObject]@{ Name = "ntdll.dll";                       Description = "NT Layer DLL";                      CompanyName = "Microsoft Corporation"; Version = "10.0.20348.2405"; Size = "2.1 MB";   BaseAddress = "0x00007FFC9E500000"; Path = "C:\Windows\System32\ntdll.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "kernel32.dll";                    Description = "Windows NT BASE API Client DLL";    CompanyName = "Microsoft Corporation"; Version = "10.0.20348.2405"; Size = "784 KB";  BaseAddress = "0x00007FFC9D100000"; Path = "C:\Windows\System32\kernel32.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "KERNELBASE.dll";                  Description = "Windows NT BASE API Client DLL";    CompanyName = "Microsoft Corporation"; Version = "10.0.20348.2405"; Size = "3.4 MB";   BaseAddress = "0x00007FFC9BD00000"; Path = "C:\Windows\System32\KERNELBASE.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "mscoree.dll";                     Description = "Microsoft .NET Runtime Execution";  CompanyName = "Microsoft Corporation"; Version = "10.0.20348.2405"; Size = "412 KB";  BaseAddress = "0x00007FFC94E00000"; Path = "C:\Windows\System32\mscoree.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "clr.dll";                         Description = "Microsoft .NET Runtime Engine";     CompanyName = "Microsoft Corporation"; Version = "4.8.9261.0";      Size = "10.8 MB"; BaseAddress = "0x00007FFC8F200000"; Path = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\clr.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "mscorlib.ni.dll";                 Description = "Common Language Runtime Library";   CompanyName = "Microsoft Corporation"; Version = "4.8.9261.0";      Size = "24.2 MB"; BaseAddress = "0x00007FFC8C100000"; Path = "C:\Windows\assembly\NativeImages_v4.0.30319_64\mscorlib\mscorlib.ni.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "System.Management.Automation.dll"; Description = "PowerShell Engine Implementation"; CompanyName = "Microsoft Corporation"; Version = "3.0.0.0";         Size = "7.6 MB";  BaseAddress = "0x00007FFC72000000"; Path = "C:\Windows\Microsoft.Net\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "PresentationFramework.dll";       Description = "Windows Presentation Framework";    CompanyName = "Microsoft Corporation"; Version = "4.8.9261.0";      Size = "16.4 MB"; BaseAddress = "0x00007FFC68400000"; Path = "C:\Windows\Microsoft.Net\assembly\GAC_MSIL\PresentationFramework\v4.0_4.0.0.0__31bf3856ad364e35\PresentationFramework.dll" })
    $dllList.Add([PSCustomObject]@{ Name = "WindowsBase.dll";                 Description = "WindowsBase Implementation";        CompanyName = "Microsoft Corporation"; Version = "4.8.9261.0";      Size = "5.2 MB";  BaseAddress = "0x00007FFC66100000"; Path = "C:\Windows\Microsoft.Net\assembly\GAC_MSIL\WindowsBase\v4.0_4.0.0.0__31bf3856ad364e35\WindowsBase.dll" })
    $gridDlls.ItemsSource = $dllList
}

$frame7 = New-ModernWindowFrame $winProp2.Content "powershell.exe:12260 Properties [SRV-PROD-01.contoso.corp] - Loaded DLLs" 860 680
Export-ElementToPng $frame7 "07_process_properties_modules.png" 860 680 192.0

# ------------------------------------------------------------------
# SCREENSHOT 8: Live Audit & Network Telemetry Console (1520x880 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 8] Capturing Live Audit & Telemetry Console (192 DPI)..." -ForegroundColor Yellow

$ms7 = [System.IO.MemoryStream]::new($mainXamlBytes)
$win7 = [System.Windows.Markup.XamlReader]::Load($ms7)
$ms7.Close()

Apply-WindowThemeLight $win7
$pMap7 = Build-ProcessMapLight
$tree7 = Build-ObservableTree $pMap7 "" $true

$win7.FindName("GridProcesses").ItemsSource = $tree7
$win7.FindName("SummaryBar").DataContext    = $sumVm
if ($win7.FindName("HostTabsList")) { $win7.FindName("HostTabsList").ItemsSource = $hostTabs }

# Expand Log Drawer
$chkLog7 = $win7.FindName("ChkShowLog")
if ($chkLog7) { $chkLog7.IsChecked = $true }
$logPane7 = $win7.FindName("LogPane")
if ($logPane7) { $logPane7.Visibility = "Visible" }

$txtConsole7 = $win7.FindName("TxtLogConsole")
if ($txtConsole7) {
    $sbCon = [System.Text.StringBuilder]::new()
    [void]$sbCon.AppendLine("[18:42:09.840] [INIT]   PSRPM initialized for target 'SRV-PROD-01.contoso.corp' (Mode: WinRM-SSL PSSession, Interval: 1000ms).")
    [void]$sbCon.AppendLine("[18:42:10.124] [SYNC #1] Full Snapshot from 'SRV-PROD-01' (WINRM-SSL) | RTT: 5ms | Wire: 1.18 KB -> Raw: 9.42 KB (GZIP 87% saved) | Procs: 78, Services: 184")
    [void]$sbCon.AppendLine("[18:42:11.128] [TELEM]   Seq #0042 | RTT:   5ms (Avg: 5.2ms) | Wire:  0.28 KB -> Raw:  1.92 KB (GZIP 85%) | BW: 0.28 KB/s (RX: 24.8 KB) | Dyn: 14, +Meta: 0, -Exit: 0")
    [void]$sbCon.AppendLine("[18:42:12.130] [PROC+]   Spawned: conhost.exe (PID 12940, PPID 12260, User: CONTOSO\svc-monitor)")
    [void]$sbCon.AppendLine("[18:42:13.134] [TELEM]   Seq #0043 | RTT:   6ms (Avg: 5.2ms) | Wire:  0.31 KB -> Raw:  2.14 KB (GZIP 85%) | BW: 0.31 KB/s (RX: 25.1 KB) | Dyn: 14, +Meta: 1, -Exit: 0")
    [void]$sbCon.AppendLine("[18:42:14.138] [TELEM]   Seq #0044 | RTT:   5ms (Avg: 5.2ms) | Wire:  0.26 KB -> Raw:  1.84 KB (GZIP 86%) | BW: 0.26 KB/s (RX: 25.4 KB) | Dyn:  9, +Meta: 0, -Exit: 0")
    [void]$sbCon.AppendLine("[18:42:15.142] [ACTION]  User requested Process Properties Inspector on PID 12260 (powershell.exe).")
    [void]$sbCon.AppendLine("[18:42:15.160] [DEEP]    DeepInspector completed Core inspection for PID 12260 in 18ms (Payload: 1.4 KB).")
    $txtConsole7.Text = $sbCon.ToString()
}

$statText7 = $win7.FindName("StatusText")
if ($statText7) {
    $statText7.Text = "CPU Usage: 4.82% (K: 1.35%) | Commit Charge: 18.2% 14.8/81.2 GB | Wire: 1.18 KB (5 ms) | Log: Active"
}
$txtTelem7 = $win7.FindName("TxtTelemTransport")
if ($txtTelem7) { $txtTelem7.Text = "WINRM-SSL | RTT: 5ms" }
$txtWire7 = $win7.FindName("TxtTelemPayload")
if ($txtWire7) { $txtWire7.Text = "Wire: 1.18 KB (87% GZIP)" }

$frame8 = New-ModernWindowFrame $win7.Content "PSRPM - PowerShell Remote Process Manager [SRV-PROD-01.contoso.corp] - Live Telemetry Console" 1520 880
Export-ElementToPng $frame8 "08_live_telemetry_audit_console.png" 1520 880 192.0

# ------------------------------------------------------------------
# SCREENSHOT 9: Connect to Target System Dialog (520x400 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 9] Capturing Connect to Target Dialog (192 DPI)..." -ForegroundColor Yellow

$connBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "ConnectDialog.xaml"))
$msConn = [System.IO.MemoryStream]::new($connBytes)
$winConn = [System.Windows.Markup.XamlReader]::Load($msConn)
$msConn.Close()

$winConn.FindName("TxtConnectComputer").Text   = "SRV-PROD-01.contoso.corp"
$winConn.FindName("ChkUseSSL").IsChecked       = $true
$winConn.FindName("TxtConnectPort").Text       = "5986"
$winConn.FindName("TxtCredStatus").Text        = "CONTOSO\svc-monitor (Saved Profile)"
$winConn.FindName("ChkOpenInNewTab").IsChecked = $true

$frame9 = New-ModernWindowFrame $winConn.Content "Connect to Target System" 520 400
Export-ElementToPng $frame9 "09_connect_remote_winrm.png" 520 400 192.0

# ------------------------------------------------------------------
# SCREENSHOT 10: Services Manager Tab (1520x840 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 10] Capturing Services Manager Tab (192 DPI)..." -ForegroundColor Yellow

$winSvcMain = [System.Windows.Markup.XamlReader]::Load([System.IO.MemoryStream]::new([System.IO.File]::ReadAllBytes((Join-Path $uiDir "MainWindow.xaml"))))
$tabsMain = $winSvcMain.FindName("MainTabControl")
if ($tabsMain) { $tabsMain.SelectedIndex = 1 }

$sumVmSvc = [SystemSummaryViewModel]::new()
$sumVmSvc.UpdateSummary(3.4, 4294967296, 17179869184, 82, 1240, 48200, 5368709120, 21474836480)
$winSvcMain.FindName("SummaryBar").DataContext = $sumVmSvc

$svcSampleCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$sampleServices = @(
    @{ n = "LanmanServer";      d = "Server";                             p = 1024; st = "Running"; sm = "Auto";   u = "LocalSystem";                 dep = "SamSS, Srv2";              rev = "";                       desc = "Supports file, print, and named-pipe sharing over the network for this computer."; bin = "C:\Windows\System32\svchost.exe -k netsvcs -p" }
    @{ n = "LanmanWorkstation"; d = "Workstation";                        p = 1024; st = "Running"; sm = "Auto";   u = "LocalSystem";                 dep = "Bowser, MRxSmb20, NSI";     rev = "Netlogon";               desc = "Creates and maintains client network connections to remote servers using the SMB protocol."; bin = "C:\Windows\System32\svchost.exe -k NetworkService -p" }
    @{ n = "RpcSs";             d = "Remote Procedure Call (RPC)";        p = 836;  st = "Running"; sm = "Auto";   u = "NT AUTHORITY\NetworkService";  dep = "DxgKrnl";                  rev = "DcomLaunch, Spooler, W32Time, Winmgmt"; desc = "The RPCSS service is the Service Control Manager for COM and DCOM servers."; bin = "C:\Windows\System32\svchost.exe -k rpcss -p" }
    @{ n = "Spooler";           d = "Print Spooler";                      p = 1840; st = "Running"; sm = "Auto";   u = "LocalSystem";                 dep = "RPCSS, HTTP";              rev = "Fax";                    desc = "This service spools print jobs and handles interaction with the printer."; bin = "C:\Windows\System32\spoolsv.exe" }
    @{ n = "Winmgmt";           d = "Windows Management Instrumentation"; p = 2410; st = "Running"; sm = "Auto";   u = "LocalSystem";                 dep = "RPCSS";                    rev = "IPHLPSVC, wuauserv";     desc = "Provides a common interface and object model to access management information about operating system, devices, applications and services."; bin = "C:\Windows\System32\svchost.exe -k netsvcs -p" }
    @{ n = "wuauserv";          d = "Windows Update";                     p = 0;    st = "Stopped"; sm = "Manual"; u = "LocalSystem";                 dep = "rpcss";                    rev = "";                       desc = "Enables the detection, download, and installation of updates for Windows and other programs."; bin = "C:\Windows\System32\svchost.exe -k netsvcs -p" }
    @{ n = "EventLog";          d = "Windows Event Log";                  p = 908;  st = "Running"; sm = "Auto";   u = "NT AUTHORITY\LocalService";   dep = "";                         rev = "TaskScheduler";          desc = "This service manages events and event logs."; bin = "C:\Windows\System32\svchost.exe -k LocalServiceNetworkRestricted -p" }
    @{ n = "Schedule";          d = "Task Scheduler";                     p = 1204; st = "Running"; sm = "Auto";   u = "LocalSystem";                 dep = "EventLog, RPCSS";          rev = "";                       desc = "Enables a user to configure and schedule automated tasks on this computer."; bin = "C:\Windows\System32\svchost.exe -k netsvcs -p" }
    @{ n = "W32Time";           d = "Windows Time";                       p = 0;    st = "Stopped"; sm = "Manual"; u = "NT AUTHORITY\LocalService";   dep = "";                         rev = "";                       desc = "Maintains date and time synchronization on all clients and servers in the network."; bin = "C:\Windows\System32\svchost.exe -k LocalService -p" }
    @{ n = "TermService";       d = "Remote Desktop Services";            p = 3120; st = "Running"; sm = "Manual"; u = "NT AUTHORITY\NetworkService";  dep = "RPCSS, TermDD";            rev = "SessionEnv, UmRdpService"; desc = "Allows users to connect interactively to a remote computer."; bin = "C:\Windows\System32\svchost.exe -k termsvcs" }
    @{ n = "BFE";               d = "Base Filtering Engine";              p = 1488; st = "Running"; sm = "Auto";   u = "NT AUTHORITY\LocalService";   dep = "RpcSs";                    rev = "MpsSvc, IKEEXT";         desc = "The Base Filtering Engine (BFE) is a service that manages firewall and Internet Protocol security (IPsec) policies."; bin = "C:\Windows\System32\svchost.exe -k LocalServiceNoNetwork -p" }
    @{ n = "MpsSvc";            d = "Windows Defender Firewall";          p = 1488; st = "Running"; sm = "Auto";   u = "NT AUTHORITY\LocalService";   dep = "BFE, RpcSs";               rev = "";                       desc = "Windows Defender Firewall helps protect your computer by preventing unauthorized users from gaining access to your computer."; bin = "C:\Windows\System32\svchost.exe -k LocalServiceNoNetwork -p" }
    @{ n = "Dhcp";              d = "DHCP Client";                        p = 1620; st = "Running"; sm = "Auto";   u = "NT AUTHORITY\NetworkService";  dep = "Afd, NetBT, NSI";          rev = "";                       desc = "Registers and updates IP addresses and DNS records for this computer."; bin = "C:\Windows\System32\svchost.exe -k LocalServiceNetworkRestricted -p" }
    @{ n = "Dnscache";          d = "DNS Client";                         p = 1750; st = "Running"; sm = "Auto";   u = "NT AUTHORITY\NetworkService";  dep = "nsi, netbt";               rev = "";                       desc = "The DNS Client service (dnscache) caches Domain Name System (DNS) names and registers the full computer name for this computer."; bin = "C:\Windows\System32\svchost.exe -k NetworkService -p" }
)

foreach ($s in $sampleServices) {
    $svm = [ServiceItemViewModel]::new()
    $svm.UpdateService($s.n, $s.d, $s.p, $s.st, $s.sm, $s.u, $s.dep, $s.rev, $s.desc, $s.bin)
    $svcSampleCol.Add($svm)
}
$gridSvc = $winSvcMain.FindName("GridServices")
$gridSvc.ItemsSource = $svcSampleCol
$winSvcMain.FindName("TxtSvcSummary").Text = "14 Services (12 Running, 2 Stopped)"
$gridSvc.SelectedIndex = 3 # Spooler selected

$frame10 = New-ModernWindowFrame $winSvcMain.Content "PSRPM - PowerShell Remote Process Manager [SRV-PROD-01.contoso.corp] - Services Manager" 1520 840
Export-ElementToPng $frame10 "10_services_manager_light.png" 1520 840 192.0

# ------------------------------------------------------------------
# SCREENSHOT 11: Service Details & Dependencies Inspector (620x540 @ 2x DPI)
# ------------------------------------------------------------------
Write-Host "`n[SCREENSHOT 11] Capturing Service Details & Dependencies Dialog (192 DPI)..." -ForegroundColor Yellow

$svcDlgBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "ServiceDetailWindow.xaml"))
$msSvcDlg = [System.IO.MemoryStream]::new($svcDlgBytes)
$winSvcDlg = [System.Windows.Markup.XamlReader]::Load($msSvcDlg)
$msSvcDlg.Close()

$winSvcDlg.FindName("TxtDlgDisplayName").Text = "Print Spooler"
$winSvcDlg.FindName("TxtDlgServiceName").Text = "Spooler"
$winSvcDlg.FindName("TxtDlgPid").Text = "1840"
$winSvcDlg.FindName("TxtDlgDescription").Text = "This service spools print jobs and handles interaction with the printer. If you turn off this service, you will not be able to print or see your printers."
$winSvcDlg.FindName("TxtDlgPath").Text = "C:\Windows\System32\spoolsv.exe"
$winSvcDlg.FindName("TxtDlgStartup").Text = "Auto"
$winSvcDlg.FindName("TxtDlgAccount").Text = "LocalSystem"
$winSvcDlg.FindName("TxtDlgDepSummary").Text = "RPCSS, HTTP"

$tcSvcDlg = $winSvcDlg.FindName("SvcTabControl")
if ($tcSvcDlg) { $tcSvcDlg.SelectedIndex = 1 }

$prereqItems = @(
    [PSCustomObject]@{ Name = "RPCSS"; DisplayName = "Remote Procedure Call (RPC)"; Status = "Running" }
    [PSCustomObject]@{ Name = "HTTP";  DisplayName = "HTTP Service (System Driver)"; Status = "Running (Kernel/Core)" }
)
$dependentItems = @(
    [PSCustomObject]@{ Name = "Fax";   DisplayName = "Fax Service"; Status = "Stopped" }
)
$winSvcDlg.FindName("GridDlgPrereqs").ItemsSource = $prereqItems
$winSvcDlg.FindName("GridDlgDependents").ItemsSource = $dependentItems

$frame11 = New-ModernWindowFrame $winSvcDlg.Content "Print Spooler (Spooler) Details & Dependencies [SRV-PROD-01.contoso.corp]" 620 540
Export-ElementToPng $frame11 "11_service_dependencies_inspector.png" 620 540 192.0

# ------------------------------------------------------------------
# Generate Gallery Markdown Index
# ------------------------------------------------------------------
Write-Host "`n[STEP 2] Generating Screenshots Catalog & Review Document..." -ForegroundColor Yellow

$readmeContent = @'
# PSRPM Ultra-HD (2x Scaling) Screenshots - Clean Light Mode

This gallery contains ultra-high-resolution marketing and documentation screenshots for **PSRPM (PowerShell Remote Process Manager)** in **Clean Light Mode** (Sysinternals Refined).

- **Render Scale**: `192 DPI` (Double scaling / 2x Retina) for razor-sharp vector lines, text, and icons.
- **Aspect & Width**: Expanded 1520px wide layout showing full process paths, users, descriptions, and companies without horizontal clipping.
- **Target Context**: Pure enterprise sample server (`SRV-PROD-01.contoso.corp`, `CONTOSO\svc-monitor`) with zero local workstation or personal user info.

---

## Screenshot Gallery

### 1. Main Window - Sysinternals Refined Light Mode (Hero Shot)
**File**: [`01_process_tree_light.png`](01_process_tree_light.png) (3040 x 1680 @ 2x DPI)
- Full hierarchical Tree-Grid with pixel-snapped vector guide connectors
- Multi-host tabs (`SRV-PROD-01 [WINRM-SSL]`, `SRV-DB-02 [WINRM-SSL]`, `SRV-APP-03 [WINRM]`)
- Populated toolbar sparklines (CPU with kernel time line, Commit charge, I/O, Network)
- Semantic pastel category colors (Services in light cyan, User apps in periwinkle, Packaged in lavender)
- Process Explorer column metric tints (CPU green, Private Bytes yellow, Working Set orange)

![PSRPM Light Mode Hero](01_process_tree_light.png)

---

### 2. Ancestor-Preserving Search Filter
**File**: [`02_ancestor_search_filter.png`](02_ancestor_search_filter.png) (3040 x 1680 @ 2x DPI)
- Instant search filter preserving the entire parent-child process tree lineage
- Matching `powershell` processes highlighted at 100% opacity; ancestor nodes (`explorer.exe`, `userinit.exe`, `winlogon.exe`, `System`) remain visible with dimmed opacity (`0.62`)
- Sysadmins never lose context of which process or parent spawned the target

![Ancestor-Preserving Search](02_ancestor_search_filter.png)

---

### 3. System Information Dashboard - Summary & Hardware
**File**: [`03_system_information_dashboard.png`](03_system_information_dashboard.png) (1840 x 1400 @ 2x DPI)
- Hardware metadata: `Dell PowerEdge R750 Enterprise Cloud Node` (16 Cores, 32 Threads, 64 GB RAM)
- 240-sample real-time CPU chart with kernel time red overlay and green grid
- Memory commit charge gauge, physical memory meters, and I/O delta charts
- Kernel performance counters: Context switches/s, Interrupts/s, System calls/s, DPCs/s, Page faults/s

![System Information Dashboard](03_system_information_dashboard.png)

---

### 4. System Information - CPU & Kernel Telemetry
**File**: [`04_system_information_cpu.png`](04_system_information_cpu.png) (1840 x 1400 @ 2x DPI)
- Dedicated CPU telemetry dashboard with aggregate and per-core processor charts
- Kernel time vs. user time breakdown
- Real-time interrupt and context switch rate gauges

![System Information CPU](04_system_information_cpu.png)

---

### 5. Process Properties Inspector - Image & Security
**File**: [`05_process_properties_image.png`](05_process_properties_image.png) (1720 x 1360 @ 2x DPI)
- Complete process metadata extracted from remote PEB and token
- Executable path, command line, working directory, parent process link, user SID, elevation level
- Verified exploit mitigations: DEP (Permanent), ASLR (High Entropy 64-bit), CFG (Control Flow Guard)

![Process Properties Image](05_process_properties_image.png)

---

### 6. Process Properties Inspector - Performance & Process Tree
**File**: [`06_process_properties_performance.png`](06_process_properties_performance.png) (1720 x 1360 @ 2x DPI)
- Real-time CPU usage, total processor time, kernel/user time split, and cycle counts
- Handles, threads, working set memory, and private bytes meters
- Interactive focused parent-child process tree

![Process Properties Performance](06_process_properties_performance.png)

---

### 7. Process Properties Inspector - Loaded DLLs & Modules
**File**: [`07_process_properties_modules.png`](07_process_properties_modules.png) (1720 x 1360 @ 2x DPI)
- Lazy-loaded on-demand module inspection (< 46 ms)
- 64-bit base addresses, binary sizes, verified digital signatures, versions, disk paths

![Process Properties Modules](07_process_properties_modules.png)

---

### 8. Live Audit & Network Telemetry Console (Ctrl+L)
**File**: [`08_live_telemetry_audit_console.png`](08_live_telemetry_audit_console.png) (3040 x 1760 @ 2x DPI)
- Expanded bottom telemetry drawer showing real-time WinRM differential packet logs
- Proof of ultra-low network impact: ~1.18 KB initial sync, ~0.28 KB delta ticks, < 5 ms RTT, 87% GZIP savings
- Real-time audit of process spawn/exit lifecycles and administrative actions

![Live Telemetry Console](08_live_telemetry_audit_console.png)

---

### 9. Connect to Target System Dialog (WinRM)
**File**: [`09_connect_remote_winrm.png`](09_connect_remote_winrm.png) (1040 x 800 @ 2x DPI)
- Enterprise remote connection dialog over WinRM HTTPS (Port 5986)
- Saved credentials profile and multi-session host tab selection

![Connect Dialog](09_connect_remote_winrm.png)

### 10. Services Manager Tab & Action Toolbar
**File**: [`10_services_manager_light.png`](10_services_manager_light.png) (3040 x 1680 @ 2x DPI)
- Full services catalog with live status badges, startup types, log on accounts, and dependencies column
- Dedicated action toolbar for instant Start, Stop, Restart, Properties, and Process navigation

![Services Manager](10_services_manager_light.png)

### 11. Service Details & Two-Way Dependencies Inspector
**File**: [`11_service_dependencies_inspector.png`](11_service_dependencies_inspector.png) (1240 x 1080 @ 2x DPI)
- Two-tab modal inspector with General details and interactive two-way Dependencies (Prerequisites and Dependents)
- Full Service Control actions (Start, Stop, Restart) directly within the modal inspector

![Service Details & Dependencies](11_service_dependencies_inspector.png)

---

## How to Re-generate

To regenerate all screenshots at any time:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Capture-Screenshots.ps1
```
'@

Set-Content -Path (Join-Path $outDir "README.md") -Value $readmeContent -Encoding ASCII
Set-Content -Path (Join-Path $docsOut "README.md") -Value $readmeContent -Encoding ASCII

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " ALL 11 LIGHT MODE ULTRA-HD SCREENSHOTS GENERATED SUCCESSFULLY!" -ForegroundColor Green
Write-Host " Location: $outDir" -ForegroundColor Cyan
Write-Host " Scale: 192 DPI (2x Retina)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
