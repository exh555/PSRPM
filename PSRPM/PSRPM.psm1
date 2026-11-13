# Requires -Version 5.1
# PSRPM - PowerShell Remote Process Manager
# Main Module Entry Point & WPF UI Controller

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Xaml -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue

# Load Private Engine & ViewModel Components
$privateDir = Join-Path $PSScriptRoot "Private"
. (Join-Path $privateDir "ViewModelClasses.ps1")
. (Join-Path $privateDir "DataCollector.ps1")
. (Join-Path $privateDir "DeepInspector.ps1")
. (Join-Path $privateDir "ProcessActions.ps1")
. (Join-Path $privateDir "RunspaceEngine.ps1")

# Define Shell32 P/Invoke for Application User Model ID via Reflection.Emit (100% Fileless & EDR-Safe)
if (-not ([System.Management.Automation.PSTypeName]'PSRPM.Shell32Native').Type) {
    try {
        $domain = [AppDomain]::CurrentDomain
        $an = [System.Reflection.AssemblyName]::new("PSRPM_Shell32Assembly")
        $ab = $domain.DefineDynamicAssembly($an, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
        $mb = $ab.DefineDynamicModule("PSRPM_Shell32Module")
        $tb = $mb.DefineType("PSRPM.Shell32Native", [System.Reflection.TypeAttributes]::Public)
        
        [void]$tb.DefinePInvokeMethod(
            "SetCurrentProcessExplicitAppUserModelID",
            "shell32.dll",
            "SetCurrentProcessExplicitAppUserModelID",
            [System.Reflection.MethodAttributes]"Public,Static,PinvokeImpl",
            [System.Reflection.CallingConventions]::Standard,
            [int],
            @([string]),
            [System.Runtime.InteropServices.CallingConvention]::Winapi,
            [System.Runtime.InteropServices.CharSet]::Unicode
        )
        [void]$tb.CreateType()
    } catch {}
}

# Resolve dynamic module version from single source of truth (PSRPM.psd1)
$script:AppVersion = "1.7.0"
try {
    $manifestPath = Join-Path $PSScriptRoot "PSRPM.psd1"
    if (Test-Path $manifestPath) {
        $m = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
        if ($m -and $m['ModuleVersion']) {
            $script:AppVersion = [string]$m['ModuleVersion']
        }
    }
} catch {}

function Get-PSRPMNextColumnSortState {
    <#
    .SYNOPSIS
        Computes the next Process Grid view mode and sort state when a column header is clicked.
    .DESCRIPTION
        Matches Sysinternals Process Explorer behavior:
        - Clicking the 'Process' column (SortMemberPath 'Name') cycles:
          Tree View -> Flat Ascending -> Flat Descending -> Tree View.
        - Clicking any other column auto-switches from Tree View to Flat View and toggles Asc/Desc.
    #>
    param(
        [bool]$IsTreeMode,
        [string]$CurrentSortProperty,
        [bool]$CurrentSortDescending,
        [string]$ClickedSortProperty
    )

    if ([string]::IsNullOrWhiteSpace($ClickedSortProperty)) {
        $ClickedSortProperty = "PID"
    }

    if ($ClickedSortProperty -eq "Name") {
        if ($IsTreeMode -or $CurrentSortProperty -ne "Name") {
            return @{
                IsTreeMode     = $false
                SortProperty   = "Name"
                SortDescending = $false
            }
        }
        if (-not $CurrentSortDescending) {
            return @{
                IsTreeMode     = $false
                SortProperty   = "Name"
                SortDescending = $true
            }
        }
        return @{
            IsTreeMode     = $true
            SortProperty   = "PID"
            SortDescending = $false
        }
    }

    $defaultDescending = $ClickedSortProperty -in @("CPU", "TreeCPU", "NetTotalBps", "TreeNetTotalBps", "NetRxBps", "NetTxBps", "PrivateBytes", "MemoryBytes", "Handles")
    if ($IsTreeMode -or $CurrentSortProperty -ne $ClickedSortProperty) {
        return @{
            IsTreeMode     = $false
            SortProperty   = $ClickedSortProperty
            SortDescending = $defaultDescending
        }
    }

    return @{
        IsTreeMode     = $false
        SortProperty   = $ClickedSortProperty
        SortDescending = (-not $CurrentSortDescending)
    }
}

function Start-PSRPM {
    <#
    .SYNOPSIS
        Launches PowerShell Remote Process Manager (PSRPM) with a real-time hierarchical Tree-Grid UI.
    .DESCRIPTION
        Connects to a remote Windows computer via WinRM (-ComputerName) or executes locally (-LocalOnly)
        with near-zero remote CPU/memory footprint (<2-5ms per tick via native NtQuerySystemInformation
        and differential GZIP JSON telemetry).
    .PARAMETER ComputerName
        Target remote hostname or IP address. Defaults to 'localhost'.
    .PARAMETER Credential
        Optional PSCredential for authenticating the WinRM PSSession.
    .PARAMETER Port
        Optional custom WinRM port (defaults to 5985 for HTTP or 5986 for SSL).
    .PARAMETER UseSSL
        Use HTTPS transport for the WinRM PSSession.
    .PARAMETER RefreshIntervalMs
        Telemetry polling interval in milliseconds (250 to 60000). Defaults to 1000ms.
    .PARAMETER LocalOnly
        Run directly in the local PowerShell process without creating a WinRM PSSession or requiring elevation.
    .EXAMPLE
        Start-PSRPM -ComputerName "SRV-PROD-01" -Credential (Get-Credential)
    .EXAMPLE
        Start-PSRPM -LocalOnly
    .EXAMPLE
        Start-PSRPM -LocalOnly -NoWait
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName = "localhost",

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [int]$Port = 0,

        [Parameter(Mandatory = $false)]
        [switch]$UseSSL,

        [Parameter(Mandatory = $false)]
        [ValidateRange(250, 60000)]
        [int]$RefreshIntervalMs = 1000,

        [Parameter(Mandatory = $false)]
        [Alias("Local")]
        [switch]$LocalOnly,

        [Parameter(Mandatory = $false)]
        [Alias("Background")]
        [switch]$NoWait,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Light", "Dark", "Classic", "HighContrast")]
        [string]$Theme,

        [Parameter(Mandatory = $false)]
        [switch]$Dark,

        [Parameter(Mandatory = $false)]
        [string]$IconPath
    )

    $isLocalMode = [bool]$LocalOnly
    $session = $null
    $targetLabel = if ($isLocalMode) { $env:COMPUTERNAME } else { $ComputerName }

    # 0. Set Explicit AppUserModelID to prevent Windows Taskbar from grouping under powershell.exe
    try {
        if (([System.Management.Automation.PSTypeName]'PSRPM.Shell32Native').Type) {
            [void][PSRPM.Shell32Native]::SetCurrentProcessExplicitAppUserModelID("PSRPM.RemoteProcessManager.1.0")
        }
    } catch {}

    # If -NoWait is specified, launch in an isolated STA background runspace and unlock the terminal immediately
    if ($NoWait) {
        $bound = @{}
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -notin @("NoWait", "Background")) {
                $bound[$k] = $PSBoundParameters[$k]
            }
        }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($modPath, $params)
            Import-Module $modPath -Force
            Start-PSRPM @params
        })
        [void]$ps.AddArgument((Join-Path $PSScriptRoot "PSRPM.psd1"))
        [void]$ps.AddArgument($bound)

        if (-not $script:BackgroundRunspaces) {
            $script:BackgroundRunspaces = [System.Collections.Generic.List[Object]]::new()
        } else {
            for ($bi = $script:BackgroundRunspaces.Count - 1; $bi -ge 0; $bi--) {
                $bgItem = $script:BackgroundRunspaces[$bi]
                if ($bgItem.Handle -and $bgItem.Handle.IsCompleted) {
                    try { $bgItem.PowerShell.EndInvoke($bgItem.Handle) } catch {}
                    try { $bgItem.PowerShell.Dispose() } catch {}
                    try { $bgItem.Runspace.Close(); $bgItem.Runspace.Dispose() } catch {}
                    $script:BackgroundRunspaces.RemoveAt($bi)
                }
            }
        }
        $handle = $ps.BeginInvoke()
        $script:BackgroundRunspaces.Add(@{ Runspace = $rs; PowerShell = $ps; Handle = $handle })

        Write-Host "[PSRPM] Launched in background (Target: $targetLabel). Terminal remains unlocked." -ForegroundColor Green
        return
    }

    # 1. Establish Persistent Remote PSSession (unless -LocalOnly is specified)
    if (-not $isLocalMode) {
        try {
            Write-Host "[PSRPM] Connecting to '$ComputerName' via WinRM..." -ForegroundColor Cyan
            $so = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 15000 -CancelTimeout 5000 -NoMachineProfile
            $sessParams = @{
                ComputerName  = $ComputerName
                SessionOption = $so
                ErrorAction   = 'Stop'
            }
            if ($Credential) { $sessParams['Credential'] = $Credential }
            if ($Port -gt 0) { $sessParams['Port'] = $Port }
            if ($UseSSL)     { $sessParams['UseSSL'] = $true }

            $session = New-PSSession @sessParams
        } catch {
            $errMsg = $_.Exception.Message
            if ($ComputerName -in @("localhost", "127.0.0.1", ".", $env:COMPUTERNAME)) {
                $ans = [System.Windows.MessageBox]::Show(
                    "Could not establish a WinRM session to '$ComputerName':`n`n$errMsg`n`nWould you like to continue in Local-Only Mode (-LocalOnly) without WinRM or Admin requirements?",
                    "PSRPM - WinRM Connection Fallback",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question
                )
                if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
                    $isLocalMode = $true
                    $targetLabel = $env:COMPUTERNAME
                } else {
                    return
                }
            } else {
                [System.Windows.MessageBox]::Show(
                    "Failed to connect to remote computer '$ComputerName' via WinRM:`n`n$errMsg`n`nTip: You can still launch the UI using -LocalOnly and connect from File -> Connect to Remote Computer.",
                    "PSRPM - WinRM Connection Error",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error
                ) | Out-Null
                return
            }
        }
    }

    # 2. Load MainWindow.xaml
    $uiDir = Join-Path $PSScriptRoot "UI"
    $mainXamlPath       = Join-Path $uiDir "MainWindow.xaml"
    $propXamlPath       = Join-Path $uiDir "PropertiesWindow.xaml"
    $connXamlPath       = Join-Path $uiDir "ConnectDialog.xaml"
    $sysInfoXamlPath    = Join-Path $uiDir "SystemInfoWindow.xaml"
    $helpXamlPath       = Join-Path $uiDir "HelpWindow.xaml"
    $svcDetailXamlPath  = Join-Path $uiDir "ServiceDetailWindow.xaml"
    $findHandleXamlPath = Join-Path $uiDir "FindHandleWindow.xaml"

    $xamlBytes = [System.IO.File]::ReadAllBytes($mainXamlPath)
    $msXaml = [System.IO.MemoryStream]::new($xamlBytes)
    $window = [System.Windows.Markup.XamlReader]::Load($msXaml)
    $msXaml.Close()

    $window.Title = "PSRPM - PowerShell Remote Process Manager [$targetLabel]"

    # Resolve and Attach Application Window & Taskbar Icon (Custom via -IconPath or Default Assets/psrpm.ico)
    $appIconFrame = $null
    $resolvedIconPath = $null
    if ($IconPath -and [System.IO.File]::Exists($IconPath)) {
        $resolvedIconPath = (Resolve-Path -LiteralPath $IconPath).Path
    } else {
        $defaultIco = Join-Path $PSScriptRoot "Assets\psrpm.ico"
        if ([System.IO.File]::Exists($defaultIco)) {
            $resolvedIconPath = $defaultIco
        }
    }
    if ($resolvedIconPath) {
        try {
            $appIconFrame = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($resolvedIconPath))
            $window.Icon = $appIconFrame
        } catch {}
    }

    # 3. Initialize ObservableCollections & Summary ViewModel
    $processCollection  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $servicesCollection = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $hostTabsCollection = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $summaryVm          = [SystemSummaryViewModel]::new()

    $gridProcesses = $window.FindName("GridProcesses")
    $gridServices  = $window.FindName("GridServices")
    $summaryBar    = $window.FindName("SummaryBar")
    $txtLogConsole = $window.FindName("TxtLogConsole")
    $logPane       = $window.FindName("LogPane")
    $hostTabsList  = $window.FindName("HostTabsList")

    $gridProcesses.ItemsSource = $processCollection
    $gridServices.ItemsSource  = $servicesCollection
    $summaryBar.DataContext    = $summaryVm
    if ($hostTabsList) { $hostTabsList.ItemsSource = $hostTabsCollection }

    $initialTabId = [guid]::NewGuid().ToString("N")
    $initialTransport = if ($isLocalMode) { "LOCAL" } else { "WINRM" }
    $initialTabVm = [HostTabItemViewModel]::new($initialTabId, $targetLabel, $targetLabel, $initialTransport, $isLocalMode, $summaryVm)
    $initialTabVm.UpdateVisualState($true, $false, $false, $(if ($isLocalMode) { "LocalMode" } else { "Connected" }), $false, 0)
    $hostTabsCollection.Add($initialTabVm)
    $script:ActiveHostTab = $initialTabVm

    # Helper: Append Audit Entry to Activity Log Console
    $writeAuditLog = {
        param([string]$category, [string]$message)
        if ($txtLogConsole) {
            if ($txtLogConsole.Text.Length -gt 24000) {
                $txtLogConsole.Text = $txtLogConsole.Text.Substring($txtLogConsole.Text.Length - 16000)
            }
            $ts = (Get-Date).ToString("HH:mm:ss.fff")
            $txtLogConsole.AppendText("[$ts] [$category] $message`r`n")
            $txtLogConsole.ScrollToEnd()
        }
    }

    &$writeAuditLog "INIT" "PSRPM initialized for target '$targetLabel' (Mode: $(if ($isLocalMode) { 'LocalOnly' } else { 'WinRM PSSession' }), Interval: ${RefreshIntervalMs}ms)."

    # 4. Start Background Runspace Engine
    $engineHandle = Start-PSRPMEngine `
        -PSSession $session `
        -Window $window `
        -ProcessCollection $processCollection `
        -ServicesCollection $servicesCollection `
        -SummaryViewModel $summaryVm `
        -CollectorScript $script:PSRPMCollectorScriptBlock `
        -InspectorScript $script:PSRPMDeepInspectorScriptBlock `
        -ActionScript $script:PSRPMActionScriptBlock `
        -IntervalMs $RefreshIntervalMs `
        -IsLocal $isLocalMode `
        -TargetName $targetLabel `
        -InitialTabId $initialTabId `
        -LogConsole $txtLogConsole

    $stateContainer = $engineHandle.StateContainer
    $initialTabVm.ProcessMap     = $engineHandle.ProcessMap
    $initialTabVm.ServicesMap    = $engineHandle.ServicesMap
    $initialTabVm.PidServicesMap = $engineHandle.PidServicesMap

    # 5. Theme Engine (Clean Light, Precision Dark, Sysinternals Classic & High-Contrast WCAG AAA)
    $menuThemeLight        = $window.FindName("MenuThemeLight")
    $menuThemeDark         = $window.FindName("MenuThemeDark")
    $menuThemeClassic      = $window.FindName("MenuThemeClassic")
    $menuThemeHighContrast = $window.FindName("MenuThemeHighContrast")
    $txtThemeToggle        = $window.FindName("TxtThemeToggle")
    $brushConv             = [System.Windows.Media.BrushConverter]::new()

    $setResourceBrush = {
        param([string]$key, [string]$hex)
        $b = $brushConv.ConvertFromString($hex)
        if ($b.CanFreeze) { $b.Freeze() }
        $window.Resources[$key] = $b
    }

    $stateContainer.CurrentTheme = "Light"

    $applyTheme = {
        param($themeArg)
        $themeMode = if ($themeArg -is [bool]) { if ($themeArg) { "Dark" } else { "Light" } } else { [string]$themeArg }
        if (-not $themeMode) { $themeMode = "Light" }
        $stateContainer.CurrentTheme = $themeMode
        $isDark = ($themeMode -in @("Dark", "HighContrast"))
        $stateContainer.IsDarkTheme = $isDark

        if ($themeMode -eq "HighContrast") {
            &$setResourceBrush "BrushWindowBg"       "#000000"
            &$setResourceBrush "BrushToolbarBg"      "#000000"
            &$setResourceBrush "BrushSurfaceBg"      "#000000"
            &$setResourceBrush "BrushHeaderBg"       "#1A1A1A"
            &$setResourceBrush "BrushBorderSubtle"   "#FFFFFF"
            &$setResourceBrush "BrushTreeLine"       "#FFFFFF"
            &$setResourceBrush "BrushTextPrimary"    "#FFFFFF"
            &$setResourceBrush "BrushTextSecondary"  "#FFFF00"
            &$setResourceBrush "BrushTextMuted"      "#00FF00"
            &$setResourceBrush "BrushRowHover"       "#330055FF"
            &$setResourceBrush "BrushRowSelectedBg"  "#0055FF"
            &$setResourceBrush "BrushRowSelectedFg"  "#FFFFFF"
            &$setResourceBrush "BrushSparkBg"        "#000000"
            &$setResourceBrush "BrushSparkBorder"    "#FFFFFF"
            &$setResourceBrush "ColTint_CPU"          "#2200FF00"
            &$setResourceBrush "ColTint_Net"          "#220088FF"
            &$setResourceBrush "ColTint_PrivateBytes" "#22FFFF00"
            &$setResourceBrush "ColTint_WorkingSet"   "#2200FFFF"
            &$setResourceBrush "BrushMenuBg"         "#000000"
            &$setResourceBrush "BrushMenuBorder"     "#FFFFFF"
            &$setResourceBrush "BrushMenuHover"      "#222222"
            if ($menuThemeLight)        { $menuThemeLight.IsChecked        = $false }
            if ($menuThemeDark)         { $menuThemeDark.IsChecked         = $false }
            if ($menuThemeClassic)      { $menuThemeClassic.IsChecked      = $false }
            if ($menuThemeHighContrast) { $menuThemeHighContrast.IsChecked = $true }
            if ($txtThemeToggle)        { $txtThemeToggle.Text             = "High-Contrast" }
        } elseif ($themeMode -eq "Classic") {
            &$setResourceBrush "BrushWindowBg"       "#ECE9D8"
            &$setResourceBrush "BrushToolbarBg"      "#ECE9D8"
            &$setResourceBrush "BrushSurfaceBg"      "#FFFFFF"
            &$setResourceBrush "BrushHeaderBg"       "#D4D0C8"
            &$setResourceBrush "BrushBorderSubtle"   "#808080"
            &$setResourceBrush "BrushTreeLine"       "#808080"
            &$setResourceBrush "BrushTextPrimary"    "#000000"
            &$setResourceBrush "BrushTextSecondary"  "#333333"
            &$setResourceBrush "BrushTextMuted"      "#666666"
            &$setResourceBrush "BrushRowHover"       "#220A246A"
            &$setResourceBrush "BrushRowSelectedBg"  "#0A246A"
            &$setResourceBrush "BrushRowSelectedFg"  "#FFFFFF"
            &$setResourceBrush "BrushSparkBg"        "#ECE9D8"
            &$setResourceBrush "BrushSparkBorder"    "#808080"
            &$setResourceBrush "ColTint_CPU"          "#2222C55E"
            &$setResourceBrush "ColTint_Net"          "#1A0284C7"
            &$setResourceBrush "ColTint_PrivateBytes" "#28EAB308"
            &$setResourceBrush "ColTint_WorkingSet"   "#22F97316"
            &$setResourceBrush "BrushMenuBg"         "#ECE9D8"
            &$setResourceBrush "BrushMenuBorder"     "#808080"
            &$setResourceBrush "BrushMenuHover"      "#D4D0C8"
            if ($menuThemeLight)        { $menuThemeLight.IsChecked        = $false }
            if ($menuThemeDark)         { $menuThemeDark.IsChecked         = $false }
            if ($menuThemeClassic)      { $menuThemeClassic.IsChecked      = $true }
            if ($menuThemeHighContrast) { $menuThemeHighContrast.IsChecked = $false }
            if ($txtThemeToggle)        { $txtThemeToggle.Text             = "Classic" }
        } elseif ($isDark) {
            &$setResourceBrush "BrushWindowBg"       "#0B0F17"
            &$setResourceBrush "BrushToolbarBg"      "#111827"
            &$setResourceBrush "BrushSurfaceBg"      "#0F172A"
            &$setResourceBrush "BrushHeaderBg"       "#1E293B"
            &$setResourceBrush "BrushBorderSubtle"   "#26334D"
            &$setResourceBrush "BrushTreeLine"       "#64748B"
            &$setResourceBrush "BrushTextPrimary"    "#F8FAFC"
            &$setResourceBrush "BrushTextSecondary"  "#CBD5E1"
            &$setResourceBrush "BrushTextMuted"      "#94A3B8"
            &$setResourceBrush "BrushRowHover"       "#330284C7"
            &$setResourceBrush "BrushRowSelectedBg"  "#0369A1"
            &$setResourceBrush "BrushRowSelectedFg"  "#FFFFFF"
            &$setResourceBrush "BrushSparkBg"        "#090D16"
            &$setResourceBrush "BrushSparkBorder"    "#334155"
            &$setResourceBrush "ColTint_CPU"          "#1422C55E"
            &$setResourceBrush "ColTint_Net"          "#120284C7"
            &$setResourceBrush "ColTint_PrivateBytes" "#14EAB308"
            &$setResourceBrush "ColTint_WorkingSet"   "#14F97316"
            &$setResourceBrush "BrushMenuBg"         "#161F30"
            &$setResourceBrush "BrushMenuBorder"     "#334155"
            &$setResourceBrush "BrushMenuHover"      "#26354D"
            if ($menuThemeLight)        { $menuThemeLight.IsChecked        = $false }
            if ($menuThemeDark)         { $menuThemeDark.IsChecked         = $true }
            if ($menuThemeClassic)      { $menuThemeClassic.IsChecked      = $false }
            if ($menuThemeHighContrast) { $menuThemeHighContrast.IsChecked = $false }
            if ($txtThemeToggle)        { $txtThemeToggle.Text             = "Dark Mode" }
        } else {
            &$setResourceBrush "BrushWindowBg"       "#F8FAFC"
            &$setResourceBrush "BrushToolbarBg"      "#F1F5F9"
            &$setResourceBrush "BrushSurfaceBg"      "#FFFFFF"
            &$setResourceBrush "BrushHeaderBg"       "#E2E8F0"
            &$setResourceBrush "BrushBorderSubtle"   "#CBD5E1"
            &$setResourceBrush "BrushTreeLine"       "#64748B"
            &$setResourceBrush "BrushTextPrimary"    "#0F172A"
            &$setResourceBrush "BrushTextSecondary"  "#334155"
            &$setResourceBrush "BrushTextMuted"      "#64748B"
            &$setResourceBrush "BrushRowHover"       "#220284C7"
            &$setResourceBrush "BrushRowSelectedBg"  "#006CBE"
            &$setResourceBrush "BrushRowSelectedFg"  "#FFFFFF"
            &$setResourceBrush "BrushSparkBg"        "#FFFFFF"
            &$setResourceBrush "BrushSparkBorder"    "#94A3B8"
            &$setResourceBrush "ColTint_CPU"          "#2222C55E"
            &$setResourceBrush "ColTint_Net"          "#1A0284C7"
            &$setResourceBrush "ColTint_PrivateBytes" "#28EAB308"
            &$setResourceBrush "ColTint_WorkingSet"   "#22F97316"
            &$setResourceBrush "BrushMenuBg"         "#FFFFFF"
            &$setResourceBrush "BrushMenuBorder"     "#CBD5E1"
            &$setResourceBrush "BrushMenuHover"      "#F1F5F9"
            if ($menuThemeLight)        { $menuThemeLight.IsChecked        = $true }
            if ($menuThemeDark)         { $menuThemeDark.IsChecked         = $false }
            if ($menuThemeClassic)      { $menuThemeClassic.IsChecked      = $false }
            if ($menuThemeHighContrast) { $menuThemeHighContrast.IsChecked = $false }
            if ($txtThemeToggle)        { $txtThemeToggle.Text             = "Clean Light" }
        }

        foreach ($vm in $engineHandle.ProcessMap.Values) {
            $vm.SetThemeMode($themeMode)
        }

        $canClose = ($hostTabsCollection.Count -gt 1)
        foreach ($tVm in $hostTabsCollection) {
            $tVm.UpdateVisualState(($tVm -eq $script:ActiveHostTab), $isDark, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
        }
        if ($updatePauseUi) { &$updatePauseUi ([bool]$stateContainer.IsPaused) }
        if ($script:UpdateNetEtwUi) {
            &$script:UpdateNetEtwUi ([int]$stateContainer.NetEtwCap) ([int]$stateContainer.NetEtwEventsPerSec)
        }

        foreach ($activeModal in @($script:ActiveFindHandleWin, $script:ActivePropWin, $script:ActiveSysInfoWin)) {
            if ($activeModal -and $activeModal.IsLoaded) {
                foreach ($key in @("BrushWindowBg","BrushToolbarBg","BrushSurfaceBg","BrushHeaderBg","BrushBorderSubtle","BrushTreeLine","BrushTextPrimary","BrushTextSecondary","BrushTextMuted","BrushRowHover","BrushRowSelectedBg","BrushRowSelectedFg","BrushSparkBg","BrushSparkBorder","ColTint_CPU","ColTint_Net","ColTint_PrivateBytes","ColTint_WorkingSet","BrushMenuBg","BrushMenuBorder","BrushMenuHover")) {
                    if ($window.Resources.Contains($key)) {
                        $activeModal.Resources[$key] = $window.Resources[$key]
                    }
                }
            }
        }
    }

    if ($menuThemeLight)        { $menuThemeLight.add_Click({ &$applyTheme "Light" }) }
    if ($menuThemeDark)         { $menuThemeDark.add_Click({ &$applyTheme "Dark" }) }
    if ($menuThemeClassic)      { $menuThemeClassic.add_Click({ &$applyTheme "Classic" }) }
    if ($menuThemeHighContrast) { $menuThemeHighContrast.add_Click({ &$applyTheme "HighContrast" }) }

    $cycleTheme = {
        $cur = if ($stateContainer.CurrentTheme) { $stateContainer.CurrentTheme } else { if ($stateContainer.IsDarkTheme) { "Dark" } else { "Light" } }
        $next = switch ($cur) {
            "Light"        { "Dark" }
            "Dark"         { "Classic" }
            "Classic"      { "HighContrast" }
            "HighContrast" { "Light" }
            default        { "Dark" }
        }
        &$applyTheme $next
    }

    $btnToolbarTheme = $window.FindName("BtnToolbarTheme")
    if ($btnToolbarTheme) {
        $btnToolbarTheme.add_Click({ &$cycleTheme })
    }

    $initialTheme = if ($Dark.IsPresent) { "Dark" } elseif ($Theme) { $Theme } else { "Light" }
    &$applyTheme $initialTheme

    # 5B. Row Highlighting Engine (Standard Sysinternals Semantic Categories vs Minimal Flashes-Only)
    $menuHighlightCategories = $window.FindName("MenuHighlightCategories")
    $btnToggleHighlights     = $window.FindName("BtnToggleHighlights")

    $setCategoryHighlighting = {
        param([bool]$enable)
        $stateContainer.EnableCategoryHighlights = $enable
        if ($menuHighlightCategories) { $menuHighlightCategories.IsChecked = $enable }
        if ($btnToggleHighlights) {
            $btnToggleHighlights.Content = if ($enable) { "Colors: Standard" } else { "Colors: Minimal" }
            $btnToggleHighlights.ToolTip = if ($enable) {
                "Static category colors enabled (Click to switch to Minimal mode: New/Exiting flashes only)"
            } else {
                "Minimal mode active (New/Exiting flashes only. Click to restore category colors)"
            }
        }
        foreach ($vm in $engineHandle.ProcessMap.Values) {
            $vm.SetCategoryHighlights($enable)
        }
        &$writeAuditLog "OPTIONS" ("Row category highlighting set to {0} (New/Exiting lifecycle flashes remain active)." -f $(if ($enable) { "Standard" } else { "Minimal" }))
    }

    if ($menuHighlightCategories) {
        $menuHighlightCategories.add_Click({
            &$setCategoryHighlighting ([bool]$menuHighlightCategories.IsChecked)
        })
    }
    if ($btnToggleHighlights) {
        $btnToggleHighlights.add_Click({
            $cur = [bool]$stateContainer.EnableCategoryHighlights
            &$setCategoryHighlighting (-not $cur)
        })
    }

    # 6. Tree Node Expander Click Handler (PreviewMouseLeftButtonDown on GridProcesses)
    $gridProcesses.add_PreviewMouseLeftButtonDown({
        param($sender, $e)
        $dep = [System.Windows.DependencyObject]$e.OriginalSource
        while ($dep -ne $null -and $dep -ne $gridProcesses) {
            if ($dep -is [System.Windows.FrameworkElement] -and $dep.Name -eq "BtnToggleExpander") {
                $vm = $dep.DataContext
                if ($vm -and ($vm.HasChildren -or $vm.Children.Count -gt 0)) {
                    $vm.IsExpanded = -not $vm.IsExpanded
                    $vm.UpdateExpanderGeometry()
                    & $engineHandle.RefreshTree
                    $e.Handled = $true
                }
                break
            }
            if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
            } else {
                $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
            }
        }
    })

    # Preserve multi-selection when right-clicking an already-selected row; select target row otherwise
    $gridProcesses.add_PreviewMouseRightButtonDown({
        param($sender, $e)
        $dep = [System.Windows.DependencyObject]$e.OriginalSource
        while ($null -ne $dep -and $dep -ne $gridProcesses) {
            if ($dep -is [System.Windows.Controls.DataGridRow]) {
                if (-not $dep.IsSelected -and $null -ne $dep.Item) {
                    $gridProcesses.SelectedItems.Clear()
                    $dep.IsSelected = $true
                    $gridProcesses.SelectedItem = $dep.Item
                }
                break
            }
            if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
            } else {
                $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
            }
        }
    })

    # 7. View Mode Switching (Tree vs Flat) & Column Header Sorting (Process Explorer 3-Way Cycle on Process Column)
    $menuViewTree     = $window.FindName("MenuViewTree")
    $menuViewFlat     = $window.FindName("MenuViewFlat")
    $btnToolbarTree   = $window.FindName("BtnToolbarTree")
    $txtModeIndicator = $window.FindName("TxtModeIndicator")
    $menuExpandAll    = $window.FindName("MenuExpandAll")
    $menuCollapseAll  = $window.FindName("MenuCollapseAll")

    $setViewMode = {
        param([bool]$treeMode)
        $stateContainer.IsTreeMode = $treeMode
        if ($treeMode) {
            $stateContainer.SortProperty   = "PID"
            $stateContainer.SortDescending = $false
            foreach ($c in $gridProcesses.Columns) { $c.SortDirection = $null }
        } else {
            $hasActiveGlyph = $false
            foreach ($c in $gridProcesses.Columns) {
                if ($null -ne $c.SortDirection) { $hasActiveGlyph = $true; break }
            }
            if (-not $hasActiveGlyph) {
                $targetSortProp = if ($stateContainer.SortProperty) { [string]$stateContainer.SortProperty } else { "PID" }
                $dir = if ($stateContainer.SortDescending) { [System.ComponentModel.ListSortDirection]::Descending } else { [System.ComponentModel.ListSortDirection]::Ascending }
                foreach ($c in $gridProcesses.Columns) {
                    if ($c.SortMemberPath -eq $targetSortProp) {
                        $c.SortDirection = $dir
                        break
                    }
                }
            }
        }
        if ($menuViewTree)     { $menuViewTree.IsChecked   = $treeMode }
        if ($menuViewFlat)     { $menuViewFlat.IsChecked   = (-not $treeMode) }
        if ($txtModeIndicator) { $txtModeIndicator.Text    = if ($treeMode) { "Tree" } else { "Flat" } }
        & $engineHandle.RefreshTree
    }

    $gridProcesses.add_Sorting({
        param($sender, $e)
        $e.Handled = $true
        $col = $e.Column
        $sortProp = $col.SortMemberPath
        if (-not $sortProp) { $sortProp = "PID" }

        $next = Get-PSRPMNextColumnSortState `
            -IsTreeMode ([bool]$stateContainer.IsTreeMode) `
            -CurrentSortProperty ([string]$stateContainer.SortProperty) `
            -CurrentSortDescending ([bool]$stateContainer.SortDescending) `
            -ClickedSortProperty $sortProp

        if ($next.IsTreeMode) {
            &$setViewMode $true
            return
        }

        $stateContainer.SortProperty   = $next.SortProperty
        $stateContainer.SortDescending = $next.SortDescending

        foreach ($c in $gridProcesses.Columns) { $c.SortDirection = $null }
        $col.SortDirection = if ($next.SortDescending) {
            [System.ComponentModel.ListSortDirection]::Descending
        } else {
            [System.ComponentModel.ListSortDirection]::Ascending
        }

        &$setViewMode $false
    })

    if ($menuViewTree)   { $menuViewTree.add_Click({ &$setViewMode $true }) }
    if ($menuViewFlat)   { $menuViewFlat.add_Click({ &$setViewMode $false }) }
    if ($btnToolbarTree) { $btnToolbarTree.add_Click({ &$setViewMode (-not [bool]$stateContainer.IsTreeMode) }) }

    if ($menuExpandAll) {
        $menuExpandAll.add_Click({
            foreach ($vm in $engineHandle.ProcessMap.Values) {
                $vm.IsExpanded = $true
                $vm.UpdateExpanderGeometry()
            }
            & $engineHandle.RefreshTree
        })
    }
    if ($menuCollapseAll) {
        $menuCollapseAll.add_Click({
            foreach ($vm in $engineHandle.ProcessMap.Values) {
                $vm.IsExpanded = $false
                $vm.UpdateExpanderGeometry()
            }
            & $engineHandle.RefreshTree
        })
    }

    # 9. Search Filter & Interactive Semantic Legend Category Filter
    $txtSearch            = $window.FindName("TxtSearch")
    $btnClearSearch       = $window.FindName("BtnClearSearch")
    $txtFilterLegendLabel = $window.FindName("TxtFilterLegendLabel")
    $btnLegendAll         = $window.FindName("BtnLegendAll")
    $btnLegendService     = $window.FindName("BtnLegendService")
    $btnLegendOwn         = $window.FindName("BtnLegendOwn")
    $btnLegendPackaged    = $window.FindName("BtnLegendPackaged")
    $btnLegendClear       = $window.FindName("BtnLegendClear")

    if ($txtSearch) {
        $txtSearch.add_TextChanged({
            $stateContainer.FilterText = $txtSearch.Text
            & $engineHandle.RefreshTree
        })
    }
    if ($btnClearSearch) {
        $btnClearSearch.add_Click({
            if ($txtSearch) { $txtSearch.Text = "" }
            $stateContainer.FilterText = ""
            & $engineHandle.RefreshTree
        })
    }

    $updateLegendFilterUi = {
        $cur = $stateContainer.CategoryFilter
        $bc = [System.Windows.Media.BrushConverter]::new()

        if (-not $cur) {
            # ALL active
            if ($txtFilterLegendLabel) {
                $txtFilterLegendLabel.Text = "Filter Legend:"
                $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
                $txtFilterLegendLabel.Foreground = $window.FindResource("BrushTextMuted")
            }
            if ($btnLegendClear) { $btnLegendClear.Visibility = [System.Windows.Visibility]::Collapsed }

            if ($btnLegendAll) {
                $btnLegendAll.Content = "All"
                $btnLegendAll.FontWeight = [System.Windows.FontWeights]::Bold
                $btnLegendAll.BorderThickness = [System.Windows.Thickness]::new(2)
                $btnLegendAll.BorderBrush = $bc.ConvertFromString("#0284C7")
                $btnLegendAll.Opacity = 1.0
            }
            if ($btnLegendService) {
                $btnLegendService.Content = "Services"
                $btnLegendService.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendService.BorderBrush = $bc.ConvertFromString("#FDA4AF")
                $btnLegendService.Background = $bc.ConvertFromString("#FFE4E6")
                $btnLegendService.Opacity = 0.85
            }
            if ($btnLegendOwn) {
                $btnLegendOwn.Content = "Own / User"
                $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendOwn.BorderBrush = $bc.ConvertFromString("#A5B4FC")
                $btnLegendOwn.Background = $bc.ConvertFromString("#E0E7FF")
                $btnLegendOwn.Opacity = 0.85
            }
            if ($btnLegendPackaged) {
                $btnLegendPackaged.Content = "Packaged / WebView"
                $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendPackaged.BorderBrush = $bc.ConvertFromString("#06B6D4")
                $btnLegendPackaged.Background = $bc.ConvertFromString("#67E8F9")
                $btnLegendPackaged.Opacity = 0.85
            }
        } else {
            # SPECIFIC category active
            if ($btnLegendClear) { $btnLegendClear.Visibility = [System.Windows.Visibility]::Visible }
            if ($btnLegendAll) {
                $btnLegendAll.Content = "All"
                $btnLegendAll.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendAll.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendAll.BorderBrush = $bc.ConvertFromString("#94A3B8")
                $btnLegendAll.Opacity = 0.45
            }

            if ($cur -eq "Service") {
                if ($txtFilterLegendLabel) {
                    $txtFilterLegendLabel.Text = "ACTIVE FILTER:"
                    $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::Bold
                    $txtFilterLegendLabel.Foreground = $bc.ConvertFromString("#BE123C")
                }
                if ($btnLegendService) {
                    $btnLegendService.Content = "[ Services ]"
                    $btnLegendService.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(2)
                    $btnLegendService.BorderBrush = $bc.ConvertFromString("#BE123C")
                    $btnLegendService.Background = $bc.ConvertFromString("#FECDD3")
                    $btnLegendService.Opacity = 1.0
                }
                if ($btnLegendOwn) {
                    $btnLegendOwn.Content = "Own / User"
                    $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendOwn.BorderBrush = $bc.ConvertFromString("#A5B4FC")
                    $btnLegendOwn.Background = $bc.ConvertFromString("#E0E7FF")
                    $btnLegendOwn.Opacity = 0.45
                }
                if ($btnLegendPackaged) {
                    $btnLegendPackaged.Content = "Packaged / WebView"
                    $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendPackaged.BorderBrush = $bc.ConvertFromString("#06B6D4")
                    $btnLegendPackaged.Background = $bc.ConvertFromString("#67E8F9")
                    $btnLegendPackaged.Opacity = 0.45
                }
            } elseif ($cur -eq "Own") {
                if ($txtFilterLegendLabel) {
                    $txtFilterLegendLabel.Text = "ACTIVE FILTER:"
                    $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::Bold
                    $txtFilterLegendLabel.Foreground = $bc.ConvertFromString("#4338CA")
                }
                if ($btnLegendService) {
                    $btnLegendService.Content = "Services"
                    $btnLegendService.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendService.BorderBrush = $bc.ConvertFromString("#FDA4AF")
                    $btnLegendService.Background = $bc.ConvertFromString("#FFE4E6")
                    $btnLegendService.Opacity = 0.45
                }
                if ($btnLegendOwn) {
                    $btnLegendOwn.Content = "[ Own / User ]"
                    $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(2)
                    $btnLegendOwn.BorderBrush = $bc.ConvertFromString("#4338CA")
                    $btnLegendOwn.Background = $bc.ConvertFromString("#C7D2FE")
                    $btnLegendOwn.Opacity = 1.0
                }
                if ($btnLegendPackaged) {
                    $btnLegendPackaged.Content = "Packaged / WebView"
                    $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendPackaged.BorderBrush = $bc.ConvertFromString("#06B6D4")
                    $btnLegendPackaged.Background = $bc.ConvertFromString("#67E8F9")
                    $btnLegendPackaged.Opacity = 0.45
                }
            } elseif ($cur -eq "Packaged") {
                if ($txtFilterLegendLabel) {
                    $txtFilterLegendLabel.Text = "ACTIVE FILTER:"
                    $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::Bold
                    $txtFilterLegendLabel.Foreground = $bc.ConvertFromString("#0E7490")
                }
                if ($btnLegendService) {
                    $btnLegendService.Content = "Services"
                    $btnLegendService.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendService.BorderBrush = $bc.ConvertFromString("#FDA4AF")
                    $btnLegendService.Background = $bc.ConvertFromString("#FFE4E6")
                    $btnLegendService.Opacity = 0.45
                }
                if ($btnLegendOwn) {
                    $btnLegendOwn.Content = "Own / User"
                    $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendOwn.BorderBrush = $bc.ConvertFromString("#A5B4FC")
                    $btnLegendOwn.Background = $bc.ConvertFromString("#E0E7FF")
                    $btnLegendOwn.Opacity = 0.45
                }
                if ($btnLegendPackaged) {
                    $btnLegendPackaged.Content = "[ Packaged ]"
                    $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(2)
                    $btnLegendPackaged.BorderBrush = $bc.ConvertFromString("#0E7490")
                    $btnLegendPackaged.Background = $bc.ConvertFromString("#A5F3FC")
                    $btnLegendPackaged.Opacity = 1.0
                }
            }
        }
    }

    $setCategoryFilter = {
        param([string]$cat)
        if ($stateContainer.CategoryFilter -eq $cat) {
            $stateContainer.CategoryFilter = ""
        } else {
            $stateContainer.CategoryFilter = $cat
        }
        &$updateLegendFilterUi
        & $engineHandle.RefreshTree
    }
    if ($btnLegendAll) {
        $btnLegendAll.add_Click({
            $stateContainer.CategoryFilter = ""
            &$updateLegendFilterUi
            & $engineHandle.RefreshTree
        })
    }
    if ($btnLegendClear) {
        $btnLegendClear.add_Click({
            $stateContainer.CategoryFilter = ""
            &$updateLegendFilterUi
            & $engineHandle.RefreshTree
        })
    }
    if ($btnLegendService)  { $btnLegendService.add_Click({ &$setCategoryFilter "Service" }) }
    if ($btnLegendOwn)      { $btnLegendOwn.add_Click({ &$setCategoryFilter "Own" }) }
    if ($btnLegendPackaged) { $btnLegendPackaged.add_Click({ &$setCategoryFilter "Packaged" }) }
    &$updateLegendFilterUi

    # 9B. Status Bar Responsive Overflow Sync
    $scrollStatusLegend = $window.FindName("ScrollStatusLegend")
    $btnStatusOverflow  = $window.FindName("BtnStatusOverflow")

    $syncStatusOverflow = {
        if ($scrollStatusLegend -and $btnStatusOverflow) {
            $scrollable = $scrollStatusLegend.ScrollableWidth
            if ($scrollable -gt 2) {
                $btnStatusOverflow.Visibility = [System.Windows.Visibility]::Visible
                $atEnd = ($scrollStatusLegend.HorizontalOffset -ge ($scrollable - 8))
                $btnStatusOverflow.Content = if ($atEnd) { "<< Start" } else { ">> More" }
                $btnStatusOverflow.ToolTip = if ($atEnd) {
                    "Showing scrolled status items. Click to return to beginning of legend."
                } else {
                    "More status items hidden (window is narrow). Click to scroll right, or use mouse wheel."
                }
            } else {
                $btnStatusOverflow.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }

    if ($scrollStatusLegend) {
        $scrollStatusLegend.add_ScrollChanged({ &$syncStatusOverflow })
        $scrollStatusLegend.add_PreviewMouseWheel({
            param($sender, $e)
            if ($scrollStatusLegend.ScrollableWidth -gt 0) {
                $newOff = $scrollStatusLegend.HorizontalOffset - ($e.Delta / 3)
                $scrollStatusLegend.ScrollToHorizontalOffset($newOff)
                $e.Handled = $true
            }
        })
    }
    if ($btnStatusOverflow) {
        $btnStatusOverflow.add_Click({
            if ($scrollStatusLegend) {
                if ($scrollStatusLegend.HorizontalOffset -ge ($scrollStatusLegend.ScrollableWidth - 8)) {
                    $scrollStatusLegend.ScrollToHorizontalOffset(0)
                } else {
                    $scrollStatusLegend.ScrollToHorizontalOffset($scrollStatusLegend.HorizontalOffset + 140)
                }
            }
        })
    }
    $window.add_SizeChanged({ &$syncStatusOverflow })

    # 10. Polling Rate & Pause/Resume Controls
    $menuRefresh      = $window.FindName("MenuRefresh")
    $btnToolbarRef    = $window.FindName("BtnToolbarRefresh")
    $btnToolbarPause  = $window.FindName("BtnToolbarPause")
    $iconToolbarPause = $window.FindName("IconToolbarPause")
    $txtToolbarPause  = $window.FindName("TxtToolbarPause")
    $badgePaused      = $window.FindName("BadgePaused")
    $statusText       = $window.FindName("StatusText")
    $menuRate500ms    = $window.FindName("MenuRate500ms")
    $menuRate1s       = $window.FindName("MenuRate1s")
    $menuRate2s       = $window.FindName("MenuRate2s")
    $menuRate5s       = $window.FindName("MenuRate5s")
    $menuRatePaused   = $window.FindName("MenuRatePaused")
    $menuVerbose      = $window.FindName("MenuVerboseTelemetry")

    $geomPause      = [System.Windows.Media.Geometry]::Parse("M6,19h4V5H6V19z M14,5v14h4V5H14z")
    $geomResume     = [System.Windows.Media.Geometry]::Parse("M8,5.14v14l11-7-11-7z")
    $brushAmber     = $brushConv.ConvertFromString("#F59E0B")
    $brushAmberDark = $brushConv.ConvertFromString("#D97706")
    $brushAmberBg   = $brushConv.ConvertFromString("#26F59E0B")

    $updatePauseUi = {
        param([bool]$pauseState)
        $useDark = [bool]$stateContainer.IsDarkTheme
        if ($pauseState) {
            if ($iconToolbarPause) {
                $iconToolbarPause.Data = $geomResume
                $iconToolbarPause.Fill = if ($useDark) { $brushAmber } else { $brushAmberDark }
            }
            if ($txtToolbarPause) {
                $txtToolbarPause.Text = "PAUSED"
                $txtToolbarPause.Foreground = if ($useDark) { $brushAmber } else { $brushAmberDark }
                $txtToolbarPause.FontWeight = [System.Windows.FontWeights]::Bold
                $txtToolbarPause.Visibility = [System.Windows.Visibility]::Visible
            }
            if ($btnToolbarPause) {
                $btnToolbarPause.ToolTip = "Resume Polling (Space)"
                $btnToolbarPause.Background = $brushAmberBg
                $btnToolbarPause.BorderBrush = if ($useDark) { $brushAmber } else { $brushAmberDark }
            }
            if ($badgePaused) {
                $badgePaused.Visibility = [System.Windows.Visibility]::Visible
            }
            if ($statusText) {
                $lastTelem = [string]$stateContainer.LastStatusText
                if ($lastTelem) {
                    $statusText.Text = "[PAUSED] $lastTelem"
                } else {
                    $statusText.Text = "PAUSED - Telemetry collection suspended. Press Space or click Resume to continue."
                }
            }
        } else {
            if ($iconToolbarPause) {
                $iconToolbarPause.Data = $geomPause
                $secBrush = $window.TryFindResource("BrushTextSecondary")
                if ($null -eq $secBrush) {
                    $secBrush = if ($useDark) { $brushConv.ConvertFromString("#CBD5E1") } else { $brushConv.ConvertFromString("#334155") }
                }
                $iconToolbarPause.Fill = $secBrush
            }
            if ($txtToolbarPause) {
                $txtToolbarPause.Text = ""
                $txtToolbarPause.Visibility = [System.Windows.Visibility]::Collapsed
            }
            if ($btnToolbarPause) {
                $btnToolbarPause.ToolTip = "Pause Polling (Space)"
                $btnToolbarPause.Background = [System.Windows.Media.Brushes]::Transparent
                $btnToolbarPause.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            }
            if ($badgePaused) {
                $badgePaused.Visibility = [System.Windows.Visibility]::Collapsed
            }
            if ($statusText) {
                $lastTelem = [string]$stateContainer.LastStatusText
                if ($lastTelem) {
                    $statusText.Text = $lastTelem
                }
            }
        }

        if ($script:ActiveHostTab) {
            $canClose = ($hostTabsCollection.Count -gt 1)
            $script:ActiveHostTab.UpdateVisualState($true, $useDark, $canClose, $stateContainer.ConnectionState, $pauseState, $stateContainer.PollLatencyMs)
        }
    }

    $setPollingRate = {
        param([int]$ms, [bool]$pause)
        $prevPaused = [bool]$stateContainer.IsPaused
        $stateContainer.IsPaused = $pause
        if (-not $pause -and $ms -ge 250) {
            $stateContainer.IntervalMs = $ms
        }
        if ($menuRate500ms)  { $menuRate500ms.IsChecked  = (-not $pause -and $ms -eq 500) }
        if ($menuRate1s)     { $menuRate1s.IsChecked     = (-not $pause -and $ms -eq 1000) }
        if ($menuRate2s)     { $menuRate2s.IsChecked     = (-not $pause -and $ms -eq 2000) }
        if ($menuRate5s)     { $menuRate5s.IsChecked     = (-not $pause -and $ms -eq 5000) }
        if ($menuRatePaused) { $menuRatePaused.IsChecked = $pause }

        &$updatePauseUi $pause

        if ($prevPaused -ne $pause) {
            if ($pause) {
                &$writeAuditLog "RATE" "Telemetry collection paused. Press Space or click Resume to continue."
            } else {
                &$writeAuditLog "RATE" "Telemetry collection resumed (Interval: $($stateContainer.IntervalMs) ms)."
            }
        }
        [void]$stateContainer.WakeEvent.Set()
    }

    $triggerImmediateRefresh = {
        &$setPollingRate $stateContainer.IntervalMs $false
    }
    if ($menuRefresh)   { $menuRefresh.add_Click($triggerImmediateRefresh) }
    if ($btnToolbarRef) { $btnToolbarRef.add_Click($triggerImmediateRefresh) }

    if ($menuRate500ms)   { $menuRate500ms.add_Click({ &$setPollingRate 500 $false }) }
    if ($menuRate1s)      { $menuRate1s.add_Click({ &$setPollingRate 1000 $false }) }
    if ($menuRate2s)      { $menuRate2s.add_Click({ &$setPollingRate 2000 $false }) }
    if ($menuRate5s)      { $menuRate5s.add_Click({ &$setPollingRate 5000 $false }) }
    if ($menuRatePaused)  { $menuRatePaused.add_Click({ &$setPollingRate $stateContainer.IntervalMs (-not [bool]$stateContainer.IsPaused) }) }
    if ($btnToolbarPause) { $btnToolbarPause.add_Click({ &$setPollingRate $stateContainer.IntervalMs (-not [bool]$stateContainer.IsPaused) }) }
    # 11. Audit Log Pane & Telemetry Stream Controls
    $menuViewLog      = $window.FindName("MenuViewLog")
    $btnShowLog       = $window.FindName("BtnShowLog")
    $btnToggleLogPane = $window.FindName("BtnToggleLogPane")
    $btnClearLog      = $window.FindName("BtnClearLog")
    $btnCopyLog       = $window.FindName("BtnCopyLog")
    $chkStreamTicks   = $window.FindName("ChkStreamTicks")

    if ($menuVerbose) {
        $menuVerbose.add_Click({
            $val = [bool]$menuVerbose.IsChecked
            $stateContainer.VerboseTelemetryLog = $val
            if ($chkStreamTicks) { $chkStreamTicks.IsChecked = $val }
            if ($val -and $logPane) {
                $logPane.Visibility = "Visible"
                if ($menuViewLog) { $menuViewLog.IsChecked = $true }
            }
        })
    }
    if ($chkStreamTicks) {
        $chkStreamTicks.add_Click({
            $val = [bool]$chkStreamTicks.IsChecked
            $stateContainer.VerboseTelemetryLog = $val
            if ($menuVerbose) { $menuVerbose.IsChecked = $val }
        })
    }

    $toggleLogPane = {
        if ($logPane.Visibility -eq "Visible") {
            $logPane.Visibility = "Collapsed"
            if ($menuViewLog) { $menuViewLog.IsChecked = $false }
        } else {
            $logPane.Visibility = "Visible"
            if ($menuViewLog) { $menuViewLog.IsChecked = $true }
        }
    }
    if ($menuViewLog)      { $menuViewLog.add_Click($toggleLogPane) }
    if ($btnShowLog)       { $btnShowLog.add_Click($toggleLogPane) }
    if ($btnToggleLogPane) { $btnToggleLogPane.add_Click($toggleLogPane) }
    if ($btnClearLog)      { $btnClearLog.add_Click({ if ($txtLogConsole) { $txtLogConsole.Clear() } }) }
    if ($btnCopyLog)       { $btnCopyLog.add_Click({ if ($txtLogConsole -and $txtLogConsole.Text) { [System.Windows.Clipboard]::SetText($txtLogConsole.Text) } }) }

    # 12. Process & Service Operations Dispatcher
    $menuConfirmKill = $window.FindName("MenuConfirmKill")
    $jssAction = [System.Web.Script.Serialization.JavaScriptSerializer]::new()

    $invokeProcessAction = {
        param(
            [string]$actionName,
            [Object]$procVm,
            [string]$priorityVal = "Normal",
            [scriptblock]$afterCallback = $null,
            [string]$handleId = "",
            [string]$dumpType = "Mini"
        )

        $selectedTargets = [System.Collections.Generic.List[Object]]::new()
        if ($null -ne $procVm) {
            [void]$selectedTargets.Add($procVm)
        } else {
            $seenPids = [System.Collections.Generic.HashSet[int]]::new()
            if ($gridProcesses.SelectedItems -and $gridProcesses.SelectedItems.Count -gt 0) {
                foreach ($item in @($gridProcesses.SelectedItems)) {
                    if ($null -ne $item -and $seenPids.Add([int]$item.PID)) {
                        [void]$selectedTargets.Add($item)
                    }
                }
            } elseif ($gridProcesses.SelectedItem) {
                [void]$selectedTargets.Add($gridProcesses.SelectedItem)
            }
        }
        if ($selectedTargets.Count -eq 0) { return }

        $batchCapable = $actionName -in @("KillProcess", "KillTree", "SuspendProcess", "ResumeProcess", "SetPriority")
        if ($selectedTargets.Count -eq 1 -or -not $batchCapable) {
            $singleVm = $selectedTargets[0]
            $tPid  = [int]$singleVm.PID
            $tName = [string]$singleVm.Name

            if ($tPid -le 4 -and $actionName -in @("KillProcess", "KillTree", "SuspendProcess", "CreateDump")) {
                [System.Windows.MessageBox]::Show(
                    "Cannot perform '$actionName' on critical Windows kernel process '$tName' (PID $tPid).",
                    "PSRPM - Protected Kernel Process",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                ) | Out-Null
                return
            }

            $confirmRequired = if ($menuConfirmKill) { [bool]$menuConfirmKill.IsChecked } else { $true }
            if ($confirmRequired -and $actionName -in @("KillProcess", "KillTree")) {
                $promptMsg = if ($actionName -eq "KillTree") {
                    "Are you sure you want to terminate '$tName' (PID $tPid) and ALL of its descendant child processes on $($stateContainer.TargetDisplayName)?"
                } else {
                    "Are you sure you want to terminate '$tName' (PID $tPid) on $($stateContainer.TargetDisplayName)?"
                }
                $confirm = [System.Windows.MessageBox]::Show(
                    $promptMsg,
                    "PSRPM - Confirm Process Termination",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning
                )
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }

            &$writeAuditLog "ACTION" "Dispatching $actionName on '$tName' (PID $tPid)..."

            $cmdPayload = @{
                CommandType        = "ProcessAction"
                Action             = $actionName
                TargetPid          = $tPid
                ExpectedName       = $tName
                ExpectedCreateTime = if ($singleVm.CreateTime) { [long]$singleVm.CreateTime } else { 0L }
                ServiceName        = ""
                Priority           = $priorityVal
                HandleId           = $handleId
                DumpType           = $dumpType
            }

            $localJss   = $jssAction
            $localLog   = $writeAuditLog
            $localState = $stateContainer
            $localAfter = $afterCallback
            $localAct   = $actionName

            & $engineHandle.SendCommand $cmdPayload ({
                param($res)
                $actSuccess = $false
                if ($res.Success -and $res.PayloadJson) {
                    $parsed = $localJss.DeserializeObject($res.PayloadJson)
                    if ($parsed['Success']) {
                        $actSuccess = $true
                        &$localLog "SUCCESS" "$($parsed['Message']) ($($res.ElapsedMs)ms)"
                        if ($localAct -eq "CreateDump" -and $parsed['DumpPath']) {
                            $dPath = [string]$parsed['DumpPath']
                            try { [System.Windows.Clipboard]::SetText($dPath) } catch { }
                            [System.Windows.MessageBox]::Show(
                                "Process memory dump created successfully!`n`nRemote Path:`n$dPath`n`n(The remote file path has been copied to your clipboard).",
                                "PSRPM - Memory Dump Created",
                                [System.Windows.MessageBoxButton]::OK,
                                [System.Windows.MessageBoxImage]::Information
                            ) | Out-Null
                        }
                    } else {
                        &$localLog "WARN" "$($parsed['Message']) ($($res.ElapsedMs)ms)"
                        [System.Windows.MessageBox]::Show($parsed['Message'], "PSRPM - Operation Warning", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                    }
                } else {
                    &$localLog "ERROR" "$localAct failed: $($res.Error)"
                    [System.Windows.MessageBox]::Show("Action '$localAct' failed:`n$($res.Error)", "PSRPM - Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                }
                [void]$localState.WakeEvent.Set()
                if ($localAfter) { & $localAfter $actSuccess }
            }.GetNewClosure())
            return
        }

        # Multi-select batch path
        $validTargets  = [System.Collections.Generic.List[Object]]::new()
        $skippedKernel = [System.Collections.Generic.List[Object]]::new()
        $protectKernel = $actionName -in @("KillProcess", "KillTree", "SuspendProcess")

        foreach ($cand in $selectedTargets) {
            if ($protectKernel -and ([int]$cand.PID -le 4)) {
                [void]$skippedKernel.Add($cand)
            } else {
                [void]$validTargets.Add($cand)
            }
        }

        if ($validTargets.Count -eq 0) {
            $firstKern = $skippedKernel[0]
            [System.Windows.MessageBox]::Show(
                "Cannot perform '$actionName' on critical Windows kernel process(es) such as '$($firstKern.Name)' (PID $($firstKern.PID)).",
                "PSRPM - Protected Kernel Process",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }

        if ($skippedKernel.Count -gt 0) {
            &$writeAuditLog "WARN" "Skipping $($skippedKernel.Count) protected kernel process(es) (PID <= 4) from batch $actionName."
        }

        # For KillTree, avoid dispatching redundant KillTree commands on descendants of an already-selected root
        $dispatchTargets = $validTargets
        if ($actionName -eq "KillTree" -and $engineHandle -and $engineHandle.ProcessMap) {
            $selectedPidSet = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($vt in $validTargets) { [void]$selectedPidSet.Add([int]$vt.PID) }
            $deduped = [System.Collections.Generic.List[Object]]::new()
            $procMap = $engineHandle.ProcessMap
            foreach ($vt in $validTargets) {
                $hasSelectedAncestor = $false
                $curPid = [int]$vt.ParentPID
                $depth = 0
                $visitedAnc = [System.Collections.Generic.HashSet[int]]::new()
                [void]$visitedAnc.Add([int]$vt.PID)
                while ($curPid -gt 0 -and $depth -lt 128 -and $visitedAnc.Add($curPid)) {
                    if ($selectedPidSet.Contains($curPid)) {
                        $hasSelectedAncestor = $true
                        break
                    }
                    if ($procMap.ContainsKey($curPid)) {
                        $curPid = [int]$procMap[$curPid].ParentPID
                    } else {
                        break
                    }
                    $depth++
                }
                if (-not $hasSelectedAncestor) {
                    [void]$deduped.Add($vt)
                }
            }
            if ($deduped.Count -gt 0) {
                $dispatchTargets = $deduped
            }
        }

        $confirmRequired = if ($menuConfirmKill) { [bool]$menuConfirmKill.IsChecked } else { $true }
        if ($confirmRequired -and $actionName -in @("KillProcess", "KillTree")) {
            $previewLines = [System.Collections.Generic.List[string]]::new()
            $maxPreview = [Math]::Min(8, $validTargets.Count)
            for ($pi = 0; $pi -lt $maxPreview; $pi++) {
                $pv = $validTargets[$pi]
                [void]$previewLines.Add("  - $($pv.Name) (PID $($pv.PID))")
            }
            if ($validTargets.Count -gt 8) {
                [void]$previewLines.Add("  ...and $($validTargets.Count - 8) more.")
            }
            $actionVerb = if ($actionName -eq "KillTree") {
                "terminate $($validTargets.Count) selected processes and ALL of their descendant child processes"
            } else {
                "terminate $($validTargets.Count) selected processes"
            }
            $promptMsg = "Are you sure you want to $actionVerb on $($stateContainer.TargetDisplayName)?`n`n" + ($previewLines -join "`n")
            if ($skippedKernel.Count -gt 0) {
                $promptMsg += "`n`nNote: $($skippedKernel.Count) protected kernel process(es) (PID <= 4) will be skipped."
            }
            $confirm = [System.Windows.MessageBox]::Show(
                $promptMsg,
                "PSRPM - Confirm Batch Process Termination",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        $payloadTargets = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($dt in $dispatchTargets) {
            [void]$payloadTargets.Add(@{
                TargetPid          = [int]$dt.PID
                ExpectedName       = [string]$dt.Name
                ExpectedCreateTime = if ($dt.CreateTime) { [long]$dt.CreateTime } else { 0L }
            })
        }

        &$writeAuditLog "ACTION" "Dispatching batch $actionName on $($dispatchTargets.Count) target(s)..."

        $cmdPayload = @{
            CommandType = "BatchProcessAction"
            Action      = $actionName
            Targets     = @($payloadTargets.ToArray())
            Priority    = $priorityVal
            DumpType    = $dumpType
        }

        $localJss   = $jssAction
        $localLog   = $writeAuditLog
        $localState = $stateContainer
        $localAfter = $afterCallback
        $localAct   = $actionName
        $localTotal = $dispatchTargets.Count

        & $engineHandle.SendCommand $cmdPayload ({
            param($res)
            $okCount = 0
            $failMsgs = [System.Collections.Generic.List[string]]::new()
            if ($res.Success -and $res.PayloadJson) {
                $parsedArr = $localJss.DeserializeObject($res.PayloadJson)
                foreach ($item in $parsedArr) {
                    if ($null -eq $item) { continue }
                    if ($item['Success']) {
                        $okCount++
                        &$localLog "SUCCESS" "$($item['Message'])"
                    } else {
                        $msgText = [string]$item['Message']
                        if ([string]::IsNullOrWhiteSpace($msgText)) { $msgText = "Unknown error on PID $($item['PID'])" }
                        [void]$failMsgs.Add("PID $($item['PID']): $msgText")
                        &$localLog "WARN" "$msgText"
                    }
                }
                if ($failMsgs.Count -eq 0) {
                    &$localLog "SUCCESS" "Batch $localAct completed ($okCount/$localTotal succeeded, $($res.ElapsedMs)ms)."
                } else {
                    &$localLog "WARN" "Batch $localAct finished: $okCount succeeded, $($failMsgs.Count) failed ($($res.ElapsedMs)ms)."
                    $showLimit = [Math]::Min(10, $failMsgs.Count)
                    $previewErr = [System.Collections.Generic.List[string]]::new()
                    for ($ei = 0; $ei -lt $showLimit; $ei++) {
                        [void]$previewErr.Add("  - $($failMsgs[$ei])")
                    }
                    if ($failMsgs.Count -gt 10) {
                        [void]$previewErr.Add("  ...and $($failMsgs.Count - 10) more (see Audit Log).")
                    }
                    $summaryErr = "Batch '$localAct': $okCount succeeded, $($failMsgs.Count) failed:`n`n" + ($previewErr -join "`n")
                    [System.Windows.MessageBox]::Show($summaryErr, "PSRPM - Batch Operation Warning", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                }
            } else {
                &$localLog "ERROR" "Batch $localAct failed: $($res.Error)"
                [System.Windows.MessageBox]::Show("Batch action '$localAct' failed:`n$($res.Error)", "PSRPM - Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            }
            [void]$localState.WakeEvent.Set()
            if ($localAfter) { & $localAfter ($okCount -gt 0) }
        }.GetNewClosure())
    }

    # Wire Process Menu, Toolbar & ContextMenu Actions
    $window.FindName("MenuEndProcess").add_Click({ &$invokeProcessAction "KillProcess" $null })
    $window.FindName("MenuEndProcessTree").add_Click({ &$invokeProcessAction "KillTree" $null })
    $window.FindName("MenuSuspend").add_Click({ &$invokeProcessAction "SuspendProcess" $null })
    $window.FindName("MenuResume").add_Click({ &$invokeProcessAction "ResumeProcess" $null })
    $btnKillProcess = $window.FindName("BtnToolbarKill")
    if ($btnKillProcess) { $btnKillProcess.add_Click({ &$invokeProcessAction "KillProcess" $null }) }
    $btnKillTree = $window.FindName("BtnToolbarKillTree")
    if ($btnKillTree) { $btnKillTree.add_Click({ &$invokeProcessAction "KillTree" $null }) }

    $actionCreateDump = {
        param([string]$dumpType, [Object]$targetProc = $null)
        $procVm = if ($targetProc) { $targetProc } else { $gridProcesses.SelectedItem }
        if (-not $procVm) { return }
        $tPid  = [int]$procVm.PID
        $tName = [string]$procVm.Name
        if ($tPid -le 4) {
            [System.Windows.MessageBox]::Show(
                "Cannot generate a memory dump for System process '$tName' (PID $tPid).",
                "PSRPM - Protected Kernel Process",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }
        $typeLabel = if ($dumpType -eq "Full") { "Full Memory Dump (~$([Math]::Round($procVm.MemoryBytes / 1MB, 1)) MB)" } else { "Minidump" }
        $msg = "Generate $typeLabel for '$tName' (PID $tPid) on $($stateContainer.TargetDisplayName)?`n`nThe dump will be saved directly to 'C:\temp\' on the target host."
        $confirm = [System.Windows.MessageBox]::Show(
            $msg,
            "PSRPM - Confirm Process Dump",
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -eq [System.Windows.MessageBoxResult]::OK) {
            &$invokeProcessAction "CreateDump" $procVm "Normal" $null "" $dumpType
        }
    }

    $menuCreateMini = $window.FindName("MenuCreateMiniDump")
    if ($menuCreateMini) { $menuCreateMini.add_Click({ &$actionCreateDump "Mini" }) }
    $menuCreateFull = $window.FindName("MenuCreateFullDump")
    if ($menuCreateFull) { $menuCreateFull.add_Click({ &$actionCreateDump "Full" }) }
    $ctxCreateMini  = $window.FindName("CtxCreateMiniDump")
    if ($ctxCreateMini)  { $ctxCreateMini.add_Click({ &$actionCreateDump "Mini" }) }
    $ctxCreateFull  = $window.FindName("CtxCreateFullDump")
    if ($ctxCreateFull)  { $ctxCreateFull.add_Click({ &$actionCreateDump "Full" }) }

    $window.FindName("MenuPrioIdle").add_Click({ &$invokeProcessAction "SetPriority" $null "Idle" })
    $window.FindName("MenuPrioBelow").add_Click({ &$invokeProcessAction "SetPriority" $null "BelowNormal" })
    $window.FindName("MenuPrioNormal").add_Click({ &$invokeProcessAction "SetPriority" $null "Normal" })
    $window.FindName("MenuPrioAbove").add_Click({ &$invokeProcessAction "SetPriority" $null "AboveNormal" })
    $window.FindName("MenuPrioHigh").add_Click({ &$invokeProcessAction "SetPriority" $null "High" })

    $window.FindName("CtxEndProcess").add_Click({ &$invokeProcessAction "KillProcess" $null })
    $window.FindName("CtxEndTree").add_Click({ &$invokeProcessAction "KillTree" $null })
    $window.FindName("CtxSuspend").add_Click({ &$invokeProcessAction "SuspendProcess" $null })
    $window.FindName("CtxResume").add_Click({ &$invokeProcessAction "ResumeProcess" $null })
    $window.FindName("CtxCopyCmdLine").add_Click({
        $sel = $gridProcesses.SelectedItem
        if ($sel -and $sel.CommandLine) {
            [System.Windows.Clipboard]::SetText($sel.CommandLine)
            &$writeAuditLog "CLIPBOARD" "Copied command line for $($sel.Name) (PID $($sel.PID))."
        }
    })
    $window.FindName("CtxCopyPath").add_Click({
        $sel = $gridProcesses.SelectedItem
        if ($sel -and $sel.Path) {
            [System.Windows.Clipboard]::SetText($sel.Path)
            &$writeAuditLog "CLIPBOARD" "Copied executable path for $($sel.Name) (PID $($sel.PID))."
        }
    })

    $menuProcessItem     = $window.FindName("MenuProcess")
    $menuPropsItem       = $window.FindName("MenuProperties")
    $menuSuspendItem     = $window.FindName("MenuSuspend")
    $menuResumeItem      = $window.FindName("MenuResume")
    $menuKillItem        = $window.FindName("MenuEndProcess")
    $menuKillTreeItem    = $window.FindName("MenuEndProcessTree")
    $menuCreateDumpItem  = $window.FindName("MenuCreateDump")
    $ctxPropsItem        = $window.FindName("CtxProperties")
    $ctxSuspendItem      = $window.FindName("CtxSuspend")
    $ctxResumeItem       = $window.FindName("CtxResume")
    $ctxKillItem         = $window.FindName("CtxEndProcess")
    $ctxKillTreeItem     = $window.FindName("CtxEndTree")
    $ctxCreateDumpItem   = $window.FindName("CtxCreateDump")
    $ctxCopyCmdItem      = $window.FindName("CtxCopyCmdLine")
    $ctxCopyPathItem     = $window.FindName("CtxCopyPath")

    $updateProcessMenuState = {
        $selCount = if ($gridProcesses.SelectedItems) { $gridProcesses.SelectedItems.Count } elseif ($gridProcesses.SelectedItem) { 1 } else { 0 }
        $isMulti  = ($selCount -gt 1)
        $singleEnabled = (-not $isMulti)

        if ($menuPropsItem)      { $menuPropsItem.IsEnabled      = $singleEnabled }
        if ($menuCreateDumpItem) { $menuCreateDumpItem.IsEnabled = $singleEnabled }
        if ($ctxPropsItem)       { $ctxPropsItem.IsEnabled       = $singleEnabled }
        if ($ctxCreateDumpItem)  { $ctxCreateDumpItem.IsEnabled  = $singleEnabled }
        if ($ctxCopyCmdItem)     { $ctxCopyCmdItem.IsEnabled     = $singleEnabled }
        if ($ctxCopyPathItem)    { $ctxCopyPathItem.IsEnabled    = $singleEnabled }

        if ($isMulti) {
            if ($menuKillItem)     { $menuKillItem.Header     = "_Kill $selCount Processes" }
            if ($menuKillTreeItem) { $menuKillTreeItem.Header = "Kill $selCount Process _Trees" }
            if ($menuSuspendItem)  { $menuSuspendItem.Header  = "_Suspend $selCount Processes" }
            if ($menuResumeItem)   { $menuResumeItem.Header   = "R_esume $selCount Processes" }
            if ($ctxKillItem)      { $ctxKillItem.Header      = "Kill $selCount Processes" }
            if ($ctxKillTreeItem)  { $ctxKillTreeItem.Header  = "Kill $selCount Process Trees" }
            if ($ctxSuspendItem)   { $ctxSuspendItem.Header   = "Suspend $selCount Processes" }
            if ($ctxResumeItem)    { $ctxResumeItem.Header    = "Resume $selCount Processes" }
        } else {
            if ($menuKillItem)     { $menuKillItem.Header     = "_Kill Process" }
            if ($menuKillTreeItem) { $menuKillTreeItem.Header = "Kill Process _Tree" }
            if ($menuSuspendItem)  { $menuSuspendItem.Header  = "_Suspend Process" }
            if ($menuResumeItem)   { $menuResumeItem.Header   = "R_esume Process" }
            if ($ctxKillItem)      { $ctxKillItem.Header      = "Kill Process" }
            if ($ctxKillTreeItem)  { $ctxKillTreeItem.Header  = "Kill Process Tree" }
            if ($ctxSuspendItem)   { $ctxSuspendItem.Header   = "Suspend Process" }
            if ($ctxResumeItem)    { $ctxResumeItem.Header    = "Resume Process" }
        }
    }

    if ($gridProcesses.ContextMenu) { $gridProcesses.ContextMenu.add_Opened($updateProcessMenuState) }
    if ($menuProcessItem)           { $menuProcessItem.add_SubmenuOpened($updateProcessMenuState) }

    # Wire Service Toolbar & ContextMenu Actions
    $invokeServiceAction = {
        param([string]$svcOp, [Object]$targetSvc = $null, [scriptblock]$onComplete = $null)
        $selSvc = if ($targetSvc) { $targetSvc } else { $gridServices.SelectedItem }
        if (-not $selSvc) { return }
        $sName = [string]$selSvc.Name
        &$writeAuditLog "SERVICE" "Requesting '$svcOp' on service '$sName'..."

        $cmdPayload = @{
            CommandType  = "ProcessAction"
            Action       = "ControlService"
            TargetPid    = 0
            ExpectedName = $svcOp
            ServiceName  = $sName
            Priority     = ""
        }
        $localJss    = $jssAction
        $localLog    = $writeAuditLog
        $localState  = $stateContainer
        $localEngine = $engineHandle
        $localSvcOp  = $svcOp
        $localSName  = $sName
        $localCb     = $onComplete

        & $engineHandle.SendCommand $cmdPayload ({
            param($res)
            if ($localEngine -and $localEngine.RequestFullSync) {
                & $localEngine.RequestFullSync
            } else {
                $localState.ForceFullSync = $true
                [void]$localState.WakeEvent.Set()
            }
            if ($res.Success -and $res.PayloadJson) {
                $parsed = $localJss.DeserializeObject($res.PayloadJson)
                &$localLog "SERVICE" "$($parsed['Message']) ($($res.ElapsedMs)ms)"
            } else {
                &$localLog "ERROR" "Service action '$localSvcOp' on '$localSName' failed: $($res.Error)"
            }
            if ($localCb) {
                try { &$localCb $res } catch {}
            }
        }.GetNewClosure())
    }

    $btnSvcStart            = $window.FindName("BtnSvcStart")
    $btnSvcStop             = $window.FindName("BtnSvcStop")
    $btnSvcRestart          = $window.FindName("BtnSvcRestart")
    $btnSvcProperties       = $window.FindName("BtnSvcProperties")
    $btnSvcGoToProcess      = $window.FindName("BtnSvcGoToProcess")
    $txtSvcSummary          = $window.FindName("TxtSvcSummary")
    $txtSearchServices      = $window.FindName("TxtSearchServices")
    $btnClearSearchServices = $window.FindName("BtnClearSearchServices")

    $ctxStartService        = $window.FindName("CtxStartService")
    $ctxStopService         = $window.FindName("CtxStopService")
    $ctxRestartService      = $window.FindName("CtxRestartService")
    $ctxServiceProperties   = $window.FindName("CtxServiceProperties")
    $ctxGoToServiceProcess  = $window.FindName("CtxGoToServiceProcess")
    $ctxCopyServiceName    = $window.FindName("CtxCopyServiceName")

    $updateSvcToolbarButtons = {
        $sel = $gridServices.SelectedItem
        if ($sel) {
            $isRun = ($sel.Status -eq "Running")
            $isPaused = ($sel.Status -eq "Paused")
            $canStart = (-not $isRun)
            $canStop = ($isRun -or $isPaused)
            $canRestart = ($isRun -or $isPaused)
            $hasPid = ($sel.PID -gt 0)

            if ($btnSvcStart)       { $btnSvcStart.IsEnabled = $canStart }
            if ($btnSvcStop)        { $btnSvcStop.IsEnabled = $canStop }
            if ($btnSvcRestart)     { $btnSvcRestart.IsEnabled = $canRestart }
            if ($btnSvcProperties)  { $btnSvcProperties.IsEnabled = $true }
            if ($btnSvcGoToProcess) { $btnSvcGoToProcess.IsEnabled = $hasPid }

            if ($ctxStartService)       { $ctxStartService.IsEnabled = $canStart }
            if ($ctxStopService)        { $ctxStopService.IsEnabled = $canStop }
            if ($ctxRestartService)     { $ctxRestartService.IsEnabled = $canRestart }
            if ($ctxServiceProperties)  { $ctxServiceProperties.IsEnabled = $true }
            if ($ctxGoToServiceProcess) { $ctxGoToServiceProcess.IsEnabled = $hasPid }
            if ($ctxCopyServiceName)    { $ctxCopyServiceName.IsEnabled = $true }
        } else {
            if ($btnSvcStart)       { $btnSvcStart.IsEnabled = $false }
            if ($btnSvcStop)        { $btnSvcStop.IsEnabled = $false }
            if ($btnSvcRestart)     { $btnSvcRestart.IsEnabled = $false }
            if ($btnSvcProperties)  { $btnSvcProperties.IsEnabled = $false }
            if ($btnSvcGoToProcess) { $btnSvcGoToProcess.IsEnabled = $false }

            if ($ctxStartService)       { $ctxStartService.IsEnabled = $false }
            if ($ctxStopService)        { $ctxStopService.IsEnabled = $false }
            if ($ctxRestartService)     { $ctxRestartService.IsEnabled = $false }
            if ($ctxServiceProperties)  { $ctxServiceProperties.IsEnabled = $false }
            if ($ctxGoToServiceProcess) { $ctxGoToServiceProcess.IsEnabled = $false }
            if ($ctxCopyServiceName)    { $ctxCopyServiceName.IsEnabled = $false }
        }
    }
    $gridServices.add_SelectionChanged({ &$updateSvcToolbarButtons })
    &$updateSvcToolbarButtons

    $actionGoToServiceProcess = {
        $selSvc = $gridServices.SelectedItem
        if ($selSvc -and $selSvc.PID -gt 0 -and $engineHandle.ProcessMap.ContainsKey($selSvc.PID)) {
            $targetVm = $engineHandle.ProcessMap[$selSvc.PID]
            $mainTabs = $window.FindName("MainTabControl")
            if ($mainTabs) { $mainTabs.SelectedIndex = 0 }
            $currPid = $targetVm.ParentPID
            $guard = 0
            while ($currPid -gt 0 -and $engineHandle.ProcessMap.ContainsKey($currPid) -and $guard -lt 30) {
                $parentVm = $engineHandle.ProcessMap[$currPid]
                $parentVm.IsExpanded = $true
                $parentVm.UpdateExpanderGeometry()
                $currPid = $parentVm.ParentPID
                $guard++
            }
            if ($engineHandle.RefreshTree) { & $engineHandle.RefreshTree }
            $gridProcesses.SelectedItem = $targetVm
            $gridProcesses.ScrollIntoView($targetVm)
        }
    }

    $actionShowServiceProperties = {
        $selSvc = $gridServices.SelectedItem
        if (-not $selSvc) { return }

        $sBytes = [System.IO.File]::ReadAllBytes($svcDetailXamlPath)
        $msSvc = [System.IO.MemoryStream]::new($sBytes)
        $svcWin = [System.Windows.Markup.XamlReader]::Load($msSvc)
        $msSvc.Close()
        $svcWin.Owner = $window
        if ($appIconFrame) { $svcWin.Icon = $appIconFrame }

        foreach ($key in @("BrushWindowBg","BrushToolbarBg","BrushSurfaceBg","BrushHeaderBg","BrushBorderSubtle","BrushTextPrimary","BrushTextSecondary","BrushTextMuted","BrushRowHover","BrushRowSelectedBg","BrushRowSelectedFg","BrushMenuBg","BrushMenuBorder","BrushMenuHover")) {
            if ($window.Resources.Contains($key)) {
                $svcWin.Resources[$key] = $window.Resources[$key]
            }
        }

        $svcWin.Title = "$($selSvc.DisplayName) ($($selSvc.Name)) Details & Dependencies [$($stateContainer.TargetDisplayName)]"

        $svcWin.FindName("TxtDlgDisplayName").Text = $selSvc.DisplayName
        $svcWin.FindName("TxtDlgServiceName").Text = $selSvc.Name
        $svcWin.FindName("TxtDlgPid").Text = if ($selSvc.PID -gt 0) { [string]$selSvc.PID } else { "None" }

        $badgeStatus = $svcWin.FindName("BadgeDlgStatus")
        $txtStatus   = $svcWin.FindName("TxtDlgStatus")
        $txtStatus.Text = $selSvc.Status.ToUpper()
        $bc = [System.Windows.Media.BrushConverter]::new()
        if ($selSvc.Status -eq "Running") {
            $badgeStatus.Background = $bc.ConvertFromString("#16A34A")
        } elseif ($selSvc.Status -eq "Paused") {
            $badgeStatus.Background = $bc.ConvertFromString("#D97706")
        } else {
            $badgeStatus.Background = $bc.ConvertFromString("#64748B")
        }

        $txtDesc = $svcWin.FindName("TxtDlgDescription")
        if ($txtDesc) {
            $txtDesc.Text = if ($selSvc.Description) { $selSvc.Description } else { "No description available for this service." }
        }
        $txtPath = $svcWin.FindName("TxtDlgPath")
        if ($txtPath) {
            $txtPath.Text = if ($selSvc.BinaryPath) { $selSvc.BinaryPath } else { "N/A" }
        }
        $txtStartup = $svcWin.FindName("TxtDlgStartup")
        if ($txtStartup) {
            $txtStartup.Text = $selSvc.StartType
        }
        $txtAccount = $svcWin.FindName("TxtDlgAccount")
        if ($txtAccount) {
            $txtAccount.Text = $selSvc.User
        }
        $txtDepSummary = $svcWin.FindName("TxtDlgDepSummary")
        if ($txtDepSummary) {
            $txtDepSummary.Text = if ($selSvc.DependenciesFormatted) { $selSvc.DependenciesFormatted } else { "None" }
        }

        # Prerequisites List
        $gridPrereqs = $svcWin.FindName("GridDlgPrereqs")
        $prereqList = [System.Collections.Generic.List[Object]]::new()
        if ($selSvc.Dependencies) {
            $rawDeps = $selSvc.Dependencies -split "[,;/]"
            foreach ($rawD in $rawDeps) {
                $dTrim = $rawD.Trim()
                if (-not $dTrim) { continue }
                $cleanD = $dTrim.TrimStart('+')
                $pDisp = $cleanD
                $pStat = "Unknown"
                if ($engineHandle.ServicesMap.ContainsKey($cleanD)) {
                    $matchVm = $engineHandle.ServicesMap[$cleanD]
                    $pDisp = $matchVm.DisplayName
                    $pStat = $matchVm.Status
                } elseif ($cleanD -match "^(Tcpip|RpcSs|HTTP|Afd|NetBT|DxgKrnl|MountMgr|AFD|BFE)$") {
                    $pStat = "Running (Kernel/Core)"
                }
                $prereqList.Add([PSCustomObject]@{
                    Name        = $cleanD
                    DisplayName = $pDisp
                    Status      = $pStat
                })
            }
        }
        if ($gridPrereqs) {
            $gridPrereqs.ItemsSource = $prereqList
        }

        # Dependents List
        $gridDependents = $svcWin.FindName("GridDlgDependents")
        $dependentList = [System.Collections.Generic.List[Object]]::new()
        if ($selSvc.DependentServices) {
            $rawRev = $selSvc.DependentServices -split "[,;/]"
            foreach ($rawR in $rawRev) {
                $rTrim = $rawR.Trim()
                if (-not $rTrim) { continue }
                $rDisp = $rTrim
                $rStat = "Unknown"
                if ($engineHandle.ServicesMap.ContainsKey($rTrim)) {
                    $matchVm = $engineHandle.ServicesMap[$rTrim]
                    $rDisp = $matchVm.DisplayName
                    $rStat = $matchVm.Status
                }
                $dependentList.Add([PSCustomObject]@{
                    Name        = $rTrim
                    DisplayName = $rDisp
                    Status      = $rStat
                })
            }
        }
        if ($gridDependents) {
            $gridDependents.ItemsSource = $dependentList
        }

        # Wire Dialog Action Buttons
        $btnDlgStart   = $svcWin.FindName("BtnDlgStart")
        $btnDlgStop    = $svcWin.FindName("BtnDlgStop")
        $btnDlgRestart = $svcWin.FindName("BtnDlgRestart")
        $btnDlgClose   = $svcWin.FindName("BtnDlgClose")
        $txtDlgPid     = $svcWin.FindName("TxtDlgPid")
        $localSvcWin   = $svcWin
        $localInvoke   = $invokeServiceAction
        $targetSvc     = $selSvc

        $updateSvcDialogUi = {
            param([string]$statusOverride = "", [int]$pidOverride = -1)
            $liveSvc = if ($engineHandle.ServicesMap.ContainsKey($targetSvc.Name)) {
                $engineHandle.ServicesMap[$targetSvc.Name]
            } else {
                $targetSvc
            }

            $curStatus = if ($statusOverride) { $statusOverride } else { [string]$liveSvc.Status }
            $curPid    = if ($pidOverride -ge 0) { $pidOverride } else { [int]$liveSvc.PID }

            if ($txtStatus) {
                $txtStatus.Text = $curStatus.ToUpper()
            }
            if ($badgeStatus) {
                if ($curStatus -eq "Running") {
                    $badgeStatus.Background = $bc.ConvertFromString("#16A34A")
                } elseif ($curStatus -eq "Paused") {
                    $badgeStatus.Background = $bc.ConvertFromString("#D97706")
                } elseif ($curStatus.EndsWith("...")) {
                    $badgeStatus.Background = $bc.ConvertFromString("#EAB308")
                } else {
                    $badgeStatus.Background = $bc.ConvertFromString("#64748B")
                }
            }
            if ($txtDlgPid) {
                $txtDlgPid.Text = if ($curPid -gt 0) { [string]$curPid } else { "None" }
            }

            $isTransitioning = $curStatus.EndsWith("...")
            if ($btnDlgStart) {
                $btnDlgStart.IsEnabled = (-not $isTransitioning -and $curStatus -ne "Running")
            }
            if ($btnDlgStop) {
                $btnDlgStop.IsEnabled = (-not $isTransitioning -and ($curStatus -eq "Running" -or $curStatus -eq "Paused"))
            }
            if ($btnDlgRestart) {
                $btnDlgRestart.IsEnabled = (-not $isTransitioning -and ($curStatus -eq "Running" -or $curStatus -eq "Paused"))
            }
        }

        $executeDlgAction = {
            param([string]$op)
            $inFlightText = switch ($op) {
                "Start"   { "Starting..." }
                "Stop"    { "Stopping..." }
                "Restart" { "Restarting..." }
                default   { "$op..." }
            }
            &$updateSvcDialogUi $inFlightText

            &$localInvoke $op $targetSvc ({
                param($res)
                if ($engineHandle.ServicesMap.ContainsKey($targetSvc.Name)) {
                    $live = $engineHandle.ServicesMap[$targetSvc.Name]
                    &$updateSvcDialogUi $live.Status $live.PID
                } else {
                    $exp = if ($op -eq "Start") { "Running" } elseif ($op -eq "Stop") { "Stopped" } else { "Running" }
                    &$updateSvcDialogUi $exp
                }
            })
        }

        if ($btnDlgStart) {
            $btnDlgStart.add_Click({
                &$executeDlgAction "Start"
            })
        }
        if ($btnDlgStop) {
            $btnDlgStop.add_Click({
                &$executeDlgAction "Stop"
            })
        }
        if ($btnDlgRestart) {
            $btnDlgRestart.add_Click({
                &$executeDlgAction "Restart"
            })
        }
        if ($btnDlgClose) {
            $btnDlgClose.add_Click({
                $localSvcWin.Close()
            })
        }

        # Initialize UI button states and status
        &$updateSvcDialogUi

        # Lightweight background poll so live telemetry updates status and PID automatically
        $svcTimer = [System.Windows.Threading.DispatcherTimer]::new(
            [System.Windows.Threading.DispatcherPriority]::Background,
            $svcWin.Dispatcher
        )
        $svcTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
        $svcTimer.add_Tick({
            if ($engineHandle.ServicesMap.ContainsKey($targetSvc.Name)) {
                $live = $engineHandle.ServicesMap[$targetSvc.Name]
                if ($txtStatus -and -not $txtStatus.Text.EndsWith("...")) {
                    &$updateSvcDialogUi $live.Status $live.PID
                }
            }
        })
        $svcTimer.Start()

        $svcWin.add_Closed({
            if ($svcTimer) { $svcTimer.Stop() }
        })

        [void]$svcWin.ShowDialog()
    }

    if ($btnSvcStart)          { $btnSvcStart.add_Click({ &$invokeServiceAction "Start" }) }
    if ($btnSvcStop)           { $btnSvcStop.add_Click({ &$invokeServiceAction "Stop" }) }
    if ($btnSvcRestart)        { $btnSvcRestart.add_Click({ &$invokeServiceAction "Restart" }) }
    if ($btnSvcProperties)     { $btnSvcProperties.add_Click({ &$actionShowServiceProperties }) }
    if ($btnSvcGoToProcess)    { $btnSvcGoToProcess.add_Click($actionGoToServiceProcess) }

    if ($ctxStartService)      { $ctxStartService.add_Click({ &$invokeServiceAction "Start" }) }
    if ($ctxStopService)       { $ctxStopService.add_Click({ &$invokeServiceAction "Stop" }) }
    if ($ctxRestartService)    { $ctxRestartService.add_Click({ &$invokeServiceAction "Restart" }) }
    if ($ctxServiceProperties) { $ctxServiceProperties.add_Click({ &$actionShowServiceProperties }) }
    if ($ctxGoToServiceProcess) { $ctxGoToServiceProcess.add_Click($actionGoToServiceProcess) }
    if ($ctxCopyServiceName) {
        $ctxCopyServiceName.add_Click({
            $sel = $gridServices.SelectedItem
            if ($sel -and $sel.Name) {
                [System.Windows.Clipboard]::SetText($sel.Name)
                &$writeAuditLog "CLIPBOARD" "Copied service name '$($sel.Name)'."
            }
        })
    }

    $gridServices.add_MouseDoubleClick({
        param($sender, $e)
        if ($gridServices.SelectedItem) {
            &$actionShowServiceProperties
        }
    })
    $gridServices.add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $gridServices.SelectedItem) {
            &$actionShowServiceProperties
            $e.Handled = $true
        }
    })

    $updateSvcSummaryText = {
        if (-not $txtSvcSummary -or $null -eq $servicesCollection) { return }
        $totCount = $servicesCollection.Count
        if ($totCount -eq 0) {
            $txtSvcSummary.Text = "0 Services"
            return
        }
        $runCount = 0
        foreach ($svm in $servicesCollection) {
            if ($svm.Status -eq "Running") { $runCount++ }
        }
        $stopCount = $totCount - $runCount
        $sTerm = if ($txtSearchServices) { $txtSearchServices.Text.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($sTerm)) {
            $txtSvcSummary.Text = "$totCount Services ($runCount Running, $stopCount Stopped)"
        } else {
            $cv = [System.Windows.Data.CollectionViewSource]::GetDefaultView($servicesCollection)
            $visCount = 0
            if ($cv) { foreach ($ci in $cv) { $visCount++ } }
            $txtSvcSummary.Text = "$visCount of $totCount Services ($runCount Running, $stopCount Stopped)"
        }
    }

    $updateServicesFilter = {
        if ($null -eq $servicesCollection) { return }
        $filterText = if ($txtSearchServices) { $txtSearchServices.Text.Trim() } else { "" }
        $svcView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($servicesCollection)
        if (-not $svcView) { return }

        if ([string]::IsNullOrWhiteSpace($filterText)) {
            $svcView.Filter = $null
        } else {
            $fLower = $filterText.ToLowerInvariant()
            $svcView.Filter = [Predicate[Object]]({
                param($item)
                if (-not $item) { return $false }
                $n = [string]$item.Name
                $d = [string]$item.DisplayName
                $p = [string]$item.PIDFormatted
                $s = [string]$item.Status
                $t = [string]$item.StartType
                $u = [string]$item.User
                $dp = [string]$item.Dependencies
                return ($n.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $d.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $p.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $s.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $t.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $u.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $dp.IndexOf($fLower, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            }.GetNewClosure())
        }
        &$updateSvcSummaryText
    }

    if ($txtSearchServices) {
        $txtSearchServices.add_TextChanged({ &$updateServicesFilter })
    }
    if ($btnClearSearchServices) {
        $btnClearSearchServices.add_Click({
            if ($txtSearchServices) { $txtSearchServices.Text = "" }
            &$updateServicesFilter
        })
    }

    # 13. Deep Process Properties Inspector Modal (6-Tab Sysinternals Process Explorer Layout)
    $actionShowProperties = {
        if ($gridProcesses.SelectedItems -and $gridProcesses.SelectedItems.Count -gt 1) { return }
        $selectedVm = $gridProcesses.SelectedItem
        if (-not $selectedVm) { return }

        $pBytes = [System.IO.File]::ReadAllBytes($propXamlPath)
        $msProp = [System.IO.MemoryStream]::new($pBytes)
        $propWin = [System.Windows.Markup.XamlReader]::Load($msProp)
        $msProp.Close()
        $propWin.Owner = $window
        if ($appIconFrame) { $propWin.Icon = $appIconFrame }

        # Propagate active theme resources from main window
        foreach ($key in @("BrushWindowBg","BrushToolbarBg","BrushSurfaceBg","BrushHeaderBg","BrushBorderSubtle","BrushTreeLine","BrushTextPrimary","BrushTextSecondary","BrushTextMuted","BrushRowHover","BrushRowSelectedBg","BrushRowSelectedFg","BrushSparkBg","BrushSparkBorder","ColTint_CPU","ColTint_PrivateBytes","ColTint_WorkingSet","BrushMenuBg","BrushMenuBorder","BrushMenuHover")) {
            if ($window.Resources.Contains($key)) {
                $propWin.Resources[$key] = $window.Resources[$key]
            }
        }
        $script:ActivePropWin = $propWin
        $propWin.add_Closed({ $script:ActivePropWin = $null })

        $targetPid = [int]$selectedVm.PID
        $propWin.Title = "$($selectedVm.Name):$targetPid Properties [$($stateContainer.TargetDisplayName)]"

        # Populate Immediate Static Metadata from Host ViewModel
        $propWin.FindName("PropHeaderName").Text  = $selectedVm.Name
        $propWin.FindName("PropHeaderPid").Text   = "PID: $($selectedVm.PIDDisplay)"
        $propWin.FindName("PropDescription").Text = if ($selectedVm.Description) { $selectedVm.Description } else { $selectedVm.Name }
        $propWin.FindName("PropCompany").Text     = if ($selectedVm.CompanyName) { $selectedVm.CompanyName } else { "N/A" }
        $propWin.FindName("PropPath").Text        = $selectedVm.Path
        $propWin.FindName("PropCmdLine").Text     = $selectedVm.CommandLine
        $propWin.FindName("PropUser").Text        = $selectedVm.User
        $propWin.FindName("PropStartTime").Text   = $selectedVm.StartTime
        $propWin.FindName("PropArch").Text        = $selectedVm.Architecture
        if ($selectedVm.IconSource) {
            $propWin.FindName("PropIcon").Source = $selectedVm.IconSource
        }

        if ($selectedVm.ParentPID -gt 0 -and $engineHandle.ProcessMap.ContainsKey($selectedVm.ParentPID)) {
            $parentVm = $engineHandle.ProcessMap[$selectedVm.ParentPID]
            $propWin.FindName("PropParentPid").Text = "$($parentVm.Name) ($($parentVm.PID))"
        } elseif ($selectedVm.ParentPID -gt 0) {
            $propWin.FindName("PropParentPid").Text = "Non-existent process ($($selectedVm.ParentPID))"
        } else {
            $propWin.FindName("PropParentPid").Text = "System Root"
        }

        $btnSuspendResume = $propWin.FindName("BtnSuspendResume")
        $btnSuspendResume.Content = if ($selectedVm.Status -eq "Suspended") { "Resume" } else { "Suspend" }

        # Build Expanded Ancestry & Descendant Tree Focused on Selected Process
        $expansionState = @{}
        $buildDescendantTree = {
            param([Object]$vmNode, [bool]$isTarget, [int]$depth)
            $childNodes = [System.Collections.Generic.List[Object]]::new()
            if ($depth -lt 12 -and $vmNode.Children) {
                foreach ($ch in $vmNode.Children) {
                    $childNodes.Add((&$buildDescendantTree $ch $false ($depth + 1)))
                }
            }
            $isExp = if ($expansionState.ContainsKey($vmNode.PID)) { $expansionState[$vmNode.PID] } else { $true }
            return [PSCustomObject]@{
                Name                  = $vmNode.Name
                PID                   = $vmNode.PID
                CPUFormatted          = if ($vmNode.CPUFormatted) { $vmNode.CPUFormatted } else { "0.00" }
                PrivateBytesFormatted = $vmNode.PrivateBytesFormatted
                MemoryFormatted       = $vmNode.MemoryFormatted
                IsNodeExpanded        = $isExp
                IsTargetNode          = $isTarget
                TargetBadgeVisibility = if ($isTarget) { "Visible" } else { "Collapsed" }
                NodeFontWeight        = if ($isTarget) { "Bold" } else { "SemiBold" }
                NodeBackground        = if ($isTarget) { "#E0F2FE" } else { "Transparent" }
                NodeBorderBrush       = if ($isTarget) { "#0284C7" } else { "Transparent" }
                Children              = $childNodes
            }
        }

        $buildFullAncestryTree = {
            if (-not $engineHandle.ProcessMap.ContainsKey($targetPid)) { return $null }
            $liveTarget = $engineHandle.ProcessMap[$targetPid]

            # Capture existing node expansion states before rebuild
            $captureExp = {
                param($node)
                if ($node -and $node.PID) { $expansionState[$node.PID] = [bool]$node.IsNodeExpanded }
                if ($node -and $node.Children) {
                    foreach ($c in $node.Children) { &$captureExp $c }
                }
            }
            if ($propTree -and $propTree.ItemsSource) {
                foreach ($root in $propTree.ItemsSource) { &$captureExp $root }
            }

            $currentTreeNode = &$buildDescendantTree $liveTarget $true 0
            $cursorVm = $liveTarget
            $guard = 0
            $visitedAncestors = [System.Collections.Generic.HashSet[int]]::new()
            [void]$visitedAncestors.Add($liveTarget.PID)

            while ($cursorVm.ParentPID -gt 0 -and $engineHandle.ProcessMap.ContainsKey($cursorVm.ParentPID) -and -not $visitedAncestors.Contains($cursorVm.ParentPID) -and $guard -lt 15) {
                $parentVm = $engineHandle.ProcessMap[$cursorVm.ParentPID]
                [void]$visitedAncestors.Add($parentVm.PID)
                $parentChildren = [System.Collections.Generic.List[Object]]::new()
                $parentChildren.Add($currentTreeNode)

                $isParentExp = if ($expansionState.ContainsKey($parentVm.PID)) { $expansionState[$parentVm.PID] } else { $true }
                $currentTreeNode = [PSCustomObject]@{
                    Name                  = $parentVm.Name
                    PID                   = $parentVm.PID
                    CPUFormatted          = if ($parentVm.CPUFormatted) { $parentVm.CPUFormatted } else { "0.00" }
                    PrivateBytesFormatted = $parentVm.PrivateBytesFormatted
                    MemoryFormatted       = $parentVm.MemoryFormatted
                    IsNodeExpanded        = $isParentExp
                    IsTargetNode          = $false
                    TargetBadgeVisibility = "Collapsed"
                    NodeFontWeight        = "SemiBold"
                    NodeBackground        = "Transparent"
                    NodeBorderBrush       = "Transparent"
                    Children              = $parentChildren
                }
                $cursorVm = $parentVm
                $guard++
            }
            return $currentTreeNode
        }

        $propTree = $propWin.FindName("PropProcessTree")
        $initialTreeNode = &$buildFullAncestryTree
        if ($initialTreeNode) {
            $propTree.ItemsSource = @($initialTreeNode)
        }

        $treeHeaderSpacer = $propWin.FindName("TreeHeaderScrollSpacer")
        $syncTreeHeaderSpacer = {
            if (-not $treeHeaderSpacer -or -not $propTree) { return }
            $sv = $propTree.Template.FindName("_tv_scrollviewer_", $propTree)
            if ($sv -and $sv.ComputedVerticalScrollBarVisibility -eq [System.Windows.Visibility]::Visible) {
                $treeHeaderSpacer.Visibility = [System.Windows.Visibility]::Visible
                $treeHeaderSpacer.Width = [System.Windows.SystemParameters]::VerticalScrollBarWidth
            } else {
                $treeHeaderSpacer.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
        if ($propTree) {
            $propTree.add_SizeChanged({ &$syncTreeHeaderSpacer })
        }

        $propTabControl = $propWin.FindName("PropTabControl")

        # Lazy Tab Load State (Zero overhead for DLLs/Handles unless tab is selected)
        $tabLoadState = @{
            ModulesLoaded = $false
            HandlesLoaded = $false
        }
        $perfQueryState = @{ InFlight = $false }

        # Async Deep Inspector Query Helper
        $runDeepInspect = {
            param([bool]$verifyAuthenticode, [string]$inspectMode = "Core")
            if ($verifyAuthenticode) {
                $propWin.FindName("PropSignature").Text = "Verifying Authenticode signature on target..."
            }
            if ($inspectMode -eq "Modules") {
                $loadingMod = [PSCustomObject]@{
                    Name        = "Loading DLLs..."
                    Description = "Enumerating loaded modules for PID $targetPid..."
                    CompanyName = ""
                    Version     = ""
                    Size        = ""
                    BaseAddress = ""
                    Path        = ""
                }
                $propWin.FindName("GridPropDlls").ItemsSource = @($loadingMod)
            } elseif ($inspectMode -eq "Handles") {
                $loadingHnd = [PSCustomObject]@{
                    Type   = "Loading..."
                    Name   = "Querying open kernel handles for PID $targetPid..."
                    Handle = ""
                    Access = ""
                }
                $propWin.FindName("GridPropHandles").ItemsSource = @($loadingHnd)
            }

            $cmd = @{
                CommandType     = "InspectPid"
                TargetPid       = $targetPid
                VerifySignature = $verifyAuthenticode
                InspectMode     = $inspectMode
            }
            $localPropWin        = $propWin
            $localSelectedVm     = $selectedVm
            $localJss            = $jssAction
            $localInspectMode    = $inspectMode
            $localLog            = $writeAuditLog
            $localTargetPid      = $targetPid
            $localProcessMap     = $engineHandle.ProcessMap
            $localPerfQueryState = $perfQueryState

            & $engineHandle.SendCommand $cmd ({
                param($res)
                if (-not $localPropWin.IsVisible) {
                    if ($localPerfQueryState) { $localPerfQueryState.InFlight = $false }
                    return
                }
                if (-not $res.Success -or -not $res.PayloadJson) {
                    if ($localPerfQueryState) { $localPerfQueryState.InFlight = $false }
                    if ($localInspectMode -eq "Modules") {
                        $localPropWin.FindName("GridPropDlls").ItemsSource = @([PSCustomObject]@{
                            Name = "[Error]"; Description = "Error: $($res.Error)"; CompanyName = ""; Version = ""; Size = ""; BaseAddress = ""; Path = ""
                        })
                    } elseif ($localInspectMode -eq "Handles") {
                        $localPropWin.FindName("GridPropHandles").ItemsSource = @([PSCustomObject]@{
                            Type = "[Error]"; Name = "Error: $($res.Error)"; Handle = ""; Access = ""
                        })
                    } elseif ($localInspectMode -ne "Performance") {
                        $localPropWin.FindName("PropWorkDir").Text = "Error: $($res.Error)"
                        &$localLog "ERROR" "InspectPid ($localInspectMode) on PID $($localSelectedVm.PID) failed: $($res.Error)"
                    }
                    return
                }
                try {
                    $d = $localJss.DeserializeObject($res.PayloadJson)
                    $mode = if ($d['InspectMode']) { [string]$d['InspectMode'] } else { $localInspectMode }
                    $inspKB = [Math]::Round($res.PayloadJson.Length / 1024.0, 2)

                    if ($mode -eq "Core" -or $mode -eq "All") {
                        $imgDet = $d['ImageDetails']
                        if ($imgDet) {
                            $localPropWin.FindName("PropVersion").Text   = [string]$imgDet['FileVersion']
                            $localPropWin.FindName("PropBuildTime").Text = [string]$imgDet['BuildTime']
                        }
                        $localPropWin.FindName("PropWorkDir").Text   = [string]$d['CurrentDirectory']
                        $localPropWin.FindName("PropAutostart").Text = [string]$d['Autostart']

                        $sig = $d['Signature']
                        if ($sig -and $sig['Status'] -ne "NotVerified") {
                            $sigTxt = if ($sig['Signer'] -and $sig['Signer'] -ne "N/A") {
                                "$($sig['Status']) - $($sig['Signer'])"
                            } else {
                                "$($sig['Status'])"
                            }
                            $sigBlock = $localPropWin.FindName("PropSignature")
                            $sigBlock.Text = $sigTxt
                            $sigBlock.Foreground = if ($sig['Status'] -eq "Valid") { "#16A34A" } else { "#DC2626" }
                        }

                        # Convert dictionary arrays to PSCustomObjects for closure-safe DataGrid binding & sorting
                        $connList = [System.Collections.Generic.List[Object]]::new()
                        if ($d['Connections']) {
                            foreach ($cItem in $d['Connections']) {
                                $connList.Add([PSCustomObject]@{
                                    Protocol       = [string]$cItem['Protocol']
                                    LocalEndpoint  = [string]$cItem['LocalEndpoint']
                                    RemoteEndpoint = [string]$cItem['RemoteEndpoint']
                                    State          = [string]$cItem['State']
                                })
                            }
                        }
                        $localPropWin.FindName("GridNetConnections").ItemsSource = $connList

                        $svcList = [System.Collections.Generic.List[Object]]::new()
                        if ($d['Services']) {
                            foreach ($sItem in $d['Services']) {
                                $svcList.Add([PSCustomObject]@{
                                    Name        = [string]$sItem['Name']
                                    DisplayName = [string]$sItem['DisplayName']
                                    Status      = [string]$sItem['Status']
                                    StartType   = [string]$sItem['StartType']
                                    User        = [string]$sItem['User']
                                })
                            }
                        }
                        $localPropWin.FindName("GridPropServices").ItemsSource = $svcList

                        $envList = [System.Collections.Generic.List[Object]]::new()
                        if ($d['Environment']) {
                            foreach ($eItem in $d['Environment']) {
                                $envList.Add([PSCustomObject]@{
                                    Key   = [string]$eItem['Key']
                                    Value = [string]$eItem['Value']
                                })
                            }
                        }
                        $localPropWin.FindName("GridPropEnv").ItemsSource = $envList

                        &$localLog "INSPECT" "PID $($localSelectedVm.PID) ($($localSelectedVm.Name)) [Mode: Core] | RTT: $($res.ElapsedMs)ms | Payload: ${inspKB} KB (Sockets: $($connList.Count), Services: $($svcList.Count), Env: $($envList.Count))"
                    }

                    # Performance Counters (updated by Performance, Core, or All)
                    if ($mode -eq "Performance" -or $mode -eq "Core" -or $mode -eq "All") {
                        $perf = $d['Performance']
                        if ($perf) {
                            $curVm = if ($localProcessMap -and $localProcessMap.ContainsKey($localTargetPid)) { $localProcessMap[$localTargetPid] } else { $localSelectedVm }
                            $cpuTxt = if (-not $curVm.CPUFormatted) { "0.00%" } elseif ($curVm.CPUFormatted -eq "Suspended") { "Suspended" } else { "$($curVm.CPUFormatted)%" }
                            $localPropWin.FindName("PropCpu").Text                = "CPU Usage: $cpuTxt (Base Priority: $($curVm.BasePriority))"
                            $localPropWin.FindName("PropTotalCpuTime").Text       = "Total Processor Time: $($perf['TotalCpuTime'])"
                            $localPropWin.FindName("PropKernelUserTime").Text     = "Kernel: $($perf['KernelTime']) | User: $($perf['UserTime'])"
                            $localPropWin.FindName("PropCycles").Text             = "CPU Cycles: $($perf['Cycles'])"
                            $localPropWin.FindName("PropThreadsHandles").Text     = "Handles: $($curVm.HandlesFormatted) (GDI: $($perf['GdiHandles']), USER: $($perf['UserHandles']))"
                            $localPropWin.FindName("PropPrivateBytes").Text       = "Private Bytes: $($curVm.PrivateBytesFormatted)"
                            $localPropWin.FindName("PropRam").Text                = "Working Set: $($curVm.MemoryFormatted) (Peak: $($perf['PeakWorkingSet']))"
                            $localPropWin.FindName("PropVirtualPageFaults").Text  = "Virtual Size: $($perf['VirtualSize']) | Page Faults: $($perf['PageFaults'])"
                            $localPropWin.FindName("PropPools").Text              = "Paged Pool: $($perf['PagedPool']) | Non-Paged Pool: $($perf['NonPagedPool'])"
                            $localPropWin.FindName("PropIoCounters").Text         = "I/O Reads: $($perf['IoReadBytes']) ($($perf['IoReadOps']) ops) | Writes: $($perf['IoWriteBytes']) ($($perf['IoWriteOps']) ops)"
                        }
                    }

                    if ($mode -eq "Modules" -or $mode -eq "All") {
                        $modList = [System.Collections.Generic.List[Object]]::new()
                        if ($d['Modules']) {
                            foreach ($mItem in $d['Modules']) {
                                $modList.Add([PSCustomObject]@{
                                    Name        = [string]$mItem['Name']
                                    Description = [string]$mItem['Description']
                                    CompanyName = [string]$mItem['CompanyName']
                                    Version     = [string]$mItem['Version']
                                    Size        = [string]$mItem['Size']
                                    BaseAddress = [string]$mItem['BaseAddress']
                                    Path        = [string]$mItem['Path']
                                })
                            }
                        }
                        $localPropWin.FindName("GridPropDlls").ItemsSource = $modList
                        &$localLog "INSPECT" "PID $($localSelectedVm.PID) ($($localSelectedVm.Name)) [Mode: DLLs] | RTT: $($res.ElapsedMs)ms | Payload: ${inspKB} KB (Loaded Modules: $($modList.Count))"
                    }

                    if ($mode -eq "Handles" -or $mode -eq "All") {
                        $hndList = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
                        if ($d['Handles']) {
                            foreach ($hItem in $d['Handles']) {
                                $hndList.Add([PSCustomObject]@{
                                    Type   = [string]$hItem['Type']
                                    Name   = [string]$hItem['Name']
                                    Handle = [string]$hItem['Handle']
                                    Access = [string]$hItem['Access']
                                })
                            }
                        }
                        $localPropWin.FindName("GridPropHandles").ItemsSource = $hndList
                        &$localLog "INSPECT" "PID $($localSelectedVm.PID) ($($localSelectedVm.Name)) [Mode: Handles] | RTT: $($res.ElapsedMs)ms | Payload: ${inspKB} KB (Named Kernel Handles: $($hndList.Count))"
                    }
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($localInspectMode -eq "Modules") {
                        $localPropWin.FindName("GridPropDlls").ItemsSource = @([PSCustomObject]@{
                            Name = "[UI Error]"; Description = $errMsg; CompanyName = ""; Version = ""; Size = ""; BaseAddress = ""; Path = ""
                        })
                    } elseif ($localInspectMode -eq "Handles") {
                        $localPropWin.FindName("GridPropHandles").ItemsSource = @([PSCustomObject]@{
                            Type = "[UI Error]"; Name = $errMsg; Handle = ""; Access = ""
                        })
                    } else {
                        &$localLog "ERROR" "InspectPid ($localInspectMode) UI error: $errMsg"
                    }
                } finally {
                    if ($localPerfQueryState) { $localPerfQueryState.InFlight = $false }
                }
            }.GetNewClosure())
        }

        # Lightweight Realtime Performance Refresher (Zero Extra Wire Overhead)
        $refreshLivePerformanceTab = {
            if (-not $propWin.IsVisible) { return }
            $selTab = $propTabControl.SelectedItem
            if (-not $selTab -or [string]$selTab.Header -ne "Performance") { return }

            if (-not $engineHandle.ProcessMap.ContainsKey($targetPid)) {
                $txtCpu = $propWin.FindName("PropCpu")
                if ($txtCpu) {
                    $txtCpu.Text = "CPU Usage: Process Exited (PID $targetPid)"
                    $txtCpu.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#DC2626")
                }
                return
            }

            $liveTargetVm = $engineHandle.ProcessMap[$targetPid]

            # 1. Update CPU Counter (fix 0.00% idle and Suspended formatting)
            $txtCpu = $propWin.FindName("PropCpu")
            if ($txtCpu) {
                $cpuDisplay = if (-not $liveTargetVm.CPUFormatted) { "0.00%" } elseif ($liveTargetVm.CPUFormatted -eq "Suspended") { "Suspended" } else { "$($liveTargetVm.CPUFormatted)%" }
                $txtCpu.Text = "CPU Usage: $cpuDisplay (Base Priority: $($liveTargetVm.BasePriority))"
                $txtCpu.Foreground = if ($liveTargetVm.CPU -gt 0) {
                    [System.Windows.Media.BrushConverter]::new().ConvertFromString("#16A34A")
                } else {
                    [System.Windows.Media.BrushConverter]::new().ConvertFromString("#475569")
                }
            }

            # 2. Update Memory Counters (Working Set & Private Bytes)
            $txtPriv = $propWin.FindName("PropPrivateBytes")
            if ($txtPriv) { $txtPriv.Text = "Private Bytes: $($liveTargetVm.PrivateBytesFormatted)" }

            $txtRam = $propWin.FindName("PropRam")
            if ($txtRam) {
                $peakMatch = [regex]::Match($txtRam.Text, "\(Peak: [^)]+\)")
                $peakSuffix = if ($peakMatch.Success) { " " + $peakMatch.Value } else { "" }
                $txtRam.Text = "Working Set: $($liveTargetVm.MemoryFormatted)$peakSuffix"
            }

            # 3. Update Handles Counter
            $txtHnd = $propWin.FindName("PropThreadsHandles")
            if ($txtHnd) {
                $gdiMatch = [regex]::Match($txtHnd.Text, "\(GDI: [^)]+\)")
                $gdiSuffix = if ($gdiMatch.Success) { " " + $gdiMatch.Value } else { "" }
                $txtHnd.Text = "Handles: $($liveTargetVm.HandlesFormatted)$gdiSuffix"
            }

            # 4. Update Process Ancestry Tree
            $newTree = &$buildFullAncestryTree
            if ($newTree) {
                $propTree.ItemsSource = @($newTree)
            }

            # 5. Live Query for CPU Cycles, Processor Times & I/O Counters
            if (-not $perfQueryState.InFlight) {
                $perfQueryState.InFlight = $true
                &$runDeepInspect $false "Performance"
            }
        }

        # 1-second UI DispatcherTimer for Lightweight Realtime Performance Updates
        $propTimer = [System.Windows.Threading.DispatcherTimer]::new(
            [System.Windows.Threading.DispatcherPriority]::Background,
            $propWin.Dispatcher
        )
        $propTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
        $propTimer.add_Tick({ &$refreshLivePerformanceTab })
        $propTimer.Start()

        $propWin.add_Closed({
            if ($propTimer) { $propTimer.Stop() }
            $perfQueryState.InFlight = $false
        })

        # Wire Lazy Tab Activation for DLLs and Handles
        $propTabControl.add_SelectionChanged({
            param($sender, $e)
            if ($e.OriginalSource -ne $propTabControl) { return }
            $selTab = $propTabControl.SelectedItem
            if (-not $selTab) { return }
            $tabHeader = [string]$selTab.Header
            if ($tabHeader -eq "DLLs" -and -not $tabLoadState.ModulesLoaded) {
                $tabLoadState.ModulesLoaded = $true
                & $runDeepInspect $false "Modules"
            } elseif ($tabHeader -eq "Handles" -and -not $tabLoadState.HandlesLoaded) {
                $tabLoadState.HandlesLoaded = $true
                & $runDeepInspect $false "Handles"
            } elseif ($tabHeader -eq "Performance") {
                if ($syncTreeHeaderSpacer) { & $syncTreeHeaderSpacer }
                if ($refreshLivePerformanceTab) { & $refreshLivePerformanceTab }
            }
        })

        # Wire Modal Buttons
        $propWin.FindName("BtnCopyPath").add_Click({
            if ($selectedVm.Path) { [System.Windows.Clipboard]::SetText($selectedVm.Path) }
        })
        $propWin.FindName("BtnCopyCmd").add_Click({
            if ($selectedVm.CommandLine) { [System.Windows.Clipboard]::SetText($selectedVm.CommandLine) }
        })
        $propWin.FindName("BtnVerifySig").add_Click({
            & $runDeepInspect $true "Core"
        })
        $propWin.FindName("BtnRefreshInspector").add_Click({
            $selTab = $propTabControl.SelectedItem
            $tabHeader = if ($selTab) { [string]$selTab.Header } else { "Image" }
            if ($tabHeader -eq "DLLs") {
                $tabLoadState.ModulesLoaded = $true
                & $runDeepInspect $false "Modules"
            } elseif ($tabHeader -eq "Handles") {
                $tabLoadState.HandlesLoaded = $true
                & $runDeepInspect $false "Handles"
            } else {
                & $runDeepInspect $false "Core"
                if ($tabHeader -eq "Performance" -and $refreshLivePerformanceTab) { & $refreshLivePerformanceTab }
            }
        })
        $btnSuspendResume.add_Click({
            $act = if ($selectedVm.Status -eq "Suspended") { "ResumeProcess" } else { "SuspendProcess" }
            $localBtn = $btnSuspendResume
            $localVm  = $selectedVm
            $localRun = $runDeepInspect
            &$invokeProcessAction $act $selectedVm "Normal" ({
                $localBtn.Content = if ($localVm.Status -eq "Suspended") { "Suspend" } else { "Resume" }
                & $localRun $false "Core"
            })
        })
        $btnPropCreateDump = $propWin.FindName("BtnPropCreateDump")
        if ($btnPropCreateDump) {
            $btnPropCreateDump.add_Click({
                if ($btnPropCreateDump.ContextMenu) {
                    $btnPropCreateDump.ContextMenu.PlacementTarget = $btnPropCreateDump
                    $btnPropCreateDump.ContextMenu.IsOpen = $true
                } else {
                    &$actionCreateDump "Mini" $selectedVm
                }
            })
        }
        $menuPropMini = $propWin.FindName("MenuPropMiniDump")
        if ($menuPropMini) {
            $menuPropMini.add_Click({ &$actionCreateDump "Mini" $selectedVm })
        }
        $menuPropFull = $propWin.FindName("MenuPropFullDump")
        if ($menuPropFull) {
            $menuPropFull.add_Click({ &$actionCreateDump "Full" $selectedVm })
        }

        $gridPropHandles = $propWin.FindName("GridPropHandles")
        $ctxPropClose = $propWin.FindName("CtxPropCloseHandle")
        $ctxPropCopyName = $propWin.FindName("CtxPropCopyHandleName")
        $ctxPropCopyVal = $propWin.FindName("CtxPropCopyHandleValue")

        $closePropSelectedHandle = {
            if (-not $gridPropHandles -or -not $gridPropHandles.SelectedItem) { return }
            $sel = $gridPropHandles.SelectedItem
            $hVal = [string]$sel.Handle
            $tVal = [string]$sel.Type
            $nVal = [string]$sel.Name
            $pName = [string]$selectedVm.Name
            $pidVal = [int]$selectedVm.PID

            if ($tVal -eq "DLL" -or [string]::IsNullOrWhiteSpace($hVal) -or $hVal -eq "N/A" -or ($tVal -and $tVal.StartsWith("["))) {
                [System.Windows.MessageBox]::Show(
                    "Cannot close this handle entry ($($tVal): $nVal).",
                    "PSRPM - Close Handle",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                ) | Out-Null
                return
            }

            $warnMsg = "WARNING: Forcibly closing an active handle in '$pName' (PID $pidVal) can cause the target process to crash or become unstable.`n`nAre you sure you want to close handle $hVal ($nVal)?"
            $confirm = [System.Windows.MessageBox]::Show(
                $warnMsg,
                "PSRPM - Confirm Close Handle",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

            $localGrid = $gridPropHandles
            $localSel = $sel
            $localHVal = $hVal
            $localWin = $propWin
            $closeCallback = {
                param($actionSuccess)
                if ($actionSuccess -eq $false) { return }
                $win = $localWin
                if ($win -and $win.IsLoaded) {
                    $win.Dispatcher.Invoke([Action]({
                        if ($localGrid -and $localGrid.ItemsSource) {
                            $items = $localGrid.ItemsSource
                            $removeIdx = -1
                            for ($i = $items.Count - 1; $i -ge 0; $i--) {
                                if ($items[$i] -eq $localSel -or ($items[$i].Handle -eq $localHVal)) {
                                    $removeIdx = $i
                                    break
                                }
                            }
                            if ($removeIdx -ge 0) {
                                [void]$items.RemoveAt($removeIdx)
                            }
                        }
                    }))
                }
            }.GetNewClosure()

            &$invokeProcessAction "CloseHandle" $selectedVm "Normal" $closeCallback $hVal
        }

        if ($ctxPropClose) {
            $ctxPropClose.add_Click({ & $closePropSelectedHandle })
        }
        if ($ctxPropCopyName) {
            $ctxPropCopyName.add_Click({
                if ($gridPropHandles.SelectedItem -and $gridPropHandles.SelectedItem.Name) {
                    [System.Windows.Clipboard]::SetText([string]$gridPropHandles.SelectedItem.Name)
                }
            })
        }
        if ($ctxPropCopyVal) {
            $ctxPropCopyVal.add_Click({
                if ($gridPropHandles.SelectedItem -and $gridPropHandles.SelectedItem.Handle) {
                    [System.Windows.Clipboard]::SetText([string]$gridPropHandles.SelectedItem.Handle)
                }
            })
        }
        if ($gridPropHandles) {
            $gridPropHandles.add_KeyDown({
                param($s, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Delete) {
                    & $closePropSelectedHandle
                }
            })
        }

        $propWin.FindName("BtnPropEndProcess").add_Click({
            $localPropWin = $propWin
            &$invokeProcessAction "KillProcess" $selectedVm "Normal" ({ $localPropWin.Close() })
        })
        $propWin.FindName("BtnPropEndTree").add_Click({
            $localPropWin = $propWin
            &$invokeProcessAction "KillTree" $selectedVm "Normal" ({ $localPropWin.Close() })
        })
        $propWin.FindName("BtnCloseProp").add_Click({ $propWin.Close() })

        # Trigger Initial On-Demand Core Inspection (Fast < 20ms, skips DLLs & Handles until tab clicked)
        & $runDeepInspect $false "Core"
        [void]$propWin.ShowDialog()
    }

    $window.FindName("MenuProperties").add_Click($actionShowProperties)
    $window.FindName("BtnToolbarProps").add_Click($actionShowProperties)
    $window.FindName("CtxProperties").add_Click($actionShowProperties)
    $gridProcesses.add_MouseDoubleClick({
        param($sender, $e)
        $dep = [System.Windows.DependencyObject]$e.OriginalSource
        while ($dep -ne $null -and $dep -ne $gridProcesses) {
            if ($dep -is [System.Windows.FrameworkElement] -and $dep.Name -eq "BtnToggleExpander") {
                return
            }
            if ($dep -is [System.Windows.Controls.DataGridRow]) {
                &$actionShowProperties
                break
            }
            if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
            } else {
                $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
            }
        }
    })

    # 14. In-App Target Connection / Host Switcher Modal (Ctrl+K)
    # 14. Multi-Host Session Tab Orchestration & Target Connection Manager
    $actionSelectHostTab = {
        param([Object]$targetTabVm, [Object]$engine = $engineHandle)
        if (-not $targetTabVm -or $targetTabVm -eq $script:ActiveHostTab) { return }
        if (-not $engine) { $engine = $engineHandle }

        # 1. Snapshot current active tab state into its own viewmodel
        if ($script:ActiveHostTab -and $engine -and $engine.ProcessMap) {
            $script:ActiveHostTab.ConnState          = [string]$stateContainer.ConnectionState
            $script:ActiveHostTab.EnableNetEtw       = [bool]$stateContainer.EnableNetEtw
            $script:ActiveHostTab.NetEtwCap          = [int]$stateContainer.NetEtwCap
            $script:ActiveHostTab.NetEtwEventsPerSec = [int]$stateContainer.NetEtwEventsPerSec
            $script:ActiveHostTab.NetBannerDismissedCap = [int]$script:NetBannerDismissedCap
            $script:ActiveHostTab.ProcessMap         = [System.Collections.Generic.Dictionary[int, Object]]::new($engine.ProcessMap)
            $script:ActiveHostTab.ServicesMap    = [System.Collections.Generic.Dictionary[string, Object]]::new($engine.ServicesMap)
            $script:ActiveHostTab.PidServicesMap = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new($engine.PidServicesMap)
            if ($engine.TelemStats -and $script:ActiveHostTab.TelemStats) {
                $script:ActiveHostTab.TelemStats.TotalWireBytes  = [long]$engine.TelemStats.TotalWireBytes
                $script:ActiveHostTab.TelemStats.TotalRawBytes   = [long]$engine.TelemStats.TotalRawBytes
                $script:ActiveHostTab.TelemStats.TotalTicks      = [long]$engine.TelemStats.TotalTicks
                $script:ActiveHostTab.TelemStats.TotalRttMs      = [long]$engine.TelemStats.TotalRttMs
                $script:ActiveHostTab.TelemStats.LastReceivedSeq = [int]$engine.TelemStats.LastReceivedSeq
            }
        }

        # 2. Switch Active Tab reference
        $script:ActiveHostTab             = $targetTabVm
        $stateContainer.ActiveTabId       = $targetTabVm.TabId
        $stateContainer.TargetDisplayName = $targetTabVm.Title
        $stateContainer.TransportBadge    = $targetTabVm.Transport
        $stateContainer.ConnectionState   = if ($targetTabVm.ConnState) { $targetTabVm.ConnState } elseif ($targetTabVm.IsLocal) { "LocalMode" } else { "Connected" }
        $stateContainer.EnableNetEtw       = [bool]$targetTabVm.EnableNetEtw
        $stateContainer.NetEtwCap          = [int]$targetTabVm.NetEtwCap
        $stateContainer.NetEtwEventsPerSec = [int]$targetTabVm.NetEtwEventsPerSec
        $script:NetBannerDismissedCap      = [int]$targetTabVm.NetBannerDismissedCap
        if ($updateNetEtwUi) { &$updateNetEtwUi $stateContainer.NetEtwCap $stateContainer.NetEtwEventsPerSec }

        # 3. Swap process maps and per-tab telemetry accumulators into engineHandle
        if ($engine -and $engine.TelemStats -and $targetTabVm.TelemStats) {
            $engine.TelemStats.TotalWireBytes  = [long]$targetTabVm.TelemStats.TotalWireBytes
            $engine.TelemStats.TotalRawBytes   = [long]$targetTabVm.TelemStats.TotalRawBytes
            $engine.TelemStats.TotalTicks      = [long]$targetTabVm.TelemStats.TotalTicks
            $engine.TelemStats.TotalRttMs      = [long]$targetTabVm.TelemStats.TotalRttMs
            $engine.TelemStats.LastReceivedSeq = [int]$targetTabVm.TelemStats.LastReceivedSeq
        }
        if ($engine -and $engine.ProcessMap) {
            $engine.ProcessMap.Clear()
            if ($targetTabVm.ProcessMap) {
                foreach ($kvp in $targetTabVm.ProcessMap.GetEnumerator()) {
                    $engine.ProcessMap[$kvp.Key] = $kvp.Value
                }
            }
            if ($engine.ServicesMap) {
                $engine.ServicesMap.Clear()
                if ($targetTabVm.ServicesMap) {
                    foreach ($kvp in $targetTabVm.ServicesMap.GetEnumerator()) {
                        $engine.ServicesMap[$kvp.Key] = $kvp.Value
                    }
                }
            }
            if ($engine.PidServicesMap) {
                $engine.PidServicesMap.Clear()
                if ($targetTabVm.PidServicesMap) {
                    foreach ($kvp in $targetTabVm.PidServicesMap.GetEnumerator()) {
                        $engine.PidServicesMap[$kvp.Key] = $kvp.Value
                    }
                }
            }
        }

        # 4. Swap SummaryBar, Engine SummaryVm Target, and Reconcile ServicesCollection In-Place (Zero .Clear())
        if ($summaryBar) { $summaryBar.DataContext = $targetTabVm.SummaryVm }
        if ($engine -and $engine.SetSummaryViewModel) {
            & $engine.SetSummaryViewModel $targetTabVm.SummaryVm
        }
        if ($null -ne $servicesCollection) {
            $desiredServices = [System.Collections.Generic.List[Object]]::new()
            if ($null -ne $targetTabVm.ServicesMap) {
                foreach ($sItem in $targetTabVm.ServicesMap.Values) {
                    $desiredServices.Add($sItem)
                }
            }
            if ($engine -and $engine.ReconcileServices) {
                & $engine.ReconcileServices $desiredServices
            } else {
                for ($si = $servicesCollection.Count - 1; $si -ge 0; $si--) {
                    $servicesCollection.RemoveAt($si)
                }
                foreach ($sItem in $desiredServices) {
                    $servicesCollection.Add($sItem)
                }
            }
            if ($updateSvcSummaryText) { &$updateSvcSummaryText }
            if ($updateSvcToolbarButtons) { &$updateSvcToolbarButtons }
        }

        # 5. Update Tab visual highlights
        $isDark = [bool]$stateContainer.IsDarkTheme
        $canClose = ($hostTabsCollection.Count -gt 1)
        foreach ($tVm in $hostTabsCollection) {
            $tVm.UpdateVisualState(($tVm -eq $targetTabVm), $isDark, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
        }

        # 6. Update Window Title
        if ($window) {
            $window.Title = "PSRPM - PowerShell Remote Process Manager [$($targetTabVm.Title)]"
        }

        # 7. Refresh Tree View instantly (< 2ms)
        if ($engine -and $engine.RefreshTree) {
            & $engine.RefreshTree
        }

        # 8. Notify Runspace to switch active poll target
        if ($engine -and $engine.SendCommand) {
            $cmdSelect = @{
                CommandType        = "SelectTabSession"
                TabId              = $targetTabVm.TabId
                ForceFullSync      = ($targetTabVm.ProcessMap.Count -eq 0)
                EnableNetEtw       = [bool]$targetTabVm.EnableNetEtw
                NetEtwCap          = [int]$stateContainer.NetEtwCap
                NetEtwEventsPerSec = [int]$stateContainer.NetEtwEventsPerSec
            }
            & $engine.SendCommand $cmdSelect $null
        }
        if ($writeAuditLog) {
            &$writeAuditLog "TAB" "Switched to session tab '$($targetTabVm.Title)' ($($targetTabVm.Transport))."
        }
    }

    $actionCloseHostTab = {
        param([Object]$tabToClose)
        if (-not $tabToClose -or $hostTabsCollection.Count -le 1) { return }

        $closeIdx = $hostTabsCollection.IndexOf($tabToClose)
        if ($closeIdx -lt 0) { return }

        $wasActive = ($tabToClose -eq $script:ActiveHostTab)
        $tabId = $tabToClose.TabId

        $cmdClose = @{
            CommandType = "CloseTabSession"
            TabId       = $tabId
        }
        & $engineHandle.SendCommand $cmdClose $null

        [void]$hostTabsCollection.Remove($tabToClose)

        if ($wasActive) {
            $newIdx = [Math]::Min($closeIdx, $hostTabsCollection.Count - 1)
            $newActive = $hostTabsCollection[$newIdx]
            &$actionSelectHostTab $newActive $engineHandle
        } else {
            $canClose = ($hostTabsCollection.Count -gt 1)
            $isDark = [bool]$stateContainer.IsDarkTheme
            foreach ($tVm in $hostTabsCollection) {
                $tVm.UpdateVisualState(($tVm -eq $script:ActiveHostTab), $isDark, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
            }
        }
        &$writeAuditLog "TAB" "Closed session tab '$($tabToClose.Title)'."
    }

    $cycleHostTab = {
        param([int]$direction)
        if ($hostTabsCollection.Count -le 1) { return }
        $curIdx = $hostTabsCollection.IndexOf($script:ActiveHostTab)
        if ($curIdx -lt 0) { $curIdx = 0 }
        $nextIdx = ($curIdx + $direction + $hostTabsCollection.Count) % $hostTabsCollection.Count
        &$actionSelectHostTab $hostTabsCollection[$nextIdx] $engineHandle
    }

    if ($hostTabsList) {
        $hostTabsList.add_PreviewMouseLeftButtonDown({
            param($sender, $e)
            $dep = [System.Windows.DependencyObject]$e.OriginalSource
            while ($dep -ne $null -and $dep -ne $hostTabsList) {
                if ($dep -is [System.Windows.FrameworkElement] -and $dep.Name -eq "BtnCloseHostTab") {
                    $tabVm = $dep.DataContext
                    if ($tabVm) {
                        &$actionCloseHostTab $tabVm
                        $e.Handled = $true
                    }
                    break
                }
                if ($dep -is [System.Windows.FrameworkElement] -and $dep.Name -eq "TabItemBorder") {
                    $tabVm = $dep.DataContext
                    if ($tabVm) {
                        if ($e.ClickCount -eq 2) {
                            &$actionConnectDialog $false
                        } else {
                            &$actionSelectHostTab $tabVm $engineHandle
                        }
                        $e.Handled = $true
                    }
                    break
                }
                if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                    $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
                } else {
                    $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
                }
            }
        })
    }

    # Helper: Instantiate HostTabItemViewModel in Module Scope (Prevents DynamicModule class resolution errors)
    $fnCreateHostTabVm = {
        param([string]$tabId, [string]$compName, [string]$title, [string]$transport, [bool]$isLocal)
        $newSumVm = [SystemSummaryViewModel]::new()
        return [HostTabItemViewModel]::new($tabId, $compName, $title, $transport, $isLocal, $newSumVm)
    }

    $actionConnectDialog = {
        param([bool]$forceNewTab = $false)
        $cBytes = [System.IO.File]::ReadAllBytes($connXamlPath)
        $msConn = [System.IO.MemoryStream]::new($cBytes)
        $connWin = [System.Windows.Markup.XamlReader]::Load($msConn)
        $msConn.Close()

        $connWin.Owner = $window
        if ($appIconFrame) { $connWin.Icon = $appIconFrame }

        $rbRemote      = $connWin.FindName("RbRemoteHost")
        $rbLocal       = $connWin.FindName("RbLocalOnly")
        $gridInputs    = $connWin.FindName("GridRemoteInputs")
        $txtComp       = $connWin.FindName("TxtConnectComputer")
        $chkSsl        = $connWin.FindName("ChkUseSSL")
        $txtPort       = $connWin.FindName("TxtConnectPort")
        $btnPickCred   = $connWin.FindName("BtnPickCredential")
        $txtCredStatus = $connWin.FindName("TxtCredStatus")
        $chkOpenNewTab = $connWin.FindName("ChkOpenInNewTab")

        if ($chkOpenNewTab) {
            $chkOpenNewTab.IsChecked = [bool]$forceNewTab
        }

        # Context-aware defaults: If currently in Local Mode, default to Local Host Only
        if ($stateContainer.ConnectionState -eq "LocalMode" -or $isLocalMode) {
            if ($rbLocal)    { $rbLocal.IsChecked = $true }
            if ($gridInputs) { $gridInputs.IsEnabled = $false }
        } else {
            if ($rbRemote)   { $rbRemote.IsChecked = $true }
            if ($gridInputs) { $gridInputs.IsEnabled = $true }
        }

        $txtComp.Text = if ($forceNewTab) { "localhost" } else { $stateContainer.TargetDisplayName }
        $credHolder   = @{ Value = $Credential }

        $rbRemote.add_Checked({ $gridInputs.IsEnabled = $true })
        $rbLocal.add_Checked({  $gridInputs.IsEnabled = $false })

        $btnPickCred.add_Click({
            try {
                $c = Get-Credential
                if ($c) {
                    $credHolder.Value = $c
                    $txtCredStatus.Text = $c.UserName
                }
            } catch {}
        })

        $connWin.FindName("BtnConnectSubmit").add_Click({
            $useLocal = [bool]$rbLocal.IsChecked
            $compName = $txtComp.Text.Trim()
            if (-not $useLocal -and [string]::IsNullOrWhiteSpace($compName)) {
                [System.Windows.MessageBox]::Show("Please enter a remote computer name or IP address.", "PSRPM", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }

            $portNum = 0
            [void][int]::TryParse($txtPort.Text.Trim(), [ref]$portNum)
            $useSslVal = [bool]$chkSsl.IsChecked
            $openNew   = if ($chkOpenNewTab) { [bool]$chkOpenNewTab.IsChecked } else { $false }
            $targetLabel = if ($useLocal) { "$env:COMPUTERNAME" } else { $compName }

            $connWin.IsEnabled = $false

            if ($openNew) {
                &$writeAuditLog "CONNECT" "Opening new host session tab for '$targetLabel'..."
                $newTabId = [guid]::NewGuid().ToString("N")
                $addCmd = @{
                    CommandType  = "AddTabSession"
                    TabId        = $newTabId
                    ComputerName = $compName
                    IsLocal      = $useLocal
                    Credential   = $credHolder.Value
                    Port         = $portNum
                    UseSSL       = $useSslVal
                }

                $localConnWin     = $connWin
                $localLog         = $writeAuditLog
                $localComp        = $compName
                $localEngine      = $engineHandle
                $localTabsCol     = $hostTabsCollection
                $localActionSel   = $actionSelectHostTab
                $localCreateTabVm = $fnCreateHostTabVm

                & $localEngine.SendCommand $addCmd ({
                    param($res)
                    try {
                        $localConnWin.IsEnabled = $true
                        if ($res.Success) {
                            $tabTitle = $res.Target
                            if ($res.IsLocal) {
                                $localCount = 0
                                foreach ($t in $localTabsCol) { if ($t.IsLocal) { $localCount++ } }
                                if ($localCount -gt 0) {
                                    $tabTitle = "$($res.Target) #$($localCount + 1)"
                                }
                            }

                            $newTabVm = & $localCreateTabVm $res.TabId $res.Target $tabTitle $res.Transport ([bool]$res.IsLocal)
                            if ($res.ConnState) { $newTabVm.ConnState = [string]$res.ConnState }
                            $localTabsCol.Add($newTabVm)

                            try {
                                & $localActionSel $newTabVm $localEngine
                            } catch {
                                &$localLog "ERROR" "SelectTab error: $($_.Exception.Message)"
                            }

                            &$localLog "CONNECT" "Connected to $($tabTitle) ($($res.Transport)) in $($res.ElapsedMs)ms."
                            $localConnWin.Close()
                        } else {
                            &$localLog "ERROR" "Failed to connect to '$localComp': $($res.Error)"
                            [System.Windows.MessageBox]::Show(
                                $localConnWin,
                                "Failed to connect to '$localComp':`n`n$($res.Error)`n`nTip: If WinRM remoting is not configured on this computer, choose 'Local Host Only' to monitor processes without WinRM.",
                                "PSRPM - Connection Error",
                                [System.Windows.MessageBoxButton]::OK,
                                [System.Windows.MessageBoxImage]::Error
                            ) | Out-Null
                        }
                    } catch {
                        &$localLog "ERROR" "AddTabSession UI callback error: $($_.Exception.Message)"
                        $localConnWin.Close()
                    }
                }.GetNewClosure())
            } else {
                &$writeAuditLog "CONNECT" "Switching target to '$targetLabel'..."
                $switchCmd = @{
                    CommandType  = "SwitchTarget"
                    ComputerName = $compName
                    IsLocal      = $useLocal
                    Credential   = $credHolder.Value
                    Port         = $portNum
                    UseSSL       = $useSslVal
                }

                $localConnWin = $connWin
                $localWin     = $window
                $localState   = $stateContainer
                $localLog     = $writeAuditLog
                $localComp    = $compName
                $localTabsCol = $hostTabsCollection
                $curTab       = $script:ActiveHostTab
                $localUpdNet  = $updateNetEtwUi

                & $engineHandle.SendCommand $switchCmd ({
                    param($res)
                    try {
                        $localConnWin.IsEnabled = $true
                        if ($res.Success) {
                            $localState.EnableNetEtw = $false
                            $localState.NetEtwCap = 0
                            $localState.NetEtwEventsPerSec = 0
                            if ($localUpdNet) { & $localUpdNet 0 0 }
                            if ($curTab) {
                                $curTab.ComputerName = $localState.TargetDisplayName
                                $curTab.Title        = $localState.TargetDisplayName
                                $curTab.Transport    = $localState.TransportBadge
                                $curTab.IsLocal      = ($localState.ConnectionState -eq "LocalMode")
                                $curTab.ConnState    = [string]$localState.ConnectionState
                                if ($curTab.TelemStats) {
                                    $curTab.TelemStats.TotalWireBytes  = 0L
                                    $curTab.TelemStats.TotalRawBytes   = 0L
                                    $curTab.TelemStats.TotalTicks      = 0L
                                    $curTab.TelemStats.TotalRttMs      = 0L
                                    $curTab.TelemStats.LastReceivedSeq = 0
                                }
                                $canClose = ($localTabsCol.Count -gt 1)
                                $isDark   = [bool]$localState.IsDarkTheme
                                $curTab.UpdateVisualState($true, $isDark, $canClose, $localState.ConnectionState, [bool]$localState.IsPaused, $localState.PollLatencyMs)
                            }
                            $localWin.Title = "PSRPM - PowerShell Remote Process Manager [$($localState.TargetDisplayName)]"
                            &$localLog "CONNECT" $res.Message
                            $localConnWin.Close()
                        } else {
                            &$localLog "ERROR" "Failed to switch target: $($res.Error)"
                            [System.Windows.MessageBox]::Show(
                                $localConnWin,
                                "Failed to connect to '$localComp':`n`n$($res.Error)`n`nTip: If WinRM remoting is not configured on this computer, choose 'Local Host Only' to monitor processes without WinRM.",
                                "PSRPM - Connection Error",
                                [System.Windows.MessageBoxButton]::OK,
                                [System.Windows.MessageBoxImage]::Error
                            ) | Out-Null
                        }
                    } catch {
                        &$localLog "ERROR" "SwitchTarget UI callback error: $($_.Exception.Message)"
                        $localConnWin.Close()
                    }
                }.GetNewClosure())
            }
        })

        $connWin.FindName("BtnConnectCancel").add_Click({ $connWin.Close() })
        [void]$connWin.ShowDialog()
    }

    $window.FindName("MenuConnectHost").add_Click({ &$actionConnectDialog $false })
    $window.FindName("BtnConnectHost").add_Click({ &$actionConnectDialog $false })

    $menuNewHostTab = $window.FindName("MenuNewHostTab")
    if ($menuNewHostTab) { $menuNewHostTab.add_Click({ &$actionConnectDialog $true }) }

    $menuCloseHostTab = $window.FindName("MenuCloseHostTab")
    if ($menuCloseHostTab) { $menuCloseHostTab.add_Click({ &$actionCloseHostTab $script:ActiveHostTab }) }

    $menuNextHostTab = $window.FindName("MenuNextHostTab")
    if ($menuNextHostTab) { $menuNextHostTab.add_Click({ &$cycleHostTab 1 }) }

    $menuPrevHostTab = $window.FindName("MenuPrevHostTab")
    if ($menuPrevHostTab) { $menuPrevHostTab.add_Click({ &$cycleHostTab -1 }) }

    $btnAddHostTab = $window.FindName("BtnAddHostTab")
    if ($btnAddHostTab) { $btnAddHostTab.add_Click({ &$actionConnectDialog $true }) }

    $window.FindName("MenuSwitchLocal").add_Click({
        $switchLocalCmd = @{
            CommandType  = "SwitchTarget"
            ComputerName = $env:COMPUTERNAME
            IsLocal      = $true
            Credential   = $null
            Port         = 0
            UseSSL       = $false
        }
        $localWin     = $window
        $localState   = $stateContainer
        $localLog     = $writeAuditLog
        $localTabsCol = $hostTabsCollection
        $curTab       = $script:ActiveHostTab
        & $engineHandle.SendCommand $switchLocalCmd ({
            param($res)
            if ($res.Success) {
                if ($curTab) {
                    $curTab.ComputerName = $localState.TargetDisplayName
                    $curTab.Title        = $localState.TargetDisplayName
                    $curTab.Transport    = "LOCAL"
                    $curTab.IsLocal      = $true
                    $curTab.UpdateVisualState($true, [bool]$localState.IsDarkTheme, ($localTabsCol.Count -gt 1), "LocalMode", [bool]$localState.IsPaused, $localState.PollLatencyMs)
                }
                $localWin.Title = "PSRPM - PowerShell Remote Process Manager [$($localState.TargetDisplayName)]"
                &$localLog "CONNECT" $res.Message
            }
        }.GetNewClosure())
    })

    # 15. Forensic Snapshot Exports (Pure WPF Microsoft.Win32.SaveFileDialog)
    $exportSnapshot = {
        param([string]$format)
        $dlg = [Microsoft.Win32.SaveFileDialog]::new()
        $tsFile = (Get-Date).ToString("yyyyMMdd_HHmmss")
        if ($format -eq "JSON") {
            $dlg.Filter   = "JSON Forensic Snapshot (*.json)|*.json"
            $dlg.FileName = "PSRPM_Snapshot_$($stateContainer.TargetDisplayName)_$tsFile.json"
        } else {
            $dlg.Filter   = "CSV Process Snapshot (*.csv)|*.csv"
            $dlg.FileName = "PSRPM_Snapshot_$($stateContainer.TargetDisplayName)_$tsFile.csv"
        }

        if ($dlg.ShowDialog($window) -eq $true) {
            try {
                $includeNetCols = ([int]$stateContainer.NetEtwCap -eq 1)
                if (-not $includeNetCols) {
                    foreach ($vmCheck in $engineHandle.ProcessMap.Values) {
                        if ($vmCheck.NetTotalBps -gt 0L -or $vmCheck.TreeNetTotalBps -gt 0L) {
                            $includeNetCols = $true
                            break
                        }
                    }
                }
                $rows = foreach ($vm in $engineHandle.ProcessMap.Values) {
                    if ($includeNetCols) {
                        [PSCustomObject]@{
                            PID             = $vm.PID
                            ParentPID       = $vm.ParentPID
                            Name            = $vm.Name
                            CPU             = $vm.CPU
                            TreeCPU         = $vm.TreeCPU
                            NetRxBps        = $vm.NetRxBps
                            NetTxBps        = $vm.NetTxBps
                            NetTotalBps     = $vm.NetTotalBps
                            TreeNetRxBps    = $vm.TreeNetRxBps
                            TreeNetTxBps    = $vm.TreeNetTxBps
                            TreeNetTotalBps = $vm.TreeNetTotalBps
                            PrivateBytesKB  = [Math]::Round($vm.PrivateBytes / 1024.0, 0)
                            WorkingSetKB    = [Math]::Round($vm.MemoryBytes / 1024.0, 0)
                            Threads         = $vm.Threads
                            Handles         = $vm.Handles
                            Status          = $vm.Status
                            Category        = $vm.Category
                            Arch            = $vm.Architecture
                            User            = $vm.User
                            Description     = $vm.Description
                            CompanyName     = $vm.CompanyName
                            HostedServices  = $vm.HostedServices
                            StartTime       = $vm.StartTime
                            Path            = $vm.Path
                            CommandLine     = $vm.CommandLine
                        }
                    } else {
                        [PSCustomObject]@{
                            PID            = $vm.PID
                            ParentPID      = $vm.ParentPID
                            Name           = $vm.Name
                            CPU            = $vm.CPU
                            TreeCPU        = $vm.TreeCPU
                            PrivateBytesKB = [Math]::Round($vm.PrivateBytes / 1024.0, 0)
                            WorkingSetKB   = [Math]::Round($vm.MemoryBytes / 1024.0, 0)
                            Threads        = $vm.Threads
                            Handles        = $vm.Handles
                            Status         = $vm.Status
                            Category       = $vm.Category
                            Arch           = $vm.Architecture
                            User           = $vm.User
                            Description    = $vm.Description
                            CompanyName    = $vm.CompanyName
                            HostedServices = $vm.HostedServices
                            StartTime      = $vm.StartTime
                            Path           = $vm.Path
                            CommandLine    = $vm.CommandLine
                        }
                    }
                }
                if ($format -eq "JSON") {
                    $activeSumm = if ($script:ActiveHostTab -and $script:ActiveHostTab.SummaryVm) { $script:ActiveHostTab.SummaryVm } else { $summaryVm }
                    $histObj = [PSCustomObject]@{
                        Cpu          = $activeSumm.GetCpuHistory240()
                        Kernel       = $activeSumm.GetKernelHistory240()
                        CommitCharge = $activeSumm.GetCommitHistory240()
                        RamPhysical  = $activeSumm.GetRamHistory240()
                        IoTotal      = $activeSumm.GetIoTotalHistory240()
                        IoWrite      = $activeSumm.GetIoWriteHistory240()
                        NetRx        = $activeSumm.GetNetRxHistory240()
                        NetTx        = $activeSumm.GetNetTxHistory240()
                    }
                    $exportPkg = [PSCustomObject]@{
                        Target        = $stateContainer.TargetDisplayName
                        ExportTimeUtc = [System.DateTime]::UtcNow.ToString("o")
                        SystemSummary = [PSCustomObject]@{
                            CpuPercent      = [Math]::Round($activeSumm.CpuUsage, 2)
                            KernelPercent   = [Math]::Round($activeSumm.KernelCpuUsage, 2)
                            CommitChargeMB  = $activeSumm.CommitUsedMB
                            CommitLimitMB   = $activeSumm.CommitLimitMB
                            PhysicalTotalMB = $activeSumm.RamTotalMB
                            PhysicalUsedMB  = $activeSumm.RamUsedMB
                            PhysicalAvailMB = [Math]::Max(0L, ($activeSumm.RamTotalMB - $activeSumm.RamUsedMB))
                            ProcessCount    = $activeSumm.ProcessCount
                            ThreadCount     = $activeSumm.ThreadCount
                            HandleCount     = $activeSumm.HandleCount
                            History240      = $histObj
                            History120      = $histObj
                        }
                        Processes     = $rows
                    }
                    $exportPkg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
                } else {
                    $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
                }
                &$writeAuditLog "EXPORT" "Exported $($rows.Count) processes ($format) to '$($dlg.FileName)'."
            } catch {
                [System.Windows.MessageBox]::Show("Failed to export snapshot:`n$($_.Exception.Message)", "PSRPM - Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            }
        }
    }

    $window.FindName("MenuExportCsv").add_Click({ &$exportSnapshot "CSV" })
    $window.FindName("MenuExportJson").add_Click({ &$exportSnapshot "JSON" })
    $window.FindName("MenuExit").add_Click({ $window.Close() })

    # 15B. System Information Window (Summary, CPU, Memory, I/O Tabs - Double-Click Mini Graphs or Ctrl+I)
    $script:ActiveSysInfoWin = $null
    $actionShowSystemInfo = {
        param([int]$initialTabIndex = 0)
        if ($script:ActiveSysInfoWin -and $script:ActiveSysInfoWin.IsLoaded) {
            $tcExisting = $script:ActiveSysInfoWin.FindName("SysInfoTabControl")
            if ($tcExisting -and $initialTabIndex -ge 0 -and $initialTabIndex -lt $tcExisting.Items.Count) {
                $tcExisting.SelectedIndex = $initialTabIndex
            }
            [void]$script:ActiveSysInfoWin.Activate()
            return
        }

        $sBytes = [System.IO.File]::ReadAllBytes($sysInfoXamlPath)
        $msSys  = [System.IO.MemoryStream]::new($sBytes)
        $sysWin = [System.Windows.Markup.XamlReader]::Load($msSys)
        $msSys.Close()

        $activeSumm = if ($script:ActiveHostTab -and $script:ActiveHostTab.SummaryVm) { $script:ActiveHostTab.SummaryVm } else { $summaryVm }
        $sysWin.Owner       = $window
        if ($appIconFrame) { $sysWin.Icon = $appIconFrame }
        $sysWin.Title       = "System Information [$($stateContainer.TargetDisplayName)]"
        $sysWin.DataContext = $activeSumm

        # Propagate active theme resources from main window
        foreach ($key in @("BrushWindowBg","BrushToolbarBg","BrushSurfaceBg","BrushHeaderBg","BrushBorderSubtle","BrushTreeLine","BrushTextPrimary","BrushTextSecondary","BrushTextMuted","BrushRowHover","BrushRowSelectedBg","BrushRowSelectedFg","BrushSparkBg","BrushSparkBorder","ColTint_CPU","ColTint_PrivateBytes","ColTint_WorkingSet","BrushMenuBg","BrushMenuBorder","BrushMenuHover")) {
            if ($window.Resources.Contains($key)) {
                $sysWin.Resources[$key] = $window.Resources[$key]
            }
        }

        $activeSumm.IsSysInfoOpen = $true
        $activeSumm.RefreshSysInfoGraphs()
        if ($activeSumm.ShowOneGraphPerCpu) {
            foreach ($cg in $activeSumm.CoreGraphs) { $cg.BuildCoreGeometry() }
        }

        $tcSys = $sysWin.FindName("SysInfoTabControl")
        if ($tcSys -and $initialTabIndex -ge 0 -and $initialTabIndex -lt $tcSys.Items.Count) {
            $tcSys.SelectedIndex = $initialTabIndex
        }

        $qCpu    = $sysWin.FindName("QuadCpu")
        $qCommit = $sysWin.FindName("QuadCommit")
        $qRam    = $sysWin.FindName("QuadRam")
        $qIo     = $sysWin.FindName("QuadIo")
        if ($qCpu -and $tcSys) {
            $qCpu.add_MouseLeftButtonDown({ param($s,$e) if ($e.ClickCount -eq 2) { $tcSys.SelectedIndex = 1; $e.Handled = $true } }.GetNewClosure())
        }
        if ($qCommit -and $tcSys) {
            $qCommit.add_MouseLeftButtonDown({ param($s,$e) if ($e.ClickCount -eq 2) { $tcSys.SelectedIndex = 2; $e.Handled = $true } }.GetNewClosure())
        }
        if ($qRam -and $tcSys) {
            $qRam.add_MouseLeftButtonDown({ param($s,$e) if ($e.ClickCount -eq 2) { $tcSys.SelectedIndex = 2; $e.Handled = $true } }.GetNewClosure())
        }
        if ($qIo -and $tcSys) {
            $qIo.add_MouseLeftButtonDown({ param($s,$e) if ($e.ClickCount -eq 2) { $tcSys.SelectedIndex = 3; $e.Handled = $true } }.GetNewClosure())
        }

        $chkPerCpu = $sysWin.FindName("ChkPerCpuGraph")
        if ($chkPerCpu) {
            $localSumm = $activeSumm
            $chkPerCpu.add_Checked({ $localSumm.SetPerCpuMode($true) }.GetNewClosure())
            $chkPerCpu.add_Unchecked({ $localSumm.SetPerCpuMode($false) }.GetNewClosure())
        }

        $btnSysOk = $sysWin.FindName("BtnSysInfoOk")
        if ($btnSysOk) {
            $btnSysOk.add_Click({ $sysWin.Close() }.GetNewClosure())
        }

        $sysWin.add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $sysWin.Close()
                $e.Handled = $true
            }
        }.GetNewClosure())

        $localCloseSumm = $activeSumm
        $sysWin.add_Closed({
            $localCloseSumm.IsSysInfoOpen = $false
            $script:ActiveSysInfoWin = $null
        }.GetNewClosure())

        $script:ActiveSysInfoWin = $sysWin
        $sysWin.Show()
    }

    $menuSysInfo    = $window.FindName("MenuSystemInfo")
    $cardMiniCpu    = $window.FindName("CardMiniCpu")
    $cardMiniCommit = $window.FindName("CardMiniCommit")
    $cardMiniRam    = $window.FindName("CardMiniRam")

    if ($menuSysInfo) {
        $menuSysInfo.add_Click({ &$actionShowSystemInfo 0 })
    }
    if ($cardMiniCpu) {
        $cardMiniCpu.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                $tabIdx = if ($script:ActiveSysInfoWin -and $script:ActiveSysInfoWin.IsLoaded) { 1 } else { 0 }
                &$actionShowSystemInfo $tabIdx
                $e.Handled = $true
            }
        })
    }
    if ($cardMiniCommit) {
        $cardMiniCommit.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                $tabIdx = if ($script:ActiveSysInfoWin -and $script:ActiveSysInfoWin.IsLoaded) { 2 } else { 0 }
                &$actionShowSystemInfo $tabIdx
                $e.Handled = $true
            }
        })
    }
    if ($cardMiniRam) {
        $cardMiniRam.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                &$actionShowSystemInfo 2
                $e.Handled = $true
            }
        })
    }

    # 15C. Help, Reference & About Modal Window (F1 or Help Menu)
    $actionShowHelp = {
        param([int]$initialTabIndex = 0)
        try {
            $hBytes = [System.IO.File]::ReadAllBytes($helpXamlPath)
            $msHelp = [System.IO.MemoryStream]::new($hBytes)
            $helpWin = [System.Windows.Markup.XamlReader]::Load($msHelp)
            $msHelp.Close()

            $helpWin.Owner = $window
            if ($appIconFrame) { $helpWin.Icon = $appIconFrame }

            $tcHelp = $helpWin.FindName("HelpTabControl")
            if ($tcHelp -and $initialTabIndex -ge 0 -and $initialTabIndex -lt $tcHelp.Items.Count) {
                $tcHelp.SelectedIndex = $initialTabIndex
            }

            # Populate live diagnostic information in About tab
            $txtAboutHost = $helpWin.FindName("TxtAboutHost")
            if ($txtAboutHost) { $txtAboutHost.Text = "$env:COMPUTERNAME" }

            $txtAboutUser = $helpWin.FindName("TxtAboutUser")
            if ($txtAboutUser) { $txtAboutUser.Text = "$env:USERDOMAIN\$env:USERNAME" }

            # Update Help & About Window Version Badges dynamically from single source of truth
            $txtHeaderBadge = $helpWin.FindName("TxtHeaderBadge")
            if ($txtHeaderBadge) {
                $txtHeaderBadge.Text = "v$($script:AppVersion)"
            }

            $txtAboutVer = $helpWin.FindName("TxtAboutVersion")
            if ($txtAboutVer) {
                $txtAboutVer.Text = "$($script:AppVersion)"
            }

            $txtAboutTarget = $helpWin.FindName("TxtAboutTarget")
            if ($txtAboutTarget) { $txtAboutTarget.Text = "$($stateContainer.TargetDisplayName)" }

            $txtAboutTransport = $helpWin.FindName("TxtAboutTransport")
            if ($txtAboutTransport) { $txtAboutTransport.Text = "$($stateContainer.TransportBadge) ($($stateContainer.ConnectionState))" }

            $txtAboutPsVer = $helpWin.FindName("TxtAboutPsVersion")
            if ($txtAboutPsVer) { $txtAboutPsVer.Text = "$($PSVersionTable.PSVersion)" }

            $txtAboutClrVer = $helpWin.FindName("TxtAboutClrVersion")
            if ($txtAboutClrVer) { $txtAboutClrVer.Text = "$([Environment]::Version)" }

            $txtAboutArch = $helpWin.FindName("TxtAboutArch")
            if ($txtAboutArch) {
                $bitStr = if ([System.Environment]::Is64BitProcess) { "64-bit (x64)" } else { "32-bit (x86)" }
                $txtAboutArch.Text = "$bitStr on $($env:PROCESSOR_ARCHITECTURE)"
            }

            $btnHelpClose = $helpWin.FindName("BtnHelpClose")
            if ($btnHelpClose) {
                $btnHelpClose.add_Click({ $helpWin.Close() })
            }

            [void]$helpWin.ShowDialog()
        } catch {
            &$writeAuditLog "ERROR" "Failed to display Help window: $($_.Exception.Message)"
        }
    }

    $menuHelpTopics = $window.FindName("MenuHelpTopics")
    if ($menuHelpTopics) { $menuHelpTopics.add_Click({ &$actionShowHelp 0 }) }

    $menuHelpArchitecture = $window.FindName("MenuHelpArchitecture")
    if ($menuHelpArchitecture) { $menuHelpArchitecture.add_Click({ &$actionShowHelp 1 }) }

    $menuHelpConnectivity = $window.FindName("MenuHelpConnectivity")
    if ($menuHelpConnectivity) { $menuHelpConnectivity.add_Click({ &$actionShowHelp 2 }) }

    $menuHelpAbout = $window.FindName("MenuHelpAbout")
    if ($menuHelpAbout) { $menuHelpAbout.add_Click({ &$actionShowHelp 3 }) }

    $menuFileHelp = $window.FindName("MenuFileHelp")
    if ($menuFileHelp) { $menuFileHelp.add_Click({ &$actionShowHelp 0 }) }

    $btnToolbarHelp = $window.FindName("BtnToolbarHelp")
    if ($btnToolbarHelp) { $btnToolbarHelp.add_Click({ &$actionShowHelp 0 }) }

    # 15C. Find Handle or DLL Window (Ctrl+Shift+F or Find Menu / Toolbar)
    $script:ActiveFindHandleWin  = $null
    $script:FindHandleControls   = @{}
    $script:FindHandleResultsCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()

    $executeHandleSearch = {
        $ctrls     = $script:FindHandleControls
        $txtBox    = $ctrls['TxtSearchHandle']
        $btnSearch = $ctrls['BtnSearchHandle']
        $txtStatus = $ctrls['TxtHandleStatus']
        $findWin   = $script:ActiveFindHandleWin
        $localCol  = $script:FindHandleResultsCol

        $q = if ($txtBox) { $txtBox.Text.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($q)) {
            if ($txtStatus) { $txtStatus.Text = "Please enter a file name, folder path, DLL, or key substring to search." }
            return
        }

        if ($btnSearch) { $btnSearch.IsEnabled = $false }
        if ($txtStatus) { $txtStatus.Text = "Searching across processes on '$($stateContainer.TargetDisplayName)' for '$q'..." }

        $cmdFind = @{
            CommandType = "FindHandles"
            Query       = $q
        }

        $localJss = $jssAction
        $localQ   = $q

        & $engineHandle.SendCommand $cmdFind ({
            param($res)
            if ($findWin -and $findWin.IsLoaded) {
                $findWin.Dispatcher.Invoke([Action]({
                    if ($btnSearch) { $btnSearch.IsEnabled = $true }
                    if ($res.Success -and $res.PayloadJson) {
                        $parsedList = $localJss.DeserializeObject($res.PayloadJson)
                        for ($i = $localCol.Count - 1; $i -ge 0; $i--) { $localCol.RemoveAt($i) }
                        if ($parsedList -and $parsedList.Count -gt 0) {
                            foreach ($item in $parsedList) {
                                [void]$localCol.Add([PSCustomObject]@{
                                    ProcessName = [string]$item['ProcessName']
                                    PID         = [int]$item['PID']
                                    Type        = [string]$item['Type']
                                    Handle      = [string]$item['Handle']
                                    Name        = [string]$item['Name']
                                })
                            }
                            if ($txtStatus) {
                                $txtStatus.Text = "Found $($parsedList.Count) matching handle(s) and DLL(s) in $($res.ElapsedMs) ms."
                            }
                        } else {
                            if ($txtStatus) {
                                $txtStatus.Text = "0 matches found for '$localQ' ($($res.ElapsedMs) ms)."
                            }
                        }
                    } else {
                        if ($txtStatus) {
                            $txtStatus.Text = "Search failed: $($res.Error)"
                        }
                    }
                }))
            }
        }.GetNewClosure())
    }

    $closeSelectedHandle = {
        $gridHandles = $script:FindHandleControls['GridHandleResults']
        if (-not $gridHandles -or -not $gridHandles.SelectedItem) { return }
        $sel    = $gridHandles.SelectedItem
        $hVal   = [string]$sel.Handle
        $tVal   = [string]$sel.Type
        $pName  = [string]$sel.ProcessName
        $pidVal = [int]$sel.PID
        $nVal   = [string]$sel.Name

        if ($tVal -eq "DLL" -or [string]::IsNullOrWhiteSpace($hVal) -or $hVal -eq "N/A" -or ($tVal -and $tVal.StartsWith("["))) {
            [System.Windows.MessageBox]::Show(
                "Cannot close this handle entry ($($tVal): $nVal).",
                "PSRPM - Close Handle",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            return
        }

        $warnMsg = "WARNING: Forcibly closing an active handle in '$pName' (PID $pidVal) can cause the target process to crash or become unstable.`n`nAre you sure you want to close handle $hVal ($nVal)?"
        $confirm = [System.Windows.MessageBox]::Show(
            $warnMsg,
            "PSRPM - Confirm Close Handle",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $procVmDummy = [PSCustomObject]@{
            PID  = $pidVal
            Name = $pName
        }
        $targetPid    = $pidVal
        $targetHnd    = $hVal
        $targetPName  = $pName
        $targetSel    = $sel
        $targetCol    = $script:FindHandleResultsCol
        $targetWin    = $script:ActiveFindHandleWin
        $targetStatus = $script:FindHandleControls['TxtHandleStatus']

        $closeCallback = {
            param($actionSuccess)
            if ($actionSuccess -eq $false) { return }
            $win = $targetWin
            if ($win -and $win.IsLoaded) {
                $win.Dispatcher.Invoke([Action]({
                    $col = $targetCol
                    if (-not $col) { return }
                    $removeIdx = -1
                    for ($i = $col.Count - 1; $i -ge 0; $i--) {
                        $item = $col[$i]
                        if ($item -eq $targetSel) {
                            $removeIdx = $i
                            break
                        }
                        $itemPid = [int]$item.PID
                        $itemHnd = [string]$item.Handle
                        $matchHnd = ($itemHnd.Trim().ToLowerInvariant() -eq $targetHnd.Trim().ToLowerInvariant())
                        if ($itemPid -eq $targetPid -and $matchHnd) {
                            $removeIdx = $i
                            break
                        }
                    }
                    if ($removeIdx -ge 0) {
                        [void]$col.RemoveAt($removeIdx)
                    }
                    $txtSt = $targetStatus
                    if ($txtSt) {
                        if ($removeIdx -ge 0) {
                            $txtSt.Text = "Successfully closed handle $targetHnd in '$targetPName' (PID $targetPid). Remaining matches: $($col.Count)."
                        } else {
                            $txtSt.Text = "Closed handle $targetHnd in '$targetPName' (PID $targetPid)."
                        }
                    }
                }))
            }
        }.GetNewClosure()

        &$invokeProcessAction "CloseHandle" $procVmDummy "Normal" $closeCallback $hVal
    }

    $goToProcessInTree = {
        $gridHandles = $script:FindHandleControls['GridHandleResults']
        if (-not $gridHandles -or -not $gridHandles.SelectedItem) { return }
        $sel    = $gridHandles.SelectedItem
        $pidVal = [int]$sel.PID

        $mainTabs = $window.FindName("MainTabControl")
        if ($mainTabs -and $mainTabs.SelectedIndex -ne 0) {
            $mainTabs.SelectedIndex = 0
        }

        if ($engineHandle.ProcessMap.ContainsKey($pidVal)) {
            $targetVm = $engineHandle.ProcessMap[$pidVal]
            $currPid = $targetVm.ParentPID
            $guard = 0
            while ($currPid -gt 0 -and $engineHandle.ProcessMap.ContainsKey($currPid) -and $guard -lt 30) {
                $parentVm = $engineHandle.ProcessMap[$currPid]
                $parentVm.IsExpanded = $true
                $parentVm.UpdateExpanderGeometry()
                $currPid = $parentVm.ParentPID
                $guard++
            }
            if ($engineHandle.RefreshTree) { & $engineHandle.RefreshTree }
            $gridProcesses.SelectedItem = $targetVm
            $gridProcesses.ScrollIntoView($targetVm)
            $window.Activate()
        } else {
            [System.Windows.MessageBox]::Show("Process '$($sel.ProcessName)' (PID $pidVal) is no longer active in the process tree.", "PSRPM - Process Not Found", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    }

    $copySelectedPath = {
        $gridHandles = $script:FindHandleControls['GridHandleResults']
        if ($gridHandles -and $gridHandles.SelectedItem) {
            $sel = $gridHandles.SelectedItem
            if ($sel.Name) {
                [System.Windows.Clipboard]::SetText([string]$sel.Name)
                &$writeAuditLog "CLIPBOARD" "Copied object path '$($sel.Name)'."
            }
        }
    }

    $actionShowFindHandle = {
        if ($script:ActiveFindHandleWin -and $script:ActiveFindHandleWin.IsLoaded) {
            $script:ActiveFindHandleWin.Activate()
            $txt = $script:FindHandleControls['TxtSearchHandle']
            if ($txt) { [void]$txt.Focus() }
            return
        }

        # Clear any previous search results so fresh modal opens cleanly
        for ($i = $script:FindHandleResultsCol.Count - 1; $i -ge 0; $i--) { $script:FindHandleResultsCol.RemoveAt($i) }

        $fBytes  = [System.IO.File]::ReadAllBytes($findHandleXamlPath)
        $msFind  = [System.IO.MemoryStream]::new($fBytes)
        $findWin = [System.Windows.Markup.XamlReader]::Load($msFind)
        $msFind.Close()

        $findWin.Owner = $window
        if ($appIconFrame) { $findWin.Icon = $appIconFrame }
        $findWin.Title = "Find Handle or DLL Substring [$($stateContainer.TargetDisplayName)]"

        # Apply active theme brushes from main window
        foreach ($key in @("BrushWindowBg","BrushToolbarBg","BrushSurfaceBg","BrushHeaderBg","BrushBorderSubtle","BrushTreeLine","BrushTextPrimary","BrushTextSecondary","BrushTextMuted","BrushRowHover","BrushRowSelectedBg","BrushRowSelectedFg","BrushMenuBg","BrushMenuBorder","BrushMenuHover")) {
            if ($window.Resources.Contains($key)) {
                $findWin.Resources[$key] = $window.Resources[$key]
            }
        }

        $txtSearchHandle = $findWin.FindName("TxtSearchHandle")
        $btnSearchHandle = $findWin.FindName("BtnSearchHandle")
        $txtHandleStatus = $findWin.FindName("TxtHandleStatus")
        $gridHandles     = $findWin.FindName("GridHandleResults")
        $ctxCloseHandle  = $findWin.FindName("CtxCloseHandle")
        $ctxGoToProcess  = $findWin.FindName("CtxGoToProcess")
        $ctxCopyPath     = $findWin.FindName("CtxCopyPath")
        $btnCloseHandle  = $findWin.FindName("BtnCloseHandle")
        $btnGoToProcess  = $findWin.FindName("BtnGoToProcess")
        $btnCopyPath     = $findWin.FindName("BtnCopyPath")
        $btnCloseDlg     = $findWin.FindName("BtnCloseDlg")

        if ($txtSearchHandle) { $txtSearchHandle.Text = "" }
        if ($txtHandleStatus) { $txtHandleStatus.Text = "Enter a file name, folder path, DLL, or registry key to search across processes." }

        $script:ActiveFindHandleWin = $findWin
        $script:FindHandleControls = @{
            TxtSearchHandle   = $txtSearchHandle
            BtnSearchHandle   = $btnSearchHandle
            TxtHandleStatus   = $txtHandleStatus
            GridHandleResults = $gridHandles
        }

        if ($gridHandles) {
            $gridHandles.ItemsSource = $script:FindHandleResultsCol
            $gridHandles.add_MouseDoubleClick({
                param($s, $e)
                $dg = $script:FindHandleControls['GridHandleResults']
                if ($dg -and $dg.SelectedItem) {
                    &$goToProcessInTree
                }
            })
        }

        if ($btnSearchHandle) { $btnSearchHandle.add_Click({ &$executeHandleSearch }) }
        if ($txtSearchHandle) {
            $txtSearchHandle.add_KeyDown({
                param($s, $e)
                if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                    &$executeHandleSearch
                    $e.Handled = $true
                }
            })
        }
        if ($btnCloseHandle) { $btnCloseHandle.add_Click({ &$closeSelectedHandle }) }
        if ($ctxCloseHandle) { $ctxCloseHandle.add_Click({ &$closeSelectedHandle }) }
        if ($btnGoToProcess) { $btnGoToProcess.add_Click({ &$goToProcessInTree }) }
        if ($ctxGoToProcess) { $ctxGoToProcess.add_Click({ &$goToProcessInTree }) }
        if ($btnCopyPath)    { $btnCopyPath.add_Click({ &$copySelectedPath }) }
        if ($ctxCopyPath)    { $ctxCopyPath.add_Click({ &$copySelectedPath }) }
        if ($btnCloseDlg)    { $btnCloseDlg.add_Click({ if ($script:ActiveFindHandleWin) { $script:ActiveFindHandleWin.Close() } }) }

        $findWin.add_KeyDown({
            param($s, $e)
            $dg = $script:FindHandleControls['GridHandleResults']
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                if ($script:ActiveFindHandleWin) {
                    $script:ActiveFindHandleWin.Close()
                }
                $e.Handled = $true
            } elseif ($e.Key -eq [System.Windows.Input.Key]::Delete -and $dg -and $dg.IsKeyboardFocusWithin) {
                &$closeSelectedHandle
                $e.Handled = $true
            } elseif ($e.Key -eq [System.Windows.Input.Key]::Enter -and $dg -and $dg.IsKeyboardFocusWithin) {
                &$goToProcessInTree
                $e.Handled = $true
            }
        })

        $findWin.add_Closed({
            for ($i = $script:FindHandleResultsCol.Count - 1; $i -ge 0; $i--) { $script:FindHandleResultsCol.RemoveAt($i) }
            $script:ActiveFindHandleWin = $null
            $script:FindHandleControls.Clear()
        })

        $findWin.Show()
        if ($txtSearchHandle) {
            [void]$txtSearchHandle.Focus()
        }
    }

    $menuFindHandle     = $window.FindName("MenuFindHandle")
    $btnFindHandleOrDll = $window.FindName("BtnFindHandleOrDll")
    if ($menuFindHandle)     { $menuFindHandle.add_Click({ &$actionShowFindHandle }) }
    if ($btnFindHandleOrDll) { $btnFindHandleOrDll.add_Click({ &$actionShowFindHandle }) }

    # 15B. Opt-In Per-Process Kernel Network Monitoring (ETW) Controls & Banner
    $menuViewNetEtw       = $window.FindName("MenuViewNetEtw")
    $menuColTreeNet       = $window.FindName("MenuColTreeNet")
    $menuColNetRxTx       = $window.FindName("MenuColNetRxTx")
    $btnToolbarNetEtw     = $window.FindName("BtnToolbarNetEtw")
    $ellNetEtwDot         = $window.FindName("EllNetEtwDot")
    $txtNetEtwBtn         = $window.FindName("TxtNetEtwBtn")
    $btnToolbarNetRxTx    = $window.FindName("BtnToolbarNetRxTx")
    $netEtwAlertBanner    = $window.FindName("NetEtwAlertBanner")
    $bdNetEtwBannerBadge  = $window.FindName("BdNetEtwBannerBadge")
    $txtNetEtwBannerBadge = $window.FindName("TxtNetEtwBannerBadge")
    $txtNetEtwBannerMsg   = $window.FindName("TxtNetEtwBannerMsg")
    $btnNetEtwResume      = $window.FindName("BtnNetEtwResume")
    $btnNetEtwTurnOff     = $window.FindName("BtnNetEtwTurnOff")
    $btnNetEtwDismiss     = $window.FindName("BtnNetEtwDismiss")
    $colNetTotal          = $window.FindName("ColNetTotal")
    $colTreeNet           = $window.FindName("ColTreeNet")
    $colNetRx             = $window.FindName("ColNetRx")
    $colNetTx             = $window.FindName("ColNetTx")

    $script:ShowTreeNetCol = $true
    $script:ShowRxTxCols   = $false
    $script:NetBannerDismissedCap = 0

    $syncNetColumnVisibility = {
        $isActive = ([int]$stateContainer.NetEtwCap -eq 1)
        $visMain  = if ($isActive) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $visTree  = if ($isActive -and $script:ShowTreeNetCol) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $visSplit = if ($isActive -and $script:ShowRxTxCols) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }

        if ($colNetTotal) { $colNetTotal.Visibility = $visMain }
        if ($colTreeNet)  { $colTreeNet.Visibility  = $visTree }
        if ($colNetRx)    { $colNetRx.Visibility    = $visSplit }
        if ($colNetTx)    { $colNetTx.Visibility    = $visSplit }

        $curSort = [string]$stateContainer.SortProperty
        if (($curSort -in @("NetTotalBps") -and -not $isActive) -or
            ($curSort -in @("TreeNetTotalBps", "TreeNetRxBps", "TreeNetTxBps") -and -not ($isActive -and $script:ShowTreeNetCol)) -or
            ($curSort -in @("NetRxBps", "NetTxBps") -and -not ($isActive -and $script:ShowRxTxCols))) {
            &$setViewMode $true
        }
    }

    $updateNetEtwUi = {
        param([int]$cap, [int]$evRate)
        if ($script:ActiveHostTab) {
            $script:ActiveHostTab.NetEtwCap = $cap
            $script:ActiveHostTab.NetEtwEventsPerSec = $evRate
            $script:ActiveHostTab.EnableNetEtw = [bool]$stateContainer.EnableNetEtw
        }
        $isEnabled = [bool]$stateContainer.EnableNetEtw
        if ($menuViewNetEtw) { $menuViewNetEtw.IsChecked = $isEnabled }

        if ($ellNetEtwDot -and $txtNetEtwBtn) {
            switch ($cap) {
                1 {
                    $ellNetEtwDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0EA5E9")
                    $txtNetEtwBtn.Text = if ($evRate -gt 0) { "Net ETW ($evRate/s)" } else { "Net ETW: ON" }
                }
                2 {
                    $ellNetEtwDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F59E0B")
                    $txtNetEtwBtn.Text = "Net ETW (Paused)"
                }
                3 {
                    $ellNetEtwDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#64748B")
                    $txtNetEtwBtn.Text = "Net ETW (Admin)"
                }
                default {
                    $ellNetEtwDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
                    $txtNetEtwBtn.Text = if ($isEnabled) { "Net ETW..." } else { "Net ETW" }
                }
            }
        }
        if ($btnToolbarNetRxTx) {
            $btnToolbarNetRxTx.Visibility = if ($cap -eq 1) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }
        if ($menuColTreeNet) { $menuColTreeNet.IsChecked = $script:ShowTreeNetCol }
        if ($menuColNetRxTx) { $menuColNetRxTx.IsChecked = $script:ShowRxTxCols }

        &$syncNetColumnVisibility

        if ($netEtwAlertBanner) {
            if ($cap -eq 0 -or $cap -eq 1) {
                $script:NetBannerDismissedCap = 0
                if ($script:ActiveHostTab) { $script:ActiveHostTab.NetBannerDismissedCap = 0 }
                $netEtwAlertBanner.Visibility = [System.Windows.Visibility]::Collapsed
            } elseif ($script:NetBannerDismissedCap -ne $cap) {
                $bcNet = [System.Windows.Media.BrushConverter]::new()
                $isDarkBanner = [bool]$stateContainer.IsDarkTheme
                $netEtwAlertBanner.Visibility = [System.Windows.Visibility]::Visible
                if ($cap -eq 2) {
                    $netEtwAlertBanner.Background  = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#451A03" } else { "#FEF3C7" }))
                    $netEtwAlertBanner.BorderBrush = $bcNet.ConvertFromString("#F59E0B")
                    if ($bdNetEtwBannerBadge)  { $bdNetEtwBannerBadge.Background = $bcNet.ConvertFromString("#D97706") }
                    if ($txtNetEtwBannerBadge) { $txtNetEtwBannerBadge.Text = "CIRCUIT BREAKER" }
                    if ($txtNetEtwBannerMsg)   {
                        $txtNetEtwBannerMsg.Text = "Per-process Network ETW auto-paused after exceeding 25,000 events/sec ($evRate/s) to protect host CPU. Click Resume to restart."
                        $txtNetEtwBannerMsg.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#FEF3C7" } else { "#0F172A" }))
                    }
                    if ($btnNetEtwResume) {
                        $btnNetEtwResume.Visibility  = [System.Windows.Visibility]::Visible
                        $btnNetEtwResume.Background  = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#1E293B" } else { "#FFFFFF" }))
                        $btnNetEtwResume.Foreground  = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#F8FAFC" } else { "#0F172A" }))
                    }
                    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#FEF3C7" } else { "#0F172A" })) }
                    if ($btnNetEtwDismiss) { $btnNetEtwDismiss.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#FDE68A" } else { "#475569" })) }
                } elseif ($cap -eq 3) {
                    $netEtwAlertBanner.Background  = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#082F49" } else { "#E0F2FE" }))
                    $netEtwAlertBanner.BorderBrush = $bcNet.ConvertFromString("#0284C7")
                    if ($bdNetEtwBannerBadge)  { $bdNetEtwBannerBadge.Background = $bcNet.ConvertFromString("#0284C7") }
                    if ($txtNetEtwBannerBadge) { $txtNetEtwBannerBadge.Text = "TIER 1 FALLBACK" }
                    if ($txtNetEtwBannerMsg)   {
                        $txtNetEtwBannerMsg.Text = "Kernel Network ETW requires Administrators or Performance Log Users on target host. System-wide NET rate remains active."
                        $txtNetEtwBannerMsg.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#E0F2FE" } else { "#0F172A" }))
                    }
                    if ($btnNetEtwResume)  { $btnNetEtwResume.Visibility  = [System.Windows.Visibility]::Collapsed }
                    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#E0F2FE" } else { "#0F172A" })) }
                    if ($btnNetEtwDismiss) { $btnNetEtwDismiss.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#BAE6FD" } else { "#475569" })) }
                } else {
                    $netEtwAlertBanner.Background  = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#450A0A" } else { "#FEE2E2" }))
                    $netEtwAlertBanner.BorderBrush = $bcNet.ConvertFromString("#EF4444")
                    if ($bdNetEtwBannerBadge)  { $bdNetEtwBannerBadge.Background = $bcNet.ConvertFromString("#DC2626") }
                    if ($txtNetEtwBannerBadge) { $txtNetEtwBannerBadge.Text = "ETW UNAVAILABLE" }
                    if ($txtNetEtwBannerMsg)   {
                        $txtNetEtwBannerMsg.Text = "Unable to start Microsoft-Windows-Kernel-Network ETW session on target host."
                        $txtNetEtwBannerMsg.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#FEE2E2" } else { "#0F172A" }))
                    }
                    if ($btnNetEtwResume)  { $btnNetEtwResume.Visibility  = [System.Windows.Visibility]::Collapsed }
                    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#FEE2E2" } else { "#0F172A" })) }
                    if ($btnNetEtwDismiss) { $btnNetEtwDismiss.Foreground = $bcNet.ConvertFromString($(if ($isDarkBanner) { "#FECACA" } else { "#475569" })) }
                }
            } else {
                $netEtwAlertBanner.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }
    $script:UpdateNetEtwUi = $updateNetEtwUi
    $stateContainer.OnNetEtwStateChanged = $updateNetEtwUi

    $setNetEtwEnabled = {
        param([bool]$enable, [bool]$resetBreaker = $false)
        $script:NetBannerDismissedCap = 0
        if ($script:ActiveHostTab) { $script:ActiveHostTab.NetBannerDismissedCap = 0 }
        $stateContainer.EnableNetEtw = $enable
        if (-not $enable) {
            $stateContainer.NetEtwCap = 0
            $stateContainer.NetEtwEventsPerSec = 0
            if ($engineHandle -and $engineHandle.ProcessMap) {
                foreach ($vmNet in $engineHandle.ProcessMap.Values) {
                    $vmNet.UpdateNetwork(0L, 0L)
                    $vmNet.UpdateTreeNetwork(0L, 0L)
                }
            }
        }
        if ($script:ActiveHostTab) { $script:ActiveHostTab.EnableNetEtw = $enable }
        &$updateNetEtwUi $(if ($enable) { if ($stateContainer.NetEtwCap -eq 1) { 1 } else { 0 } } else { 0 }) 0
        if ($engineHandle -and $engineHandle.SendCommand) {
            & $engineHandle.SendCommand @{
                CommandType  = "SetNetEtw"
                Enable       = $enable
                ResetBreaker = $resetBreaker
            } $null
        }
    }

    if ($btnToolbarNetEtw) {
        $btnToolbarNetEtw.add_Click({
            $want = (-not [bool]$stateContainer.EnableNetEtw)
            &$setNetEtwEnabled $want $want
        })
    }
    if ($menuViewNetEtw) {
        $menuViewNetEtw.add_Click({
            $want = [bool]$menuViewNetEtw.IsChecked
            &$setNetEtwEnabled $want $want
        })
    }
    if ($btnToolbarNetRxTx) {
        $btnToolbarNetRxTx.add_Click({
            $script:ShowRxTxCols = (-not $script:ShowRxTxCols)
            if ($menuColNetRxTx) { $menuColNetRxTx.IsChecked = $script:ShowRxTxCols }
            &$syncNetColumnVisibility
        })
    }
    if ($menuColNetRxTx) {
        $menuColNetRxTx.add_Click({
            $script:ShowRxTxCols = [bool]$menuColNetRxTx.IsChecked
            &$syncNetColumnVisibility
        })
    }
    if ($menuColTreeNet) {
        $menuColTreeNet.add_Click({
            $script:ShowTreeNetCol = [bool]$menuColTreeNet.IsChecked
            &$syncNetColumnVisibility
        })
    }
    if ($btnNetEtwResume)  { $btnNetEtwResume.add_Click({ &$setNetEtwEnabled $true $true }) }
    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.add_Click({ &$setNetEtwEnabled $false $true }) }
    if ($btnNetEtwDismiss) {
        $btnNetEtwDismiss.add_Click({
            $script:NetBannerDismissedCap = [int]$stateContainer.NetEtwCap
            if ($script:ActiveHostTab) { $script:ActiveHostTab.NetBannerDismissedCap = [int]$stateContainer.NetEtwCap }
            if ($netEtwAlertBanner) { $netEtwAlertBanner.Visibility = [System.Windows.Visibility]::Collapsed }
        })
    }

    # 16. Global Keyboard Accelerators
    $window.add_PreviewKeyDown({
        param($sender, $e)
        $mods = [System.Windows.Input.Keyboard]::Modifiers
        $isCtrl  = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        $isShift = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0

        if ($e.Key -eq [System.Windows.Input.Key]::F1) {
            &$actionShowHelp 0
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::F5) {
            &$triggerImmediateRefresh
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Space -and -not $txtSearch.IsKeyboardFocusWithin -and -not ($txtSearchServices -and $txtSearchServices.IsKeyboardFocusWithin)) {
            &$setPollingRate $stateContainer.IntervalMs (-not [bool]$stateContainer.IsPaused)
            $e.Handled = $true
        } elseif ($isCtrl -and $isShift -and $e.Key -eq [System.Windows.Input.Key]::N) {
            $want = (-not [bool]$stateContainer.EnableNetEtw)
            &$setNetEtwEnabled $want $want
            $e.Handled = $true
        } elseif ($isCtrl -and $isShift -and $e.Key -eq [System.Windows.Input.Key]::F) {
            &$actionShowFindHandle
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::F) {
            $mainTabs = $window.FindName("MainTabControl")
            if ($mainTabs -and $mainTabs.SelectedIndex -eq 1 -and $txtSearchServices) {
                $txtSearchServices.Focus()
                $txtSearchServices.SelectAll()
            } elseif ($txtSearch) {
                $txtSearch.Focus()
                $txtSearch.SelectAll()
            }
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            if ($txtSearchServices -and ($txtSearchServices.Text.Length -gt 0 -or $txtSearchServices.IsKeyboardFocusWithin)) {
                $txtSearchServices.Text = ""
                &$updateServicesFilter
                $gridServices.Focus()
                $e.Handled = $true
            } elseif ($txtSearch -and ($txtSearch.Text.Length -gt 0 -or $txtSearch.IsKeyboardFocusWithin)) {
                $txtSearch.Text = ""
                $stateContainer.FilterText = ""
                & $engineHandle.RefreshTree
                $gridProcesses.Focus()
                $e.Handled = $true
            }
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::T) {
            &$setViewMode (-not [bool]$stateContainer.IsTreeMode)
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::D) {
            &$cycleTheme
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::L) {
            &$toggleLogPane
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::I) {
            &$actionShowSystemInfo 0
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::K) {
            if ($isShift) {
                &$actionConnectDialog $true
            } else {
                &$actionConnectDialog $false
            }
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::W) {
            &$actionCloseHostTab $script:ActiveHostTab
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::Tab) {
            if ($isShift) {
                &$cycleHostTab -1
            } else {
                &$cycleHostTab 1
            }
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::S) {
            &$exportSnapshot "CSV"
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Left -and -not $txtSearch.IsKeyboardFocusWithin -and -not ($txtSearchServices -and $txtSearchServices.IsKeyboardFocusWithin) -and $stateContainer.IsTreeMode) {
            $sel = $gridProcesses.SelectedItem
            if ($sel) {
                if (($sel.HasChildren -or $sel.Children.Count -gt 0) -and $sel.IsExpanded) {
                    $sel.IsExpanded = $false
                    $sel.UpdateExpanderGeometry()
                    & $engineHandle.RefreshTree
                    $e.Handled = $true
                } elseif ($sel.ParentPID -gt 0 -and $engineHandle.ProcessMap.ContainsKey($sel.ParentPID)) {
                    $parentVm = $engineHandle.ProcessMap[$sel.ParentPID]
                    $gridProcesses.SelectedItem = $parentVm
                    $gridProcesses.ScrollIntoView($parentVm)
                    $e.Handled = $true
                }
            }
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Right -and -not $txtSearch.IsKeyboardFocusWithin -and -not ($txtSearchServices -and $txtSearchServices.IsKeyboardFocusWithin) -and $stateContainer.IsTreeMode) {
            $sel = $gridProcesses.SelectedItem
            if ($sel -and ($sel.HasChildren -or $sel.Children.Count -gt 0)) {
                if (-not $sel.IsExpanded) {
                    $sel.IsExpanded = $true
                    $sel.UpdateExpanderGeometry()
                    & $engineHandle.RefreshTree
                    $e.Handled = $true
                } elseif ($sel.Children.Count -gt 0) {
                    $firstChild = $sel.Children[0]
                    $gridProcesses.SelectedItem = $firstChild
                    $gridProcesses.ScrollIntoView($firstChild)
                    $e.Handled = $true
                }
            }
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Delete -and -not $txtSearch.IsKeyboardFocusWithin -and -not ($txtSearchServices -and $txtSearchServices.IsKeyboardFocusWithin)) {
            if ($isShift) {
                &$invokeProcessAction "KillTree" $null
            } else {
                &$invokeProcessAction "KillProcess" $null
            }
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Return -and $gridProcesses.IsKeyboardFocusWithin) {
            &$actionShowProperties
            $e.Handled = $true
        }
    })

    # 17. Deterministic Teardown on Window Close
    $window.add_Closed({
        try {
            $stateContainer.EnableNetEtw = $false
            $stateContainer.IsStopping = $true
            if ($stateContainer.WakeEvent) {
                try { [void]$stateContainer.WakeEvent.Set() } catch {}
            }
            if ($engineHandle.Timer) { $engineHandle.Timer.Stop() }
            if ($engineHandle.Handle -and $engineHandle.Handle.AsyncWaitHandle) {
                if ($engineHandle.Handle.AsyncWaitHandle.WaitOne(2500)) {
                    try { [void]$engineHandle.PowerShell.EndInvoke($engineHandle.Handle) } catch {}
                }
            }
        } catch {}
        finally {
            if ($LocalOnly -and ('PSRPM.EtwNetConsumerV1' -as [type])) {
                try {
                    [PSRPM.EtwNetConsumerV1]::Active = 0
                    $th = [PSRPM.EtwNetConsumerV1]::ActiveTraceHandle
                    if ($th -ne [uint64]::MaxValue -and $th -ne [uint64]0) {
                        [void][PSRPM.EtwNetConsumerV1]::CloseTrace($th)
                    }
                    $pb = 112 + [IntPtr]::Size
                    $pt = $pb + 512
                    $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($pt)
                    for ($zi = 0; $zi -lt $pt; $zi += 8) { [System.Runtime.InteropServices.Marshal]::WriteInt64($ptr, $zi, 0L) }
                    [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 0, $pt)
                    [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 44, 0x00020000)
                    [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 108 + [IntPtr]::Size, $pb)
                    [void][PSRPM.EtwNetConsumerV1]::ControlTraceW([uint64]0, "PSRPM_NetMon_$PID", $ptr, [uint32]1)
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
                } catch {}
            }
            try { if ($engineHandle.PowerShell) { $engineHandle.PowerShell.Dispose() } } catch {}
            try {
                if ($engineHandle.Runspace) {
                    $engineHandle.Runspace.Close()
                    $engineHandle.Runspace.Dispose()
                }
            } catch {}
            try {
                if ($stateContainer.WakeEvent) {
                    $stateContainer.WakeEvent.Dispose()
                }
            } catch {}
            if ($session) {
                try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch {}
            }
            $script:UpdateNetEtwUi = $null
            $script:ActiveHostTab  = $null
        }
    })

    [void]$window.ShowDialog()
}

function Start-RemoteProcessManager {
    <#
    .SYNOPSIS
        Alias wrapper for Start-PSRPM (backward-compatible with PSRTM command naming).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false)]
        [string]$ComputerName = "localhost",

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $false)]
        [int]$Port = 0,

        [Parameter(Mandatory = $false)]
        [switch]$UseSSL,

        [Parameter(Mandatory = $false)]
        [ValidateRange(250, 60000)]
        [int]$RefreshIntervalMs = 1000,

        [Parameter(Mandatory = $false)]
        [Alias("Local")]
        [switch]$LocalOnly,

        [Parameter(Mandatory = $false)]
        [Alias("Background")]
        [switch]$NoWait,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Light", "Dark", "Classic", "HighContrast")]
        [string]$Theme,

        [Parameter(Mandatory = $false)]
        [switch]$Dark,

        [Parameter(Mandatory = $false)]
        [string]$IconPath
    )
    Start-PSRPM @PSBoundParameters
}

Set-Alias -Name psrpm -Value Start-PSRPM -Scope Global -ErrorAction SilentlyContinue
Export-ModuleMember -Function Start-PSRPM, Start-RemoteProcessManager -Alias psrpm
