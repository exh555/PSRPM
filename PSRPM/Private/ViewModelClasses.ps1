# Requires -Version 5.1
# PSRPM Pure PowerShell 5.1 Native ViewModel Classes
# 100% In-Memory Reflection.Emit Class Compilation (Zero DLL Writes, Zero csc.exe)
# Dirty-Checked INotifyPropertyChanged + Process Explorer Tree Geometry & Sparkline Builders

class PSRPMProcessCollection : System.Collections.ObjectModel.ObservableCollection[Object] {
    hidden [System.Collections.Generic.IList[Object]] $_backing
    hidden static [System.Reflection.PropertyInfo] $_itemsProp = [System.Collections.ObjectModel.Collection[Object]].GetProperty(
        "Items",
        [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    )

    PSRPMProcessCollection() : base() {
        $this._backing = [System.Collections.Generic.IList[Object]]([PSRPMProcessCollection]::_itemsProp.GetValue($this, $null))
    }

    [void] ReplaceOrder([System.Collections.Generic.List[Object]]$desired) {
        $n = $desired.Count
        $m = $this.Count
        if ($m -gt $n) {
            for ($i = $m - 1; $i -ge $n; $i--) {
                $this.RemoveAt($i)
            }
        }
        $common = [Math]::Min($this.Count, $n)
        $changedIdx = [System.Collections.Generic.List[int]]::new()
        $oldItems   = [System.Collections.Generic.List[Object]]::new()
        $backing    = $this._backing
        for ($i = 0; $i -lt $common; $i++) {
            $oldItem = $backing[$i]
            $newItem = $desired[$i]
            if (-not [Object]::ReferenceEquals($oldItem, $newItem)) {
                $changedIdx.Add($i)
                $oldItems.Add($oldItem)
                $backing[$i] = $newItem
            }
        }
        for ($c = 0; $c -lt $changedIdx.Count; $c++) {
            $idx = $changedIdx[$c]
            $evArgs = [System.Collections.Specialized.NotifyCollectionChangedEventArgs]::new(
                [System.Collections.Specialized.NotifyCollectionChangedAction]::Replace,
                $backing[$idx],
                $oldItems[$c],
                $idx
            )
            $this.OnCollectionChanged($evArgs)
        }
        if ($changedIdx.Count -gt 0) {
            $this.OnPropertyChanged([PSRPMThemeRegistry]::GetPropArgs("Item[]"))
        }
        for ($i = $common; $i -lt $n; $i++) {
            $this.Add($desired[$i])
        }
    }
}

class PSRPMThemeRegistry {
    hidden static [hashtable] $_PaletteCache = @{}
    hidden static [hashtable] $_CustomPalettes = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    hidden static [System.Collections.Generic.Dictionary[string, System.ComponentModel.PropertyChangedEventArgs]] $_PropArgsCache = [System.Collections.Generic.Dictionary[string, System.ComponentModel.PropertyChangedEventArgs]]::new([System.StringComparer]::Ordinal)
    hidden static [System.Collections.Generic.Dictionary[string, Object]] $_FrozenBrushCache = [System.Collections.Generic.Dictionary[string, Object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    hidden static [System.Collections.Generic.Dictionary[string, Object]] $_FrozenGeomCache = [System.Collections.Generic.Dictionary[string, Object]]::new([System.StringComparer]::Ordinal)
    hidden static [Object] $_BrushConverter = $null
    hidden static [Object] $_VisVisible = $null
    hidden static [Object] $_VisCollapsed = $null
    hidden static [Object] $_WeightNormal = $null
    hidden static [Object] $_WeightSemiBold = $null
    hidden static [Object] $_WeightBold = $null

    static [System.ComponentModel.PropertyChangedEventArgs] GetPropArgs([string]$name) {
        $argsObj = $null
        if ([PSRPMThemeRegistry]::_PropArgsCache.TryGetValue($name, [ref]$argsObj)) {
            return $argsObj
        }
        $argsObj = [System.ComponentModel.PropertyChangedEventArgs]::new($name)
        [PSRPMThemeRegistry]::_PropArgsCache[$name] = $argsObj
        return $argsObj
    }

    static [Object] GetFrozenBrush([string]$hex) {
        if ([string]::IsNullOrWhiteSpace($hex)) { return $null }
        $cached = $null
        if ([PSRPMThemeRegistry]::_FrozenBrushCache.TryGetValue($hex, [ref]$cached)) {
            return $cached
        }
        try {
            if ($null -eq [PSRPMThemeRegistry]::_BrushConverter) {
                $bcType = [System.Type]::GetType("System.Windows.Media.BrushConverter, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35", $false)
                if ($null -ne $bcType) {
                    [PSRPMThemeRegistry]::_BrushConverter = [Activator]::CreateInstance($bcType)
                }
            }
            if ($null -ne [PSRPMThemeRegistry]::_BrushConverter) {
                $b = [PSRPMThemeRegistry]::_BrushConverter.ConvertFromString($hex)
                if ($null -ne $b -and $b.CanFreeze) { $b.Freeze() }
                if ([PSRPMThemeRegistry]::_FrozenBrushCache.Count -ge 512) {
                    [PSRPMThemeRegistry]::_FrozenBrushCache.Clear()
                }
                [PSRPMThemeRegistry]::_FrozenBrushCache[$hex] = $b
                return $b
            }
        } catch {}
        return $hex
    }

    static [Object] GetFrozenGeometry([string]$pathData) {
        if ([string]::IsNullOrEmpty($pathData)) { return $null }
        $cached = $null
        if ([PSRPMThemeRegistry]::_FrozenGeomCache.TryGetValue($pathData, [ref]$cached)) {
            return $cached
        }
        try {
            $gType = [System.Type]::GetType("System.Windows.Media.Geometry, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35", $false)
            if ($null -ne $gType) {
                $g = $gType.GetMethod("Parse", [Type[]]@([string])).Invoke($null, [Object[]]@($pathData))
                if ($null -ne $g -and $g.CanFreeze) { $g.Freeze() }
                if ([PSRPMThemeRegistry]::_FrozenGeomCache.Count -ge 256) {
                    [PSRPMThemeRegistry]::_FrozenGeomCache.Clear()
                }
                [PSRPMThemeRegistry]::_FrozenGeomCache[$pathData] = $g
                return $g
            }
        } catch {}
        return $pathData
    }

    static [Object] GetVisibility([string]$visStr) {
        if ($null -eq [PSRPMThemeRegistry]::_VisVisible) {
            try {
                $vType = [System.Type]::GetType("System.Windows.Visibility, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35", $false)
                if ($null -ne $vType) {
                    [PSRPMThemeRegistry]::_VisVisible   = [Enum]::Parse($vType, "Visible")
                    [PSRPMThemeRegistry]::_VisCollapsed = [Enum]::Parse($vType, "Collapsed")
                }
            } catch {}
        }
        if ($visStr -eq "Visible") {
            if ($null -ne [PSRPMThemeRegistry]::_VisVisible) { return [PSRPMThemeRegistry]::_VisVisible }
            return "Visible"
        }
        if ($null -ne [PSRPMThemeRegistry]::_VisCollapsed) { return [PSRPMThemeRegistry]::_VisCollapsed }
        return "Collapsed"
    }

    static [Object] GetFontWeight([string]$weightStr) {
        if ($null -eq [PSRPMThemeRegistry]::_WeightNormal) {
            try {
                $fwType = [System.Type]::GetType("System.Windows.FontWeights, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35", $false)
                if ($null -ne $fwType) {
                    [PSRPMThemeRegistry]::_WeightNormal   = $fwType.GetProperty("Normal").GetValue($null, $null)
                    [PSRPMThemeRegistry]::_WeightSemiBold = $fwType.GetProperty("SemiBold").GetValue($null, $null)
                    [PSRPMThemeRegistry]::_WeightBold     = $fwType.GetProperty("Bold").GetValue($null, $null)
                }
            } catch {}
        }
        if ($weightStr -eq "Bold") {
            if ($null -ne [PSRPMThemeRegistry]::_WeightBold) { return [PSRPMThemeRegistry]::_WeightBold }
            return "Bold"
        }
        if ($weightStr -eq "SemiBold") {
            if ($null -ne [PSRPMThemeRegistry]::_WeightSemiBold) { return [PSRPMThemeRegistry]::_WeightSemiBold }
            return "SemiBold"
        }
        if ($null -ne [PSRPMThemeRegistry]::_WeightNormal) { return [PSRPMThemeRegistry]::_WeightNormal }
        return "Normal"
    }

    static [bool] IsDarkMode([string]$mode) {
        $norm = [PSRPMThemeRegistry]::NormalizeMode($mode)
        if ([PSRPMThemeRegistry]::_CustomPalettes.ContainsKey($norm)) {
            return [bool]([PSRPMThemeRegistry]::_CustomPalettes[$norm].IsDark)
        }
        return ($norm -in @("Dark", "TokyoNight", "HighContrast"))
    }

    static [string] NormalizeMode([string]$mode) {
        switch ($mode) {
            "Light"           { return "Light" }
            "Dark"            { return "Dark" }
            "TokyoNight"      { return "TokyoNight" }
            "TokyoNightLight" { return "TokyoNightLight" }
            "Classic"         { return "Classic" }
            "HighContrast"    { return "HighContrast" }
        }
        if (-not [string]::IsNullOrWhiteSpace($mode) -and [PSRPMThemeRegistry]::_CustomPalettes.ContainsKey($mode)) {
            return [string]([PSRPMThemeRegistry]::_CustomPalettes[$mode].Name)
        }
        return "Light"
    }

    static [string[]] GetBuiltInNames() {
        return @("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")
    }

    static [void] ClearCache() {
        [PSRPMThemeRegistry]::_PaletteCache.Clear()
        [PSRPMThemeRegistry]::_FrozenBrushCache.Clear()
    }

    static [void] ClearCustomPalettes() {
        [PSRPMThemeRegistry]::_CustomPalettes.Clear()
        [PSRPMThemeRegistry]::_PaletteCache.Clear()
        [PSRPMThemeRegistry]::_FrozenBrushCache.Clear()
    }

    hidden static [hashtable] CloneDeep([hashtable]$src) {
        $copy = @{}
        foreach ($k in $src.Keys) {
            $v = $src[$k]
            if ($v -is [hashtable]) {
                $copy[$k] = [PSRPMThemeRegistry]::CloneDeep($v)
            } else {
                $copy[$k] = $v
            }
        }
        return $copy
    }

    hidden static [void] MergeSection([hashtable]$target, [hashtable]$overlay) {
        if ($null -eq $overlay) { return }
        foreach ($k in $overlay.Keys) {
            $v = $overlay[$k]
            if (($v -is [hashtable]) -and ($target[$k] -is [hashtable])) {
                [PSRPMThemeRegistry]::MergeSection([hashtable]$target[$k], [hashtable]$v)
            } else {
                $target[$k] = $v
            }
        }
    }

    static [hashtable] RegisterPalette([hashtable]$customSpec) {
        if ($null -eq $customSpec -or [string]::IsNullOrWhiteSpace([string]$customSpec.Name)) {
            throw "Custom theme palette must specify a non-empty 'Name'."
        }
        $name = ([string]$customSpec.Name).Trim()
        $isDark = if ($customSpec.ContainsKey("IsDark")) { [bool]$customSpec.IsDark } else { $false }
        $baseName = if ($customSpec.ContainsKey("BaseTheme") -and -not [string]::IsNullOrWhiteSpace([string]$customSpec.BaseTheme)) {
            [string]$customSpec.BaseTheme
        } elseif ($isDark) {
            "Dark"
        } else {
            "Light"
        }
        if ($baseName -ieq $name) {
            $baseName = if ($isDark) { "Dark" } else { "Light" }
        }
        $basePal = [PSRPMThemeRegistry]::GetPalette($baseName)
        $merged = [PSRPMThemeRegistry]::CloneDeep($basePal)
        $merged.Name = $name
        $merged.DisplayName = if ($customSpec.ContainsKey("DisplayName") -and -not [string]::IsNullOrWhiteSpace([string]$customSpec.DisplayName)) {
            [string]$customSpec.DisplayName
        } else {
            $name
        }
        $merged.IsDark = $isDark
        foreach ($sec in @("Brushes", "Rows", "TabColors", "Legend", "Banner")) {
            if ($customSpec.ContainsKey($sec) -and ($customSpec[$sec] -is [hashtable])) {
                [PSRPMThemeRegistry]::MergeSection([hashtable]$merged[$sec], [hashtable]$customSpec[$sec])
            }
        }
        [PSRPMThemeRegistry]::_CustomPalettes[$name] = $merged
        [PSRPMThemeRegistry]::_PaletteCache[$name] = $merged
        return $merged
    }

    static [hashtable] GetPalette([string]$mode) {
        $norm = [PSRPMThemeRegistry]::NormalizeMode($mode)
        if ([PSRPMThemeRegistry]::_PaletteCache.ContainsKey($norm)) {
            return [PSRPMThemeRegistry]::_PaletteCache[$norm]
        }
        $built = [PSRPMThemeRegistry]::BuildPalette($norm)
        [PSRPMThemeRegistry]::_PaletteCache[$norm] = $built
        return $built
    }

    hidden static [hashtable] BuildPalette([string]$mode) {
        if ([PSRPMThemeRegistry]::_CustomPalettes.ContainsKey($mode)) {
            return [PSRPMThemeRegistry]::_CustomPalettes[$mode]
        }
        if ($mode -eq "TokyoNight") {
            return @{
                Name        = "TokyoNight"
                DisplayName = "Tokyo Night"
                IsDark      = $true
                Brushes     = @{
                    BrushWindowBg        = "#16161E"
                    BrushToolbarBg       = "#16161E"
                    BrushSurfaceBg       = "#1A1B26"
                    BrushHeaderBg        = "#1F2335"
                    BrushBorderSubtle    = "#292E42"
                    BrushTreeLine        = "#565F89"
                    BrushTextPrimary     = "#C0CAF5"
                    BrushTextSecondary   = "#A9B1D6"
                    BrushTextMuted       = "#8890B5"
                    BrushRowHover        = "#202330"
                    BrushRowSelectedBg   = "#3D59A1"
                    BrushRowSelectedFg   = "#FFFFFF"
                    BrushSparkBg         = "#16161E"
                    BrushSparkBorder     = "#292E42"
                    BrushSparkGrid       = "#292E42"
                    BrushMenuBg          = "#16161E"
                    BrushMenuBorder      = "#292E42"
                    BrushMenuHover       = "#202330"
                    BrushAccent          = "#7AA2F7"
                    BrushBadgeBg         = "#3D59A1"
                    BrushBadgeFg         = "#FFFFFF"
                    BrushHelpSuccessFg   = "#9ECE6A"
                    BrushHelpAmberFg     = "#E0AF68"
                    BrushHelpVioletFg    = "#BB9AF7"
                    ColTint_CPU          = "#149ECE6A"
                    ColTint_Net          = "#147AA2F7"
                    ColTint_PrivateBytes = "#14E0AF68"
                    ColTint_WorkingSet   = "#14FF9E64"
                    BrushLogBg           = "#16161E"
                    BrushLogHeaderBg     = "#1F2335"
                    BrushLogBorder       = "#292E42"
                    BrushLogFg           = "#7AA2F7"
                    BrushLogTitleFg      = "#C0CAF5"
                    BrushLogBtnBg        = "#292E42"
                    BrushLogBtnFg        = "#C0CAF5"
                    BrushLogTelem1       = "#7AA2F7"
                    BrushLogTelem2       = "#73DACA"
                    BrushLogTelem3       = "#E0AF68"
                    BrushLogTelem4       = "#BB9AF7"
                    BrushTargetNodeBg    = "#202A46"
                    BrushKillBg          = "#3D1F2B"
                    BrushKillFg          = "#F7768E"
                    BrushKillBorder      = "#F7768E"
                    BrushKillTreeBg      = "#913B4E"
                    BrushKillTreeFg      = "#FFFFFF"
                    BrushKillTreeBorder  = "#F7768E"
                    BrushSwatchSvcBg     = "#2C1F35"
                    BrushSwatchSvcBorder = "#7A4C82"
                    BrushSwatchSvcFg     = "#C0CAF5"
                    BrushSwatchOwnBg     = "#202A46"
                    BrushSwatchOwnBorder = "#3D59A1"
                    BrushSwatchOwnFg     = "#C0CAF5"
                    BrushSwatchPkgBg     = "#172D3A"
                    BrushSwatchPkgBorder = "#2AC3DE"
                    BrushSwatchPkgFg     = "#C0CAF5"
                    BrushSwatchSuspBg    = "#292E42"
                    BrushSwatchSuspBorder= "#565F89"
                    BrushSwatchSuspFg    = "#9AA5CE"
                    BrushSwatchNewBg     = "#1C382E"
                    BrushSwatchNewBorder = "#41A6B5"
                    BrushSwatchNewFg     = "#9ECE6A"
                    BrushSwatchExitBg    = "#3D1F2B"
                    BrushSwatchExitBorder= "#F7768E"
                    BrushSwatchExitFg    = "#F7768E"
                    BrushNetRxStroke     = "#7AA2F7"
                    BrushNetRxFill       = "#447AA2F7"
                    BrushNetTxStroke     = "#73DACA"
                    BrushNetTxFill       = "#4473DACA"
                    BrushDeltaGrowthFg   = "#FF8DA1"
                    BrushDeltaShrinkFg   = "#9ECE6A"
                    BrushDeltaNewFg      = "#7AA2F7"
                    BrushBadgeTcpBg      = "#202A46"
                    BrushBadgeTcpFg      = "#7AA2F7"
                    BrushBadgeUdpBg      = "#172D3A"
                    BrushBadgeUdpFg      = "#73DACA"
                    BrushStateEstBg      = "#1C382E"
                    BrushStateEstFg      = "#9ECE6A"
                    BrushStateListenBg   = "#1F2335"
                    BrushStateListenFg   = "#A9B1D6"
                    BrushStateTimeWaitBg = "#3B2314"
                    BrushStateTimeWaitFg = "#FDBA74"
                    BrushNetRowNewBg     = "#143326"
                    BrushNetRowNewFg     = "#86EFAC"
                    BrushNetRowModBg     = "#3B3210"
                    BrushNetRowModFg     = "#FDE047"
                    BrushNetRowDelBg     = "#3F161D"
                    BrushNetRowDelFg     = "#FCA5A5"
                    BrushGaugeCpuFill    = "#9ECE6A"
                    BrushGaugeCpuArea    = "#559ECE6A"
                    BrushGaugeCpuStroke  = "#9ECE6A"
                    BrushGaugeKernelFill = "#F7768E"
                    BrushGaugeKernelArea = "#77F7768E"
                    BrushGaugeKernelStroke = "#F7768E"
                    BrushGaugeCommitFill = "#E0AF68"
                    BrushGaugeCommitArea = "#55E0AF68"
                    BrushGaugeCommitStroke = "#E0AF68"
                    BrushGaugeRamFill    = "#FF9E64"
                    BrushGaugeRamArea    = "#55FF9E64"
                    BrushGaugeRamStroke  = "#FF9E64"
                    BrushGaugeIoReadFill = "#7AA2F7"
                    BrushGaugeIoReadArea = "#557AA2F7"
                    BrushGaugeIoReadStroke = "#7AA2F7"
                    BrushGaugeIoWriteArea = "#66BB9AF7"
                    BrushGaugeIoWriteStroke = "#BB9AF7"
                    BrushMiniCpuFill     = "#449ECE6A"
                    BrushMiniCommitFill  = "#44E0AF68"
                    BrushMiniRamFill     = "#44FF9E64"
                    BrushSigSignedFg     = "#9ECE6A"
                    BrushSigUnsignedFg   = "#F7768E"
                    BrushStatusActiveFg  = "#9ECE6A"
                    BrushStatusIdleFg    = "#8890B5"
                    BrushStatusExitedFg  = "#F7768E"
                    BrushSvcRunningBg    = "#0F766E"
                    BrushSvcPausedBg     = "#9E6A1C"
                    BrushSvcStoppedBg    = "#3D59A1"
                }
                Rows = @{
                    Default   = @{ Bg = "#1A1B26"; Fg = "#C0CAF5" }
                    New       = @{ Bg = "#1C382E"; Fg = "#9ECE6A" }
                    Exiting   = @{ Bg = "#3D1F2B"; Fg = "#F7768E" }
                    Suspended = @{ Bg = "#292E42"; Fg = "#9AA5CE" }
                    HighCPU   = @{ Bg = "#362A1C"; Fg = "#E0AF68" }
                    Packaged  = @{ Bg = "#172D3A"; Fg = "#C0CAF5" }
                    Service   = @{ Bg = "#2C1F35"; Fg = "#C0CAF5" }
                    Own       = @{ Bg = "#202A46"; Fg = "#C0CAF5" }
                }
                TabColors = @{
                    ActiveBg      = "#1A1B26"
                    ActiveBorder  = "#7AA2F7"
                    ActiveFg      = "#C0CAF5"
                    StandbyBg     = "#16161E"
                    StandbyBorder = "#292E42"
                    StandbyFg     = "#8890B5"
                    BadgeLocalBg  = "#0F766E"
                    BadgeWinRmBg  = "#3D59A1"
                }
                Legend = @{
                    AllActiveBorder = "#7AA2F7"
                    AllIdleBorder   = "#565F89"
                    Service  = @{ Bg = "#2C1F35"; Border = "#7A4C82"; ActiveBg = "#3D2B4A"; ActiveBorder = "#BB9AF7"; ActiveText = "#BB9AF7"; Fg = "#C0CAF5" }
                    Own      = @{ Bg = "#202A46"; Border = "#3D59A1"; ActiveBg = "#2B3A63"; ActiveBorder = "#7AA2F7"; ActiveText = "#7AA2F7"; Fg = "#C0CAF5" }
                    Packaged = @{ Bg = "#172D3A"; Border = "#2AC3DE"; ActiveBg = "#1F3E50"; ActiveBorder = "#7DCFFF"; ActiveText = "#7DCFFF"; Fg = "#C0CAF5" }
                }
                Banner = @{
                    Cap2   = @{ Bg = "#362A1C"; Border = "#E0AF68"; BadgeBg = "#9E6A1C"; Fg = "#C0CAF5"; MutedFg = "#E0AF68"; BtnBg = "#1F2335"; BtnFg = "#C0CAF5" }
                    Cap3   = @{ Bg = "#202A46"; Border = "#7AA2F7"; BadgeBg = "#3D59A1"; Fg = "#C0CAF5"; MutedFg = "#7DCFFF" }
                    CapErr = @{ Bg = "#3D1F2B"; Border = "#F7768E"; BadgeBg = "#913B4E"; Fg = "#C0CAF5"; MutedFg = "#F7768E" }
                }
            }
        }
        if ($mode -eq "TokyoNightLight") {
            return @{
                Name        = "TokyoNightLight"
                DisplayName = "Tokyo Night Light"
                IsDark      = $false
                Brushes     = @{
                    BrushWindowBg        = "#D6D8DF"
                    BrushToolbarBg       = "#DADCE3"
                    BrushSurfaceBg       = "#E6E7ED"
                    BrushHeaderBg        = "#D0D2DA"
                    BrushBorderSubtle    = "#C1C2C7"
                    BrushTreeLine        = "#707280"
                    BrushTextPrimary     = "#343B59"
                    BrushTextSecondary   = "#40434F"
                    BrushTextMuted       = "#4C516D"
                    BrushRowHover        = "#DCDEE3"
                    BrushRowSelectedBg   = "#224E99"
                    BrushRowSelectedFg   = "#FFFFFF"
                    BrushSparkBg         = "#E6E7ED"
                    BrushSparkBorder     = "#C1C2C7"
                    BrushSparkGrid       = "#C1C2C7"
                    BrushMenuBg          = "#D6D8DF"
                    BrushMenuBorder      = "#C1C2C7"
                    BrushMenuHover       = "#E1E2E8"
                    BrushAccent          = "#224E99"
                    BrushBadgeBg         = "#224E99"
                    BrushBadgeFg         = "#FFFFFF"
                    BrushHelpSuccessFg   = "#166534"
                    BrushHelpAmberFg     = "#92400E"
                    BrushHelpVioletFg    = "#6D28D9"
                    ColTint_CPU          = "#1F385F0D"
                    ColTint_Net          = "#1A2959AA"
                    ColTint_PrivateBytes = "#228F5E15"
                    ColTint_WorkingSet   = "#1F965027"
                    BrushLogBg           = "#E6E7ED"
                    BrushLogHeaderBg     = "#D6D8DF"
                    BrushLogBorder       = "#C1C2C7"
                    BrushLogFg           = "#343B59"
                    BrushLogTitleFg      = "#343B59"
                    BrushLogBtnBg        = "#C1C2C7"
                    BrushLogBtnFg        = "#343B59"
                    BrushLogTelem1       = "#2959AA"
                    BrushLogTelem2       = "#1F5B53"
                    BrushLogTelem3       = "#754A0D"
                    BrushLogTelem4       = "#5A3E8E"
                    BrushTargetNodeBg    = "#D6DDF0"
                    BrushKillBg          = "#EDD0D5"
                    BrushKillFg          = "#6E2634"
                    BrushKillBorder      = "#8C4351"
                    BrushKillTreeBg      = "#8C4351"
                    BrushKillTreeFg      = "#FFFFFF"
                    BrushKillTreeBorder  = "#6E2634"
                    BrushSwatchSvcBg     = "#EBD8E4"
                    BrushSwatchSvcBorder = "#A57593"
                    BrushSwatchSvcFg     = "#4A2538"
                    BrushSwatchOwnBg     = "#D6DDF0"
                    BrushSwatchOwnBorder = "#7A92C8"
                    BrushSwatchOwnFg     = "#29355A"
                    BrushSwatchPkgBg     = "#CDE3EA"
                    BrushSwatchPkgBorder = "#568EA1"
                    BrushSwatchPkgFg     = "#0F4B6E"
                    BrushSwatchSuspBg    = "#CFD2DC"
                    BrushSwatchSuspBorder= "#707280"
                    BrushSwatchSuspFg    = "#40434F"
                    BrushSwatchNewBg     = "#CFE3CC"
                    BrushSwatchNewBorder = "#48701A"
                    BrushSwatchNewFg     = "#264709"
                    BrushSwatchExitBg    = "#EDD0D5"
                    BrushSwatchExitBorder= "#8C4351"
                    BrushSwatchExitFg    = "#6E2634"
                    BrushNetRxStroke     = "#2959AA"
                    BrushNetRxFill       = "#442959AA"
                    BrushNetTxStroke     = "#33635C"
                    BrushNetTxFill       = "#4433635C"
                    BrushDeltaGrowthFg   = "#8C2D3D"
                    BrushDeltaShrinkFg   = "#2F5E1B"
                    BrushDeltaNewFg      = "#224E99"
                    BrushBadgeTcpBg      = "#D6DDF0"
                    BrushBadgeTcpFg      = "#224E99"
                    BrushBadgeUdpBg      = "#CDE3EA"
                    BrushBadgeUdpFg      = "#0F4B6E"
                    BrushStateEstBg      = "#CFE3CC"
                    BrushStateEstFg      = "#264709"
                    BrushStateListenBg   = "#CFD2DC"
                    BrushStateListenFg   = "#40434F"
                    BrushStateTimeWaitBg = "#F5DEC9"
                    BrushStateTimeWaitFg = "#7A340E"
                    BrushNetRowNewBg     = "#D5E6CE"
                    BrushNetRowNewFg     = "#1E4620"
                    BrushNetRowModBg     = "#F2E5B5"
                    BrushNetRowModFg     = "#5C430D"
                    BrushNetRowDelBg     = "#F2D4D7"
                    BrushNetRowDelFg     = "#7A1C24"
                    BrushGaugeCpuFill    = "#9BC97E"
                    BrushGaugeCpuArea    = "#889BC97E"
                    BrushGaugeCpuStroke  = "#385F0D"
                    BrushGaugeKernelFill = "#E39AA8"
                    BrushGaugeKernelArea = "#AAE39AA8"
                    BrushGaugeKernelStroke = "#8C2D3D"
                    BrushGaugeCommitFill = "#DEC488"
                    BrushGaugeCommitArea = "#AADEC488"
                    BrushGaugeCommitStroke = "#754A0D"
                    BrushGaugeRamFill    = "#E6AC84"
                    BrushGaugeRamArea    = "#AAE6AC84"
                    BrushGaugeRamStroke  = "#965027"
                    BrushGaugeIoReadFill = "#8FB0DE"
                    BrushGaugeIoReadArea = "#AA8FB0DE"
                    BrushGaugeIoReadStroke = "#2959AA"
                    BrushGaugeIoWriteArea = "#BBD4A2C4"
                    BrushGaugeIoWriteStroke = "#7847BB"
                    BrushMiniCpuFill     = "#33385F0D"
                    BrushMiniCommitFill  = "#338F5E15"
                    BrushMiniRamFill     = "#33965027"
                    BrushSigSignedFg     = "#264709"
                    BrushSigUnsignedFg   = "#8C2D3D"
                    BrushStatusActiveFg  = "#385F0D"
                    BrushStatusIdleFg    = "#4C516D"
                    BrushStatusExitedFg  = "#8C2D3D"
                    BrushSvcRunningBg    = "#33635C"
                    BrushSvcPausedBg     = "#8F5E15"
                    BrushSvcStoppedBg    = "#4C516D"
                }
                Rows = @{
                    Default   = @{ Bg = "#E6E7ED"; Fg = "#343B59" }
                    New       = @{ Bg = "#CFE3CC"; Fg = "#264709" }
                    Exiting   = @{ Bg = "#EDD0D5"; Fg = "#6E2634" }
                    Suspended = @{ Bg = "#CFD2DC"; Fg = "#40434F" }
                    HighCPU   = @{ Bg = "#EBE0C5"; Fg = "#634F30" }
                    Packaged  = @{ Bg = "#CDE3EA"; Fg = "#0F4B6E" }
                    Service   = @{ Bg = "#EBD8E4"; Fg = "#4A2538" }
                    Own       = @{ Bg = "#D6DDF0"; Fg = "#29355A" }
                }
                TabColors = @{
                    ActiveBg      = "#E6E7ED"
                    ActiveBorder  = "#224E99"
                    ActiveFg      = "#343B59"
                    StandbyBg     = "#D6D8DF"
                    StandbyBorder = "#C1C2C7"
                    StandbyFg     = "#4C516D"
                    BadgeLocalBg  = "#33635C"
                    BadgeWinRmBg  = "#224E99"
                }
                Legend = @{
                    AllActiveBorder = "#2959AA"
                    AllIdleBorder   = "#8A8E9E"
                    Service  = @{ Bg = "#EBD8E4"; Border = "#A57593"; ActiveBg = "#E0C2D5"; ActiveBorder = "#7847BB"; ActiveText = "#5A3E8E"; Fg = "#4A2538" }
                    Own      = @{ Bg = "#D6DDF0"; Border = "#7A92C8"; ActiveBg = "#C1CDE9"; ActiveBorder = "#2959AA"; ActiveText = "#2959AA"; Fg = "#29355A" }
                    Packaged = @{ Bg = "#CDE3EA"; Border = "#568EA1"; ActiveBg = "#B5D6E1"; ActiveBorder = "#0F4B6E"; ActiveText = "#0F4B6E"; Fg = "#0F4B6E" }
                }
                Banner = @{
                    Cap2   = @{ Bg = "#EBE0C5"; Border = "#8F5E15"; BadgeBg = "#8F5E15"; Fg = "#343B59"; MutedFg = "#634F30"; BtnBg = "#E6E7ED"; BtnFg = "#343B59" }
                    Cap3   = @{ Bg = "#D6DDF0"; Border = "#2959AA"; BadgeBg = "#2959AA"; Fg = "#343B59"; MutedFg = "#2959AA" }
                    CapErr = @{ Bg = "#EDD0D5"; Border = "#8C4351"; BadgeBg = "#8C4351"; Fg = "#343B59"; MutedFg = "#6E2634" }
                }
            }
        }
        if ($mode -eq "HighContrast") {
            return @{
                Name        = "HighContrast"
                DisplayName = "High-Contrast"
                IsDark      = $true
                Brushes     = @{
                    BrushWindowBg        = "#000000"
                    BrushToolbarBg       = "#000000"
                    BrushSurfaceBg       = "#000000"
                    BrushHeaderBg        = "#1A1A1A"
                    BrushBorderSubtle    = "#FFFFFF"
                    BrushTreeLine        = "#FFFFFF"
                    BrushTextPrimary     = "#FFFFFF"
                    BrushTextSecondary   = "#FFFF00"
                    BrushTextMuted       = "#00FF00"
                    BrushRowHover        = "#330055FF"
                    BrushRowSelectedBg   = "#0055FF"
                    BrushRowSelectedFg   = "#FFFFFF"
                    BrushSparkBg         = "#000000"
                    BrushSparkBorder     = "#FFFFFF"
                    BrushSparkGrid       = "#808080"
                    BrushMenuBg          = "#000000"
                    BrushMenuBorder      = "#FFFFFF"
                    BrushMenuHover       = "#222222"
                    BrushAccent          = "#FFFF00"
                    BrushBadgeBg         = "#0055FF"
                    BrushBadgeFg         = "#FFFFFF"
                    BrushHelpSuccessFg   = "#00FF00"
                    BrushHelpAmberFg     = "#FFFF00"
                    BrushHelpVioletFg    = "#D8B4FE"
                    ColTint_CPU          = "#2200FF00"
                    ColTint_Net          = "#220088FF"
                    ColTint_PrivateBytes = "#22FFFF00"
                    ColTint_WorkingSet   = "#2200FFFF"
                    BrushLogBg           = "#000000"
                    BrushLogHeaderBg     = "#1A1A1A"
                    BrushLogBorder       = "#FFFFFF"
                    BrushLogFg           = "#00FF00"
                    BrushLogTitleFg      = "#FFFF00"
                    BrushLogBtnBg        = "#000000"
                    BrushLogBtnFg        = "#FFFFFF"
                    BrushLogTelem1       = "#00FFFF"
                    BrushLogTelem2       = "#00FF00"
                    BrushLogTelem3       = "#FFFF00"
                    BrushLogTelem4       = "#FFFFFF"
                    BrushTargetNodeBg    = "#001A33"
                    BrushKillBg          = "#550000"
                    BrushKillFg          = "#FFFF00"
                    BrushKillBorder      = "#FFFFFF"
                    BrushKillTreeBg      = "#AA0000"
                    BrushKillTreeFg      = "#FFFFFF"
                    BrushKillTreeBorder  = "#FFFFFF"
                    BrushSwatchSvcBg     = "#330033"
                    BrushSwatchSvcBorder = "#FFFFFF"
                    BrushSwatchSvcFg     = "#FFB6C1"
                    BrushSwatchOwnBg     = "#001A33"
                    BrushSwatchOwnBorder = "#FFFFFF"
                    BrushSwatchOwnFg     = "#ADD8E6"
                    BrushSwatchPkgBg     = "#003333"
                    BrushSwatchPkgBorder = "#FFFFFF"
                    BrushSwatchPkgFg     = "#00FFFF"
                    BrushSwatchSuspBg    = "#222222"
                    BrushSwatchSuspBorder= "#AAAAAA"
                    BrushSwatchSuspFg    = "#AAAAAA"
                    BrushSwatchNewBg     = "#005500"
                    BrushSwatchNewBorder = "#00FF00"
                    BrushSwatchNewFg     = "#00FF00"
                    BrushSwatchExitBg    = "#550000"
                    BrushSwatchExitBorder= "#FF5555"
                    BrushSwatchExitFg    = "#FF5555"
                    BrushNetRxStroke     = "#00FFFF"
                    BrushNetRxFill       = "#4400FFFF"
                    BrushNetTxStroke     = "#00FF00"
                    BrushNetTxFill       = "#4400FF00"
                    BrushDeltaGrowthFg   = "#FF5555"
                    BrushDeltaShrinkFg   = "#00FF00"
                    BrushDeltaNewFg      = "#00FFFF"
                    BrushBadgeTcpBg      = "#001A33"
                    BrushBadgeTcpFg      = "#00FFFF"
                    BrushBadgeUdpBg      = "#003333"
                    BrushBadgeUdpFg      = "#FFFF00"
                    BrushStateEstBg      = "#005500"
                    BrushStateEstFg      = "#00FF00"
                    BrushStateListenBg   = "#1A1A1A"
                    BrushStateListenFg   = "#FFFFFF"
                    BrushStateTimeWaitBg = "#3B1E00"
                    BrushStateTimeWaitFg = "#FFB84D"
                    BrushNetRowNewBg     = "#003300"
                    BrushNetRowNewFg     = "#66FF66"
                    BrushNetRowModBg     = "#332B00"
                    BrushNetRowModFg     = "#FFFF00"
                    BrushNetRowDelBg     = "#3B0000"
                    BrushNetRowDelFg     = "#FF8080"
                    BrushGaugeCpuFill    = "#00CC00"
                    BrushGaugeCpuArea    = "#4400FF00"
                    BrushGaugeCpuStroke  = "#00FF00"
                    BrushGaugeKernelFill = "#FF3333"
                    BrushGaugeKernelArea = "#66FF5555"
                    BrushGaugeKernelStroke = "#FF5555"
                    BrushGaugeCommitFill = "#CCCC00"
                    BrushGaugeCommitArea = "#55FFFF00"
                    BrushGaugeCommitStroke = "#FFFF00"
                    BrushGaugeRamFill    = "#FF9900"
                    BrushGaugeRamArea    = "#55FFAA00"
                    BrushGaugeRamStroke  = "#FFA500"
                    BrushGaugeIoReadFill = "#0099FF"
                    BrushGaugeIoReadArea = "#5500FFFF"
                    BrushGaugeIoReadStroke = "#00FFFF"
                    BrushGaugeIoWriteArea = "#55FF00FF"
                    BrushGaugeIoWriteStroke = "#FF00FF"
                    BrushMiniCpuFill     = "#4400FF00"
                    BrushMiniCommitFill  = "#44FFFF00"
                    BrushMiniRamFill     = "#44FFA500"
                    BrushSigSignedFg     = "#00FF00"
                    BrushSigUnsignedFg   = "#FF5555"
                    BrushStatusActiveFg  = "#00FF00"
                    BrushStatusIdleFg    = "#FFFFFF"
                    BrushStatusExitedFg  = "#FF5555"
                    BrushSvcRunningBg    = "#008000"
                    BrushSvcPausedBg     = "#806600"
                    BrushSvcStoppedBg    = "#444444"
                }
                Rows = @{
                    Default   = @{ Bg = "#000000"; Fg = "#FFFFFF" }
                    New       = @{ Bg = "#005500"; Fg = "#00FF00" }
                    Exiting   = @{ Bg = "#550000"; Fg = "#FF5555" }
                    Suspended = @{ Bg = "#222222"; Fg = "#AAAAAA" }
                    HighCPU   = @{ Bg = "#333300"; Fg = "#FFFF00" }
                    Packaged  = @{ Bg = "#003333"; Fg = "#00FFFF" }
                    Service   = @{ Bg = "#330033"; Fg = "#FFB6C1" }
                    Own       = @{ Bg = "#001A33"; Fg = "#ADD8E6" }
                }
                TabColors = @{
                    ActiveBg      = "#000000"
                    ActiveBorder  = "#FFFF00"
                    ActiveFg      = "#FFFFFF"
                    StandbyBg     = "#1A1A1A"
                    StandbyBorder = "#FFFFFF"
                    StandbyFg     = "#FFFF00"
                    BadgeLocalBg  = "#008000"
                    BadgeWinRmBg  = "#0055FF"
                }
                Legend = @{
                    AllActiveBorder = "#FFFF00"
                    AllIdleBorder   = "#FFFFFF"
                    Service  = @{ Bg = "#330033"; Border = "#FFFFFF"; ActiveBg = "#550055"; ActiveBorder = "#FFFF00"; ActiveText = "#FFFF00"; Fg = "#FFB6C1" }
                    Own      = @{ Bg = "#001A33"; Border = "#FFFFFF"; ActiveBg = "#003366"; ActiveBorder = "#FFFF00"; ActiveText = "#FFFF00"; Fg = "#ADD8E6" }
                    Packaged = @{ Bg = "#003333"; Border = "#FFFFFF"; ActiveBg = "#005555"; ActiveBorder = "#FFFF00"; ActiveText = "#FFFF00"; Fg = "#00FFFF" }
                }
                Banner = @{
                    Cap2   = @{ Bg = "#333300"; Border = "#FFFF00"; BadgeBg = "#806600"; Fg = "#FFFFFF"; MutedFg = "#FFFF00"; BtnBg = "#000000"; BtnFg = "#FFFFFF" }
                    Cap3   = @{ Bg = "#001A33"; Border = "#00FFFF"; BadgeBg = "#0055FF"; Fg = "#FFFFFF"; MutedFg = "#00FFFF" }
                    CapErr = @{ Bg = "#550000"; Border = "#FF5555"; BadgeBg = "#AA0000"; Fg = "#FFFFFF"; MutedFg = "#FF5555" }
                }
            }
        }
        if ($mode -eq "Classic") {
            return @{
                Name        = "Classic"
                DisplayName = "Classic"
                IsDark      = $false
                Brushes     = @{
                    BrushWindowBg        = "#ECE9D8"
                    BrushToolbarBg       = "#ECE9D8"
                    BrushSurfaceBg       = "#FFFFFF"
                    BrushHeaderBg        = "#D4D0C8"
                    BrushBorderSubtle    = "#808080"
                    BrushTreeLine        = "#808080"
                    BrushTextPrimary     = "#000000"
                    BrushTextSecondary   = "#333333"
                    BrushTextMuted       = "#4D4D4D"
                    BrushRowHover        = "#220A246A"
                    BrushRowSelectedBg   = "#0A246A"
                    BrushRowSelectedFg   = "#FFFFFF"
                    BrushSparkBg         = "#ECE9D8"
                    BrushSparkBorder     = "#808080"
                    BrushSparkGrid       = "#CBD5E1"
                    BrushMenuBg          = "#ECE9D8"
                    BrushMenuBorder      = "#808080"
                    BrushMenuHover       = "#D4D0C8"
                    BrushAccent          = "#0A246A"
                    BrushBadgeBg         = "#0A246A"
                    BrushBadgeFg         = "#FFFFFF"
                    BrushHelpSuccessFg   = "#166534"
                    BrushHelpAmberFg     = "#92400E"
                    BrushHelpVioletFg    = "#6D28D9"
                    ColTint_CPU          = "#2222C55E"
                    ColTint_Net          = "#1A0284C7"
                    ColTint_PrivateBytes = "#28EAB308"
                    ColTint_WorkingSet   = "#22F97316"
                    BrushLogBg           = "#0F172A"
                    BrushLogHeaderBg     = "#1E293B"
                    BrushLogBorder       = "#334155"
                    BrushLogFg           = "#38BDF8"
                    BrushLogTitleFg      = "#E2E8F0"
                    BrushLogBtnBg        = "#334155"
                    BrushLogBtnFg        = "#E2E8F0"
                    BrushLogTelem1       = "#93C5FD"
                    BrushLogTelem2       = "#6EE7B7"
                    BrushLogTelem3       = "#FCD34D"
                    BrushLogTelem4       = "#DDD6FE"
                    BrushTargetNodeBg    = "#E0E0FF"
                    BrushKillBg          = "#FEE2E2"
                    BrushKillFg          = "#991B1B"
                    BrushKillBorder      = "#F87171"
                    BrushKillTreeBg      = "#FECACA"
                    BrushKillTreeFg      = "#7F1D1D"
                    BrushKillTreeBorder  = "#EF4444"
                    BrushSwatchSvcBg     = "#FFE0E0"
                    BrushSwatchSvcBorder = "#FDA4AF"
                    BrushSwatchSvcFg     = "#000000"
                    BrushSwatchOwnBg     = "#E0E0FF"
                    BrushSwatchOwnBorder = "#A5B4FC"
                    BrushSwatchOwnFg     = "#000000"
                    BrushSwatchPkgBg     = "#E0FFFF"
                    BrushSwatchPkgBorder = "#06B6D4"
                    BrushSwatchPkgFg     = "#000000"
                    BrushSwatchSuspBg    = "#D0D0D0"
                    BrushSwatchSuspBorder= "#808080"
                    BrushSwatchSuspFg    = "#000000"
                    BrushSwatchNewBg     = "#80FF80"
                    BrushSwatchNewBorder = "#16A34A"
                    BrushSwatchNewFg     = "#000000"
                    BrushSwatchExitBg    = "#FF8080"
                    BrushSwatchExitBorder= "#DC2626"
                    BrushSwatchExitFg    = "#000000"
                    BrushNetRxStroke     = "#0284C7"
                    BrushNetRxFill       = "#5538BDF8"
                    BrushNetTxStroke     = "#008000"
                    BrushNetTxFill       = "#4D16A34A"
                    BrushDeltaGrowthFg   = "#991B1B"
                    BrushDeltaShrinkFg   = "#166534"
                    BrushDeltaNewFg      = "#075985"
                    BrushBadgeTcpBg      = "#E0E0FF"
                    BrushBadgeTcpFg      = "#0A246A"
                    BrushBadgeUdpBg      = "#E0FFFF"
                    BrushBadgeUdpFg      = "#0E7490"
                    BrushStateEstBg      = "#DCFCE7"
                    BrushStateEstFg      = "#166534"
                    BrushStateListenBg   = "#ECE9D8"
                    BrushStateListenFg   = "#333333"
                    BrushStateTimeWaitBg = "#FFEDD5"
                    BrushStateTimeWaitFg = "#9A3412"
                    BrushNetRowNewBg     = "#DCFCE7"
                    BrushNetRowNewFg     = "#14532D"
                    BrushNetRowModBg     = "#FEF08A"
                    BrushNetRowModFg     = "#713F12"
                    BrushNetRowDelBg     = "#FEE2E2"
                    BrushNetRowDelFg     = "#7F1D1D"
                    BrushGaugeCpuFill    = "#86EFAC"
                    BrushGaugeCpuArea    = "#8886EFAC"
                    BrushGaugeCpuStroke  = "#16A34A"
                    BrushGaugeKernelFill = "#FCA5A5"
                    BrushGaugeKernelArea = "#AAFCA5A5"
                    BrushGaugeKernelStroke = "#DC2626"
                    BrushGaugeCommitFill = "#D4D47A"
                    BrushGaugeCommitArea = "#AAD4D47A"
                    BrushGaugeCommitStroke = "#A16207"
                    BrushGaugeRamFill    = "#FDBA74"
                    BrushGaugeRamArea    = "#AAFDBA74"
                    BrushGaugeRamStroke  = "#EA580C"
                    BrushGaugeIoReadFill = "#93C5FD"
                    BrushGaugeIoReadArea = "#AA93C5FD"
                    BrushGaugeIoReadStroke = "#3B82F6"
                    BrushGaugeIoWriteArea = "#BBF9A8D4"
                    BrushGaugeIoWriteStroke = "#DB2777"
                    BrushMiniCpuFill     = "#3322C55E"
                    BrushMiniCommitFill  = "#33EAB308"
                    BrushMiniRamFill     = "#33F97316"
                    BrushSigSignedFg     = "#166534"
                    BrushSigUnsignedFg   = "#991B1B"
                    BrushStatusActiveFg  = "#166534"
                    BrushStatusIdleFg    = "#475569"
                    BrushStatusExitedFg  = "#991B1B"
                    BrushSvcRunningBg    = "#15803D"
                    BrushSvcPausedBg     = "#B45309"
                    BrushSvcStoppedBg    = "#475569"
                }
                Rows = @{
                    Default   = @{ Bg = "#FFFFFF"; Fg = "#000000" }
                    New       = @{ Bg = "#80FF80"; Fg = "#000000" }
                    Exiting   = @{ Bg = "#FF8080"; Fg = "#000000" }
                    Suspended = @{ Bg = "#D0D0D0"; Fg = "#000000" }
                    HighCPU   = @{ Bg = "#FFFFB0"; Fg = "#000000" }
                    Packaged  = @{ Bg = "#E0FFFF"; Fg = "#000000" }
                    Service   = @{ Bg = "#FFE0E0"; Fg = "#000000" }
                    Own       = @{ Bg = "#E0E0FF"; Fg = "#000000" }
                }
                TabColors = @{
                    ActiveBg      = "#FFFFFF"
                    ActiveBorder  = "#0369A1"
                    ActiveFg      = "#0F172A"
                    StandbyBg     = "#E2E8F0"
                    StandbyBorder = "#CBD5E1"
                    StandbyFg     = "#475569"
                    BadgeLocalBg  = "#0F766E"
                    BadgeWinRmBg  = "#0369A1"
                }
                Legend = @{
                    AllActiveBorder = "#0A246A"
                    AllIdleBorder   = "#808080"
                    Service  = @{ Bg = "#FFE0E0"; Border = "#FDA4AF"; ActiveBg = "#FECDD3"; ActiveBorder = "#BE123C"; ActiveText = "#BE123C"; Fg = "#000000" }
                    Own      = @{ Bg = "#E0E0FF"; Border = "#A5B4FC"; ActiveBg = "#C7D2FE"; ActiveBorder = "#4338CA"; ActiveText = "#4338CA"; Fg = "#000000" }
                    Packaged = @{ Bg = "#E0FFFF"; Border = "#06B6D4"; ActiveBg = "#22D3EE"; ActiveBorder = "#0E7490"; ActiveText = "#0E7490"; Fg = "#000000" }
                }
                Banner = @{
                    Cap2   = @{ Bg = "#FEF3C7"; Border = "#F59E0B"; BadgeBg = "#B45309"; Fg = "#0F172A"; MutedFg = "#475569"; BtnBg = "#FFFFFF"; BtnFg = "#0F172A" }
                    Cap3   = @{ Bg = "#E0F2FE"; Border = "#0284C7"; BadgeBg = "#0369A1"; Fg = "#0F172A"; MutedFg = "#475569" }
                    CapErr = @{ Bg = "#FEE2E2"; Border = "#EF4444"; BadgeBg = "#DC2626"; Fg = "#0F172A"; MutedFg = "#475569" }
                }
            }
        }
        if ($mode -eq "Dark") {
            return @{
                Name        = "Dark"
                DisplayName = "Dark Mode"
                IsDark      = $true
                Brushes     = @{
                    BrushWindowBg        = "#0B0F17"
                    BrushToolbarBg       = "#111827"
                    BrushSurfaceBg       = "#0F172A"
                    BrushHeaderBg        = "#1E293B"
                    BrushBorderSubtle    = "#26334D"
                    BrushTreeLine        = "#64748B"
                    BrushTextPrimary     = "#F8FAFC"
                    BrushTextSecondary   = "#CBD5E1"
                    BrushTextMuted       = "#94A3B8"
                    BrushRowHover        = "#330284C7"
                    BrushRowSelectedBg   = "#0369A1"
                    BrushRowSelectedFg   = "#FFFFFF"
                    BrushSparkBg         = "#090D16"
                    BrushSparkBorder     = "#334155"
                    BrushSparkGrid       = "#334155"
                    BrushMenuBg          = "#161F30"
                    BrushMenuBorder      = "#334155"
                    BrushMenuHover       = "#26354D"
                    BrushAccent          = "#38BDF8"
                    BrushBadgeBg         = "#0369A1"
                    BrushBadgeFg         = "#FFFFFF"
                    BrushHelpSuccessFg   = "#4ADE80"
                    BrushHelpAmberFg     = "#FBBF24"
                    BrushHelpVioletFg    = "#C4B5FD"
                    ColTint_CPU          = "#1422C55E"
                    ColTint_Net          = "#120284C7"
                    ColTint_PrivateBytes = "#14EAB308"
                    ColTint_WorkingSet   = "#14F97316"
                    BrushLogBg           = "#090D16"
                    BrushLogHeaderBg     = "#111827"
                    BrushLogBorder       = "#334155"
                    BrushLogFg           = "#7DD3FC"
                    BrushLogTitleFg      = "#F8FAFC"
                    BrushLogBtnBg        = "#1E293B"
                    BrushLogBtnFg        = "#F8FAFC"
                    BrushLogTelem1       = "#93C5FD"
                    BrushLogTelem2       = "#6EE7B7"
                    BrushLogTelem3       = "#FCD34D"
                    BrushLogTelem4       = "#DDD6FE"
                    BrushTargetNodeBg    = "#1E3A5F"
                    BrushKillBg          = "#451A22"
                    BrushKillFg          = "#FCA5A5"
                    BrushKillBorder      = "#991B1B"
                    BrushKillTreeBg      = "#7F1D1D"
                    BrushKillTreeFg      = "#FEE2E2"
                    BrushKillTreeBorder  = "#EF4444"
                    BrushSwatchSvcBg     = "#3B1824"
                    BrushSwatchSvcBorder = "#BE123C"
                    BrushSwatchSvcFg     = "#F8FAFC"
                    BrushSwatchOwnBg     = "#1E2646"
                    BrushSwatchOwnBorder = "#4F46E5"
                    BrushSwatchOwnFg     = "#F8FAFC"
                    BrushSwatchPkgBg     = "#0E3A47"
                    BrushSwatchPkgBorder = "#0891B2"
                    BrushSwatchPkgFg     = "#F8FAFC"
                    BrushSwatchSuspBg    = "#334155"
                    BrushSwatchSuspBorder= "#64748B"
                    BrushSwatchSuspFg    = "#CBD5E1"
                    BrushSwatchNewBg     = "#14532D"
                    BrushSwatchNewBorder = "#22C55E"
                    BrushSwatchNewFg     = "#F8FAFC"
                    BrushSwatchExitBg    = "#7F1D1D"
                    BrushSwatchExitBorder= "#EF4444"
                    BrushSwatchExitFg    = "#F8FAFC"
                    BrushNetRxStroke     = "#38BDF8"
                    BrushNetRxFill       = "#4438BDF8"
                    BrushNetTxStroke     = "#34D399"
                    BrushNetTxFill       = "#4410B981"
                    BrushDeltaGrowthFg   = "#FCA5A5"
                    BrushDeltaShrinkFg   = "#6EE7B7"
                    BrushDeltaNewFg      = "#7DD3FC"
                    BrushBadgeTcpBg      = "#1E3A5F"
                    BrushBadgeTcpFg      = "#7DD3FC"
                    BrushBadgeUdpBg      = "#0E3A47"
                    BrushBadgeUdpFg      = "#67E8F9"
                    BrushStateEstBg      = "#14532D"
                    BrushStateEstFg      = "#86EFAC"
                    BrushStateListenBg   = "#1E293B"
                    BrushStateListenFg   = "#CBD5E1"
                    BrushStateTimeWaitBg = "#3B2314"
                    BrushStateTimeWaitFg = "#FDBA74"
                    BrushNetRowNewBg     = "#143326"
                    BrushNetRowNewFg     = "#86EFAC"
                    BrushNetRowModBg     = "#3B3210"
                    BrushNetRowModFg     = "#FDE047"
                    BrushNetRowDelBg     = "#3F161D"
                    BrushNetRowDelFg     = "#FCA5A5"
                    BrushGaugeCpuFill    = "#22C55E"
                    BrushGaugeCpuArea    = "#5522C55E"
                    BrushGaugeCpuStroke  = "#4ADE80"
                    BrushGaugeKernelFill = "#EF4444"
                    BrushGaugeKernelArea = "#77EF4444"
                    BrushGaugeKernelStroke = "#F87171"
                    BrushGaugeCommitFill = "#CA8A04"
                    BrushGaugeCommitArea = "#55CA8A04"
                    BrushGaugeCommitStroke = "#FACC15"
                    BrushGaugeRamFill    = "#EA580C"
                    BrushGaugeRamArea    = "#55EA580C"
                    BrushGaugeRamStroke  = "#FB923C"
                    BrushGaugeIoReadFill = "#38BDF8"
                    BrushGaugeIoReadArea = "#5538BDF8"
                    BrushGaugeIoReadStroke = "#38BDF8"
                    BrushGaugeIoWriteArea = "#66F472B6"
                    BrushGaugeIoWriteStroke = "#F472B6"
                    BrushMiniCpuFill     = "#4422C55E"
                    BrushMiniCommitFill  = "#44EAB308"
                    BrushMiniRamFill     = "#44F97316"
                    BrushSigSignedFg     = "#4ADE80"
                    BrushSigUnsignedFg   = "#FCA5A5"
                    BrushStatusActiveFg  = "#4ADE80"
                    BrushStatusIdleFg    = "#94A3B8"
                    BrushStatusExitedFg  = "#F87171"
                    BrushSvcRunningBg    = "#15803D"
                    BrushSvcPausedBg     = "#B45309"
                    BrushSvcStoppedBg    = "#475569"
                }
                Rows = @{
                    Default   = @{ Bg = "#0F172A"; Fg = "#F1F5F9" }
                    New       = @{ Bg = "#14532D"; Fg = "#F1F5F9" }
                    Exiting   = @{ Bg = "#7F1D1D"; Fg = "#F1F5F9" }
                    Suspended = @{ Bg = "#334155"; Fg = "#CBD5E1" }
                    HighCPU   = @{ Bg = "#451A03"; Fg = "#F1F5F9" }
                    Packaged  = @{ Bg = "#0E3A47"; Fg = "#F1F5F9" }
                    Service   = @{ Bg = "#3B1824"; Fg = "#F1F5F9" }
                    Own       = @{ Bg = "#1E2646"; Fg = "#F1F5F9" }
                }
                TabColors = @{
                    ActiveBg      = "#0F172A"
                    ActiveBorder  = "#38BDF8"
                    ActiveFg      = "#F8FAFC"
                    StandbyBg     = "#1E293B"
                    StandbyBorder = "#334155"
                    StandbyFg     = "#94A3B8"
                    BadgeLocalBg  = "#0F766E"
                    BadgeWinRmBg  = "#0369A1"
                }
                Legend = @{
                    AllActiveBorder = "#38BDF8"
                    AllIdleBorder   = "#64748B"
                    Service  = @{ Bg = "#3B1824"; Border = "#BE123C"; ActiveBg = "#5B1B2E"; ActiveBorder = "#FB7185"; ActiveText = "#FDA4AF"; Fg = "#F8FAFC" }
                    Own      = @{ Bg = "#1E2646"; Border = "#4F46E5"; ActiveBg = "#2A3566"; ActiveBorder = "#818CF8"; ActiveText = "#A5B4FC"; Fg = "#F8FAFC" }
                    Packaged = @{ Bg = "#0E3A47"; Border = "#0891B2"; ActiveBg = "#155E75"; ActiveBorder = "#22D3EE"; ActiveText = "#67E8F9"; Fg = "#F8FAFC" }
                }
                Banner = @{
                    Cap2   = @{ Bg = "#451A03"; Border = "#F59E0B"; BadgeBg = "#B45309"; Fg = "#FEF3C7"; MutedFg = "#FDE68A"; BtnBg = "#1E293B"; BtnFg = "#F8FAFC" }
                    Cap3   = @{ Bg = "#082F49"; Border = "#0284C7"; BadgeBg = "#0369A1"; Fg = "#E0F2FE"; MutedFg = "#BAE6FD" }
                    CapErr = @{ Bg = "#450A0A"; Border = "#EF4444"; BadgeBg = "#DC2626"; Fg = "#FEE2E2"; MutedFg = "#FECACA" }
                }
            }
        }
        # Default: Clean Light
        return @{
            Name        = "Light"
            DisplayName = "Clean Light"
            IsDark      = $false
            Brushes     = @{
                BrushWindowBg        = "#F8FAFC"
                BrushToolbarBg       = "#F1F5F9"
                BrushSurfaceBg       = "#FFFFFF"
                BrushHeaderBg        = "#E2E8F0"
                BrushBorderSubtle    = "#CBD5E1"
                BrushTreeLine        = "#64748B"
                BrushTextPrimary     = "#0F172A"
                BrushTextSecondary   = "#334155"
                BrushTextMuted       = "#475569"
                BrushRowHover        = "#220284C7"
                BrushRowSelectedBg   = "#006CBE"
                BrushRowSelectedFg   = "#FFFFFF"
                BrushSparkBg         = "#FFFFFF"
                BrushSparkBorder     = "#94A3B8"
                BrushSparkGrid       = "#CBD5E1"
                BrushMenuBg          = "#FFFFFF"
                BrushMenuBorder      = "#CBD5E1"
                BrushMenuHover       = "#F1F5F9"
                BrushAccent          = "#0369A1"
                BrushBadgeBg         = "#0369A1"
                BrushBadgeFg         = "#FFFFFF"
                BrushHelpSuccessFg   = "#166534"
                BrushHelpAmberFg     = "#92400E"
                BrushHelpVioletFg    = "#6D28D9"
                ColTint_CPU          = "#2222C55E"
                ColTint_Net          = "#1A0284C7"
                ColTint_PrivateBytes = "#28EAB308"
                ColTint_WorkingSet   = "#22F97316"
                BrushLogBg           = "#0F172A"
                BrushLogHeaderBg     = "#1E293B"
                BrushLogBorder       = "#334155"
                BrushLogFg           = "#38BDF8"
                BrushLogTitleFg      = "#E2E8F0"
                BrushLogBtnBg        = "#334155"
                BrushLogBtnFg        = "#E2E8F0"
                BrushLogTelem1       = "#93C5FD"
                BrushLogTelem2       = "#6EE7B7"
                BrushLogTelem3       = "#FCD34D"
                BrushLogTelem4       = "#DDD6FE"
                BrushTargetNodeBg    = "#E0F2FE"
                BrushKillBg          = "#FEE2E2"
                BrushKillFg          = "#991B1B"
                BrushKillBorder      = "#F87171"
                BrushKillTreeBg      = "#FECACA"
                BrushKillTreeFg      = "#7F1D1D"
                BrushKillTreeBorder  = "#EF4444"
                BrushSwatchSvcBg     = "#FFE4E6"
                BrushSwatchSvcBorder = "#FDA4AF"
                BrushSwatchSvcFg     = "#0F172A"
                BrushSwatchOwnBg     = "#E0E7FF"
                BrushSwatchOwnBorder = "#A5B4FC"
                BrushSwatchOwnFg     = "#0F172A"
                BrushSwatchPkgBg     = "#67E8F9"
                BrushSwatchPkgBorder = "#06B6D4"
                BrushSwatchPkgFg     = "#0F172A"
                BrushSwatchSuspBg    = "#94A3B8"
                BrushSwatchSuspBorder= "#64748B"
                BrushSwatchSuspFg    = "#0F172A"
                BrushSwatchNewBg     = "#86EFAC"
                BrushSwatchNewBorder = "#22C55E"
                BrushSwatchNewFg     = "#0F172A"
                BrushSwatchExitBg    = "#FCA5A5"
                BrushSwatchExitBorder= "#EF4444"
                BrushSwatchExitFg    = "#0F172A"
                BrushNetRxStroke     = "#0284C7"
                BrushNetRxFill       = "#5538BDF8"
                BrushNetTxStroke     = "#15803D"
                BrushNetTxFill       = "#4D22C55E"
                BrushDeltaGrowthFg   = "#B91C1C"
                BrushDeltaShrinkFg   = "#166534"
                BrushDeltaNewFg      = "#0369A1"
                BrushBadgeTcpBg      = "#E0F2FE"
                BrushBadgeTcpFg      = "#0369A1"
                BrushBadgeUdpBg      = "#ECFEFF"
                BrushBadgeUdpFg      = "#0E7490"
                BrushStateEstBg      = "#DCFCE7"
                BrushStateEstFg      = "#166534"
                BrushStateListenBg   = "#F1F5F9"
                BrushStateListenFg   = "#475569"
                BrushStateTimeWaitBg = "#FFEDD5"
                BrushStateTimeWaitFg = "#9A3412"
                BrushNetRowNewBg     = "#DCFCE7"
                BrushNetRowNewFg     = "#14532D"
                BrushNetRowModBg     = "#FEF08A"
                BrushNetRowModFg     = "#713F12"
                BrushNetRowDelBg     = "#FEE2E2"
                BrushNetRowDelFg     = "#7F1D1D"
                BrushGaugeCpuFill    = "#86EFAC"
                BrushGaugeCpuArea    = "#8886EFAC"
                BrushGaugeCpuStroke  = "#16A34A"
                BrushGaugeKernelFill = "#FCA5A5"
                BrushGaugeKernelArea = "#AAFCA5A5"
                BrushGaugeKernelStroke = "#DC2626"
                BrushGaugeCommitFill = "#D4D47A"
                BrushGaugeCommitArea = "#AAD4D47A"
                BrushGaugeCommitStroke = "#A16207"
                BrushGaugeRamFill    = "#FDBA74"
                BrushGaugeRamArea    = "#AAFDBA74"
                BrushGaugeRamStroke  = "#EA580C"
                BrushGaugeIoReadFill = "#93C5FD"
                BrushGaugeIoReadArea = "#AA93C5FD"
                BrushGaugeIoReadStroke = "#3B82F6"
                BrushGaugeIoWriteArea = "#BBF9A8D4"
                BrushGaugeIoWriteStroke = "#DB2777"
                BrushMiniCpuFill     = "#3322C55E"
                BrushMiniCommitFill  = "#33EAB308"
                BrushMiniRamFill     = "#33F97316"
                BrushSigSignedFg     = "#166534"
                BrushSigUnsignedFg   = "#B91C1C"
                BrushStatusActiveFg  = "#166534"
                BrushStatusIdleFg    = "#475569"
                BrushStatusExitedFg  = "#B91C1C"
                BrushSvcRunningBg    = "#15803D"
                BrushSvcPausedBg     = "#B45309"
                BrushSvcStoppedBg    = "#475569"
            }
            Rows = @{
                Default   = @{ Bg = "#FFFFFF"; Fg = "#0F172A" }
                New       = @{ Bg = "#86EFAC"; Fg = "#0F172A" }
                Exiting   = @{ Bg = "#FCA5A5"; Fg = "#0F172A" }
                Suspended = @{ Bg = "#94A3B8"; Fg = "#0F172A" }
                HighCPU   = @{ Bg = "#FDE68A"; Fg = "#0F172A" }
                Packaged  = @{ Bg = "#67E8F9"; Fg = "#0F172A" }
                Service   = @{ Bg = "#FFE4E6"; Fg = "#0F172A" }
                Own       = @{ Bg = "#E0E7FF"; Fg = "#0F172A" }
            }
            TabColors = @{
                ActiveBg      = "#FFFFFF"
                ActiveBorder  = "#0369A1"
                ActiveFg      = "#0F172A"
                StandbyBg     = "#E2E8F0"
                StandbyBorder = "#CBD5E1"
                StandbyFg     = "#475569"
                BadgeLocalBg  = "#0F766E"
                BadgeWinRmBg  = "#0369A1"
            }
            Legend = @{
                AllActiveBorder = "#0369A1"
                AllIdleBorder   = "#94A3B8"
                Service  = @{ Bg = "#FFE4E6"; Border = "#FDA4AF"; ActiveBg = "#FECDD3"; ActiveBorder = "#BE123C"; ActiveText = "#BE123C"; Fg = "#0F172A" }
                Own      = @{ Bg = "#E0E7FF"; Border = "#A5B4FC"; ActiveBg = "#C7D2FE"; ActiveBorder = "#4338CA"; ActiveText = "#4338CA"; Fg = "#0F172A" }
                Packaged = @{ Bg = "#67E8F9"; Border = "#06B6D4"; ActiveBg = "#22D3EE"; ActiveBorder = "#0E7490"; ActiveText = "#0E7490"; Fg = "#0F172A" }
            }
            Banner = @{
                Cap2   = @{ Bg = "#FEF3C7"; Border = "#F59E0B"; BadgeBg = "#B45309"; Fg = "#0F172A"; MutedFg = "#475569"; BtnBg = "#FFFFFF"; BtnFg = "#0F172A" }
                Cap3   = @{ Bg = "#E0F2FE"; Border = "#0284C7"; BadgeBg = "#0369A1"; Fg = "#0F172A"; MutedFg = "#475569" }
                CapErr = @{ Bg = "#FEE2E2"; Border = "#EF4444"; BadgeBg = "#DC2626"; Fg = "#0F172A"; MutedFg = "#475569" }
            }
        }
    }
}

class ProcessItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [int]$PID
    [string]$PIDDisplay
    [long]$CreateTime
    [string]$Name
    [int]$ParentPID
    [double]$CPU
    [string]$CPUFormatted
    [double]$TreeCPU
    [string]$TreeCPUFormatted
    hidden [double]$PendingTreeCPU
    [long]$NetRxBps
    [long]$NetTxBps
    [long]$NetTotalBps
    [string]$NetTotalFormatted
    [string]$NetRxFormatted
    [string]$NetTxFormatted
    [long]$TreeNetRxBps
    [long]$TreeNetTxBps
    [long]$TreeNetTotalBps
    [string]$TreeNetTotalFormatted
    [string]$NetToolTip
    hidden [long]$PendingTreeNetRx
    hidden [long]$PendingTreeNetTx
    [long]$MemoryBytes
    [string]$MemoryFormatted
    [long]$PrivateBytes
    [string]$PrivateBytesFormatted
    [string]$Status
    [string]$User
    [string]$Description
    [string]$CompanyName
    [string]$FileVersion
    [int]$Threads
    [int]$Handles
    [string]$HandlesFormatted
    [string]$Path
    [string]$CommandLine
    [string]$CommandLineToolTip
    [string]$StartTime
    [string]$Architecture
    [int]$SessionId
    [int]$BasePriority
    [string]$Category
    [string]$HostedServices
    [int]$LifecycleState # 0 = Normal, 1 = New (Lime Flash), 2 = Exiting (Crimson Flash)

    # Session Peaks, Local Network Session Totals & Baseline Diff State
    [double]$PeakCPU
    [string]$PeakCPUFormatted
    [long]$PeakPrivateBytes
    [string]$PeakPrivateBytesFormatted
    [long]$PeakMemoryBytes
    [string]$PeakMemoryFormatted
    [int]$PeakHandles
    [string]$PeakHandlesFormatted
    [long]$SessionNetRxBytes
    [long]$SessionNetTxBytes

    [bool]$HasBaseline
    [bool]$SpawnedPostBaseline
    [double]$BaselineCPU
    [long]$BaselinePrivateBytes
    [long]$BaselineMemoryBytes
    [int]$BaselineHandles
    [double]$CPUDelta
    [long]$PrivateBytesDelta
    [long]$MemoryDelta
    [int]$HandlesDelta
    [string]$CPUDeltaFormatted
    [string]$CPUDeltaBrush
    [Object]$CPUDeltaSolidBrush
    [string]$PrivateDeltaFormatted
    [string]$PrivateDeltaBadgeText
    [string]$PrivateDeltaBadgeVisibility
    [Object]$PrivateDeltaBadgeVis
    [string]$PrivateDeltaBrush
    [Object]$PrivateDeltaSolidBrush
    [string]$MemoryDeltaFormatted
    [string]$WsDeltaBadgeText
    [string]$WsDeltaBadgeVisibility
    [Object]$WsDeltaBadgeVis
    [string]$MemoryDeltaBrush
    [Object]$MemoryDeltaSolidBrush
    [string]$HandlesDeltaFormatted
    [string]$HandlesDeltaBrush
    [Object]$HandlesDeltaSolidBrush

    # Enriched Hover & Cell ToolTips (CommandLineToolTip preserved separately)
    [string]$ProcessHoverToolTip
    [string]$CpuCellToolTip
    [string]$PrivateCellToolTip
    [string]$WsCellToolTip
    [string]$HandlesCellToolTip

    # Tree-Grid Visual State Properties
    [bool]$IsExpanded
    [bool]$HasChildren
    [int]$Level
    [bool]$IsTreeMode
    [bool]$IsCompactRows
    [double]$IndentWidth
    [string]$TreeGuideVisibility
    [Object]$TreeGuideVis
    [string]$TreeGuideGeometry
    [Object]$TreeGuidePathGeometry
    [string]$ToggleVisibility
    [Object]$ToggleVis
    [string]$LeafVisibility
    [Object]$LeafVis
    [string]$ExpanderGeometry
    [Object]$ExpanderPathGeometry
    [Object]$IconSource
    [string]$FallbackIconVisibility
    [Object]$FallbackIconVis
    [string]$NameFontWeight
    [Object]$NameWeight
    [string]$RowBackground
    [Object]$RowBackgroundBrush
    [string]$RowForeground
    [Object]$RowForegroundBrush
    [double]$RowOpacity
    [bool]$IsDarkTheme
    [string]$ThemeMode
    [bool]$EnableCategoryHighlights

    [System.Collections.ObjectModel.ObservableCollection[ProcessItemViewModel]]$Children

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    ProcessItemViewModel() {
        $this.Children               = [System.Collections.ObjectModel.ObservableCollection[ProcessItemViewModel]]::new()
        $this.Handlers               = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.PIDDisplay             = "0"
        $this.Name                   = ""
        $this.User                   = "N/A"
        $this.Description            = ""
        $this.CompanyName            = ""
        $this.FileVersion            = ""
        $this.Path                   = "N/A"
        $this.CommandLine            = "N/A"
        $this.CommandLineToolTip     = ""
        $this.StartTime              = "N/A"
        $this.Architecture           = "x64"
        $this.Category               = "System"
        $this.HostedServices         = ""
        $this.Status                 = "Running"
        $this.CPU                    = 0.0
        $this.CPUFormatted           = ""
        $this.TreeCPU                = 0.0
        $this.TreeCPUFormatted       = ""
        $this.PendingTreeCPU         = 0.0
        $this.MemoryBytes            = 0L
        $this.MemoryFormatted        = "0 K"
        $this.PrivateBytes           = 0L
        $this.PrivateBytesFormatted  = "0 K"
        $this.Handles                = 0
        $this.HandlesFormatted       = "0"
        $this.Threads                = 0
        $this.LifecycleState         = 0
        $this.IsExpanded             = $true
        $this.HasChildren            = $false
        $this.Level                  = 0
        $this.IsTreeMode             = $true
        $this.IndentWidth            = 16.0
        $this.TreeGuideVisibility    = "Visible"
        $this.TreeGuideVis           = [PSRPMThemeRegistry]::GetVisibility("Visible")
        $this.TreeGuideGeometry      = ""
        $this.TreeGuidePathGeometry  = $null
        $this.ToggleVisibility       = "Collapsed"
        $this.ToggleVis              = [PSRPMThemeRegistry]::GetVisibility("Collapsed")
        $this.LeafVisibility         = "Visible"
        $this.LeafVis                = [PSRPMThemeRegistry]::GetVisibility("Visible")
        $this.ExpanderGeometry       = "M 0,2.5 L 5,2.5"
        $this.ExpanderPathGeometry   = [PSRPMThemeRegistry]::GetFrozenGeometry("M 0,2.5 L 5,2.5")
        $this.IconSource             = $null
        $this.FallbackIconVisibility = "Visible"
        $this.FallbackIconVis        = [PSRPMThemeRegistry]::GetVisibility("Visible")
        $this.NameFontWeight         = "Normal"
        $this.NameWeight             = [PSRPMThemeRegistry]::GetFontWeight("Normal")
        $this.RowBackground          = "#FFFFFF"
        $this.RowBackgroundBrush     = [PSRPMThemeRegistry]::GetFrozenBrush("#FFFFFF")
        $this.RowForeground          = "#0F172A"
        $this.RowForegroundBrush     = [PSRPMThemeRegistry]::GetFrozenBrush("#0F172A")
        $this.RowOpacity             = 1.0
        $this.IsDarkTheme            = $false
        $this.ThemeMode              = "Light"
        $this.EnableCategoryHighlights = $true

        $this.PeakCPU                    = 0.0
        $this.PeakCPUFormatted           = ""
        $this.PeakPrivateBytes           = 0L
        $this.PeakPrivateBytesFormatted  = "0 K"
        $this.PeakMemoryBytes            = 0L
        $this.PeakMemoryFormatted        = "0 K"
        $this.PeakHandles                = 0
        $this.PeakHandlesFormatted       = "0"
        $this.SessionNetRxBytes          = 0L
        $this.SessionNetTxBytes          = 0L

        $this.HasBaseline                = $false
        $this.SpawnedPostBaseline        = $false
        $this.BaselineCPU                = 0.0
        $this.BaselinePrivateBytes       = 0L
        $this.BaselineMemoryBytes        = 0L
        $this.BaselineHandles            = 0
        $this.CPUDelta                   = 0.0
        $this.PrivateBytesDelta          = 0L
        $this.MemoryDelta                = 0L
        $this.HandlesDelta               = 0
        $this.CPUDeltaFormatted          = ""
        $this.CPUDeltaBrush              = "#475569"
        $this.CPUDeltaSolidBrush         = [PSRPMThemeRegistry]::GetFrozenBrush("#475569")
        $this.PrivateDeltaFormatted      = ""
        $this.PrivateDeltaBadgeText      = ""
        $this.PrivateDeltaBadgeVisibility= "Collapsed"
        $this.PrivateDeltaBadgeVis       = [PSRPMThemeRegistry]::GetVisibility("Collapsed")
        $this.PrivateDeltaBrush          = "#64748B"
        $this.PrivateDeltaSolidBrush     = [PSRPMThemeRegistry]::GetFrozenBrush("#64748B")
        $this.MemoryDeltaFormatted       = ""
        $this.WsDeltaBadgeText           = ""
        $this.WsDeltaBadgeVisibility     = "Collapsed"
        $this.WsDeltaBadgeVis            = [PSRPMThemeRegistry]::GetVisibility("Collapsed")
        $this.MemoryDeltaBrush           = "#64748B"
        $this.MemoryDeltaSolidBrush      = [PSRPMThemeRegistry]::GetFrozenBrush("#64748B")
        $this.HandlesDeltaFormatted      = ""
        $this.HandlesDeltaBrush          = "#64748B"
        $this.HandlesDeltaSolidBrush     = [PSRPMThemeRegistry]::GetFrozenBrush("#64748B")

        $this.ProcessHoverToolTip        = ""
        $this.CpuCellToolTip             = ""
        $this.PrivateCellToolTip         = ""
        $this.WsCellToolTip              = ""
        $this.HandlesCellToolTip         = ""
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [PSRPMThemeRegistry]::GetPropArgs($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] SetStaticMetadata([Object]$m, [bool]$isDark) {
        $this.PID          = [int]$m['id']
        $this.PIDDisplay   = $this.PID.ToString()
        $this.CreateTime   = [long]$m['ct']
        $this.Name         = [string]$m['n']
        $this.ParentPID    = [int]$m['p']
        $this.User         = [string]$m['u']
        $this.Architecture = [string]$m['arch']
        $this.Path         = [string]$m['path']
        $this.CommandLine  = [string]$m['cmd']
        $this.Description  = [string]$m['desc']
        $this.CompanyName  = [string]$m['comp']
        $this.FileVersion  = if ($null -ne $m['ver']) { [string]$m['ver'] } else { "" }
        $this.StartTime    = [string]$m['start']
        $this.SessionId    = [int]$m['sid']
        $this.BasePriority = [int]$m['prio']
        if ($m['cat']) { $this.Category = [string]$m['cat'] }
        $this.IsDarkTheme  = $isDark

        $this.UpdateCommandLineToolTip()
        $this.RefreshRowColors()
        $this.RefreshHoverToolTip()

        $this.OnPropertyChanged('PID')
        $this.OnPropertyChanged('PIDDisplay')
        $this.OnPropertyChanged('Name')
        $this.OnPropertyChanged('ParentPID')
        $this.OnPropertyChanged('User')
        $this.OnPropertyChanged('Architecture')
        $this.OnPropertyChanged('Path')
        $this.OnPropertyChanged('CommandLine')
        $this.OnPropertyChanged('CommandLineToolTip')
        $this.OnPropertyChanged('Description')
        $this.OnPropertyChanged('CompanyName')
        $this.OnPropertyChanged('FileVersion')
        $this.OnPropertyChanged('StartTime')
        $this.OnPropertyChanged('SessionId')
        $this.OnPropertyChanged('BasePriority')
        $this.OnPropertyChanged('Category')
        $this.OnPropertyChanged('ProcessHoverToolTip')
    }

    [void] UpdateCommandLineToolTip() {
        $p = if ([string]::IsNullOrWhiteSpace($this.Path) -or $this.Path -eq "N/A") { "n/a" } else { $this.Path }
        $c = if ([string]::IsNullOrWhiteSpace($this.CommandLine) -or $this.CommandLine -eq "N/A") { "n/a" } else { $this.CommandLine }
        if ($p -eq "n/a" -and $c -eq "n/a") {
            $this.CommandLineToolTip = "Command line: n/a"
        } elseif ($p -ne "n/a" -and $c -ne "n/a") {
            $this.CommandLineToolTip = "Path: $p`nCommand line: $c"
        } elseif ($c -ne "n/a") {
            $this.CommandLineToolTip = "Command line: $c"
        } else {
            $this.CommandLineToolTip = "Path: $p`nCommand line: n/a"
        }
    }

    static [string] FormatCpuDisplay([double]$cpuVal, [string]$statusStr) {
        if ($statusStr -eq "Suspended") { return "Suspended" }
        if ($cpuVal -le 0.0) { return "" }
        if ($cpuVal -lt 0.01) { return "< 0.01" }
        return $cpuVal.ToString("F2")
    }

    static [string] FormatCompactByteDelta([long]$delta) {
        $abs = [Math]::Abs($delta)
        $sign = if ($delta -gt 0L) { "+" } elseif ($delta -lt 0L) { "-" } else { "" }
        if ($abs -ge 1073741824L) { return "$sign$(([Math]::Round($abs / 1073741824.0, 1)).ToString('F1'))G" }
        if ($abs -ge 1048576L)    { return "$sign$(([Math]::Round($abs / 1048576.0, 1)).ToString('F1'))M" }
        if ($abs -ge 1024L)       { return "$sign$([Math]::Round($abs / 1024.0, 0))K" }
        return "$sign${abs}B"
    }

    static [string] FormatSignedKB([long]$delta) {
        $kb = [long][Math]::Round($delta / 1024.0, 0)
        if ($delta -gt 0L -and $kb -eq 0L) { $kb = 1L }
        elseif ($delta -lt 0L -and $kb -eq 0L) { $kb = -1L }
        if ($kb -gt 0L) { return "+$($kb.ToString('N0')) K" }
        return "$($kb.ToString('N0')) K"
    }

    hidden [string[]] ResolveDeltaBrushes() {
        $mode = if ([string]::IsNullOrWhiteSpace($this.ThemeMode)) { if ($this.IsDarkTheme) { "Dark" } else { "Light" } } else { $this.ThemeMode }
        $pal = [PSRPMThemeRegistry]::GetPalette($mode)
        $b = $pal.Brushes
        $g = if ($b['BrushDeltaGrowthFg']) { [string]$b['BrushDeltaGrowthFg'] } else { "#B91C1C" }
        $s = if ($b['BrushDeltaShrinkFg']) { [string]$b['BrushDeltaShrinkFg'] } else { "#15803D" }
        $n = if ($b['BrushDeltaNewFg'])    { [string]$b['BrushDeltaNewFg'] }    else { "#0369A1" }
        $m = if ($b['BrushTextMuted'])     { [string]$b['BrushTextMuted'] }     else { "#64748B" }
        return @($g, $s, $n, $m)
    }

    [void] RefreshCpuCellToolTip() {
        $curCpu = if ($this.CPUFormatted) { "$($this.CPUFormatted)%" } else { "0.00%" }
        $treeC  = if ($this.TreeCPUFormatted) { "$($this.TreeCPUFormatted)%" } else { "0.00%" }
        $pkCpu  = if ($this.PeakCPUFormatted) { "$($this.PeakCPUFormatted)%" } else { "0.00%" }
        $tip = "CPU: $curCpu | Tree CPU: $treeC | Session Peak: $pkCpu"
        if ($this.HasBaseline) {
            if ($this.SpawnedPostBaseline) {
                $tip += "`nBaseline: [NEW] Spawned post-baseline"
            } else {
                $tip += "`nBaseline Delta: $($this.CPUDeltaFormatted)"
            }
        }
        if ($this.CpuCellToolTip -ne $tip) {
            $this.CpuCellToolTip = $tip
            $this.OnPropertyChanged('CpuCellToolTip')
        }
    }

    [void] RefreshProcessHoverToolTipOnly() {
        $sb = [System.Text.StringBuilder]::new(384)
        [void]$sb.Append("$($this.Name) (PID $($this.PID), PPID $($this.ParentPID)) | $($this.Architecture) | Session $($this.SessionId)")
        [void]$sb.Append("`nUser: $($this.User) | Category: $($this.Category) | Status: $($this.Status)")
        if (-not [string]::IsNullOrWhiteSpace($this.HostedServices)) {
            $svcList = $this.HostedServices
            if ($svcList.Length -gt 240) { $svcList = $svcList.Substring(0, 237) + "..." }
            [void]$sb.Append("`nServices: $svcList")
        }
        $pStr = if ([string]::IsNullOrWhiteSpace($this.Path) -or $this.Path -eq "N/A") { "" } else { $this.Path }
        $cStr = if ([string]::IsNullOrWhiteSpace($this.CommandLine) -or $this.CommandLine -eq "N/A") { "" } else { $this.CommandLine }
        if ($pStr) {
            [void]$sb.Append("`nPath: $pStr")
        }
        if ($cStr -and $cStr -ne $pStr) {
            $cDisp = if ($cStr.Length -gt 420) { $cStr.Substring(0, 417) + "..." } else { $cStr }
            [void]$sb.Append("`nCmd: $cDisp")
        }
        $curCpu = if ($this.CPUFormatted) { "$($this.CPUFormatted)%" } else { "0.00%" }
        $pkCpu  = if ($this.PeakCPUFormatted) { "$($this.PeakCPUFormatted)%" } else { "0.00%" }
        [void]$sb.Append("`nCPU: $curCpu (Peak $pkCpu) | Private: $($this.PrivateBytesFormatted) (Peak $($this.PeakPrivateBytesFormatted))")
        [void]$sb.Append("`nWorking Set: $($this.MemoryFormatted) (Peak $($this.PeakMemoryFormatted)) | Handles: $($this.HandlesFormatted) (Peak $($this.PeakHandlesFormatted))")
        if ($this.HasBaseline) {
            if ($this.SpawnedPostBaseline) {
                [void]$sb.Append("`nBaseline: [NEW] Spawned after baseline")
            } else {
                [void]$sb.Append("`nBaseline: CPU $($this.CPUDeltaFormatted) | Private $($this.PrivateDeltaFormatted) | WS $($this.MemoryDeltaFormatted) | Handles $($this.HandlesDeltaFormatted)")
            }
        }
        $newTip = $sb.ToString()
        if ($this.ProcessHoverToolTip -ne $newTip) {
            $this.ProcessHoverToolTip = $newTip
            $this.OnPropertyChanged('ProcessHoverToolTip')
        }
    }

    [void] RefreshPrivateCellToolTip() {
        $privTip = "Private Bytes: $($this.PrivateBytesFormatted) | Session Peak: $($this.PeakPrivateBytesFormatted)"
        if ($this.HasBaseline) {
            $privTip += if ($this.SpawnedPostBaseline) { "`nBaseline: [NEW] Spawned post-baseline" } else { "`nBaseline Delta: $($this.PrivateDeltaFormatted)" }
        }
        if ($this.PrivateCellToolTip -ne $privTip) { $this.PrivateCellToolTip = $privTip; $this.OnPropertyChanged('PrivateCellToolTip') }
    }

    [void] RefreshWsCellToolTip() {
        $wsTip = "Working Set: $($this.MemoryFormatted) | Session Peak: $($this.PeakMemoryFormatted)"
        if ($this.HasBaseline) {
            $wsTip += if ($this.SpawnedPostBaseline) { "`nBaseline: [NEW] Spawned post-baseline" } else { "`nBaseline Delta: $($this.MemoryDeltaFormatted)" }
        }
        if ($this.WsCellToolTip -ne $wsTip) { $this.WsCellToolTip = $wsTip; $this.OnPropertyChanged('WsCellToolTip') }
    }

    [void] RefreshHandlesCellToolTip() {
        $hndTip = "Handles: $($this.HandlesFormatted) | Session Peak: $($this.PeakHandlesFormatted)"
        if ($this.HasBaseline) {
            $hndTip += if ($this.SpawnedPostBaseline) { "`nBaseline: [NEW] Spawned post-baseline" } else { "`nBaseline Delta: $($this.HandlesDeltaFormatted)" }
        }
        if ($this.HandlesCellToolTip -ne $hndTip) { $this.HandlesCellToolTip = $hndTip; $this.OnPropertyChanged('HandlesCellToolTip') }
    }

    [void] RefreshHoverToolTip() {
        $this.RefreshProcessHoverToolTipOnly()
        $this.RefreshPrivateCellToolTip()
        $this.RefreshWsCellToolTip()
        $this.RefreshHandlesCellToolTip()
        $this.RefreshCpuCellToolTip()
    }

    [void] UpdateBaselineDiffs() {
        $brushes = $this.ResolveDeltaBrushes()
        $growthHex  = $brushes[0]
        $shrinkHex  = $brushes[1]
        $newHex     = $brushes[2]
        $neutralHex = $brushes[3]

        if (-not $this.HasBaseline) {
            $this.CPUDelta          = 0.0
            $this.PrivateBytesDelta = 0L
            $this.MemoryDelta       = 0L
            $this.HandlesDelta      = 0
            $cFmt = ""; $cBr = $neutralHex
            $pFmt = ""; $pBadge = ""; $pVis = "Collapsed"; $pBr = $neutralHex
            $wFmt = ""; $wBadge = ""; $wVis = "Collapsed"; $wBr = $neutralHex
            $hFmt = ""; $hBr = $neutralHex
        } elseif ($this.SpawnedPostBaseline) {
            $this.CPUDelta          = [Math]::Round($this.CPU, 2)
            $this.PrivateBytesDelta = $this.PrivateBytes
            $this.MemoryDelta       = $this.MemoryBytes
            $this.HandlesDelta      = $this.Handles
            $cFmt = "[NEW]"; $cBr = $newHex
            $pFmt = "[NEW]"; $pBadge = "[NEW]"; $pVis = "Visible"; $pBr = $newHex
            $wFmt = "[NEW]"; $wBadge = "[NEW]"; $wVis = "Visible"; $wBr = $newHex
            $hFmt = "[NEW]"; $hBr = $newHex
        } else {
            $cd = [Math]::Round($this.CPU - $this.BaselineCPU, 2)
            if ([Math]::Abs($cd) -lt 0.005) { $cd = 0.0 }
            $pd = $this.PrivateBytes - $this.BaselinePrivateBytes
            $wd = $this.MemoryBytes  - $this.BaselineMemoryBytes
            $hd = $this.Handles      - $this.BaselineHandles
            $this.CPUDelta          = $cd
            $this.PrivateBytesDelta = $pd
            $this.MemoryDelta       = $wd
            $this.HandlesDelta      = $hd

            if ($cd -gt 0.0) {
                $cFmt = "+$($cd.ToString('F2'))%"
                $cBr  = $growthHex
            } elseif ($cd -lt 0.0) {
                $cFmt = "$($cd.ToString('F2'))%"
                $cBr  = $shrinkHex
            } else {
                $cFmt = "0.00%"
                $cBr  = $neutralHex
            }

            $pFmt = [ProcessItemViewModel]::FormatSignedKB($pd)
            $pSig = ([Math]::Abs($pd) -ge 65536L)
            $pBadge = if ($pSig) { [ProcessItemViewModel]::FormatCompactByteDelta($pd) } else { "" }
            $pVis   = if ($pSig) { "Visible" } else { "Collapsed" }
            $pBr    = if ($pd -gt 0L) { $growthHex } elseif ($pd -lt 0L) { $shrinkHex } else { $neutralHex }

            $wFmt = [ProcessItemViewModel]::FormatSignedKB($wd)
            $wSig = ([Math]::Abs($wd) -ge 65536L)
            $wBadge = if ($wSig) { [ProcessItemViewModel]::FormatCompactByteDelta($wd) } else { "" }
            $wVis   = if ($wSig) { "Visible" } else { "Collapsed" }
            $wBr    = if ($wd -gt 0L) { $growthHex } elseif ($wd -lt 0L) { $shrinkHex } else { $neutralHex }

            $hFmt = if ($hd -gt 0) { "+$($hd.ToString('N0'))" } else { $hd.ToString('N0') }
            $hBr  = if ($hd -gt 0) { $growthHex } elseif ($hd -lt 0) { $shrinkHex } else { $neutralHex }
        }

        if ($this.CPUDeltaFormatted -ne $cFmt)           { $this.CPUDeltaFormatted = $cFmt;           $this.OnPropertyChanged('CPUDeltaFormatted') }
        if ($this.CPUDeltaBrush -ne $cBr)                { $this.CPUDeltaBrush = $cBr;                $this.CPUDeltaSolidBrush = [PSRPMThemeRegistry]::GetFrozenBrush($cBr); $this.OnPropertyChanged('CPUDeltaBrush'); $this.OnPropertyChanged('CPUDeltaSolidBrush') }

        if ($this.PrivateDeltaFormatted -ne $pFmt)       { $this.PrivateDeltaFormatted = $pFmt;       $this.OnPropertyChanged('PrivateDeltaFormatted') }
        if ($this.PrivateDeltaBadgeText -ne $pBadge)     { $this.PrivateDeltaBadgeText = $pBadge;     $this.OnPropertyChanged('PrivateDeltaBadgeText') }
        if ($this.PrivateDeltaBadgeVisibility -ne $pVis) { $this.PrivateDeltaBadgeVisibility = $pVis; $this.PrivateDeltaBadgeVis = [PSRPMThemeRegistry]::GetVisibility($pVis); $this.OnPropertyChanged('PrivateDeltaBadgeVisibility'); $this.OnPropertyChanged('PrivateDeltaBadgeVis') }
        if ($this.PrivateDeltaBrush -ne $pBr)            { $this.PrivateDeltaBrush = $pBr;            $this.PrivateDeltaSolidBrush = [PSRPMThemeRegistry]::GetFrozenBrush($pBr); $this.OnPropertyChanged('PrivateDeltaBrush'); $this.OnPropertyChanged('PrivateDeltaSolidBrush') }

        if ($this.MemoryDeltaFormatted -ne $wFmt)        { $this.MemoryDeltaFormatted = $wFmt;        $this.OnPropertyChanged('MemoryDeltaFormatted') }
        if ($this.WsDeltaBadgeText -ne $wBadge)          { $this.WsDeltaBadgeText = $wBadge;          $this.OnPropertyChanged('WsDeltaBadgeText') }
        if ($this.WsDeltaBadgeVisibility -ne $wVis)      { $this.WsDeltaBadgeVisibility = $wVis;      $this.WsDeltaBadgeVis = [PSRPMThemeRegistry]::GetVisibility($wVis); $this.OnPropertyChanged('WsDeltaBadgeVisibility'); $this.OnPropertyChanged('WsDeltaBadgeVis') }
        if ($this.MemoryDeltaBrush -ne $wBr)             { $this.MemoryDeltaBrush = $wBr;             $this.MemoryDeltaSolidBrush = [PSRPMThemeRegistry]::GetFrozenBrush($wBr); $this.OnPropertyChanged('MemoryDeltaBrush'); $this.OnPropertyChanged('MemoryDeltaSolidBrush') }

        if ($this.HandlesDeltaFormatted -ne $hFmt)       { $this.HandlesDeltaFormatted = $hFmt;       $this.OnPropertyChanged('HandlesDeltaFormatted') }
        if ($this.HandlesDeltaBrush -ne $hBr)            { $this.HandlesDeltaBrush = $hBr;            $this.HandlesDeltaSolidBrush = [PSRPMThemeRegistry]::GetFrozenBrush($hBr); $this.OnPropertyChanged('HandlesDeltaBrush'); $this.OnPropertyChanged('HandlesDeltaSolidBrush') }

        $this.RefreshCpuCellToolTip()
    }

    [void] SetBaselineState([bool]$hasBase, [bool]$spawnedNew, [long]$basePriv, [long]$baseWs, [int]$baseHnd) {
        $fallbackCpu = if ($hasBase -and (-not $spawnedNew)) { $this.CPU } else { 0.0 }
        $this.SetBaselineState($hasBase, $spawnedNew, $basePriv, $baseWs, $baseHnd, $fallbackCpu)
    }

    [void] SetBaselineState([bool]$hasBase, [bool]$spawnedNew, [long]$basePriv, [long]$baseWs, [int]$baseHnd, [double]$baseCpu) {
        $this.HasBaseline          = $hasBase
        $this.SpawnedPostBaseline  = $spawnedNew
        $this.BaselineCPU          = $baseCpu
        $this.BaselinePrivateBytes = $basePriv
        $this.BaselineMemoryBytes  = $baseWs
        $this.BaselineHandles      = $baseHnd
        $this.OnPropertyChanged('HasBaseline')
        $this.OnPropertyChanged('SpawnedPostBaseline')
        $this.UpdateBaselineDiffs()
        $this.RefreshHoverToolTip()
    }

    [void] ClearBaseline() {
        $this.SetBaselineState($false, $false, 0L, 0L, 0, 0.0)
    }

    [void] AddSessionNetworkBytes([long]$rxBytes, [long]$txBytes) {
        if ($rxBytes -gt 0L) { $this.SessionNetRxBytes += $rxBytes }
        if ($txBytes -gt 0L) { $this.SessionNetTxBytes += $txBytes }
    }

    [void] UpdateDynamic([double]$cpu, [long]$wsBytes, [long]$privBytes, [int]$threads, [int]$handles, [int]$flags) {
        $prevHighCpu = ($this.CPU -ge 50.0)
        $newStatus = if ($flags -band 1) { "Suspended" } else { "Running" }
        $statusChanged = ($this.Status -ne $newStatus)
        if ($statusChanged) {
            $this.Status = $newStatus
            $this.OnPropertyChanged('Status')
        }

        $cpuFmtChanged  = $statusChanged
        $wsFmtChanged   = $false
        $privFmtChanged = $false
        $hndFmtChanged  = $false

        $cpuChanged = ($this.CPU -ne $cpu) -or $statusChanged
        if ($cpuChanged) {
            $this.CPU = $cpu
            $newCpuFmt = [ProcessItemViewModel]::FormatCpuDisplay($cpu, $this.Status)
            if ($this.CPUFormatted -ne $newCpuFmt) {
                $this.CPUFormatted = $newCpuFmt
                $this.OnPropertyChanged('CPUFormatted')
                $cpuFmtChanged = $true
            }
            if ($cpu -gt $this.PeakCPU) {
                $this.PeakCPU = $cpu
                $newPkCpuFmt = [ProcessItemViewModel]::FormatCpuDisplay($cpu, "Running")
                if ($this.PeakCPUFormatted -ne $newPkCpuFmt) {
                    $this.PeakCPUFormatted = $newPkCpuFmt
                    $this.OnPropertyChanged('PeakCPUFormatted')
                    $cpuFmtChanged = $true
                }
            }
        }

        $wsChanged = ($this.MemoryBytes -ne $wsBytes)
        if ($wsChanged) {
            $this.MemoryBytes = $wsBytes
            $wsKB = [Math]::Round($wsBytes / 1KB, 0)
            $newWsFmt = "$($wsKB.ToString('N0')) K"
            if ($this.MemoryFormatted -ne $newWsFmt) {
                $this.MemoryFormatted = $newWsFmt
                $this.OnPropertyChanged('MemoryFormatted')
                $wsFmtChanged = $true
            }
            if ($wsBytes -gt $this.PeakMemoryBytes) {
                $this.PeakMemoryBytes = $wsBytes
                if ($this.PeakMemoryFormatted -ne $newWsFmt) {
                    $this.PeakMemoryFormatted = $newWsFmt
                    $this.OnPropertyChanged('PeakMemoryFormatted')
                    $wsFmtChanged = $true
                }
            }
        }

        $privChanged = ($this.PrivateBytes -ne $privBytes)
        if ($privChanged) {
            $this.PrivateBytes = $privBytes
            $pbKB = [Math]::Round($privBytes / 1KB, 0)
            $newPbFmt = "$($pbKB.ToString('N0')) K"
            if ($this.PrivateBytesFormatted -ne $newPbFmt) {
                $this.PrivateBytesFormatted = $newPbFmt
                $this.OnPropertyChanged('PrivateBytesFormatted')
                $privFmtChanged = $true
            }
            if ($privBytes -gt $this.PeakPrivateBytes) {
                $this.PeakPrivateBytes = $privBytes
                if ($this.PeakPrivateBytesFormatted -ne $newPbFmt) {
                    $this.PeakPrivateBytesFormatted = $newPbFmt
                    $this.OnPropertyChanged('PeakPrivateBytesFormatted')
                    $privFmtChanged = $true
                }
            }
        }

        if ($this.Threads -ne $threads) {
            $this.Threads = $threads
            $this.OnPropertyChanged('Threads')
        }

        $hndChanged = ($this.Handles -ne $handles)
        if ($hndChanged) {
            $this.Handles = $handles
            $newHndFmt = $handles.ToString("N0")
            if ($this.HandlesFormatted -ne $newHndFmt) {
                $this.HandlesFormatted = $newHndFmt
                $this.OnPropertyChanged('HandlesFormatted')
                $hndFmtChanged = $true
            }
            if ($handles -gt $this.PeakHandles) {
                $this.PeakHandles = $handles
                if ($this.PeakHandlesFormatted -ne $newHndFmt) {
                    $this.PeakHandlesFormatted = $newHndFmt
                    $this.OnPropertyChanged('PeakHandlesFormatted')
                    $hndFmtChanged = $true
                }
            }
        }

        if ($this.HasBaseline -and ($cpuChanged -or $privChanged -or $wsChanged -or $hndChanged)) {
            $this.UpdateBaselineDiffs()
        }

        $needFullTip = [string]::IsNullOrEmpty($this.ProcessHoverToolTip)
        if ($needFullTip) {
            $this.RefreshHoverToolTip()
        } else {
            if ($cpuFmtChanged)  { $this.RefreshCpuCellToolTip() }
            if ($privFmtChanged) { $this.RefreshPrivateCellToolTip() }
            if ($wsFmtChanged)   { $this.RefreshWsCellToolTip() }
            if ($hndFmtChanged)  { $this.RefreshHandlesCellToolTip() }
            if ($cpuFmtChanged -or $privFmtChanged -or $wsFmtChanged -or $hndFmtChanged) {
                $this.RefreshProcessHoverToolTipOnly()
            }
        }

        if ($statusChanged -or ($prevHighCpu -ne ($cpu -ge 50.0))) {
            $this.RefreshRowColors()
        }
    }

    [void] UpdateTreeCpu([double]$treeCpu) {
        $clamped = [Math]::Max(0.0, [Math]::Min(100.0, [Math]::Round($treeCpu, 2)))
        $this.TreeCPU = $clamped
        $newTreeFmt = if ($clamped -lt 0.05) {
            ""
        } else {
            $clamped.ToString("F2")
        }
        if ($this.TreeCPUFormatted -ne $newTreeFmt) {
            $this.TreeCPUFormatted = $newTreeFmt
            $this.OnPropertyChanged('TreeCPUFormatted')
            $this.RefreshCpuCellToolTip()
        }
    }

    static [string] FormatNetRate([long]$bps) {
        if ($bps -le 0L) { return "" }
        $mbps = ($bps * 8.0) / 1000000.0
        if ($mbps -lt 0.01) { return "< 0.01 Mb/s" }
        return ($mbps.ToString("F2") + " Mb/s")
    }

    [void] RefreshNetToolTip() {
        $ownTot = $this.NetTotalBps
        $treeTot = $this.TreeNetTotalBps
        $tip = if ($ownTot -le 0L -and $treeTot -le 0L) {
            $null
        } else {
            $ownRx = if ($this.NetRxBps -gt 0L) { [ProcessItemViewModel]::FormatNetRate($this.NetRxBps) } else { "0.00 Mb/s" }
            $ownTx = if ($this.NetTxBps -gt 0L) { [ProcessItemViewModel]::FormatNetRate($this.NetTxBps) } else { "0.00 Mb/s" }
            $trRx  = if ($this.TreeNetRxBps -gt 0L) { [ProcessItemViewModel]::FormatNetRate($this.TreeNetRxBps) } else { "0.00 Mb/s" }
            $trTx  = if ($this.TreeNetTxBps -gt 0L) { [ProcessItemViewModel]::FormatNetRate($this.TreeNetTxBps) } else { "0.00 Mb/s" }
            "Own:  Recv $ownRx | Send $ownTx`nTree: Recv $trRx | Send $trTx"
        }
        if ($this.NetToolTip -ne $tip) {
            $this.NetToolTip = $tip
            $this.OnPropertyChanged('NetToolTip')
        }
    }

    [void] UpdateNetwork([long]$rx, [long]$tx) {
        $rxVal = if ($rx -gt 0L) { $rx } else { 0L }
        $txVal = if ($tx -gt 0L) { $tx } else { 0L }
        $totVal = $rxVal + $txVal
        $changed = $false

        if ($this.NetRxBps -ne $rxVal) {
            $this.NetRxBps = $rxVal
            $rxFmt = [ProcessItemViewModel]::FormatNetRate($rxVal)
            if ($this.NetRxFormatted -ne $rxFmt) {
                $this.NetRxFormatted = $rxFmt
                $this.OnPropertyChanged('NetRxFormatted')
            }
            $changed = $true
        }
        if ($this.NetTxBps -ne $txVal) {
            $this.NetTxBps = $txVal
            $txFmt = [ProcessItemViewModel]::FormatNetRate($txVal)
            if ($this.NetTxFormatted -ne $txFmt) {
                $this.NetTxFormatted = $txFmt
                $this.OnPropertyChanged('NetTxFormatted')
            }
            $changed = $true
        }
        if ($this.NetTotalBps -ne $totVal) {
            $this.NetTotalBps = $totVal
            $totFmt = [ProcessItemViewModel]::FormatNetRate($totVal)
            if ($this.NetTotalFormatted -ne $totFmt) {
                $this.NetTotalFormatted = $totFmt
                $this.OnPropertyChanged('NetTotalFormatted')
            }
            $changed = $true
        }
        if ($changed) { $this.RefreshNetToolTip() }
    }

    [void] UpdateTreeNetwork([long]$tRx, [long]$tTx) {
        $rxVal = if ($tRx -gt 0L) { $tRx } else { 0L }
        $txVal = if ($tTx -gt 0L) { $tTx } else { 0L }
        $totVal = $rxVal + $txVal
        $changed = $false

        if ($this.TreeNetRxBps -ne $rxVal) {
            $this.TreeNetRxBps = $rxVal
            $changed = $true
        }
        if ($this.TreeNetTxBps -ne $txVal) {
            $this.TreeNetTxBps = $txVal
            $changed = $true
        }
        if ($this.TreeNetTotalBps -ne $totVal) {
            $this.TreeNetTotalBps = $totVal
            $totFmt = [ProcessItemViewModel]::FormatNetRate($totVal)
            if ($this.TreeNetTotalFormatted -ne $totFmt) {
                $this.TreeNetTotalFormatted = $totFmt
                $this.OnPropertyChanged('TreeNetTotalFormatted')
            }
            $changed = $true
        }
        if ($changed) { $this.RefreshNetToolTip() }
    }

    [void] SetTheme([bool]$isDark) {
        $mode = if ($isDark) { "Dark" } else { "Light" }
        $this.SetThemeMode($mode)
    }

    [void] SetThemeMode([string]$mode) {
        $palette = [PSRPMThemeRegistry]::GetPalette($mode)
        $this.ThemeMode   = [string]$palette.Name
        $this.IsDarkTheme = [bool]$palette.IsDark
        $this.RefreshRowColors($palette)
        if ($this.HasBaseline) { $this.UpdateBaselineDiffs() }
    }

    [void] SetLifecycleState([int]$state) {
        if ($this.LifecycleState -ne $state) {
            $this.LifecycleState = $state
            $this.RefreshRowColors()
        }
    }

    [void] SetCategoryHighlights([bool]$enable) {
        if ($this.EnableCategoryHighlights -ne $enable) {
            $this.EnableCategoryHighlights = $enable
            $this.RefreshRowColors()
        }
    }

    [void] RefreshRowColors() {
        $mode = $this.ThemeMode
        if ([string]::IsNullOrWhiteSpace($mode)) {
            $mode = if ($this.IsDarkTheme) { "Dark" } else { "Light" }
        }
        $this.RefreshRowColors([PSRPMThemeRegistry]::GetPalette($mode))
    }

    [void] RefreshRowColors([hashtable]$palette) {
        $rows = $palette.Rows

        $tierKey = "Default"
        if ($this.LifecycleState -eq 1) {
            $tierKey = "New"
        } elseif ($this.LifecycleState -eq 2) {
            $tierKey = "Exiting"
        } elseif ($this.EnableCategoryHighlights) {
            if ($this.Status -eq "Suspended") {
                $tierKey = "Suspended"
            } elseif ($this.CPU -ge 50.0) {
                $tierKey = "HighCPU"
            } elseif ($this.Category -eq "Packaged") {
                $tierKey = "Packaged"
            } elseif ($this.Category -eq "Service") {
                $tierKey = "Service"
            } elseif ($this.Category -eq "Own") {
                $tierKey = "Own"
            }
        }

        $pair = $rows[$tierKey]
        if (-not $pair) { $pair = $rows["Default"] }
        $bg = $pair.Bg
        $fg = $pair.Fg

        if ($this.RowBackground -ne $bg) {
            $this.RowBackground = $bg
            $this.RowBackgroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush($bg)
            $this.OnPropertyChanged('RowBackground')
            $this.OnPropertyChanged('RowBackgroundBrush')
        }
        if ($this.RowForeground -ne $fg) {
            $this.RowForeground = $fg
            $this.RowForegroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush($fg)
            $this.OnPropertyChanged('RowForeground')
            $this.OnPropertyChanged('RowForegroundBrush')
        }
    }

    [void] SetIcon([Object]$icoBmp) {
        if ($null -ne $icoBmp) {
            $this.IconSource = $icoBmp
            $this.FallbackIconVisibility = "Collapsed"
            $this.FallbackIconVis = [PSRPMThemeRegistry]::GetVisibility("Collapsed")
            $this.OnPropertyChanged('IconSource')
            $this.OnPropertyChanged('FallbackIconVisibility')
            $this.OnPropertyChanged('FallbackIconVis')
        }
    }

    [void] UpdateExpanderGeometry() {
        $newExpGeom = if ($this.IsCompactRows) {
            if ($this.IsExpanded) {
                "M 0,2 L 4,2"
            } else {
                "M 0,2 L 4,2 M 2,0 L 2,4"
            }
        } else {
            if ($this.IsExpanded) {
                "M 0,2.5 L 5,2.5"
            } else {
                "M 0,2.5 L 5,2.5 M 2.5,0 L 2.5,5"
            }
        }
        if ($this.ExpanderGeometry -ne $newExpGeom) {
            $this.ExpanderGeometry = $newExpGeom
            $this.ExpanderPathGeometry = [PSRPMThemeRegistry]::GetFrozenGeometry($newExpGeom)
            $this.OnPropertyChanged('ExpanderGeometry')
            $this.OnPropertyChanged('ExpanderPathGeometry')
        }
    }

    [void] UpdateTreeState([int]$level, [bool]$isTreeMode, [bool]$hasChildren, [string]$guideGeom, [double]$opacity) {
        $this.UpdateTreeState($level, $isTreeMode, $hasChildren, $guideGeom, $opacity, $false)
    }

    [void] UpdateTreeState([int]$level, [bool]$isTreeMode, [bool]$hasChildren, [string]$guideGeom, [double]$opacity, [bool]$isCompactRows) {
        $step = if ($isCompactRows) { 12.0 } else { 16.0 }
        $newIndent = if ($isTreeMode) { [double](($level + 1) * $step) } else { $step }
        $newGuideVis = "Visible"
        $newToggleVis = if ($isTreeMode -and $hasChildren) { "Visible" } else { "Collapsed" }
        $newLeafVis = if ($isTreeMode -and -not $hasChildren) { "Visible" } else { "Collapsed" }
        $this.IsCompactRows = $isCompactRows
        $newExpGeom = if ($isCompactRows) {
            if ($this.IsExpanded) {
                "M 0,2 L 4,2" # Centered [-] minus bar inside 8x8 DPI-safe box
            } else {
                "M 0,2 L 4,2 M 2,0 L 2,4" # Centered [+] plus cross inside 8x8 DPI-safe box
            }
        } else {
            if ($this.IsExpanded) {
                "M 0,2.5 L 5,2.5" # Centered [-] minus bar inside 9x9 DPI-safe box
            } else {
                "M 0,2.5 L 5,2.5 M 2.5,0 L 2.5,5" # Centered [+] plus cross inside 9x9 DPI-safe box
            }
        }
        $newWeight = if ($hasChildren) { "SemiBold" } else { "Normal" }

        if ($this.HasChildren -ne $hasChildren) { $this.HasChildren = $hasChildren; $this.OnPropertyChanged('HasChildren') }
        if ($this.Level -ne $level) { $this.Level = $level; $this.OnPropertyChanged('Level') }
        if ($this.IsTreeMode -ne $isTreeMode) { $this.IsTreeMode = $isTreeMode; $this.OnPropertyChanged('IsTreeMode') }
        if ($this.IndentWidth -ne $newIndent) { $this.IndentWidth = $newIndent; $this.OnPropertyChanged('IndentWidth') }
        if ($this.TreeGuideVisibility -ne $newGuideVis) { $this.TreeGuideVisibility = $newGuideVis; $this.TreeGuideVis = [PSRPMThemeRegistry]::GetVisibility($newGuideVis); $this.OnPropertyChanged('TreeGuideVisibility'); $this.OnPropertyChanged('TreeGuideVis') }
        if ($this.TreeGuideGeometry -ne $guideGeom) { $this.TreeGuideGeometry = $guideGeom; $this.TreeGuidePathGeometry = [PSRPMThemeRegistry]::GetFrozenGeometry($guideGeom); $this.OnPropertyChanged('TreeGuideGeometry'); $this.OnPropertyChanged('TreeGuidePathGeometry') }
        if ($this.ToggleVisibility -ne $newToggleVis) { $this.ToggleVisibility = $newToggleVis; $this.ToggleVis = [PSRPMThemeRegistry]::GetVisibility($newToggleVis); $this.OnPropertyChanged('ToggleVisibility'); $this.OnPropertyChanged('ToggleVis') }
        if ($this.LeafVisibility -ne $newLeafVis) { $this.LeafVisibility = $newLeafVis; $this.LeafVis = [PSRPMThemeRegistry]::GetVisibility($newLeafVis); $this.OnPropertyChanged('LeafVisibility'); $this.OnPropertyChanged('LeafVis') }
        if ($this.ExpanderGeometry -ne $newExpGeom) { $this.ExpanderGeometry = $newExpGeom; $this.ExpanderPathGeometry = [PSRPMThemeRegistry]::GetFrozenGeometry($newExpGeom); $this.OnPropertyChanged('ExpanderGeometry'); $this.OnPropertyChanged('ExpanderPathGeometry') }
        if ($this.NameFontWeight -ne $newWeight) { $this.NameFontWeight = $newWeight; $this.NameWeight = [PSRPMThemeRegistry]::GetFontWeight($newWeight); $this.OnPropertyChanged('NameFontWeight'); $this.OnPropertyChanged('NameWeight') }
        if ($this.RowOpacity -ne $opacity) { $this.RowOpacity = $opacity; $this.OnPropertyChanged('RowOpacity') }
    }
}

class ServiceItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [string]$Name
    [string]$DisplayName
    [int]$PID
    [string]$PIDFormatted
    [string]$Status
    [string]$StartType
    [string]$User
    [string]$StatusBrush
    [string]$Dependencies
    [string]$DependentServices
    [string]$DependenciesFormatted
    [string]$DependentServicesFormatted
    [string]$Description
    [string]$BinaryPath
    [bool]$CanStart
    [bool]$CanStop
    [bool]$CanRestart

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    ServiceItemViewModel() {
        $this.Handlers                   = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.Status                     = "Stopped"
        $this.StatusBrush                = "#94A3B8"
        $this.StartType                  = "Manual"
        $this.User                       = "LocalSystem"
        $this.PIDFormatted               = ""
        $this.Dependencies               = ""
        $this.DependentServices          = ""
        $this.DependenciesFormatted      = "None"
        $this.DependentServicesFormatted = "None"
        $this.Description                = ""
        $this.BinaryPath                 = ""
        $this.CanStart                   = $true
        $this.CanStop                    = $false
        $this.CanRestart                 = $false
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [PSRPMThemeRegistry]::GetPropArgs($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] UpdateService([string]$name, [string]$disp, [int]$pidVal, [string]$status, [string]$startType, [string]$user) {
        $this.UpdateService($name, $disp, $pidVal, $status, $startType, $user, "", "", "", "")
    }

    [void] UpdateService([string]$name, [string]$disp, [int]$pidVal, [string]$status, [string]$startType, [string]$user, [string]$dep, [string]$rev, [string]$desc, [string]$bin) {
        if ($this.Name -ne $name)           { $this.Name = $name; $this.OnPropertyChanged('Name') }
        if ($this.DisplayName -ne $disp)    { $this.DisplayName = $disp; $this.OnPropertyChanged('DisplayName') }
        if ($this.PID -ne $pidVal) {
            $this.PID = $pidVal
            $this.PIDFormatted = if ($pidVal -gt 0) { [string]$pidVal } else { "" }
            $this.OnPropertyChanged('PID')
            $this.OnPropertyChanged('PIDFormatted')
        }
        if ($this.StartType -ne $startType) { $this.StartType = $startType; $this.OnPropertyChanged('StartType') }
        if ($this.User -ne $user)           { $this.User = $user; $this.OnPropertyChanged('User') }
        if ($this.Description -ne $desc)    { $this.Description = $desc; $this.OnPropertyChanged('Description') }
        if ($this.BinaryPath -ne $bin)      { $this.BinaryPath = $bin; $this.OnPropertyChanged('BinaryPath') }

        if ($this.Dependencies -ne $dep) {
            $this.Dependencies = $dep
            $this.DependenciesFormatted = if ([string]::IsNullOrWhiteSpace($dep)) { "None" } else { $dep }
            $this.OnPropertyChanged('Dependencies')
            $this.OnPropertyChanged('DependenciesFormatted')
        }

        if ($this.DependentServices -ne $rev) {
            $this.DependentServices = $rev
            $this.DependentServicesFormatted = if ([string]::IsNullOrWhiteSpace($rev)) { "None" } else { $rev }
            $this.OnPropertyChanged('DependentServices')
            $this.OnPropertyChanged('DependentServicesFormatted')
        }

        if ($this.Status -ne $status) {
            $this.Status = $status
            if ($status -eq "Running") {
                $this.StatusBrush = "#22C55E"
                $this.CanStart    = $false
                $this.CanStop     = $true
                $this.CanRestart  = $true
            } elseif ($status -eq "Paused") {
                $this.StatusBrush = "#F59E0B"
                $this.CanStart    = $true
                $this.CanStop     = $true
                $this.CanRestart  = $true
            } else {
                $this.StatusBrush = "#94A3B8"
                $this.CanStart    = $true
                $this.CanStop     = $false
                $this.CanRestart  = $false
            }
            $this.OnPropertyChanged('Status')
            $this.OnPropertyChanged('StatusBrush')
            $this.OnPropertyChanged('CanStart')
            $this.OnPropertyChanged('CanStop')
            $this.OnPropertyChanged('CanRestart')
        }
    }
}

class CpuCoreGraphViewModel : System.ComponentModel.INotifyPropertyChanged {
    [int]$CoreIndex
    [string]$CoreLabel
    [string]$UsageFormatted
    [string]$TotalPoints
    [string]$TotalFillPoints
    [string]$KernelPoints
    [string]$KernelFillPoints

    hidden [System.Collections.Generic.Queue[double]] $TotalHistory
    hidden [System.Collections.Generic.Queue[double]] $KernelHistory
    hidden [int] $RecordedSamples
    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    CpuCoreGraphViewModel([int]$idx) {
        $this.CoreIndex        = $idx
        $this.CoreLabel        = "CPU $idx"
        $this.UsageFormatted   = "0.0%"
        $this.TotalPoints      = ""
        $this.TotalFillPoints  = ""
        $this.KernelPoints     = ""
        $this.KernelFillPoints = ""
        $this.TotalHistory     = [System.Collections.Generic.Queue[double]]::new()
        $this.KernelHistory    = [System.Collections.Generic.Queue[double]]::new()
        $this.RecordedSamples  = 0
        $this.Handlers         = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()

        for ($i = 0; $i -lt 60; $i++) {
            $this.TotalHistory.Enqueue(0.0)
            $this.KernelHistory.Enqueue(0.0)
        }
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [PSRPMThemeRegistry]::GetPropArgs($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] EnqueueSample([double]$totPct, [double]$kernPct, [bool]$buildGeom) {
        if ($this.TotalHistory.Count -ge 60)  { [void]$this.TotalHistory.Dequeue() }
        if ($this.KernelHistory.Count -ge 60) { [void]$this.KernelHistory.Dequeue() }
        $this.TotalHistory.Enqueue($totPct)
        $this.KernelHistory.Enqueue($kernPct)
        if ($this.RecordedSamples -lt 60) { $this.RecordedSamples++ }
        $this.UsageFormatted = "$($totPct.ToString('F1'))% (K: $($kernPct.ToString('F1'))%)"

        if ($buildGeom) {
            $this.BuildCoreGeometry()
        }
    }

    [double[]] GetSamplePair([int]$idx) {
        $totArr  = $this.TotalHistory.ToArray()
        $kernArr = $this.KernelHistory.ToArray()
        if ($totArr.Count -eq 0) { return [double[]]@(0.0, 0.0) }
        $safeIdx = [Math]::Max(0, [Math]::Min($totArr.Count - 1, $idx))
        $kVal    = if ($safeIdx -lt $kernArr.Count) { [double]$kernArr[$safeIdx] } else { 0.0 }
        return [double[]]@([double]$totArr[$safeIdx], $kVal)
    }

    [void] BuildCoreGeometry() {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $totArr  = $this.TotalHistory.ToArray()
        $kernArr = $this.KernelHistory.ToArray()
        $total   = $totArr.Count
        $avail   = [Math]::Max(0, [Math]::Min($total, $this.RecordedSamples))
        $w = 180.0
        $h = 80.0

        if ($avail -le 0) {
            $this.TotalPoints      = ""
            $this.TotalFillPoints  = ""
            $this.KernelPoints     = ""
            $this.KernelFillPoints = ""
        } elseif ($avail -eq 1) {
            $tv = [Math]::Max(0.0, [Math]::Min(100.0, $totArr[$total - 1]))
            $kv = [Math]::Max(0.0, [Math]::Min($tv, $kernArr[$total - 1]))
            $ty = [Math]::Round(($h - 1.0) - (($tv / 100.0) * ($h - 4.0)), 1).ToString("F1", $inv)
            $ky = [Math]::Round(($h - 1.0) - (($kv / 100.0) * ($h - 4.0)), 1).ToString("F1", $inv)
            $this.TotalPoints      = "179.0,$ty 180.0,$ty"
            $this.TotalFillPoints  = "179.0,80.0 179.0,$ty 180.0,$ty 180.0,80.0"
            $this.KernelPoints     = "179.0,$ky 180.0,$ky"
            $this.KernelFillPoints = "179.0,80.0 179.0,$ky 180.0,$ky 180.0,80.0"
        } else {
            $maxIdx    = [Math]::Max(1, $total - 1)
            $firstIdx  = $total - $avail
            $xFirst    = [Math]::Round(($firstIdx / [double]$maxIdx) * $w, 1).ToString("F1", $inv)

            $tLine = [System.Text.StringBuilder]::new(320)
            $tFill = [System.Text.StringBuilder]::new(340)
            $kLine = [System.Text.StringBuilder]::new(320)
            $kFill = [System.Text.StringBuilder]::new(340)
            [void]$tFill.Append("$xFirst,80.0 ")
            [void]$kFill.Append("$xFirst,80.0 ")

            for ($i = $firstIdx; $i -lt $total; $i++) {
                $x  = [Math]::Round(($i / [double]$maxIdx) * $w, 1).ToString("F1", $inv)
                $tv = [Math]::Max(0.0, [Math]::Min(100.0, $totArr[$i]))
                $kv = [Math]::Max(0.0, [Math]::Min($tv, $kernArr[$i]))
                $ty = [Math]::Round(($h - 1.0) - (($tv / 100.0) * ($h - 4.0)), 1).ToString("F1", $inv)
                $ky = [Math]::Round(($h - 1.0) - (($kv / 100.0) * ($h - 4.0)), 1).ToString("F1", $inv)
                [void]$tLine.Append("$x,$ty ")
                [void]$tFill.Append("$x,$ty ")
                [void]$kLine.Append("$x,$ky ")
                [void]$kFill.Append("$x,$ky ")
            }
            [void]$tFill.Append("180.0,80.0")
            [void]$kFill.Append("180.0,80.0")

            $this.TotalPoints      = $tLine.ToString().Trim()
            $this.TotalFillPoints  = $tFill.ToString().Trim()
            $this.KernelPoints     = $kLine.ToString().Trim()
            $this.KernelFillPoints = $kFill.ToString().Trim()
        }

        $this.OnPropertyChanged('UsageFormatted')
        $this.OnPropertyChanged('TotalPoints')
        $this.OnPropertyChanged('TotalFillPoints')
        $this.OnPropertyChanged('KernelPoints')
        $this.OnPropertyChanged('KernelFillPoints')
    }
}

class SystemSummaryViewModel : System.ComponentModel.INotifyPropertyChanged {
    # Main Window Toolbar Sparkline Properties
    [double]$CpuUsage
    [double]$KernelCpuUsage
    [string]$CpuSummaryFormatted
    [long]$RamUsedMB
    [long]$RamTotalMB
    [string]$RamSummaryFormatted
    [string]$RamPctFormatted
    [long]$CommitUsedMB
    [long]$CommitLimitMB
    [string]$CommitSummaryFormatted
    [double]$CommitPct
    [double]$RamPct
    [int]$ProcessCount
    [int]$ThreadCount
    [int]$HandleCount
    [string]$CpuPoints
    [string]$CpuFillPoints
    [string]$CommitPoints
    [string]$CommitFillPoints
    [string]$RamPoints
    [string]$RamFillPoints
    [Object]$CpuPointCollection
    [Object]$CpuFillPointCollection
    [Object]$CommitPointCollection
    [Object]$CommitFillPointCollection
    [Object]$RamPointCollection
    [Object]$RamFillPointCollection

    # System Information Modal State & Per-Core Toggle
    [bool]$IsSysInfoOpen
    [bool]$IsWindowMinimized
    [bool]$ShowOneGraphPerCpu
    [string]$SingleCpuGraphVisibility
    [string]$PerCpuGridVisibility
    [System.Collections.ObjectModel.ObservableCollection[Object]]$CoreGraphs

    # Summary Tab: Static System & Storage Metadata
    [string]$HwMachine
    [string]$HwHost
    [string]$HwOS
    [string]$HwCpuName
    [string]$HwArch
    [string]$HwCoresText
    [string]$HwCoresCount
    [string]$HwSocketsCount
    [string]$HwLogicalCount
    [string]$HwMemoryGBText
    [string]$HwCommitLimitGBText
    [string]$HwBootDrive
    [string]$HwDriveType
    [string]$HwCapacityGBText
    [string]$HwAvailableGBText
    [string]$HwFileSystem
    [string]$HwReadOnly

    # System Information 360-Sample (6-Minute @ 1s) Chart Point Collections (360x120 Viewbox Canvas, 1:1 X mapping)
    [string]$SysCpuPoints
    [string]$SysCpuFillPoints
    [string]$SysKernelPoints
    [string]$SysKernelFillPoints
    [string]$SysCommitPoints
    [string]$SysCommitFillPoints
    [string]$SysRamPoints
    [string]$SysRamFillPoints
    [string]$SysIoPoints
    [string]$SysIoFillPoints
    [string]$SysIoWritePoints
    [string]$SysIoWriteFillPoints
    [string]$SysNetRxPoints
    [string]$SysNetRxFillPoints
    [string]$SysNetTxPoints
    [string]$SysNetTxFillPoints

    # Stepped Rolling Window (60 -> 120 -> 180 -> 360 samples) Axis Labels
    [int]$RecordedSampleCount
    [int]$PollingIntervalMs
    [string]$ChartTimeSpanLabel
    [string]$ChartAxisLeftLabel
    [string]$ChartAxisMidLabel

    # Vertical Bar Gauge Heights & Labels (44x120 Viewbox Canvas)
    [double]$CpuGaugeTotalHeight
    [double]$CpuGaugeTotalTop
    [double]$CpuGaugeKernelHeight
    [double]$CpuGaugeKernelTop
    [double]$CommitGaugeHeight
    [double]$CommitGaugeTop
    [double]$RamGaugeHeight
    [double]$RamGaugeTop
    [double]$IoGaugeHeight
    [double]$IoGaugeTop
    [double]$NetGaugeHeight
    [double]$NetGaugeTop
    [string]$CpuGaugeText
    [string]$CommitGaugeText
    [string]$RamGaugeText
    [string]$IoGaugeText
    [string]$NetGaugeText

    # CPU Tab Counters
    [string]$HandlesFormatted
    [string]$ThreadsFormatted
    [string]$ProcessesFormatted
    [string]$ContextSwitchDeltaFormatted
    [string]$InterruptDeltaFormatted
    [string]$SystemCallDeltaFormatted
    [string]$KernelCpuFormatted
    [string]$UserCpuFormatted

    # Memory Tab Counters (Exact KB matching Process Explorer)
    [string]$CommitCurrentK
    [string]$CommitLimitK
    [string]$CommitPeakK
    [string]$CommitPeakLimitPct
    [string]$CommitCurrentLimitPct
    [string]$PhysTotalK
    [string]$PhysAvailableK
    [string]$PhysInUseK
    [string]$SystemCacheK
    [string]$KernelPagedK
    [string]$KernelNonpagedK
    [string]$KernelTotalK
    [string]$PageFaultDeltaFormatted
    [string]$PageReadDeltaFormatted
    [string]$PageFileWriteDeltaFormatted
    [string]$MappedFileWriteDeltaFormatted

    # I/O Tab Counters
    [string]$IoTotalRateFormatted
    [string]$IoReadDeltaFormatted
    [string]$IoWriteDeltaFormatted
    [string]$IoOtherDeltaFormatted
    [string]$IoPeakRateFormatted
    [string]$IoSessionTotalFormatted

    # Extended Hardware Counters (Network & Disk Activity)
    [double]$NetRxKBs
    [double]$NetTxKBs
    [double]$DiskReadKBs
    [double]$DiskWriteKBs
    [double]$DiskQueueDepth
    [string]$NetThroughputFormatted
    [string]$DiskActivityFormatted
    [string]$NetRxRateFormatted
    [string]$NetTxRateFormatted
    [string]$NetTotalRateFormatted
    [string]$NetPeakRateFormatted
    [string]$NetMidRateFormatted
    [string]$NetSessionRxFormatted
    [string]$NetSessionTxFormatted
    [string]$NetSessionTotalFormatted
    [string]$NetEtwStatusSummary
    hidden [double]$SessionNetRxBytes
    hidden [double]$SessionNetTxBytes
    hidden [long]$LastNetAccumUtcTicks

    hidden [System.Collections.Generic.Queue[double]] $CpuHistory
    hidden [System.Collections.Generic.Queue[double]] $CommitHistory
    hidden [System.Collections.Generic.Queue[double]] $RamHistory

    # 360-Sample (6-Minute @ 1s) Circular Ring Buffers (23 KB Total Metric Memory)
    hidden [System.Collections.Generic.Queue[double]] $CpuHistory240
    hidden [System.Collections.Generic.Queue[double]] $KernelHistory240
    hidden [System.Collections.Generic.Queue[double]] $CommitHistory240
    hidden [System.Collections.Generic.Queue[double]] $RamHistory240
    hidden [System.Collections.Generic.Queue[double]] $IoTotalHistory240
    hidden [System.Collections.Generic.Queue[double]] $IoWriteHistory240
    hidden [System.Collections.Generic.Queue[double]] $NetRxHistory240
    hidden [System.Collections.Generic.Queue[double]] $NetTxHistory240

    # Parallel 360-Sample Hover Attribution Ring Buffers (~35 KB Total, Zero Per-Tick Alloc)
    hidden [System.Collections.Generic.Queue[long]]   $CoreSampleUtcTicks60
    hidden [System.Collections.Generic.Queue[long]]   $SampleUtcTicks240
    hidden [System.Collections.Generic.Queue[int]]    $TopCpuPid240
    hidden [System.Collections.Generic.Queue[string]] $TopCpuName240
    hidden [System.Collections.Generic.Queue[double]] $TopCpuVal240
    hidden [System.Collections.Generic.Queue[int]]    $TopCommitPid240
    hidden [System.Collections.Generic.Queue[string]] $TopCommitName240
    hidden [System.Collections.Generic.Queue[long]]   $TopCommitVal240
    hidden [System.Collections.Generic.Queue[int]]    $TopRamPid240
    hidden [System.Collections.Generic.Queue[string]] $TopRamName240
    hidden [System.Collections.Generic.Queue[long]]   $TopRamVal240
    hidden [System.Collections.Generic.Queue[int]]    $TopNetPid240
    hidden [System.Collections.Generic.Queue[string]] $TopNetName240
    hidden [System.Collections.Generic.Queue[long]]   $TopNetRx240
    hidden [System.Collections.Generic.Queue[long]]   $TopNetTx240
    hidden [System.Collections.Generic.Queue[int]]    $TopNetCap240
    hidden [long] $LastCommitLimitBytes
    hidden [long] $LastPhysTotalBytes

    # Backward-compatibility aliases
    hidden [System.Collections.Generic.Queue[double]] $CpuHistory120
    hidden [System.Collections.Generic.Queue[double]] $KernelHistory120
    hidden [System.Collections.Generic.Queue[double]] $CommitHistory120
    hidden [System.Collections.Generic.Queue[double]] $RamHistory120
    hidden [System.Collections.Generic.Queue[double]] $IoTotalHistory120
    hidden [System.Collections.Generic.Queue[double]] $IoWriteHistory120
    hidden [System.Collections.Generic.Queue[double]] $NetRxHistory120
    hidden [System.Collections.Generic.Queue[double]] $NetTxHistory120
    hidden [long] $SessionIoBytesTotal
    hidden [double] $PeakIoBytesDelta

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    SystemSummaryViewModel() {
        $this.Handlers               = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.CpuHistory             = [System.Collections.Generic.Queue[double]]::new()
        $this.CommitHistory          = [System.Collections.Generic.Queue[double]]::new()
        $this.RamHistory             = [System.Collections.Generic.Queue[double]]::new()
        $this.CpuHistory240          = [System.Collections.Generic.Queue[double]]::new(360)
        $this.KernelHistory240       = [System.Collections.Generic.Queue[double]]::new(360)
        $this.CommitHistory240       = [System.Collections.Generic.Queue[double]]::new(360)
        $this.RamHistory240          = [System.Collections.Generic.Queue[double]]::new(360)
        $this.IoTotalHistory240      = [System.Collections.Generic.Queue[double]]::new(360)
        $this.IoWriteHistory240      = [System.Collections.Generic.Queue[double]]::new(360)
        $this.NetRxHistory240        = [System.Collections.Generic.Queue[double]]::new(360)
        $this.NetTxHistory240        = [System.Collections.Generic.Queue[double]]::new(360)
        $this.CoreSampleUtcTicks60   = [System.Collections.Generic.Queue[long]]::new(60)
        $this.SampleUtcTicks240      = [System.Collections.Generic.Queue[long]]::new(360)
        $this.TopCpuPid240           = [System.Collections.Generic.Queue[int]]::new(360)
        $this.TopCpuName240          = [System.Collections.Generic.Queue[string]]::new(360)
        $this.TopCpuVal240           = [System.Collections.Generic.Queue[double]]::new(360)
        $this.TopCommitPid240        = [System.Collections.Generic.Queue[int]]::new(360)
        $this.TopCommitName240       = [System.Collections.Generic.Queue[string]]::new(360)
        $this.TopCommitVal240        = [System.Collections.Generic.Queue[long]]::new(360)
        $this.TopRamPid240           = [System.Collections.Generic.Queue[int]]::new(360)
        $this.TopRamName240          = [System.Collections.Generic.Queue[string]]::new(360)
        $this.TopRamVal240           = [System.Collections.Generic.Queue[long]]::new(360)
        $this.TopNetPid240           = [System.Collections.Generic.Queue[int]]::new(360)
        $this.TopNetName240          = [System.Collections.Generic.Queue[string]]::new(360)
        $this.TopNetRx240            = [System.Collections.Generic.Queue[long]]::new(360)
        $this.TopNetTx240            = [System.Collections.Generic.Queue[long]]::new(360)
        $this.TopNetCap240           = [System.Collections.Generic.Queue[int]]::new(360)
        $this.LastCommitLimitBytes   = 0L
        $this.LastPhysTotalBytes     = 0L

        # Backward-compatibility aliases
        $this.CpuHistory120          = $this.CpuHistory240
        $this.KernelHistory120       = $this.KernelHistory240
        $this.CommitHistory120       = $this.CommitHistory240
        $this.RamHistory120          = $this.RamHistory240
        $this.IoTotalHistory120      = $this.IoTotalHistory240
        $this.IoWriteHistory120      = $this.IoWriteHistory240
        $this.NetRxHistory120        = $this.NetRxHistory240
        $this.NetTxHistory120        = $this.NetTxHistory240
        $this.CoreGraphs             = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()

        $this.IsSysInfoOpen            = $false
        $this.IsWindowMinimized        = $false
        $this.ShowOneGraphPerCpu       = $false
        $this.SingleCpuGraphVisibility = "Visible"
        $this.PerCpuGridVisibility     = "Collapsed"
        $this.SessionIoBytesTotal      = 0L
        $this.PeakIoBytesDelta         = 1024.0

        $this.NetRxKBs                 = 0.0
        $this.NetTxKBs                 = 0.0
        $this.DiskReadKBs              = 0.0
        $this.DiskWriteKBs             = 0.0
        $this.DiskQueueDepth           = 0.0
        $this.NetThroughputFormatted   = "NET: 0.0 KB/s"
        $this.DiskActivityFormatted    = "I/O: 0.0 KB/s | 0 IOPS"

        $this.CpuUsage               = 0.0
        $this.KernelCpuUsage         = 0.0
        $this.CpuSummaryFormatted    = "0.0%"
        $this.RamUsedMB              = 0
        $this.RamTotalMB             = 0
        $this.RamSummaryFormatted    = "0 / 0 MB"
        $this.RamPctFormatted        = "0.0%"
        $this.CommitUsedMB           = 0
        $this.CommitLimitMB          = 0
        $this.CommitSummaryFormatted = "0.0%"
        $this.ProcessCount           = 0
        $this.ThreadCount            = 0
        $this.HandleCount            = 0
        $this.CpuPoints              = "0,25 92,25"
        $this.CpuFillPoints          = "0,26 0,25 92,25 92,26"
        $this.CommitPoints           = "0,25 98,25"
        $this.CommitFillPoints       = "0,26 0,25 98,25 98,26"
        $this.RamPoints              = "0,25 105,25"
        $this.RamFillPoints          = "0,26 0,25 105,25 105,26"
        $this.CpuPointCollection     = $null
        $this.CpuFillPointCollection = $null
        $this.CommitPointCollection  = $null
        $this.CommitFillPointCollection = $null
        $this.RamPointCollection     = $null
        $this.RamFillPointCollection = $null

        # Default System Information Values
        $cores = [Environment]::ProcessorCount
        $this.HwMachine           = "Windows Workstation"
        $this.HwHost              = [string]$env:COMPUTERNAME
        $this.HwOS                = [Environment]::OSVersion.VersionString
        $this.HwCpuName           = "Processor"
        $this.HwArch              = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
        $this.HwCoresText         = "$cores physical / $cores logical"
        $this.HwCoresCount        = "$cores"
        $this.HwSocketsCount      = "1"
        $this.HwLogicalCount      = "$cores"
        $this.HwMemoryGBText      = "0.0 GB"
        $this.HwCommitLimitGBText = "0.0 GB"
        $this.HwBootDrive         = "C:\"
        $this.HwDriveType         = "Fixed"
        $this.HwCapacityGBText    = "0.0 GB"
        $this.HwAvailableGBText   = "0.0 GB"
        $this.HwFileSystem        = "NTFS"
        $this.HwReadOnly          = "No"

        $this.SysCpuPoints         = ""
        $this.SysCpuFillPoints     = ""
        $this.SysKernelPoints      = ""
        $this.SysKernelFillPoints  = ""
        $this.SysCommitPoints      = ""
        $this.SysCommitFillPoints  = ""
        $this.SysRamPoints         = ""
        $this.SysRamFillPoints     = ""
        $this.SysIoPoints          = ""
        $this.SysIoFillPoints      = ""
        $this.SysIoWritePoints     = ""
        $this.SysIoWriteFillPoints = ""
        $this.SysNetRxPoints       = ""
        $this.SysNetRxFillPoints   = ""
        $this.SysNetTxPoints       = ""
        $this.SysNetTxFillPoints   = ""

        $this.RecordedSampleCount  = 0
        $this.PollingIntervalMs    = 1000
        $this.UpdateChartAxisLabels()

        $this.CpuGaugeTotalHeight  = 0.0
        $this.CpuGaugeTotalTop     = 120.0
        $this.CpuGaugeKernelHeight = 0.0
        $this.CpuGaugeKernelTop    = 120.0
        $this.CommitGaugeHeight    = 0.0
        $this.CommitGaugeTop       = 120.0
        $this.RamGaugeHeight       = 0.0
        $this.RamGaugeTop          = 120.0
        $this.IoGaugeHeight        = 0.0
        $this.IoGaugeTop           = 120.0
        $this.NetGaugeHeight       = 0.0
        $this.NetGaugeTop          = 120.0

        $this.CpuGaugeText    = "0.00%"
        $this.CommitGaugeText = "0.0 GB"
        $this.RamGaugeText    = "0.0 GB"
        $this.IoGaugeText     = "0 B"
        $this.NetGaugeText    = "0 B/s"

        $this.NetRxRateFormatted       = "0 B/s"
        $this.NetTxRateFormatted       = "0 B/s"
        $this.NetTotalRateFormatted    = "0 B/s"
        $this.NetPeakRateFormatted     = "64.0 KB/s"
        $this.NetMidRateFormatted      = "32.0 KB/s"
        $this.NetSessionRxFormatted    = "0 B"
        $this.NetSessionTxFormatted    = "0 B"
        $this.NetSessionTotalFormatted = "0 B"
        $this.NetEtwStatusSummary      = "Off (Ctrl+Shift+N)"
        $this.SessionNetRxBytes        = 0.0
        $this.SessionNetTxBytes        = 0.0
        $this.LastNetAccumUtcTicks     = 0L

        $this.HandlesFormatted            = "0"
        $this.ThreadsFormatted            = "0"
        $this.ProcessesFormatted          = "0"
        $this.ContextSwitchDeltaFormatted = "0"
        $this.InterruptDeltaFormatted     = "0"
        $this.SystemCallDeltaFormatted    = "0"
        $this.KernelCpuFormatted          = "0.00%"
        $this.UserCpuFormatted            = "0.00%"

        $this.CommitCurrentK                = "0"
        $this.CommitLimitK                  = "0"
        $this.CommitPeakK                   = "0"
        $this.CommitPeakLimitPct            = "0.00%"
        $this.CommitCurrentLimitPct         = "0.00%"
        $this.PhysTotalK                    = "0"
        $this.PhysAvailableK                = "0"
        $this.PhysInUseK                    = "0"
        $this.SystemCacheK                  = "0"
        $this.KernelPagedK                  = "0"
        $this.KernelNonpagedK               = "0"
        $this.KernelTotalK                  = "0"
        $this.PageFaultDeltaFormatted       = "0"
        $this.PageReadDeltaFormatted        = "0"
        $this.PageFileWriteDeltaFormatted   = "0"
        $this.MappedFileWriteDeltaFormatted = "0"

        $this.IoTotalRateFormatted    = "0 B/s"
        $this.IoReadDeltaFormatted    = "0 B"
        $this.IoWriteDeltaFormatted   = "0 B"
        $this.IoOtherDeltaFormatted   = "0 B"
        $this.IoPeakRateFormatted     = "0 B/s"
        $this.IoSessionTotalFormatted = "0.0 MB"

        for ($i = 0; $i -lt 30; $i++) {
            $this.CpuHistory.Enqueue(0.0)
            $this.CommitHistory.Enqueue(0.0)
            $this.RamHistory.Enqueue(0.0)
        }
        for ($i = 0; $i -lt 60; $i++) {
            $this.CoreSampleUtcTicks60.Enqueue(0L)
        }
        for ($i = 0; $i -lt 360; $i++) {
            $this.CpuHistory240.Enqueue(0.0)
            $this.KernelHistory240.Enqueue(0.0)
            $this.CommitHistory240.Enqueue(0.0)
            $this.RamHistory240.Enqueue(0.0)
            $this.IoTotalHistory240.Enqueue(0.0)
            $this.IoWriteHistory240.Enqueue(0.0)
            $this.NetRxHistory240.Enqueue(0.0)
            $this.NetTxHistory240.Enqueue(0.0)
            $this.SampleUtcTicks240.Enqueue(0L)
            $this.TopCpuPid240.Enqueue(0)
            $this.TopCpuName240.Enqueue("")
            $this.TopCpuVal240.Enqueue(0.0)
            $this.TopCommitPid240.Enqueue(0)
            $this.TopCommitName240.Enqueue("")
            $this.TopCommitVal240.Enqueue(0L)
            $this.TopRamPid240.Enqueue(0)
            $this.TopRamName240.Enqueue("")
            $this.TopRamVal240.Enqueue(0L)
            $this.TopNetPid240.Enqueue(0)
            $this.TopNetName240.Enqueue("")
            $this.TopNetRx240.Enqueue(0L)
            $this.TopNetTx240.Enqueue(0L)
            $this.TopNetCap240.Enqueue(0)
        }
    }

    [double[]] GetCpuHistory360()     { return $this.CpuHistory240.ToArray() }
    [double[]] GetKernelHistory360()  { return $this.KernelHistory240.ToArray() }
    [double[]] GetCommitHistory360()  { return $this.CommitHistory240.ToArray() }
    [double[]] GetRamHistory360()     { return $this.RamHistory240.ToArray() }
    [double[]] GetIoTotalHistory360() { return $this.IoTotalHistory240.ToArray() }
    [double[]] GetIoWriteHistory360() { return $this.IoWriteHistory240.ToArray() }
    [double[]] GetNetRxHistory360()   { return $this.NetRxHistory240.ToArray() }
    [double[]] GetNetTxHistory360()   { return $this.NetTxHistory240.ToArray() }

    [double[]] GetCpuHistory240()     { return $this.CpuHistory240.ToArray() }
    [double[]] GetKernelHistory240()  { return $this.KernelHistory240.ToArray() }
    [double[]] GetCommitHistory240()  { return $this.CommitHistory240.ToArray() }
    [double[]] GetRamHistory240()     { return $this.RamHistory240.ToArray() }
    [double[]] GetIoTotalHistory240() { return $this.IoTotalHistory240.ToArray() }
    [double[]] GetIoWriteHistory240() { return $this.IoWriteHistory240.ToArray() }
    [double[]] GetNetRxHistory240()   { return $this.NetRxHistory240.ToArray() }
    [double[]] GetNetTxHistory240()   { return $this.NetTxHistory240.ToArray() }

    # Backward-compatibility aliases
    [double[]] GetCpuHistory120()     { return $this.CpuHistory240.ToArray() }
    [double[]] GetKernelHistory120()  { return $this.KernelHistory240.ToArray() }
    [double[]] GetCommitHistory120()  { return $this.CommitHistory240.ToArray() }
    [double[]] GetRamHistory120()     { return $this.RamHistory240.ToArray() }
    [double[]] GetIoTotalHistory120() { return $this.IoTotalHistory240.ToArray() }
    [double[]] GetIoWriteHistory120() { return $this.IoWriteHistory240.ToArray() }
    [double[]] GetNetRxHistory120()   { return $this.NetRxHistory240.ToArray() }
    [double[]] GetNetTxHistory120()   { return $this.NetTxHistory240.ToArray() }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [PSRPMThemeRegistry]::GetPropArgs($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] SetPerCpuMode([bool]$perCpu) {
        $this.ShowOneGraphPerCpu       = $perCpu
        $this.SingleCpuGraphVisibility = if ($perCpu) { "Collapsed" } else { "Visible" }
        $this.PerCpuGridVisibility     = if ($perCpu) { "Visible" }   else { "Collapsed" }
        if ($perCpu) {
            foreach ($cg in $this.CoreGraphs) {
                $cg.BuildCoreGeometry()
            }
        }
        $this.OnPropertyChanged('ShowOneGraphPerCpu')
        $this.OnPropertyChanged('SingleCpuGraphVisibility')
        $this.OnPropertyChanged('PerCpuGridVisibility')
    }

    static [string] FormatBytesStatic([double]$bytes) {
        if ($bytes -le 0.0) { return "0" }
        if ($bytes -ge 1073741824.0) { return "$(([Math]::Round($bytes / 1073741824.0, 2)).ToString('F2')) GB" }
        if ($bytes -ge 1048576.0)    { return "$(([Math]::Round($bytes / 1048576.0, 1)).ToString('F1')) MB" }
        if ($bytes -ge 1024.0)       { return "$(([Math]::Round($bytes / 1024.0, 1)).ToString('F1')) KB" }
        return "$([Math]::Round($bytes, 0)) B"
    }

    hidden [string] FormatBytesCompact([double]$bytes) {
        return [SystemSummaryViewModel]::FormatBytesStatic($bytes)
    }

    hidden [Object[]] BuildSparklineNative([double[]]$arr, [double]$width, [double]$height) {
        $cnt = $arr.Count
        $lineSb = [System.Text.StringBuilder]::new(256)
        $fillSb = [System.Text.StringBuilder]::new(280)
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $wStr = $width.ToString("F1", $inv)
        $hStr = $height.ToString("F1", $inv)
        [void]$fillSb.Append("0,$hStr ")

        $linePts = $null
        $fillPts = $null
        $hasWpf = $false
        try {
            $pcType = [System.Type]::GetType("System.Windows.Media.PointCollection, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35", $false)
            if ($null -ne $pcType) {
                $linePts = [Activator]::CreateInstance($pcType, [Object[]]@([int]$cnt))
                $fillPts = [Activator]::CreateInstance($pcType, [Object[]]@([int]($cnt + 2)))
                $fillPts.Add([System.Windows.Point]::new(0.0, $height))
                $hasWpf = $true
            }
        } catch { $hasWpf = $false }

        $maxIdx = [Math]::Max(1, $cnt - 1)
        for ($i = 0; $i -lt $cnt; $i++) {
            $x = [Math]::Round(($i / [double]$maxIdx) * $width, 1)
            $val = [Math]::Max(0.0, [Math]::Min(100.0, $arr[$i]))
            $y = [Math]::Round(($height - 1.0) - (($val / 100.0) * ($height - 13.0)), 1)
            if ($hasWpf) {
                $wp = [System.Windows.Point]::new($x, $y)
                $linePts.Add($wp)
                $fillPts.Add($wp)
            }
            $pt = "$($x.ToString('F1', $inv)),$($y.ToString('F1', $inv)) "
            [void]$lineSb.Append($pt)
            [void]$fillSb.Append($pt)
        }
        [void]$fillSb.Append("$wStr,$hStr")
        if ($hasWpf) {
            $fillPts.Add([System.Windows.Point]::new($width, $height))
            if ($linePts.CanFreeze) { $linePts.Freeze() }
            if ($fillPts.CanFreeze) { $fillPts.Freeze() }
        }
        return @($lineSb.ToString().Trim(), $fillSb.ToString().Trim(), $linePts, $fillPts)
    }

    hidden [string[]] BuildSparkline([double[]]$arr, [double]$width, [double]$height) {
        $res = $this.BuildSparklineNative($arr, $width, $height)
        return @([string]$res[0], [string]$res[1])
    }

    [int] GetActiveChartWindowCount() {
        $n = $this.RecordedSampleCount
        if ($n -le 60)  { return 60 }
        if ($n -le 120) { return 120 }
        if ($n -le 180) { return 180 }
        return 360
    }

    hidden [string] FormatAxisDuration([double]$sec) {
        $s = [int][Math]::Round($sec)
        if ($s -le 0) { return "0s" }
        if ($s -lt 60) { return "${s}s" }
        $m = [int][Math]::Floor($s / 60)
        $r = $s % 60
        if ($r -eq 0) { return "${m}m" }
        return ("{0}:{1:D2}" -f $m, $r)
    }

    hidden [void] UpdateChartAxisLabels() {
        $bucket   = $this.GetActiveChartWindowCount()
        $stepSec  = [Math]::Max(0.25, $this.PollingIntervalMs / 1000.0)
        $totalSec = $bucket * $stepSec
        $divSec   = $totalSec / 6.0
        $this.ChartAxisLeftLabel = "-" + $this.FormatAxisDuration($totalSec)
        $this.ChartAxisMidLabel  = "-" + $this.FormatAxisDuration($totalSec / 2.0)
        $this.ChartTimeSpanLabel = "Window: $($this.FormatAxisDuration($totalSec)) ($($this.FormatAxisDuration($divSec))/div)"
    }

    [void] SetPollingIntervalMs([int]$ms) {
        $safeMs = [Math]::Max(250, $ms)
        if ($this.PollingIntervalMs -ne $safeMs) {
            $this.PollingIntervalMs = $safeMs
            $this.UpdateChartAxisLabels()
            $this.OnPropertyChanged('ChartTimeSpanLabel')
            $this.OnPropertyChanged('ChartAxisLeftLabel')
            $this.OnPropertyChanged('ChartAxisMidLabel')
        }
    }

    hidden [string[]] BuildLargeChart([double[]]$arr, [double]$maxScale, [double]$width, [double]$height) {
        return $this.BuildLargeChart($arr, $maxScale, $width, $height, $arr.Count, $arr.Count)
    }

    hidden [string[]] BuildLargeChart([double[]]$arr, [double]$maxScale, [double]$width, [double]$height, [int]$bucketSize, [int]$recordedCount) {
        $total = if ($arr) { $arr.Count } else { 0 }
        if ($total -le 0) { return @("", "") }
        $winSize = [Math]::Max(2, [Math]::Min($total, $bucketSize))
        $avail   = [Math]::Max(0, [Math]::Min($winSize, $recordedCount))
        if ($avail -le 0) { return @("", "") }

        $inv     = [System.Globalization.CultureInfo]::InvariantCulture
        $wStr    = $width.ToString("F1", $inv)
        $hStr    = $height.ToString("F1", $inv)
        $safeMax = if ($maxScale -gt 0.0) { $maxScale } else { 100.0 }

        if ($avail -eq 1) {
            $val  = [Math]::Max(0.0, [Math]::Min($safeMax, $arr[$total - 1]))
            $y    = [Math]::Round(($height - 1.0) - (($val / $safeMax) * ($height - 4.0)), 1)
            $yStr = $y.ToString("F1", $inv)
            $xPrev = [Math]::Max(0.0, $width - 1.0).ToString("F1", $inv)
            return @("$xPrev,$yStr $wStr,$yStr", "$xPrev,$hStr $xPrev,$yStr $wStr,$yStr $wStr,$hStr")
        }

        $lineSb        = [System.Text.StringBuilder]::new(2800)
        $fillSb        = [System.Text.StringBuilder]::new(3072)
        $winStartInArr = $total - $winSize
        $firstSlot     = $winSize - $avail
        $maxIdx        = [Math]::Max(1, $winSize - 1)
        $xFirst        = [Math]::Round(($firstSlot / [double]$maxIdx) * $width, 1)
        [void]$fillSb.Append("$($xFirst.ToString('F1', $inv)),$hStr ")

        for ($s = $firstSlot; $s -lt $winSize; $s++) {
            $arrIdx = $winStartInArr + $s
            $x      = [Math]::Round(($s / [double]$maxIdx) * $width, 1)
            $val    = [Math]::Max(0.0, [Math]::Min($safeMax, $arr[$arrIdx]))
            $y      = [Math]::Round(($height - 1.0) - (($val / $safeMax) * ($height - 4.0)), 1)
            $pt     = "$($x.ToString('F1', $inv)),$($y.ToString('F1', $inv)) "
            [void]$lineSb.Append($pt)
            [void]$fillSb.Append($pt)
        }
        [void]$fillSb.Append("$wStr,$hStr")
        return @($lineSb.ToString().Trim(), $fillSb.ToString().Trim())
    }

    [void] UpdateHardwareInfo([Object]$hw) {
        if (-not $hw) { return }
        if ($hw['machine']) { $this.HwMachine      = [string]$hw['machine'] }
        if ($hw['host'])    { $this.HwHost         = [string]$hw['host'] }
        if ($hw['os'])      { $this.HwOS           = [string]$hw['os'] }
        if ($hw['cpu'])     { $this.HwCpuName      = [string]$hw['cpu'] }
        if ($hw['arch'])    { $this.HwArch         = [string]$hw['arch'] }
        $cCount = if ($hw['cores'])   { [int]$hw['cores'] }   else { [Environment]::ProcessorCount }
        $lCount = if ($hw['logical']) { [int]$hw['logical'] } else { $cCount }
        $sCount = if ($hw['sockets']) { [int]$hw['sockets'] } else { 1 }
        $this.HwCoresText    = "$cCount physical / $lCount logical"
        $this.HwCoresCount   = "$cCount"
        $this.HwLogicalCount = "$lCount"
        $this.HwSocketsCount = "$sCount"
        if ($hw['boot'])    { $this.HwBootDrive      = [string]$hw['boot'] }
        if ($hw['fs'])      { $this.HwFileSystem     = [string]$hw['fs'] }
        if ($hw['type'])    { $this.HwDriveType      = [string]$hw['type'] }
        if ($hw['ro'])      { $this.HwReadOnly       = [string]$hw['ro'] }
        if ($null -ne $hw['capGB'])   { $this.HwCapacityGBText  = "$([double]$hw['capGB']) GB" }
        if ($null -ne $hw['availGB']) { $this.HwAvailableGBText = "$([double]$hw['availGB']) GB" }

        $this.OnPropertyChanged('HwMachine')
        $this.OnPropertyChanged('HwHost')
        $this.OnPropertyChanged('HwOS')
        $this.OnPropertyChanged('HwCpuName')
        $this.OnPropertyChanged('HwArch')
        $this.OnPropertyChanged('HwCoresText')
        $this.OnPropertyChanged('HwCoresCount')
        $this.OnPropertyChanged('HwLogicalCount')
        $this.OnPropertyChanged('HwSocketsCount')
        $this.OnPropertyChanged('HwBootDrive')
        $this.OnPropertyChanged('HwFileSystem')
        $this.OnPropertyChanged('HwDriveType')
        $this.OnPropertyChanged('HwReadOnly')
        $this.OnPropertyChanged('HwCapacityGBText')
        $this.OnPropertyChanged('HwAvailableGBText')
    }

    [void] UpdateSummary([double]$cpu, [long]$ramUsed, [long]$ramTotal, [int]$procs, [int]$threads, [int]$handles, [long]$commitUsed, [long]$commitLimit) {
        $cpuChanged = ($this.CpuUsage -ne $cpu)
        $this.CpuUsage = $cpu
        $newCpuFmt = "$($cpu.ToString('F1'))%"
        $cpuFmtChanged = ($this.CpuSummaryFormatted -ne $newCpuFmt)
        $this.CpuSummaryFormatted = $newCpuFmt

        $ramUsedChanged  = ($this.RamUsedMB -ne $ramUsed)
        $ramTotalChanged = ($this.RamTotalMB -ne $ramTotal)
        $this.RamUsedMB  = $ramUsed
        $this.RamTotalMB = $ramTotal
        $this.RamPct     = if ($ramTotal -gt 0) { [Math]::Round(($ramUsed / [double]$ramTotal) * 100.0, 1) } else { 0.0 }
        $newRamPctFmt    = "$($this.RamPct.ToString('F1'))%"
        $ramPctChanged   = ($this.RamPctFormatted -ne $newRamPctFmt)
        $this.RamPctFormatted = $newRamPctFmt
        $newRamSumFmt    = "Physical Memory: $($this.RamUsedMB.ToString('N0')) / $($this.RamTotalMB.ToString('N0')) MB ($($this.RamPctFormatted))"
        $ramSumChanged   = ($this.RamSummaryFormatted -ne $newRamSumFmt)
        $this.RamSummaryFormatted = $newRamSumFmt

        $this.CommitUsedMB  = $commitUsed
        $this.CommitLimitMB = $commitLimit
        $this.CommitPct     = if ($commitLimit -gt 0) { [Math]::Round(($commitUsed / [double]$commitLimit) * 100.0, 1) } else { 0.0 }
        $newComFmt          = "$($this.CommitPct.ToString('F1'))%"
        $comFmtChanged      = ($this.CommitSummaryFormatted -ne $newComFmt)
        $this.CommitSummaryFormatted = $newComFmt

        $procChanged   = ($this.ProcessCount -ne $procs)
        $threadChanged = ($this.ThreadCount -ne $threads)
        $handleChanged = ($this.HandleCount -ne $handles)
        $this.ProcessCount       = $procs
        $this.ThreadCount        = $threads
        $this.HandleCount        = $handles
        if ($procChanged)   { $this.ProcessesFormatted = $procs.ToString("N0") }
        if ($threadChanged) { $this.ThreadsFormatted   = $threads.ToString("N0") }
        if ($handleChanged) { $this.HandlesFormatted   = $handles.ToString("N0") }

        $this.HwMemoryGBText      = "$([Math]::Round($ramTotal / 1024.0, 1).ToString('F1')) GB"
        $this.HwCommitLimitGBText = "$([Math]::Round($commitLimit / 1024.0, 1).ToString('F1')) GB"
        if ($ramTotal -gt 0L)    { $this.LastPhysTotalBytes   = $ramTotal * 1048576L }
        if ($commitLimit -gt 0L) { $this.LastCommitLimitBytes = $commitLimit * 1048576L }

        if ($this.CpuHistory.Count -ge 30)    { [void]$this.CpuHistory.Dequeue() }
        if ($this.CommitHistory.Count -ge 30) { [void]$this.CommitHistory.Dequeue() }
        if ($this.RamHistory.Count -ge 30)    { [void]$this.RamHistory.Dequeue() }

        $this.CpuHistory.Enqueue($cpu)
        $this.CommitHistory.Enqueue($this.CommitPct)
        $this.RamHistory.Enqueue($this.RamPct)

        if ($cpuChanged)      { $this.OnPropertyChanged('CpuUsage') }
        if ($cpuFmtChanged)   { $this.OnPropertyChanged('CpuSummaryFormatted') }
        if ($ramUsedChanged)  { $this.OnPropertyChanged('RamUsedMB') }
        if ($ramTotalChanged) { $this.OnPropertyChanged('RamTotalMB') }
        if ($ramPctChanged)   { $this.OnPropertyChanged('RamPctFormatted') }
        if ($ramSumChanged)   { $this.OnPropertyChanged('RamSummaryFormatted') }
        if ($comFmtChanged)   { $this.OnPropertyChanged('CommitSummaryFormatted') }
        if ($procChanged)     { $this.OnPropertyChanged('ProcessCount') }
        if ($threadChanged)   { $this.OnPropertyChanged('ThreadCount') }
        if ($handleChanged)   { $this.OnPropertyChanged('HandleCount') }

        if (-not $this.IsWindowMinimized) {
            $this.RefreshSparklines()
        }
    }

    [void] RefreshSparklines() {
        $cpuSpark = $this.BuildSparklineNative($this.CpuHistory.ToArray(), 86.0, 26.0)
        $this.CpuPoints              = [string]$cpuSpark[0]
        $this.CpuFillPoints          = [string]$cpuSpark[1]
        $this.CpuPointCollection     = $cpuSpark[2]
        $this.CpuFillPointCollection = $cpuSpark[3]

        $comSpark = $this.BuildSparklineNative($this.CommitHistory.ToArray(), 90.0, 26.0)
        $this.CommitPoints              = [string]$comSpark[0]
        $this.CommitFillPoints          = [string]$comSpark[1]
        $this.CommitPointCollection     = $comSpark[2]
        $this.CommitFillPointCollection = $comSpark[3]

        $ramSpark = $this.BuildSparklineNative($this.RamHistory.ToArray(), 96.0, 26.0)
        $this.RamPoints              = [string]$ramSpark[0]
        $this.RamFillPoints          = [string]$ramSpark[1]
        $this.RamPointCollection     = $ramSpark[2]
        $this.RamFillPointCollection = $ramSpark[3]

        $this.OnPropertyChanged('CpuPoints')
        $this.OnPropertyChanged('CpuFillPoints')
        $this.OnPropertyChanged('CpuPointCollection')
        $this.OnPropertyChanged('CpuFillPointCollection')
        $this.OnPropertyChanged('CommitPoints')
        $this.OnPropertyChanged('CommitFillPoints')
        $this.OnPropertyChanged('CommitPointCollection')
        $this.OnPropertyChanged('CommitFillPointCollection')
        $this.OnPropertyChanged('RamPoints')
        $this.OnPropertyChanged('RamFillPoints')
        $this.OnPropertyChanged('RamPointCollection')
        $this.OnPropertyChanged('RamFillPointCollection')
    }

    [void] UpdateExtendedTelemetry([Object]$sysArr, [Object]$coresArr) {
        $this.UpdateExtendedTelemetry($sysArr, $coresArr, 1.0)
    }

    [void] UpdateExtendedTelemetry([Object]$sysArr, [Object]$coresArr, [double]$elapsedSec) {
        if (-not $sysArr -or $sysArr.Count -lt 27) { return }

        $safeElapsed = if ($elapsedSec -gt 0.0) { [Math]::Max(0.05, $elapsedSec) } else { 1.0 }
        $cpuTot      = [double]$sysArr[0]
        $kernCpu     = [double]$sysArr[8]
        $userCpu     = [Math]::Max(0.0, [Math]::Round($cpuTot - $kernCpu, 2))
        $commitCurKB = [long]$sysArr[9]
        $commitLimKB = [long]$sysArr[10]
        $commitPkKB  = [long]$sysArr[11]
        $physTotKB   = [long]$sysArr[12]
        $physAvailKB = [long]$sysArr[13]
        $sysCacheKB  = [long]$sysArr[14]
        $kernPagedKB = [long]$sysArr[15]
        $kernNonpKB  = [long]$sysArr[16]
        $pfDelta     = [long]$sysArr[17]
        $prDelta     = [long]$sysArr[18]
        $pfwDelta    = [long]$sysArr[19]
        $mfwDelta    = [long]$sysArr[20]
        $csDelta     = [long]$sysArr[21]
        $intrDelta   = [long]$sysArr[22]
        $scDelta     = [long]$sysArr[23]
        $ioReadD     = [long]$sysArr[24]
        $ioWriteD    = [long]$sysArr[25]
        $ioOtherD    = [long]$sysArr[26]

        $this.KernelCpuUsage = $kernCpu
        $physUsedKB  = [Math]::Max(0L, $physTotKB - $physAvailKB)
        $kernTotalKB = $kernPagedKB + $kernNonpKB
        $ioTotalD    = $ioReadD + $ioWriteD + $ioOtherD
        $ioWriteAllD = $ioWriteD + $ioOtherD
        $ioTotalRate = [double]$ioTotalD / $safeElapsed
        $ioWriteRate = [double]$ioWriteAllD / $safeElapsed
        $this.SessionIoBytesTotal += $ioTotalD

        # 1. Enqueue 360-Sample Circular Ring Buffers (6 Minutes @ 1s)
        if ($this.CpuHistory240.Count -ge 360)     { [void]$this.CpuHistory240.Dequeue() }
        if ($this.KernelHistory240.Count -ge 360)  { [void]$this.KernelHistory240.Dequeue() }
        if ($this.CommitHistory240.Count -ge 360)  { [void]$this.CommitHistory240.Dequeue() }
        if ($this.RamHistory240.Count -ge 360)     { [void]$this.RamHistory240.Dequeue() }
        if ($this.IoTotalHistory240.Count -ge 360) { [void]$this.IoTotalHistory240.Dequeue() }
        if ($this.IoWriteHistory240.Count -ge 360) { [void]$this.IoWriteHistory240.Dequeue() }

        $comPctExact = if ($commitLimKB -gt 0L) { ($commitCurKB / [double]$commitLimKB) * 100.0 } else { $this.CommitPct }
        $ramPctExact = if ($physTotKB -gt 0L)   { ($physUsedKB  / [double]$physTotKB)   * 100.0 } else { $this.RamPct }

        $this.CpuHistory240.Enqueue($cpuTot)
        $this.KernelHistory240.Enqueue($kernCpu)
        $this.CommitHistory240.Enqueue($comPctExact)
        $this.RamHistory240.Enqueue($ramPctExact)
        $this.IoTotalHistory240.Enqueue($ioTotalRate)
        $this.IoWriteHistory240.Enqueue($ioWriteRate)
        if ($this.RecordedSampleCount -lt 360) { $this.RecordedSampleCount++ }

        # 2. Enqueue Per-Core CPU Ring Buffers
        if ($coresArr -and $coresArr.Count -gt 0) {
            if ($this.CoreSampleUtcTicks60.Count -ge 60) { [void]$this.CoreSampleUtcTicks60.Dequeue() }
            $this.CoreSampleUtcTicks60.Enqueue([DateTime]::UtcNow.Ticks)
            while ($this.CoreGraphs.Count -lt $coresArr.Count) {
                $newCoreVm = [CpuCoreGraphViewModel]::new($this.CoreGraphs.Count)
                $this.CoreGraphs.Add($newCoreVm)
            }
            $buildCoresNow = ($this.IsSysInfoOpen -and $this.ShowOneGraphPerCpu)
            for ($c = 0; $c -lt $coresArr.Count; $c++) {
                $pair = $coresArr[$c]
                if ($pair -and $pair.Count -ge 2) {
                    $this.CoreGraphs[$c].EnqueueSample([double]$pair[0], [double]$pair[1], $buildCoresNow)
                }
            }
        }
        if ($commitLimKB -gt 0L) { $this.LastCommitLimitBytes = $commitLimKB * 1024L }
        if ($physTotKB -gt 0L)   { $this.LastPhysTotalBytes   = $physTotKB * 1024L }

        # 3. Update Formatted Counter Strings & Gauges
        $this.CpuGaugeText    = "$($cpuTot.ToString('F2'))%"
        $this.CommitGaugeText = "$([Math]::Round($commitCurKB / 1048576.0, 1).ToString('F1')) GB"
        $this.RamGaugeText    = "$([Math]::Round($physUsedKB / 1048576.0, 1).ToString('F1')) GB"
        $this.IoGaugeText     = $this.FormatRateCompact($ioTotalRate)

        $this.ContextSwitchDeltaFormatted = $csDelta.ToString("N0")
        $this.InterruptDeltaFormatted     = $intrDelta.ToString("N0")
        $this.SystemCallDeltaFormatted    = $scDelta.ToString("N0")
        $this.KernelCpuFormatted          = "$($kernCpu.ToString('F2'))%"
        $this.UserCpuFormatted            = "$($userCpu.ToString('F2'))%"

        $this.CommitCurrentK        = $commitCurKB.ToString("N0")
        $this.CommitLimitK          = $commitLimKB.ToString("N0")
        $this.CommitPeakK           = $commitPkKB.ToString("N0")
        $pkPct = if ($commitLimKB -gt 0L) { ($commitPkKB / [double]$commitLimKB) * 100.0 } else { 0.0 }
        $this.CommitPeakLimitPct    = "$($pkPct.ToString('F2'))%"
        $this.CommitCurrentLimitPct = "$($comPctExact.ToString('F2'))%"

        $this.PhysTotalK      = $physTotKB.ToString("N0")
        $this.PhysAvailableK  = $physAvailKB.ToString("N0")
        $this.PhysInUseK      = $physUsedKB.ToString("N0")
        $this.SystemCacheK    = $sysCacheKB.ToString("N0")
        $this.KernelPagedK    = $kernPagedKB.ToString("N0")
        $this.KernelNonpagedK = $kernNonpKB.ToString("N0")
        $this.KernelTotalK    = $kernTotalKB.ToString("N0")

        $this.PageFaultDeltaFormatted       = $pfDelta.ToString("N0")
        $this.PageReadDeltaFormatted        = $prDelta.ToString("N0")
        $this.PageFileWriteDeltaFormatted   = $pfwDelta.ToString("N0")
        $this.MappedFileWriteDeltaFormatted = $mfwDelta.ToString("N0")

        $this.IoTotalRateFormatted    = $this.FormatRateCompact($ioTotalRate)
        $this.IoReadDeltaFormatted    = $this.FormatBytesCompact([double]$ioReadD)
        $this.IoWriteDeltaFormatted   = $this.FormatBytesCompact([double]$ioWriteD)
        $this.IoOtherDeltaFormatted   = $this.FormatBytesCompact([double]$ioOtherD)
        $this.IoSessionTotalFormatted = $this.FormatBytesCompact([double]$this.SessionIoBytesTotal)

        # 3. Extended Hardware Counters (Network Throughput & Storage Activity)
        if ($sysArr.Count -gt 27) {
            $this.NetRxKBs       = [double]$sysArr[27]
            $this.NetTxKBs       = if ($sysArr.Count -gt 28) { [double]$sysArr[28] } else { 0.0 }
            $this.DiskReadKBs    = if ($sysArr.Count -gt 29) { [double]$sysArr[29] } else { 0.0 }
            $this.DiskWriteKBs   = if ($sysArr.Count -gt 30) { [double]$sysArr[30] } else { 0.0 }
            $this.DiskQueueDepth = if ($sysArr.Count -gt 31) { [double]$sysArr[31] } else { 0.0 }

            $rxStr = if ($this.NetRxKBs -ge 1024.0) { "$(([Math]::Round($this.NetRxKBs / 1024.0, 1)).ToString('F1')) MB/s" } else { "$(([Math]::Round($this.NetRxKBs, 1)).ToString('F1')) KB/s" }
            $txStr = if ($this.NetTxKBs -ge 1024.0) { "$(([Math]::Round($this.NetTxKBs / 1024.0, 1)).ToString('F1')) MB/s" } else { "$(([Math]::Round($this.NetTxKBs, 1)).ToString('F1')) KB/s" }
            $this.NetThroughputFormatted = "NET: v $rxStr ^ $txStr"

            $dTotKB = $this.DiskReadKBs + $this.DiskWriteKBs
            $dStr = if ($dTotKB -ge 1024.0) { "$(([Math]::Round($dTotKB / 1024.0, 1)).ToString('F1')) MB/s" } else { "$(([Math]::Round($dTotKB, 1)).ToString('F1')) KB/s" }
            $this.DiskActivityFormatted = "I/O: $dStr | $([int]$this.DiskQueueDepth) IOPS"

            if ($this.NetRxHistory240.Count -ge 360) { [void]$this.NetRxHistory240.Dequeue() }
            if ($this.NetTxHistory240.Count -ge 360) { [void]$this.NetTxHistory240.Dequeue() }
            $this.NetRxHistory240.Enqueue($this.NetRxKBs)
            $this.NetTxHistory240.Enqueue($this.NetTxKBs)

            $nowTicks = [DateTime]::UtcNow.Ticks
            if ($this.LastNetAccumUtcTicks -gt 0L) {
                $dtSec = ($nowTicks - $this.LastNetAccumUtcTicks) / 10000000.0
                if ($dtSec -ge 0.05 -and $dtSec -le 15.0) {
                    $this.SessionNetRxBytes += ($this.NetRxKBs * 1024.0 * $dtSec)
                    $this.SessionNetTxBytes += ($this.NetTxKBs * 1024.0 * $dtSec)
                }
            }
            $this.LastNetAccumUtcTicks = $nowTicks

            $this.OnPropertyChanged('NetRxKBs')
            $this.OnPropertyChanged('NetTxKBs')
            $this.OnPropertyChanged('DiskReadKBs')
            $this.OnPropertyChanged('DiskWriteKBs')
            $this.OnPropertyChanged('DiskQueueDepth')
            $this.OnPropertyChanged('NetThroughputFormatted')
            $this.OnPropertyChanged('DiskActivityFormatted')
        }

        # Only build the 240-point UI strings and notify System Info properties when the System Info window is open!
        if ($this.IsSysInfoOpen) {
            $this.RefreshSysInfoGraphs()
        }
    }

    [void] ResetNetAccumTimestamp() {
        $this.LastNetAccumUtcTicks = 0L
    }

    [void] UpdateNetEtwStatus([int]$cap, [int]$evRate) {
        $txt = switch ($cap) {
            1 { "Active ($evRate ev/s)" }
            2 { "Paused ($evRate ev/s breaker)" }
            3 { "Tier 1 (Admin needed)" }
            4 { "Unavailable on host" }
            default { "Off (Ctrl+Shift+N)" }
        }
        if ($this.NetEtwStatusSummary -ne $txt) {
            $this.NetEtwStatusSummary = $txt
            $this.OnPropertyChanged('NetEtwStatusSummary')
        }
    }

    [void] RefreshSysInfoGraphs() {
        $cpuArr   = $this.CpuHistory240.ToArray()
        $kernArr  = $this.KernelHistory240.ToArray()
        $comArr   = $this.CommitHistory240.ToArray()
        $ramArr   = $this.RamHistory240.ToArray()
        $ioTotArr = $this.IoTotalHistory240.ToArray()
        $ioWrtArr = $this.IoWriteHistory240.ToArray()
        $netRxArr = $this.NetRxHistory240.ToArray()
        $netTxArr = $this.NetTxHistory240.ToArray()

        $winSize = $this.GetActiveChartWindowCount()
        $recCnt  = $this.RecordedSampleCount
        $this.UpdateChartAxisLabels()

        $visIoCount  = [Math]::Min($winSize, $recCnt)
        $visIoStart  = [Math]::Max(0, $ioTotArr.Count - $visIoCount)
        $maxIo = 65536.0 # 64 KB/s minimum full-scale so idle noise stays flat at bottom
        for ($i = $visIoStart; $i -lt $ioTotArr.Count; $i++) {
            if ($ioTotArr[$i] -gt $maxIo) { $maxIo = $ioTotArr[$i] }
        }
        $this.PeakIoBytesDelta = $maxIo
        $this.IoPeakRateFormatted = "$($this.FormatBytesCompact($maxIo))/s"

        $visNetCount = [Math]::Min($winSize, $recCnt)
        $visNetStart = [Math]::Max(0, $netRxArr.Count - $visNetCount)
        $maxNetKB = 64.0 # 64 KB/s minimum full-scale matching I/O ceiling
        for ($i = $visNetStart; $i -lt $netRxArr.Count; $i++) {
            if ($netRxArr[$i] -gt $maxNetKB) { $maxNetKB = $netRxArr[$i] }
        }
        for ($i = $visNetStart; $i -lt $netTxArr.Count; $i++) {
            if ($netTxArr[$i] -gt $maxNetKB) { $maxNetKB = $netTxArr[$i] }
        }
        $this.NetPeakRateFormatted = "$($this.FormatBytesCompact($maxNetKB * 1024.0))/s"
        $this.NetMidRateFormatted  = "$($this.FormatBytesCompact($maxNetKB * 512.0))/s"

        $cTot   = $this.BuildLargeChart($cpuArr,   100.0,     360.0, 120.0, $winSize, $recCnt)
        $cKern  = $this.BuildLargeChart($kernArr,  100.0,     360.0, 120.0, $winSize, $recCnt)
        $cCom   = $this.BuildLargeChart($comArr,   100.0,     360.0, 120.0, $winSize, $recCnt)
        $cRam   = $this.BuildLargeChart($ramArr,   100.0,     360.0, 120.0, $winSize, $recCnt)
        $cIoT   = $this.BuildLargeChart($ioTotArr, $maxIo,    360.0, 120.0, $winSize, $recCnt)
        $cIoW   = $this.BuildLargeChart($ioWrtArr, $maxIo,    360.0, 120.0, $winSize, $recCnt)
        $cNetRx = $this.BuildLargeChart($netRxArr, $maxNetKB, 360.0, 120.0, $winSize, $recCnt)
        $cNetTx = $this.BuildLargeChart($netTxArr, $maxNetKB, 360.0, 120.0, $winSize, $recCnt)

        $this.SysCpuPoints         = $cTot[0]
        $this.SysCpuFillPoints     = $cTot[1]
        $this.SysKernelPoints      = $cKern[0]
        $this.SysKernelFillPoints  = $cKern[1]
        $this.SysCommitPoints      = $cCom[0]
        $this.SysCommitFillPoints  = $cCom[1]
        $this.SysRamPoints         = $cRam[0]
        $this.SysRamFillPoints     = $cRam[1]
        $this.SysIoPoints          = $cIoT[0]
        $this.SysIoFillPoints      = $cIoT[1]
        $this.SysIoWritePoints     = $cIoW[0]
        $this.SysIoWriteFillPoints = $cIoW[1]
        $this.SysNetRxPoints       = $cNetRx[0]
        $this.SysNetRxFillPoints   = $cNetRx[1]
        $this.SysNetTxPoints       = $cNetTx[0]
        $this.SysNetTxFillPoints   = $cNetTx[1]

        # Vertical Gauge Bar Heights (0..120 px)
        $lastCpu   = if ($cpuArr.Count -gt 0)   { $cpuArr[$cpuArr.Count - 1] }     else { 0.0 }
        $lastKern  = if ($kernArr.Count -gt 0)  { $kernArr[$kernArr.Count - 1] }   else { 0.0 }
        $lastCom   = if ($comArr.Count -gt 0)   { $comArr[$comArr.Count - 1] }     else { 0.0 }
        $lastRam   = if ($ramArr.Count -gt 0)   { $ramArr[$ramArr.Count - 1] }     else { 0.0 }
        $lastIo    = if ($ioTotArr.Count -gt 0) { $ioTotArr[$ioTotArr.Count - 1] } else { 0.0 }
        $lastRxKB  = if ($netRxArr.Count -gt 0) { $netRxArr[$netRxArr.Count - 1] } else { 0.0 }
        $lastTxKB  = if ($netTxArr.Count -gt 0) { $netTxArr[$netTxArr.Count - 1] } else { 0.0 }
        $lastTotKB = $lastRxKB + $lastTxKB

        $this.CpuGaugeTotalHeight  = [Math]::Round(([Math]::Min(100.0, $lastCpu) / 100.0) * 120.0, 1)
        $this.CpuGaugeTotalTop     = [Math]::Round(120.0 - $this.CpuGaugeTotalHeight, 1)
        $this.CpuGaugeKernelHeight = [Math]::Round(([Math]::Min($lastCpu, $lastKern) / 100.0) * 120.0, 1)
        $this.CpuGaugeKernelTop    = [Math]::Round(120.0 - $this.CpuGaugeKernelHeight, 1)

        $this.CommitGaugeHeight    = [Math]::Round(([Math]::Min(100.0, $lastCom) / 100.0) * 120.0, 1)
        $this.CommitGaugeTop       = [Math]::Round(120.0 - $this.CommitGaugeHeight, 1)

        $this.RamGaugeHeight       = [Math]::Round(([Math]::Min(100.0, $lastRam) / 100.0) * 120.0, 1)
        $this.RamGaugeTop          = [Math]::Round(120.0 - $this.RamGaugeHeight, 1)

        $this.IoGaugeHeight        = [Math]::Round(([Math]::Min($maxIo, $lastIo) / $maxIo) * 120.0, 1)
        $this.IoGaugeTop           = [Math]::Round(120.0 - $this.IoGaugeHeight, 1)

        $this.NetGaugeHeight       = [Math]::Round(([Math]::Min($maxNetKB, $lastTotKB) / $maxNetKB) * 120.0, 1)
        $this.NetGaugeTop          = [Math]::Round(120.0 - $this.NetGaugeHeight, 1)

        $rxRateFmt  = if ($lastRxKB -gt 0.0)  { "$($this.FormatBytesCompact($lastRxKB * 1024.0))/s" }  else { "0 B/s" }
        $txRateFmt  = if ($lastTxKB -gt 0.0)  { "$($this.FormatBytesCompact($lastTxKB * 1024.0))/s" }  else { "0 B/s" }
        $totRateFmt = if ($lastTotKB -gt 0.0) { "$($this.FormatBytesCompact($lastTotKB * 1024.0))/s" } else { "0 B/s" }
        $this.NetGaugeText             = $totRateFmt
        $this.NetRxRateFormatted       = $rxRateFmt
        $this.NetTxRateFormatted       = $txRateFmt
        $this.NetTotalRateFormatted    = $totRateFmt
        $this.NetSessionRxFormatted    = if ($this.SessionNetRxBytes -gt 0.0) { $this.FormatBytesCompact($this.SessionNetRxBytes) } else { "0 B" }
        $this.NetSessionTxFormatted    = if ($this.SessionNetTxBytes -gt 0.0) { $this.FormatBytesCompact($this.SessionNetTxBytes) } else { "0 B" }
        $sessTot                       = $this.SessionNetRxBytes + $this.SessionNetTxBytes
        $this.NetSessionTotalFormatted = if ($sessTot -gt 0.0) { $this.FormatBytesCompact($sessTot) } else { "0 B" }

        foreach ($prop in @(
            'SysCpuPoints', 'SysCpuFillPoints', 'SysKernelPoints', 'SysKernelFillPoints',
            'SysCommitPoints', 'SysCommitFillPoints', 'SysRamPoints', 'SysRamFillPoints',
            'SysIoPoints', 'SysIoFillPoints', 'SysIoWritePoints', 'SysIoWriteFillPoints',
            'SysNetRxPoints', 'SysNetRxFillPoints', 'SysNetTxPoints', 'SysNetTxFillPoints',
            'CpuGaugeTotalHeight', 'CpuGaugeTotalTop', 'CpuGaugeKernelHeight', 'CpuGaugeKernelTop',
            'CommitGaugeHeight', 'CommitGaugeTop', 'RamGaugeHeight', 'RamGaugeTop',
            'IoGaugeHeight', 'IoGaugeTop', 'NetGaugeHeight', 'NetGaugeTop',
            'CpuGaugeText', 'CommitGaugeText', 'RamGaugeText', 'IoGaugeText', 'NetGaugeText',
            'HandlesFormatted', 'ThreadsFormatted', 'ProcessesFormatted',
            'ContextSwitchDeltaFormatted', 'InterruptDeltaFormatted', 'SystemCallDeltaFormatted',
            'KernelCpuFormatted', 'UserCpuFormatted',
            'CommitCurrentK', 'CommitLimitK', 'CommitPeakK', 'CommitPeakLimitPct', 'CommitCurrentLimitPct',
            'PhysTotalK', 'PhysAvailableK', 'PhysInUseK', 'SystemCacheK',
            'KernelPagedK', 'KernelNonpagedK', 'KernelTotalK',
            'PageFaultDeltaFormatted', 'PageReadDeltaFormatted', 'PageFileWriteDeltaFormatted', 'MappedFileWriteDeltaFormatted',
            'IoTotalRateFormatted', 'IoReadDeltaFormatted', 'IoWriteDeltaFormatted', 'IoOtherDeltaFormatted',
            'IoPeakRateFormatted', 'IoSessionTotalFormatted',
            'NetRxRateFormatted', 'NetTxRateFormatted', 'NetTotalRateFormatted',
            'NetPeakRateFormatted', 'NetMidRateFormatted',
            'NetSessionRxFormatted', 'NetSessionTxFormatted', 'NetSessionTotalFormatted', 'NetEtwStatusSummary',
            'HwMemoryGBText', 'HwCommitLimitGBText',
            'ChartTimeSpanLabel', 'ChartAxisLeftLabel', 'ChartAxisMidLabel'
        )) {
            $this.OnPropertyChanged($prop)
        }
    }

    hidden [string] FormatRateCompact([double]$bytesPerSec) {
        if ($bytesPerSec -le 0.0) { return "0 B/s" }
        return "$($this.FormatBytesCompact($bytesPerSec))/s"
    }

    hidden [string] FormatHoverTimestamp([long]$utcTicks) {
        $dtLocal = [DateTime]::new($utcTicks, [DateTimeKind]::Utc).ToLocalTime()
        $ageSec  = [int][Math]::Max(0.0, [Math]::Round(([DateTime]::UtcNow.Ticks - $utcTicks) / 10000000.0))
        $ageText = if ($ageSec -lt 1) {
            "now"
        } elseif ($ageSec -lt 60) {
            "-${ageSec}s"
        } else {
            $mins = [int][Math]::Floor($ageSec / 60)
            $rem  = $ageSec % 60
            "-${mins}m ${rem}s"
        }
        return "$($dtLocal.ToString('HH:mm:ss')) ($ageText)"
    }

    [void] RecordTopProcessSample(
        [long]$utcTicks,
        [int]$topCpuPid,    [string]$topCpuName,    [double]$topCpuVal,
        [int]$topCommitPid, [string]$topCommitName, [long]$topCommitBytes,
        [int]$topRamPid,    [string]$topRamName,    [long]$topRamBytes,
        [int]$topNetPid,    [string]$topNetName,    [long]$topNetRxBps, [long]$topNetTxBps, [int]$netCap
    ) {
        if ($this.SampleUtcTicks240.Count -ge 360) { [void]$this.SampleUtcTicks240.Dequeue() }
        if ($this.TopCpuPid240.Count -ge 360)      { [void]$this.TopCpuPid240.Dequeue() }
        if ($this.TopCpuName240.Count -ge 360)     { [void]$this.TopCpuName240.Dequeue() }
        if ($this.TopCpuVal240.Count -ge 360)      { [void]$this.TopCpuVal240.Dequeue() }
        if ($this.TopCommitPid240.Count -ge 360)   { [void]$this.TopCommitPid240.Dequeue() }
        if ($this.TopCommitName240.Count -ge 360)  { [void]$this.TopCommitName240.Dequeue() }
        if ($this.TopCommitVal240.Count -ge 360)   { [void]$this.TopCommitVal240.Dequeue() }
        if ($this.TopRamPid240.Count -ge 360)      { [void]$this.TopRamPid240.Dequeue() }
        if ($this.TopRamName240.Count -ge 360)     { [void]$this.TopRamName240.Dequeue() }
        if ($this.TopRamVal240.Count -ge 360)      { [void]$this.TopRamVal240.Dequeue() }
        if ($this.TopNetPid240.Count -ge 360)      { [void]$this.TopNetPid240.Dequeue() }
        if ($this.TopNetName240.Count -ge 360)     { [void]$this.TopNetName240.Dequeue() }
        if ($this.TopNetRx240.Count -ge 360)       { [void]$this.TopNetRx240.Dequeue() }
        if ($this.TopNetTx240.Count -ge 360)       { [void]$this.TopNetTx240.Dequeue() }
        if ($this.TopNetCap240.Count -ge 360)      { [void]$this.TopNetCap240.Dequeue() }

        $this.SampleUtcTicks240.Enqueue($utcTicks)
        $this.TopCpuPid240.Enqueue($topCpuPid)
        $this.TopCpuName240.Enqueue($(if ($topCpuName) { $topCpuName } else { "" }))
        $this.TopCpuVal240.Enqueue($topCpuVal)
        $this.TopCommitPid240.Enqueue($topCommitPid)
        $this.TopCommitName240.Enqueue($(if ($topCommitName) { $topCommitName } else { "" }))
        $this.TopCommitVal240.Enqueue($topCommitBytes)
        $this.TopRamPid240.Enqueue($topRamPid)
        $this.TopRamName240.Enqueue($(if ($topRamName) { $topRamName } else { "" }))
        $this.TopRamVal240.Enqueue($topRamBytes)
        $this.TopNetPid240.Enqueue($topNetPid)
        $this.TopNetName240.Enqueue($(if ($topNetName) { $topNetName } else { "" }))
        $this.TopNetRx240.Enqueue($topNetRxBps)
        $this.TopNetTx240.Enqueue($topNetTxBps)
        $this.TopNetCap240.Enqueue($netCap)
    }

    [string] GetGraphHoverInfo([string]$chartKey, [int]$sampleIndex, [bool]$isMini) {
        $ticksArr = $this.SampleUtcTicks240.ToArray()
        if ($ticksArr.Count -eq 0) { return "No telemetry samples available yet" }

        $idx240 = if ($isMini) {
            $miniCount = switch ($chartKey) {
                'Commit' { $this.CommitHistory.Count }
                'Ram'    { $this.RamHistory.Count }
                default  { $this.CpuHistory.Count }
            }
            $offset = [Math]::Max(0, $ticksArr.Count - $miniCount)
            [Math]::Max(0, [Math]::Min($ticksArr.Count - 1, $offset + $sampleIndex))
        } else {
            [Math]::Max(0, [Math]::Min($ticksArr.Count - 1, $sampleIndex))
        }

        $utcTicks = $ticksArr[$idx240]
        if ($utcTicks -le 0L) {
            $preMsg = "No sample recorded yet (pre-session)`nMove right toward live data"
            if ($isMini) { $preMsg += "`nDouble-click for System Information (Ctrl+I)" }
            return $preMsg
        }

        $timeLine = "Time: $($this.FormatHoverTimestamp($utcTicks))"
        $valLine  = ""
        $topLine  = ""

        switch ($chartKey) {
            'Cpu' {
                $cArr = $this.CpuHistory240.ToArray()
                $kArr = $this.KernelHistory240.ToArray()
                $cVal = if ($idx240 -lt $cArr.Count) { [double]$cArr[$idx240] } else { 0.0 }
                $kVal = if ($idx240 -lt $kArr.Count) { [double]$kArr[$idx240] } else { 0.0 }
                $uVal = [Math]::Max(0.0, $cVal - $kVal)
                $valLine = "CPU: $($cVal.ToString('F1'))% (Kernel: $($kVal.ToString('F1'))%, User: $($uVal.ToString('F1'))%)"

                $pids  = $this.TopCpuPid240.ToArray()
                $names = $this.TopCpuName240.ToArray()
                $vals  = $this.TopCpuVal240.ToArray()
                $tPid  = if ($idx240 -lt $pids.Count)  { $pids[$idx240] }  else { 0 }
                $tName = if ($idx240 -lt $names.Count) { $names[$idx240] } else { "" }
                $tVal  = if ($idx240 -lt $vals.Count)  { $vals[$idx240] }  else { 0.0 }
                $topLine = if ($tPid -gt 0) {
                    $label = if ([string]::IsNullOrWhiteSpace($tName)) { "PID $tPid" } else { "$tName (PID $tPid)" }
                    "Top: $label - $($tVal.ToString('F2'))% CPU"
                } else {
                    "Top: Idle (< 0.1% active)"
                }
            }
            'Commit' {
                $mArr = $this.CommitHistory240.ToArray()
                $pct  = if ($idx240 -lt $mArr.Count) { [double]$mArr[$idx240] } else { 0.0 }
                if ($this.LastCommitLimitBytes -gt 0L) {
                    $approxUsed = ($pct / 100.0) * [double]$this.LastCommitLimitBytes
                    $valLine = "Commit: $($pct.ToString('F1'))% (~$($this.FormatBytesCompact($approxUsed)) / $($this.FormatBytesCompact([double]$this.LastCommitLimitBytes)))"
                } else {
                    $valLine = "Commit: $($pct.ToString('F1'))%"
                }

                $pids  = $this.TopCommitPid240.ToArray()
                $names = $this.TopCommitName240.ToArray()
                $vals  = $this.TopCommitVal240.ToArray()
                $tPid  = if ($idx240 -lt $pids.Count)  { $pids[$idx240] }  else { 0 }
                $tName = if ($idx240 -lt $names.Count) { $names[$idx240] } else { "" }
                $tVal  = if ($idx240 -lt $vals.Count)  { $vals[$idx240] }  else { 0L }
                $topLine = if ($tPid -gt 0) {
                    $label = if ([string]::IsNullOrWhiteSpace($tName)) { "PID $tPid" } else { "$tName (PID $tPid)" }
                    "Top: $label - $($this.FormatBytesCompact([double]$tVal)) Private"
                } else {
                    "Top: Unavailable"
                }
            }
            'Ram' {
                $rArr = $this.RamHistory240.ToArray()
                $pct  = if ($idx240 -lt $rArr.Count) { [double]$rArr[$idx240] } else { 0.0 }
                if ($this.LastPhysTotalBytes -gt 0L) {
                    $approxUsed = ($pct / 100.0) * [double]$this.LastPhysTotalBytes
                    $valLine = "Physical RAM: $($pct.ToString('F1'))% (~$($this.FormatBytesCompact($approxUsed)) / $($this.FormatBytesCompact([double]$this.LastPhysTotalBytes)))"
                } else {
                    $valLine = "Physical RAM: $($pct.ToString('F1'))%"
                }

                $pids  = $this.TopRamPid240.ToArray()
                $names = $this.TopRamName240.ToArray()
                $vals  = $this.TopRamVal240.ToArray()
                $tPid  = if ($idx240 -lt $pids.Count)  { $pids[$idx240] }  else { 0 }
                $tName = if ($idx240 -lt $names.Count) { $names[$idx240] } else { "" }
                $tVal  = if ($idx240 -lt $vals.Count)  { $vals[$idx240] }  else { 0L }
                $topLine = if ($tPid -gt 0) {
                    $label = if ([string]::IsNullOrWhiteSpace($tName)) { "PID $tPid" } else { "$tName (PID $tPid)" }
                    "Top: $label - $($this.FormatBytesCompact([double]$tVal)) Working Set"
                } else {
                    "Top: Unavailable"
                }
            }
            'Io' {
                $iTot = $this.IoTotalHistory240.ToArray()
                $iWrt = $this.IoWriteHistory240.ToArray()
                $totB = if ($idx240 -lt $iTot.Count) { [double]$iTot[$idx240] } else { 0.0 }
                $wrtB = if ($idx240 -lt $iWrt.Count) { [double]$iWrt[$idx240] } else { 0.0 }
                $valLine = "I/O Total: $($this.FormatRateCompact($totB)) (Write/Other: $($this.FormatRateCompact($wrtB)))"
                $topLine = "Top: Per-process I/O delta not polled (zero-overhead mode)"
            }
            'Net' {
                $rxArr = $this.NetRxHistory240.ToArray()
                $netTxHist = $this.NetTxHistory240.ToArray()
                $rxBps = if ($idx240 -lt $rxArr.Count)     { [double]$rxArr[$idx240] * 1024.0 }     else { 0.0 }
                $txBps = if ($idx240 -lt $netTxHist.Count) { [double]$netTxHist[$idx240] * 1024.0 } else { 0.0 }
                $valLine = "Network: Rx $($this.FormatRateCompact($rxBps)) | Tx $($this.FormatRateCompact($txBps))"

                $caps  = $this.TopNetCap240.ToArray()
                $pids  = $this.TopNetPid240.ToArray()
                $names = $this.TopNetName240.ToArray()
                $pRx   = $this.TopNetRx240.ToArray()
                $pTx   = $this.TopNetTx240.ToArray()
                $capAt = if ($idx240 -lt $caps.Count)  { $caps[$idx240] }  else { 0 }
                $tPid  = if ($idx240 -lt $pids.Count)  { $pids[$idx240] }  else { 0 }
                $tName = if ($idx240 -lt $names.Count) { $names[$idx240] } else { "" }
                $rxV   = if ($idx240 -lt $pRx.Count)   { [double]$pRx[$idx240] } else { 0.0 }
                $txV   = if ($idx240 -lt $pTx.Count)   { [double]$pTx[$idx240] } else { 0.0 }

                $topLine = switch ($capAt) {
                    1 {
                        if ($tPid -gt 0) {
                            $label = if ([string]::IsNullOrWhiteSpace($tName)) { "PID $tPid" } else { "$tName (PID $tPid)" }
                            "Top: $label - Rx $($this.FormatRateCompact($rxV)) | Tx $($this.FormatRateCompact($txV))"
                        } else {
                            "Top: No active per-process traffic in sample"
                        }
                    }
                    2 { "Top: Net ETW auto-paused (circuit breaker)" }
                    3 { "Top: Net ETW unavailable (requires Elevation)" }
                    4 { "Top: Net ETW unavailable on host" }
                    default { "Top: Enable Net ETW (Ctrl+Shift+N) for process attribution" }
                }
            }
            default {
                $valLine = $chartKey
            }
        }

        $res = "$valLine`n$timeLine`n$topLine"
        if ($isMini) { $res += "`nDouble-click for System Information (Ctrl+I)" }
        return $res
    }

    [string] GetCoreHoverInfo([Object]$coreVm, [int]$sampleIndex) {
        if (-not $coreVm) { return "" }
        $pair = $coreVm.GetSamplePair($sampleIndex)
        $tot  = [double]$pair[0]
        $kern = [double]$pair[1]
        $ticksArr = $this.CoreSampleUtcTicks60.ToArray()
        if ($ticksArr.Count -eq 0) {
            return "$($coreVm.CoreLabel): $($tot.ToString('F1'))% (Kernel: $($kern.ToString('F1'))%)"
        }
        $safeIdx  = [Math]::Max(0, [Math]::Min($ticksArr.Count - 1, $sampleIndex))
        $utcTicks = $ticksArr[$safeIdx]
        if ($utcTicks -le 0L) {
            return "$($coreVm.CoreLabel): No sample recorded yet (pre-session)"
        }
        return "$($coreVm.CoreLabel): $($tot.ToString('F1'))% (Kernel: $($kern.ToString('F1'))%)`nTime: $($this.FormatHoverTimestamp($utcTicks))"
    }
}

class InspectorModuleItem {
    [string]$Name
    [string]$Description
    [string]$CompanyName
    [string]$Version
    [string]$Size
    [string]$BaseAddress
    [string]$Path

    InspectorModuleItem([Object]$d) {
        $this.Name        = [string]$d['Name']
        $this.Description = [string]$d['Description']
        $this.CompanyName = [string]$d['CompanyName']
        $this.Version     = [string]$d['Version']
        $this.Size        = [string]$d['Size']
        $this.BaseAddress = [string]$d['BaseAddress']
        $this.Path        = [string]$d['Path']
    }
}

class InspectorHandleItem {
    [string]$Type
    [string]$Name
    [string]$Handle
    [string]$Access

    InspectorHandleItem([Object]$d) {
        $this.Type   = [string]$d['Type']
        $this.Name   = [string]$d['Name']
        $this.Handle = [string]$d['Handle']
        $this.Access = [string]$d['Access']
    }
}

class InspectorConnectionItem {
    [string]$Protocol
    [string]$LocalEndpoint
    [string]$RemoteEndpoint
    [string]$State

    InspectorConnectionItem([Object]$d) {
        $this.Protocol       = [string]$d['Protocol']
        $this.LocalEndpoint  = [string]$d['LocalEndpoint']
        $this.RemoteEndpoint = [string]$d['RemoteEndpoint']
        $this.State          = [string]$d['State']
    }
}

class InspectorServiceItem {
    [string]$Name
    [string]$DisplayName
    [string]$Status
    [string]$StartType
    [string]$User

    InspectorServiceItem([Object]$d) {
        $this.Name        = [string]$d['Name']
        $this.DisplayName = [string]$d['DisplayName']
        $this.Status      = [string]$d['Status']
        $this.StartType   = [string]$d['StartType']
        $this.User        = [string]$d['User']
    }
}

class InspectorEnvItem {
    [string]$Key
    [string]$Value

    InspectorEnvItem([Object]$d) {
        $this.Key   = [string]$d['Key']
        $this.Value = [string]$d['Value']
    }
}

class HostTabItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [string]$TabId
    [string]$ComputerName
    [string]$Title
    [string]$Transport
    [string]$BadgeBackground
    [Object]$BadgeBackgroundBrush
    [bool]$IsLocal
    [bool]$IsActive
    [bool]$IsDarkTheme
    [string]$ThemeMode
    [string]$StatusDotFill
    [Object]$StatusDotFillBrush
    [string]$TabBackground
    [Object]$TabBackgroundBrush
    [string]$TabBorderBrush
    [Object]$TabBorderSolidBrush
    [string]$TitleForeground
    [Object]$TitleForegroundBrush
    [string]$TitleFontWeight
    [Object]$TitleWeight
    [string]$AccentVisibility
    [Object]$AccentVis
    [string]$CloseVisibility
    [Object]$CloseVis
    [string]$LatencyText
    [string]$ConnState
    [int]$Port
    [bool]$UseSSL

    # Per-Tab Isolated State Caches (Enables <5ms Instant Tab Switching & 0 KB/s Standby)
    [Object]$ProcessMap
    [Object]$ServicesMap
    [Object]$PidServicesMap
    [Object]$SummaryVm
    [hashtable]$TelemStats
    [bool]$EnableNetEtw
    [int]$NetEtwCap
    [int]$NetEtwEventsPerSec
    [int]$NetBannerDismissedCap
    [bool]$HasBaseline
    [string]$BaselineTimeText
    [hashtable]$BaselineSnapshots
    [Object]$NetworkSockets
    [Object]$NetworkTimeline
    [Object]$PendingNetTimeline
    [bool]$HasLoadedSockets
    [string]$NetworkSubMode
    [string]$NetworkSocketsSummary
    [bool]$AutoRefreshSockets
    [hashtable]$NetworkPrevSnapshot
    [string]$NetworkStatusCountsText

    hidden [string]$_LastTitle
    hidden [string]$_LastTransport
    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    HostTabItemViewModel([string]$tabId, [string]$compName, [string]$title, [string]$transport, [bool]$isLocal, [Object]$summaryVm) {
        $this.Handlers        = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.TabId           = $tabId
        $this.ComputerName    = $compName
        $this.Title           = $title
        $this.Transport       = $transport
        $this._LastTitle      = $title
        $this._LastTransport  = $transport
        $this.BadgeBackground = if ($isLocal) { "#0D9488" } else { "#0284C7" }
        $this.BadgeBackgroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush($this.BadgeBackground)
        $this.IsLocal         = $isLocal
        $this.ConnState       = if ($isLocal) { "LocalMode" } else { "Connected" }
        $this.Port            = 0
        $this.UseSSL          = $false
        $this.IsActive        = $true
        $this.IsDarkTheme     = $false
        $this.ThemeMode       = "Light"
        $this.StatusDotFill   = "#16A34A"
        $this.StatusDotFillBrush = [PSRPMThemeRegistry]::GetFrozenBrush("#16A34A")
        $this.TabBackground   = "#FFFFFF"
        $this.TabBackgroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush("#FFFFFF")
        $this.TabBorderBrush  = "#0284C7"
        $this.TabBorderSolidBrush = [PSRPMThemeRegistry]::GetFrozenBrush("#0284C7")
        $this.TitleForeground = "#0F172A"
        $this.TitleForegroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush("#0F172A")
        $this.TitleFontWeight = "Bold"
        $this.TitleWeight     = [PSRPMThemeRegistry]::GetFontWeight("Bold")
        $this.AccentVisibility = "Visible"
        $this.AccentVis       = [PSRPMThemeRegistry]::GetVisibility("Visible")
        $this.CloseVisibility = "Collapsed"
        $this.CloseVis        = [PSRPMThemeRegistry]::GetVisibility("Collapsed")
        $this.LatencyText     = ""
        $this.EnableNetEtw    = $false
        $this.NetEtwCap       = 0
        $this.NetEtwEventsPerSec = 0
        $this.NetBannerDismissedCap = 0
        $this.HasBaseline     = $false
        $this.BaselineTimeText = ""
        $this.BaselineSnapshots = @{}
        $this.NetworkSockets  = [System.Collections.Generic.List[Object]]::new()
        $this.NetworkTimeline = [System.Collections.Generic.List[Object]]::new()
        $this.PendingNetTimeline = [System.Collections.Generic.Queue[Object]]::new()
        $this.HasLoadedSockets = $false
        $this.NetworkSubMode   = "Sockets"
        $this.NetworkSocketsSummary = "Not queried yet"
        $this.AutoRefreshSockets = $true
        $this.NetworkPrevSnapshot = @{}
        $this.NetworkStatusCountsText = "Endpoints: 0  |  Established: 0  |  Listening: 0  |  Time Wait: 0  |  Close Wait: 0"

        $this.ProcessMap     = [System.Collections.Generic.Dictionary[int, Object]]::new()
        $this.ServicesMap    = [System.Collections.Generic.Dictionary[string, Object]]::new()
        $this.PidServicesMap = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new()
        $this.SummaryVm      = if ($summaryVm) { $summaryVm } else { [SystemSummaryViewModel]::new() }
        $this.TelemStats     = @{
            TotalWireBytes  = 0L
            TotalRawBytes   = 0L
            TotalTicks      = 0L
            TotalRttMs      = 0L
            LastReceivedSeq = 0
        }
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [PSRPMThemeRegistry]::GetPropArgs($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] UpdateVisualState([bool]$active, [bool]$isDark, [bool]$canClose, [string]$connState, [bool]$isPaused, [int]$rttMs) {
        $resolvedMode = if (-not [string]::IsNullOrWhiteSpace($this.ThemeMode) -and ([PSRPMThemeRegistry]::IsDarkMode($this.ThemeMode) -eq $isDark)) {
            $this.ThemeMode
        } elseif ($isDark) {
            "Dark"
        } else {
            "Light"
        }
        $this.UpdateVisualState($active, $resolvedMode, $canClose, $connState, $isPaused, $rttMs)
    }

    [void] UpdateVisualState([bool]$active, [string]$themeMode, [bool]$canClose, [string]$connState, [bool]$isPaused, [int]$rttMs) {
        $resolvedMode = if ([string]::IsNullOrWhiteSpace($themeMode)) { "Light" } else { $themeMode }
        $palette = [PSRPMThemeRegistry]::GetPalette($resolvedMode)
        $tabColors = $palette.TabColors

        $this.ThemeMode   = $resolvedMode
        $this.IsDarkTheme = [bool]$palette.IsDark

        $newCloseVis  = if ($canClose) { "Visible" } else { "Collapsed" }
        $newAccentVis = if ($active)   { "Visible" } else { "Collapsed" }
        $newWeight    = if ($active)   { "Bold" }    else { "SemiBold" }
        $newBadgeBg   = if ($this.IsLocal) { [string]$tabColors.BadgeLocalBg } else { [string]$tabColors.BadgeWinRmBg }

        $newDotFill = "#64748B"
        $newLatText = ""
        $newTabBg   = ""
        $newTabBd   = ""
        $newTitleFg = ""

        if ($active) {
            if ($connState -eq "NotConnected") {
                $newDotFill = "#64748B"
                $newLatText = "Not Connected"
            } elseif ($connState -eq "Connecting") {
                $newDotFill = "#0284C7"
                $newLatText = "Connecting..."
            } elseif ($isPaused) {
                $newDotFill = "#F59E0B"
                $newLatText = "Paused"
            } elseif ($connState -in @("Connected", "LocalMode")) {
                $newDotFill = "#16A34A"
                $newLatText = "${rttMs}ms"
            } elseif ($connState -eq "Degraded") {
                $newDotFill = "#EAB308"
                $newLatText = "Degraded"
            } elseif ($connState -eq "Reconnecting") {
                $newDotFill = "#EA580C"
                $newLatText = "Reconnecting"
            } else {
                $newDotFill = "#DC2626"
                $newLatText = "Offline"
            }
            $newTabBg   = [string]$tabColors.ActiveBg
            $newTabBd   = [string]$tabColors.ActiveBorder
            $newTitleFg = [string]$tabColors.ActiveFg
        } else {
            if ($connState -eq "NotConnected") {
                $newLatText = "Not Connected"
                $newDotFill = "#64748B"
            } elseif ($connState -eq "Connecting") {
                $newLatText = "Connecting..."
                $newDotFill = "#0284C7"
            } elseif ($connState -eq "Disconnected") {
                $newLatText = "Offline"
                $newDotFill = "#DC2626"
            } elseif ($connState -eq "Reconnecting") {
                $newLatText = "Reconnecting"
                $newDotFill = "#EA580C"
            } elseif ($connState -eq "Degraded") {
                $newLatText = "Degraded"
                $newDotFill = "#EAB308"
            } else {
                $newLatText = "Standby"
                $newDotFill = "#64748B"
            }
            $newTabBg   = [string]$tabColors.StandbyBg
            $newTabBd   = [string]$tabColors.StandbyBorder
            $newTitleFg = [string]$tabColors.StandbyFg
        }

        if ($this.Title -ne $this._LastTitle) {
            $this._LastTitle = $this.Title
            $this.OnPropertyChanged('Title')
        }
        if ($this.Transport -ne $this._LastTransport) {
            $this._LastTransport = $this.Transport
            $this.OnPropertyChanged('Transport')
        }
        if ($this.IsActive -ne $active) {
            $this.IsActive = $active
            $this.OnPropertyChanged('IsActive')
        }
        if ($this.BadgeBackground -ne $newBadgeBg) {
            $this.BadgeBackground = $newBadgeBg
            $this.BadgeBackgroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush($newBadgeBg)
            $this.OnPropertyChanged('BadgeBackground')
            $this.OnPropertyChanged('BadgeBackgroundBrush')
        }
        if ($this.StatusDotFill -ne $newDotFill) {
            $this.StatusDotFill = $newDotFill
            $this.StatusDotFillBrush = [PSRPMThemeRegistry]::GetFrozenBrush($newDotFill)
            $this.OnPropertyChanged('StatusDotFill')
            $this.OnPropertyChanged('StatusDotFillBrush')
        }
        if ($this.TabBackground -ne $newTabBg) {
            $this.TabBackground = $newTabBg
            $this.TabBackgroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush($newTabBg)
            $this.OnPropertyChanged('TabBackground')
            $this.OnPropertyChanged('TabBackgroundBrush')
        }
        if ($this.TabBorderBrush -ne $newTabBd) {
            $this.TabBorderBrush = $newTabBd
            $this.TabBorderSolidBrush = [PSRPMThemeRegistry]::GetFrozenBrush($newTabBd)
            $this.OnPropertyChanged('TabBorderBrush')
            $this.OnPropertyChanged('TabBorderSolidBrush')
        }
        if ($this.TitleForeground -ne $newTitleFg) {
            $this.TitleForeground = $newTitleFg
            $this.TitleForegroundBrush = [PSRPMThemeRegistry]::GetFrozenBrush($newTitleFg)
            $this.OnPropertyChanged('TitleForeground')
            $this.OnPropertyChanged('TitleForegroundBrush')
        }
        if ($this.TitleFontWeight -ne $newWeight) {
            $this.TitleFontWeight = $newWeight
            $this.TitleWeight = [PSRPMThemeRegistry]::GetFontWeight($newWeight)
            $this.OnPropertyChanged('TitleFontWeight')
            $this.OnPropertyChanged('TitleWeight')
        }
        if ($this.AccentVisibility -ne $newAccentVis) {
            $this.AccentVisibility = $newAccentVis
            $this.AccentVis = [PSRPMThemeRegistry]::GetVisibility($newAccentVis)
            $this.OnPropertyChanged('AccentVisibility')
            $this.OnPropertyChanged('AccentVis')
        }
        if ($this.CloseVisibility -ne $newCloseVis) {
            $this.CloseVisibility = $newCloseVis
            $this.CloseVis = [PSRPMThemeRegistry]::GetVisibility($newCloseVis)
            $this.OnPropertyChanged('CloseVisibility')
            $this.OnPropertyChanged('CloseVis')
        }
        if ($this.LatencyText -ne $newLatText) {
            $this.LatencyText = $newLatText
            $this.OnPropertyChanged('LatencyText')
        }
    }
}
