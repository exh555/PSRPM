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
$script:AppVersion = "1.13.0"
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
        - Clicking the 'Process' column (SortMemberPath 'Name') cycles through 4 views:
          Tree View (Newest First) -> Tree View (Classic Oldest First) -> Flat Ascending -> Flat Descending -> Tree View (Newest First).
        - Clicking any other column auto-switches from Tree View to Flat View and toggles Asc/Desc.
    #>
    param(
        [bool]$IsTreeMode,
        [bool]$CurrentTreeNewestFirst = $false,
        [string]$CurrentSortProperty,
        [bool]$CurrentSortDescending,
        [string]$ClickedSortProperty
    )

    if ([string]::IsNullOrWhiteSpace($ClickedSortProperty)) {
        $ClickedSortProperty = "PID"
    }

    if ($ClickedSortProperty -eq "Name") {
        if ($IsTreeMode) {
            if ($CurrentTreeNewestFirst) {
                return @{
                    IsTreeMode          = $true
                    TreeSortNewestFirst = $false
                    SortProperty        = "PID"
                    SortDescending      = $false
                }
            }
            return @{
                IsTreeMode          = $false
                TreeSortNewestFirst = $false
                SortProperty        = "Name"
                SortDescending      = $false
            }
        }
        if ($CurrentSortProperty -ne "Name") {
            return @{
                IsTreeMode          = $false
                TreeSortNewestFirst = $CurrentTreeNewestFirst
                SortProperty        = "Name"
                SortDescending      = $false
            }
        }
        if (-not $CurrentSortDescending) {
            return @{
                IsTreeMode          = $false
                TreeSortNewestFirst = $CurrentTreeNewestFirst
                SortProperty        = "Name"
                SortDescending      = $true
            }
        }
        return @{
            IsTreeMode          = $true
            TreeSortNewestFirst = $true
            SortProperty        = "PID"
            SortDescending      = $false
        }
    }

    $defaultDescending = $ClickedSortProperty -in @("CPU", "TreeCPU", "NetTotalBps", "TreeNetTotalBps", "NetRxBps", "NetTxBps", "PrivateBytes", "MemoryBytes", "Handles", "Threads", "CreateTime")
    if ($IsTreeMode -or $CurrentSortProperty -ne $ClickedSortProperty) {
        return @{
            IsTreeMode          = $false
            TreeSortNewestFirst = $CurrentTreeNewestFirst
            SortProperty        = $ClickedSortProperty
            SortDescending      = $defaultDescending
        }
    }

    return @{
        IsTreeMode          = $false
        TreeSortNewestFirst = $CurrentTreeNewestFirst
        SortProperty        = $ClickedSortProperty
        SortDescending      = (-not $CurrentSortDescending)
    }
}

$script:PSRPMPreferencesPathOverride = $null

function Get-PSRPMPreferencesPath {
    param([string]$CustomPath)
    if (-not [string]::IsNullOrWhiteSpace($CustomPath)) {
        return $CustomPath
    }
    if (-not [string]::IsNullOrWhiteSpace($script:PSRPMPreferencesPathOverride)) {
        return $script:PSRPMPreferencesPathOverride
    }
    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = $env:LOCALAPPDATA
    }
    if ([string]::IsNullOrWhiteSpace($localAppData) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $localAppData = Join-Path $env:USERPROFILE "AppData\Local"
    }
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        return $null
    }
    return (Join-Path (Join-Path $localAppData "PSRPM") "preferences.json")
}

function Get-PSRPMColumnCatalog {
    return @(
        @{ Key = "Process";        ControlName = "ColProcess";      Header = "Process";        Group = "Identity";    Hint = "Process tree hierarchy, icon, and image name";          SortProp = "Name";            DefaultVisible = $true;  DefaultWidth = 270.0; IsLocked = $true;  IsNetEtw = $false }
        @{ Key = "CPU";            ControlName = "ColCpu";          Header = "CPU";            Group = "Performance"; Hint = "Own process CPU utilization percentage";               SortProp = "CPU";             DefaultVisible = $true;  DefaultWidth = 70.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "TreeCPU";        ControlName = "ColTreeCpu";      Header = "Tree CPU Usage"; Group = "Performance"; Hint = "Aggregate CPU usage across process and descendants";    SortProp = "TreeCPU";         DefaultVisible = $true;  DefaultWidth = 104.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "NetTotal";       ControlName = "ColNetTotal";     Header = "Network";        Group = "Network ETW"; Hint = "Combined live network throughput (requires Net ETW)";    SortProp = "NetTotalBps";     DefaultVisible = $false; DefaultWidth = 94.0;  IsLocked = $false; IsNetEtw = $true }
        @{ Key = "TreeNet";        ControlName = "ColTreeNet";      Header = "Tree Net";       Group = "Network ETW"; Hint = "Aggregate network rate across subtree (requires ETW)";   SortProp = "TreeNetTotalBps"; DefaultVisible = $false; DefaultWidth = 94.0;  IsLocked = $false; IsNetEtw = $true }
        @{ Key = "NetRx";          ControlName = "ColNetRx";        Header = "Net Recv";       Group = "Network ETW"; Hint = "Inbound network receive rate (requires Net ETW)";        SortProp = "NetRxBps";        DefaultVisible = $false; DefaultWidth = 94.0;  IsLocked = $false; IsNetEtw = $true }
        @{ Key = "NetTx";          ControlName = "ColNetTx";        Header = "Net Send";       Group = "Network ETW"; Hint = "Outbound network send rate (requires Net ETW)";          SortProp = "NetTxBps";        DefaultVisible = $false; DefaultWidth = 94.0;  IsLocked = $false; IsNetEtw = $true }
        @{ Key = "PrivateBytes";   ControlName = "ColPrivateBytes";    Header = "Private Bytes";  Group = "Performance"; Hint = "Committed private virtual memory bytes";                SortProp = "PrivateBytes";      DefaultVisible = $true;  DefaultWidth = 98.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "WorkingSet";     ControlName = "ColWorkingSet";      Header = "Working Set";    Group = "Performance"; Hint = "Physical RAM currently resident in process";             SortProp = "MemoryBytes";       DefaultVisible = $true;  DefaultWidth = 98.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "PeakCPU";        ControlName = "ColPeakCpu";         Header = "Peak CPU";       Group = "Performance"; Hint = "Highest own CPU percentage observed during session";       SortProp = "PeakCPU";           DefaultVisible = $false; DefaultWidth = 76.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "PeakPrivate";    ControlName = "ColPeakPrivate";     Header = "Peak Private";   Group = "Performance"; Hint = "Highest Private Bytes observed during session";          SortProp = "PeakPrivateBytes";  DefaultVisible = $false; DefaultWidth = 102.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "CPUDelta";       ControlName = "ColCpuDelta";        Header = "CPU Delta";      Group = "Performance"; Hint = "Signed own CPU percentage change since baseline (Ctrl+B)"; SortProp = "CPUDelta";        DefaultVisible = $false; DefaultWidth = 78.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "PrivateDelta";   ControlName = "ColPrivateDelta";    Header = "Private Delta";  Group = "Performance"; Hint = "Signed Private Bytes change since baseline (Ctrl+B)";    SortProp = "PrivateBytesDelta"; DefaultVisible = $false; DefaultWidth = 102.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "WSDelta";        ControlName = "ColWorkingSetDelta"; Header = "WS Delta";       Group = "Performance"; Hint = "Signed Working Set change since baseline (Ctrl+B)";      SortProp = "MemoryDelta";       DefaultVisible = $false; DefaultWidth = 98.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "PID";            ControlName = "ColPid";          Header = "PID";            Group = "Identity";    Hint = "Windows numeric process identifier";                     SortProp = "PID";             DefaultVisible = $true;  DefaultWidth = 62.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "ParentPID";      ControlName = "ColParentPid";    Header = "Parent PID";     Group = "Identity";    Hint = "Creator parent process identifier";                      SortProp = "ParentPID";       DefaultVisible = $false; DefaultWidth = 78.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Description";    ControlName = "ColDescription";  Header = "Description";    Group = "Image";       Hint = "PE FileDescription or hosted Windows services";          SortProp = "Description";     DefaultVisible = $true;  DefaultWidth = 240.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "CompanyName";    ControlName = "ColCompanyName";  Header = "Company Name";   Group = "Image";       Hint = "Executable publisher / vendor from version resource";    SortProp = "CompanyName";     DefaultVisible = $true;  DefaultWidth = 165.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Version";        ControlName = "ColVersion";      Header = "Version";        Group = "Image";       Hint = "Executable FileVersion string";                          SortProp = "FileVersion";     DefaultVisible = $false; DefaultWidth = 105.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "CommandLine";    ControlName = "ColCommandLine";  Header = "Command Line";   Group = "Image";       Hint = "Full process launch command line arguments";             SortProp = "CommandLine";     DefaultVisible = $false; DefaultWidth = 280.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Path";           ControlName = "ColPath";         Header = "Image Path";     Group = "Image";       Hint = "Full on-disk executable image path";                     SortProp = "Path";            DefaultVisible = $false; DefaultWidth = 240.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "User";           ControlName = "ColUser";         Header = "User";           Group = "Identity";    Hint = "Security token owner (DOMAIN\Account)";                 SortProp = "User";            DefaultVisible = $true;  DefaultWidth = 145.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Handles";        ControlName = "ColHandles";      Header = "Handles";        Group = "Performance"; Hint = "Open kernel object handle count";                        SortProp = "Handles";         DefaultVisible = $true;  DefaultWidth = 72.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Threads";        ControlName = "ColThreads";      Header = "Threads";        Group = "Performance"; Hint = "Active OS thread count";                                 SortProp = "Threads";         DefaultVisible = $false; DefaultWidth = 68.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "SessionId";      ControlName = "ColSessionId";    Header = "Session";        Group = "Identity";    Hint = "Terminal Services / Windows logon session ID";           SortProp = "SessionId";       DefaultVisible = $false; DefaultWidth = 64.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "BasePriority";   ControlName = "ColBasePriority"; Header = "Base Priority";  Group = "Performance"; Hint = "Kernel base scheduling priority class";                  SortProp = "BasePriority";    DefaultVisible = $false; DefaultWidth = 88.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Architecture";   ControlName = "ColArchitecture"; Header = "Architecture";   Group = "Identity";    Hint = "Process binary bitness (x64 or x86)";                    SortProp = "Architecture";    DefaultVisible = $false; DefaultWidth = 78.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "StartTime";      ControlName = "ColStartTime";    Header = "Start Time";     Group = "Identity";    Hint = "Local timestamp when process started (sorts by age)";     SortProp = "CreateTime";      DefaultVisible = $false; DefaultWidth = 135.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Status";         ControlName = "ColStatus";       Header = "Status";         Group = "Identity";    Hint = "Execution state (Running or Suspended)";                 SortProp = "Status";          DefaultVisible = $false; DefaultWidth = 82.0;  IsLocked = $false; IsNetEtw = $false }
        @{ Key = "HostedServices"; ControlName = "ColServices";     Header = "Services";       Group = "Image";       Hint = "Windows services hosted inside this process";            SortProp = "HostedServices";  DefaultVisible = $false; DefaultWidth = 180.0; IsLocked = $false; IsNetEtw = $false }
        @{ Key = "Category";       ControlName = "ColCategory";     Header = "Category";       Group = "Identity";    Hint = "Semantic group (Own, Service, Packaged, System)";        SortProp = "Category";        DefaultVisible = $false; DefaultWidth = 82.0;  IsLocked = $false; IsNetEtw = $false }
    )
}

function Get-PSRPMDefaultPreferences {
    $catalog = Get-PSRPMColumnCatalog
    $defVis  = @($catalog | Where-Object { $_.DefaultVisible } | ForEach-Object { $_.Key })
    $defOrd  = @($catalog | ForEach-Object { $_.Key })
    return @{
        Theme                    = "Light"
        AlwaysOnTop              = $false
        EnableCategoryHighlights = $true
        ConfirmKill              = $true
        VerboseTelemetryLog      = $true
        IsTreeMode               = $true
        TreeSortNewestFirst      = $true
        SortProperty             = "PID"
        SortDescending           = $false
        RefreshIntervalMs        = 1000
        LogPaneVisible           = $false
        LogPaneHeight            = 175.0
        LogAutoScroll            = $true
        VisibleColumns           = $defVis
        ColumnOrder              = $defOrd
        ColumnWidths             = @{}
    }
}

function Read-PSRPMPreferences {
    param(
        [string]$Path,
        [switch]$UseDefaults
    )
    $defaults   = Get-PSRPMDefaultPreferences
    $targetPath = Get-PSRPMPreferencesPath -CustomPath $Path
    $result     = @{
        Preferences    = $defaults
        LoadedFromDisk = $false
        HadParseError  = $false
        SkippedDisk    = [bool]$UseDefaults
        Path           = $targetPath
    }
    if ([bool]$UseDefaults -or [string]::IsNullOrWhiteSpace($targetPath) -or -not [System.IO.File]::Exists($targetPath)) {
        return $result
    }

    try {
        $rawJson = [System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            $result.HadParseError = $true
            return $result
        }
        $parsed = ConvertFrom-Json -InputObject $rawJson -ErrorAction Stop
        if ($null -eq $parsed) {
            $result.HadParseError = $true
            return $result
        }

        $allowedThemes = @("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")
        if ($null -ne $parsed.PSObject.Properties['Theme']) {
            $tVal = [string]$parsed.Theme
            if ($tVal -in $allowedThemes) {
                $defaults.Theme = $tVal
            }
        }

        foreach ($boolKey in @("AlwaysOnTop", "EnableCategoryHighlights", "ConfirmKill", "VerboseTelemetryLog", "IsTreeMode", "TreeSortNewestFirst", "SortDescending", "LogPaneVisible", "LogAutoScroll")) {
            if ($null -ne $parsed.PSObject.Properties[$boolKey] -and $null -ne $parsed.$boolKey) {
                if ($parsed.$boolKey -is [bool]) {
                    $defaults[$boolKey] = [bool]$parsed.$boolKey
                } elseif ([string]$parsed.$boolKey -match '^(true|1)$') {
                    $defaults[$boolKey] = $true
                } elseif ([string]$parsed.$boolKey -match '^(false|0)$') {
                    $defaults[$boolKey] = $false
                }
            }
        }

        $allowedSortProps = @("Name", "PID", "ParentPID", "CPU", "TreeCPU", "CPUDelta", "NetTotalBps", "TreeNetTotalBps", "NetRxBps", "NetTxBps", "PrivateBytes", "MemoryBytes", "PeakCPU", "PeakPrivateBytes", "PrivateBytesDelta", "MemoryDelta", "Status", "Handles", "Threads", "SessionId", "BasePriority", "Architecture", "CreateTime", "Category", "User", "HostedServices", "CompanyName", "Description", "FileVersion", "CommandLine", "Path")
        if ($null -ne $parsed.PSObject.Properties['SortProperty']) {
            $sProp = [string]$parsed.SortProperty
            if ($sProp -in $allowedSortProps) {
                $defaults.SortProperty = $sProp
            }
        }

        $catalog = Get-PSRPMColumnCatalog
        $validColKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($cDef in $catalog) { [void]$validColKeys.Add([string]$cDef.Key) }

        if ($null -ne $parsed.PSObject.Properties['VisibleColumns'] -and $null -ne $parsed.VisibleColumns) {
            $visSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $visList = [System.Collections.Generic.List[string]]::new()
            [void]$visSeen.Add("Process")
            $visList.Add("Process")
            foreach ($vc in @($parsed.VisibleColumns)) {
                $vcKey = [string]$vc
                if ($validColKeys.Contains($vcKey) -and $visSeen.Add($vcKey)) {
                    $visList.Add($vcKey)
                }
            }
            $defaults.VisibleColumns = @($visList)
        }

        if ($null -ne $parsed.PSObject.Properties['ColumnOrder'] -and $null -ne $parsed.ColumnOrder) {
            $ordSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $ordList = [System.Collections.Generic.List[string]]::new()
            [void]$ordSeen.Add("Process")
            $ordList.Add("Process")
            foreach ($oc in @($parsed.ColumnOrder)) {
                $ocKey = [string]$oc
                if ($validColKeys.Contains($ocKey) -and $ordSeen.Add($ocKey)) {
                    $ordList.Add($ocKey)
                }
            }
            foreach ($cDef in $catalog) {
                if ($ordSeen.Add([string]$cDef.Key)) {
                    $ordList.Add([string]$cDef.Key)
                }
            }
            $defaults.ColumnOrder = @($ordList)
        }

        if ($null -ne $parsed.PSObject.Properties['ColumnWidths'] -and $null -ne $parsed.ColumnWidths) {
            $cleanWidths = @{}
            if ($parsed.ColumnWidths -is [System.Collections.IDictionary]) {
                foreach ($wk in $parsed.ColumnWidths.Keys) {
                    $wKey = [string]$wk
                    if ($validColKeys.Contains($wKey)) {
                        $wNum = 0.0
                        if ([double]::TryParse([string]$parsed.ColumnWidths[$wk], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$wNum)) {
                            if ($wNum -ge 40.0 -and $wNum -le 1200.0) {
                                $cleanWidths[$wKey] = [Math]::Round($wNum, 1)
                            }
                        }
                    }
                }
            } else {
                foreach ($wp in $parsed.ColumnWidths.PSObject.Properties) {
                    $wKey = [string]$wp.Name
                    if ($validColKeys.Contains($wKey)) {
                        $wNum = 0.0
                        if ([double]::TryParse([string]$wp.Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$wNum)) {
                            if ($wNum -ge 40.0 -and $wNum -le 1200.0) {
                                $cleanWidths[$wKey] = [Math]::Round($wNum, 1)
                            }
                        }
                    }
                }
            }
            $defaults.ColumnWidths = $cleanWidths
        }

        if ($null -ne $parsed.PSObject.Properties['RefreshIntervalMs'] -and $null -ne $parsed.RefreshIntervalMs) {
            $rMs = 0
            if ([int]::TryParse([string]$parsed.RefreshIntervalMs, [ref]$rMs)) {
                if ($rMs -ge 250 -and $rMs -le 60000) {
                    $defaults.RefreshIntervalMs = $rMs
                }
            }
        }

        if ($null -ne $parsed.PSObject.Properties['LogPaneHeight'] -and $null -ne $parsed.LogPaneHeight) {
            $lHeight = 0.0
            if ([double]::TryParse([string]$parsed.LogPaneHeight, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lHeight)) {
                if ($lHeight -ge 85.0 -and $lHeight -le 1200.0) {
                    $defaults.LogPaneHeight = [Math]::Round($lHeight, 1)
                }
            }
        }

        $result.LoadedFromDisk = $true
        return $result
    } catch {
        $result.Preferences   = Get-PSRPMDefaultPreferences
        $result.HadParseError = $true
        return $result
    }
}

function Save-PSRPMPreferences {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Preferences,
        [string]$Path
    )
    $targetPath = Get-PSRPMPreferencesPath -CustomPath $Path
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        throw "Unable to resolve local application data path for PSRPM preferences."
    }
    $parentDir = [System.IO.Path]::GetDirectoryName($targetPath)
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not [System.IO.Directory]::Exists($parentDir)) {
        [void][System.IO.Directory]::CreateDirectory($parentDir)
    }

    $visColsSave = if ($Preferences.ContainsKey('VisibleColumns') -and $Preferences.VisibleColumns) { @($Preferences.VisibleColumns) } else { @((Get-PSRPMDefaultPreferences).VisibleColumns) }
    $colOrdSave  = if ($Preferences.ContainsKey('ColumnOrder') -and $Preferences.ColumnOrder) { @($Preferences.ColumnOrder) } else { @((Get-PSRPMDefaultPreferences).ColumnOrder) }
    $colWidSave  = if ($Preferences.ContainsKey('ColumnWidths') -and $Preferences.ColumnWidths -is [System.Collections.IDictionary]) { $Preferences.ColumnWidths } else { @{} }

    $ordered = [ordered]@{
        Theme                    = [string]$Preferences.Theme
        AlwaysOnTop              = [bool]$Preferences.AlwaysOnTop
        EnableCategoryHighlights = [bool]$Preferences.EnableCategoryHighlights
        ConfirmKill              = [bool]$Preferences.ConfirmKill
        VerboseTelemetryLog      = [bool]$Preferences.VerboseTelemetryLog
        IsTreeMode               = [bool]$Preferences.IsTreeMode
        TreeSortNewestFirst      = [bool]$Preferences.TreeSortNewestFirst
        SortProperty             = [string]$Preferences.SortProperty
        SortDescending           = [bool]$Preferences.SortDescending
        RefreshIntervalMs        = [int]$Preferences.RefreshIntervalMs
        LogPaneVisible           = [bool]$Preferences.LogPaneVisible
        LogPaneHeight            = [Math]::Round([double]$Preferences.LogPaneHeight, 1)
        LogAutoScroll            = [bool]$Preferences.LogAutoScroll
        VisibleColumns           = $visColsSave
        ColumnOrder              = $colOrdSave
        ColumnWidths             = $colWidSave
    }

    $jsonText  = ConvertTo-Json -InputObject $ordered -Depth 4
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $tmpPath   = "$targetPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $jsonText, $utf8NoBom)
    [System.IO.File]::Copy($tmpPath, $targetPath, $true)
    try { [System.IO.File]::Delete($tmpPath) } catch {}
    return $targetPath
}

function Reset-PSRPMPreferences {
    param([string]$Path)
    $targetPath = Get-PSRPMPreferencesPath -CustomPath $Path
    if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
        $tmpPath = "$targetPath.tmp"
        if ([System.IO.File]::Exists($tmpPath)) {
            try { [System.IO.File]::Delete($tmpPath) } catch {}
        }
        if ([System.IO.File]::Exists($targetPath)) {
            [System.IO.File]::Delete($targetPath)
            return $true
        }
    }
    return $false
}

function Start-PSRPM {
    <#
    .SYNOPSIS
        Launches PowerShell Remote Process Manager (PSRPM) with a real-time hierarchical Tree-Grid UI.
    .DESCRIPTION
        Launches PSRPM locally by default (zero WinRM or Administrator prerequisites when invoked
        without -ComputerName), or connects to a remote Windows computer via WinRM (-ComputerName)
        with near-zero remote CPU/memory footprint (<2-5ms per tick via native NtQuerySystemInformation
        and differential GZIP JSON telemetry).
        By default, PSRPM launches in an isolated background STA runspace so your terminal prompt
        remains unlocked; pass -Wait to run synchronously until the window closes.
    .PARAMETER ComputerName
        Target remote hostname or IP address for WinRM mode. When omitted (along with -Credential,
        -Port, and -UseSSL), PSRPM starts in Local-Only Mode automatically. Passing '-ComputerName localhost'
        explicitly tests/connects over WinRM loopback unless -LocalOnly is also specified.
    .PARAMETER Credential
        Optional PSCredential for authenticating the WinRM PSSession.
    .PARAMETER Port
        Optional custom WinRM port (defaults to 5985 for HTTP or 5986 for SSL).
    .PARAMETER UseSSL
        Use HTTPS transport for the WinRM PSSession.
    .PARAMETER RefreshIntervalMs
        Telemetry polling interval in milliseconds (250 to 60000). Defaults to 1000ms.
    .PARAMETER LocalOnly
        Force execution directly in the local PowerShell process without creating a WinRM PSSession.
        Also active automatically when Start-PSRPM is called with no remote connection parameters.
    .PARAMETER Wait
        Block the calling PowerShell terminal synchronously until the PSRPM window closes.
        By default, PSRPM launches in a background STA runspace and returns the prompt immediately.
    .PARAMETER NoWait
        Legacy switch retained for backwards compatibility (non-blocking background launch is now
        the default whenever -Wait is omitted). Alias: -Background.
    .PARAMETER Defaults
        Skip loading saved preferences from %LOCALAPPDATA%\PSRPM\preferences.json for this session
        and start with built-in factory defaults (saved config on disk is left untouched).
        Aliases: -Default, -NoConfig, -NoPreferences.
    .EXAMPLE
        Start-PSRPM
    .EXAMPLE
        Start-PSRPM -ComputerName "SRV-PROD-01" -Credential (Get-Credential)
    .EXAMPLE
        Start-PSRPM -LocalOnly
    .EXAMPLE
        Start-PSRPM -LocalOnly -Wait
    .EXAMPLE
        Start-PSRPM -Defaults
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
        [switch]$Wait,

        [Parameter(Mandatory = $false)]
        [Alias("Background")]
        [switch]$NoWait,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")]
        [string]$Theme = "Light",

        [Parameter(Mandatory = $false)]
        [switch]$Dark,

        [Parameter(Mandatory = $false)]
        [Alias("Topmost")]
        [switch]$AlwaysOnTop,

        [Parameter(Mandatory = $false)]
        [string]$IconPath,

        [Parameter(Mandatory = $false)]
        [Alias("Default", "NoConfig", "NoPreferences")]
        [switch]$Defaults
    )

    $hasExplicitWinRmTarget = $PSBoundParameters.ContainsKey("ComputerName") -or
        $PSBoundParameters.ContainsKey("Credential") -or
        ($Port -gt 0) -or
        [bool]$UseSSL
    $isLocalMode = [bool]$LocalOnly -or (-not $hasExplicitWinRmTarget)
    $session = $null
    $targetLabel = if ($isLocalMode) { $env:COMPUTERNAME } else { $ComputerName }

    # 0. Set Explicit AppUserModelID to prevent Windows Taskbar from grouping under powershell.exe
    try {
        if (([System.Management.Automation.PSTypeName]'PSRPM.Shell32Native').Type) {
            [void][PSRPM.Shell32Native]::SetCurrentProcessExplicitAppUserModelID("PSRPM.RemoteProcessManager.1.0")
        }
    } catch {}

    # Launch in an isolated STA background runspace by default so the terminal stays unlocked; pass -Wait to block until closed
    if (-not [bool]$Wait) {
        $bound = @{}
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -notin @("Wait", "NoWait", "Background")) {
                $bound[$k] = $PSBoundParameters[$k]
            }
        }
        $bound["Wait"] = $true

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

        Write-Host "[PSRPM] Launched in background (Target: $targetLabel). Terminal remains unlocked (use -Wait to block)." -ForegroundColor Green
        return
    }

    # 1. Establish Persistent Remote PSSession (when WinRM parameters are explicitly supplied)
    if (-not $isLocalMode) {
        try {
            Write-Host "[PSRPM] Connecting to '$ComputerName' via WinRM..." -ForegroundColor Cyan
            $so = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000 -CancelTimeout 5000 -NoMachineProfile
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
                    "Could not establish a WinRM loopback session to '$ComputerName':`n`n$errMsg`n`nWould you like to continue in Local-Only Mode (zero WinRM/Admin required)?`nTip: Running 'Start-PSRPM' without -ComputerName starts in Local-Only Mode automatically.",
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
                    "Failed to connect to remote computer '$ComputerName' via WinRM:`n`n$errMsg`n`nTip: Launch without -ComputerName (or pass -LocalOnly) for Local-Only Mode, then use File -> Connect to Remote Computer.",
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
    $selectColsXamlPath = Join-Path $uiDir "SelectColumnsWindow.xaml"

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
            $icoBytes = [System.IO.File]::ReadAllBytes($resolvedIconPath)
            $msIco = [System.IO.MemoryStream]::new($icoBytes)
            $appIconFrame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                $msIco,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            )
            $appIconFrame.Freeze()
            $msIco.Close()
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
            $ts = (Get-Date).ToString("HH:mm:ss.fff")
            $lineStr = "[$ts] [$category] $message`r`n"
            $autoScrollOn = if ($null -ne $stateContainer -and $stateContainer.ContainsKey('LogAutoScroll')) {
                [bool]$stateContainer.LogAutoScroll -and (($txtLogConsole.ViewportHeight -le 0) -or ($txtLogConsole.ExtentHeight -le $txtLogConsole.ViewportHeight) -or (($txtLogConsole.VerticalOffset + $txtLogConsole.ViewportHeight) -ge ($txtLogConsole.ExtentHeight - 24.0)))
            } else {
                ($txtLogConsole.ViewportHeight -le 0) -or ($txtLogConsole.ExtentHeight -le $txtLogConsole.ViewportHeight) -or (($txtLogConsole.VerticalOffset + $txtLogConsole.ViewportHeight) -ge ($txtLogConsole.ExtentHeight - 24.0))
            }
            try {
                if ($null -ne $stateContainer) { $stateContainer.IsAppendingLog = $true }
                if ($autoScrollOn) {
                    if ($txtLogConsole.Text.Length -gt 72000) {
                        $txtLogConsole.Text = $txtLogConsole.Text.Substring($txtLogConsole.Text.Length - 48000)
                    }
                    $txtLogConsole.AppendText($lineStr)
                    $txtLogConsole.ScrollToEnd()
                } else {
                    if ($txtLogConsole.Text.Length -gt 192000) {
                        $savedOffset = $txtLogConsole.VerticalOffset
                        $txtLogConsole.Text = $txtLogConsole.Text.Substring($txtLogConsole.Text.Length - 144000)
                        $txtLogConsole.ScrollToVerticalOffset([Math]::Max(0.0, $savedOffset - 1200.0))
                    }
                    $txtLogConsole.AppendText($lineStr)
                }
            } finally {
                if ($null -ne $stateContainer) { $stateContainer.IsAppendingLog = $false }
            }
        }
    }

    $prefLoadResult = Read-PSRPMPreferences -UseDefaults:$Defaults
    $savedPrefs     = $prefLoadResult.Preferences
    if (-not $PSBoundParameters.ContainsKey('RefreshIntervalMs') -and $savedPrefs -and $savedPrefs.RefreshIntervalMs -ge 250) {
        $RefreshIntervalMs = [int]$savedPrefs.RefreshIntervalMs
    }

    &$writeAuditLog "INIT" "PSRPM initialized for target '$targetLabel' (Mode: $(if ($isLocalMode) { 'LocalOnly' } else { 'WinRM PSSession' }), Interval: ${RefreshIntervalMs}ms)."
    if ($prefLoadResult.SkippedDisk) {
        &$writeAuditLog "PREFS" "Skipped saved preferences (-Defaults specified); using factory defaults (saved config on disk left untouched)."
    } elseif ($prefLoadResult.HadParseError) {
        &$writeAuditLog "WARN" "Ignoring malformed preferences file '$($prefLoadResult.Path)'; using factory defaults."
    } elseif ($prefLoadResult.LoadedFromDisk) {
        &$writeAuditLog "PREFS" "Loaded saved user preferences from '$($prefLoadResult.Path)'."
    }

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

    # 5. Theme Engine (Clean Light, Precision Dark, Tokyo Night, Tokyo Night Light, Sysinternals Classic & High-Contrast WCAG AAA)
    $menuThemeCycle           = $window.FindName("MenuThemeCycle")
    $menuThemeLight           = $window.FindName("MenuThemeLight")
    $menuThemeDark            = $window.FindName("MenuThemeDark")
    $menuThemeTokyoNight      = $window.FindName("MenuThemeTokyoNight")
    $menuThemeTokyoNightLight = $window.FindName("MenuThemeTokyoNightLight")
    $menuThemeClassic         = $window.FindName("MenuThemeClassic")
    $menuThemeHighContrast    = $window.FindName("MenuThemeHighContrast")
    $txtThemeToggle           = $window.FindName("TxtThemeToggle")
    $brushConv                = [System.Windows.Media.BrushConverter]::new()

    $setResourceBrush = {
        param([string]$key, [string]$hex)
        $b = $brushConv.ConvertFromString($hex)
        if ($b.CanFreeze) { $b.Freeze() }
        $window.Resources[$key] = $b
    }

    $frozenBrushCache = @{}
    $getFrozenBrush = {
        param([string]$hex)
        if ($frozenBrushCache.ContainsKey($hex)) { return $frozenBrushCache[$hex] }
        $b = $brushConv.ConvertFromString($hex)
        if ($b.CanFreeze) { $b.Freeze() }
        $frozenBrushCache[$hex] = $b
        return $b
    }

    $syncDialogThemeBrushes = {
        param($targetWin)
        if (-not $targetWin) { return }
        foreach ($key in @($window.Resources.Keys)) {
            if ($key -is [string] -and ($key.StartsWith("Brush") -or $key.StartsWith("ColTint_"))) {
                $targetWin.Resources[$key] = $window.Resources[$key]
            }
        }
    }

    $menuSavePreferences  = $window.FindName("MenuSavePreferences")
    $menuResetPreferences = $window.FindName("MenuResetPreferences")
    $prefsDirtyState      = @{
        IsDirty   = $false
        Announced = $false
        Suppress  = $false
        Reasons   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $updateSavePrefsCue = {
        if (-not $menuSavePreferences) { return }
        if ([bool]$prefsDirtyState.IsDirty) {
            $reasonList = if ($prefsDirtyState.Reasons.Count -gt 0) {
                (@($prefsDirtyState.Reasons) | Sort-Object) -join ", "
            } else {
                "Session settings"
            }
            $menuSavePreferences.Header = "_Save Current Preferences as Default *"
            $menuSavePreferences.ToolTip = ("Unsaved session changes ({0}). Preferences are opt-in and never auto-saved on exit; click to save to %LOCALAPPDATA%\PSRPM\preferences.json." -f $reasonList)
        } else {
            $menuSavePreferences.Header = "_Save Current Preferences as Default"
            $menuSavePreferences.ToolTip = "Opt-in: Save current theme, columns, sort/view mode, log console state, and options to %LOCALAPPDATA%\PSRPM\preferences.json (never auto-saved on exit)"
        }
    }
    $markUnsavedPrefs = {
        param([string]$reason = "Settings")
        if ([bool]$prefsDirtyState.Suppress -or (-not $window.IsLoaded)) { return }
        if ($reason) { [void]$prefsDirtyState.Reasons.Add($reason) }
        $prefsDirtyState.IsDirty = $true
        &$updateSavePrefsCue
        if (-not [bool]$prefsDirtyState.Announced) {
            $prefsDirtyState.Announced = $true
            &$writeAuditLog "PREFS" ("Session preference changed ({0}). Preferences are opt-in only and never auto-saved on exit; use Options -> Save Current Preferences as Default to persist." -f $reason)
        }
    }
    $clearUnsavedPrefs = {
        $prefsDirtyState.IsDirty = $false
        $prefsDirtyState.Announced = $false
        $prefsDirtyState.Reasons.Clear()
        &$updateSavePrefsCue
    }
    &$updateSavePrefsCue

    $stateContainer.CurrentTheme = "Light"
    $stateContainer.ThemePalette = [PSRPMThemeRegistry]::GetPalette("Light")

    $applyTheme = {
        param($themeArg)
        $themeMode = if ($themeArg -is [bool]) { if ($themeArg) { "Dark" } else { "Light" } } else { [string]$themeArg }
        if (-not $themeMode) { $themeMode = "Light" }

        $prevTheme = [string]$stateContainer.CurrentTheme
        $palette = [PSRPMThemeRegistry]::GetPalette($themeMode)
        $resolvedMode = [string]$palette.Name
        $isDark = [bool]$palette.IsDark

        $stateContainer.CurrentTheme = $resolvedMode
        $stateContainer.IsDarkTheme  = $isDark
        $stateContainer.ThemePalette = $palette

        foreach ($kv in $palette.Brushes.GetEnumerator()) {
            &$setResourceBrush $kv.Key $kv.Value
        }

        if ($menuThemeLight)           { $menuThemeLight.IsChecked           = ($resolvedMode -eq "Light") }
        if ($menuThemeDark)            { $menuThemeDark.IsChecked            = ($resolvedMode -eq "Dark") }
        if ($menuThemeTokyoNight)      { $menuThemeTokyoNight.IsChecked      = ($resolvedMode -eq "TokyoNight") }
        if ($menuThemeTokyoNightLight) { $menuThemeTokyoNightLight.IsChecked = ($resolvedMode -eq "TokyoNightLight") }
        if ($menuThemeClassic)         { $menuThemeClassic.IsChecked         = ($resolvedMode -eq "Classic") }
        if ($menuThemeHighContrast)    { $menuThemeHighContrast.IsChecked    = ($resolvedMode -eq "HighContrast") }
        if ($txtThemeToggle)           { $txtThemeToggle.Text                = [string]$palette.DisplayName }

        foreach ($vm in $engineHandle.ProcessMap.Values) {
            $vm.SetThemeMode($resolvedMode)
        }
        foreach ($tVm in $hostTabsCollection) {
            if ($tVm -and $tVm.ProcessMap) {
                foreach ($cachedVm in $tVm.ProcessMap.Values) {
                    $cachedVm.SetThemeMode($resolvedMode)
                }
            }
        }

        $canClose = ($hostTabsCollection.Count -gt 1)
        foreach ($tVm in $hostTabsCollection) {
            $tVm.UpdateVisualState(($tVm -eq $script:ActiveHostTab), $resolvedMode, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
        }
        if ($script:UpdateLegendFilterUi) { &$script:UpdateLegendFilterUi }
        if ($updatePauseUi) { &$updatePauseUi ([bool]$stateContainer.IsPaused) }
        if ($script:UpdateNetEtwUi) {
            &$script:UpdateNetEtwUi ([int]$stateContainer.NetEtwCap) ([int]$stateContainer.NetEtwEventsPerSec)
        }
        if ($script:RefreshNetworkThemeBrushes) {
            &$script:RefreshNetworkThemeBrushes
        }

        foreach ($activeModal in @($script:ActiveFindHandleWin, $script:ActivePropWin, $script:ActiveSysInfoWin)) {
            if ($activeModal -and $activeModal.IsLoaded) {
                &$syncDialogThemeBrushes $activeModal
            }
        }
        if ($prevTheme -ne $resolvedMode) {
            &$markUnsavedPrefs "Theme"
        }
    }

    if ($menuThemeLight)           { $menuThemeLight.add_Click({ &$applyTheme "Light" }) }
    if ($menuThemeDark)            { $menuThemeDark.add_Click({ &$applyTheme "Dark" }) }
    if ($menuThemeTokyoNight)      { $menuThemeTokyoNight.add_Click({ &$applyTheme "TokyoNight" }) }
    if ($menuThemeTokyoNightLight) { $menuThemeTokyoNightLight.add_Click({ &$applyTheme "TokyoNightLight" }) }
    if ($menuThemeClassic)         { $menuThemeClassic.add_Click({ &$applyTheme "Classic" }) }
    if ($menuThemeHighContrast)    { $menuThemeHighContrast.add_Click({ &$applyTheme "HighContrast" }) }

    $cycleTheme = {
        $cur = if ($stateContainer.CurrentTheme) { $stateContainer.CurrentTheme } else { if ($stateContainer.IsDarkTheme) { "Dark" } else { "Light" } }
        $next = switch ($cur) {
            "Light"           { "Dark" }
            "Dark"            { "TokyoNight" }
            "TokyoNight"      { "TokyoNightLight" }
            "TokyoNightLight" { "Classic" }
            "Classic"         { "HighContrast" }
            "HighContrast"    { "Light" }
            default           { "Dark" }
        }
        &$applyTheme $next
    }

    if ($menuThemeCycle) {
        $menuThemeCycle.add_Click({ &$cycleTheme })
    }

    $btnToolbarTheme = $window.FindName("BtnToolbarTheme")
    if ($btnToolbarTheme) {
        $btnToolbarTheme.add_Click({ &$cycleTheme })
    }

    $initialTheme = if ($Dark.IsPresent) {
        "Dark"
    } elseif ($PSBoundParameters.ContainsKey('Theme') -and $Theme) {
        $Theme
    } elseif ($savedPrefs -and $savedPrefs.Theme) {
        [string]$savedPrefs.Theme
    } else {
        "Light"
    }
    &$applyTheme $initialTheme

    # 5B. Row Highlighting Engine (Standard Sysinternals Semantic Categories vs Minimal Flashes-Only)
    $menuHighlightCategories = $window.FindName("MenuHighlightCategories")
    $btnToggleHighlights     = $window.FindName("BtnToggleHighlights")

    $setCategoryHighlighting = {
        param([bool]$enable)
        $prevHighlight = [bool]$stateContainer.EnableCategoryHighlights
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
        foreach ($tVm in $hostTabsCollection) {
            if ($tVm -and $tVm.ProcessMap) {
                foreach ($cachedVm in $tVm.ProcessMap.Values) {
                    $cachedVm.SetCategoryHighlights($enable)
                }
            }
        }
        if ($prevHighlight -ne $enable) {
            &$markUnsavedPrefs "Highlighting"
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
    if ($savedPrefs -and (-not [bool]$savedPrefs.EnableCategoryHighlights)) {
        &$setCategoryHighlighting $false
    }

    # 5C. Always On Top (Topmost) Window Controller
    $menuAlwaysOnTop = $window.FindName("MenuAlwaysOnTop")
    $setAlwaysOnTop = {
        param([bool]$enable)
        $prevTopmost = [bool]$stateContainer.AlwaysOnTop
        $stateContainer.AlwaysOnTop = $enable
        $window.Topmost = $enable
        if ($menuAlwaysOnTop) { $menuAlwaysOnTop.IsChecked = $enable }
        foreach ($activeModal in @($script:ActiveFindHandleWin, $script:ActivePropWin, $script:ActiveSysInfoWin)) {
            if ($activeModal -and $activeModal.IsLoaded) {
                $activeModal.Topmost = $enable
            }
        }
        if ($prevTopmost -ne $enable) {
            &$markUnsavedPrefs "Always On Top"
        }
        &$writeAuditLog "OPTIONS" ("Always On Top window pinning {0}." -f $(if ($enable) { "enabled" } else { "disabled" }))
    }
    if ($menuAlwaysOnTop) {
        $menuAlwaysOnTop.add_Click({
            &$setAlwaysOnTop ([bool]$menuAlwaysOnTop.IsChecked)
        })
    }
    if ($AlwaysOnTop.IsPresent -or ($savedPrefs -and [bool]$savedPrefs.AlwaysOnTop)) {
        &$setAlwaysOnTop $true
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
    $menuViewTree         = $window.FindName("MenuViewTree")
    $menuViewFlat         = $window.FindName("MenuViewFlat")
    $menuTreeOrderNewest  = $window.FindName("MenuTreeOrderNewest")
    $menuTreeOrderClassic = $window.FindName("MenuTreeOrderClassic")
    $btnToolbarTree       = $window.FindName("BtnToolbarTree")
    $txtModeIndicator     = $window.FindName("TxtModeIndicator")
    $menuExpandAll        = $window.FindName("MenuExpandAll")
    $menuCollapseAll      = $window.FindName("MenuCollapseAll")

    $stateContainer.TreeSortNewestFirst = $true

    $setViewMode = {
        param([bool]$treeMode)
        $prevTreeMode = [bool]$stateContainer.IsTreeMode
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
        if ($txtModeIndicator) {
            $txtModeIndicator.Text = if ($treeMode) {
                if ([bool]$stateContainer.TreeSortNewestFirst) { "Tree (New)" } else { "Tree" }
            } else {
                "Flat"
            }
        }
        & $engineHandle.RefreshTree
        if ($prevTreeMode -ne $treeMode) {
            &$markUnsavedPrefs "View Mode"
        }
    }

    $setTreeSortOrder = {
        param([bool]$newestFirst)
        $prevNewestFirst = [bool]$stateContainer.TreeSortNewestFirst
        $stateContainer.TreeSortNewestFirst = $newestFirst
        if ($menuTreeOrderNewest)  { $menuTreeOrderNewest.IsChecked  = $newestFirst }
        if ($menuTreeOrderClassic) { $menuTreeOrderClassic.IsChecked = (-not $newestFirst) }
        if (-not [bool]$stateContainer.IsTreeMode) {
            &$setViewMode $true
        } else {
            if ($txtModeIndicator) {
                $txtModeIndicator.Text = if ($newestFirst) { "Tree (New)" } else { "Tree" }
            }
            & $engineHandle.RefreshTree
        }
        if ($prevNewestFirst -ne $newestFirst) {
            &$markUnsavedPrefs "Tree Order"
        }
        &$writeAuditLog "VIEW" ("Tree View ordering set to {0}." -f $(if ($newestFirst) { "Newest First (Creation Time Descending)" } else { "Classic Process Explorer (Oldest First)" }))
    }

    $gridProcesses.add_Sorting({
        param($sender, $e)
        $e.Handled = $true
        $col = $e.Column
        $sortProp = $col.SortMemberPath
        if (-not $sortProp) { $sortProp = "PID" }

        $prevSortProp = [string]$stateContainer.SortProperty
        $prevSortDesc = [bool]$stateContainer.SortDescending

        $next = Get-PSRPMNextColumnSortState `
            -IsTreeMode ([bool]$stateContainer.IsTreeMode) `
            -CurrentTreeNewestFirst ([bool]$stateContainer.TreeSortNewestFirst) `
            -CurrentSortProperty $prevSortProp `
            -CurrentSortDescending $prevSortDesc `
            -ClickedSortProperty $sortProp

        if ($next.IsTreeMode) {
            $newest = [bool]$next.TreeSortNewestFirst
            $prevNewestSort = [bool]$stateContainer.TreeSortNewestFirst
            $stateContainer.TreeSortNewestFirst = $newest
            if ($menuTreeOrderNewest)  { $menuTreeOrderNewest.IsChecked  = $newest }
            if ($menuTreeOrderClassic) { $menuTreeOrderClassic.IsChecked = (-not $newest) }
            if ($prevNewestSort -ne $newest) {
                &$markUnsavedPrefs "Tree Order"
            }
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

        if (($prevSortProp -ne [string]$next.SortProperty) -or ($prevSortDesc -ne [bool]$next.SortDescending)) {
            &$markUnsavedPrefs "Sort Order"
        }
        &$setViewMode $false
    })

    if ($menuViewTree)         { $menuViewTree.add_Click({ &$setViewMode $true }) }
    if ($menuViewFlat)         { $menuViewFlat.add_Click({ &$setViewMode $false }) }
    if ($menuTreeOrderNewest)  { $menuTreeOrderNewest.add_Click({ &$setTreeSortOrder $true }) }
    if ($menuTreeOrderClassic) { $menuTreeOrderClassic.add_Click({ &$setTreeSortOrder $false }) }
    if ($btnToolbarTree)       { $btnToolbarTree.add_Click({ &$setViewMode (-not [bool]$stateContainer.IsTreeMode) }) }

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
        $pal = if ($stateContainer.ThemePalette) { $stateContainer.ThemePalette } else { [PSRPMThemeRegistry]::GetPalette($(if ($stateContainer.CurrentTheme) { $stateContainer.CurrentTheme } else { "Light" })) }
        $leg = $pal.Legend
        $svc = $leg.Service
        $own = $leg.Own
        $pkg = $leg.Packaged
        $hdrBg = $pal.Brushes.BrushHeaderBg
        $txtPri = $pal.Brushes.BrushTextPrimary

        if ($btnLegendAll) {
            $btnLegendAll.Background = &$getFrozenBrush $hdrBg
            $btnLegendAll.Foreground = &$getFrozenBrush $txtPri
        }

        if (-not $cur) {
            # ALL active
            if ($txtFilterLegendLabel) {
                $txtFilterLegendLabel.Text = "Filter:"
                $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
                $txtFilterLegendLabel.Foreground = $window.FindResource("BrushTextMuted")
            }
            if ($btnLegendClear) { $btnLegendClear.Visibility = [System.Windows.Visibility]::Collapsed }

            if ($btnLegendAll) {
                $btnLegendAll.Content = "All"
                $btnLegendAll.FontWeight = [System.Windows.FontWeights]::Bold
                $btnLegendAll.BorderThickness = [System.Windows.Thickness]::new(2)
                $btnLegendAll.BorderBrush = &$getFrozenBrush $leg.AllActiveBorder
                $btnLegendAll.Opacity = 1.0
            }
            if ($btnLegendService) {
                $btnLegendService.Content = "Services"
                $btnLegendService.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendService.BorderBrush = &$getFrozenBrush $svc.Border
                $btnLegendService.Background = &$getFrozenBrush $svc.Bg
                $btnLegendService.Foreground = &$getFrozenBrush $svc.Fg
                $btnLegendService.Opacity = 0.85
            }
            if ($btnLegendOwn) {
                $btnLegendOwn.Content = "Own / User"
                $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendOwn.BorderBrush = &$getFrozenBrush $own.Border
                $btnLegendOwn.Background = &$getFrozenBrush $own.Bg
                $btnLegendOwn.Foreground = &$getFrozenBrush $own.Fg
                $btnLegendOwn.Opacity = 0.85
            }
            if ($btnLegendPackaged) {
                $btnLegendPackaged.Content = "Packaged"
                $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendPackaged.BorderBrush = &$getFrozenBrush $pkg.Border
                $btnLegendPackaged.Background = &$getFrozenBrush $pkg.Bg
                $btnLegendPackaged.Foreground = &$getFrozenBrush $pkg.Fg
                $btnLegendPackaged.Opacity = 0.85
            }
        } else {
            # SPECIFIC category active
            if ($btnLegendClear) { $btnLegendClear.Visibility = [System.Windows.Visibility]::Visible }
            if ($btnLegendAll) {
                $btnLegendAll.Content = "All"
                $btnLegendAll.FontWeight = [System.Windows.FontWeights]::Normal
                $btnLegendAll.BorderThickness = [System.Windows.Thickness]::new(1)
                $btnLegendAll.BorderBrush = &$getFrozenBrush $leg.AllIdleBorder
                $btnLegendAll.Opacity = 0.45
            }

            if ($cur -eq "Service") {
                if ($txtFilterLegendLabel) {
                    $txtFilterLegendLabel.Text = "ACTIVE FILTER:"
                    $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::Bold
                    $txtFilterLegendLabel.Foreground = &$getFrozenBrush $svc.ActiveText
                }
                if ($btnLegendService) {
                    $btnLegendService.Content = "[ Services ]"
                    $btnLegendService.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(2)
                    $btnLegendService.BorderBrush = &$getFrozenBrush $svc.ActiveBorder
                    $btnLegendService.Background = &$getFrozenBrush $svc.ActiveBg
                    $btnLegendService.Foreground = &$getFrozenBrush $svc.Fg
                    $btnLegendService.Opacity = 1.0
                }
                if ($btnLegendOwn) {
                    $btnLegendOwn.Content = "Own / User"
                    $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendOwn.BorderBrush = &$getFrozenBrush $own.Border
                    $btnLegendOwn.Background = &$getFrozenBrush $own.Bg
                    $btnLegendOwn.Foreground = &$getFrozenBrush $own.Fg
                    $btnLegendOwn.Opacity = 0.45
                }
                if ($btnLegendPackaged) {
                    $btnLegendPackaged.Content = "Packaged"
                    $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendPackaged.BorderBrush = &$getFrozenBrush $pkg.Border
                    $btnLegendPackaged.Background = &$getFrozenBrush $pkg.Bg
                    $btnLegendPackaged.Foreground = &$getFrozenBrush $pkg.Fg
                    $btnLegendPackaged.Opacity = 0.45
                }
            } elseif ($cur -eq "Own") {
                if ($txtFilterLegendLabel) {
                    $txtFilterLegendLabel.Text = "ACTIVE FILTER:"
                    $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::Bold
                    $txtFilterLegendLabel.Foreground = &$getFrozenBrush $own.ActiveText
                }
                if ($btnLegendService) {
                    $btnLegendService.Content = "Services"
                    $btnLegendService.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendService.BorderBrush = &$getFrozenBrush $svc.Border
                    $btnLegendService.Background = &$getFrozenBrush $svc.Bg
                    $btnLegendService.Foreground = &$getFrozenBrush $svc.Fg
                    $btnLegendService.Opacity = 0.45
                }
                if ($btnLegendOwn) {
                    $btnLegendOwn.Content = "[ Own / User ]"
                    $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(2)
                    $btnLegendOwn.BorderBrush = &$getFrozenBrush $own.ActiveBorder
                    $btnLegendOwn.Background = &$getFrozenBrush $own.ActiveBg
                    $btnLegendOwn.Foreground = &$getFrozenBrush $own.Fg
                    $btnLegendOwn.Opacity = 1.0
                }
                if ($btnLegendPackaged) {
                    $btnLegendPackaged.Content = "Packaged"
                    $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendPackaged.BorderBrush = &$getFrozenBrush $pkg.Border
                    $btnLegendPackaged.Background = &$getFrozenBrush $pkg.Bg
                    $btnLegendPackaged.Foreground = &$getFrozenBrush $pkg.Fg
                    $btnLegendPackaged.Opacity = 0.45
                }
            } elseif ($cur -eq "Packaged") {
                if ($txtFilterLegendLabel) {
                    $txtFilterLegendLabel.Text = "ACTIVE FILTER:"
                    $txtFilterLegendLabel.FontWeight = [System.Windows.FontWeights]::Bold
                    $txtFilterLegendLabel.Foreground = &$getFrozenBrush $pkg.ActiveText
                }
                if ($btnLegendService) {
                    $btnLegendService.Content = "Services"
                    $btnLegendService.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendService.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendService.BorderBrush = &$getFrozenBrush $svc.Border
                    $btnLegendService.Background = &$getFrozenBrush $svc.Bg
                    $btnLegendService.Foreground = &$getFrozenBrush $svc.Fg
                    $btnLegendService.Opacity = 0.45
                }
                if ($btnLegendOwn) {
                    $btnLegendOwn.Content = "Own / User"
                    $btnLegendOwn.FontWeight = [System.Windows.FontWeights]::Normal
                    $btnLegendOwn.BorderThickness = [System.Windows.Thickness]::new(1)
                    $btnLegendOwn.BorderBrush = &$getFrozenBrush $own.Border
                    $btnLegendOwn.Background = &$getFrozenBrush $own.Bg
                    $btnLegendOwn.Foreground = &$getFrozenBrush $own.Fg
                    $btnLegendOwn.Opacity = 0.45
                }
                if ($btnLegendPackaged) {
                    $btnLegendPackaged.Content = "[ Packaged ]"
                    $btnLegendPackaged.FontWeight = [System.Windows.FontWeights]::Bold
                    $btnLegendPackaged.BorderThickness = [System.Windows.Thickness]::new(2)
                    $btnLegendPackaged.BorderBrush = &$getFrozenBrush $pkg.ActiveBorder
                    $btnLegendPackaged.Background = &$getFrozenBrush $pkg.ActiveBg
                    $btnLegendPackaged.Foreground = &$getFrozenBrush $pkg.Fg
                    $btnLegendPackaged.Opacity = 1.0
                }
            }
        }
    }
    $script:UpdateLegendFilterUi = $updateLegendFilterUi
    &$updateLegendFilterUi

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
    $btnProcEmptyClear = $window.FindName("BtnProcEmptyClear")
    if ($btnProcEmptyClear) {
        $btnProcEmptyClear.add_Click({
            if ($txtSearch) { $txtSearch.Text = "" }
            $stateContainer.FilterText     = ""
            $stateContainer.CategoryFilter = ""
            &$updateLegendFilterUi
            & $engineHandle.RefreshTree
            if ($gridProcesses) { $gridProcesses.Focus() }
        })
    }
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
            $pauseThemeMode = if ($stateContainer.CurrentTheme) { [string]$stateContainer.CurrentTheme } elseif ($useDark) { "Dark" } else { "Light" }
            $script:ActiveHostTab.UpdateVisualState($true, $pauseThemeMode, $canClose, $stateContainer.ConnectionState, $pauseState, $stateContainer.PollLatencyMs)
        }
        if ($script:SyncNetworkAutoTimer) {
            &$script:SyncNetworkAutoTimer
        }
    }

    $setPollingRate = {
        param([int]$ms, [bool]$pause)
        $prevPaused = [bool]$stateContainer.IsPaused
        $prevInterval = [int]$stateContainer.IntervalMs
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
        if (-not $pause -and $ms -ge 250 -and $prevInterval -ne $ms) {
            &$markUnsavedPrefs "Refresh Interval"
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
    $menuViewLog       = $window.FindName("MenuViewLog")
    $btnShowLog        = $window.FindName("BtnShowLog")
    $btnToggleLogPane  = $window.FindName("BtnToggleLogPane")
    $btnClearLog       = $window.FindName("BtnClearLog")
    $btnCopyLog        = $window.FindName("BtnCopyLog")
    $chkStreamTicks    = $window.FindName("ChkStreamTicks")
    $chkLogAutoScroll  = $window.FindName("ChkLogAutoScroll")
    $logPaneResizer    = $window.FindName("LogPaneResizer")
    $hostTabBar        = $window.FindName("HostTabBar")
    $netEtwAlertBanner = $window.FindName("NetEtwAlertBanner")
    $minLogPaneHeight     = 85.0
    $defaultLogPaneHeight = 175.0
    $logResizeState       = @{
        StartMouseY = 0.0
        StartHeight = 175.0
    }

    $getMaxLogPaneHeight = {
        $winH = if ($window.ActualHeight -gt 0) { [double]$window.ActualHeight } elseif (-not [double]::IsNaN($window.Height) -and $window.Height -gt 0) { [double]$window.Height } else { 780.0 }
        $twoThirdsCap = [Math]::Floor($winH * (2.0 / 3.0))
        $chromeH = 54.0
        if ($hostTabBar -and $hostTabBar.ActualHeight -gt 0) { $chromeH += $hostTabBar.ActualHeight } else { $chromeH += 32.0 }
        if ($summaryBar -and $summaryBar.ActualHeight -gt 0) { $chromeH += $summaryBar.ActualHeight } else { $chromeH += 38.0 }
        if ($netEtwAlertBanner -and $netEtwAlertBanner.Visibility -eq [System.Windows.Visibility]::Visible) {
            $chromeH += $(if ($netEtwAlertBanner.ActualHeight -gt 0) { $netEtwAlertBanner.ActualHeight } else { 32.0 })
        }
        $headroomCap = [Math]::Floor($winH - $chromeH - 120.0)
        $effectiveMax = [Math]::Min($twoThirdsCap, $headroomCap)
        return [double][Math]::Max($minLogPaneHeight, $effectiveMax)
    }

    $clampLogPaneHeight = {
        param([double]$requestedHeight = -1.0)
        if (-not $logPane) { return }
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { return }
        $winH = if ($window.ActualHeight -gt 0) { [double]$window.ActualHeight } elseif (-not [double]::IsNaN($window.Height) -and $window.Height -gt 0) { [double]$window.Height } else { 780.0 }
        if ($winH -lt 200.0) { return }

        $curH = if ($requestedHeight -gt 0) {
            $requestedHeight
        } elseif (-not [double]::IsNaN($logPane.Height) -and $logPane.Height -gt 0) {
            [double]$logPane.Height
        } elseif ($logPane.ActualHeight -gt 0) {
            [double]$logPane.ActualHeight
        } else {
            $defaultLogPaneHeight
        }

        $maxH = [double](& $getMaxLogPaneHeight)
        $clampedH = [Math]::Max($minLogPaneHeight, [Math]::Min($maxH, $curH))
        if ([double]::IsNaN($logPane.Height) -or [Math]::Abs($logPane.Height - $clampedH) -ge 0.5) {
            $logPane.Height = $clampedH
        }
    }

    if ($logPaneResizer) {
        $logPaneResizer.add_DragStarted({
            param($sender, $e)
            if (-not $logPane) { return }
            $logResizeState.StartMouseY = [System.Windows.Input.Mouse]::GetPosition($window).Y
            $curH = if ($logPane.ActualHeight -gt 0) {
                [double]$logPane.ActualHeight
            } elseif (-not [double]::IsNaN($logPane.Height) -and $logPane.Height -gt 0) {
                [double]$logPane.Height
            } else {
                $defaultLogPaneHeight
            }
            $logResizeState.StartHeight = $curH
        })
        $logPaneResizer.add_DragDelta({
            param($sender, $e)
            if (-not $logPane) { return }
            $curMouseY = [System.Windows.Input.Mouse]::GetPosition($window).Y
            $deltaY = $logResizeState.StartMouseY - $curMouseY
            $targetH = $logResizeState.StartHeight + $deltaY
            & $clampLogPaneHeight $targetH
        })
        $logPaneResizer.add_MouseDoubleClick({
            param($sender, $e)
            & $clampLogPaneHeight $defaultLogPaneHeight
            $e.Handled = $true
        })
    }
    $window.add_SizeChanged({ & $clampLogPaneHeight })
    $window.add_StateChanged({
        if ($window.WindowState -ne [System.Windows.WindowState]::Minimized) {
            & $clampLogPaneHeight
        }
    })

    if ($menuVerbose) {
        $menuVerbose.add_Click({
            $val = [bool]$menuVerbose.IsChecked
            $stateContainer.VerboseTelemetryLog = $val
            if ($chkStreamTicks) { $chkStreamTicks.IsChecked = $val }
            if ($val -and $logPane) {
                $logPane.Visibility = "Visible"
                & $clampLogPaneHeight
                if ($menuViewLog) { $menuViewLog.IsChecked = $true }
                if ($txtLogConsole -and [bool]$stateContainer.LogAutoScroll) {
                    try {
                        $stateContainer.IsAppendingLog = $true
                        $txtLogConsole.ScrollToEnd()
                    } finally {
                        $stateContainer.IsAppendingLog = $false
                    }
                }
            }
            &$markUnsavedPrefs "Verbose Log"
        })
    }
    if ($chkStreamTicks) {
        $chkStreamTicks.add_Click({
            $val = [bool]$chkStreamTicks.IsChecked
            $stateContainer.VerboseTelemetryLog = $val
            if ($menuVerbose) { $menuVerbose.IsChecked = $val }
            &$markUnsavedPrefs "Verbose Log"
        })
    }
    if ($chkLogAutoScroll) {
        $chkLogAutoScroll.add_Click({
            $val = [bool]$chkLogAutoScroll.IsChecked
            $stateContainer.LogAutoScroll = $val
            if ($val -and $txtLogConsole) {
                try {
                    $stateContainer.IsAppendingLog = $true
                    $txtLogConsole.ScrollToEnd()
                } finally {
                    $stateContainer.IsAppendingLog = $false
                }
            }
            &$markUnsavedPrefs "Log Console"
        })
    }
    if ($txtLogConsole) {
        $txtLogConsole.AddHandler(
            [System.Windows.Controls.ScrollViewer]::ScrollChangedEvent,
            [System.Windows.Controls.ScrollChangedEventHandler]{
                param($sender, $e)
                if ($stateContainer.IsAppendingLog) { return }
                if ($e.ViewportHeight -le 0) { return }
                if ($e.ViewportHeightChange -ne 0) {
                    if ([bool]$stateContainer.LogAutoScroll) {
                        try {
                            $stateContainer.IsAppendingLog = $true
                            $txtLogConsole.ScrollToEnd()
                        } finally {
                            $stateContainer.IsAppendingLog = $false
                        }
                    }
                    return
                }
                if ($e.VerticalChange -eq 0 -and $e.ExtentHeightChange -ne 0) { return }

                $atBottom = ($e.VerticalOffset + $e.ViewportHeight) -ge ($e.ExtentHeight - 4.0)
                if ($e.VerticalChange -lt 0 -and -not $atBottom) {
                    if ($stateContainer.LogAutoScroll) {
                        $stateContainer.LogAutoScroll = $false
                        if ($chkLogAutoScroll -and $chkLogAutoScroll.IsChecked -ne $false) {
                            $chkLogAutoScroll.IsChecked = $false
                        }
                    }
                } elseif ($e.VerticalChange -gt 0 -and $atBottom) {
                    if (-not $stateContainer.LogAutoScroll) {
                        $stateContainer.LogAutoScroll = $true
                        if ($chkLogAutoScroll -and $chkLogAutoScroll.IsChecked -ne $true) {
                            $chkLogAutoScroll.IsChecked = $true
                        }
                    }
                }
            }
        )
    }

    $toggleLogPane = {
        if ($logPane.Visibility -eq "Visible") {
            $logPane.Visibility = "Collapsed"
            if ($menuViewLog) { $menuViewLog.IsChecked = $false }
        } else {
            $logPane.Visibility = "Visible"
            & $clampLogPaneHeight
            if ($menuViewLog) { $menuViewLog.IsChecked = $true }
            if ($txtLogConsole -and [bool]$stateContainer.LogAutoScroll) {
                try {
                    $stateContainer.IsAppendingLog = $true
                    $txtLogConsole.ScrollToEnd()
                } finally {
                    $stateContainer.IsAppendingLog = $false
                }
            }
        }
        &$markUnsavedPrefs "Log Console"
    }
    if ($menuViewLog)      { $menuViewLog.add_Click($toggleLogPane) }
    if ($btnShowLog)       { $btnShowLog.add_Click($toggleLogPane) }
    if ($btnToggleLogPane) { $btnToggleLogPane.add_Click($toggleLogPane) }
    if ($btnClearLog)      {
        $btnClearLog.add_Click({
            if ($txtLogConsole) {
                try {
                    $stateContainer.IsAppendingLog = $true
                    $txtLogConsole.Clear()
                } finally {
                    $stateContainer.IsAppendingLog = $false
                }
            }
            $stateContainer.LogAutoScroll = $true
            if ($chkLogAutoScroll) { $chkLogAutoScroll.IsChecked = $true }
        })
    }
    $copyToClipboardSafe = {
        param([string]$text, [string]$auditCategory = "", [string]$auditMessage = "")
        if ([string]::IsNullOrEmpty($text)) { return $false }
        $copied = $false
        $lastErr = $null
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                [System.Windows.Clipboard]::SetText($text)
                $copied = $true
                break
            } catch {
                $lastErr = $_
                if ($attempt -lt 2) {
                    [System.Threading.Thread]::Sleep((($attempt + 1) * 15))
                }
            }
        }
        if ($copied) {
            if ($auditCategory -and $auditMessage) {
                &$writeAuditLog $auditCategory $auditMessage
            }
            return $true
        }
        $errDetail = if ($lastErr -and $lastErr.Exception) { $lastErr.Exception.Message } else { "Clipboard busy" }
        &$writeAuditLog "WARN" "Clipboard copy failed after retries: $errDetail"
        return $false
    }
    if ($btnCopyLog)       { $btnCopyLog.add_Click({ if ($txtLogConsole -and $txtLogConsole.Text) { [void](&$copyToClipboardSafe $txtLogConsole.Text "" "") } }) }

    # 12. Process & Service Operations Dispatcher
    $menuConfirmKill = $window.FindName("MenuConfirmKill")
    if ($menuConfirmKill) {
        $menuConfirmKill.add_Click({
            &$markUnsavedPrefs "Confirm Kill"
        })
    }
    if ($gridProcesses) {
        $gridProcesses.add_ColumnReordered({
            &$markUnsavedPrefs "Column Order"
        })
    }
    $jssAction = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jssAction.MaxJsonLength = 10485760

    # 12A. Customizable Process Columns Engine (Visibility, Ordering, Widths, Header Menu & Picker Dialog)
    $colCatalog = Get-PSRPMColumnCatalog
    $colDefByKey = [ordered]@{}
    $colObjByKey = [ordered]@{}
    $colKeyByObj = [System.Collections.Generic.Dictionary[Object, string]]::new()
    foreach ($cDef in $colCatalog) {
        $k = [string]$cDef.Key
        $colDefByKey[$k] = $cDef
        $cObj = $window.FindName([string]$cDef.ControlName)
        if ($cObj) {
            $colObjByKey[$k] = $cObj
            $colKeyByObj[$cObj] = $k
        }
    }

    $script:ShowNetTotalCol = $true
    $script:ShowTreeNetCol  = $true
    $script:ShowRxTxCols    = $false
    $script:NetBannerDismissedCap = 0

    $script:UserVisibleCols = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $script:ColumnOrderList = [System.Collections.Generic.List[string]]::new()
    $script:ColumnWidthsMap = @{}
    foreach ($cDef in $colCatalog) {
        $ck = [string]$cDef.Key
        if ([bool]$cDef.DefaultVisible) { [void]$script:UserVisibleCols.Add($ck) }
        $script:ColumnOrderList.Add($ck)
    }

    $applyColumnLayout = {
        param([bool]$applyWidths = $false)
        if (-not $gridProcesses) { return }

        $isNetActive = ([int]$stateContainer.NetEtwCap -eq 1)

        # 1. Apply Visibility (respecting Net ETW active state + locked Process column)
        [void]$script:UserVisibleCols.Add("Process")
        foreach ($cDef in $colCatalog) {
            $ck = [string]$cDef.Key
            $cObj = $colObjByKey[$ck]
            if (-not $cObj) { continue }

            $wantVis = $false
            if ([bool]$cDef.IsLocked) {
                $wantVis = $true
            } elseif ([bool]$cDef.IsNetEtw) {
                if ($isNetActive) {
                    switch ($ck) {
                        "NetTotal" { $wantVis = [bool]$script:ShowNetTotalCol }
                        "TreeNet"  { $wantVis = [bool]$script:ShowTreeNetCol }
                        "NetRx"    { $wantVis = [bool]$script:ShowRxTxCols }
                        "NetTx"    { $wantVis = [bool]$script:ShowRxTxCols }
                    }
                }
            } else {
                $wantVis = $script:UserVisibleCols.Contains($ck)
            }

            $targetVis = if ($wantVis) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
            if ($cObj.Visibility -ne $targetVis) {
                $cObj.Visibility = $targetVis
            }

            if ($applyWidths) {
                $wVal = [double]$cDef.DefaultWidth
                if ($script:ColumnWidthsMap.ContainsKey($ck)) {
                    $customW = [double]$script:ColumnWidthsMap[$ck]
                    if ($customW -ge 40.0 -and $customW -le 1200.0) {
                        $wVal = $customW
                    }
                }
                $cObj.Width = [System.Windows.Controls.DataGridLength]::new($wVal)
            }
        }

        # 2. Apply DisplayIndex Ordering (Process pinned at 0)
        $orderedKeys = [System.Collections.Generic.List[string]]::new()
        $seenOrder = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        [void]$seenOrder.Add("Process")
        $orderedKeys.Add("Process")
        foreach ($ok in $script:ColumnOrderList) {
            if ($colObjByKey.Contains($ok) -and $seenOrder.Add($ok)) {
                $orderedKeys.Add($ok)
            }
        }
        foreach ($cDef in $colCatalog) {
            $dk = [string]$cDef.Key
            if ($colObjByKey.Contains($dk) -and $seenOrder.Add($dk)) {
                $orderedKeys.Add($dk)
            }
        }
        $script:ColumnOrderList.Clear()
        foreach ($ok in $orderedKeys) { $script:ColumnOrderList.Add($ok) }

        $maxIdx = $gridProcesses.Columns.Count - 1
        for ($di = 0; $di -lt $orderedKeys.Count; $di++) {
            if ($di -gt $maxIdx) { break }
            $cObj = $colObjByKey[$orderedKeys[$di]]
            if ($cObj -and $cObj.DisplayIndex -ne $di) {
                try { $cObj.DisplayIndex = $di } catch {}
            }
        }

        # 3. Sort Guard: if current flat-sort column is now hidden, return cleanly to Tree Mode
        if (-not [bool]$stateContainer.IsTreeMode) {
            $curSort = [string]$stateContainer.SortProperty
            $sortStillVisible = $false
            foreach ($c in $gridProcesses.Columns) {
                if ($c.SortMemberPath -eq $curSort -and $c.Visibility -eq [System.Windows.Visibility]::Visible) {
                    $sortStillVisible = $true
                    break
                }
            }
            if (-not $sortStillVisible) {
                &$setViewMode $true
            }
        }
    }

    $syncLiveOrderAndWidths = {
        if (-not $gridProcesses) { return }
        $pairs = [System.Collections.Generic.List[Object]]::new()
        foreach ($cDef in $colCatalog) {
            $ck = [string]$cDef.Key
            $cObj = $colObjByKey[$ck]
            if ($cObj) {
                $pairs.Add([PSCustomObject]@{ Key = $ck; DisplayIndex = [int]$cObj.DisplayIndex })
                if ($cObj.Visibility -eq [System.Windows.Visibility]::Visible) {
                    $wPx = if ($cObj.ActualWidth -ge 40.0) { [double]$cObj.ActualWidth } elseif ($cObj.Width.DisplayValue -ge 40.0) { [double]$cObj.Width.DisplayValue } else { [double]$cDef.DefaultWidth }
                    $script:ColumnWidthsMap[$ck] = [Math]::Round([Math]::Max(40.0, [Math]::Min(1200.0, $wPx)), 1)
                }
            }
        }
        $sortedPairs = $pairs | Sort-Object -Property DisplayIndex
        $script:ColumnOrderList.Clear()
        [void]$script:ColumnOrderList.Add("Process")
        foreach ($sp in $sortedPairs) {
            if ($sp.Key -ne "Process") { $script:ColumnOrderList.Add($sp.Key) }
        }
    }

    $autoFitVisibleColumns = {
        if (-not $gridProcesses) { return }
        foreach ($cDef in $colCatalog) {
            $cObj = $colObjByKey[[string]$cDef.Key]
            if ($cObj -and $cObj.Visibility -eq [System.Windows.Visibility]::Visible) {
                $cObj.Width = [System.Windows.Controls.DataGridLength]::Auto
            }
        }
        $gridProcesses.UpdateLayout()
        foreach ($cDef in $colCatalog) {
            $ck = [string]$cDef.Key
            $cObj = $colObjByKey[$ck]
            if ($cObj -and $cObj.Visibility -eq [System.Windows.Visibility]::Visible) {
                $fitW = [Math]::Max(52.0, [Math]::Min(480.0, [Math]::Ceiling($cObj.ActualWidth + 6.0)))
                $cObj.Width = [System.Windows.Controls.DataGridLength]::new($fitW)
                $script:ColumnWidthsMap[$ck] = $fitW
            }
        }
        &$markUnsavedPrefs "Columns"
    }

    $resetColumnsToDefault = {
        $script:UserVisibleCols.Clear()
        $script:ColumnOrderList.Clear()
        $script:ColumnWidthsMap = @{}
        foreach ($cDef in $colCatalog) {
            $ck = [string]$cDef.Key
            if ([bool]$cDef.DefaultVisible) { [void]$script:UserVisibleCols.Add($ck) }
            $script:ColumnOrderList.Add($ck)
        }
        $script:ShowNetTotalCol = $true
        $script:ShowTreeNetCol  = $true
        $script:ShowRxTxCols    = $false
        if ($menuColTreeNet) { $menuColTreeNet.IsChecked = $true }
        if ($menuColNetRxTx) { $menuColNetRxTx.IsChecked = $false }
        &$applyColumnLayout $true
        &$markUnsavedPrefs "Columns"
        &$writeAuditLog "VIEW" "Reset Process columns to default layout."
    }

    $openSelectColumnsDialog = {
        if (-not [System.IO.File]::Exists($selectColsXamlPath)) { return }
        &$syncLiveOrderAndWidths

        $scBytes = [System.IO.File]::ReadAllBytes($selectColsXamlPath)
        $msSc = [System.IO.MemoryStream]::new($scBytes)
        $scWin = [System.Windows.Markup.XamlReader]::Load($msSc)
        $msSc.Close()

        $scWin.Owner = $window
        if ($appIconFrame) { $scWin.Icon = $appIconFrame }
        &$syncDialogThemeBrushes $scWin

        $txtColFilter        = $scWin.FindName("TxtColFilter")
        $btnColFilterClear   = $scWin.FindName("BtnColFilterClear")
        $lstAvailCols        = $scWin.FindName("LstAvailableColumns")
        $lstColOrder         = $scWin.FindName("LstColumnOrder")
        $txtSelCount         = $scWin.FindName("TxtSelectedCount")
        $btnMoveUp           = $scWin.FindName("BtnColMoveUp")
        $btnMoveDown         = $scWin.FindName("BtnColMoveDown")
        $btnPresetDefault    = $scWin.FindName("BtnPresetDefault")
        $btnPresetProcExp    = $scWin.FindName("BtnPresetProcExp")
        $btnPresetForensic   = $scWin.FindName("BtnPresetForensic")
        $btnResetCols        = $scWin.FindName("BtnColResetDefaults")
        $btnColOk            = $scWin.FindName("BtnColOk")

        $availItems = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
        $orderItems = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
        $dlgState   = @{
            SuppressRebuild = $false
            OrderKeys       = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($ok in $script:ColumnOrderList) { $dlgState.OrderKeys.Add($ok) }

        $itemByKey = @{}
        $isNetActiveNow = ([int]$stateContainer.NetEtwCap -eq 1)

        $rebuildOrderList = {
            param([string]$selectKey)
            $orderItems.Clear()
            $visNum = 1
            $activeVisCount = 0
            $etwGatedCount  = 0
            foreach ($ok in $dlgState.OrderKeys) {
                $it = $itemByKey[$ok]
                if ($it -and [bool]$it.IsChecked) {
                    $isGated = ([bool]$it.IsNetEtw -and -not $isNetActiveNow)
                    $suffix = if ($it.IsLocked) { " (Locked)" } elseif ($isGated) { " (ETW off)" } else { "" }
                    if ($isGated) { $etwGatedCount++ } else { $activeVisCount++ }
                    $oObj = [PSCustomObject]@{
                        Key        = $ok
                        IsLocked   = [bool]$it.IsLocked
                        OrderLabel = ("{0}. {1}{2}" -f $visNum, $it.Header, $suffix)
                    }
                    $orderItems.Add($oObj)
                    $visNum++
                }
            }
            if ($txtSelCount) {
                if ($etwGatedCount -gt 0) {
                    $txtSelCount.Text = ("{0} of {1} visible (+{2} ETW off)" -f $activeVisCount, $availItems.Count, $etwGatedCount)
                } else {
                    $txtSelCount.Text = ("{0} of {1} visible" -f $activeVisCount, $availItems.Count)
                }
            }
            if ($selectKey) {
                for ($oi = 0; $oi -lt $orderItems.Count; $oi++) {
                    if ($orderItems[$oi].Key -eq $selectKey) {
                        $lstColOrder.SelectedIndex = $oi
                        break
                    }
                }
            }
        }

        foreach ($cDef in $colCatalog) {
            $ck = [string]$cDef.Key
            $initChecked = if ([bool]$cDef.IsLocked) {
                $true
            } elseif ([bool]$cDef.IsNetEtw) {
                switch ($ck) {
                    "NetTotal" { [bool]$script:ShowNetTotalCol }
                    "TreeNet"  { [bool]$script:ShowTreeNetCol }
                    "NetRx"    { [bool]$script:ShowRxTxCols }
                    "NetTx"    { [bool]$script:ShowRxTxCols }
                    default    { $false }
                }
            } else {
                $script:UserVisibleCols.Contains($ck)
            }

            $rowObj = [PSCustomObject]@{
                Key            = $ck
                Header         = [string]$cDef.Header
                Group          = [string]$cDef.Group
                Hint           = [string]$cDef.Hint
                IsLocked       = [bool]$cDef.IsLocked
                IsNetEtw       = [bool]$cDef.IsNetEtw
                IsCheckEnabled = (-not [bool]$cDef.IsLocked)
                IsChecked      = $initChecked
                RowVisibility  = "Visible"
            }
            $itemByKey[$ck] = $rowObj
            $availItems.Add($rowObj)
        }

        $lstAvailCols.ItemsSource = $availItems
        $lstColOrder.ItemsSource  = $orderItems
        &$rebuildOrderList ""

        # Sync Display Order when any checkbox in LstAvailableColumns toggles
        $lstAvailCols.AddHandler(
            [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
            [System.Windows.RoutedEventHandler]({
                param($s, $ev)
                if ($ev.OriginalSource -is [System.Windows.Controls.CheckBox] -and $ev.OriginalSource.DataContext) {
                    $ev.OriginalSource.DataContext.IsChecked = [bool]$ev.OriginalSource.IsChecked
                }
                if (-not $dlgState.SuppressRebuild) { &$rebuildOrderList "" }
            })
        )
        $lstAvailCols.AddHandler(
            [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
            [System.Windows.RoutedEventHandler]({
                param($s, $ev)
                if ($ev.OriginalSource -is [System.Windows.Controls.CheckBox] -and $ev.OriginalSource.DataContext) {
                    $ev.OriginalSource.DataContext.IsChecked = [bool]$ev.OriginalSource.IsChecked
                }
                if (-not $dlgState.SuppressRebuild) { &$rebuildOrderList "" }
            })
        )

        $applyFilter = {
            $q = if ($txtColFilter) { $txtColFilter.Text.Trim() } else { "" }
            foreach ($it in $availItems) {
                $vis = if ([string]::IsNullOrWhiteSpace($q)) {
                    "Visible"
                } elseif (
                    $it.Header.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $it.Group.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $it.Hint.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                ) {
                    "Visible"
                } else {
                    "Collapsed"
                }
                $it.RowVisibility = $vis
            }
            $lstAvailCols.ItemsSource = $null
            $lstAvailCols.ItemsSource = $availItems
        }

        if ($txtColFilter)      { $txtColFilter.add_TextChanged({ &$applyFilter }) }
        if ($btnColFilterClear) { $btnColFilterClear.add_Click({ $txtColFilter.Text = ""; $txtColFilter.Focus() }) }

        $applyPreset = {
            param([string[]]$visibleOrder)
            $dlgState.SuppressRebuild = $true
            try {
                $visSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                [void]$visSet.Add("Process")
                foreach ($vk in $visibleOrder) { [void]$visSet.Add($vk) }

                $newOrder = [System.Collections.Generic.List[string]]::new()
                $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                [void]$seen.Add("Process")
                $newOrder.Add("Process")
                foreach ($vk in $visibleOrder) {
                    if ($itemByKey.ContainsKey($vk) -and $seen.Add($vk)) { $newOrder.Add($vk) }
                }
                foreach ($cDef in $colCatalog) {
                    $ck = [string]$cDef.Key
                    if ($seen.Add($ck)) { $newOrder.Add($ck) }
                }
                $dlgState.OrderKeys = $newOrder

                foreach ($it in $availItems) {
                    $it.IsChecked = $visSet.Contains($it.Key)
                }
                $lstAvailCols.Items.Refresh()
            } finally {
                $dlgState.SuppressRebuild = $false
            }
            &$rebuildOrderList ""
        }

        if ($btnPresetDefault) {
            $btnPresetDefault.add_Click({
                $defKeys = @($colCatalog | Where-Object { $_.DefaultVisible } | ForEach-Object { [string]$_.Key })
                &$applyPreset $defKeys
            })
        }
        if ($btnPresetProcExp) {
            $btnPresetProcExp.add_Click({
                &$applyPreset @("Process", "CPU", "TreeCPU", "PrivateBytes", "WorkingSet", "PID", "Description", "CompanyName", "Version", "CommandLine", "User", "Handles")
            })
        }
        if ($btnPresetForensic) {
            $btnPresetForensic.add_Click({
                &$applyPreset @("Process", "PID", "ParentPID", "User", "SessionId", "Architecture", "StartTime", "Version", "CompanyName", "Path", "CommandLine")
            })
        }
        if ($btnResetCols) {
            $btnResetCols.add_Click({
                $defKeys = @($colCatalog | Where-Object { $_.DefaultVisible } | ForEach-Object { [string]$_.Key })
                &$applyPreset $defKeys
            })
        }

        $moveSelectedOrder = {
            param([int]$delta)
            $sel = $lstColOrder.SelectedItem
            if (-not $sel -or $sel.IsLocked) { return }
            $curVisIdx = $lstColOrder.SelectedIndex
            $nxtVisIdx = $curVisIdx + $delta
            if ($nxtVisIdx -lt 1 -or $nxtVisIdx -ge $orderItems.Count) { return }

            $targetKey = $orderItems[$nxtVisIdx].Key
            $idxA = $dlgState.OrderKeys.IndexOf($sel.Key)
            $idxB = $dlgState.OrderKeys.IndexOf($targetKey)
            if ($idxA -le 0 -or $idxB -le 0) { return }

            $dlgState.OrderKeys.RemoveAt($idxA)
            $insertAt = $dlgState.OrderKeys.IndexOf($targetKey)
            if ($delta -gt 0) { $insertAt++ }
            $dlgState.OrderKeys.Insert($insertAt, $sel.Key)
            &$rebuildOrderList $sel.Key
        }
        if ($btnMoveUp)   { $btnMoveUp.add_Click({ &$moveSelectedOrder -1 }) }
        if ($btnMoveDown) { $btnMoveDown.add_Click({ &$moveSelectedOrder 1 }) }

        if ($btnColOk) {
            $btnColOk.add_Click({ $scWin.DialogResult = $true })
        }

        if ($scWin.ShowDialog() -eq $true) {
            $script:UserVisibleCols.Clear()
            [void]$script:UserVisibleCols.Add("Process")
            $etwPickCount = 0
            foreach ($it in $availItems) {
                if ([bool]$it.IsChecked) {
                    if ([bool]$it.IsNetEtw) {
                        $etwPickCount++
                        switch ($it.Key) {
                            "NetTotal" { $script:ShowNetTotalCol = $true }
                            "TreeNet"  { $script:ShowTreeNetCol  = $true }
                            "NetRx"    { $script:ShowRxTxCols    = $true }
                            "NetTx"    { $script:ShowRxTxCols    = $true }
                        }
                    } else {
                        [void]$script:UserVisibleCols.Add([string]$it.Key)
                    }
                } else {
                    if ([bool]$it.IsNetEtw) {
                        switch ($it.Key) {
                            "NetTotal" { $script:ShowNetTotalCol = $false }
                            "TreeNet"  { $script:ShowTreeNetCol  = $false }
                            "NetRx"    { $script:ShowRxTxCols    = $false }
                            "NetTx"    { $script:ShowRxTxCols    = $false }
                        }
                    }
                }
            }
            if ($menuColTreeNet) { $menuColTreeNet.IsChecked = $script:ShowTreeNetCol }
            if ($menuColNetRxTx) { $menuColNetRxTx.IsChecked = $script:ShowRxTxCols }

            $script:ColumnOrderList.Clear()
            foreach ($ok in $dlgState.OrderKeys) { $script:ColumnOrderList.Add($ok) }
            &$applyColumnLayout $false
            &$markUnsavedPrefs "Columns"

            if ($etwPickCount -gt 0 -and -not $isNetActiveNow -and $statusText) {
                $statusText.Text = "Column layout updated. Enable Per-Process Network Monitoring (Ctrl+Shift+N) to show live Net ETW columns."
            }
            &$writeAuditLog "VIEW" ("Updated Process column layout ({0} active columns)." -f $script:UserVisibleCols.Count)
        }
    }

    $menuViewSelectColumns = $window.FindName("MenuViewSelectColumns")
    if ($menuViewSelectColumns) {
        $menuViewSelectColumns.add_Click({ &$openSelectColumnsDialog })
    }

    $procHeaderCtxMenu = $gridProcesses.TryFindResource("ProcessHeaderContextMenu")
    if ($procHeaderCtxMenu) {
        $procHeaderCtxMenu.add_Opened({
            param($sender, $e)
            $sender.Items.Clear()

            $clickedHeader = $sender.PlacementTarget
            $clickedColKey = ""
            if ($clickedHeader -is [System.Windows.Controls.Primitives.DataGridColumnHeader] -and $clickedHeader.Column) {
                if ($colKeyByObj.ContainsKey($clickedHeader.Column)) {
                    $clickedColKey = $colKeyByObj[$clickedHeader.Column]
                }
            }

            if ($clickedColKey -and $colDefByKey.Contains($clickedColKey)) {
                $cDefClicked = $colDefByKey[$clickedColKey]
                if (-not [bool]$cDefClicked.IsLocked) {
                    $miHide = [System.Windows.Controls.MenuItem]::new()
                    $miHide.Header = ("Hide '{0}'" -f $cDefClicked.Header)
                    $miHide.Tag = $clickedColKey
                    $miHide.add_Click({
                        param($s, $ev)
                        $tk = [string]$s.Tag
                        if ($colDefByKey[$tk].IsNetEtw) {
                            switch ($tk) {
                                "NetTotal" { $script:ShowNetTotalCol = $false }
                                "TreeNet"  { $script:ShowTreeNetCol  = $false }
                                "NetRx"    { $script:ShowRxTxCols    = $false }
                                "NetTx"    { $script:ShowRxTxCols    = $false }
                            }
                            if ($menuColTreeNet) { $menuColTreeNet.IsChecked = $script:ShowTreeNetCol }
                            if ($menuColNetRxTx) { $menuColNetRxTx.IsChecked = $script:ShowRxTxCols }
                        } else {
                            [void]$script:UserVisibleCols.Remove($tk)
                        }
                        &$applyColumnLayout $false
                        &$markUnsavedPrefs "Columns"
                    })
                    [void]$sender.Items.Add($miHide)
                    [void]$sender.Items.Add([System.Windows.Controls.Separator]::new())
                }
            }

            $quickKeys = @("CPU", "TreeCPU", "PrivateBytes", "WorkingSet", "PID", "ParentPID", "Description", "CompanyName", "Version", "CommandLine", "Path", "User", "Handles", "Threads", "SessionId", "Architecture", "StartTime", "Status")
            foreach ($qk in $quickKeys) {
                $qDef = $colDefByKey[$qk]
                if (-not $qDef) { continue }
                $mi = [System.Windows.Controls.MenuItem]::new()
                $mi.Header = [string]$qDef.Header
                $mi.IsCheckable = $true
                $mi.IsChecked = $script:UserVisibleCols.Contains($qk)
                $mi.Tag = $qk
                $mi.add_Click({
                    param($s, $ev)
                    $tk = [string]$s.Tag
                    if ([bool]$s.IsChecked) {
                        [void]$script:UserVisibleCols.Add($tk)
                    } else {
                        [void]$script:UserVisibleCols.Remove($tk)
                    }
                    &$applyColumnLayout $false
                    &$markUnsavedPrefs "Columns"
                })
                [void]$sender.Items.Add($mi)
            }

            [void]$sender.Items.Add([System.Windows.Controls.Separator]::new())

            $miSelect = [System.Windows.Controls.MenuItem]::new()
            $miSelect.Header = "Select Columns..."
            $miSelect.FontWeight = [System.Windows.FontWeights]::SemiBold
            $miSelect.add_Click({ &$openSelectColumnsDialog })
            [void]$sender.Items.Add($miSelect)

            $miFit = [System.Windows.Controls.MenuItem]::new()
            $miFit.Header = "Auto-Fit Visible Columns"
            $miFit.add_Click({ &$autoFitVisibleColumns })
            [void]$sender.Items.Add($miFit)

            $miReset = [System.Windows.Controls.MenuItem]::new()
            $miReset.Header = "Reset Columns to Default"
            $miReset.add_Click({ &$resetColumnsToDefault })
            [void]$sender.Items.Add($miReset)
        })
    }

    $applyPreferencesObject = {
        param([hashtable]$prefs, [bool]$overrideCli = $false)
        if (-not $prefs) { return }

        $prefsDirtyState.Suppress = $true
        try {
            $targetTheme = if (-not $overrideCli -and $Dark.IsPresent) {
                "Dark"
            } elseif (-not $overrideCli -and $PSBoundParameters.ContainsKey('Theme') -and $Theme) {
                $Theme
            } else {
                [string]$prefs.Theme
            }
            &$applyTheme $targetTheme
            &$setCategoryHighlighting ([bool]$prefs.EnableCategoryHighlights)

            $targetTopmost = if (-not $overrideCli -and $AlwaysOnTop.IsPresent) { $true } else { [bool]$prefs.AlwaysOnTop }
            &$setAlwaysOnTop $targetTopmost

            if ($menuConfirmKill) {
                $menuConfirmKill.IsChecked = [bool]$prefs.ConfirmKill
            }

            $verboseVal = [bool]$prefs.VerboseTelemetryLog
            $stateContainer.VerboseTelemetryLog = $verboseVal
            if ($menuVerbose)    { $menuVerbose.IsChecked    = $verboseVal }
            if ($chkStreamTicks) { $chkStreamTicks.IsChecked = $verboseVal }

            $autoScrollVal = [bool]$prefs.LogAutoScroll
            $stateContainer.LogAutoScroll = $autoScrollVal
            if ($chkLogAutoScroll) { $chkLogAutoScroll.IsChecked = $autoScrollVal }

            $targetRate = if (-not $overrideCli -and $PSBoundParameters.ContainsKey('RefreshIntervalMs')) {
                [int]$RefreshIntervalMs
            } else {
                [int]$prefs.RefreshIntervalMs
            }
            &$setPollingRate $targetRate $false

            $newestVal = [bool]$prefs.TreeSortNewestFirst
            $stateContainer.TreeSortNewestFirst = $newestVal
            if ($menuTreeOrderNewest)  { $menuTreeOrderNewest.IsChecked  = $newestVal }
            if ($menuTreeOrderClassic) { $menuTreeOrderClassic.IsChecked = (-not $newestVal) }

            if ($prefs.ContainsKey('VisibleColumns') -and $prefs.VisibleColumns) {
                $script:UserVisibleCols.Clear()
                [void]$script:UserVisibleCols.Add("Process")
                foreach ($vc in @($prefs.VisibleColumns)) {
                    $vcKey = [string]$vc
                    if ($colDefByKey.Contains($vcKey) -and -not [bool]$colDefByKey[$vcKey].IsNetEtw) {
                        [void]$script:UserVisibleCols.Add($vcKey)
                    }
                }
            }
            if ($prefs.ContainsKey('ColumnOrder') -and $prefs.ColumnOrder) {
                $script:ColumnOrderList.Clear()
                foreach ($oc in @($prefs.ColumnOrder)) {
                    $script:ColumnOrderList.Add([string]$oc)
                }
            }
            if ($prefs.ContainsKey('ColumnWidths') -and $prefs.ColumnWidths -is [System.Collections.IDictionary]) {
                $script:ColumnWidthsMap = @{}
                foreach ($wk in $prefs.ColumnWidths.Keys) {
                    $script:ColumnWidthsMap[[string]$wk] = [double]$prefs.ColumnWidths[$wk]
                }
            } else {
                $script:ColumnWidthsMap = @{}
            }
            &$applyColumnLayout $true

            if ([bool]$prefs.IsTreeMode) {
                &$setViewMode $true
            } else {
                $stateContainer.SortProperty   = [string]$prefs.SortProperty
                $stateContainer.SortDescending = [bool]$prefs.SortDescending
                foreach ($c in $gridProcesses.Columns) { $c.SortDirection = $null }
                $dir = if ($stateContainer.SortDescending) {
                    [System.ComponentModel.ListSortDirection]::Descending
                } else {
                    [System.ComponentModel.ListSortDirection]::Ascending
                }
                foreach ($c in $gridProcesses.Columns) {
                    if ($c.SortMemberPath -eq $stateContainer.SortProperty) {
                        $c.SortDirection = $dir
                        break
                    }
                }
                &$setViewMode $false
            }

            if ($logPane) {
                $reqLogH = if ($prefs.LogPaneHeight -ge $minLogPaneHeight) { [double]$prefs.LogPaneHeight } else { $defaultLogPaneHeight }
                $logPane.Height = $reqLogH
                if ([bool]$prefs.LogPaneVisible) {
                    $logPane.Visibility = "Visible"
                    & $clampLogPaneHeight $reqLogH
                    if ($menuViewLog) { $menuViewLog.IsChecked = $true }
                    if ($txtLogConsole -and $autoScrollVal) {
                        try {
                            $stateContainer.IsAppendingLog = $true
                            $txtLogConsole.ScrollToEnd()
                        } finally {
                            $stateContainer.IsAppendingLog = $false
                        }
                    }
                } else {
                    $logPane.Visibility = "Collapsed"
                    if ($menuViewLog) { $menuViewLog.IsChecked = $false }
                }
            }
        } finally {
            $prefsDirtyState.Suppress = $false
        }
    }

    if ($prefLoadResult.LoadedFromDisk) {
        &$applyPreferencesObject $savedPrefs $false
    }
    &$clearUnsavedPrefs

    if ($menuSavePreferences) {
        $menuSavePreferences.add_Click({
            try {
                $curLogH = if ($logPane -and -not [double]::IsNaN($logPane.Height) -and $logPane.Height -ge $minLogPaneHeight) {
                    [double]$logPane.Height
                } elseif ($logPane -and $logPane.ActualHeight -ge $minLogPaneHeight) {
                    [double]$logPane.ActualHeight
                } else {
                    $defaultLogPaneHeight
                }
                &$syncLiveOrderAndWidths
                $visColsSnap = [System.Collections.Generic.List[string]]::new()
                foreach ($ok in $script:ColumnOrderList) {
                    if ($script:UserVisibleCols.Contains($ok)) { $visColsSnap.Add($ok) }
                }
                $snapshot = @{
                    Theme                    = if ($stateContainer.CurrentTheme) { [string]$stateContainer.CurrentTheme } else { "Light" }
                    AlwaysOnTop              = [bool]$window.Topmost
                    EnableCategoryHighlights = [bool]$stateContainer.EnableCategoryHighlights
                    ConfirmKill              = if ($menuConfirmKill) { [bool]$menuConfirmKill.IsChecked } else { $true }
                    VerboseTelemetryLog      = [bool]$stateContainer.VerboseTelemetryLog
                    IsTreeMode               = [bool]$stateContainer.IsTreeMode
                    TreeSortNewestFirst      = [bool]$stateContainer.TreeSortNewestFirst
                    SortProperty             = if ($stateContainer.SortProperty) { [string]$stateContainer.SortProperty } else { "PID" }
                    SortDescending           = [bool]$stateContainer.SortDescending
                    RefreshIntervalMs        = [int]$stateContainer.IntervalMs
                    LogPaneVisible           = ($logPane -and $logPane.Visibility -eq "Visible")
                    LogPaneHeight            = $curLogH
                    LogAutoScroll            = [bool]$stateContainer.LogAutoScroll
                    VisibleColumns           = @($visColsSnap)
                    ColumnOrder              = @($script:ColumnOrderList)
                    ColumnWidths             = $script:ColumnWidthsMap
                }
                $savedPath = Save-PSRPMPreferences -Preferences $snapshot
                &$clearUnsavedPrefs
                &$writeAuditLog "PREFS" "Saved current preferences as default to '$savedPath' (opt-in persistence)."
                if ($statusText) {
                    $statusText.Text = "Saved current preferences as default ($savedPath)."
                }
            } catch {
                &$writeAuditLog "WARN" "Failed to save preferences: $($_.Exception.Message)"
            }
        })
    }

    if ($menuResetPreferences) {
        $menuResetPreferences.add_Click({
            try {
                $removed = Reset-PSRPMPreferences
                $factory = Get-PSRPMDefaultPreferences
                &$applyPreferencesObject $factory $true
                &$clearUnsavedPrefs
                $msg = if ($removed) {
                    "Deleted saved preferences file and restored factory defaults."
                } else {
                    "Restored factory default preferences."
                }
                &$writeAuditLog "PREFS" $msg
                if ($statusText) {
                    $statusText.Text = $msg
                }
            } catch {
                &$writeAuditLog "WARN" "Failed to reset preferences: $($_.Exception.Message)"
            }
        })
    }

    $getDialogOwnerWindow = {
        if ($script:ActivePropWin -and $script:ActivePropWin.IsLoaded -and $script:ActivePropWin.IsVisible) {
            return $script:ActivePropWin
        }
        if ($script:ActiveFindHandleWin -and $script:ActiveFindHandleWin.IsLoaded -and $script:ActiveFindHandleWin.IsActive) {
            return $script:ActiveFindHandleWin
        }
        return $window
    }

    $showMsgSafe = {
        param($primaryOwner, $fallbackOwner, [string]$msgText, [string]$msgTitle, $msgBtn, $msgImg)
        $resolvedOwner = if ($primaryOwner -and $primaryOwner.IsLoaded -and $primaryOwner.IsVisible) {
            $primaryOwner
        } elseif ($fallbackOwner -and $fallbackOwner.IsLoaded -and $fallbackOwner.IsVisible) {
            $fallbackOwner
        } else {
            $null
        }
        if ($resolvedOwner) {
            return [System.Windows.MessageBox]::Show($resolvedOwner, $msgText, $msgTitle, $msgBtn, $msgImg)
        }
        return [System.Windows.MessageBox]::Show($msgText, $msgTitle, $msgBtn, $msgImg)
    }

    $jumpToProcessInMainGrid = {
        param(
            [int]$pidVal,
            [bool]$openTcpProps = $false,
            [string]$procNameHint = "",
            $msgOwner = $null,
            [bool]$activateWindow = $false
        )
        $resolvedOwner = if ($msgOwner -and $msgOwner.IsLoaded -and $msgOwner.IsVisible) { $msgOwner } else { $window }
        if ($pidVal -le 0) {
            &$showMsgSafe $resolvedOwner $window "Kernel/TIME_WAIT endpoint (PID $pidVal) does not belong to an active process." "PSRPM - No Owning Process" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Information) | Out-Null
            return
        }
        if (-not $engineHandle.ProcessMap.ContainsKey($pidVal)) {
            $procDesc = if ($procNameHint) { "'$procNameHint' (PID $pidVal)" } else { "PID $pidVal" }
            &$showMsgSafe $resolvedOwner $window "Process $procDesc is no longer running in the process tree." "PSRPM - Process Not Found" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Information) | Out-Null
            return
        }
        $targetVm = $engineHandle.ProcessMap[$pidVal]
        if (-not $openTcpProps -and $mainTabs -and $mainTabs.SelectedIndex -ne 0) {
            $mainTabs.SelectedIndex = 0
        }
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
        if ($gridProcesses.Items -and -not $gridProcesses.Items.Contains($targetVm)) {
            if ($txtSearch) { $txtSearch.Text = "" }
            $stateContainer.FilterText     = ""
            $stateContainer.CategoryFilter = ""
            if ($updateLegendFilterUi) { &$updateLegendFilterUi }
            if ($engineHandle.RefreshTree) { & $engineHandle.RefreshTree }
        }
        if ($gridProcesses.SelectedItems.Count -gt 1) { $gridProcesses.SelectedItems.Clear() }
        $gridProcesses.SelectedItem = $targetVm
        if (-not $openTcpProps) { $gridProcesses.ScrollIntoView($targetVm) }
        if ($activateWindow -and $window) { [void]$window.Activate() }
        if ($openTcpProps -and $gridProcesses.SelectedItem -eq $targetVm) {
            $script:PendingPropTabIndex = 4
            &$actionShowProperties
        }
    }

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

        $ownerWin = & $getDialogOwnerWindow
        $batchCapable = $actionName -in @("KillProcess", "KillTree", "SuspendProcess", "ResumeProcess", "SetPriority")
        if ($selectedTargets.Count -eq 1 -or -not $batchCapable) {
            $singleVm = $selectedTargets[0]
            $tPid  = [int]$singleVm.PID
            $tName = [string]$singleVm.Name

            if ($tPid -le 4 -and $actionName -in @("KillProcess", "KillTree", "SuspendProcess", "CreateDump")) {
                &$showMsgSafe $ownerWin $window `
                    "Cannot perform '$actionName' on critical Windows kernel process '$tName' (PID $tPid)." `
                    "PSRPM - Protected Kernel Process" `
                    ([System.Windows.MessageBoxButton]::OK) `
                    ([System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }

            $confirmRequired = if ($menuConfirmKill) { [bool]$menuConfirmKill.IsChecked } else { $true }
            if ($confirmRequired -and $actionName -in @("KillProcess", "KillTree")) {
                $promptMsg = if ($actionName -eq "KillTree") {
                    "Are you sure you want to terminate '$tName' (PID $tPid) and ALL of its descendant child processes on $($stateContainer.TargetDisplayName)?"
                } else {
                    "Are you sure you want to terminate '$tName' (PID $tPid) on $($stateContainer.TargetDisplayName)?"
                }
                $confirm = &$showMsgSafe $ownerWin $window `
                    $promptMsg `
                    "PSRPM - Confirm Process Termination" `
                    ([System.Windows.MessageBoxButton]::YesNo) `
                    ([System.Windows.MessageBoxImage]::Warning)
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

            $localJss      = $jssAction
            $localLog      = $writeAuditLog
            $localState    = $stateContainer
            $localAfter    = $afterCallback
            $localAct      = $actionName
            $localOwner    = $ownerWin
            $localWindow   = $window
            $localMsgSafe  = $showMsgSafe
            $localCopyClip = $copyToClipboardSafe

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
                            [void](&$localCopyClip $dPath "" "")
                            &$localMsgSafe $localOwner $localWindow `
                                "Process memory dump created successfully!`n`nRemote Path:`n$dPath`n`n(The remote file path has been copied to your clipboard)." `
                                "PSRPM - Memory Dump Created" `
                                ([System.Windows.MessageBoxButton]::OK) `
                                ([System.Windows.MessageBoxImage]::Information) | Out-Null
                        }
                    } else {
                        &$localLog "WARN" "$($parsed['Message']) ($($res.ElapsedMs)ms)"
                        &$localMsgSafe $localOwner $localWindow ([string]$parsed['Message']) "PSRPM - Operation Warning" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Warning) | Out-Null
                    }
                } else {
                    &$localLog "ERROR" "$localAct failed: $($res.Error)"
                    &$localMsgSafe $localOwner $localWindow "Action '$localAct' failed:`n$($res.Error)" "PSRPM - Error" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Error) | Out-Null
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
                $ownerWin,
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
                $ownerWin,
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

        $localJss     = $jssAction
        $localLog     = $writeAuditLog
        $localState   = $stateContainer
        $localAfter   = $afterCallback
        $localAct     = $actionName
        $localTotal   = $dispatchTargets.Count
        $localOwner   = $ownerWin
        $localWindow  = $window
        $localMsgSafe = $showMsgSafe

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
                    &$localMsgSafe $localOwner $localWindow $summaryErr "PSRPM - Batch Operation Warning" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Warning) | Out-Null
                }
            } else {
                &$localLog "ERROR" "Batch $localAct failed: $($res.Error)"
                &$localMsgSafe $localOwner $localWindow "Batch action '$localAct' failed:`n$($res.Error)" "PSRPM - Error" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Error) | Out-Null
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
        $ownerWin = & $getDialogOwnerWindow
        $tPid  = [int]$procVm.PID
        $tName = [string]$procVm.Name
        if ($tPid -le 4) {
            [System.Windows.MessageBox]::Show(
                $ownerWin,
                "Cannot generate a memory dump for System process '$tName' (PID $tPid).",
                "PSRPM - Protected Kernel Process",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
            return
        }
        $typeLabel = if ($dumpType -eq "Full") { "Full Memory Dump (~$([Math]::Round($procVm.MemoryBytes / 1MB, 1)) MB)" } else { "Minidump" }
        $msg = "Generate $typeLabel for '$tName' (PID $tPid) on $($stateContainer.TargetDisplayName)?`n`nThe dump will be saved directly to '%SystemRoot%\Temp\PSRPM_Dumps' (or '%LOCALAPPDATA%\PSRPM\Dumps') on the target host."
        $confirm = [System.Windows.MessageBox]::Show(
            $ownerWin,
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

    $prioControlMap = @{
        MenuPrioIdle   = "Idle"
        MenuPrioBelow  = "BelowNormal"
        MenuPrioNormal = "Normal"
        MenuPrioAbove  = "AboveNormal"
        MenuPrioHigh   = "High"
        CtxPrioIdle    = "Idle"
        CtxPrioBelow   = "BelowNormal"
        CtxPrioNormal  = "Normal"
        CtxPrioAbove   = "AboveNormal"
        CtxPrioHigh    = "High"
    }
    $onPrioClick = {
        param($sender, $e)
        if ($sender -and $sender.Tag) {
            &$invokeProcessAction "SetPriority" $null ([string]$sender.Tag)
        }
    }
    foreach ($entry in $prioControlMap.GetEnumerator()) {
        $prioCtrl = $window.FindName($entry.Key)
        if ($prioCtrl) {
            $prioCtrl.Tag = $entry.Value
            $prioCtrl.add_Click($onPrioClick)
        }
    }

    $actionCopyCmdLine = {
        $sel = $gridProcesses.SelectedItem
        if ($sel -and $sel.CommandLine) {
            [void](&$copyToClipboardSafe $sel.CommandLine "CLIPBOARD" "Copied command line for $($sel.Name) (PID $($sel.PID)).")
        }
    }
    $actionCopyPath = {
        $sel = $gridProcesses.SelectedItem
        if ($sel -and $sel.Path) {
            [void](&$copyToClipboardSafe $sel.Path "CLIPBOARD" "Copied executable path for $($sel.Name) (PID $($sel.PID)).")
        }
    }

    $window.FindName("CtxEndProcess").add_Click({ &$invokeProcessAction "KillProcess" $null })
    $window.FindName("CtxEndTree").add_Click({ &$invokeProcessAction "KillTree" $null })
    $window.FindName("CtxSuspend").add_Click({ &$invokeProcessAction "SuspendProcess" $null })
    $window.FindName("CtxResume").add_Click({ &$invokeProcessAction "ResumeProcess" $null })
    $window.FindName("CtxCopyCmdLine").add_Click($actionCopyCmdLine)
    $window.FindName("CtxCopyPath").add_Click($actionCopyPath)
    $menuCopyCmdItem = $window.FindName("MenuCopyCmdLine")
    if ($menuCopyCmdItem) { $menuCopyCmdItem.add_Click($actionCopyCmdLine) }
    $menuCopyPathItem = $window.FindName("MenuCopyPath")
    if ($menuCopyPathItem) { $menuCopyPathItem.add_Click($actionCopyPath) }

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
        if ($menuCopyCmdItem)    { $menuCopyCmdItem.IsEnabled    = $singleEnabled }
        if ($menuCopyPathItem)   { $menuCopyPathItem.IsEnabled   = $singleEnabled }
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
            $svcSuccess = $false
            if ($res.Success -and $res.PayloadJson) {
                $parsed = $localJss.DeserializeObject($res.PayloadJson)
                if ($parsed -and $parsed['Success']) {
                    $svcSuccess = $true
                    &$localLog "SERVICE" "$($parsed['Message']) ($($res.ElapsedMs)ms)"
                } else {
                    $errMsg = if ($parsed -and $parsed['Message']) { [string]$parsed['Message'] } else { "Unknown service control failure." }
                    &$localLog "WARN" "$errMsg ($($res.ElapsedMs)ms)"
                }
            } else {
                &$localLog "ERROR" "Service action '$localSvcOp' on '$localSName' failed: $($res.Error)"
            }
            if ($localCb) {
                try {
                    &$localCb $res $svcSuccess
                } catch {
                    try { &$localLog "WARN" "Service UI callback failed: $($_.Exception.Message)" } catch {}
                }
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
        if ($selSvc -and $selSvc.PID -gt 0) {
            &$jumpToProcessInMainGrid ([int]$selSvc.PID) $false ([string]$selSvc.DisplayName) $window $false
        }
    }

    $registerDialogRenderFlush = {
        param([System.Windows.Window]$dlg)
        if (-not $dlg) { return }
        $dlg.Topmost = [bool]$window.Topmost
        $dlg.add_ContentRendered({
            param($s, $e)
            if ($s -is [System.Windows.UIElement]) {
                $s.InvalidateVisual()
            }
        })
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
        &$syncDialogThemeBrushes $svcWin

        $svcWin.Title = "$($selSvc.DisplayName) ($($selSvc.Name)) Details & Dependencies [$($stateContainer.TargetDisplayName)]"

        $svcWin.FindName("TxtDlgDisplayName").Text = $selSvc.DisplayName
        $svcWin.FindName("TxtDlgServiceName").Text = $selSvc.Name
        $svcWin.FindName("TxtDlgPid").Text = if ($selSvc.PID -gt 0) { [string]$selSvc.PID } else { "None" }

        $getSvcBadgeKey = {
            param([string]$st)
            if ($st -eq "Running") { return "BrushSvcRunningBg" }
            if ($st -eq "Paused" -or ($st -and $st.EndsWith("..."))) { return "BrushSvcPausedBg" }
            return "BrushSvcStoppedBg"
        }

        $badgeStatus = $svcWin.FindName("BadgeDlgStatus")
        $txtStatus   = $svcWin.FindName("TxtDlgStatus")
        $txtStatus.Text = $selSvc.Status.ToUpper()
        if ($badgeStatus) {
            $badgeStatus.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, (&$getSvcBadgeKey ([string]$selSvc.Status)))
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
                $badgeStatus.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, (&$getSvcBadgeKey $curStatus))
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

            $svcDlgCb = & {
                param($cEngine, $cSvcName, $cOp, $cUiFn, $cWin)
                return ({
                    param($res, [bool]$ok = $false)
                    if ($cWin -and -not $cWin.IsLoaded) { return }
                    if ($cEngine.ServicesMap.ContainsKey($cSvcName)) {
                        $live = $cEngine.ServicesMap[$cSvcName]
                        &$cUiFn $live.Status $live.PID
                    } elseif ($ok) {
                        $exp = if ($cOp -eq "Start") { "Running" } elseif ($cOp -eq "Stop") { "Stopped" } else { "Running" }
                        &$cUiFn $exp
                    } else {
                        &$cUiFn
                    }
                }.GetNewClosure())
            } $engineHandle ([string]$targetSvc.Name) $op $updateSvcDialogUi $localSvcWin

            &$localInvoke $op $targetSvc $svcDlgCb
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

        &$registerDialogRenderFlush $svcWin
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
                [void](&$copyToClipboardSafe $sel.Name "CLIPBOARD" "Copied service name '$($sel.Name)'.")
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

    $svcEmptyOverlay   = $window.FindName("SvcEmptyStateOverlay")
    $txtSvcEmptyTitle  = $window.FindName("TxtSvcEmptyTitle")
    $txtSvcEmptyHint   = $window.FindName("TxtSvcEmptyHint")
    $btnSvcEmptyClear  = $window.FindName("BtnSvcEmptyClear")

    $updateSvcSummaryText = {
        if ($null -eq $servicesCollection) { return }
        $totCount = $servicesCollection.Count
        $sTerm = if ($txtSearchServices) { $txtSearchServices.Text.Trim() } else { "" }
        if ($totCount -eq 0) {
            if ($txtSvcSummary) { $txtSvcSummary.Text = "0 Services" }
            if ($svcEmptyOverlay) { $svcEmptyOverlay.Visibility = [System.Windows.Visibility]::Collapsed }
            return
        }
        $runCount = 0
        foreach ($svm in $servicesCollection) {
            if ($svm.Status -eq "Running") { $runCount++ }
        }
        $stopCount = $totCount - $runCount
        $visCount = $totCount
        if ([string]::IsNullOrWhiteSpace($sTerm)) {
            if ($txtSvcSummary) { $txtSvcSummary.Text = "$totCount Services ($runCount Running, $stopCount Stopped)" }
        } else {
            $cv = [System.Windows.Data.CollectionViewSource]::GetDefaultView($servicesCollection)
            $visCount = 0
            if ($cv) { foreach ($ci in $cv) { $visCount++ } }
            if ($txtSvcSummary) { $txtSvcSummary.Text = "$visCount of $totCount Services ($runCount Running, $stopCount Stopped)" }
        }
        if ($svcEmptyOverlay) {
            if (-not [string]::IsNullOrWhiteSpace($sTerm) -and $visCount -eq 0) {
                if ($txtSvcEmptyTitle) { $txtSvcEmptyTitle.Text = ("No services match '{0}'" -f $sTerm) }
                if ($txtSvcEmptyHint)  { $txtSvcEmptyHint.Text  = ("Showing 0 of {0} Windows services on target host." -f $totCount) }
                $svcEmptyOverlay.Visibility = [System.Windows.Visibility]::Visible
            } else {
                $svcEmptyOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            }
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
    if ($btnSvcEmptyClear) {
        $btnSvcEmptyClear.add_Click({
            if ($txtSearchServices) { $txtSearchServices.Text = "" }
            &$updateServicesFilter
            if ($gridServices) { $gridServices.Focus() }
        })
    }

    # 13. Deep Process Properties Inspector Modal (6-Tab Sysinternals Process Explorer Layout)
    $script:PendingPropTabIndex = 0
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
        &$syncDialogThemeBrushes $propWin
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
                NodeBackground        = if ($isTarget) { if ($stateContainer.ThemePalette -and $stateContainer.ThemePalette.Brushes['BrushTargetNodeBg']) { $stateContainer.ThemePalette.Brushes['BrushTargetNodeBg'] } else { "#E0F2FE" } } else { "Transparent" }
                NodeBorderBrush       = if ($isTarget) { if ($stateContainer.ThemePalette -and $stateContainer.ThemePalette.Brushes['BrushAccent']) { $stateContainer.ThemePalette.Brushes['BrushAccent'] } else { "#0284C7" } } else { "Transparent" }
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
        if ($script:PendingPropTabIndex -gt 0 -and $propTabControl -and $script:PendingPropTabIndex -lt $propTabControl.Items.Count) {
            $propTabControl.SelectedIndex = [int]$script:PendingPropTabIndex
        }
        $script:PendingPropTabIndex = 0

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
                            $sigResKey = if ($sig['Status'] -eq "Valid") { "BrushSigSignedFg" } else { "BrushSigUnsignedFg" }
                            $sigBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $sigResKey)
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
                        $localPropWin.InvalidateVisual()

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
                    $txtCpu.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "BrushStatusExitedFg")
                }
                return
            }

            $liveTargetVm = $engineHandle.ProcessMap[$targetPid]

            # 1. Update CPU Counter (fix 0.00% idle and Suspended formatting)
            $txtCpu = $propWin.FindName("PropCpu")
            if ($txtCpu) {
                $cpuDisplay = if (-not $liveTargetVm.CPUFormatted) { "0.00%" } elseif ($liveTargetVm.CPUFormatted -eq "Suspended") { "Suspended" } else { "$($liveTargetVm.CPUFormatted)%" }
                $txtCpu.Text = "CPU Usage: $cpuDisplay (Base Priority: $($liveTargetVm.BasePriority))"
                $cpuFgKey = if ($liveTargetVm.CPU -gt 0) { "BrushStatusActiveFg" } else { "BrushStatusIdleFg" }
                $txtCpu.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $cpuFgKey)
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
            if ($selectedVm.Path) { [void](&$copyToClipboardSafe $selectedVm.Path "" "") }
        })
        $propWin.FindName("BtnCopyCmd").add_Click({
            if ($selectedVm.CommandLine) { [void](&$copyToClipboardSafe $selectedVm.CommandLine "" "") }
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
            $cb = & {
                param($cBtn, $cAct, $cRun, $cWin)
                return ({
                    param([bool]$ok = $false)
                    if (-not $ok) { return }
                    if ($cWin -and -not $cWin.IsLoaded) { return }
                    $cBtn.Content = if ($cAct -eq "SuspendProcess") { "Resume" } else { "Suspend" }
                    & $cRun $false "Core"
                }.GetNewClosure())
            } $btnSuspendResume $act $runDeepInspect $propWin
            &$invokeProcessAction $act $selectedVm "Normal" $cb
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
                    $propWin,
                    "Cannot close this handle entry ($($tVal): $nVal).",
                    "PSRPM - Close Handle",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                ) | Out-Null
                return
            }

            $warnMsg = "WARNING: Forcibly closing an active handle in '$pName' (PID $pidVal) can cause the target process to crash or become unstable.`n`nAre you sure you want to close handle $hVal ($nVal)?"
            $confirm = [System.Windows.MessageBox]::Show(
                $propWin,
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

        $copyPropHandleName = {
            if ($gridPropHandles.SelectedItem -and $gridPropHandles.SelectedItem.Name) {
                [void](&$copyToClipboardSafe ([string]$gridPropHandles.SelectedItem.Name) "" "")
            }
        }

        if ($ctxPropClose) {
            $ctxPropClose.add_Click({ & $closePropSelectedHandle })
        }
        if ($ctxPropCopyName) {
            $ctxPropCopyName.add_Click($copyPropHandleName)
        }
        if ($ctxPropCopyVal) {
            $ctxPropCopyVal.add_Click({
                if ($gridPropHandles.SelectedItem -and $gridPropHandles.SelectedItem.Handle) {
                    [void](&$copyToClipboardSafe ([string]$gridPropHandles.SelectedItem.Handle) "" "")
                }
            })
        }
        if ($gridPropHandles) {
            $gridPropHandles.add_KeyDown({
                param($s, $e)
                $mods = [System.Windows.Input.Keyboard]::Modifiers
                $isCtrl = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
                if ($e.Key -eq [System.Windows.Input.Key]::Delete) {
                    & $closePropSelectedHandle
                    $e.Handled = $true
                } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::C) {
                    & $copyPropHandleName
                    $e.Handled = $true
                }
            })
        }

        $mkCloseOnOkCb = {
            param($cWin)
            return ({
                param([bool]$ok = $false)
                if (-not $ok) { return }
                if ($cWin -and $cWin.IsLoaded) { $cWin.Close() }
            }.GetNewClosure())
        }
        $propWin.FindName("BtnPropEndProcess").add_Click({
            $cb = &$mkCloseOnOkCb $propWin
            &$invokeProcessAction "KillProcess" $selectedVm "Normal" $cb
        })
        $propWin.FindName("BtnPropEndTree").add_Click({
            $cb = &$mkCloseOnOkCb $propWin
            &$invokeProcessAction "KillTree" $selectedVm "Normal" $cb
        })
        $propWin.FindName("BtnCloseProp").add_Click({ $propWin.Close() })

        # Trigger Initial On-Demand Core Inspection on ContentRendered (prevents D3D9 partial dirty-rect race during ShowDialog)
        $propWin.Topmost = [bool]$window.Topmost
        $coreInspectState = @{ InitialCoreFired = $false }
        $propWin.add_ContentRendered({
            param($s, $e)
            if ($s -is [System.Windows.UIElement]) {
                $s.InvalidateVisual()
            }
            if (-not $coreInspectState.InitialCoreFired) {
                $coreInspectState.InitialCoreFired = $true
                & $runDeepInspect $false "Core"
            }
        })
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
            if ($script:SaveActiveTabFeatureState) { &$script:SaveActiveTabFeatureState $script:ActiveHostTab }
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
        $curThemeMode = if ($stateContainer.CurrentTheme) { [string]$stateContainer.CurrentTheme } elseif ([bool]$stateContainer.IsDarkTheme) { "Dark" } else { "Light" }
        $curCatHighlights = [bool]$stateContainer.EnableCategoryHighlights
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
                    $kvp.Value.EnableCategoryHighlights = $curCatHighlights
                    $kvp.Value.SetThemeMode($curThemeMode)
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

        # 5. Update Tab visual highlights & feature caches
        $curThemeMode = if ($stateContainer.CurrentTheme) { [string]$stateContainer.CurrentTheme } elseif ([bool]$stateContainer.IsDarkTheme) { "Dark" } else { "Light" }
        $canClose = ($hostTabsCollection.Count -gt 1)
        foreach ($tVm in $hostTabsCollection) {
            $tVm.UpdateVisualState(($tVm -eq $targetTabVm), $curThemeMode, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
        }
        if ($script:RestoreActiveTabFeatureState) { &$script:RestoreActiveTabFeatureState $targetTabVm }

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
            $curThemeMode = if ($stateContainer.CurrentTheme) { [string]$stateContainer.CurrentTheme } elseif ([bool]$stateContainer.IsDarkTheme) { "Dark" } else { "Light" }
            foreach ($tVm in $hostTabsCollection) {
                $tVm.UpdateVisualState(($tVm -eq $script:ActiveHostTab), $curThemeMode, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
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

    $syncTargetSwitchUi = {
        param($tabObj)
        $stateContainer.EnableNetEtw = $false
        $stateContainer.NetEtwCap = 0
        $stateContainer.NetEtwEventsPerSec = 0
        if ($updateNetEtwUi) { & $updateNetEtwUi 0 0 }
        if ($tabObj) {
            $tabObj.ComputerName = $stateContainer.TargetDisplayName
            $tabObj.Title        = $stateContainer.TargetDisplayName
            $tabObj.Transport    = $stateContainer.TransportBadge
            $tabObj.IsLocal      = ($stateContainer.ConnectionState -eq "LocalMode")
            $tabObj.ConnState    = [string]$stateContainer.ConnectionState
            if ($tabObj.TelemStats) {
                $tabObj.TelemStats.TotalWireBytes  = 0L
                $tabObj.TelemStats.TotalRawBytes   = 0L
                $tabObj.TelemStats.TotalTicks      = 0L
                $tabObj.TelemStats.TotalRttMs      = 0L
                $tabObj.TelemStats.LastReceivedSeq = 0
            }
            $canClose = ($hostTabsCollection.Count -gt 1)
            $curThemeMode = if ($stateContainer.CurrentTheme) { [string]$stateContainer.CurrentTheme } elseif ([bool]$stateContainer.IsDarkTheme) { "Dark" } else { "Light" }
            $tabObj.UpdateVisualState($true, $curThemeMode, $canClose, $stateContainer.ConnectionState, [bool]$stateContainer.IsPaused, $stateContainer.PollLatencyMs)
        }
        $window.Title = "PSRPM - PowerShell Remote Process Manager [$($stateContainer.TargetDisplayName)]"
        if ($script:ResetActiveTabFeatureState) { &$script:ResetActiveTabFeatureState $tabObj }
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
        &$syncDialogThemeBrushes $connWin

        $rbRemote      = $connWin.FindName("RbRemoteHost")
        $rbLocal       = $connWin.FindName("RbLocalOnly")
        $gridInputs    = $connWin.FindName("GridRemoteInputs")
        $txtComp       = $connWin.FindName("TxtConnectComputer")
        $chkSsl        = $connWin.FindName("ChkUseSSL")
        $txtPort       = $connWin.FindName("TxtConnectPort")
        $btnPickCred   = $connWin.FindName("BtnPickCredential")
        $txtCredStatus = $connWin.FindName("TxtCredStatus")
        $chkOpenNewTab = $connWin.FindName("ChkOpenInNewTab")
        $bdConnectErr  = $connWin.FindName("BdConnectError")
        $txtConnectErr = $connWin.FindName("TxtConnectError")
        $txtConnProg   = $connWin.FindName("TxtConnectProgress")
        $btnSubmit     = $connWin.FindName("BtnConnectSubmit")

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

        $setConnectBanner = {
            param([bool]$isError, [string]$msg)
            if ($isError) {
                if ($txtConnProg) { $txtConnProg.Visibility = [System.Windows.Visibility]::Collapsed }
                if ($txtConnectErr) { $txtConnectErr.Text = $msg }
                if ($bdConnectErr) { $bdConnectErr.Visibility = [System.Windows.Visibility]::Visible }
            } else {
                if ($bdConnectErr) { $bdConnectErr.Visibility = [System.Windows.Visibility]::Collapsed }
                if (-not [string]::IsNullOrWhiteSpace($msg) -and $txtConnProg) {
                    $txtConnProg.Text = $msg
                    $txtConnProg.Visibility = [System.Windows.Visibility]::Visible
                } elseif ($txtConnProg) {
                    $txtConnProg.Visibility = [System.Windows.Visibility]::Collapsed
                }
            }
        }
        $setConnectBusy = {
            param([bool]$busy)
            if ($btnSubmit)     { $btnSubmit.IsEnabled     = (-not $busy) }
            if ($rbRemote)      { $rbRemote.IsEnabled      = (-not $busy) }
            if ($rbLocal)       { $rbLocal.IsEnabled       = (-not $busy) }
            if ($chkOpenNewTab) { $chkOpenNewTab.IsEnabled = (-not $busy) }
            if ($gridInputs)    { $gridInputs.IsEnabled    = ((-not $busy) -and (-not [bool]$rbLocal.IsChecked)) }
        }

        $rbRemote.add_Checked({ $gridInputs.IsEnabled = $true; &$setConnectBanner $false "" })
        $rbLocal.add_Checked({  $gridInputs.IsEnabled = $false; &$setConnectBanner $false "" })
        if ($txtComp) { $txtComp.add_TextChanged({ &$setConnectBanner $false "" }) }
        if ($txtPort) { $txtPort.add_TextChanged({ &$setConnectBanner $false "" }) }

        $btnPickCred.add_Click({
            try {
                $c = Get-Credential
                if ($c) {
                    $credHolder.Value = $c
                    $txtCredStatus.Text = $c.UserName
                }
            } catch {}
        })

        $btnSubmit.add_Click({
            $useLocal = [bool]$rbLocal.IsChecked
            $compName = $txtComp.Text.Trim()
            if (-not $useLocal -and [string]::IsNullOrWhiteSpace($compName)) {
                &$setConnectBanner $true "Please enter a remote computer name or IP address."
                if ($txtComp) { [void]$txtComp.Focus() }
                return
            }

            $portText = $txtPort.Text.Trim()
            $portNum  = 0
            if (-not $useLocal -and -not [string]::IsNullOrWhiteSpace($portText)) {
                if (-not [int]::TryParse($portText, [ref]$portNum) -or $portNum -lt 1 -or $portNum -gt 65535) {
                    &$setConnectBanner $true "Custom WinRM port must be a number between 1 and 65535 (or leave blank for default 5985 / 5986)."
                    if ($txtPort) { [void]$txtPort.Focus() }
                    return
                }
            }
            $useSslVal = [bool]$chkSsl.IsChecked
            $openNew   = if ($chkOpenNewTab) { [bool]$chkOpenNewTab.IsChecked } else { $false }
            $targetLabel = if ($useLocal) { "$env:COMPUTERNAME" } else { $compName }

            &$setConnectBusy $true
            &$setConnectBanner $false $(if ($useLocal) { "Initializing Local-Only telemetry session for '$targetLabel'..." } else { "Connecting to '$targetLabel' via WinRM..." })

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
                $localSetBanner   = $setConnectBanner
                $localSetBusy     = $setConnectBusy

                & $localEngine.SendCommand $addCmd ({
                    param($res)
                    try {
                        if (-not $localConnWin -or -not $localConnWin.IsLoaded) { return }
                        &$localSetBusy $false
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
                            &$localSetBanner $true "Connection to '$localComp' failed: $($res.Error)`nTip: Choose 'Local Host Only' if WinRM is not configured, or verify firewall/TrustedHosts."
                        }
                    } catch {
                        &$localLog "ERROR" "AddTabSession UI callback error: $($_.Exception.Message)"
                        if ($localConnWin -and $localConnWin.IsLoaded) { $localConnWin.Close() }
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

                $localConnWin      = $connWin
                $localLog          = $writeAuditLog
                $localComp         = $compName
                $curTab            = $script:ActiveHostTab
                $localSyncTargetUi = $syncTargetSwitchUi
                $localSetBanner    = $setConnectBanner
                $localSetBusy      = $setConnectBusy

                & $engineHandle.SendCommand $switchCmd ({
                    param($res)
                    try {
                        if (-not $localConnWin -or -not $localConnWin.IsLoaded) { return }
                        &$localSetBusy $false
                        if ($res.Success) {
                            & $localSyncTargetUi $curTab
                            &$localLog "CONNECT" $res.Message
                            $localConnWin.Close()
                        } else {
                            &$localLog "ERROR" "Failed to connect to '$localComp': $($res.Error)"
                            &$localSetBanner $true "Connection to '$localComp' failed: $($res.Error)`nTip: Choose 'Local Host Only' if WinRM is not configured, or verify firewall/TrustedHosts."
                        }
                    } catch {
                        &$localLog "ERROR" "SwitchTarget UI callback error: $($_.Exception.Message)"
                        if ($localConnWin -and $localConnWin.IsLoaded) { $localConnWin.Close() }
                    }
                }.GetNewClosure())
            }
        })

        $connWin.FindName("BtnConnectCancel").add_Click({ $connWin.Close() })
        &$registerDialogRenderFlush $connWin
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
        $localLog          = $writeAuditLog
        $curTab            = $script:ActiveHostTab
        $localSyncTargetUi = $syncTargetSwitchUi
        & $engineHandle.SendCommand $switchLocalCmd ({
            param($res)
            if ($res.Success) {
                & $localSyncTargetUi $curTab
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
                [System.Windows.MessageBox]::Show($window, "Failed to export snapshot:`n$($_.Exception.Message)", "PSRPM - Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            }
        }
    }

    $window.FindName("MenuExportCsv").add_Click({ &$exportSnapshot "CSV" })
    $window.FindName("MenuExportJson").add_Click({ &$exportSnapshot "JSON" })
    $window.FindName("MenuExit").add_Click({ $window.Close() })

    # 15B. System Information Window & Interactive Graph Hover Telemetry
    $script:ActiveSysInfoWin    = $null
    $script:ActiveSysHoverState = $null

    $syncHoverTipBrushes = {
        param($tt, $resSource)
        if (-not $tt -or -not $resSource) { return }
        if ($resSource.Contains("BrushSurfaceBg"))   { $tt.Background  = $resSource["BrushSurfaceBg"] }
        if ($resSource.Contains("BrushTextPrimary")) { $tt.Foreground  = $resSource["BrushTextPrimary"] }
        if ($resSource.Contains("BrushAccent"))      { $tt.BorderBrush = $resSource["BrushAccent"] }
    }

    $createHoverTip = {
        param($ownerWin)
        $tt = [System.Windows.Controls.ToolTip]::new()
        $tt.Placement       = [System.Windows.Controls.Primitives.PlacementMode]::Relative
        $tt.HasDropShadow   = $true
        $tt.Padding         = [System.Windows.Thickness]::new(8, 5, 8, 5)
        $tt.BorderThickness = [System.Windows.Thickness]::new(1)
        $tt.FontFamily      = [System.Windows.Media.FontFamily]::new("Segoe UI")
        $tt.FontSize        = 11.5
        if ($ownerWin -and $ownerWin.Resources) {
            if ($ownerWin.Resources.Contains("BrushSurfaceBg"))   { $tt.Background  = $ownerWin.Resources["BrushSurfaceBg"] }
            if ($ownerWin.Resources.Contains("BrushTextPrimary")) { $tt.Foreground  = $ownerWin.Resources["BrushTextPrimary"] }
            if ($ownerWin.Resources.Contains("BrushAccent"))      { $tt.BorderBrush = $ownerWin.Resources["BrushAccent"] }
        }
        return $tt
    }

    $findVisualAncestorByTag = {
        param($obj, [string]$tagName)
        $cur = $obj
        while ($null -ne $cur) {
            if ($cur -is [System.Windows.FrameworkElement] -and ([string]$cur.Tag -eq $tagName)) {
                return $cur
            }
            if ($cur -is [System.Windows.Media.Visual] -or $cur -is [System.Windows.Media.Media3D.Visual3D]) {
                $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur)
            } elseif ($cur -is [System.Windows.FrameworkContentElement]) {
                $cur = $cur.Parent
            } else {
                break
            }
        }
        return $null
    }

    $findVisualChildByTag = {
        param($root, [string]$tagName)
        if ($null -eq $root) { return $null }
        $queue = [System.Collections.Generic.Queue[Object]]::new()
        $queue.Enqueue($root)
        while ($queue.Count -gt 0) {
            $node = $queue.Dequeue()
            if ($node -is [System.Windows.FrameworkElement] -and ([string]$node.Tag -eq $tagName)) {
                return $node
            }
            if ($node -is [System.Windows.Media.Visual] -or $node -is [System.Windows.Media.Media3D.Visual3D]) {
                $cnt = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                for ($ci = 0; $ci -lt $cnt; $ci++) {
                    $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $ci))
                }
            }
        }
        return $null
    }

    $closeHoverState = {
        param($hoverState)
        if (-not $hoverState) { return }
        if ($hoverState.ActiveEntry -and $hoverState.ActiveEntry.Crosshair) {
            $hoverState.ActiveEntry.Crosshair.Visibility = [System.Windows.Visibility]::Collapsed
        }
        if ($hoverState.ActiveCoreCrosshair) {
            $hoverState.ActiveCoreCrosshair.Visibility = [System.Windows.Visibility]::Collapsed
            $hoverState.ActiveCoreCrosshair = $null
        }
        $hoverState.ActiveEntry = $null
        if ($hoverState.ToolTip -and $hoverState.ToolTip.IsOpen) {
            $hoverState.ToolTip.IsOpen = $false
        }
    }

    $renderChartHoverAt = {
        param($hoverState, $entry, $ptSurface, $ptBorder, $syncTipFn)
        if (-not $hoverState -or -not $entry -or -not $entry.Border) { return }
        $summVm = if ($hoverState.DataSourceElement) { $hoverState.DataSourceElement.DataContext } else { $null }
        if (-not $summVm) { return }

        $tipText = ""
        if ($entry.IsStrip) {
            $tipText = $summVm.GetGraphHoverInfo("Net", 239, $false) + "`nDouble-click for Network tab"
        } else {
            $surf = $entry.Surface
            if (-not $surf) { return }
            $surfW = if ($surf.Width -gt 0 -and -not [double]::IsNaN($surf.Width)) { [double]$surf.Width } else { [double]$surf.ActualWidth }
            if ($surfW -le 1.0) { return }

            $count = if ($entry.IsCore) { 60 } elseif ($entry.IsMini) { 30 } else { 240 }
            $clampedX = [Math]::Max(0.0, [Math]::Min($surfW, [double]$ptSurface.X))
            $frac = $clampedX / $surfW
            $idx  = [int][Math]::Round($frac * [double]($count - 1))
            $snapX = ($idx / [double][Math]::Max(1, $count - 1)) * $surfW
            $lineX = [Math]::Max(0.5, [Math]::Min($surfW - 0.5, $snapX))

            if ($entry.Crosshair) {
                $entry.Crosshair.X1 = $lineX
                $entry.Crosshair.X2 = $lineX
                if ($entry.Crosshair.Visibility -ne [System.Windows.Visibility]::Visible) {
                    $entry.Crosshair.Visibility = [System.Windows.Visibility]::Visible
                }
            }

            if ($entry.IsCore) {
                $tipText = $summVm.GetCoreHoverInfo($entry.CoreVm, $idx)
            } else {
                $tipText = $summVm.GetGraphHoverInfo([string]$entry.ChartKey, $idx, [bool]$entry.IsMini)
                if ($entry.FooterHint) { $tipText += "`n$($entry.FooterHint)" }
            }
        }

        if ([string]::IsNullOrWhiteSpace($tipText)) { return }
        $tt = $hoverState.ToolTip
        if (-not $tt) { return }
        $resDict = if ($hoverState.ResourceWindow) { $hoverState.ResourceWindow.Resources } else { $null }
        & $syncTipFn $tt $resDict
        $tt.PlacementTarget  = $entry.Border
        $tt.Content          = $tipText
        $tt.HorizontalOffset = [double]$ptBorder.X + 14.0
        $tt.VerticalOffset   = [double]$ptBorder.Y + 18.0
        if (-not $tt.IsOpen) { $tt.IsOpen = $true }
    }

    $bindChartHover = {
        param($hoverState, $border, $surface, $crosshair, [string]$chartKey, [bool]$isMini, [bool]$isStrip, [string]$footerHint)
        if (-not $hoverState -or -not $border) { return }
        $entry = @{
            Border     = $border
            Surface    = $surface
            Crosshair  = $crosshair
            ChartKey   = $chartKey
            IsMini     = $isMini
            IsCore     = $false
            IsStrip    = $isStrip
            CoreVm     = $null
            FooterHint = $footerHint
        }

        $localState    = $hoverState
        $localEntry    = $entry
        $localRender   = $renderChartHoverAt
        $localSyncTip  = $syncHoverTipBrushes
        $localClose    = $closeHoverState

        $border.add_MouseMove({
            param($s, $e)
            $ptBorder  = $e.GetPosition($localEntry.Border)
            $ptSurface = if ($localEntry.Surface) { $e.GetPosition($localEntry.Surface) } else { $ptBorder }
            if ($localState.ActiveCoreCrosshair) {
                $localState.ActiveCoreCrosshair.Visibility = [System.Windows.Visibility]::Collapsed
                $localState.ActiveCoreCrosshair = $null
            }
            if ($localState.ActiveEntry -and ($localState.ActiveEntry.Border -ne $localEntry.Border) -and $localState.ActiveEntry.Crosshair) {
                $localState.ActiveEntry.Crosshair.Visibility = [System.Windows.Visibility]::Collapsed
            }
            $localState.ActiveEntry  = $localEntry
            $localState.LastPtSurface = $ptSurface
            $localState.LastPtBorder  = $ptBorder
            & $localRender $localState $localEntry $ptSurface $ptBorder $localSyncTip
        }.GetNewClosure())

        $border.add_MouseLeave({
            param($s, $e)
            if ($localEntry.Crosshair) {
                $localEntry.Crosshair.Visibility = [System.Windows.Visibility]::Collapsed
            }
            if ($localState.ActiveEntry -and ($localState.ActiveEntry.Border -eq $localEntry.Border)) {
                & $localClose $localState
            }
        }.GetNewClosure())
    }

    $mainHoverState = @{
        ToolTip             = (& $createHoverTip $window)
        DataSourceElement   = $summaryBar
        ResourceWindow      = $window
        ActiveEntry         = $null
        ActiveCoreCrosshair = $null
        LastPtSurface       = [System.Windows.Point]::new(0, 0)
        LastPtBorder        = [System.Windows.Point]::new(0, 0)
    }
    $window.add_Deactivated({ & $closeHoverState $mainHoverState }.GetNewClosure())
    $window.add_StateChanged({
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            & $closeHoverState $mainHoverState
        }
    }.GetNewClosure())

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
        &$syncDialogThemeBrushes $sysWin
        $activeSumm.IsSysInfoOpen = $true
        $activeSumm.RefreshSysInfoGraphs()
        if ($activeSumm.ShowOneGraphPerCpu) {
            foreach ($cg in $activeSumm.CoreGraphs) { $cg.BuildCoreGeometry() }
        }

        $tcSys = $sysWin.FindName("SysInfoTabControl")
        if ($tcSys -and $initialTabIndex -ge 0 -and $initialTabIndex -lt $tcSys.Items.Count) {
            $tcSys.SelectedIndex = $initialTabIndex
        }

        $sysHoverState = @{
            ToolTip             = (& $createHoverTip $sysWin)
            DataSourceElement   = $sysWin
            ResourceWindow      = $sysWin
            ActiveEntry         = $null
            ActiveCoreCrosshair = $null
            LastPtSurface       = [System.Windows.Point]::new(0, 0)
            LastPtBorder        = [System.Windows.Point]::new(0, 0)
        }
        $script:ActiveSysHoverState = $sysHoverState

        if ($tcSys) {
            $localCloseTabHover = $closeHoverState
            $localTabState      = $sysHoverState
            $tcSys.add_SelectionChanged({ & $localCloseTabHover $localTabState }.GetNewClosure())
        }
        $localDeactClose = $closeHoverState
        $localDeactState = $sysHoverState
        $sysWin.add_Deactivated({ & $localDeactClose $localDeactState }.GetNewClosure())

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
        $qNet = $sysWin.FindName("QuadNet")
        if ($qNet -and $tcSys) {
            $qNet.add_MouseLeftButtonDown({ param($s,$e) if ($e.ClickCount -eq 2) { $tcSys.SelectedIndex = 4; $e.Handled = $true } }.GetNewClosure())
        }
        $btnOpenNetTab = $sysWin.FindName("BtnOpenNetworkTab")
        if ($btnOpenNetTab -and $tcSys) {
            $btnOpenNetTab.add_Click({ $tcSys.SelectedIndex = 4 }.GetNewClosure())
        }

        # Wire interactive hover + crosshair tracking on all SysInfo charts
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderQuadCpuChart"))    ($sysWin.FindName("CanvasQuadCpu"))    ($sysWin.FindName("CrosshairQuadCpu"))    "Cpu"    $false $false "Double-click to open CPU tab"
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderQuadCommitChart")) ($sysWin.FindName("CanvasQuadCommit")) ($sysWin.FindName("CrosshairQuadCommit")) "Commit" $false $false "Double-click to open Memory tab"
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderQuadRamChart"))    ($sysWin.FindName("CanvasQuadRam"))    ($sysWin.FindName("CrosshairQuadRam"))    "Ram"    $false $false "Double-click to open Memory tab"
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderQuadIoChart"))     ($sysWin.FindName("CanvasQuadIo"))     ($sysWin.FindName("CrosshairQuadIo"))     "Io"     $false $false "Double-click to open I/O tab"
        & $bindChartHover $sysHoverState $qNet $null $null "Net" $false $true ""
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderSysCpuChart"))     ($sysWin.FindName("CanvasSysCpu"))     ($sysWin.FindName("CrosshairSysCpu"))     "Cpu"    $false $false ""
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderMemCommitChart"))  ($sysWin.FindName("CanvasMemCommit"))  ($sysWin.FindName("CrosshairMemCommit"))  "Commit" $false $false ""
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderMemRamChart"))     ($sysWin.FindName("CanvasMemRam"))     ($sysWin.FindName("CrosshairMemRam"))     "Ram"    $false $false ""
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderSysIoChart"))      ($sysWin.FindName("CanvasSysIo"))      ($sysWin.FindName("CrosshairSysIo"))      "Io"     $false $false ""
        & $bindChartHover $sysHoverState ($sysWin.FindName("BorderSysNetChart"))     ($sysWin.FindName("CanvasSysNet"))     ($sysWin.FindName("CrosshairSysNet"))     "Net"    $false $false ""

        $itemsCoreGraphs = $sysWin.FindName("ItemsCoreGraphs")
        if ($itemsCoreGraphs) {
            $localCoreState   = $sysHoverState
            $localFindAnc     = $findVisualAncestorByTag
            $localFindChild   = $findVisualChildByTag
            $localCoreRender  = $renderChartHoverAt
            $localCoreSyncTip = $syncHoverTipBrushes
            $localCoreClose   = $closeHoverState

            $itemsCoreGraphs.add_MouseMove({
                param($s, $e)
                $coreBorder = & $localFindAnc $e.OriginalSource "CoreChartBorder"
                if (-not $coreBorder) {
                    & $localCoreClose $localCoreState
                    return
                }
                $coreVm = $coreBorder.DataContext
                if (-not $coreVm) { return }
                $coreCanvas = & $localFindChild $coreBorder "CoreCanvas"
                if (-not $coreCanvas) { return }
                $coreCrosshair = & $localFindChild $coreBorder "CoreCrosshair"

                if ($localCoreState.ActiveCoreCrosshair -and ($localCoreState.ActiveCoreCrosshair -ne $coreCrosshair)) {
                    $localCoreState.ActiveCoreCrosshair.Visibility = [System.Windows.Visibility]::Collapsed
                }
                $localCoreState.ActiveCoreCrosshair = $coreCrosshair

                $ptBorder  = $e.GetPosition($coreBorder)
                $ptSurface = $e.GetPosition($coreCanvas)
                $coreEntry = @{
                    Border     = $coreBorder
                    Surface    = $coreCanvas
                    Crosshair  = $coreCrosshair
                    ChartKey   = "Core"
                    IsMini     = $false
                    IsCore     = $true
                    IsStrip    = $false
                    CoreVm     = $coreVm
                    FooterHint = ""
                }
                $localCoreState.ActiveEntry   = $coreEntry
                $localCoreState.LastPtSurface = $ptSurface
                $localCoreState.LastPtBorder  = $ptBorder
                & $localCoreRender $localCoreState $coreEntry $ptSurface $ptBorder $localCoreSyncTip
            }.GetNewClosure())

            $itemsCoreGraphs.add_MouseLeave({
                & $localCoreClose $localCoreState
            }.GetNewClosure())
        }

        $chkPerCpu = $sysWin.FindName("ChkPerCpuGraph")
        if ($chkPerCpu) {
            $localSumm         = $activeSumm
            $localCpuHoverChk  = $sysHoverState
            $localCpuCloseFn   = $closeHoverState
            $chkPerCpu.add_Checked({
                & $localCpuCloseFn $localCpuHoverChk
                $localSumm.SetPerCpuMode($true)
            }.GetNewClosure())
            $chkPerCpu.add_Unchecked({
                & $localCpuCloseFn $localCpuHoverChk
                $localSumm.SetPerCpuMode($false)
            }.GetNewClosure())
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

        $localCloseSumm     = $activeSumm
        $localSysHoverClose = $sysHoverState
        $localCloseHoverFn  = $closeHoverState
        $localClearSysWin   = {
            $script:ActiveSysInfoWin    = $null
            $script:ActiveSysHoverState = $null
        }
        $sysWin.add_Closed({
            & $localCloseHoverFn $localSysHoverClose
            $localCloseSumm.IsSysInfoOpen = $false
            & $localClearSysWin
        }.GetNewClosure())

        $script:ActiveSysInfoWin = $sysWin
        &$registerDialogRenderFlush $sysWin
        $sysWin.Show()
    }

    $menuSysInfo    = $window.FindName("MenuSystemInfo")
    $cardMiniCpu    = $window.FindName("CardMiniCpu")
    $cardMiniCommit = $window.FindName("CardMiniCommit")
    $cardMiniRam    = $window.FindName("CardMiniRam")

    & $bindChartHover $mainHoverState $cardMiniCpu    ($window.FindName("GridMiniCpu"))    ($window.FindName("CrosshairMiniCpu"))    "Cpu"    $true $false ""
    & $bindChartHover $mainHoverState $cardMiniCommit ($window.FindName("GridMiniCommit")) ($window.FindName("CrosshairMiniCommit")) "Commit" $true $false ""
    & $bindChartHover $mainHoverState $cardMiniRam    ($window.FindName("GridMiniRam"))    ($window.FindName("CrosshairMiniRam"))    "Ram"    $true $false ""

    if ($menuSysInfo) {
        $menuSysInfo.add_Click({ &$actionShowSystemInfo 0 })
    }
    if ($cardMiniCpu) {
        $cardMiniCpu.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                &$actionShowSystemInfo 1
                $e.Handled = $true
            }
        })
    }
    if ($cardMiniCommit) {
        $cardMiniCommit.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                &$actionShowSystemInfo 2
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
    $txtTelemDiskRate = $window.FindName("TxtTelemDiskRate")
    if ($txtTelemDiskRate) {
        $txtTelemDiskRate.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                &$actionShowSystemInfo 3
                $e.Handled = $true
            }
        })
    }
    $borderTelemNetRate = $window.FindName("BorderTelemNetRate")
    if ($borderTelemNetRate) {
        $borderTelemNetRate.add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                &$actionShowSystemInfo 4
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
            &$syncDialogThemeBrushes $helpWin

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

            &$registerDialogRenderFlush $helpWin
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

    $btnToolbarHelp = $window.FindName("BtnToolbarHelp")
    if ($btnToolbarHelp) { $btnToolbarHelp.add_Click({ &$actionShowHelp 0 }) }

    # 15C. Find Handle or DLL Window (Ctrl+Shift+F or Find Menu / Toolbar)
    $script:ActiveFindHandleWin  = $null
    $script:FindHandleControls   = @{}
    $script:FindHandleResultsCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $findSearchState = @{
        ActiveGen = 0
        IsScanning = $false
        StartUtc  = [DateTime]::MinValue
        Query     = ""
        Target    = ""
        Timer     = $null
    }

    $cancelHandleSearch = {
        param([string]$reasonText = "Search cancelled.")
        $findSearchState.ActiveGen = ([int]$findSearchState.ActiveGen) + 1
        $findSearchState.IsScanning = $false
        if ($findSearchState.Timer) {
            try { $findSearchState.Timer.Stop() } catch {}
        }
        $ctrls     = $script:FindHandleControls
        $btnSearch = $ctrls['BtnSearchHandle']
        $btnCancel = $ctrls['BtnCancelSearchHandle']
        $pbSearch  = $ctrls['PbHandleSearch']
        $txtStatus = $ctrls['TxtHandleStatus']
        if ($btnSearch) { $btnSearch.IsEnabled = $true }
        if ($btnCancel) { $btnCancel.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($pbSearch)  { $pbSearch.Visibility  = [System.Windows.Visibility]::Collapsed }
        if ($txtStatus -and $reasonText) { $txtStatus.Text = $reasonText }
    }

    $executeHandleSearch = {
        $ctrls     = $script:FindHandleControls
        $txtBox    = $ctrls['TxtSearchHandle']
        $btnSearch = $ctrls['BtnSearchHandle']
        $btnCancel = $ctrls['BtnCancelSearchHandle']
        $pbSearch  = $ctrls['PbHandleSearch']
        $txtStatus = $ctrls['TxtHandleStatus']
        $findWin   = $script:ActiveFindHandleWin
        $localCol  = $script:FindHandleResultsCol

        $q = if ($txtBox) { $txtBox.Text.Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($q)) {
            if ($txtStatus) { $txtStatus.Text = "Please enter a file name, folder path, DLL, or key substring to search." }
            return
        }

        $findSearchState.ActiveGen  = ([int]$findSearchState.ActiveGen) + 1
        $findSearchState.IsScanning = $true
        $findSearchState.StartUtc   = [DateTime]::UtcNow
        $findSearchState.Query      = $q
        $findSearchState.Target     = [string]$stateContainer.TargetDisplayName
        $myGen      = [int]$findSearchState.ActiveGen
        $localState = $findSearchState

        if ($btnSearch) { $btnSearch.IsEnabled = $false }
        if ($btnCancel) { $btnCancel.Visibility = [System.Windows.Visibility]::Visible }
        if ($pbSearch)  { $pbSearch.Visibility  = [System.Windows.Visibility]::Visible }
        if ($txtStatus) { $txtStatus.Text = "Searching across processes on '$($stateContainer.TargetDisplayName)' for '$q'... (0.0s)" }
        if ($findSearchState.Timer) { $findSearchState.Timer.Start() }

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
                    if ([int]$localState.ActiveGen -ne $myGen) { return }
                    $localState.IsScanning = $false
                    if ($localState.Timer) {
                        try { $localState.Timer.Stop() } catch {}
                    }
                    if ($btnSearch) { $btnSearch.IsEnabled = $true }
                    if ($btnCancel) { $btnCancel.Visibility = [System.Windows.Visibility]::Collapsed }
                    if ($pbSearch)  { $pbSearch.Visibility  = [System.Windows.Visibility]::Collapsed }
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

        $findOwner = if ($script:ActiveFindHandleWin -and $script:ActiveFindHandleWin.IsLoaded -and $script:ActiveFindHandleWin.IsVisible) { $script:ActiveFindHandleWin } else { $window }
        if ($tVal -eq "DLL" -or [string]::IsNullOrWhiteSpace($hVal) -or $hVal -eq "N/A" -or ($tVal -and $tVal.StartsWith("["))) {
            [System.Windows.MessageBox]::Show(
                $findOwner,
                "Cannot close this handle entry ($($tVal): $nVal).",
                "PSRPM - Close Handle",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
            return
        }

        $warnMsg = "WARNING: Forcibly closing an active handle in '$pName' (PID $pidVal) can cause the target process to crash or become unstable.`n`nAre you sure you want to close handle $hVal ($nVal)?"
        $confirm = [System.Windows.MessageBox]::Show(
            $findOwner,
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
        $sel = $gridHandles.SelectedItem
        $findOwner = if ($script:ActiveFindHandleWin -and $script:ActiveFindHandleWin.IsLoaded -and $script:ActiveFindHandleWin.IsVisible) { $script:ActiveFindHandleWin } else { $window }
        &$jumpToProcessInMainGrid ([int]$sel.PID) $false ([string]$sel.ProcessName) $findOwner $true
    }

    $copySelectedPath = {
        $gridHandles = $script:FindHandleControls['GridHandleResults']
        if ($gridHandles -and $gridHandles.SelectedItem) {
            $sel = $gridHandles.SelectedItem
            if ($sel.Name) {
                [void](&$copyToClipboardSafe ([string]$sel.Name) "CLIPBOARD" "Copied object path '$($sel.Name)'.")
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
        &$syncDialogThemeBrushes $findWin

        $txtSearchHandle      = $findWin.FindName("TxtSearchHandle")
        $btnSearchHandle      = $findWin.FindName("BtnSearchHandle")
        $btnCancelSearch      = $findWin.FindName("BtnCancelSearchHandle")
        $pbHandleSearch       = $findWin.FindName("PbHandleSearch")
        $txtHandleStatus      = $findWin.FindName("TxtHandleStatus")
        $gridHandles          = $findWin.FindName("GridHandleResults")
        $ctxCloseHandle       = $findWin.FindName("CtxCloseHandle")
        $ctxGoToProcess       = $findWin.FindName("CtxGoToProcess")
        $ctxCopyPath          = $findWin.FindName("CtxCopyPath")
        $btnCloseHandle       = $findWin.FindName("BtnCloseHandle")
        $btnGoToProcess       = $findWin.FindName("BtnGoToProcess")
        $btnCopyPath          = $findWin.FindName("BtnCopyPath")
        $btnCloseDlg          = $findWin.FindName("BtnCloseDlg")

        if ($txtSearchHandle) { $txtSearchHandle.Text = "" }
        if ($txtHandleStatus) { $txtHandleStatus.Text = "Enter a file name, folder path, DLL, or registry key to search across processes." }

        $script:ActiveFindHandleWin = $findWin
        $script:FindHandleControls = @{
            TxtSearchHandle       = $txtSearchHandle
            BtnSearchHandle       = $btnSearchHandle
            BtnCancelSearchHandle = $btnCancelSearch
            PbHandleSearch        = $pbHandleSearch
            TxtHandleStatus       = $txtHandleStatus
            GridHandleResults     = $gridHandles
        }

        $findSearchState.IsScanning = $false
        $findTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background, $findWin.Dispatcher)
        $findTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $findTimer.add_Tick({
            if ($findSearchState.IsScanning -and $script:FindHandleControls['TxtHandleStatus']) {
                $elSec = ([DateTime]::UtcNow - $findSearchState.StartUtc).TotalSeconds
                $script:FindHandleControls['TxtHandleStatus'].Text = ("Searching '{0}' across processes on '{1}'... ({2:F1}s)" -f $findSearchState.Query, $findSearchState.Target, $elSec)
            }
        })
        $findSearchState.Timer = $findTimer

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
        if ($btnCancelSearch) { $btnCancelSearch.add_Click({ &$cancelHandleSearch "Search cancelled by user." }) }
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
            $mods = [System.Windows.Input.Keyboard]::Modifiers
            $isCtrl = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                if ($findSearchState.IsScanning) {
                    &$cancelHandleSearch "Search cancelled by user."
                } elseif ($script:ActiveFindHandleWin) {
                    $script:ActiveFindHandleWin.Close()
                }
                $e.Handled = $true
            } elseif ($e.Key -eq [System.Windows.Input.Key]::Delete -and $dg -and $dg.IsKeyboardFocusWithin) {
                &$closeSelectedHandle
                $e.Handled = $true
            } elseif ($e.Key -eq [System.Windows.Input.Key]::Enter -and $dg -and $dg.IsKeyboardFocusWithin) {
                &$goToProcessInTree
                $e.Handled = $true
            } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::C -and $dg -and $dg.IsKeyboardFocusWithin) {
                &$copySelectedPath
                $e.Handled = $true
            }
        })

        $findWin.add_Closed({
            &$cancelHandleSearch ""
            $findSearchState.Timer = $null
            for ($i = $script:FindHandleResultsCol.Count - 1; $i -ge 0; $i--) { $script:FindHandleResultsCol.RemoveAt($i) }
            $script:ActiveFindHandleWin = $null
            $script:FindHandleControls.Clear()
        })

        &$registerDialogRenderFlush $findWin
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

    $syncNetColumnVisibility = {
        &$applyColumnLayout $false
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
                    $ellNetEtwDot.Fill = &$getFrozenBrush "#0EA5E9"
                    $txtNetEtwBtn.Text = if ($evRate -gt 0) { "Net ETW ($evRate/s)" } else { "Net ETW: ON" }
                }
                2 {
                    $ellNetEtwDot.Fill = &$getFrozenBrush "#F59E0B"
                    $txtNetEtwBtn.Text = "Net ETW (Paused)"
                }
                3 {
                    $ellNetEtwDot.Fill = &$getFrozenBrush "#64748B"
                    $txtNetEtwBtn.Text = "Net ETW (Admin)"
                }
                default {
                    $ellNetEtwDot.Fill = &$getFrozenBrush "#94A3B8"
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
                $palBanner = if ($stateContainer.ThemePalette) { $stateContainer.ThemePalette } else { [PSRPMThemeRegistry]::GetPalette($(if ($stateContainer.CurrentTheme) { $stateContainer.CurrentTheme } else { "Light" })) }
                $netEtwAlertBanner.Visibility = [System.Windows.Visibility]::Visible
                if ($cap -eq 2) {
                    $c2 = $palBanner.Banner.Cap2
                    $netEtwAlertBanner.Background  = &$getFrozenBrush $c2.Bg
                    $netEtwAlertBanner.BorderBrush = &$getFrozenBrush $c2.Border
                    if ($bdNetEtwBannerBadge)  { $bdNetEtwBannerBadge.Background = &$getFrozenBrush $c2.BadgeBg }
                    if ($txtNetEtwBannerBadge) { $txtNetEtwBannerBadge.Text = "CIRCUIT BREAKER" }
                    if ($txtNetEtwBannerMsg)   {
                        $txtNetEtwBannerMsg.Text = "Per-process Network ETW auto-paused after exceeding 25,000 events/sec ($evRate/s) to protect host CPU. Click Resume to restart."
                        $txtNetEtwBannerMsg.Foreground = &$getFrozenBrush $c2.Fg
                    }
                    if ($btnNetEtwResume) {
                        $btnNetEtwResume.Visibility  = [System.Windows.Visibility]::Visible
                        $btnNetEtwResume.Background  = &$getFrozenBrush $c2.BtnBg
                        $btnNetEtwResume.Foreground  = &$getFrozenBrush $c2.BtnFg
                    }
                    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.Foreground = &$getFrozenBrush $c2.Fg }
                    if ($btnNetEtwDismiss) { $btnNetEtwDismiss.Foreground = &$getFrozenBrush $c2.MutedFg }
                } elseif ($cap -eq 3) {
                    $c3 = $palBanner.Banner.Cap3
                    $netEtwAlertBanner.Background  = &$getFrozenBrush $c3.Bg
                    $netEtwAlertBanner.BorderBrush = &$getFrozenBrush $c3.Border
                    if ($bdNetEtwBannerBadge)  { $bdNetEtwBannerBadge.Background = &$getFrozenBrush $c3.BadgeBg }
                    if ($txtNetEtwBannerBadge) { $txtNetEtwBannerBadge.Text = "TIER 1 FALLBACK" }
                    if ($txtNetEtwBannerMsg)   {
                        $txtNetEtwBannerMsg.Text = "Kernel Network ETW requires Administrators or Performance Log Users on target host. System-wide NET rate remains active."
                        $txtNetEtwBannerMsg.Foreground = &$getFrozenBrush $c3.Fg
                    }
                    if ($btnNetEtwResume)  { $btnNetEtwResume.Visibility  = [System.Windows.Visibility]::Collapsed }
                    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.Foreground = &$getFrozenBrush $c3.Fg }
                    if ($btnNetEtwDismiss) { $btnNetEtwDismiss.Foreground = &$getFrozenBrush $c3.MutedFg }
                } else {
                    $ce = $palBanner.Banner.CapErr
                    $netEtwAlertBanner.Background  = &$getFrozenBrush $ce.Bg
                    $netEtwAlertBanner.BorderBrush = &$getFrozenBrush $ce.Border
                    if ($bdNetEtwBannerBadge)  { $bdNetEtwBannerBadge.Background = &$getFrozenBrush $ce.BadgeBg }
                    if ($txtNetEtwBannerBadge) { $txtNetEtwBannerBadge.Text = "ETW UNAVAILABLE" }
                    if ($txtNetEtwBannerMsg)   {
                        $txtNetEtwBannerMsg.Text = "Unable to start Microsoft-Windows-Kernel-Network ETW session on target host."
                        $txtNetEtwBannerMsg.Foreground = &$getFrozenBrush $ce.Fg
                    }
                    if ($btnNetEtwResume)  { $btnNetEtwResume.Visibility  = [System.Windows.Visibility]::Collapsed }
                    if ($btnNetEtwTurnOff) { $btnNetEtwTurnOff.Foreground = &$getFrozenBrush $ce.Fg }
                    if ($btnNetEtwDismiss) { $btnNetEtwDismiss.Foreground = &$getFrozenBrush $ce.MutedFg }
                }
            } else {
                $netEtwAlertBanner.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
        if ($script:OnNetEtwStateUpdated) {
            &$script:OnNetEtwStateUpdated
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

    # 15D. Process Baseline Snapshot & Live Delta Markers (Ctrl+B / View Menu)
    $menuViewBaseline      = $window.FindName("MenuViewBaseline")
    $menuViewClearBaseline = $window.FindName("MenuViewClearBaseline")
    $badgeBaselineActive   = $window.FindName("BadgeBaselineActive")
    $txtBaselineLabel      = $window.FindName("TxtBaselineLabel")
    $btnClearBaseline      = $window.FindName("BtnClearBaseline")

    $syncBaselineUi = {
        $activeTab = $script:ActiveHostTab
        $hasBase = if ($activeTab) { [bool]$activeTab.HasBaseline } else { [bool]$stateContainer.HasBaseline }
        $baseTime = if ($activeTab -and $activeTab.BaselineTimeText) { [string]$activeTab.BaselineTimeText } else { "Now" }
        $stateContainer.HasBaseline = $hasBase
        $stateContainer.BaselineSnapshots = if ($activeTab) { $activeTab.BaselineSnapshots } else { $stateContainer.BaselineSnapshots }

        if ($hasBase) {
            if ($badgeBaselineActive) { $badgeBaselineActive.Visibility = [System.Windows.Visibility]::Visible }
            if ($txtBaselineLabel)    { $txtBaselineLabel.Text = "Baseline $baseTime" }
            if ($menuViewBaseline)    { $menuViewBaseline.Header = "Clear Process _Baseline Snapshot" }
            if ($menuViewClearBaseline) { $menuViewClearBaseline.IsEnabled = $true }
        } else {
            if ($badgeBaselineActive) { $badgeBaselineActive.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($menuViewBaseline)    { $menuViewBaseline.Header = "Set Process _Baseline Snapshot" }
            if ($menuViewClearBaseline) { $menuViewClearBaseline.IsEnabled = $false }
        }
    }

    $actionSetBaseline = {
        $snapMap = @{}
        $capturedAt = [DateTime]::Now.ToString("HH:mm:ss")
        if ($engineHandle -and $engineHandle.ProcessMap) {
            foreach ($vm in $engineHandle.ProcessMap.Values) {
                $snapMap[[int]$vm.PID] = @{
                    CreateTime   = [string]$vm.CreateTime
                    CPU          = [double]$vm.CPU
                    PrivateBytes = [long]$vm.PrivateBytes
                    MemoryBytes  = [long]$vm.MemoryBytes
                    Handles      = [int]$vm.Handles
                }
                $vm.SetBaselineState($true, $false, [long]$vm.PrivateBytes, [long]$vm.MemoryBytes, [int]$vm.Handles, [double]$vm.CPU)
            }
        }
        $stateContainer.HasBaseline       = $true
        $stateContainer.BaselineSnapshots = $snapMap
        if ($script:ActiveHostTab) {
            $script:ActiveHostTab.HasBaseline       = $true
            $script:ActiveHostTab.BaselineTimeText  = $capturedAt
            $script:ActiveHostTab.BaselineSnapshots = $snapMap
        }
        &$syncBaselineUi
        if ($engineHandle -and $engineHandle.RefreshTree) { & $engineHandle.RefreshTree }
        &$writeAuditLog "BASELINE" "Captured baseline snapshot at $capturedAt across $($snapMap.Count) processes."
    }

    $actionClearBaseline = {
        if ($engineHandle -and $engineHandle.ProcessMap) {
            foreach ($vm in $engineHandle.ProcessMap.Values) {
                $vm.ClearBaseline()
            }
        }
        $stateContainer.HasBaseline       = $false
        $stateContainer.BaselineSnapshots = $null
        if ($script:ActiveHostTab) {
            $script:ActiveHostTab.HasBaseline       = $false
            $script:ActiveHostTab.BaselineTimeText  = ""
            $script:ActiveHostTab.BaselineSnapshots = @{}
        }
        &$syncBaselineUi
        if ($engineHandle -and $engineHandle.RefreshTree) { & $engineHandle.RefreshTree }
        &$writeAuditLog "BASELINE" "Cleared process baseline snapshot."
    }

    $actionToggleBaseline = {
        if ([bool]$stateContainer.HasBaseline) {
            &$actionClearBaseline
        } else {
            &$actionSetBaseline
        }
    }

    if ($menuViewBaseline)      { $menuViewBaseline.add_Click({ &$actionToggleBaseline }) }
    if ($menuViewClearBaseline) { $menuViewClearBaseline.add_Click({ &$actionClearBaseline }) }
    if ($btnClearBaseline)      { $btnClearBaseline.add_Click({ &$actionClearBaseline }) }

    # 15E. Network Activity Controller (TCPView Active Sockets + ETW Activity Stream)
    $mainTabs                  = $window.FindName("MainTabControl")
    $btnNetModeSockets         = $window.FindName("BtnNetModeSockets")
    $btnNetModeTimeline        = $window.FindName("BtnNetModeTimeline")
    $btnNetRefreshSockets      = $window.FindName("BtnNetRefreshSockets")
    $chkNetAutoRefresh         = $window.FindName("ChkNetAutoRefresh")
    $btnNetCloseConn           = $window.FindName("BtnNetCloseConn")
    $panelNetSocketFilters     = $window.FindName("PanelNetSocketFilters")
    $panelNetTimelineFilters   = $window.FindName("PanelNetTimelineFilters")
    $chipNetTcp4               = $window.FindName("ChipNetTcp4")
    $chipNetTcp6               = $window.FindName("ChipNetTcp6")
    $chipNetUdp4               = $window.FindName("ChipNetUdp4")
    $chipNetUdp6               = $window.FindName("ChipNetUdp6")
    $chipNetEstablished        = $window.FindName("ChipNetEstablished")
    $chipNetListening          = $window.FindName("ChipNetListening")
    $chipNetSynSent            = $window.FindName("ChipNetSynSent")
    $chipNetTimeWait           = $window.FindName("ChipNetTimeWait")
    $chipNetRecv               = $window.FindName("ChipNetRecv")
    $chipNetSend               = $window.FindName("ChipNetSend")
    $btnNetClear               = $window.FindName("BtnNetClear")
    $btnNetExportCsv           = $window.FindName("BtnNetExportCsv")
    $txtNetActivitySummary     = $window.FindName("TxtNetActivitySummary")
    $txtNetStatusCounts        = $window.FindName("TxtNetStatusCounts")
    $txtSearchNetwork          = $window.FindName("TxtSearchNetwork")
    $btnClearSearchNetwork     = $window.FindName("BtnClearSearchNetwork")
    $netTabNoticeBanner        = $window.FindName("NetTabNoticeBanner")
    $txtNetBannerTitle         = $window.FindName("TxtNetBannerTitle")
    $txtNetBannerDetail        = $window.FindName("TxtNetBannerDetail")
    $btnNetBannerEnableEtw     = $window.FindName("BtnNetBannerEnableEtw")
    $btnNetBannerSwitchSockets = $window.FindName("BtnNetBannerSwitchSockets")
    $gridNetworkSockets        = $window.FindName("GridNetworkSockets")
    $gridNetworkTimeline       = $window.FindName("GridNetworkTimeline")
    $netEmptyStateOverlay      = $window.FindName("NetEmptyStateOverlay")
    $txtNetEmptyTitle          = $window.FindName("TxtNetEmptyTitle")
    $txtNetEmptyHint           = $window.FindName("TxtNetEmptyHint")

    $netSocketsCollection  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $netTimelineCollection = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    if ($gridNetworkSockets)  { $gridNetworkSockets.ItemsSource  = $netSocketsCollection }
    if ($gridNetworkTimeline) { $gridNetworkTimeline.ItemsSource = $netTimelineCollection }

    # Direct assignment avoids PowerShell enumerating an empty ListCollectionView (IEnumerable) into $null
    $netSocketsView  = [System.Windows.Data.CollectionViewSource]::GetDefaultView($netSocketsCollection)
    $netTimelineView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($netTimelineCollection)

    $netUiState = @{
        SubMode        = "Sockets"
        InFlight       = $false
        FilterTcp4     = $true
        FilterTcp6     = $true
        FilterUdp4     = $true
        FilterUdp6     = $true
        FilterEst      = $false
        FilterListen   = $false
        FilterSynSent  = $false
        FilterTimeWait = $false
        FilterRecv     = $false
        FilterSend     = $false
        SearchText     = ""
    }

    if ($netSocketsView) {
        $netSocketsView.Filter = & {
            param($localFilterState)
            return ([Predicate[Object]]{
                param($item)
                if (-not $item) { return $false }
                $proto = [string]$item.Protocol
                $st    = [string]$item.State
                $protoMatch = switch ($proto) {
                    "TCP"   { [bool]$localFilterState.FilterTcp4 }
                    "TCPv6" { [bool]$localFilterState.FilterTcp6 }
                    "UDP"   { [bool]$localFilterState.FilterUdp4 }
                    "UDPv6" { [bool]$localFilterState.FilterUdp6 }
                    default { $true }
                }
                if (-not $protoMatch) { return $false }
                if ($localFilterState.FilterEst -or $localFilterState.FilterListen -or $localFilterState.FilterSynSent -or $localFilterState.FilterTimeWait) {
                    $matchState = (
                        ($localFilterState.FilterEst      -and ($st -eq "Established")) -or
                        ($localFilterState.FilterListen   -and ($st -eq "Listen" -or $st -eq "Listening")) -or
                        ($localFilterState.FilterSynSent  -and ($st -eq "Syn Sent")) -or
                        ($localFilterState.FilterTimeWait -and ($st -eq "Time Wait" -or $st -eq "Close Wait"))
                    )
                    if (-not $matchState) { return $false }
                }
                $q = [string]$localFilterState.SearchText
                if ($q) {
                    return (
                        (([string]$item.ProcessName).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.PIDDisplay).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        ($proto.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.LocalAddress).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.LocalPortDisplay).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.LocalEndpoint).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.RemoteAddress).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.RemotePortDisplay).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.RemoteEndpoint).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        ($st.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.CreateTime).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.ModuleName).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
                    )
                }
                return $true
            }.GetNewClosure())
        } $netUiState
    }
    if ($netTimelineView) {
        $netTimelineView.Filter = & {
            param($localFilterState)
            return ([Predicate[Object]]{
                param($item)
                if (-not $item) { return $false }
                if ($localFilterState.FilterRecv -or $localFilterState.FilterSend) {
                    $matchDir = (($localFilterState.FilterRecv -and [bool]$item.IsRecv) -or ($localFilterState.FilterSend -and [bool]$item.IsSend))
                    if (-not $matchDir) { return $false }
                }
                $q = [string]$localFilterState.SearchText
                if ($q) {
                    return (
                        (([string]$item.ProcessName).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.PID).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.Operation).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.Detail).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.Category).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                        (([string]$item.User).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
                    )
                }
                return $true
            }.GetNewClosure())
        } $netUiState
    }

    $resolveNetBrushes = {
        $b = if ($stateContainer.ThemePalette -and $stateContainer.ThemePalette.Brushes) { $stateContainer.ThemePalette.Brushes } else { ([PSRPMThemeRegistry]::GetPalette("Light")).Brushes }
        return @{
            TcpBg      = if ($b['BrushBadgeTcpBg'])      { [string]$b['BrushBadgeTcpBg'] }      else { "#E0F2FE" }
            TcpFg      = if ($b['BrushBadgeTcpFg'])      { [string]$b['BrushBadgeTcpFg'] }      else { "#075985" }
            UdpBg      = if ($b['BrushBadgeUdpBg'])      { [string]$b['BrushBadgeUdpBg'] }      else { "#FEF3C7" }
            UdpFg      = if ($b['BrushBadgeUdpFg'])      { [string]$b['BrushBadgeUdpFg'] }      else { "#92400E" }
            EstBg      = if ($b['BrushStateEstBg'])      { [string]$b['BrushStateEstBg'] }      else { "#DCFCE7" }
            EstFg      = if ($b['BrushStateEstFg'])      { [string]$b['BrushStateEstFg'] }      else { "#166534" }
            ListenBg   = if ($b['BrushStateListenBg'])   { [string]$b['BrushStateListenBg'] }   else { "#E2E8F0" }
            ListenFg   = if ($b['BrushStateListenFg'])   { [string]$b['BrushStateListenFg'] }   else { "#334155" }
            TimeWaitBg = if ($b['BrushStateTimeWaitBg']) { [string]$b['BrushStateTimeWaitBg'] } else { "#FFEDD5" }
            TimeWaitFg = if ($b['BrushStateTimeWaitFg']) { [string]$b['BrushStateTimeWaitFg'] } else { "#9A3412" }
            OtherBg    = if ($b['BrushToolbarBg'])       { [string]$b['BrushToolbarBg'] }       else { "#F1F5F9" }
            OtherFg    = if ($b['BrushTextSecondary'])   { [string]$b['BrushTextSecondary'] }   else { "#334155" }
        }
    }

    $applyItemThemeColors = {
        param($item, [hashtable]$palMap)
        if (-not $item) { return }
        if ($item.PSObject.Properties['Protocol']) {
            $isUdp = ([string]$item.Protocol -like "UDP*")
            $item.ProtocolBg = if ($isUdp) { $palMap.UdpBg } else { $palMap.TcpBg }
            $item.ProtocolFg = if ($isUdp) { $palMap.UdpFg } else { $palMap.TcpFg }
            $st = [string]$item.State
            if ($st -eq "Established") {
                $item.StateBg = $palMap.EstBg; $item.StateFg = $palMap.EstFg
            } elseif ($st -eq "Listen" -or $st -eq "Listening") {
                $item.StateBg = $palMap.ListenBg; $item.StateFg = $palMap.ListenFg
            } elseif ($st -eq "Time Wait" -or $st -eq "Close Wait") {
                $item.StateBg = $palMap.TimeWaitBg; $item.StateFg = $palMap.TimeWaitFg
            } else {
                $item.StateBg = $palMap.OtherBg; $item.StateFg = $palMap.OtherFg
            }
        } elseif ($item.PSObject.Properties['Operation']) {
            if ([bool]$item.IsRecv -and [bool]$item.IsSend) {
                $item.OperationBg = $palMap.UdpBg; $item.OperationFg = $palMap.UdpFg
            } elseif ([bool]$item.IsRecv) {
                $item.OperationBg = $palMap.EstBg; $item.OperationFg = $palMap.EstFg
            } else {
                $item.OperationBg = $palMap.TcpBg; $item.OperationFg = $palMap.TcpFg
            }
        }
    }

    $script:RefreshNetworkThemeBrushes = {
        $palMap = &$resolveNetBrushes
        foreach ($sItem in $netSocketsCollection)  { &$applyItemThemeColors $sItem $palMap }
        foreach ($tItem in $netTimelineCollection) { &$applyItemThemeColors $tItem $palMap }
        if ($hostTabsCollection) {
            foreach ($hTab in $hostTabsCollection) {
                if ($hTab.NetworkSockets)  { foreach ($cs in $hTab.NetworkSockets)  { &$applyItemThemeColors $cs $palMap } }
                if ($hTab.NetworkTimeline) { foreach ($ct in $hTab.NetworkTimeline) { &$applyItemThemeColors $ct $palMap } }
            }
        }
        if ($gridNetworkSockets -and $gridNetworkSockets.Items)   { try { $gridNetworkSockets.Items.Refresh() } catch {} }
        if ($gridNetworkTimeline -and $gridNetworkTimeline.Items) { try { $gridNetworkTimeline.Items.Refresh() } catch {} }
    }

    $canCloseTcpSocket = {
        param($item)
        return ($null -ne $item -and [int]$item.PID -gt 4 -and $item.LifecycleState -ne "Del" -and $item.Protocol -eq "TCP" -and $item.State -ne "Listen" -and $item.State -ne "Time Wait")
    }

    $updateNetCloseBtnState = {
        $selItem = if ($gridNetworkSockets -and $netUiState.SubMode -eq "Sockets") { $gridNetworkSockets.SelectedItem } else { $null }
        $canClose = &$canCloseTcpSocket $selItem
        if ($btnNetCloseConn) { $btnNetCloseConn.IsEnabled = $canClose }
        $ctxClose = if ($gridNetworkSockets -and $gridNetworkSockets.ContextMenu) { $window.FindName("CtxNetSockCloseConn") } else { $null }
        if ($ctxClose) { $ctxClose.IsEnabled = $canClose }
    }

    $updateNetEmptyAndSummary = {
        $isSockets = ($netUiState.SubMode -eq "Sockets")
        $cap = [int]$stateContainer.NetEtwCap

        if ($netTabNoticeBanner) {
            if (-not $isSockets -and $cap -ne 1) {
                $netTabNoticeBanner.Visibility = [System.Windows.Visibility]::Visible
                if ($btnNetBannerSwitchSockets) { $btnNetBannerSwitchSockets.Visibility = [System.Windows.Visibility]::Visible }
                if ($cap -eq 3) {
                    if ($txtNetBannerTitle)  { $txtNetBannerTitle.Text = "TIER 1 MODE" }
                    if ($txtNetBannerDetail) { $txtNetBannerDetail.Text = "Per-process ETW telemetry requires Administrator rights on target host. Active Sockets still enumerate all TCP/UDP endpoints." }
                    if ($btnNetBannerEnableEtw) { $btnNetBannerEnableEtw.Visibility = [System.Windows.Visibility]::Collapsed }
                } elseif ($cap -eq 2) {
                    if ($txtNetBannerTitle)  { $txtNetBannerTitle.Text = "THROTTLED" }
                    if ($txtNetBannerDetail) { $txtNetBannerDetail.Text = "Network ETW paused by the high-volume safety circuit breaker. Click Resume Net ETW to continue capturing bursts." }
                    if ($btnNetBannerEnableEtw) {
                        $btnNetBannerEnableEtw.Content = "Resume Net ETW"
                        $btnNetBannerEnableEtw.Visibility = [System.Windows.Visibility]::Visible
                    }
                } else {
                    if ($txtNetBannerTitle)  { $txtNetBannerTitle.Text = "NET ETW OFF" }
                    if ($txtNetBannerDetail) { $txtNetBannerDetail.Text = "ETW Activity Stream builds its timeline from per-process Network ETW telemetry. Turn on Net ETW or switch to Active Sockets." }
                    if ($btnNetBannerEnableEtw) {
                        $btnNetBannerEnableEtw.Content = "Enable Net ETW"
                        $btnNetBannerEnableEtw.Visibility = [System.Windows.Visibility]::Visible
                    }
                }
            } else {
                $netTabNoticeBanner.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }

        if ($isSockets) {
            $totCount = $netSocketsCollection.Count
            $visCount = if ($netSocketsView) { try { [int]$netSocketsView.Count } catch { $totCount } } else { $totCount }
            if ($txtNetStatusCounts) {
                $txtNetStatusCounts.Text = if ($script:ActiveHostTab -and $script:ActiveHostTab.NetworkStatusCountsText) {
                    [string]$script:ActiveHostTab.NetworkStatusCountsText
                } else {
                    "Endpoints: 0  |  Established: 0  |  Listening: 0  |  Time Wait: 0  |  Close Wait: 0"
                }
            }
            if ($txtNetActivitySummary) {
                $baseTxt = if ($script:ActiveHostTab -and $script:ActiveHostTab.NetworkSocketsSummary) { [string]$script:ActiveHostTab.NetworkSocketsSummary } else { "Not queried yet" }
                $txtNetActivitySummary.Text = if ($visCount -lt $totCount) { "$visCount of $totCount shown - $baseTxt" } else { $baseTxt }
            }
            &$updateNetCloseBtnState
            if ($netEmptyStateOverlay) {
                if ($visCount -eq 0) {
                    $netEmptyStateOverlay.Visibility = [System.Windows.Visibility]::Visible
                    if ($netUiState.InFlight) {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "Querying active sockets..." }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Enumerating IPv4/IPv6 TCP and UDP tables on target host." }
                    } elseif ($totCount -eq 0) {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "No active sockets loaded" }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Click Refresh to snapshot live TCP/UDP endpoints." }
                    } else {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "No sockets match active filters" }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Clear the search filter or toggle protocol/state chips to view all $totCount sockets." }
                    }
                } else {
                    $netEmptyStateOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                }
            }
        } else {
            $totEv = $netTimelineCollection.Count
            $visEv = if ($netTimelineView) { try { [int]$netTimelineView.Count } catch { $totEv } } else { $totEv }
            if ($txtNetStatusCounts) {
                $txtNetStatusCounts.Text = "ETW Stream: $totEv captured (max 2,000)"
            }
            if ($txtNetActivitySummary) {
                $txtNetActivitySummary.Text = if ($visEv -lt $totEv) { "$visEv of $totEv ETW events (max 2,000)" } else { "$totEv ETW events (max 2,000)" }
            }
            &$updateNetCloseBtnState
            if ($netEmptyStateOverlay) {
                if ($visEv -eq 0) {
                    $netEmptyStateOverlay.Visibility = [System.Windows.Visibility]::Visible
                    if ($cap -eq 3) {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "ETW telemetry requires Administrator privileges" }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Switch to Active Sockets to inspect all open TCP/UDP endpoints." }
                    } elseif ($cap -ne 1) {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "ETW Activity Stream is idle" }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Click Enable Net ETW above or press Ctrl+Shift+N to record per-process network bursts." }
                    } elseif ($totEv -eq 0) {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "Waiting for per-process network activity..." }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Send and receive bursts from processes with active traffic will stream here automatically." }
                    } else {
                        if ($txtNetEmptyTitle) { $txtNetEmptyTitle.Text = "No events match active filters" }
                        if ($txtNetEmptyHint)  { $txtNetEmptyHint.Text  = "Clear the search filter or adjust Recv/Send chips." }
                    }
                } else {
                    $netEmptyStateOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                }
            }
        }
    }
    $script:OnNetEtwStateUpdated = $updateNetEmptyAndSummary

    $getSocketRowKey = {
        param($rowItem)
        if (-not $rowItem) { return "" }
        if ($rowItem.PSObject.Properties['SocketKey'] -and $rowItem.SocketKey) {
            return [string]$rowItem.SocketKey
        }
        return "$($rowItem.PID)|$($rowItem.Protocol)|$($rowItem.LocalEndpoint)|$($rowItem.RemoteEndpoint)"
    }

    $applySocketSnapshotList = {
        param([System.Collections.Generic.List[Object]]$desired)
        if (-not $desired) { $desired = [System.Collections.Generic.List[Object]]::new() }
        $selKey = ""
        if ($gridNetworkSockets -and $gridNetworkSockets.SelectedItem) {
            $selKey = &$getSocketRowKey $gridNetworkSockets.SelectedItem
        }

        $desiredKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $uniqueDesired = [System.Collections.Generic.List[Object]]::new($desired.Count)
        foreach ($dItem in $desired) {
            $dk = &$getSocketRowKey $dItem
            if ($desiredKeys.Add($dk)) {
                $uniqueDesired.Add($dItem)
            }
        }

        $collectionMutated = $false
        $existingByKey = @{}
        for ($ri = $netSocketsCollection.Count - 1; $ri -ge 0; $ri--) {
            $oldItem = $netSocketsCollection[$ri]
            $ok = &$getSocketRowKey $oldItem
            if (-not $desiredKeys.Contains($ok) -or $existingByKey.ContainsKey($ok)) {
                $netSocketsCollection.RemoveAt($ri)
                $collectionMutated = $true
            } else {
                $existingByKey[$ok] = $oldItem
            }
        }

        $syncProps = @(
            'SocketKey', 'LifecycleState', 'PID', 'PIDDisplay', 'ProcessName', 'IconSource',
            'Protocol', 'ProtocolBg', 'ProtocolFg', 'State', 'StateBg', 'StateFg',
            'LocalAddress', 'LocalPort', 'LocalPortDisplay', 'RemoteAddress', 'RemotePort', 'RemotePortDisplay',
            'LocalEndpoint', 'RemoteEndpoint', 'CreateTimestamp', 'CreateTime', 'ModuleName',
            'SentPackets', 'RecvPackets', 'SentBytes', 'RecvBytes',
            'SentPacketsFormatted', 'RecvPacketsFormatted', 'SentBytesFormatted', 'RecvBytesFormatted'
        )
        $nNew = $uniqueDesired.Count
        for ($di = 0; $di -lt $nNew; $di++) {
            $want = $uniqueDesired[$di]
            $wk = &$getSocketRowKey $want
            if ($existingByKey.ContainsKey($wk)) {
                $curObj = $existingByKey[$wk]
                foreach ($pName in $syncProps) {
                    $newVal = $want.$pName
                    if ($curObj.$pName -ne $newVal) {
                        $curObj.$pName = $newVal
                        $collectionMutated = $true
                    }
                }
                if ($di -lt $netSocketsCollection.Count) {
                    if ((&$getSocketRowKey $netSocketsCollection[$di]) -ne $wk) {
                        $oldIdx = $netSocketsCollection.IndexOf($curObj)
                        if ($oldIdx -ge 0 -and $oldIdx -ne $di) {
                            $netSocketsCollection.Move($oldIdx, $di)
                            $collectionMutated = $true
                        }
                    }
                }
            } else {
                $netSocketsCollection.Insert($di, $want)
                $existingByKey[$wk] = $want
                $collectionMutated = $true
            }
        }
        for ($ri = $netSocketsCollection.Count - 1; $ri -ge $nNew; $ri--) {
            $netSocketsCollection.RemoveAt($ri)
            $collectionMutated = $true
        }

        if ($collectionMutated -and $netSocketsView) {
            try { $netSocketsView.Refresh() } catch {}
        }
        if ($selKey -and $gridNetworkSockets) {
            $curSelKey = if ($gridNetworkSockets.SelectedItem) { &$getSocketRowKey $gridNetworkSockets.SelectedItem } else { "" }
            if ($curSelKey -ne $selKey) {
                foreach ($cand in $netSocketsCollection) {
                    if ((&$getSocketRowKey $cand) -eq $selKey) {
                        $gridNetworkSockets.SelectedItem = $cand
                        break
                    }
                }
            }
        }
    }

    $refreshNetFiltersView = {
        $netUiState.SearchText = if ($txtSearchNetwork) { $txtSearchNetwork.Text.Trim() } else { "" }
        if ($netUiState.SubMode -eq "Sockets") {
            if ($netSocketsView) { try { $netSocketsView.Refresh() } catch {} }
        } else {
            if ($netTimelineView) { try { $netTimelineView.Refresh() } catch {} }
        }
        &$updateNetEmptyAndSummary
    }

    $refreshSocketsNow = {
        if ($netUiState.InFlight) { return }
        if (-not $engineHandle -or -not $engineHandle.SendCommand) { return }
        $netUiState.InFlight = $true
        $reqTab = $script:ActiveHostTab
        $reqTabId = if ($reqTab) { [string]$reqTab.TabId } else { "" }
        &$updateNetEmptyAndSummary

        $localUi = $netUiState
        $localApply = $applySocketSnapshotList
        $localResolve = $resolveNetBrushes
        $localPaint = $applyItemThemeColors
        $localUpd = $updateNetEmptyAndSummary
        $localLog = $writeAuditLog
        $localEngine = $engineHandle
        $localTabsCol = $hostTabsCollection
        $localGetActiveTab = { return $script:ActiveHostTab }
        $jssNet = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $jssNet.MaxJsonLength = 67108864

        & $engineHandle.SendCommand @{
            CommandType     = "InspectPid"
            TargetPid       = 0
            VerifySignature = $false
            InspectMode     = "AllSockets"
        } ({
            param($res)
            $localUi.InFlight = $false
            try {
                if (-not $res -or -not $res.Success -or -not $res.PayloadJson) {
                    if ($reqTab) { $reqTab.NetworkSocketsSummary = "Socket query failed: $(if ($res) { $res.Error } else { 'No response' })" }
                    return
                }
                $parsed = $jssNet.DeserializeObject([string]$res.PayloadJson)
                if (-not $parsed -or -not [bool]$parsed["Success"]) {
                    if ($reqTab) { $reqTab.NetworkSocketsSummary = "Socket query error: $(if ($parsed) { $parsed['Error'] } else { 'Unknown' })" }
                    return
                }

                # Determine target ProcessMap (active tab vs background tab if user switched host tabs mid-flight)
                $curActiveTab = if ($localGetActiveTab) { & $localGetActiveTab } else { $null }
                $activeNow = ($curActiveTab -and $curActiveTab.TabId -eq $reqTabId) -or (-not $curActiveTab -and -not $reqTabId)
                $pMap = if ($activeNow) {
                    $localEngine.ProcessMap
                } elseif ($reqTab -and $reqTab.ProcessMap) {
                    $reqTab.ProcessMap
                } else {
                    $localEngine.ProcessMap
                }

                $palMap = & $localResolve
                $built = [System.Collections.Generic.List[Object]]::new()
                $tcp4Cnt = 0; $tcp6Cnt = 0; $udp4Cnt = 0; $udp6Cnt = 0
                $liveCount = 0; $cntEst = 0; $cntListen = 0; $cntTw = 0; $cntCw = 0

                $prevSnap = if ($reqTab -and $reqTab.NetworkPrevSnapshot) { $reqTab.NetworkPrevSnapshot } else { $null }
                $hasBaseline = ($null -ne $prevSnap -and $prevSnap.Count -gt 0)
                $nextSnap = @{}
                $liveKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

                $rawSockets = $parsed["Sockets"]
                if ($rawSockets) {
                    foreach ($row in $rawSockets) {
                        $rPid  = [int]$row["PID"]
                        $proto = [string]$row["Protocol"]
                        $stStr = [string]$row["State"]
                        switch ($proto) {
                            "TCP"   { $tcp4Cnt++ }
                            "TCPv6" { $tcp6Cnt++ }
                            "UDP"   { $udp4Cnt++ }
                            "UDPv6" { $udp6Cnt++ }
                        }
                        $liveCount++
                        if ($stStr -eq "Established") {
                            $cntEst++
                        } elseif ($stStr -eq "Listen" -or $stStr -eq "Listening") {
                            $cntListen++
                        } elseif ($stStr -eq "Time Wait") {
                            $cntTw++
                        } elseif ($stStr -eq "Close Wait") {
                            $cntCw++
                        }

                        $locAddr = if ($null -ne $row["LocalAddress"])  { [string]$row["LocalAddress"] }  else { "" }
                        $locPort = if ($null -ne $row["LocalPort"])     { [int]$row["LocalPort"] }       else { 0 }
                        $remAddr = if ($null -ne $row["RemoteAddress"]) { [string]$row["RemoteAddress"] } else { "" }
                        $remPort = if ($null -ne $row["RemotePort"])    { [int]$row["RemotePort"] }      else { 0 }
                        $locEp   = if ($null -ne $row["LocalEndpoint"]) { [string]$row["LocalEndpoint"] } else { "" }
                        $remEp   = if ($null -ne $row["RemoteEndpoint"]){ [string]$row["RemoteEndpoint"] }else { "" }
                        $cTs     = if ($null -ne $row["CreateTimestamp"]){ [long]$row["CreateTimestamp"] } else { 0L }
                        $cTime   = if ($null -ne $row["CreateTime"])    { [string]$row["CreateTime"] }    else { "" }
                        $rawMod  = if ($null -ne $row["ModuleName"])    { [string]$row["ModuleName"] }    else { "" }
                        $sentPkt = if ($null -ne $row["SentPackets"])   { [long]$row["SentPackets"] }   else { 0L }
                        $recvPkt = if ($null -ne $row["RecvPackets"])   { [long]$row["RecvPackets"] }   else { 0L }
                        $sentByt = if ($null -ne $row["SentBytes"])     { [long]$row["SentBytes"] }     else { 0L }
                        $recvByt = if ($null -ne $row["RecvBytes"])     { [long]$row["RecvBytes"] }     else { 0L }

                        $vm = if ($rPid -gt 0 -and $pMap -and $pMap.ContainsKey($rPid)) { $pMap[$rPid] } else { $null }
                        if ($rPid -eq 0 -and $stStr -eq "Time Wait") {
                            $pName      = "[Time Wait]"
                            $pidDisp    = ""
                            $iconSrc    = $null
                            $modName    = $rawMod
                        } else {
                            $pidDisp    = [string]$rPid
                            $iconSrc    = if ($vm) { $vm.IconSource } else { $null }
                            $pName      = if ($vm) { [string]$vm.Name } elseif ($rPid -eq 0) { "System Idle Process" } elseif ($rPid -eq 4) { "System" } elseif ($rawMod -match '\.exe$') { $rawMod } else { "PID $rPid" }
                            $modName    = if (-not [string]::IsNullOrWhiteSpace($rawMod)) {
                                $rawMod
                            } elseif ($vm -and $vm.HostedServices) {
                                [string]$vm.HostedServices
                            } elseif ($vm) {
                                [string]$vm.Name
                            } elseif ($rPid -eq 4) {
                                "System"
                            } else {
                                ""
                            }
                        }

                        $locPortDisp = if ($locPort -gt 0 -or ($locAddr -and $locAddr -ne "*")) { [string]$locPort } else { "" }
                        $remPortDisp = if ($remAddr -eq "*" -or [string]::IsNullOrWhiteSpace($remAddr)) { "" } else { [string]$remPort }

                        $baseKey = "$proto|$locAddr|$locPort|$remAddr|$remPort|$rPid"
                        $rowKey  = $baseKey
                        $dupSeq  = 1
                        while (-not $liveKeys.Add($rowKey)) {
                            $rowKey = "$baseKey#$dupSeq"
                            $dupSeq++
                        }

                        $lcState = ""
                        if ($hasBaseline) {
                            if (-not $prevSnap.ContainsKey($rowKey)) {
                                $lcState = "New"
                            } else {
                                $pEnt = $prevSnap[$rowKey]
                                if ($pEnt.State -ne $stStr -or $pEnt.SentBytes -ne $sentByt -or $pEnt.RecvBytes -ne $recvByt -or $pEnt.SentPackets -ne $sentPkt -or $pEnt.RecvPackets -ne $recvPkt) {
                                    $lcState = "Mod"
                                }
                            }
                        }
                        $nextSnap[$rowKey] = @{
                            State       = $stStr
                            SentPackets = $sentPkt
                            RecvPackets = $recvPkt
                            SentBytes   = $sentByt
                            RecvBytes   = $recvByt
                        }

                        $obj = [PSCustomObject]@{
                            SocketKey            = $rowKey
                            LifecycleState       = $lcState
                            PID                  = $rPid
                            PIDDisplay           = $pidDisp
                            ProcessName          = $pName
                            IconSource           = $iconSrc
                            Protocol             = $proto
                            ProtocolBg           = ""
                            ProtocolFg           = ""
                            State                = $stStr
                            StateBg              = ""
                            StateFg              = ""
                            LocalAddress         = $locAddr
                            LocalPort            = $locPort
                            LocalPortDisplay     = $locPortDisp
                            RemoteAddress        = $remAddr
                            RemotePort           = $remPort
                            RemotePortDisplay    = $remPortDisp
                            LocalEndpoint        = $locEp
                            RemoteEndpoint       = $remEp
                            CreateTimestamp      = $cTs
                            CreateTime           = $cTime
                            ModuleName           = $modName
                            SentPackets          = $sentPkt
                            RecvPackets          = $recvPkt
                            SentBytes            = $sentByt
                            RecvBytes            = $recvByt
                            SentPacketsFormatted = if ($sentPkt -gt 0L) { $sentPkt.ToString("N0") } else { "" }
                            RecvPacketsFormatted = if ($recvPkt -gt 0L) { $recvPkt.ToString("N0") } else { "" }
                            SentBytesFormatted   = if ($sentByt -gt 0L) { $sentByt.ToString("N0") } else { "" }
                            RecvBytesFormatted   = if ($recvByt -gt 0L) { $recvByt.ToString("N0") } else { "" }
                        }
                        & $localPaint $obj $palMap
                        $built.Add($obj)
                    }
                }

                # Retain vanished sockets for 1 refresh tick highlighted in Red ("Del"), matching Sysinternals TCPView
                if ($hasBaseline -and $reqTab -and $reqTab.NetworkSockets) {
                    foreach ($prevItem in $reqTab.NetworkSockets) {
                        if ($prevItem.SocketKey -and $prevItem.LifecycleState -ne "Del" -and -not $liveKeys.Contains($prevItem.SocketKey)) {
                            $delObj = [PSCustomObject]@{
                                SocketKey            = $prevItem.SocketKey
                                LifecycleState       = "Del"
                                PID                  = $prevItem.PID
                                PIDDisplay           = $prevItem.PIDDisplay
                                ProcessName          = $prevItem.ProcessName
                                IconSource           = $prevItem.IconSource
                                Protocol             = $prevItem.Protocol
                                ProtocolBg           = $prevItem.ProtocolBg
                                ProtocolFg           = $prevItem.ProtocolFg
                                State                = $prevItem.State
                                StateBg              = $prevItem.StateBg
                                StateFg              = $prevItem.StateFg
                                LocalAddress         = $prevItem.LocalAddress
                                LocalPort            = $prevItem.LocalPort
                                LocalPortDisplay     = $prevItem.LocalPortDisplay
                                RemoteAddress        = $prevItem.RemoteAddress
                                RemotePort           = $prevItem.RemotePort
                                RemotePortDisplay    = $prevItem.RemotePortDisplay
                                LocalEndpoint        = $prevItem.LocalEndpoint
                                RemoteEndpoint       = $prevItem.RemoteEndpoint
                                CreateTimestamp      = $prevItem.CreateTimestamp
                                CreateTime           = $prevItem.CreateTime
                                ModuleName           = $prevItem.ModuleName
                                SentPackets          = $prevItem.SentPackets
                                RecvPackets          = $prevItem.RecvPackets
                                SentBytes            = $prevItem.SentBytes
                                RecvBytes            = $prevItem.RecvBytes
                                SentPacketsFormatted = $prevItem.SentPacketsFormatted
                                RecvPacketsFormatted = $prevItem.RecvPacketsFormatted
                                SentBytesFormatted   = $prevItem.SentBytesFormatted
                                RecvBytesFormatted   = $prevItem.RecvBytesFormatted
                            }
                            & $localPaint $delObj $palMap
                            $built.Add($delObj)
                        }
                    }
                }

                $rateLabel   = if ($reqTab -and $reqTab.AutoRefreshSockets) { "Update: 2 sec" } else { "Update: Paused" }
                $countsText  = "Endpoints: $liveCount  |  Established: $cntEst  |  Listening: $cntListen  |  Time Wait: $cntTw  |  Close Wait: $cntCw"
                $snapSummary = "$liveCount endpoints ($tcp4Cnt TCP4, $tcp6Cnt TCP6, $udp4Cnt UDP4, $udp6Cnt UDP6) - $rateLabel - Snapshot $([DateTime]::Now.ToString('HH:mm:ss'))"
                if ($reqTab) {
                    $reqTab.NetworkPrevSnapshot     = $nextSnap
                    $reqTab.NetworkStatusCountsText = $countsText
                    $reqTab.NetworkSockets          = $built
                    $reqTab.HasLoadedSockets        = $true
                    $reqTab.NetworkSocketsSummary   = $snapSummary
                }
                if ($activeNow) {
                    & $localApply $built
                }
            } catch {
                if ($reqTab) { $reqTab.NetworkSocketsSummary = "Socket parse error: $($_.Exception.Message)" }
                if ($localLog) { & $localLog "ERROR" "AllSockets callback failed: $($_.Exception.Message)" }
            } finally {
                & $localUpd
            }
        }.GetNewClosure())
    }

    $netAutoTimer = [System.Windows.Threading.DispatcherTimer]::new(
        [System.Windows.Threading.DispatcherPriority]::Background,
        $window.Dispatcher
    )
    $netAutoTimer.Interval = [TimeSpan]::FromMilliseconds(2000)
    $netAutoTimer.add_Tick({
        $onNetTab = ($mainTabs -and $mainTabs.SelectedIndex -eq 2)
        if ($onNetTab -and $netUiState.SubMode -eq "Sockets" -and $script:ActiveHostTab -and $script:ActiveHostTab.AutoRefreshSockets -and -not [bool]$stateContainer.IsPaused) {
            if ($stateContainer.ConnectionState -notin @("Disconnected", "Reconnecting")) {
                &$refreshSocketsNow
            }
        } else {
            $netAutoTimer.Stop()
        }
    })

    $syncNetworkAutoTimer = {
        $onNetTab = ($mainTabs -and $mainTabs.SelectedIndex -eq 2)
        $wantAuto = ($script:ActiveHostTab -and [bool]$script:ActiveHostTab.AutoRefreshSockets)
        if ($onNetTab -and $netUiState.SubMode -eq "Sockets" -and $wantAuto -and -not [bool]$stateContainer.IsPaused) {
            if (-not $netAutoTimer.IsEnabled) { $netAutoTimer.Start() }
        } else {
            if ($netAutoTimer.IsEnabled) { $netAutoTimer.Stop() }
        }
    }
    $script:SyncNetworkAutoTimer = $syncNetworkAutoTimer

    $materializeNetBurstRow = {
        param([hashtable]$rec, [hashtable]$palMap)
        $isRx = [bool]$rec.IsRecv
        $isTx = [bool]$rec.IsSend
        $opName = if ($isRx -and $isTx) { "Recv + Send" } elseif ($isRx) { "Recv" } else { "Send" }
        $sessTot = [long]$rec.SessionBytes
        $evObj = [PSCustomObject]@{
            TimestampTicks        = [long]$rec.TimestampTicks
            TimeText              = [string]$rec.TimeText
            PID                   = [int]$rec.PID
            ProcessName           = [string]$rec.ProcessName
            IconSource            = $rec.IconSource
            Operation             = $opName
            OperationBg           = ""
            OperationFg           = ""
            IsRecv                = $isRx
            IsSend                = $isTx
            Detail                = ("Rx: {0} | Tx: {1}" -f [string]$rec.RxFmt, [string]$rec.TxFmt)
            RateBps               = [double]$rec.RateBps
            RateFormatted         = [string]$rec.RateFmt
            TreeRateBps           = [double]$rec.TreeRateBps
            TreeRateFormatted     = [string]$rec.TreeRateFmt
            SessionBytes          = $sessTot
            SessionTotalFormatted = if ($sessTot -gt 0L) { [SystemSummaryViewModel]::FormatBytesStatic([double]$sessTot) } else { "0 B" }
            Category              = [string]$rec.Category
            User                  = [string]$rec.User
        }
        &$applyItemThemeColors $evObj $palMap
        return $evObj
    }

    $flushPendingNetTimeline = {
        param($tabObj)
        if (-not $tabObj -or -not $tabObj.PendingNetTimeline -or $tabObj.PendingNetTimeline.Count -eq 0) { return }
        $palMap = &$resolveNetBrushes
        while ($tabObj.PendingNetTimeline.Count -gt 0) {
            $rec = $tabObj.PendingNetTimeline.Dequeue()
            $evObj = &$materializeNetBurstRow $rec $palMap
            $netTimelineCollection.Add($evObj)
        }
        while ($netTimelineCollection.Count -gt 2000) {
            $netTimelineCollection.RemoveAt(0)
        }
    }

    $setNetworkSubMode = {
        param([string]$mode)
        if ($mode -ne "Timeline") { $mode = "Sockets" }
        $netUiState.SubMode = $mode
        if ($script:ActiveHostTab) { $script:ActiveHostTab.NetworkSubMode = $mode }

        $isSock = ($mode -eq "Sockets")
        if ($btnNetModeSockets)        { $btnNetModeSockets.IsChecked  = $isSock }
        if ($btnNetModeTimeline)       { $btnNetModeTimeline.IsChecked = (-not $isSock) }
        if ($btnNetRefreshSockets)     { $btnNetRefreshSockets.Visibility = if ($isSock) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        if ($chkNetAutoRefresh)        { $chkNetAutoRefresh.Visibility    = if ($isSock) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        if ($btnNetCloseConn)          { $btnNetCloseConn.Visibility      = if ($isSock) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        if ($panelNetSocketFilters)    { $panelNetSocketFilters.Visibility   = if ($isSock) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        if ($panelNetTimelineFilters)  { $panelNetTimelineFilters.Visibility = if ($isSock) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible } }
        if ($btnNetClear)              { $btnNetClear.Visibility = if ($isSock) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible } }
        if ($gridNetworkSockets)       { $gridNetworkSockets.Visibility  = if ($isSock) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        if ($gridNetworkTimeline)      { $gridNetworkTimeline.Visibility = if ($isSock) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible } }

        &$syncNetworkAutoTimer
        if ($isSock -and $mainTabs -and $mainTabs.SelectedIndex -eq 2 -and $script:ActiveHostTab -and -not $script:ActiveHostTab.HasLoadedSockets) {
            &$refreshSocketsNow
        } elseif (-not $isSock -and $mainTabs -and $mainTabs.SelectedIndex -eq 2 -and $script:ActiveHostTab) {
            &$flushPendingNetTimeline $script:ActiveHostTab
        }
        &$refreshNetFiltersView
    }

    if ($btnNetModeSockets)  { $btnNetModeSockets.add_Click({ &$setNetworkSubMode "Sockets" }) }
    if ($btnNetModeTimeline) { $btnNetModeTimeline.add_Click({ &$setNetworkSubMode "Timeline" }) }
    if ($btnNetRefreshSockets) { $btnNetRefreshSockets.add_Click({ &$refreshSocketsNow }) }
    if ($chkNetAutoRefresh) {
        $chkNetAutoRefresh.add_Click({
            $want = [bool]$chkNetAutoRefresh.IsChecked
            if ($script:ActiveHostTab) { $script:ActiveHostTab.AutoRefreshSockets = $want }
            &$syncNetworkAutoTimer
            if ($want -and $mainTabs -and $mainTabs.SelectedIndex -eq 2 -and $netUiState.SubMode -eq "Sockets") {
                &$refreshSocketsNow
            }
        })
    }

    foreach ($chipPair in @(
        @{ Ctrl = $chipNetTcp4;        Prop = "FilterTcp4" }
        @{ Ctrl = $chipNetTcp6;        Prop = "FilterTcp6" }
        @{ Ctrl = $chipNetUdp4;        Prop = "FilterUdp4" }
        @{ Ctrl = $chipNetUdp6;        Prop = "FilterUdp6" }
        @{ Ctrl = $chipNetEstablished; Prop = "FilterEst" }
        @{ Ctrl = $chipNetListening;   Prop = "FilterListen" }
        @{ Ctrl = $chipNetSynSent;     Prop = "FilterSynSent" }
        @{ Ctrl = $chipNetTimeWait;    Prop = "FilterTimeWait" }
        @{ Ctrl = $chipNetRecv;        Prop = "FilterRecv" }
        @{ Ctrl = $chipNetSend;        Prop = "FilterSend" }
    )) {
        if ($chipPair.Ctrl) {
            & {
                param($localPairCtrl, $localPairProp, $localUiRef, $localRefFn)
                $localPairCtrl.add_Click({
                    $localUiRef[$localPairProp] = [bool]$localPairCtrl.IsChecked
                    & $localRefFn
                }.GetNewClosure())
            } $chipPair.Ctrl $chipPair.Prop $netUiState $refreshNetFiltersView
        }
    }

    if ($txtSearchNetwork)      { $txtSearchNetwork.add_TextChanged({ &$refreshNetFiltersView }) }
    if ($btnClearSearchNetwork) {
        $btnClearSearchNetwork.add_Click({
            if ($txtSearchNetwork) { $txtSearchNetwork.Text = ""; $txtSearchNetwork.Focus() }
            &$refreshNetFiltersView
        })
    }
    if ($btnNetClear) {
        $btnNetClear.add_Click({
            for ($ri = $netTimelineCollection.Count - 1; $ri -ge 0; $ri--) {
                $netTimelineCollection.RemoveAt($ri)
            }
            if ($script:ActiveHostTab) {
                if ($script:ActiveHostTab.NetworkTimeline) { $script:ActiveHostTab.NetworkTimeline.Clear() }
                if ($script:ActiveHostTab.PendingNetTimeline) { $script:ActiveHostTab.PendingNetTimeline.Clear() }
            }
            &$updateNetEmptyAndSummary
        })
    }
    if ($btnNetBannerEnableEtw)    { $btnNetBannerEnableEtw.add_Click({ &$setNetEtwEnabled $true $true }) }
    if ($btnNetBannerSwitchSockets){ $btnNetBannerSwitchSockets.add_Click({ &$setNetworkSubMode "Sockets" }) }

    if ($btnNetExportCsv) {
        $btnNetExportCsv.add_Click({
            $dlgNet = [Microsoft.Win32.SaveFileDialog]::new()
            $tsNet = (Get-Date).ToString("yyyyMMdd_HHmmss")
            $isSock = ($netUiState.SubMode -eq "Sockets")
            $dlgNet.Filter = "CSV Network Telemetry (*.csv)|*.csv"
            $dlgNet.FileName = if ($isSock) { "PSRPM_Sockets_$($stateContainer.TargetDisplayName)_$tsNet.csv" } else { "PSRPM_NetTimeline_$($stateContainer.TargetDisplayName)_$tsNet.csv" }
            if ($dlgNet.ShowDialog($window) -eq $true) {
                try {
                    $exportList = [System.Collections.Generic.List[Object]]::new()
                    if ($isSock -and $netSocketsView) {
                        foreach ($r in $netSocketsView) {
                            $exportList.Add([PSCustomObject]@{
                                ProcessName    = $r.ProcessName
                                PID            = $r.PIDDisplay
                                Protocol       = $r.Protocol
                                State          = $r.State
                                LocalAddress   = $r.LocalAddress
                                LocalPort      = $r.LocalPortDisplay
                                RemoteAddress  = $r.RemoteAddress
                                RemotePort     = $r.RemotePortDisplay
                                CreateTime     = $r.CreateTime
                                ModuleName     = $r.ModuleName
                                SentPackets    = $r.SentPackets
                                RecvPackets    = $r.RecvPackets
                                SentBytes      = $r.SentBytes
                                RecvBytes      = $r.RecvBytes
                            })
                        }
                    } elseif (-not $isSock -and $netTimelineView) {
                        foreach ($r in $netTimelineView) {
                            $exportList.Add([PSCustomObject]@{
                                Time          = $r.TimeText
                                ProcessName   = $r.ProcessName
                                PID           = $r.PID
                                Operation     = $r.Operation
                                Detail        = $r.Detail
                                Rate          = $r.RateFormatted
                                TreeRate      = $r.TreeRateFormatted
                                SessionTotal  = $r.SessionTotalFormatted
                                Category      = $r.Category
                                User          = $r.User
                            })
                        }
                    }
                    $exportList | Export-Csv -LiteralPath $dlgNet.FileName -NoTypeInformation -Encoding UTF8
                    &$writeAuditLog "EXPORT" "Exported $($exportList.Count) Network Activity rows to '$($dlgNet.FileName)'."
                } catch {
                    &$showMsgSafe $window $null "Failed to export CSV: $($_.Exception.Message)" "PSRPM - Export Error" ([System.Windows.MessageBoxButton]::OK) ([System.Windows.MessageBoxImage]::Error) | Out-Null
                }
            }
        })
    }

    # Network Activity Context Menu Actions (Filter, Go To Process, Open Properties -> TCP/IP Tab)
    $selectProcessInMainGrid = {
        param([int]$pidVal, [bool]$openTcpProps = $false)
        &$jumpToProcessInMainGrid $pidVal $openTcpProps "" $window $false
    }

    $closeSelectedTcpConn = {
        if (-not $gridNetworkSockets -or -not $gridNetworkSockets.SelectedItem) { return }
        $sel = $gridNetworkSockets.SelectedItem
        if (-not (&$canCloseTcpSocket $sel)) {
            return
        }
        $ownerWin = & $getDialogOwnerWindow
        $confirmClose = [System.Windows.MessageBox]::Show(
            $ownerWin,
            "Close TCP connection $($sel.LocalEndpoint) -> $($sel.RemoteEndpoint) owned by '$($sel.ProcessName)' (PID $(if ($sel.PIDDisplay) { $sel.PIDDisplay } else { $sel.PID }))?",
            "PSRPM - Close TCP Connection",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirmClose -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $epSpec = "$($sel.LocalAddress)|$($sel.LocalPort)|$($sel.RemoteAddress)|$($sel.RemotePort)"
        $pIdNum = [int]$sel.PID
        $procTarget = if ($pIdNum -gt 0 -and $engineHandle -and $engineHandle.ProcessMap -and $engineHandle.ProcessMap.ContainsKey($pIdNum)) {
            $engineHandle.ProcessMap[$pIdNum]
        } else {
            [PSCustomObject]@{ PID = $pIdNum; Name = [string]$sel.ProcessName; CreateTime = 0L }
        }
        $afterCloseCb = & {
            param($localRefreshFn)
            return ({
                param([bool]$ok)
                if ($ok -and $localRefreshFn) { & $localRefreshFn }
            }.GetNewClosure())
        } $refreshSocketsNow
        &$invokeProcessAction "CloseTcpConnection" $procTarget "Normal" $afterCloseCb $epSpec
    }

    if ($btnNetCloseConn) { $btnNetCloseConn.add_Click({ &$closeSelectedTcpConn }) }
    if ($gridNetworkSockets) {
        $gridNetworkSockets.add_SelectionChanged({ &$updateNetCloseBtnState })
    }
    foreach ($netGridRef in @($gridNetworkSockets, $gridNetworkTimeline)) {
        if ($netGridRef) {
            & {
                param($gTarget, $localSelFn)
                $gTarget.add_PreviewMouseRightButtonDown({
                    param($sender, $e)
                    $dep = [System.Windows.DependencyObject]$e.OriginalSource
                    while ($null -ne $dep -and $dep -ne $gTarget) {
                        if ($dep -is [System.Windows.Controls.DataGridRow]) {
                            if (-not $dep.IsSelected -and $null -ne $dep.Item) {
                                $dep.IsSelected = $true
                                $gTarget.SelectedItem = $dep.Item
                            }
                            break
                        }
                        if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
                        } else {
                            $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
                        }
                    }
                }.GetNewClosure())
                $gTarget.add_MouseDoubleClick({
                    param($sender, $e)
                    $dep = [System.Windows.DependencyObject]$e.OriginalSource
                    while ($null -ne $dep -and $dep -ne $gTarget) {
                        if ($dep -is [System.Windows.Controls.DataGridRow] -and $null -ne $dep.Item) {
                            $rowPid = 0
                            try { $rowPid = [int]$dep.Item.PID } catch { $rowPid = 0 }
                            & $localSelFn $rowPid $true
                            $e.Handled = $true
                            break
                        }
                        if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
                        } else {
                            $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
                        }
                    }
                }.GetNewClosure())
            } $netGridRef $selectProcessInMainGrid
        }
    }
    $ctxNetSockCloseConn = $window.FindName("CtxNetSockCloseConn")
    if ($ctxNetSockCloseConn) { $ctxNetSockCloseConn.add_Click({ &$closeSelectedTcpConn }) }

    foreach ($ctxMap in @(
        @{ Name = "CtxNetSockFilterProc";    Mode = "FilterProc";   Grid = $gridNetworkSockets }
        @{ Name = "CtxNetSockFilterRemote";  Mode = "FilterRemote"; Grid = $gridNetworkSockets }
        @{ Name = "CtxNetSockGoToProcess";   Mode = "GoToProc";     Grid = $gridNetworkSockets }
        @{ Name = "CtxNetSockPropsTcp";      Mode = "PropsTcp";     Grid = $gridNetworkSockets }
        @{ Name = "CtxNetSockCopyDetails";   Mode = "CopyDetails";  Grid = $gridNetworkSockets }
        @{ Name = "CtxNetSockCopyLocal";     Mode = "CopyLocal";    Grid = $gridNetworkSockets }
        @{ Name = "CtxNetSockCopyRemote";    Mode = "CopyRemote";   Grid = $gridNetworkSockets }
        @{ Name = "CtxNetTimeFilterProc";    Mode = "FilterProc";   Grid = $gridNetworkTimeline }
        @{ Name = "CtxNetTimeGoToProcess";   Mode = "GoToProc";     Grid = $gridNetworkTimeline }
        @{ Name = "CtxNetTimePropsTcp";      Mode = "PropsTcp";     Grid = $gridNetworkTimeline }
        @{ Name = "CtxNetTimeCopyDetails";   Mode = "CopyDetails";  Grid = $gridNetworkTimeline }
    )) {
        $mCtrl = $window.FindName($ctxMap.Name)
        if ($mCtrl) {
            & {
                param($targetMenuCtrl, $localGridRef, $localMode, $localSearch, $localSelFn, $localCopyClip)
                $targetMenuCtrl.add_Click({
                    if (-not $localGridRef -or -not $localGridRef.SelectedItem) { return }
                    $row = $localGridRef.SelectedItem
                    switch ($localMode) {
                        "FilterProc" {
                            if ($localSearch) { $localSearch.Text = [string]$row.ProcessName }
                        }
                        "FilterRemote" {
                            $ipOnly = if ($row.PSObject.Properties['RemoteAddress'] -and $row.RemoteAddress) { [string]$row.RemoteAddress } else {
                                $ep = [string]$row.RemoteEndpoint
                                if ($ep -match '^\[([^\]]+)\]:\d+$') { $matches[1] } elseif ($ep -match '^([^:]+):\d+$') { $matches[1] } else { $ep }
                            }
                            if ($ipOnly -and $ipOnly -notin @("*", "*:*", "0.0.0.0", "::", "0:0:0:0:0:0:0:0") -and $localSearch) { $localSearch.Text = $ipOnly }
                        }
                        "GoToProc"  { & $localSelFn ([int]$row.PID) $false }
                        "PropsTcp"  { & $localSelFn ([int]$row.PID) $true }
                        "CopyDetails" {
                            if ($row.PSObject.Properties['LocalEndpoint']) {
                                $detailLines = @(
                                    "Process Name:   $($row.ProcessName)"
                                    "Process ID:     $($row.PIDDisplay)"
                                    "Protocol:       $($row.Protocol)"
                                    "State:          $($row.State)"
                                    "Local Address:  $($row.LocalAddress)"
                                    "Local Port:     $($row.LocalPortDisplay)"
                                    "Remote Address: $($row.RemoteAddress)"
                                    "Remote Port:    $($row.RemotePortDisplay)"
                                    "Create Time:    $($row.CreateTime)"
                                    "Module Name:    $($row.ModuleName)"
                                    "Sent Packets:   $($row.SentPacketsFormatted)"
                                    "Recv Packets:   $($row.RecvPacketsFormatted)"
                                    "Sent Bytes:     $($row.SentBytesFormatted)"
                                    "Recv Bytes:     $($row.RecvBytesFormatted)"
                                )
                                [void](&$localCopyClip ($detailLines -join "`r`n") "" "")
                            } else {
                                $detailLines = @(
                                    "Time:          $($row.TimeText)"
                                    "Process Name:  $($row.ProcessName)"
                                    "Process ID:    $($row.PID)"
                                    "Operation:     $($row.Operation)"
                                    "Detail:        $($row.Detail)"
                                    "Rate:          $($row.RateFormatted)"
                                    "Tree Rate:     $($row.TreeRateFormatted)"
                                    "Session Total: $($row.SessionTotalFormatted)"
                                    "Category:      $($row.Category)"
                                    "User:          $($row.User)"
                                )
                                [void](&$localCopyClip ($detailLines -join "`r`n") "" "")
                            }
                        }
                        "CopyLocal" { if ($row.LocalEndpoint)  { [void](&$localCopyClip ([string]$row.LocalEndpoint) "" "") } }
                        "CopyRemote"{ if ($row.RemoteEndpoint) { [void](&$localCopyClip ([string]$row.RemoteEndpoint) "" "") } }
                    }
                }.GetNewClosure())
            } $mCtrl $ctxMap.Grid $ctxMap.Mode $txtSearchNetwork $selectProcessInMainGrid $copyToClipboardSafe
        }
    }

    if ($mainTabs) {
        $mainTabs.add_SelectionChanged({
            param($s, $e)
            if ($e.OriginalSource -ne $mainTabs) { return }
            if ($mainTabs.SelectedIndex -eq 2) {
                if ($netUiState.SubMode -eq "Sockets" -and $script:ActiveHostTab -and -not $script:ActiveHostTab.HasLoadedSockets) {
                    &$refreshSocketsNow
                } elseif ($netUiState.SubMode -eq "Timeline" -and $script:ActiveHostTab) {
                    &$flushPendingNetTimeline $script:ActiveHostTab
                }
                &$syncNetworkAutoTimer
                &$updateNetEmptyAndSummary
            } else {
                if ($netAutoTimer.IsEnabled) { $netAutoTimer.Stop() }
            }
        })
    }

    # Engine OnTickProcessed Hook: Refresh Active Graph Hover ToolTips & Append ETW Network Bursts
    $stateContainer.OnTickProcessed = {
        param([double]$elapsedSec, [int]$netCap)
        foreach ($st in @($mainHoverState, $script:ActiveSysHoverState)) {
            if ($st -and $st.ActiveEntry -and $st.ToolTip -and $st.ToolTip.IsOpen) {
                if ($st.ActiveEntry.Border -and $st.ActiveEntry.Border.IsMouseOver) {
                    & $renderChartHoverAt $st $st.ActiveEntry $st.LastPtSurface $st.LastPtBorder $syncHoverTipBrushes
                } else {
                    & $closeHoverState $st
                }
            }
        }
        if ($netCap -ne 1 -or -not $engineHandle -or -not $engineHandle.ProcessMap) { return }
        $nowDt = [DateTime]::Now
        $nowTimeText = $nowDt.ToString("HH:mm:ss.f")
        $nowTicks = [long]$nowDt.Ticks
        $onNetTimeline = ($mainTabs -and $mainTabs.SelectedIndex -eq 2 -and $netUiState.SubMode -eq "Timeline")
        $pendingQueue = if (-not $onNetTimeline -and $script:ActiveHostTab -and $script:ActiveHostTab.PendingNetTimeline) { $script:ActiveHostTab.PendingNetTimeline } else { $null }

        if ($onNetTimeline) {
            if ($script:ActiveHostTab) {
                &$flushPendingNetTimeline $script:ActiveHostTab
            }
            $palMap = &$resolveNetBrushes
            $addedAny = $false
            foreach ($vm in $engineHandle.ProcessMap.Values) {
                if ($vm.NetRxBps -le 0.0 -and $vm.NetTxBps -le 0.0) { continue }
                $sessTot = [long]($vm.SessionNetRxBytes + $vm.SessionNetTxBytes)
                $evObj = &$materializeNetBurstRow @{
                    TimestampTicks = $nowTicks
                    TimeText       = $nowTimeText
                    PID            = [int]$vm.PID
                    ProcessName    = [string]$vm.Name
                    IconSource     = $vm.IconSource
                    IsRecv         = ($vm.NetRxBps -gt 0.0)
                    IsSend         = ($vm.NetTxBps -gt 0.0)
                    RxFmt          = [string]$vm.NetRxFormatted
                    TxFmt          = [string]$vm.NetTxFormatted
                    RateBps        = [double]$vm.NetTotalBps
                    RateFmt        = [string]$vm.NetTotalFormatted
                    TreeRateBps    = [double]$vm.TreeNetTotalBps
                    TreeRateFmt    = [string]$vm.TreeNetTotalFormatted
                    SessionBytes   = $sessTot
                    Category       = [string]$vm.Category
                    User           = [string]$vm.User
                } $palMap
                $netTimelineCollection.Add($evObj)
                $addedAny = $true
            }
            while ($netTimelineCollection.Count -gt 2000) {
                $netTimelineCollection.RemoveAt(0)
            }
            if ($addedAny) {
                &$updateNetEmptyAndSummary
            }
        } elseif ($pendingQueue) {
            foreach ($vm in $engineHandle.ProcessMap.Values) {
                if ($vm.NetRxBps -le 0.0 -and $vm.NetTxBps -le 0.0) { continue }
                $sessTot = [long]($vm.SessionNetRxBytes + $vm.SessionNetTxBytes)
                $pendingQueue.Enqueue(@{
                    TimestampTicks = $nowTicks
                    TimeText       = $nowTimeText
                    PID            = [int]$vm.PID
                    ProcessName    = [string]$vm.Name
                    IconSource     = $vm.IconSource
                    IsRecv         = ($vm.NetRxBps -gt 0.0)
                    IsSend         = ($vm.NetTxBps -gt 0.0)
                    RxFmt          = [string]$vm.NetRxFormatted
                    TxFmt          = [string]$vm.NetTxFormatted
                    RateBps        = [double]$vm.NetTotalBps
                    RateFmt        = [string]$vm.NetTotalFormatted
                    TreeRateBps    = [double]$vm.TreeNetTotalBps
                    TreeRateFmt    = [string]$vm.TreeNetTotalFormatted
                    SessionBytes   = $sessTot
                    Category       = [string]$vm.Category
                    User           = [string]$vm.User
                })
                while ($pendingQueue.Count -gt 2000) {
                    [void]$pendingQueue.Dequeue()
                }
            }
        }
    }

    # Host Tab Switching & Host Reconnect Sync Hooks
    $script:SaveActiveTabFeatureState = {
        param($oldTab)
        if (-not $oldTab) { return }
        $snapSockets = [System.Collections.Generic.List[Object]]::new()
        foreach ($si in $netSocketsCollection) { $snapSockets.Add($si) }
        $oldTab.NetworkSockets = $snapSockets

        $snapTimeline = [System.Collections.Generic.List[Object]]::new()
        foreach ($ti in $netTimelineCollection) { $snapTimeline.Add($ti) }
        $oldTab.NetworkTimeline = $snapTimeline
        $oldTab.NetworkSubMode  = [string]$netUiState.SubMode
    }

    $script:RestoreActiveTabFeatureState = {
        param($newTab)
        &$syncBaselineUi
        if (-not $newTab) { return }

        &$applySocketSnapshotList $newTab.NetworkSockets
        for ($ri = $netTimelineCollection.Count - 1; $ri -ge 0; $ri--) {
            $netTimelineCollection.RemoveAt($ri)
        }
        if ($newTab.NetworkTimeline) {
            foreach ($ti in $newTab.NetworkTimeline) { $netTimelineCollection.Add($ti) }
        }
        if ($chkNetAutoRefresh) { $chkNetAutoRefresh.IsChecked = [bool]$newTab.AutoRefreshSockets }
        $targetMode = if ($newTab.NetworkSubMode) { [string]$newTab.NetworkSubMode } else { "Sockets" }
        &$setNetworkSubMode $targetMode
        &$refreshNetFiltersView
    }

    $script:ResetActiveTabFeatureState = {
        param($tabObj)
        if ($tabObj) {
            $tabObj.HasBaseline = $false
            $tabObj.BaselineTimeText = ""
            $tabObj.BaselineSnapshots = @{}
            $tabObj.HasLoadedSockets = $false
            $tabObj.NetworkSocketsSummary = "Not queried yet"
            $tabObj.NetworkStatusCountsText = "Endpoints: 0  |  Established: 0  |  Listening: 0  |  Time Wait: 0  |  Close Wait: 0"
            $tabObj.NetworkPrevSnapshot = @{}
            $tabObj.AutoRefreshSockets = $true
            if ($tabObj.NetworkSockets)     { $tabObj.NetworkSockets.Clear() }
            if ($tabObj.NetworkTimeline)    { $tabObj.NetworkTimeline.Clear() }
            if ($tabObj.PendingNetTimeline) { $tabObj.PendingNetTimeline.Clear() }
            if ($tabObj.SummaryVm) { $tabObj.SummaryVm.ResetNetAccumTimestamp() }
        }
        $stateContainer.HasBaseline = $false
        $stateContainer.BaselineSnapshots = $null
        if ($chkNetAutoRefresh) { $chkNetAutoRefresh.IsChecked = $true }
        &$syncBaselineUi
        &$applySocketSnapshotList ([System.Collections.Generic.List[Object]]::new())
        for ($ri = $netTimelineCollection.Count - 1; $ri -ge 0; $ri--) {
            $netTimelineCollection.RemoveAt($ri)
        }
        &$syncNetworkAutoTimer
        &$refreshNetFiltersView
    }

    # 16. Global Keyboard Accelerators
    $isInteractiveKeyTarget = {
        param($src)
        foreach ($cand in @($src, [System.Windows.Input.Keyboard]::FocusedElement)) {
            $dep = $cand -as [System.Windows.DependencyObject]
            while ($null -ne $dep) {
                if ($dep -is [System.Windows.Controls.Primitives.TextBoxBase] -or
                    $dep -is [System.Windows.Controls.PasswordBox] -or
                    $dep -is [System.Windows.Controls.Primitives.ButtonBase] -or
                    $dep -is [System.Windows.Controls.MenuItem] -or
                    $dep -is [System.Windows.Controls.Primitives.MenuBase] -or
                    $dep -is [System.Windows.Controls.TabItem] -or
                    $dep -is [System.Windows.Controls.ComboBox] -or
                    $dep -is [System.Windows.Controls.ComboBoxItem] -or
                    $dep -is [System.Windows.Controls.Slider] -or
                    $dep -is [System.Windows.Controls.Primitives.ScrollBar]) {
                    return $true
                }
                if ($dep -is [System.Windows.Controls.DataGrid] -or $dep -is [System.Windows.Window]) {
                    break
                }
                if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
                    $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
                } else {
                    $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
                }
            }
        }
        return $false
    }

    $window.add_PreviewKeyDown({
        param($sender, $e)
        $mods = [System.Windows.Input.Keyboard]::Modifiers
        $isCtrl  = ($mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        $isShift = ($mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
        $searchHasFocus = ($txtSearch.IsKeyboardFocusWithin -or ($txtSearchServices -and $txtSearchServices.IsKeyboardFocusWithin) -or ($txtSearchNetwork -and $txtSearchNetwork.IsKeyboardFocusWithin))

        if ($e.Key -eq [System.Windows.Input.Key]::F1) {
            &$actionShowHelp 0
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::F5) {
            &$triggerImmediateRefresh
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Space -and -not $searchHasFocus -and -not (&$isInteractiveKeyTarget $e.OriginalSource)) {
            &$setPollingRate $stateContainer.IntervalMs (-not [bool]$stateContainer.IsPaused)
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::B) {
            if ($isShift) {
                &$actionClearBaseline
            } else {
                &$actionToggleBaseline
            }
            $e.Handled = $true
        } elseif ($isCtrl -and $isShift -and $e.Key -eq [System.Windows.Input.Key]::N) {
            $want = (-not [bool]$stateContainer.EnableNetEtw)
            &$setNetEtwEnabled $want $want
            $e.Handled = $true
        } elseif ($isCtrl -and $isShift -and $e.Key -eq [System.Windows.Input.Key]::F) {
            &$actionShowFindHandle
            $e.Handled = $true
        } elseif ($isCtrl -and $e.Key -eq [System.Windows.Input.Key]::F) {
            if ($mainTabs -and $mainTabs.SelectedIndex -eq 1 -and $txtSearchServices) {
                $txtSearchServices.Focus()
                $txtSearchServices.SelectAll()
            } elseif ($mainTabs -and $mainTabs.SelectedIndex -eq 2 -and $txtSearchNetwork) {
                $txtSearchNetwork.Focus()
                $txtSearchNetwork.SelectAll()
            } elseif ($txtSearch) {
                $txtSearch.Focus()
                $txtSearch.SelectAll()
            }
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            if ($txtSearchNetwork -and ($txtSearchNetwork.Text.Length -gt 0 -or $txtSearchNetwork.IsKeyboardFocusWithin)) {
                $txtSearchNetwork.Text = ""
                &$refreshNetFiltersView
                if ($netUiState.SubMode -eq "Sockets" -and $gridNetworkSockets) { $gridNetworkSockets.Focus() }
                elseif ($gridNetworkTimeline) { $gridNetworkTimeline.Focus() }
                $e.Handled = $true
            } elseif ($txtSearchServices -and ($txtSearchServices.Text.Length -gt 0 -or $txtSearchServices.IsKeyboardFocusWithin)) {
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
        } elseif ($isCtrl -and $isShift -and $e.Key -eq [System.Windows.Input.Key]::T) {
            &$setAlwaysOnTop (-not [bool]$window.Topmost)
            $e.Handled = $true
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
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Left -and -not $searchHasFocus -and $stateContainer.IsTreeMode) {
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
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Right -and -not $searchHasFocus -and $stateContainer.IsTreeMode) {
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
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Delete -and $gridProcesses.IsKeyboardFocusWithin) {
            if ($isShift) {
                &$invokeProcessAction "KillTree" $null
            } else {
                &$invokeProcessAction "KillProcess" $null
            }
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Return -and $gridProcesses.IsKeyboardFocusWithin) {
            &$actionShowProperties
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Return -and $gridNetworkSockets -and $gridNetworkSockets.IsKeyboardFocusWithin -and $gridNetworkSockets.SelectedItem) {
            $rowPid = 0
            try { $rowPid = [int]$gridNetworkSockets.SelectedItem.PID } catch { $rowPid = 0 }
            &$selectProcessInMainGrid $rowPid $true
            $e.Handled = $true
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Return -and $gridNetworkTimeline -and $gridNetworkTimeline.IsKeyboardFocusWithin -and $gridNetworkTimeline.SelectedItem) {
            $rowPid = 0
            try { $rowPid = [int]$gridNetworkTimeline.SelectedItem.PID } catch { $rowPid = 0 }
            &$selectProcessInMainGrid $rowPid $true
            $e.Handled = $true
        }
    })

    # 17. Deterministic Teardown on Window Close
    $window.add_Closed({
        try {
            & $closeHoverState $mainHoverState
            & $closeHoverState $script:ActiveSysHoverState
            $stateContainer.OnTickProcessed = $null
            $stateContainer.EnableNetEtw = $false
            $stateContainer.IsStopping = $true
            if ($netAutoTimer) { $netAutoTimer.Stop() }
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
            if ($isLocalMode -and ('PSRPM.EtwNetConsumerV1' -as [type])) {
                try {
                    [PSRPM.EtwNetConsumerV1]::Active = 0
                    $th = [PSRPM.EtwNetConsumerV1]::ActiveTraceHandle
                    if ($th -ne [uint64]::MaxValue -and $th -ne [uint64]0) {
                        [void][PSRPM.EtwNetConsumerV1]::CloseTrace($th)
                    }
                    $pb = 112 + [IntPtr]::Size
                    $pt = $pb + 512
                    $ptr = [IntPtr]::Zero
                    try {
                        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($pt)
                        for ($zi = 0; $zi -lt $pt; $zi += 8) { [System.Runtime.InteropServices.Marshal]::WriteInt64($ptr, $zi, 0L) }
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 0, $pt)
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 44, 0x00020000)
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 108 + [IntPtr]::Size, $pb)
                        [void][PSRPM.EtwNetConsumerV1]::ControlTraceW([uint64]0, "PSRPM_NetMon_$PID", $ptr, [uint32]1)
                    } finally {
                        if ($ptr -ne [IntPtr]::Zero) {
                            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
                            $ptr = [IntPtr]::Zero
                        }
                    }
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
            $script:UpdateNetEtwUi              = $null
            $script:OnNetEtwStateUpdated        = $null
            $script:SyncNetworkAutoTimer        = $null
            $script:RefreshNetworkThemeBrushes  = $null
            $script:SaveActiveTabFeatureState   = $null
            $script:RestoreActiveTabFeatureState= $null
            $script:ResetActiveTabFeatureState  = $null
            $script:ActiveHostTab               = $null
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
        [switch]$Wait,

        [Parameter(Mandatory = $false)]
        [Alias("Background")]
        [switch]$NoWait,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")]
        [string]$Theme = "Light",

        [Parameter(Mandatory = $false)]
        [switch]$Dark,

        [Parameter(Mandatory = $false)]
        [Alias("Topmost")]
        [switch]$AlwaysOnTop,

        [Parameter(Mandatory = $false)]
        [string]$IconPath,

        [Parameter(Mandatory = $false)]
        [Alias("Default", "NoConfig", "NoPreferences")]
        [switch]$Defaults
    )
    Start-PSRPM @PSBoundParameters
}

Set-Alias -Name psrpm -Value Start-PSRPM -Scope Global -ErrorAction SilentlyContinue
Export-ModuleMember -Function Start-PSRPM, Start-RemoteProcessManager -Alias psrpm
