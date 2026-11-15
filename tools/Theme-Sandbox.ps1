# Requires -Version 5.1
<#
.SYNOPSIS
    Interactive Theme Sandbox & Live Preview App for PSRPM.
.DESCRIPTION
    Launches PSRPM's real WPF XAML UI populated with realistic synthetic telemetry
    across all semantic row states, host tabs, network badges, ETW banners, log console,
    and all 7 child dialogs. Supports instant switching across all 6 built-in themes
    plus loading, live-watching, exporting, and WCAG 2.1 AA contrast-auditing custom
    JSON themes.

    100% fileless (zero Add-Type -TypeDefinition / csc.exe) and strict 7-bit ASCII.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tools\Theme-Sandbox.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tools\Theme-Sandbox.ps1 -Theme TokyoNight
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tools\Theme-Sandbox.ps1 -ThemeFile .\tools\sample-theme.json -Watch
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$Theme = "Light",

    [Parameter(Mandatory = $false)]
    [string]$ThemeFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$Watch
)

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw "Theme-Sandbox.ps1 requires an STA thread for WPF. Launch with: powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tools\Theme-Sandbox.ps1"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
$uiDir     = Join-Path $repoRoot "PSRPM\UI"
$privDir   = Join-Path $repoRoot "PSRPM\Private"

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Xaml -ErrorAction Stop
Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop

. (Join-Path $privDir "ViewModelClasses.ps1")

$iconPath = Join-Path $repoRoot "PSRPM\Assets\psrpm_24.png"
if (-not (Test-Path $iconPath)) {
    $iconPath = Join-Path $repoRoot "PSRPM\Assets\psrpm.png"
}
$appIconFrame = if (Test-Path $iconPath) {
    [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($iconPath))
} else {
    $null
}

$brushConv = [System.Windows.Media.BrushConverter]::new()
$frozenBrushCache = @{}

function Get-FrozenBrush {
    param([string]$hex)
    if ([string]::IsNullOrWhiteSpace($hex)) { $hex = "#00000000" }
    if ($frozenBrushCache.ContainsKey($hex)) { return $frozenBrushCache[$hex] }
    $b = $brushConv.ConvertFromString($hex)
    if ($b.CanFreeze) { $b.Freeze() }
    $frozenBrushCache[$hex] = $b
    return $b
}

function Convert-JsonObjectToHashtable {
    param($obj)
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $obj.Keys) {
            $ht[[string]$key] = Convert-JsonObjectToHashtable $obj[$key]
        }
        return $ht
    }
    if (($obj -is [System.Collections.IEnumerable]) -and -not ($obj -is [string])) {
        $arr = New-Object System.Collections.Generic.List[Object]
        foreach ($item in $obj) {
            [void]$arr.Add((Convert-JsonObjectToHashtable $item))
        }
        return ,($arr.ToArray())
    }
    return $obj
}

function ConvertTo-PrettyThemeJson {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,
        [int]$Indent = 0
    )
    $pad = "  " * $Indent
    $childPad = "  " * ($Indent + 1)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("{")

    $preferredOrder = @("Name", "DisplayName", "IsDark", "BaseTheme", "Brushes", "Rows", "TabColors", "Legend", "Banner")
    $keysList = [System.Collections.Generic.List[string]]::new()
    foreach ($pk in $preferredOrder) {
        if ($Data.ContainsKey($pk)) { [void]$keysList.Add($pk) }
    }
    foreach ($rk in ($Data.Keys | Sort-Object)) {
        if (-not $keysList.Contains([string]$rk)) { [void]$keysList.Add([string]$rk) }
    }

    for ($i = 0; $i -lt $keysList.Count; $i++) {
        $k = $keysList[$i]
        $v = $Data[$k]
        $comma = if ($i -lt ($keysList.Count - 1)) { "," } else { "" }
        $escKey = $k.Replace('\', '\\').Replace('"', '\"')
        if ($v -is [hashtable]) {
            $nested = ConvertTo-PrettyThemeJson -Data $v -Indent ($Indent + 1)
            [void]$sb.AppendLine(('{0}"{1}": {2}{3}' -f $childPad, $escKey, $nested, $comma))
        } elseif ($v -is [bool]) {
            $boolStr = if ($v) { "true" } else { "false" }
            [void]$sb.AppendLine(('{0}"{1}": {2}{3}' -f $childPad, $escKey, $boolStr, $comma))
        } elseif (($v -is [int]) -or ($v -is [long]) -or ($v -is [double])) {
            [void]$sb.AppendLine(('{0}"{1}": {2}{3}' -f $childPad, $escKey, $v, $comma))
        } else {
            $sVal = ([string]$v).Replace('\', '\\').Replace('"', '\"')
            [void]$sb.AppendLine(('{0}"{1}": "{2}"{3}' -f $childPad, $escKey, $sVal, $comma))
        }
    }
    [void]$sb.Append(('{0}}}' -f $pad))
    return $sb.ToString()
}

function Get-RelativeLuminance {
    param([string]$hex)
    if ([string]::IsNullOrWhiteSpace($hex)) { return 0.0 }
    $h = $hex.Trim().TrimStart('#')
    if ($h.Length -eq 8) { $h = $h.Substring(2) }
    if ($h.Length -ne 6) { return 0.0 }
    $r = [Convert]::ToInt32($h.Substring(0, 2), 16) / 255.0
    $g = [Convert]::ToInt32($h.Substring(2, 2), 16) / 255.0
    $b = [Convert]::ToInt32($h.Substring(4, 2), 16) / 255.0
    $linR = if ($r -le 0.03928) { $r / 12.92 } else { [Math]::Pow((($r + 0.055) / 1.055), 2.4) }
    $linG = if ($g -le 0.03928) { $g / 12.92 } else { [Math]::Pow((($g + 0.055) / 1.055), 2.4) }
    $linB = if ($b -le 0.03928) { $b / 12.92 } else { [Math]::Pow((($b + 0.055) / 1.055), 2.4) }
    return (0.2126 * $linR + 0.7152 * $linG + 0.0722 * $linB)
}

function Get-ContrastRatio {
    param([string]$hexA, [string]$hexB)
    $l1 = Get-RelativeLuminance $hexA
    $l2 = Get-RelativeLuminance $hexB
    $hi = [Math]::Max($l1, $l2)
    $lo = [Math]::Min($l1, $l2)
    return (($hi + 0.05) / ($lo + 0.05))
}

function Remove-JsoncCommentsAndTrailingCommas {
    param([string]$Raw)
    if ([string]::IsNullOrEmpty($Raw)) { return $Raw }
    $sb = [System.Text.StringBuilder]::new($Raw.Length)
    $inStr = $false
    $esc = $false
    $len = $Raw.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Raw[$i]
        if ($inStr) {
            [void]$sb.Append($ch)
            if ($esc) {
                $esc = $false
            } elseif ($ch -eq '\') {
                $esc = $true
            } elseif ($ch -eq '"') {
                $inStr = $false
            }
            continue
        }
        if ($ch -eq '"') {
            $inStr = $true
            [void]$sb.Append($ch)
            continue
        }
        if ($ch -eq '/' -and ($i + 1) -lt $len) {
            $next = $Raw[$i + 1]
            if ($next -eq '/') {
                $i += 2
                while ($i -lt $len -and $Raw[$i] -ne "`n") { $i++ }
                if ($i -lt $len) { [void]$sb.Append("`n") }
                continue
            }
            if ($next -eq '*') {
                $i += 2
                while ($i -lt ($len - 1) -and -not ($Raw[$i] -eq '*' -and $Raw[$i + 1] -eq '/')) {
                    if ($Raw[$i] -eq "`n") { [void]$sb.Append("`n") }
                    $i++
                }
                $i++
                continue
            }
        }
        [void]$sb.Append($ch)
    }

    # Strip trailing commas outside strings
    $noComments = $sb.ToString()
    $out = [System.Text.StringBuilder]::new($noComments.Length)
    $inStr = $false
    $esc = $false
    $nLen = $noComments.Length
    for ($i = 0; $i -lt $nLen; $i++) {
        $ch = $noComments[$i]
        if ($inStr) {
            [void]$out.Append($ch)
            if ($esc) { $esc = $false }
            elseif ($ch -eq '\') { $esc = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') {
            $inStr = $true
            [void]$out.Append($ch)
            continue
        }
        if ($ch -eq ',') {
            $j = $i + 1
            while ($j -lt $nLen -and [char]::IsWhiteSpace($noComments[$j])) { $j++ }
            if ($j -lt $nLen -and ($noComments[$j] -eq '}' -or $noComments[$j] -eq ']')) {
                continue
            }
        }
        [void]$out.Append($ch)
    }
    return $out.ToString()
}

function ConvertFrom-CssHex {
    param([string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return $null }
    $h = $Hex.Trim().TrimStart('#')
    if ($h -notmatch '^[0-9A-Fa-f]+$') { return $null }
    if ($h.Length -eq 3) {
        $h = "{0}{0}{1}{1}{2}{2}FF" -f $h[0], $h[1], $h[2]
    } elseif ($h.Length -eq 4) {
        $h = "{0}{0}{1}{1}{2}{2}{3}{3}" -f $h[0], $h[1], $h[2], $h[3]
    } elseif ($h.Length -eq 6) {
        $h = "${h}FF"
    } elseif ($h.Length -ne 8) {
        return $null
    }
    return @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16), [Convert]::ToInt32($h.Substring(6, 2), 16))
}

function Format-WpfHex {
    param([int]$R, [int]$G, [int]$B, [int]$A = 255)
    $rc = [Math]::Max(0, [Math]::Min(255, $R))
    $gc = [Math]::Max(0, [Math]::Min(255, $G))
    $bc = [Math]::Max(0, [Math]::Min(255, $B))
    $ac = [Math]::Max(0, [Math]::Min(255, $A))
    if ($ac -eq 255) {
        return ('#{0:X2}{1:X2}{2:X2}' -f $rc, $gc, $bc)
    }
    return ('#{0:X2}{1:X2}{2:X2}{3:X2}' -f $ac, $rc, $gc, $bc)
}

function Resolve-VsCodeColor {
    param(
        [hashtable]$Colors,
        [string[]]$Keys,
        [string]$DefaultHex,
        [string]$BaseBgHex = "#1E1E1E",
        [switch]$KeepAlpha
    )
    $rawHex = $null
    if ($Colors) {
        foreach ($k in $Keys) {
            if ($Colors.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace([string]$Colors[$k])) {
                $rawHex = [string]$Colors[$k]
                break
            }
        }
    }
    if (-not $rawHex) { $rawHex = $DefaultHex }
    $rgba = ConvertFrom-CssHex $rawHex
    if ($null -eq $rgba) {
        $rgba = ConvertFrom-CssHex $DefaultHex
    }
    if ($rgba[3] -eq 255 -or $KeepAlpha) {
        return (Format-WpfHex $rgba[0] $rgba[1] $rgba[2] $rgba[3])
    }
    $bg = ConvertFrom-CssHex $BaseBgHex
    if ($null -eq $bg) { $bg = @(30, 30, 30, 255) }
    $a = $rgba[3] / 255.0
    $r = [int][Math]::Round($rgba[0] * $a + $bg[0] * (1.0 - $a))
    $g = [int][Math]::Round($rgba[1] * $a + $bg[1] * (1.0 - $a))
    $b = [int][Math]::Round($rgba[2] * $a + $bg[2] * (1.0 - $a))
    return (Format-WpfHex $r $g $b 255)
}

function Mix-HexColors {
    param([string]$HexA, [string]$HexB, [double]$WeightB)
    $a = ConvertFrom-CssHex $HexA
    $b = ConvertFrom-CssHex $HexB
    if ($null -eq $a) { return $HexB }
    if ($null -eq $b) { return $HexA }
    $w = [Math]::Max(0.0, [Math]::Min(1.0, $WeightB))
    $r = [int][Math]::Round($a[0] * (1.0 - $w) + $b[0] * $w)
    $g = [int][Math]::Round($a[1] * (1.0 - $w) + $b[1] * $w)
    $bl = [int][Math]::Round($a[2] * (1.0 - $w) + $b[2] * $w)
    return (Format-WpfHex $r $g $bl 255)
}

function Set-HexAlpha {
    param([string]$Hex, [int]$AlphaByte)
    $c = ConvertFrom-CssHex $Hex
    if ($null -eq $c) { return $Hex }
    return (Format-WpfHex $c[0] $c[1] $c[2] $AlphaByte)
}

function Ensure-ContrastFg {
    param(
        [string]$FgHex,
        [string[]]$BgHexes,
        [double]$MinRatio = 4.6
    )
    $worstRatio = 21.0
    $avgLum = 0.0
    foreach ($bg in $BgHexes) {
        $r = Get-ContrastRatio $FgHex $bg
        if ($r -lt $worstRatio) { $worstRatio = $r }
        $avgLum += (Get-RelativeLuminance $bg)
    }
    if ($worstRatio -ge $MinRatio) { return $FgHex }
    $avgLum = $avgLum / [Math]::Max(1, $BgHexes.Count)
    $targetHex = if ($avgLum -lt 0.35) { "#FFFFFF" } else { "#0F172A" }

    $lo = 0.0
    $hi = 1.0
    $best = $targetHex
    for ($step = 0; $step -lt 12; $step++) {
        $mid = ($lo + $hi) / 2.0
        $cand = Mix-HexColors $FgHex $targetHex $mid
        $candMin = 21.0
        foreach ($bg in $BgHexes) {
            $cr = Get-ContrastRatio $cand $bg
            if ($cr -lt $candMin) { $candMin = $cr }
        }
        if ($candMin -ge $MinRatio) {
            $best = $cand
            $hi = $mid
        } else {
            $lo = $mid
        }
    }
    return $best
}

function Ensure-ContrastBgForWhite {
    param([string]$Hex, [double]$MinRatio = 4.6)
    if ((Get-ContrastRatio "#FFFFFF" $Hex) -ge $MinRatio) { return $Hex }
    $lo = 0.0; $hi = 1.0; $best = "#1E293B"
    for ($step = 0; $step -lt 12; $step++) {
        $mid = ($lo + $hi) / 2.0
        $cand = Mix-HexColors $Hex "#0B0F17" $mid
        if ((Get-ContrastRatio "#FFFFFF" $cand) -ge $MinRatio) {
            $best = $cand
            $hi = $mid
        } else {
            $lo = $mid
        }
    }
    return $best
}

function Get-VsCodeScopeColor {
    param([Object[]]$TokenColors, [string[]]$ScopeHints)
    if (-not $TokenColors) { return $null }
    foreach ($hint in $ScopeHints) {
        foreach ($rule in $TokenColors) {
            if (-not ($rule -is [hashtable])) { continue }
            $settings = $rule["settings"]
            if (-not ($settings -is [hashtable])) { continue }
            $fg = [string]$settings["foreground"]
            if ([string]::IsNullOrWhiteSpace($fg)) { continue }
            $scopeObj = $rule["scope"]
            $scopes = if ($scopeObj -is [string]) {
                $scopeObj -split ',' | ForEach-Object { $_.Trim() }
            } elseif ($scopeObj -is [System.Collections.IEnumerable]) {
                @($scopeObj | ForEach-Object { ([string]$_).Trim() })
            } else {
                @()
            }
            foreach ($sc in $scopes) {
                if ($sc -eq $hint -or $sc -like "$hint.*" -or $sc -like "*$hint*") {
                    return $fg
                }
            }
        }
    }
    return $null
}

function Read-VsCodeThemeRecursive {
    param([string]$Path, [System.Collections.Generic.HashSet[string]]$Visited)
    $full = (Resolve-Path -LiteralPath $Path).Path
    if ($Visited.Contains($full)) { return @{} }
    [void]$Visited.Add($full)

    $raw = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    $clean = Remove-JsoncCommentsAndTrailingCommas $raw
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 8388608
    $parsed = $jss.DeserializeObject($clean)
    $spec = Convert-JsonObjectToHashtable $parsed
    if (-not ($spec -is [hashtable])) { return @{} }

    if ($spec.ContainsKey("include") -and -not [string]::IsNullOrWhiteSpace([string]$spec["include"])) {
        $incRel = [string]$spec["include"]
        $incPath = Join-Path (Split-Path -Parent $full) $incRel
        if (Test-Path -LiteralPath $incPath) {
            $parentSpec = Read-VsCodeThemeRecursive -Path $incPath -Visited $Visited
            $mergedColors = @{}
            if ($parentSpec["colors"] -is [hashtable]) {
                foreach ($k in $parentSpec["colors"].Keys) { $mergedColors[$k] = $parentSpec["colors"][$k] }
            }
            if ($spec["colors"] -is [hashtable]) {
                foreach ($k in $spec["colors"].Keys) { $mergedColors[$k] = $spec["colors"][$k] }
            }
            $spec["colors"] = $mergedColors
            if (-not $spec.ContainsKey("type") -and $parentSpec.ContainsKey("type")) { $spec["type"] = $parentSpec["type"] }
            if (-not $spec.ContainsKey("tokenColors") -and $parentSpec.ContainsKey("tokenColors")) { $spec["tokenColors"] = $parentSpec["tokenColors"] }
        }
    }
    return $spec
}

function ConvertFrom-VsCodeTheme {
    param([hashtable]$VsCodeSpec, [string]$FallbackName = "VSCodeTheme")

    $colors = if ($VsCodeSpec["colors"] -is [hashtable]) { $VsCodeSpec["colors"] } else { @{} }
    $tokens = $VsCodeSpec["tokenColors"]

    $rawName = if ($VsCodeSpec.ContainsKey("name") -and -not [string]::IsNullOrWhiteSpace([string]$VsCodeSpec["name"])) {
        [string]$VsCodeSpec["name"]
    } else {
        $FallbackName
    }
    $cleanName = ($rawName -replace '[^A-Za-z0-9_-]', '')
    if ([string]::IsNullOrWhiteSpace($cleanName)) { $cleanName = "VSCodeCustom" }

    $vscType = ([string]$VsCodeSpec["type"]).ToLowerInvariant()
    $probeBg = Resolve-VsCodeColor $colors @("editor.background") "#1E1E1E"
    $isDark = if ($vscType -in @("dark", "hcdark")) {
        $true
    } elseif ($vscType -in @("light", "hclight")) {
        $false
    } else {
        ((Get-RelativeLuminance $probeBg) -lt 0.20)
    }

    $defBg      = if ($isDark) { "#1E1E1E" } else { "#FFFFFF" }
    $defWinBg   = if ($isDark) { "#181818" } else { "#F3F4F6" }
    $defHdrBg   = if ($isDark) { "#252526" } else { "#E5E7EB" }
    $defFg      = if ($isDark) { "#D4D4D4" } else { "#1E293B" }
    $defMuted   = if ($isDark) { "#9CA3AF" } else { "#475569" }
    $defAccent  = if ($isDark) { "#38BDF8" } else { "#0284C7" }

    $surfaceBg  = Resolve-VsCodeColor $colors @("editor.background") $defBg
    $windowBg   = Resolve-VsCodeColor $colors @("sideBar.background", "activityBar.background") $defWinBg $surfaceBg
    $toolbarBg  = Resolve-VsCodeColor $colors @("titleBar.activeBackground", "editorGroupHeader.tabsBackground", "sideBar.background") $windowBg $surfaceBg
    $headerBg   = Resolve-VsCodeColor $colors @("tab.inactiveBackground", "sideBarSectionHeader.background", "statusBar.background") $defHdrBg $surfaceBg
    $borderSub  = Resolve-VsCodeColor $colors @("panel.border", "sideBar.border", "editorGroup.border", "tab.border") (Mix-HexColors $surfaceBg $defFg 0.16) $surfaceBg
    $treeLine   = Resolve-VsCodeColor $colors @("tree.indentGuidesStroke", "editorIndentGuide.activeBackground", "editorIndentGuide.background") (Mix-HexColors $surfaceBg $defFg 0.32) $surfaceBg

    $rawPri     = Resolve-VsCodeColor $colors @("editor.foreground", "foreground") $defFg $surfaceBg
    $rawSec     = Resolve-VsCodeColor $colors @("sideBar.foreground", "foreground", "editor.foreground") $rawPri $surfaceBg
    $tokCom     = Get-VsCodeScopeColor $tokens @("comment")
    $rawMuted   = Resolve-VsCodeColor $colors @("descriptionForeground", "tab.inactiveForeground", "editorLineNumber.foreground") $(if ($tokCom) { $tokCom } else { $defMuted }) $surfaceBg
    $rawAccent  = Resolve-VsCodeColor $colors @("focusBorder", "textLink.foreground", "button.background", "activityBarBadge.background") $defAccent $surfaceBg

    $coreBgs    = @($windowBg, $toolbarBg, $surfaceBg)
    $textPri    = Ensure-ContrastFg $rawPri $coreBgs 4.65
    $textSec    = Ensure-ContrastFg $rawSec $coreBgs 4.65
    $textMuted  = Ensure-ContrastFg $rawMuted $coreBgs 4.65
    $accent     = Ensure-ContrastFg $rawAccent $coreBgs 4.65

    $rowSelBg   = Resolve-VsCodeColor $colors @("list.activeSelectionBackground", "editor.selectionBackground") (Mix-HexColors $surfaceBg $accent 0.35) $surfaceBg
    $rowSelFg   = Ensure-ContrastFg (Resolve-VsCodeColor $colors @("list.activeSelectionForeground") "#FFFFFF" $rowSelBg) @($rowSelBg) 4.65
    $rowHover   = Resolve-VsCodeColor $colors @("list.hoverBackground", "editor.lineHighlightBackground") (Mix-HexColors $surfaceBg $accent 0.12) $surfaceBg -KeepAlpha

    $badgeBg    = Resolve-VsCodeColor $colors @("badge.background", "activityBarBadge.background", "button.background") $rowSelBg $surfaceBg
    $badgeFg    = Ensure-ContrastFg (Resolve-VsCodeColor $colors @("badge.foreground", "activityBarBadge.foreground", "button.foreground") "#FFFFFF" $badgeBg) @($badgeBg) 4.65

    $menuBg     = Resolve-VsCodeColor $colors @("menu.background", "dropdown.background") $windowBg $surfaceBg
    $menuBorder = Resolve-VsCodeColor $colors @("menu.border", "dropdown.border") $borderSub $surfaceBg
    $menuHover  = Resolve-VsCodeColor $colors @("menu.selectionBackground", "list.hoverBackground") (Mix-HexColors $menuBg $accent 0.18) $menuBg

    $logBgDef   = if ($isDark) { Mix-HexColors $surfaceBg "#000000" 0.20 } else { $surfaceBg }
    $logBg      = Resolve-VsCodeColor $colors @("terminal.background", "panel.background") $logBgDef $surfaceBg
    $logHdrBg   = Resolve-VsCodeColor $colors @("panelTitle.activeBorder", "tab.inactiveBackground") $headerBg $logBg
    $logFg      = Ensure-ContrastFg (Resolve-VsCodeColor $colors @("terminal.foreground", "editor.foreground") $textPri $logBg) @($logBg) 4.65

    # Semantic Hues from Terminal ANSI -> Git/Diagnostics -> TokenColors
    $tokStr = Get-VsCodeScopeColor $tokens @("string")
    $tokKw  = Get-VsCodeScopeColor $tokens @("keyword", "storage.type")
    $tokFn  = Get-VsCodeScopeColor $tokens @("entity.name.function", "support.function")
    $tokNum = Get-VsCodeScopeColor $tokens @("constant.numeric")
    $tokTyp = Get-VsCodeScopeColor $tokens @("entity.name.type", "support.type")

    $hueGreen   = Resolve-VsCodeColor $colors @("terminal.ansiGreen", "gitDecoration.addedResourceForeground", "charts.green") $(if ($tokStr) { $tokStr } else { "#22C55E" }) $surfaceBg
    $hueRed     = Resolve-VsCodeColor $colors @("terminal.ansiRed", "editorError.foreground", "gitDecoration.deletedResourceForeground", "charts.red") "#EF4444" $surfaceBg
    $hueYellow  = Resolve-VsCodeColor $colors @("terminal.ansiYellow", "editorWarning.foreground", "gitDecoration.modifiedResourceForeground", "charts.yellow") $(if ($tokNum) { $tokNum } else { "#EAB308" }) $surfaceBg
    $hueBlue    = Resolve-VsCodeColor $colors @("terminal.ansiBlue", "editorInfo.foreground", "charts.blue") $(if ($tokFn) { $tokFn } else { $accent }) $surfaceBg
    $hueCyan    = Resolve-VsCodeColor $colors @("terminal.ansiCyan", "terminal.ansiBrightCyan") $(if ($tokTyp) { $tokTyp } else { "#06B6D4" }) $surfaceBg
    $hueMagenta = Resolve-VsCodeColor $colors @("terminal.ansiMagenta", "terminal.ansiBrightMagenta", "charts.purple") $(if ($tokKw) { $tokKw } else { "#A855F7" }) $surfaceBg
    $hueOrange  = Resolve-VsCodeColor $colors @("charts.orange", "terminal.ansiBrightRed") (Mix-HexColors $hueRed $hueYellow 0.5) $surfaceBg

    $mixAmt     = if ($isDark) { 0.22 } else { 0.16 }
    $rowNewBg   = Mix-HexColors $surfaceBg $hueGreen $mixAmt
    $rowExitBg  = Mix-HexColors $surfaceBg $hueRed $mixAmt
    $rowSuspBg  = Mix-HexColors $surfaceBg $textMuted 0.18
    $rowCpuBg   = Mix-HexColors $surfaceBg $hueYellow $mixAmt
    $rowPkgBg   = Mix-HexColors $surfaceBg $hueCyan $mixAmt
    $rowSvcBg   = Mix-HexColors $surfaceBg $hueMagenta $mixAmt
    $rowOwnBg   = Mix-HexColors $surfaceBg $hueBlue $mixAmt

    $rowDefFg   = Ensure-ContrastFg $textPri @($surfaceBg) 4.65
    $rowNewFg   = Ensure-ContrastFg $(if ($isDark) { $hueGreen } else { $textPri }) @($rowNewBg) 4.65
    $rowExitFg  = Ensure-ContrastFg $(if ($isDark) { $hueRed } else { $textPri }) @($rowExitBg) 4.65
    $rowSuspFg  = Ensure-ContrastFg $textSec @($rowSuspBg) 4.65
    $rowCpuFg   = Ensure-ContrastFg $(if ($isDark) { $hueYellow } else { $textPri }) @($rowCpuBg) 4.65
    $rowPkgFg   = Ensure-ContrastFg $textPri @($rowPkgBg) 4.65
    $rowSvcFg   = Ensure-ContrastFg $textPri @($rowSvcBg) 4.65
    $rowOwnFg   = Ensure-ContrastFg $textPri @($rowOwnBg) 4.65

    $helpGreen  = Ensure-ContrastFg $hueGreen @($surfaceBg) 4.65
    $helpAmber  = Ensure-ContrastFg $hueYellow @($surfaceBg) 4.65
    $helpViolet = Ensure-ContrastFg $hueMagenta @($surfaceBg) 4.65
    $deltaGrow  = Ensure-ContrastFg $hueRed @($surfaceBg) 4.65
    $deltaShrk  = Ensure-ContrastFg $hueGreen @($surfaceBg) 4.65
    $deltaNew   = Ensure-ContrastFg $hueBlue @($surfaceBg) 4.65

    $killBg     = Mix-HexColors $surfaceBg $hueRed 0.24
    $killFg     = Ensure-ContrastFg $hueRed @($killBg) 4.65
    $killTreeBg = Ensure-ContrastBgForWhite (Mix-HexColors $hueRed "#7F1D1D" 0.45) 4.65
    $killTreeFg = "#FFFFFF"

    $svcRunBg   = Ensure-ContrastBgForWhite (Mix-HexColors $hueGreen "#0F5132" 0.45) 4.65
    $svcPauBg   = Ensure-ContrastBgForWhite (Mix-HexColors $hueYellow "#7C2D12" 0.55) 4.65
    $svcStpBg   = Ensure-ContrastBgForWhite (Mix-HexColors $borderSub "#334155" 0.55) 4.65

    $tabActBg   = Resolve-VsCodeColor $colors @("tab.activeBackground") $surfaceBg $surfaceBg
    $tabActBdr  = Resolve-VsCodeColor $colors @("tab.activeBorderTop", "tab.activeBorder") $accent $surfaceBg
    $tabActFg   = Ensure-ContrastFg (Resolve-VsCodeColor $colors @("tab.activeForeground") $textPri $tabActBg) @($tabActBg) 4.65
    $tabStbBg   = Resolve-VsCodeColor $colors @("tab.inactiveBackground") $windowBg $surfaceBg
    $tabStbBdr  = Resolve-VsCodeColor $colors @("tab.border") $borderSub $surfaceBg
    $tabStbFg   = Ensure-ContrastFg (Resolve-VsCodeColor $colors @("tab.inactiveForeground") $textMuted $tabStbBg) @($tabStbBg) 4.65

    $tcpBg = $rowOwnBg;  $tcpFg = Ensure-ContrastFg $hueBlue @($tcpBg) 4.65
    $udpBg = $rowPkgBg;  $udpFg = Ensure-ContrastFg $hueCyan @($udpBg) 4.65
    $estBg = $rowNewBg;  $estFg = Ensure-ContrastFg $hueGreen @($estBg) 4.65
    $lisBg = $headerBg;  $lisFg = Ensure-ContrastFg $textSec @($lisBg) 4.65
    $twBg  = $rowCpuBg;  $twFg  = Ensure-ContrastFg $hueOrange @($twBg) 4.65
    $nrNewBg = $rowNewBg;  $nrNewFg = $estFg
    $nrModBg = $rowCpuBg;  $nrModFg = Ensure-ContrastFg $hueYellow @($nrModBg) 4.65
    $nrDelBg = $rowExitBg; $nrDelFg = Ensure-ContrastFg $hueRed @($nrDelBg) 4.65

    $areaAlpha = if ($isDark) { 0x55 } else { 0x99 }
    $miniAlpha = if ($isDark) { 0x44 } else { 0x33 }
    $tintAlpha = if ($isDark) { 0x16 } else { 0x20 }

    return @{
        Name        = "VSC_$cleanName"
        DisplayName = "VS Code: $rawName"
        IsDark      = $isDark
        BaseTheme   = if ($isDark) { "Dark" } else { "Light" }
        Brushes     = @{
            BrushWindowBg          = $windowBg
            BrushToolbarBg         = $toolbarBg
            BrushSurfaceBg         = $surfaceBg
            BrushHeaderBg          = $headerBg
            BrushBorderSubtle      = $borderSub
            BrushTreeLine          = $treeLine
            BrushTextPrimary       = $textPri
            BrushTextSecondary     = $textSec
            BrushTextMuted         = $textMuted
            BrushRowHover          = $rowHover
            BrushRowSelectedBg     = $rowSelBg
            BrushRowSelectedFg     = $rowSelFg
            BrushSparkBg           = $logBg
            BrushSparkBorder       = $borderSub
            BrushSparkGrid         = $borderSub
            BrushMenuBg            = $menuBg
            BrushMenuBorder        = $menuBorder
            BrushMenuHover         = $menuHover
            BrushAccent            = $accent
            BrushBadgeBg           = $badgeBg
            BrushBadgeFg           = $badgeFg
            BrushHelpSuccessFg     = $helpGreen
            BrushHelpAmberFg       = $helpAmber
            BrushHelpVioletFg      = $helpViolet
            ColTint_CPU            = (Set-HexAlpha $hueGreen $tintAlpha)
            ColTint_Net            = (Set-HexAlpha $hueBlue $tintAlpha)
            ColTint_PrivateBytes   = (Set-HexAlpha $hueYellow $tintAlpha)
            ColTint_WorkingSet     = (Set-HexAlpha $hueOrange $tintAlpha)
            BrushLogBg             = $logBg
            BrushLogHeaderBg       = $headerBg
            BrushLogBorder         = $borderSub
            BrushLogFg             = $logFg
            BrushLogTitleFg        = $textPri
            BrushLogBtnBg          = $borderSub
            BrushLogBtnFg          = $textPri
            BrushLogTelem1         = Ensure-ContrastFg $hueBlue @($logBg) 4.5
            BrushLogTelem2         = Ensure-ContrastFg $hueCyan @($logBg) 4.5
            BrushLogTelem3         = Ensure-ContrastFg $hueYellow @($logBg) 4.5
            BrushLogTelem4         = Ensure-ContrastFg $hueMagenta @($logBg) 4.5
            BrushTargetNodeBg      = $rowOwnBg
            BrushKillBg            = $killBg
            BrushKillFg            = $killFg
            BrushKillBorder        = $hueRed
            BrushKillTreeBg        = $killTreeBg
            BrushKillTreeFg        = $killTreeFg
            BrushKillTreeBorder    = $hueRed
            BrushSwatchSvcBg       = $rowSvcBg
            BrushSwatchSvcBorder   = $hueMagenta
            BrushSwatchSvcFg       = $rowSvcFg
            BrushSwatchOwnBg       = $rowOwnBg
            BrushSwatchOwnBorder   = $hueBlue
            BrushSwatchOwnFg       = $rowOwnFg
            BrushSwatchPkgBg       = $rowPkgBg
            BrushSwatchPkgBorder   = $hueCyan
            BrushSwatchPkgFg       = $rowPkgFg
            BrushSwatchSuspBg      = $rowSuspBg
            BrushSwatchSuspBorder  = $treeLine
            BrushSwatchSuspFg      = $rowSuspFg
            BrushSwatchNewBg       = $rowNewBg
            BrushSwatchNewBorder   = $hueGreen
            BrushSwatchNewFg       = $rowNewFg
            BrushSwatchExitBg      = $rowExitBg
            BrushSwatchExitBorder  = $hueRed
            BrushSwatchExitFg      = $rowExitFg
            BrushNetRxStroke       = $hueBlue
            BrushNetRxFill         = (Set-HexAlpha $hueBlue 0x44)
            BrushNetTxStroke       = $hueCyan
            BrushNetTxFill         = (Set-HexAlpha $hueCyan 0x44)
            BrushDeltaGrowthFg     = $deltaGrow
            BrushDeltaShrinkFg     = $deltaShrk
            BrushDeltaNewFg        = $deltaNew
            BrushBadgeTcpBg        = $tcpBg
            BrushBadgeTcpFg        = $tcpFg
            BrushBadgeUdpBg        = $udpBg
            BrushBadgeUdpFg        = $udpFg
            BrushStateEstBg        = $estBg
            BrushStateEstFg        = $estFg
            BrushStateListenBg     = $lisBg
            BrushStateListenFg     = $lisFg
            BrushStateTimeWaitBg   = $twBg
            BrushStateTimeWaitFg   = $twFg
            BrushNetRowNewBg       = $nrNewBg
            BrushNetRowNewFg       = $nrNewFg
            BrushNetRowModBg       = $nrModBg
            BrushNetRowModFg       = $nrModFg
            BrushNetRowDelBg       = $nrDelBg
            BrushNetRowDelFg       = $nrDelFg
            BrushGaugeCpuFill      = $hueGreen
            BrushGaugeCpuArea      = (Set-HexAlpha $hueGreen $areaAlpha)
            BrushGaugeCpuStroke    = $hueGreen
            BrushGaugeKernelFill   = $hueRed
            BrushGaugeKernelArea   = (Set-HexAlpha $hueRed $areaAlpha)
            BrushGaugeKernelStroke = $hueRed
            BrushGaugeCommitFill   = $hueYellow
            BrushGaugeCommitArea   = (Set-HexAlpha $hueYellow $areaAlpha)
            BrushGaugeCommitStroke = $hueYellow
            BrushGaugeRamFill      = $hueOrange
            BrushGaugeRamArea      = (Set-HexAlpha $hueOrange $areaAlpha)
            BrushGaugeRamStroke    = $hueOrange
            BrushGaugeIoReadFill   = $hueBlue
            BrushGaugeIoReadArea   = (Set-HexAlpha $hueBlue $areaAlpha)
            BrushGaugeIoReadStroke = $hueBlue
            BrushGaugeIoWriteArea  = (Set-HexAlpha $hueMagenta $areaAlpha)
            BrushGaugeIoWriteStroke= $hueMagenta
            BrushMiniCpuFill       = (Set-HexAlpha $hueGreen $miniAlpha)
            BrushMiniCommitFill    = (Set-HexAlpha $hueYellow $miniAlpha)
            BrushMiniRamFill       = (Set-HexAlpha $hueOrange $miniAlpha)
            BrushSigSignedFg       = $deltaShrk
            BrushSigUnsignedFg     = $deltaGrow
            BrushStatusActiveFg    = $deltaShrk
            BrushStatusIdleFg      = $textMuted
            BrushStatusExitedFg    = $deltaGrow
            BrushSvcRunningBg      = $svcRunBg
            BrushSvcPausedBg       = $svcPauBg
            BrushSvcStoppedBg      = $svcStpBg
        }
        Rows = @{
            Default   = @{ Bg = $surfaceBg; Fg = $rowDefFg }
            New       = @{ Bg = $rowNewBg;  Fg = $rowNewFg }
            Exiting   = @{ Bg = $rowExitBg; Fg = $rowExitFg }
            Suspended = @{ Bg = $rowSuspBg; Fg = $rowSuspFg }
            HighCPU   = @{ Bg = $rowCpuBg;  Fg = $rowCpuFg }
            Packaged  = @{ Bg = $rowPkgBg;  Fg = $rowPkgFg }
            Service   = @{ Bg = $rowSvcBg;  Fg = $rowSvcFg }
            Own       = @{ Bg = $rowOwnBg;  Fg = $rowOwnFg }
        }
        TabColors = @{
            ActiveBg      = $tabActBg
            ActiveBorder  = $tabActBdr
            ActiveFg      = $tabActFg
            StandbyBg     = $tabStbBg
            StandbyBorder = $tabStbBdr
            StandbyFg     = $tabStbFg
            BadgeLocalBg  = $svcRunBg
            BadgeWinRmBg  = $badgeBg
        }
        Legend = @{
            AllActiveBorder = $accent
            AllIdleBorder   = $treeLine
            Service  = @{ Bg = $rowSvcBg; Border = $hueMagenta; ActiveBg = (Mix-HexColors $rowSvcBg $hueMagenta 0.20); ActiveBorder = $hueMagenta; ActiveText = $helpViolet; Fg = $rowSvcFg }
            Own      = @{ Bg = $rowOwnBg; Border = $hueBlue;    ActiveBg = (Mix-HexColors $rowOwnBg $hueBlue 0.20);    ActiveBorder = $hueBlue;    ActiveText = $accent;     Fg = $rowOwnFg }
            Packaged = @{ Bg = $rowPkgBg; Border = $hueCyan;    ActiveBg = (Mix-HexColors $rowPkgBg $hueCyan 0.20);    ActiveBorder = $hueCyan;    ActiveText = $hueCyan;    Fg = $rowPkgFg }
        }
        Banner = @{
            Cap2   = @{ Bg = $rowCpuBg;  Border = $hueYellow; BadgeBg = $svcPauBg;   Fg = $textPri; MutedFg = $helpAmber; BtnBg = $headerBg; BtnFg = $textPri }
            Cap3   = @{ Bg = $rowOwnBg;  Border = $hueBlue;   BadgeBg = $badgeBg;    Fg = $textPri; MutedFg = $accent }
            CapErr = @{ Bg = $rowExitBg; Border = $hueRed;    BadgeBg = $killTreeBg; Fg = $textPri; MutedFg = $killFg }
        }
    }
}

function Get-ThemeContrastReport {
    param([hashtable]$Palette)
    $b = $Palette.Brushes
    $rows = [System.Collections.Generic.List[Object]]::new()

    $addCheck = {
        param([string]$cat, [string]$fgName, [string]$fgHex, [string]$bgName, [string]$bgHex)
        $ratio = Get-ContrastRatio $fgHex $bgHex
        $pass = ($ratio -ge 4.5)
        [void]$rows.Add([PSCustomObject]@{
            Category   = $cat
            FgToken    = $fgName
            FgHex      = $fgHex
            BgToken    = $bgName
            BgHex      = $bgHex
            RatioNum   = [Math]::Round($ratio, 2)
            RatioText  = ('{0:N2} : 1' -f $ratio)
            Status     = if ($pass) { "PASS" } else { "FAIL (<4.5)" }
            IsPass     = $pass
            StatusBg   = if ($pass) { [string]$b["BrushStateEstBg"] } else { [string]$b["BrushKillBg"] }
            StatusFg   = if ($pass) { [string]$b["BrushStateEstFg"] } else { [string]$b["BrushKillFg"] }
        })
    }

    foreach ($bgKey in @("BrushWindowBg", "BrushToolbarBg", "BrushSurfaceBg")) {
        foreach ($fgKey in @("BrushTextPrimary", "BrushTextSecondary", "BrushTextMuted", "BrushAccent")) {
            &$addCheck "Core UI" $fgKey ([string]$b[$fgKey]) $bgKey ([string]$b[$bgKey])
        }
    }
    foreach ($helpKey in @("BrushHelpSuccessFg", "BrushHelpAmberFg", "BrushHelpVioletFg")) {
        &$addCheck "Help Shortcuts" $helpKey ([string]$b[$helpKey]) "BrushSurfaceBg" ([string]$b["BrushSurfaceBg"])
    }
    foreach ($deltaKey in @("BrushDeltaGrowthFg", "BrushDeltaShrinkFg", "BrushDeltaNewFg")) {
        &$addCheck "Baseline Delta" $deltaKey ([string]$b[$deltaKey]) "BrushSurfaceBg" ([string]$b["BrushSurfaceBg"])
    }
    foreach ($pair in @(
        @("Selection", "BrushRowSelectedFg", "BrushRowSelectedBg"),
        @("Badge", "BrushBadgeFg", "BrushBadgeBg"),
        @("Kill Action", "BrushKillFg", "BrushKillBg"),
        @("Kill Tree", "BrushKillTreeFg", "BrushKillTreeBg"),
        @("Net TCP Badge", "BrushBadgeTcpFg", "BrushBadgeTcpBg"),
        @("Net UDP Badge", "BrushBadgeUdpFg", "BrushBadgeUdpBg"),
        @("Net Established", "BrushStateEstFg", "BrushStateEstBg"),
        @("Net Listening", "BrushStateListenFg", "BrushStateListenBg"),
        @("Net TimeWait", "BrushStateTimeWaitFg", "BrushStateTimeWaitBg"),
        @("Net Row New", "BrushNetRowNewFg", "BrushNetRowNewBg"),
        @("Net Row Mod", "BrushNetRowModFg", "BrushNetRowModBg"),
        @("Net Row Del", "BrushNetRowDelFg", "BrushNetRowDelBg")
    )) {
        &$addCheck $pair[0] $pair[1] ([string]$b[$pair[1]]) $pair[2] ([string]$b[$pair[2]])
    }
    foreach ($svcKey in @("BrushSvcRunningBg", "BrushSvcPausedBg", "BrushSvcStoppedBg")) {
        &$addCheck "Service Badge" "#FFFFFF (Text)" "#FFFFFF" $svcKey ([string]$b[$svcKey])
    }
    foreach ($rowTier in @("Default", "New", "Exiting", "Suspended", "HighCPU", "Packaged", "Service", "Own")) {
        $pair = $Palette.Rows[$rowTier]
        if ($pair) {
            &$addCheck "Process Row" "Rows.$rowTier.Fg" ([string]$pair.Fg) "Rows.$rowTier.Bg" ([string]$pair.Bg)
        }
    }
    &$addCheck "Host Tab" "TabColors.ActiveFg" ([string]$Palette.TabColors.ActiveFg) "TabColors.ActiveBg" ([string]$Palette.TabColors.ActiveBg)
    &$addCheck "Host Tab" "TabColors.StandbyFg" ([string]$Palette.TabColors.StandbyFg) "TabColors.StandbyBg" ([string]$Palette.TabColors.StandbyBg)

    $failCount = @($rows | Where-Object { -not $_.IsPass }).Count
    $minRatio = ($rows | Measure-Object -Property RatioNum -Minimum).Minimum
    return @{
        Items     = $rows
        FailCount = $failCount
        MinRatio  = $minRatio
    }
}

# ------------------------------------------------------------------
# 1. Load Real MainWindow.xaml & Inject Theme Sandbox Studio Bar
# ------------------------------------------------------------------
$mainXamlPath = Join-Path $uiDir "MainWindow.xaml"
$mBytes = [System.IO.File]::ReadAllBytes($mainXamlPath)
$msMain = [System.IO.MemoryStream]::new($mBytes)
$window = [System.Windows.Markup.XamlReader]::Load($msMain)
$msMain.Close()

$window.Title = "PSRPM Theme Sandbox - Visual Token & Palette Tester"
if ($appIconFrame) { $window.Icon = $appIconFrame }

$rootDock = $window.Content
if (-not ($rootDock -is [System.Windows.Controls.DockPanel])) {
    throw "Expected MainWindow root content to be a DockPanel."
}

$sandboxBarXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="ThemeSandboxBar" DockPanel.Dock="Top"
        Background="{DynamicResource BrushToolbarBg}"
        BorderBrush="{DynamicResource BrushAccent}"
        BorderThickness="0,0,0,2"
        Padding="8,5">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Row 1: Theme Pills & Custom JSON File Controls -->
        <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,4">
            <Border DockPanel.Dock="Left" Background="{DynamicResource BrushBadgeBg}" CornerRadius="2" Padding="6,2" Margin="0,0,8,0" VerticalAlignment="Center">
                <TextBlock Text="THEME SANDBOX" Foreground="{DynamicResource BrushBadgeFg}" FontSize="9.5" FontWeight="Bold"/>
            </Border>

            <StackPanel x:Name="SandboxThemePills" DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,10,0"/>

            <Border DockPanel.Dock="Left" Width="1" Background="{DynamicResource BrushBorderSubtle}" Margin="2,2,8,2"/>

            <Button x:Name="BtnSbLoadJson" DockPanel.Dock="Left" Content="Load JSON..." Style="{DynamicResource ToolbarButtonStyle}" Padding="7,2" Margin="0,0,4,0" FontSize="11" ToolTip="Load a PSRPM or VS Code theme JSON/JSONC file to preview live"/>
            <Button x:Name="BtnSbLoadVsCode" DockPanel.Dock="Left" Content="VS Code..." Style="{DynamicResource ToolbarButtonStyle}" Padding="7,2" Margin="0,0,4,0" FontSize="11" ToolTip="Browse installed VS Code themes or import a VS Code theme JSON/JSONC file"/>
            <Button x:Name="BtnSbReloadJson" DockPanel.Dock="Left" Content="Reload (F5)" Style="{DynamicResource ToolbarButtonStyle}" Padding="7,2" Margin="0,0,6,0" FontSize="11" IsEnabled="False" ToolTip="Reload active custom JSON file from disk"/>
            <CheckBox x:Name="ChkSbWatch" DockPanel.Dock="Left" Content="Auto-Watch" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="11" Foreground="{DynamicResource BrushTextPrimary}" ToolTip="Automatically reload custom JSON whenever the file is saved"/>
            <Button x:Name="BtnSbExportJson" DockPanel.Dock="Left" Content="Export Starter JSON..." Style="{DynamicResource ToolbarButtonStyle}" Padding="7,2" Margin="0,0,8,0" FontSize="11" ToolTip="Export the current active theme palette as an editable JSON starter file"/>

            <TextBlock x:Name="TxtSbLoadedFile" DockPanel.Dock="Left" Text="Built-in registry mode" VerticalAlignment="Center" FontSize="10.5" Foreground="{DynamicResource BrushTextMuted}" TextTrimming="CharacterEllipsis" MaxWidth="280"/>
        </DockPanel>

        <!-- Row 2: State Simulation, Child Dialog Previews & WCAG Audit -->
        <DockPanel Grid.Row="1" LastChildFill="False">
            <TextBlock DockPanel.Dock="Left" Text="States:" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource BrushTextMuted}" VerticalAlignment="Center" Margin="0,0,5,0"/>
            <Button x:Name="BtnSbToggleFlash" DockPanel.Dock="Left" Content="Flash New/Exit: ON" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,4,0" FontSize="10.5" ToolTip="Toggle New (green) and Exiting (red) process flash rows"/>
            <Button x:Name="BtnSbCycleBanner" DockPanel.Dock="Left" Content="Banner: Cap2" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,4,0" FontSize="10.5" ToolTip="Cycle NetEtwAlertBanner states (Off / Cap2 / Cap3 / CapErr)"/>
            <Button x:Name="BtnSbTogglePaused" DockPanel.Dock="Left" Content="Paused: OFF" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,8,0" FontSize="10.5" ToolTip="Toggle Paused toolbar highlight and badge"/>

            <Border DockPanel.Dock="Left" Width="1" Background="{DynamicResource BrushBorderSubtle}" Margin="0,2,8,2"/>

            <TextBlock DockPanel.Dock="Left" Text="Dialogs:" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource BrushTextMuted}" VerticalAlignment="Center" Margin="0,0,5,0"/>
            <Button x:Name="BtnSbDlgSysInfo" DockPanel.Dock="Left" Content="SysInfo" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,3,0" FontSize="10.5"/>
            <Button x:Name="BtnSbDlgProps" DockPanel.Dock="Left" Content="Props" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,3,0" FontSize="10.5"/>
            <Button x:Name="BtnSbDlgSvc" DockPanel.Dock="Left" Content="SvcDetail" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,3,0" FontSize="10.5"/>
            <Button x:Name="BtnSbDlgConnect" DockPanel.Dock="Left" Content="Connect" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,3,0" FontSize="10.5"/>
            <Button x:Name="BtnSbDlgFind" DockPanel.Dock="Left" Content="FindHandle" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,3,0" FontSize="10.5"/>
            <Button x:Name="BtnSbDlgCols" DockPanel.Dock="Left" Content="Columns" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,3,0" FontSize="10.5"/>
            <Button x:Name="BtnSbDlgHelp" DockPanel.Dock="Left" Content="Help" Style="{DynamicResource ToolbarButtonStyle}" Padding="6,2" Margin="0,0,8,0" FontSize="10.5"/>

            <Button x:Name="BtnSbContrast" DockPanel.Dock="Right" Padding="8,2" Cursor="Hand" BorderThickness="1" ToolTip="Open WCAG 2.1 AA Contrast Auditor &amp; Full Token Palette Inspector">
                <TextBlock x:Name="TxtSbContrast" Text="WCAG AA: Checking..." FontSize="10.5" FontWeight="Bold"/>
            </Button>
        </DockPanel>
    </Grid>
</Border>
'@

$sbStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($sandboxBarXaml))
$sandboxBar = [System.Windows.Markup.XamlReader]::Load($sbStream)
$sbStream.Close()
$rootDock.Children.Insert(0, $sandboxBar)

# ------------------------------------------------------------------
# 2. Populate Realistic Sample Data Across Every UI Surface
# ------------------------------------------------------------------
$sumVm = [SystemSummaryViewModel]::new()
$sumVm.HwMachine           = "Dell PowerEdge R750 Theme Lab Node"
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

$sumVm.CpuHistory.Clear()
$sumVm.CommitHistory.Clear()
$sumVm.RamHistory.Clear()
for ($i = 0; $i -lt 30; $i++) {
    $sumVm.CpuHistory.Enqueue(([Math]::Sin($i * 0.3) * 22.0 + 44.0))
    $sumVm.CommitHistory.Enqueue(([Math]::Sin($i * 0.2) * 7.0 + 35.0))
    $sumVm.RamHistory.Enqueue(([Math]::Cos($i * 0.2) * 4.0 + 52.0))
}
$spCpu = $sumVm.BuildSparkline($sumVm.CpuHistory.ToArray(), 86.0, 26.0)
$spCom = $sumVm.BuildSparkline($sumVm.CommitHistory.ToArray(), 90.0, 26.0)
$spRam = $sumVm.BuildSparkline($sumVm.RamHistory.ToArray(), 96.0, 26.0)

$sumVm.CpuHistory240.Clear()
$sumVm.KernelHistory240.Clear()
$sumVm.CommitHistory240.Clear()
$sumVm.RamHistory240.Clear()
$sumVm.IoTotalHistory240.Clear()
$sumVm.IoWriteHistory240.Clear()
$sumVm.NetRxHistory240.Clear()
$sumVm.NetTxHistory240.Clear()
for ($i = 0; $i -lt 240; $i++) {
    $cVal = [Math]::Max(6.0, [Math]::Min(94.0, [Math]::Sin($i * 0.12) * 28.0 + [Math]::Cos($i * 0.28) * 12.0 + 45.0))
    $kVal = $cVal * 0.26
    $ioTot = ([Math]::Abs([Math]::Sin($i * 0.14)) * 28.0 + [Math]::Cos($i * 0.3) * 8.0 + 12.0) * 1048576.0
    $sumVm.CpuHistory240.Enqueue($cVal)
    $sumVm.KernelHistory240.Enqueue($kVal)
    $sumVm.CommitHistory240.Enqueue(([Math]::Sin($i * 0.08) * 10.0 + 38.0))
    $sumVm.RamHistory240.Enqueue(([Math]::Cos($i * 0.05) * 5.0 + 52.0))
    $sumVm.IoTotalHistory240.Enqueue($ioTot)
    $sumVm.IoWriteHistory240.Enqueue(($ioTot * 0.42))
    [void]$sumVm.NetRxHistory240.Enqueue([Math]::Max(120.0, [Math]::Sin($i * 0.14) * 620.0 + 1180.0))
    [void]$sumVm.NetTxHistory240.Enqueue([Math]::Max(40.0, [Math]::Cos($i * 0.11) * 210.0 + 420.0))
}

while ($sumVm.CoreGraphs.Count -lt 16) {
    $sumVm.CoreGraphs.Add([CpuCoreGraphViewModel]::new($sumVm.CoreGraphs.Count))
}
for ($c = 0; $c -lt 16; $c++) {
    $cg = $sumVm.CoreGraphs[$c]
    $cg.TotalHistory.Clear()
    $cg.KernelHistory.Clear()
    $phase = $c * 0.45
    for ($s = 0; $s -lt 60; $s++) {
        $cLoad = [Math]::Max(4.0, [Math]::Min(96.0, [Math]::Sin(($s * 0.16) + $phase) * 32.0 + [Math]::Cos(($s * 0.38) + $phase) * 14.0 + 48.0))
        $cg.EnqueueSample($cLoad, ($cLoad * 0.24), $false)
    }
    $cg.BuildCoreGeometry()
}

$sumVm.UpdateSummary(48.2, 34078L, 65536L, 18, 1840, 42850, 30856L, 81200L)
$sumVm.CpuPoints        = $spCpu[0]
$sumVm.CpuFillPoints    = $spCpu[1]
$sumVm.CommitPoints     = $spCom[0]
$sumVm.CommitFillPoints = $spCom[1]
$sumVm.RamPoints        = $spRam[0]
$sumVm.RamFillPoints    = $spRam[1]
$sumVm.SessionNetRxBytes = 42860544.0
$sumVm.SessionNetTxBytes = 14820112.0
$sumVm.IsSysInfoOpen = $true
$sumVm.UpdateExtendedTelemetry(@(
    48.2, 34078, 65536, 18, 1840, 42850, 30856, 81200,
    12.5, 31596544, 83148800, 42400000, 67108864, 32213760,
    14840000, 421888, 290816, 1240, 184, 42, 12, 14820, 4180,
    32450, 24800000, 12400000, 1200000, 1420.0, 480.0, 3240.0, 1510.0, 4
), $null)

$summaryBar = $window.FindName("SummaryBar")
if ($summaryBar) { $summaryBar.DataContext = $sumVm }

# Host Tabs (Active WINRM, Standby LOCAL, Standby WINRM-SSL)
$hostTabs = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$tab1 = [HostTabItemViewModel]::new("t1", "SRV-PROD-01", "SRV-PROD-01", "WINRM", $false, $sumVm)
$tab2 = [HostTabItemViewModel]::new("t2", "WKSTN-LOCAL-01", "WKSTN-LOCAL-01", "LOCAL", $true, $null)
$tab3 = [HostTabItemViewModel]::new("t3", "DMZ-GATEWAY-02", "DMZ-GATEWAY-02", "WINRM-SSL", $false, $null)
[void]$hostTabs.Add($tab1)
[void]$hostTabs.Add($tab2)
[void]$hostTabs.Add($tab3)

$hostTabsList = $window.FindName("HostTabsList")
if ($hostTabsList) { $hostTabsList.ItemsSource = $hostTabs }

# Process Tree Dataset covering ALL 8 semantic row categories + Tree Geometry + Deltas
$procSpecs = @(
    @{ id = 4;     p = 0;     lvl = 0; exp = $true;  hc = $true;  g = "";    st = "Running";   life = 0; cat = "System";   n = "System";              u = "NT AUTHORITY\SYSTEM";      ws = 14800000;  pb = 240000;    cpu = 0.35;  rx = 0;      tx = 0;      svc = "";                        desc = "NT Kernel & System" }
    @{ id = 468;   p = 4;     lvl = 1; exp = $true;  hc = $true;  g = "L";   st = "Running";   life = 0; cat = "System";   n = "smss.exe";            u = "NT AUTHORITY\SYSTEM";      ws = 1420000;   pb = 480000;    cpu = 0.00;  rx = 0;      tx = 0;      svc = "";                        desc = "Session Manager Subsystem" }
    @{ id = 724;   p = 468;   lvl = 2; exp = $true;  hc = $true;  g = "T";   st = "Running";   life = 0; cat = "System";   n = "wininit.exe";         u = "NT AUTHORITY\SYSTEM";      ws = 4920000;   pb = 1840000;   cpu = 0.00;  rx = 0;      tx = 0;      svc = "";                        desc = "Windows Start-Up Application" }
    @{ id = 836;   p = 724;   lvl = 3; exp = $true;  hc = $true;  g = "T";   st = "Running";   life = 0; cat = "Service";  n = "services.exe";        u = "NT AUTHORITY\SYSTEM";      ws = 12480000;  pb = 8920000;   cpu = 0.12;  rx = 0;      tx = 0;      svc = "";                        desc = "Services and Controller app" }
    @{ id = 1024;  p = 836;   lvl = 4; exp = $false; hc = $false; g = "T";   st = "Running";   life = 0; cat = "Service";  n = "svchost.exe";         u = "NT AUTHORITY\SYSTEM";      ws = 28400000;  pb = 14200000;  cpu = 0.08;  rx = 18400;  tx = 6200;   svc = "DcomLaunch, PlugPlay";    desc = "Host Process for Windows Services" }
    @{ id = 2840;  p = 836;   lvl = 4; exp = $false; hc = $false; g = "T";   st = "Running";   life = 0; cat = "Service";  n = "MsMpEng.exe";         u = "NT AUTHORITY\SYSTEM";      ws = 168400000; pb = 142000000; cpu = 0.42;  rx = 4200;   tx = 1100;   svc = "WinDefend";               desc = "Antimalware Service Executable" }
    @{ id = 3680;  p = 836;   lvl = 4; exp = $false; hc = $false; g = "L";   st = "Running";   life = 0; cat = "Service";  n = "sqlservr.exe";        u = "NT SERVICE\MSSQLSERVER";   ws = 448000000; pb = 612000000; cpu = 4.84;  rx = 842000; tx = 310000; svc = "MSSQLSERVER";             desc = "SQL Server Windows NT - 64 Bit" }
    @{ id = 848;   p = 724;   lvl = 3; exp = $false; hc = $false; g = "L";   st = "Running";   life = 0; cat = "System";   n = "lsass.exe";           u = "NT AUTHORITY\SYSTEM";      ws = 38400000;  pb = 22100000;  cpu = 0.06;  rx = 12400;  tx = 8900;   svc = "SamSs, VaultSvc";         desc = "Local Security Authority Process" }
    @{ id = 912;   p = 468;   lvl = 2; exp = $true;  hc = $true;  g = "L";   st = "Running";   life = 0; cat = "System";   n = "winlogon.exe";        u = "NT AUTHORITY\SYSTEM";      ws = 11200000;  pb = 5400000;   cpu = 0.00;  rx = 0;      tx = 0;      svc = "";                        desc = "Windows Logon Application" }
    @{ id = 4820;  p = 912;   lvl = 3; exp = $true;  hc = $true;  g = "L";   st = "Running";   life = 0; cat = "Own";      n = "explorer.exe";        u = "CONTOSO\svc-monitor";      ws = 124000000; pb = 88000000;  cpu = 0.72;  rx = 0;      tx = 0;      svc = "";                        desc = "Windows Explorer" }
    @{ id = 6812;  p = 4820;  lvl = 4; exp = $false; hc = $false; g = "T";   st = "Running";   life = 0; cat = "Own";      n = "msedge.exe";          u = "CONTOSO\svc-monitor";      ws = 198000000; pb = 142000000; cpu = 1.45;  rx = 512000; tx = 96000;  svc = "";                        desc = "Microsoft Edge Browser" }
    @{ id = 9450;  p = 4820;  lvl = 4; exp = $true;  hc = $true;  g = "T";   st = "Running";   life = 0; cat = "Own";      n = "Code.exe";            u = "CONTOSO\svc-monitor";      ws = 214000000; pb = 164000000; cpu = 0.55;  rx = 24000;  tx = 12000;  svc = "";                        desc = "Visual Studio Code" }
    @{ id = 10840; p = 9450;  lvl = 5; exp = $false; hc = $false; g = "T";   st = "Running";   life = 0; cat = "Own";      n = "dotnet.exe";          u = "CONTOSO\svc-monitor";      ws = 312000000; pb = 285000000; cpu = 68.40; rx = 0;      tx = 0;      svc = "";                        desc = "High-CPU Build Worker (>50% CPU Tier)" }
    @{ id = 10990; p = 9450;  lvl = 5; exp = $false; hc = $false; g = "T";   st = "Running";   life = 1; cat = "Own";      n = "pwsh.exe";            u = "CONTOSO\svc-monitor";      ws = 72100000;  pb = 52400000;  cpu = 0.40;  rx = 1800;   tx = 900;    svc = "";                        desc = "Newly Spawned Process (New Flash Tier)" }
    @{ id = 10995; p = 9450;  lvl = 5; exp = $false; hc = $false; g = "L";   st = "Exiting";   life = 2; cat = "Own";      n = "robocopy.exe";        u = "CONTOSO\svc-monitor";      ws = 16400000;  pb = 8200000;   cpu = 0.00;  rx = 0;      tx = 0;      svc = "";                        desc = "Terminating Process (Exiting Flash Tier)" }
    @{ id = 11200; p = 4820;  lvl = 4; exp = $false; hc = $false; g = "T";   st = "Running";   life = 0; cat = "Packaged"; n = "WindowsTerminal.exe"; u = "CONTOSO\svc-monitor";      ws = 78400000;  pb = 48200000;  cpu = 0.12;  rx = 0;      tx = 0;      svc = "";                        desc = "Windows Terminal (Packaged / UWP Tier)" }
    @{ id = 11450; p = 4820;  lvl = 4; exp = $false; hc = $false; g = "L";   st = "Suspended"; life = 0; cat = "Own";      n = "notepad.exe";         u = "CONTOSO\svc-monitor";      ws = 24800000;  pb = 11200000;  cpu = 0.00;  rx = 0;      tx = 0;      svc = "";                        desc = "Suspended Process (Suspended Tier)" }
)

$procVms = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$flashVms = [System.Collections.Generic.List[ProcessItemViewModel]]::new()

foreach ($sp in $procSpecs) {
    $vm = [ProcessItemViewModel]::new()
    $vm.SetStaticMetadata(@{
        id    = $sp.id
        ct    = 134076000000000000L + $sp.id
        n     = $sp.n
        desc  = $sp.desc
        comp  = "Microsoft Corporation"
        ver   = "10.0.20348.2405"
        cmd   = "$($sp.n) --sample-theme-sandbox"
        path  = "C:\Windows\System32\$($sp.n)"
        u     = $sp.u
        sid   = 1
        arch  = "x64"
        start = "2026-11-15 16:00:00"
        prio  = 8
        p     = $sp.p
        cat   = $sp.cat
    }, $false)
    $dynFlags = if ($sp.st -eq "Suspended") { 1 } else { 0 }
    $vm.UpdateDynamic([double]$sp.cpu, [long]$sp.ws, [long]$sp.pb, 16, 420, $dynFlags)
    $vm.HostedServices = [string]$sp.svc
    $vm.UpdateTreeCpu([double]$sp.cpu)
    $vm.UpdateNetwork([long]$sp.rx, [long]$sp.tx)
    $vm.UpdateTreeNetwork([long]$sp.rx, [long]$sp.tx)

    $guide = switch ($sp.g) {
        "T" { "M 7.5,0 L 7.5,22 M 7.5,11 L 16,11" }
        "L" { "M 7.5,0 L 7.5,11 L 16,11" }
        default { "" }
    }
    $vm.IsExpanded = [bool]$sp.exp
    $vm.UpdateTreeState([int]$sp.lvl, $true, [bool]$sp.hc, $guide, 1.0)
    $vm.FallbackIconVisibility = "Visible"
    if ($sp.life -gt 0) {
        $vm.SetLifecycleState($sp.life)
        [void]$flashVms.Add($vm)
    }
    if ($sp.id -eq 3680) {
        $vm.SetBaselineState($true, $false, 580000000L, 460000000L, 400, 2.10)
        $vm.UpdateBaselineDiffs()
    } elseif ($sp.id -eq 6812) {
        $vm.SetBaselineState($true, $false, 168000000L, 210000000L, 450, 4.25)
        $vm.UpdateBaselineDiffs()
    } elseif ($sp.id -eq 10990) {
        $vm.SetBaselineState($true, $true, 0L, 0L, 0, 0.0)
        $vm.UpdateBaselineDiffs()
    }
    [void]$procVms.Add($vm)
}

$gridProcs = $window.FindName("GridProcesses")
if ($gridProcs) {
    $gridProcs.ItemsSource = $procVms
    $gridProcs.SelectedIndex = 0
}

# Services Tab Dataset
$svcVms = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$svcSamples = @(
    @("WinDefend",   "Microsoft Defender Antivirus Service", 2840, "Running", "Automatic", "LocalSystem",    "RpcSs",          "None", "Helps protect users from malware and unwanted software", "C:\Program Files\Windows Defender\MsMpEng.exe"),
    @("MSSQLSERVER", "SQL Server (MSSQLSERVER)",             3680, "Running", "Automatic", "NT SERVICE\MSSQLSERVER", "Tcpip",   "SQLSERVERAGENT", "Provides storage, processing and controlled access of data", "C:\Program Files\Microsoft SQL Server\MSSQL16\Binn\sqlservr.exe"),
    @("BITS",        "Background Intelligent Transfer",      1024, "Paused",  "Manual",    "LocalSystem",    "RpcSs, EventSystem", "wuauserv", "Transfers files in the background using idle network bandwidth", "C:\Windows\System32\svchost.exe -k netsvcs"),
    @("Spooler",     "Print Spooler",                        0,    "Stopped", "Disabled",  "LocalSystem",    "RPCSS",          "None", "This service spools print jobs and handles interaction with the printer", "C:\Windows\System32\spoolsv.exe")
)
foreach ($ss in $svcSamples) {
    $svm = [ServiceItemViewModel]::new()
    $svm.UpdateService($ss[0], $ss[1], [int]$ss[2], $ss[3], $ss[4], $ss[5], $ss[6], $ss[7], $ss[8], $ss[9])
    [void]$svcVms.Add($svm)
}
$gridSvcs = $window.FindName("GridServices")
if ($gridSvcs) {
    $gridSvcs.ItemsSource = $svcVms
    $gridSvcs.SelectedIndex = 0
}
$txtSvcSummary = $window.FindName("TxtSvcSummary")
if ($txtSvcSummary) { $txtSvcSummary.Text = "Services: 4 total | 2 Running | 1 Paused | 1 Stopped" }

# Network Activity Tab Dataset (Sockets + Timeline)
$netSocketSamples = @(
    @{ Proc = "msedge.exe";  Pid = 6812;  Proto = "TCP4"; State = "ESTABLISHED"; LAddr = "10.12.4.48";  LPort = 54120; RAddr = "140.82.114.4";  RPort = 443;  Time = "16:38:12"; Mod = "WINHTTP.dll";  SP = 412;  RP = 1284; SB = "48.2 KB";  RB = "1.4 MB";  Life = "" },
    @{ Proc = "sqlservr.exe";Pid = 3680;  Proto = "TCP6"; State = "LISTENING";   LAddr = "::";          LPort = 1433;  RAddr = "::";            RPort = 0;    Time = "16:00:05"; Mod = "sqllang.dll";  SP = 0;    RP = 0;    SB = "0 B";      RB = "0 B";     Life = "" },
    @{ Proc = "pwsh.exe";    Pid = 10990; Proto = "TCP4"; State = "ESTABLISHED"; LAddr = "10.12.4.48";  LPort = 55012; RAddr = "10.12.0.15";    RPort = 5985; Time = "16:45:01"; Mod = "wsman.dll";    SP = 18;   RP = 22;   SB = "6.4 KB";   RB = "14.2 KB"; Life = "New" },
    @{ Proc = "svchost.exe"; Pid = 1024;  Proto = "UDP4"; State = "TIME_WAIT";   LAddr = "10.12.4.48";  LPort = 5353;  RAddr = "224.0.0.251";   RPort = 5353; Time = "16:44:40"; Mod = "dnsrslvr.dll"; SP = 64;   RP = 41;   SB = "9.1 KB";   RB = "4.8 KB";  Life = "Mod" },
    @{ Proc = "robocopy.exe";Pid = 10995; Proto = "TCP4"; State = "CLOSE_WAIT";  LAddr = "10.12.4.48";  LPort = 54880; RAddr = "10.12.9.20";    RPort = 445;  Time = "16:41:19"; Mod = "mpr.dll";      SP = 920;  RP = 140;  SB = "12.4 MB";  RB = "98.0 KB"; Life = "Del" }
)

$netSocketsCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
foreach ($ns in $netSocketSamples) {
    $item = [PSCustomObject]@{
        ProcessName          = $ns.Proc
        PID                  = $ns.Pid
        PIDDisplay           = [string]$ns.Pid
        IconSource           = $appIconFrame
        Protocol             = $ns.Proto
        ProtocolBg           = "#E0F2FE"
        ProtocolFg           = "#075985"
        State                = $ns.State
        StateBg              = "#DCFCE7"
        StateFg              = "#166534"
        LocalAddress         = $ns.LAddr
        LocalPort            = $ns.LPort
        LocalPortDisplay     = [string]$ns.LPort
        RemoteAddress        = $ns.RAddr
        RemotePort           = $ns.RPort
        RemotePortDisplay    = if ($ns.RPort -gt 0) { [string]$ns.RPort } else { "*" }
        CreateTime           = $ns.Time
        CreateTimestamp      = $ns.Pid
        ModuleName           = $ns.Mod
        SentPackets          = $ns.SP
        SentPacketsFormatted = [string]$ns.SP
        RecvPackets          = $ns.RP
        RecvPacketsFormatted = [string]$ns.RP
        SentBytes            = 1024
        SentBytesFormatted   = $ns.SB
        RecvBytes            = 2048
        RecvBytesFormatted   = $ns.RB
        LifecycleState       = $ns.Life
    }
    [void]$netSocketsCol.Add($item)
}
$gridNetSockets = $window.FindName("GridNetworkSockets")
if ($gridNetSockets) { $gridNetSockets.ItemsSource = $netSocketsCol }

$netTimelineCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
foreach ($nt in @(
    @{ T = "16:45:01.14"; Proc = "msedge.exe";   Pid = 6812;  Op = "TCP Recv"; Detail = "140.82.114.4:443 (1,420 B)"; Rate = "482.1 KB/s"; TRate = "512.0 KB/s"; Tot = "14.2 MB"; Cat = "Own";     U = "CONTOSO\svc-monitor" },
    @{ T = "16:45:01.28"; Proc = "sqlservr.exe"; Pid = 3680;  Op = "TCP Send"; Detail = "10.12.4.19:51204 (840 B)";   Rate = "218.4 KB/s"; TRate = "218.4 KB/s"; Tot = "6.8 MB";  Cat = "Service"; U = "NT SERVICE\MSSQLSERVER" },
    @{ T = "16:45:01.55"; Proc = "pwsh.exe";     Pid = 10990; Op = "TCP Recv"; Detail = "10.12.0.15:5985 (1,120 B)";  Rate = "1.8 KB/s";   TRate = "1.8 KB/s";   Tot = "18.4 KB"; Cat = "Own";     U = "CONTOSO\svc-monitor" }
)) {
    [void]$netTimelineCol.Add([PSCustomObject]@{
        TimeText              = $nt.T
        TimestampTicks        = $nt.Pid
        IconSource            = $appIconFrame
        ProcessName           = $nt.Proc
        PID                   = $nt.Pid
        Operation             = $nt.Op
        OperationBg           = "#440284C7"
        OperationFg           = "#0284C7"
        Detail                = $nt.Detail
        RateBps               = 1024
        RateFormatted         = $nt.Rate
        TreeRateBps           = 1024
        TreeRateFormatted     = $nt.TRate
        SessionBytes          = 1024
        SessionTotalFormatted = $nt.Tot
        Category              = $nt.Cat
        User                  = $nt.U
    })
}
$gridNetTimeline = $window.FindName("GridNetworkTimeline")
if ($gridNetTimeline) { $gridNetTimeline.ItemsSource = $netTimelineCol }

$txtNetSummary = $window.FindName("TxtNetActivitySummary")
if ($txtNetSummary) { $txtNetSummary.Text = "Sample Snapshot: 5 Active Sockets | 3 ETW Events" }
$txtNetCounts = $window.FindName("TxtNetStatusCounts")
if ($txtNetCounts) { $txtNetCounts.Text = "Endpoints: 5  |  Established: 2  |  Listening: 1  |  Time Wait: 1  |  Close Wait: 1" }

# Status Bar & Log Console Sample Content
$txtTargetBadge = $window.FindName("TxtTargetBadge")
if ($txtTargetBadge) { $txtTargetBadge.Text = "WINRM : SRV-PROD-01" }
$statusText = $window.FindName("StatusText")
if ($statusText) { $statusText.Text = "Connected to SRV-PROD-01 (Sample Dataset) | 17 Processes | CPU: 48.2% | Commit: 38.0% | RAM: 52.0%" }
$txtTelemTransport = $window.FindName("TxtTelemTransport")
if ($txtTelemTransport) { $txtTelemTransport.Text = "Mode: Sandbox | 18 ms RTT" }
$txtTelemPayload = $window.FindName("TxtTelemPayload")
if ($txtTelemPayload) { $txtTelemPayload.Text = "Wire: 1.4 KB/s (GZIP)" }
$txtTelemNetwork = $window.FindName("TxtTelemNetwork")
if ($txtTelemNetwork) { $txtTelemNetwork.Text = "NET: 1.9 MB/s" }
$txtTelemDelta = $window.FindName("TxtTelemDelta")
if ($txtTelemDelta) { $txtTelemDelta.Text = "Seq: #1042 (+2 New, -1 Exit)" }
$txtLogConsole = $window.FindName("TxtLogConsole")
if ($txtLogConsole) {
    $txtLogConsole.Text = @(
        "[16:44:58] [AUDIT] Theme Sandbox initialized with synthetic Contoso enterprise telemetry.",
        "[16:44:59] [TELEM] Tick #1041 | 17 processes | 1.38 KB GZIP wire | 4.2 ms collector latency",
        "[16:45:00] [NET]   ETW capture active: TCP4/TCP6/UDP4 sockets + per-process throughput",
        "[16:45:01] [WARN]  Sample Circuit Breaker / Tier 1 banners available from Sandbox Bar above."
    ) -join "`r`n"
}

# ------------------------------------------------------------------
# 3. Theme State, Application, Live Reload & Contrast Audit Logic
# ------------------------------------------------------------------
$sandboxState = @{
    CurrentTheme      = "Light"
    CustomThemeName   = $null
    CustomFilePath    = $null
    CustomLastWrite   = [datetime]::MinValue
    FlashEnabled      = $true
    BannerMode        = 1   # 0=Off, 1=Cap2, 2=Cap3, 3=CapErr
    IsPaused          = $false
    HighlightsEnabled = $true
    CategoryFilter    = ""
    ActiveTab         = $tab1
    OpenDialogs       = [System.Collections.Generic.List[System.Windows.Window]]::new()
    ContrastWindow    = $null
    ContrastGrid      = $null
    TokensGrid        = $null
    ContrastSummary   = $null
    ContrastOnlyFail  = $false
    ThemeDictCache    = @{}
    ActiveThemeDict   = $null
    ContrastCache     = @{}
    PillKeySignature  = ""
    PillButtons       = [System.Collections.Generic.List[System.Windows.Controls.Button]]::new()
}

function Strip-DirectThemeBrushes {
    param([System.Windows.ResourceDictionary]$ResDict)
    if (-not $ResDict) { return }
    $toRemove = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $ResDict.Keys) {
        if ($k -is [string] -and ($k.StartsWith("Brush") -or $k.StartsWith("ColTint_"))) {
            [void]$toRemove.Add($k)
        }
    }
    foreach ($rk in $toRemove) {
        $ResDict.Remove($rk)
    }
}

Strip-DirectThemeBrushes $window.Resources

$sandboxTxtToggle = $window.FindName("TxtThemeToggle")
$sandboxMenuMap = @{
    "Light"           = $window.FindName("MenuThemeLight")
    "Dark"            = $window.FindName("MenuThemeDark")
    "TokyoNight"      = $window.FindName("MenuThemeTokyoNight")
    "TokyoNightLight" = $window.FindName("MenuThemeTokyoNightLight")
    "Classic"         = $window.FindName("MenuThemeClassic")
    "HighContrast"    = $window.FindName("MenuThemeHighContrast")
}

function Get-SandboxThemeDictionary {
    param([string]$ResolvedName, [hashtable]$Palette)
    if ($sandboxState.ThemeDictCache.ContainsKey($ResolvedName)) {
        return $sandboxState.ThemeDictCache[$ResolvedName]
    }
    $rd = [System.Windows.ResourceDictionary]::new()
    foreach ($kv in $Palette.Brushes.GetEnumerator()) {
        $rd[[string]$kv.Key] = Get-FrozenBrush ([string]$kv.Value)
    }
    $sandboxState.ThemeDictCache[$ResolvedName] = $rd
    return $rd
}

function Sync-DialogResources {
    param([System.Windows.Window]$TargetWin)
    if (-not $TargetWin -or -not $TargetWin.Resources) { return }
    $activeRd = $sandboxState.ActiveThemeDict
    if ($activeRd) {
        if ($TargetWin.Resources.MergedDictionaries.Count -eq 0) {
            Strip-DirectThemeBrushes $TargetWin.Resources
            [void]$TargetWin.Resources.MergedDictionaries.Add($activeRd)
        } elseif (-not [Object]::ReferenceEquals($TargetWin.Resources.MergedDictionaries[0], $activeRd)) {
            $TargetWin.Resources.MergedDictionaries[0] = $activeRd
        }
        return
    }
    foreach ($key in @($window.Resources.Keys)) {
        if ($key -is [string] -and ($key.StartsWith("Brush") -or $key.StartsWith("ColTint_"))) {
            $TargetWin.Resources[$key] = $window.Resources[$key]
        }
    }
}

function Update-NetworkRowBrushes {
    param([hashtable]$Palette)
    $b = $Palette.Brushes
    $tcpBg = [string]$b["BrushBadgeTcpBg"]; $tcpFg = [string]$b["BrushBadgeTcpFg"]
    $udpBg = [string]$b["BrushBadgeUdpBg"]; $udpFg = [string]$b["BrushBadgeUdpFg"]
    $estBg = [string]$b["BrushStateEstBg"]; $estFg = [string]$b["BrushStateEstFg"]
    $lisBg = [string]$b["BrushStateListenBg"]; $lisFg = [string]$b["BrushStateListenFg"]
    $twBg  = [string]$b["BrushStateTimeWaitBg"]; $twFg = [string]$b["BrushStateTimeWaitFg"]
    $othBg = [string]$b["BrushToolbarBg"]; $othFg = [string]$b["BrushTextSecondary"]

    foreach ($s in $netSocketsCol) {
        if ($s.Protocol -like "UDP*") {
            $s.ProtocolBg = $udpBg; $s.ProtocolFg = $udpFg
        } else {
            $s.ProtocolBg = $tcpBg; $s.ProtocolFg = $tcpFg
        }
        switch ($s.State) {
            "ESTABLISHED" { $s.StateBg = $estBg; $s.StateFg = $estFg }
            "LISTENING"   { $s.StateBg = $lisBg; $s.StateFg = $lisFg }
            "TIME_WAIT"   { $s.StateBg = $twBg;  $s.StateFg = $twFg }
            default       { $s.StateBg = $othBg; $s.StateFg = $othFg }
        }
    }
    foreach ($t in $netTimelineCol) {
        if ($t.Operation -like "*Send*") {
            $t.OperationBg = [string]$b["BrushNetTxFill"]
            $t.OperationFg = [string]$b["BrushNetTxStroke"]
        } else {
            $t.OperationBg = [string]$b["BrushNetRxFill"]
            $t.OperationFg = [string]$b["BrushNetRxStroke"]
        }
    }
    if ($gridNetSockets)  { $gridNetSockets.Items.Refresh() }
    if ($gridNetTimeline) { $gridNetTimeline.Items.Refresh() }
}

function Update-LegendFilterVisuals {
    $pal = [PSRPMThemeRegistry]::GetPalette($sandboxState.CurrentTheme)
    $leg = $pal.Legend
    $cur = $sandboxState.CategoryFilter

    $btnAll  = $window.FindName("BtnLegendAll")
    $btnSvc  = $window.FindName("BtnLegendService")
    $btnOwn  = $window.FindName("BtnLegendOwn")
    $btnPkg  = $window.FindName("BtnLegendPackaged")
    $btnClr  = $window.FindName("BtnLegendClear")
    $lblFilt = $window.FindName("TxtFilterLegendLabel")

    if ($btnAll) {
        $btnAll.Background = Get-FrozenBrush ([string]$pal.Brushes.BrushHeaderBg)
        $btnAll.Foreground = Get-FrozenBrush ([string]$pal.Brushes.BrushTextPrimary)
        $btnAll.BorderBrush = Get-FrozenBrush $(if (-not $cur) { [string]$leg.AllActiveBorder } else { [string]$leg.AllIdleBorder })
        $btnAll.BorderThickness = [System.Windows.Thickness]::new($(if (-not $cur) { 2 } else { 1 }))
        $btnAll.FontWeight = if (-not $cur) { [System.Windows.FontWeights]::Bold } else { [System.Windows.FontWeights]::Normal }
        $btnAll.Opacity = if (-not $cur) { 1.0 } else { 0.55 }
    }
    if ($btnClr) {
        $btnClr.Visibility = if ($cur) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    if ($lblFilt) {
        $lblFilt.Text = if ($cur) { "ACTIVE FILTER:" } else { "Filter:" }
        $lblFilt.Foreground = Get-FrozenBrush ([string]$pal.Brushes.BrushTextMuted)
    }

    $map = @(
        @("Service",  $btnSvc, $leg.Service),
        @("Own",      $btnOwn, $leg.Own),
        @("Packaged", $btnPkg, $leg.Packaged)
    )
    foreach ($entry in $map) {
        $cat = $entry[0]; $btn = $entry[1]; $st = $entry[2]
        if (-not $btn) { continue }
        $isAct = ($cur -eq $cat)
        $btn.Background = Get-FrozenBrush $(if ($isAct) { [string]$st.ActiveBg } else { [string]$st.Bg })
        $btn.BorderBrush = Get-FrozenBrush $(if ($isAct) { [string]$st.ActiveBorder } else { [string]$st.Border })
        $btn.Foreground = Get-FrozenBrush ([string]$st.Fg)
        $btn.BorderThickness = [System.Windows.Thickness]::new($(if ($isAct) { 2 } else { 1 }))
        $btn.FontWeight = if ($isAct) { [System.Windows.FontWeights]::Bold } else { [System.Windows.FontWeights]::Normal }
        $btn.Opacity = if (-not $cur -or $isAct) { 1.0 } else { 0.55 }
    }
}

function Update-BannerVisuals {
    $banner = $window.FindName("NetEtwAlertBanner")
    if (-not $banner) { return }
    $mode = [int]$sandboxState.BannerMode
    $btnCycle = $sandboxBar.FindName("BtnSbCycleBanner")
    $labels = @("Banner: Off", "Banner: Cap2", "Banner: Cap3", "Banner: CapErr")
    if ($btnCycle) { $btnCycle.Content = $labels[$mode] }

    if ($mode -eq 0) {
        $banner.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }

    $pal = [PSRPMThemeRegistry]::GetPalette($sandboxState.CurrentTheme)
    $banner.Visibility = [System.Windows.Visibility]::Visible
    $bdBadge  = $window.FindName("BdNetEtwBannerBadge")
    $txtBadge = $window.FindName("TxtNetEtwBannerBadge")
    $txtMsg   = $window.FindName("TxtNetEtwBannerMsg")
    $btnRes   = $window.FindName("BtnNetEtwResume")
    $btnOff   = $window.FindName("BtnNetEtwTurnOff")
    $btnDis   = $window.FindName("BtnNetEtwDismiss")

    if ($mode -eq 1) {
        $c = $pal.Banner.Cap2
        $banner.Background  = Get-FrozenBrush ([string]$c.Bg)
        $banner.BorderBrush = Get-FrozenBrush ([string]$c.Border)
        if ($bdBadge)  { $bdBadge.Background = Get-FrozenBrush ([string]$c.BadgeBg) }
        if ($txtBadge) { $txtBadge.Text = "CIRCUIT BREAKER" }
        if ($txtMsg)   {
            $txtMsg.Text = "Sample Cap2 Banner: Per-process Network ETW auto-paused after exceeding 25,000 events/sec."
            $txtMsg.Foreground = Get-FrozenBrush ([string]$c.Fg)
        }
        if ($btnRes) {
            $btnRes.Visibility = [System.Windows.Visibility]::Visible
            $btnRes.Background = Get-FrozenBrush ([string]$c.BtnBg)
            $btnRes.Foreground = Get-FrozenBrush ([string]$c.BtnFg)
        }
        if ($btnOff) { $btnOff.Foreground = Get-FrozenBrush ([string]$c.Fg) }
        if ($btnDis) { $btnDis.Foreground = Get-FrozenBrush ([string]$c.MutedFg) }
    } elseif ($mode -eq 2) {
        $c = $pal.Banner.Cap3
        $banner.Background  = Get-FrozenBrush ([string]$c.Bg)
        $banner.BorderBrush = Get-FrozenBrush ([string]$c.Border)
        if ($bdBadge)  { $bdBadge.Background = Get-FrozenBrush ([string]$c.BadgeBg) }
        if ($txtBadge) { $txtBadge.Text = "TIER 1 FALLBACK" }
        if ($txtMsg)   {
            $txtMsg.Text = "Sample Cap3 Banner: Kernel Network ETW requires Administrators or Performance Log Users."
            $txtMsg.Foreground = Get-FrozenBrush ([string]$c.Fg)
        }
        if ($btnRes) { $btnRes.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($btnOff) { $btnOff.Foreground = Get-FrozenBrush ([string]$c.Fg) }
        if ($btnDis) { $btnDis.Foreground = Get-FrozenBrush ([string]$c.MutedFg) }
    } else {
        $c = $pal.Banner.CapErr
        $banner.Background  = Get-FrozenBrush ([string]$c.Bg)
        $banner.BorderBrush = Get-FrozenBrush ([string]$c.Border)
        if ($bdBadge)  { $bdBadge.Background = Get-FrozenBrush ([string]$c.BadgeBg) }
        if ($txtBadge) { $txtBadge.Text = "ETW UNAVAILABLE" }
        if ($txtMsg)   {
            $txtMsg.Text = "Sample CapErr Banner: Unable to start Microsoft-Windows-Kernel-Network ETW session."
            $txtMsg.Foreground = Get-FrozenBrush ([string]$c.Fg)
        }
        if ($btnRes) { $btnRes.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($btnOff) { $btnOff.Foreground = Get-FrozenBrush ([string]$c.Fg) }
        if ($btnDis) { $btnDis.Foreground = Get-FrozenBrush ([string]$c.MutedFg) }
    }
}

function Update-PausedVisuals {
    $isPaused = [bool]$sandboxState.IsPaused
    $isDark = [PSRPMThemeRegistry]::IsDarkMode($sandboxState.CurrentTheme)
    $btnSbPaused = $sandboxBar.FindName("BtnSbTogglePaused")
    if ($btnSbPaused) { $btnSbPaused.Content = if ($isPaused) { "Paused: ON" } else { "Paused: OFF" } }

    $btnPause  = $window.FindName("BtnToolbarPause")
    $iconPause = $window.FindName("IconToolbarPause")
    $txtPause  = $window.FindName("TxtToolbarPause")
    $badge     = $window.FindName("BadgePaused")
    $amberHex  = if ($isDark) { "#F59E0B" } else { "#D97706" }

    if ($isPaused) {
        if ($iconPause) {
            $iconPause.Data = [System.Windows.Media.Geometry]::Parse("M8,5.14v14l11-7-11-7z")
            $iconPause.Fill = Get-FrozenBrush $amberHex
        }
        if ($txtPause) {
            $txtPause.Text = "PAUSED"
            $txtPause.Foreground = Get-FrozenBrush $amberHex
            $txtPause.Visibility = [System.Windows.Visibility]::Visible
        }
        if ($btnPause) {
            $btnPause.Background = Get-FrozenBrush "#26F59E0B"
            $btnPause.BorderBrush = Get-FrozenBrush $amberHex
        }
        if ($badge) { $badge.Visibility = [System.Windows.Visibility]::Visible }
    } else {
        if ($iconPause) {
            $iconPause.Data = [System.Windows.Media.Geometry]::Parse("M6,19h4V5H6V19z M14,5v14h4V5H14z")
            $pal = [PSRPMThemeRegistry]::GetPalette($sandboxState.CurrentTheme)
            $iconPause.Fill = Get-FrozenBrush ([string]$pal.Brushes.BrushTextSecondary)
        }
        if ($txtPause) { $txtPause.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($btnPause) {
            $btnPause.Background = [System.Windows.Media.Brushes]::Transparent
            $btnPause.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        }
        if ($badge) { $badge.Visibility = [System.Windows.Visibility]::Collapsed }
    }
}

function Rebuild-ThemePills {
    $panel = $sandboxBar.FindName("SandboxThemePills")
    if (-not $panel) { return }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($bn in [PSRPMThemeRegistry]::GetBuiltInNames()) { [void]$names.Add($bn) }
    if ($sandboxState.CustomThemeName -and (-not $names.Contains($sandboxState.CustomThemeName))) {
        [void]$names.Add($sandboxState.CustomThemeName)
    }

    $sigParts = [System.Collections.Generic.List[string]]::new()
    foreach ($tName in $names) {
        $pal = [PSRPMThemeRegistry]::GetPalette($tName)
        [void]$sigParts.Add(([string]$pal.Name + ":" + [string]$pal.DisplayName))
    }
    $sig = $sigParts -join "|"

    if ($sandboxState.PillKeySignature -ne $sig -or $sandboxState.PillButtons.Count -ne $names.Count) {
        $panel.Children.Clear()
        $sandboxState.PillButtons.Clear()
        $sandboxState.PillKeySignature = $sig
        foreach ($tName in $names) {
            $pal = [PSRPMThemeRegistry]::GetPalette($tName)
            $btn = [System.Windows.Controls.Button]::new()
            $btn.Content = [string]$pal.DisplayName
            $btn.Tag = [string]$pal.Name
            $btn.Padding = [System.Windows.Thickness]::new(7, 2, 7, 2)
            $btn.Margin = [System.Windows.Thickness]::new(0, 0, 3, 0)
            $btn.FontSize = 10.5
            $btn.Cursor = [System.Windows.Input.Cursors]::Hand
            $btn.BorderThickness = [System.Windows.Thickness]::new(1)
            $btn.add_Click({
                param($sender, $e)
                Apply-SandboxTheme ([string]$sender.Tag)
            })
            [void]$panel.Children.Add($btn)
            [void]$sandboxState.PillButtons.Add($btn)
        }
    }

    foreach ($btn in $sandboxState.PillButtons) {
        $isSelected = ($sandboxState.CurrentTheme -eq [string]$btn.Tag)
        if ($isSelected) {
            $btn.FontWeight = [System.Windows.FontWeights]::Bold
            $btn.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, "BrushBadgeBg")
            $btn.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, "BrushBadgeFg")
            $btn.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, "BrushAccent")
        } else {
            $btn.FontWeight = [System.Windows.FontWeights]::Normal
            $btn.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, "BrushSurfaceBg")
            $btn.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, "BrushTextPrimary")
            $btn.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, "BrushBorderSubtle")
        }
    }
}

function Update-ContrastAuditor {
    param([hashtable]$Palette)
    $pName = [string]$Palette.Name
    $report = if ($sandboxState.ContrastCache.ContainsKey($pName)) {
        $sandboxState.ContrastCache[$pName]
    } else {
        $r = Get-ThemeContrastReport -Palette $Palette
        $sandboxState.ContrastCache[$pName] = $r
        $r
    }
    $btnCon = $sandboxBar.FindName("BtnSbContrast")
    $txtCon = $sandboxBar.FindName("TxtSbContrast")
    $b = $Palette.Brushes

    if ($txtCon -and $btnCon) {
        if ($report.FailCount -eq 0) {
            $txtCon.Text = ('WCAG AA: PASS (min {0:N2}:1)' -f $report.MinRatio)
            $btnCon.Background  = Get-FrozenBrush ([string]$b["BrushStateEstBg"])
            $btnCon.BorderBrush = Get-FrozenBrush ([string]$b["BrushAccent"])
            $txtCon.Foreground  = Get-FrozenBrush ([string]$b["BrushStateEstFg"])
        } else {
            $txtCon.Text = ('WCAG AA: {0} FAIL (min {1:N2}:1)' -f $report.FailCount, $report.MinRatio)
            $btnCon.Background  = Get-FrozenBrush ([string]$b["BrushKillBg"])
            $btnCon.BorderBrush = Get-FrozenBrush ([string]$b["BrushKillBorder"])
            $txtCon.Foreground  = Get-FrozenBrush ([string]$b["BrushKillFg"])
        }
    }

    if ($sandboxState.ContrastWindow -and $sandboxState.ContrastWindow.IsLoaded) {
        Sync-DialogResources $sandboxState.ContrastWindow
        if ($sandboxState.ContrastSummary) {
            $sandboxState.ContrastSummary.Text = ('Theme: {0} | Checked {1} pairs | Failures: {2} | Lowest Ratio: {3:N2}:1' -f $Palette.DisplayName, $report.Items.Count, $report.FailCount, $report.MinRatio)
        }
        if ($sandboxState.ContrastGrid) {
            $items = if ($sandboxState.ContrastOnlyFail) {
                @($report.Items | Where-Object { -not $_.IsPass })
            } else {
                $report.Items
            }
            $sandboxState.ContrastGrid.ItemsSource = $items
        }
        if ($sandboxState.TokensGrid) {
            $tokRows = [System.Collections.Generic.List[Object]]::new()
            foreach ($tk in ($Palette.Brushes.Keys | Sort-Object)) {
                [void]$tokRows.Add([PSCustomObject]@{
                    Section = "Brushes"
                    Token   = [string]$tk
                    Hex     = [string]$Palette.Brushes[$tk]
                })
            }
            foreach ($rt in @("Default", "New", "Exiting", "Suspended", "HighCPU", "Packaged", "Service", "Own")) {
                if ($Palette.Rows[$rt]) {
                    [void]$tokRows.Add([PSCustomObject]@{ Section = "Rows.$rt"; Token = "Bg"; Hex = [string]$Palette.Rows[$rt].Bg })
                    [void]$tokRows.Add([PSCustomObject]@{ Section = "Rows.$rt"; Token = "Fg"; Hex = [string]$Palette.Rows[$rt].Fg })
                }
            }
            foreach ($tk in ($Palette.TabColors.Keys | Sort-Object)) {
                [void]$tokRows.Add([PSCustomObject]@{ Section = "TabColors"; Token = [string]$tk; Hex = [string]$Palette.TabColors[$tk] })
            }
            $sandboxState.TokensGrid.ItemsSource = $tokRows
        }
    }
}

function Apply-SandboxTheme {
    param([string]$ThemeName)
    $palette = [PSRPMThemeRegistry]::GetPalette($ThemeName)
    $resolved = [string]$palette.Name
    $sandboxState.CurrentTheme = $resolved

    $themeRd = Get-SandboxThemeDictionary -ResolvedName $resolved -Palette $palette
    $sandboxState.ActiveThemeDict = $themeRd
    if ($window.Resources.MergedDictionaries.Count -eq 0) {
        [void]$window.Resources.MergedDictionaries.Add($themeRd)
    } elseif (-not [Object]::ReferenceEquals($window.Resources.MergedDictionaries[0], $themeRd)) {
        $window.Resources.MergedDictionaries[0] = $themeRd
    }

    if ($sandboxTxtToggle) { $sandboxTxtToggle.Text = [string]$palette.DisplayName }

    foreach ($mk in $sandboxMenuMap.Keys) {
        if ($sandboxMenuMap[$mk]) { $sandboxMenuMap[$mk].IsChecked = ($resolved -eq $mk) }
    }

    foreach ($pvm in $procVms) {
        $pvm.SetThemeMode($resolved)
    }

    $canClose = ($hostTabs.Count -gt 1)
    foreach ($tvm in $hostTabs) {
        $isAct = ($tvm -eq $sandboxState.ActiveTab)
        $cState = if ($isAct) { if ($tvm.IsLocal) { "LocalMode" } else { "Connected" } } else { "Standby" }
        $tvm.UpdateVisualState($isAct, $resolved, $canClose, $cState, [bool]$sandboxState.IsPaused, 18)
    }

    Update-NetworkRowBrushes $palette
    Update-LegendFilterVisuals
    Update-BannerVisuals
    Update-PausedVisuals
    Rebuild-ThemePills

    for ($i = $sandboxState.OpenDialogs.Count - 1; $i -ge 0; $i--) {
        $dlg = $sandboxState.OpenDialogs[$i]
        if (-not $dlg -or -not $dlg.IsLoaded) {
            $sandboxState.OpenDialogs.RemoveAt($i)
            continue
        }
        Sync-DialogResources $dlg
    }

    Update-ContrastAuditor $palette
}

function Import-CustomThemeFile {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Theme file not found: $FilePath"
    }
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $spec = Read-VsCodeThemeRecursive -Path $FilePath -Visited $visited
    if (-not ($spec -is [hashtable]) -or $spec.Count -eq 0) {
        throw "Theme JSON root must be a non-empty object."
    }

    $baseFileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $isVsCode = ($spec.ContainsKey("colors") -or $spec.ContainsKey("tokenColors")) -and (-not $spec.ContainsKey("Brushes"))
    if ($isVsCode) {
        $spec = ConvertFrom-VsCodeTheme -VsCodeSpec $spec -FallbackName $baseFileName
    } elseif (-not $spec.ContainsKey("Name") -or [string]::IsNullOrWhiteSpace([string]$spec.Name)) {
        $spec.Name = $baseFileName
    }

    $reg = [PSRPMThemeRegistry]::RegisterPalette($spec)
    $regName = [string]$reg.Name
    $sandboxState.ThemeDictCache.Remove($regName)
    $sandboxState.ContrastCache.Remove($regName)
    $sandboxState.CustomThemeName = $regName
    $sandboxState.CustomFilePath  = (Resolve-Path -LiteralPath $FilePath).Path
    $sandboxState.CustomLastWrite = [System.IO.File]::GetLastWriteTimeUtc($sandboxState.CustomFilePath)

    $btnReload = $sandboxBar.FindName("BtnSbReloadJson")
    if ($btnReload) { $btnReload.IsEnabled = $true }
    $txtFile = $sandboxBar.FindName("TxtSbLoadedFile")
    if ($txtFile) {
        $prefix = if ($isVsCode) { "VS Code" } else { "Custom" }
        $txtFile.Text = ("{0}: {1}" -f $prefix, [System.IO.Path]::GetFileName($sandboxState.CustomFilePath))
        $txtFile.ToolTip = $sandboxState.CustomFilePath
    }

    Apply-SandboxTheme ([string]$reg.Name)
}

# ------------------------------------------------------------------
# 4. Child Dialog Preview Openers (Modeless + Live Theme Synced)
# ------------------------------------------------------------------
function Open-PreviewDialog {
    param([string]$FileName, [scriptblock]$OnConfigure)
    $path = Join-Path $uiDir $FileName
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = [System.IO.MemoryStream]::new($bytes)
    $dlg = [System.Windows.Markup.XamlReader]::Load($ms)
    $ms.Close()

    $dlg.Owner = $window
    if ($appIconFrame) { $dlg.Icon = $appIconFrame }
    Sync-DialogResources $dlg

    # Clear IsCancel on buttons so every preview dialog can stay open modelessly
    foreach ($btnName in @("BtnConnectCancel", "BtnHelpClose", "BtnCloseProp", "BtnColCancel", "BtnDlgClose", "BtnCloseDlg", "BtnSysInfoOk")) {
        $b = $dlg.FindName($btnName)
        if ($b -and ($b -is [System.Windows.Controls.Button])) {
            $b.IsCancel = $false
            $b.add_Click({
                param($s, $e)
                $w = [System.Windows.Window]::GetWindow($s)
                if ($w) { $w.Close() }
            })
        }
    }
    $dlg.add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $s.Close()
            $e.Handled = $true
        }
    })

    if ($OnConfigure) { & $OnConfigure $dlg }

    [void]$sandboxState.OpenDialogs.Add($dlg)
    $dlg.Show()
}

$sandboxBar.FindName("BtnSbDlgSysInfo").add_Click({
    Open-PreviewDialog "SystemInfoWindow.xaml" {
        param($d)
        $d.Title = "System Information [SRV-PROD-01] - Theme Preview"
        $d.DataContext = $sumVm
        if ($d.Content) { $d.Content.DataContext = $sumVm }
    }
})

$sandboxBar.FindName("BtnSbDlgProps").add_Click({
    Open-PreviewDialog "PropertiesWindow.xaml" {
        param($d)
        $d.Title = "pwsh.exe (10990) Properties - Theme Preview"
        $d.FindName("PropHeaderName").Text = "pwsh.exe"
        $d.FindName("PropHeaderPid").Text = "PID: 10990"
        $d.FindName("PropDescription").Text = "PowerShell 7.4 Core Terminal"
        $d.FindName("PropCompany").Text = "Microsoft Corporation"
        $d.FindName("PropVersion").Text = "7.4.6.0"
        $d.FindName("PropBuildTime").Text = "2026-10-18 14:22:10"
        $d.FindName("PropPath").Text = "C:\Program Files\PowerShell\7\pwsh.exe"
        $d.FindName("PropCmdLine").Text = "pwsh.exe -NoLogo -NoProfile"
        $d.FindName("PropWorkDir").Text = "C:\Projects\PSRPM"
        $d.FindName("PropAutostart").Text = "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        $d.FindName("PropParentPid").Text = "Code.exe (9450)"
        $d.FindName("PropUser").Text = "CONTOSO\svc-monitor (S-1-5-21-34829104-1001)"
        $d.FindName("PropStartTime").Text = "2026-11-15 16:00:00 (Uptime: 00:45:12)"
        $d.FindName("PropArch").Text = "64-bit (x64)"
        $d.FindName("PropSignature").Text = "Verified: Microsoft Corporation (Authenticode Valid)"
        if ($appIconFrame) { $d.FindName("PropIcon").Source = $appIconFrame }

        $d.FindName("PropCpu").Text = "CPU Usage: 0.40% (Normalized)"
        $d.FindName("PropTotalCpuTime").Text = "Total Processor Time: 00:01:14.208"
        $d.FindName("PropKernelUserTime").Text = "Kernel: 00:00:22.104 | User: 00:00:52.104"
        $d.FindName("PropCycles").Text = "Cycles: 2,140,884,120"
        $d.FindName("PropThreadsHandles").Text = "Threads: 16 | Handles: 610 (USER: 4, GDI: 8)"
        $d.FindName("PropPrivateBytes").Text = "Private Bytes: 52,400 K (Peak: 58,100 K)"
        $d.FindName("PropRam").Text = "Working Set: 72,100 K (Peak: 78,400 K)"
        $d.FindName("PropVirtualPageFaults").Text = "Virtual Size: 412 MB | Page Faults: 18,420"
        $d.FindName("PropPools").Text = "Paged Pool: 420 K | Non-Paged Pool: 36 K"
        $d.FindName("PropIoCounters").Text = "Reads: 1,120 (18.4 MB) | Writes: 420 (4.2 MB) | Other: 2,840"

        $d.FindName("GridPropDlls").ItemsSource = @(
            [PSCustomObject]@{ Name = "ntdll.dll"; Description = "NT Layer DLL"; CompanyName = "Microsoft Corporation"; Version = "10.0.20348.2405"; Size = "2.1 MB"; BaseAddress = "0x00007FFA84210000"; Path = "C:\Windows\System32\ntdll.dll" },
            [PSCustomObject]@{ Name = "System.Management.Automation.dll"; Description = "PowerShell Engine"; CompanyName = "Microsoft Corporation"; Version = "7.4.6"; Size = "8.4 MB"; BaseAddress = "0x00007FFA40120000"; Path = "C:\Program Files\PowerShell\7\System.Management.Automation.dll" }
        )
        $d.FindName("GridPropHandles").ItemsSource = @(
            [PSCustomObject]@{ Type = "File"; Name = "C:\Projects\PSRPM\PSRPM\PSRPM.psm1"; Handle = "0x01A4"; Access = "0x00120089" },
            [PSCustomObject]@{ Type = "Key";  Name = "\REGISTRY\MACHINE\SOFTWARE\Microsoft\PowerShell"; Handle = "0x0218"; Access = "0x00020019" }
        )
        $d.FindName("GridNetConnections").ItemsSource = @(
            [PSCustomObject]@{ Protocol = "TCP4"; LocalEndpoint = "10.12.4.48:55012"; RemoteEndpoint = "10.12.0.15:5985"; State = "ESTABLISHED" }
        )
        $d.FindName("GridPropServices").ItemsSource = @(
            [PSCustomObject]@{ Name = "WinRM"; DisplayName = "Windows Remote Management"; Status = "Running"; StartType = "Automatic"; User = "NT AUTHORITY\NetworkService" }
        )
        $d.FindName("GridPropEnv").ItemsSource = @(
            [PSCustomObject]@{ Key = "COMPUTERNAME"; Value = "SRV-PROD-01" },
            [PSCustomObject]@{ Key = "PSModulePath"; Value = "C:\Program Files\PowerShell\Modules" }
        )
    }
})

$sandboxBar.FindName("BtnSbDlgSvc").add_Click({
    Open-PreviewDialog "ServiceDetailWindow.xaml" {
        param($d)
        $d.Title = "SQL Server (MSSQLSERVER) Details - Theme Preview"
        $d.FindName("TxtDlgDisplayName").Text = "SQL Server (MSSQLSERVER)"
        $d.FindName("TxtDlgServiceName").Text = "MSSQLSERVER"
        $d.FindName("TxtDlgPid").Text = "3680"
        $d.FindName("TxtDlgDescription").Text = "Provides storage, processing and controlled access of data and rapid transaction processing."
        $d.FindName("TxtDlgPath").Text = "C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\Binn\sqlservr.exe"
        $d.FindName("TxtDlgStartup").Text = "Automatic"
        $d.FindName("TxtDlgAccount").Text = "NT SERVICE\MSSQLSERVER"
        $d.FindName("TxtDlgDepSummary").Text = "Depends on: Tcpip"
        $d.FindName("GridDlgPrereqs").ItemsSource = @([PSCustomObject]@{ Name = "Tcpip"; DisplayName = "TCP/IP Protocol Driver"; Status = "Running" })
        $d.FindName("GridDlgDependents").ItemsSource = @([PSCustomObject]@{ Name = "SQLSERVERAGENT"; DisplayName = "SQL Server Agent"; Status = "Running" })
    }
})

$sandboxBar.FindName("BtnSbDlgConnect").add_Click({
    Open-PreviewDialog "ConnectDialog.xaml" {
        param($d)
        $d.Title = "Connect to Remote Host - Theme Preview"
        $d.FindName("TxtConnectComputer").Text = "SRV-PROD-02.contoso.corp"
        $d.FindName("BdConnectError").Visibility = [System.Windows.Visibility]::Visible
        $d.FindName("TxtConnectError").Text = "Sample error banner preview: WinRM port 5985 unreachable."
    }
})

$sandboxBar.FindName("BtnSbDlgFind").add_Click({
    Open-PreviewDialog "FindHandleWindow.xaml" {
        param($d)
        $d.Title = "Find Handle or DLL - Theme Preview"
        $d.FindName("TxtSearchHandle").Text = "System.Management"
        $d.FindName("TxtHandleStatus").Text = "3 matching handles/modules found (Sample)"
        $d.FindName("GridHandleResults").ItemsSource = @(
            [PSCustomObject]@{ ProcessName = "pwsh.exe"; PID = 10990; Type = "DLL"; Handle = "0x7FFA40120000"; Name = "C:\Program Files\PowerShell\7\System.Management.Automation.dll" },
            [PSCustomObject]@{ ProcessName = "Code.exe"; PID = 9450;  Type = "File"; Handle = "0x000002B4"; Name = "C:\Projects\PSRPM\PSRPM\PSRPM.psm1" },
            [PSCustomObject]@{ ProcessName = "sqlservr.exe"; PID = 3680; Type = "Mutant"; Handle = "0x000004C0"; Name = "\BaseNamedObjects\MSSQL_Global_Lock" }
        )
    }
})

$sandboxBar.FindName("BtnSbDlgCols").add_Click({
    Open-PreviewDialog "SelectColumnsWindow.xaml" {
        param($d)
        $d.Title = "Select Columns - Theme Preview"
        $d.FindName("TxtSelectedCount").Text = "12 selected"
        $d.FindName("LstAvailableColumns").ItemsSource = @(
            [PSCustomObject]@{ Header = "Process"; Group = "Core"; Hint = "Process name & tree hierarchy"; IsChecked = $true; IsCheckEnabled = $false; RowVisibility = "Visible" },
            [PSCustomObject]@{ Header = "CPU"; Group = "CPU"; Hint = "Normalized CPU %"; IsChecked = $true; IsCheckEnabled = $true; RowVisibility = "Visible" },
            [PSCustomObject]@{ Header = "Net Total"; Group = "Network"; Hint = "ETW total rate"; IsChecked = $true; IsCheckEnabled = $true; RowVisibility = "Visible" },
            [PSCustomObject]@{ Header = "Private Bytes"; Group = "Memory"; Hint = "Committed private memory"; IsChecked = $true; IsCheckEnabled = $true; RowVisibility = "Visible" }
        )
        $d.FindName("LstColumnOrder").ItemsSource = @("Process", "CPU", "Net Total", "Private Bytes", "Working Set", "PID")
    }
})

$sandboxBar.FindName("BtnSbDlgHelp").add_Click({
    Open-PreviewDialog "HelpWindow.xaml" {
        param($d)
        $d.Title = "PSRPM Help & Shortcuts - Theme Preview"
        $d.FindName("TxtAboutHost").Text = "SRV-PROD-01"
        $d.FindName("TxtAboutUser").Text = "CONTOSO\svc-monitor"
        $d.FindName("TxtAboutTarget").Text = "SRV-PROD-01 (Sandbox)"
        $d.FindName("TxtAboutTransport").Text = "Theme Sandbox"
        $d.FindName("TxtAboutPsVersion").Text = "$($PSVersionTable.PSVersion)"
        $d.FindName("TxtAboutClrVersion").Text = "$($PSVersionTable.CLRVersion)"
        $d.FindName("TxtAboutArch").Text = "x64"
    }
})

# Contrast & Token Auditor Window
$sandboxBar.FindName("BtnSbContrast").add_Click({
    if ($sandboxState.ContrastWindow -and $sandboxState.ContrastWindow.IsLoaded) {
        $sandboxState.ContrastWindow.Activate()
        return
    }
    $auditXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSRPM WCAG 2.1 AA Contrast &amp; Token Auditor"
        Width="860" Height="580" MinWidth="700" MinHeight="420"
        WindowStartupLocation="CenterOwner"
        Background="{DynamicResource BrushWindowBg}"
        Foreground="{DynamicResource BrushTextPrimary}"
        FontFamily="Segoe UI" FontSize="12">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock x:Name="TxtAuditSummary" DockPanel.Dock="Left" Text="Audit" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="{DynamicResource BrushTextPrimary}"/>
            <CheckBox x:Name="ChkAuditOnlyFail" DockPanel.Dock="Right" Content="Show Failures Only" VerticalAlignment="Center" Foreground="{DynamicResource BrushTextPrimary}"/>
        </DockPanel>
        <TabControl Grid.Row="1" Background="{DynamicResource BrushSurfaceBg}" BorderBrush="{DynamicResource BrushBorderSubtle}">
            <TabItem Header="WCAG 2.1 AA Contrast Checks">
                <DataGrid x:Name="GridContrast" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                          GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource BrushBorderSubtle}"
                          Background="{DynamicResource BrushSurfaceBg}" Foreground="{DynamicResource BrushTextPrimary}"
                          RowHeaderWidth="0" RowHeight="24" BorderThickness="0">
                    <DataGrid.ColumnHeaderStyle>
                        <Style TargetType="DataGridColumnHeader">
                            <Setter Property="Background" Value="{DynamicResource BrushHeaderBg}"/>
                            <Setter Property="Foreground" Value="{DynamicResource BrushTextPrimary}"/>
                            <Setter Property="FontWeight" Value="SemiBold"/>
                            <Setter Property="Padding" Value="8,5"/>
                            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorderSubtle}"/>
                            <Setter Property="BorderThickness" Value="0,0,1,1"/>
                        </Style>
                    </DataGrid.ColumnHeaderStyle>
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="110"/>
                        <DataGridTemplateColumn Header="Foreground" Width="185">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0">
                                        <Border Width="14" Height="14" Background="{Binding FgHex}" BorderBrush="{DynamicResource BrushBorderSubtle}" BorderThickness="1" CornerRadius="2" Margin="0,0,6,0"/>
                                        <TextBlock Text="{Binding FgToken}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="Background" Width="185">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0">
                                        <Border Width="14" Height="14" Background="{Binding BgHex}" BorderBrush="{DynamicResource BrushBorderSubtle}" BorderThickness="1" CornerRadius="2" Margin="0,0,6,0"/>
                                        <TextBlock Text="{Binding BgToken}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Preview" Binding="{Binding FgHex}" Width="80"/>
                        <DataGridTextColumn Header="Ratio" Binding="{Binding RatioText}" Width="80"/>
                        <DataGridTemplateColumn Header="AA Status" Width="*">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <Border Background="{Binding StatusBg}" CornerRadius="2" Padding="6,1" HorizontalAlignment="Left" Margin="4,0" VerticalAlignment="Center">
                                        <TextBlock Text="{Binding Status}" Foreground="{Binding StatusFg}" FontSize="10.5" FontWeight="Bold"/>
                                    </Border>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
            <TabItem Header="All Active Tokens &amp; Swatches">
                <DataGrid x:Name="GridAllTokens" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                          GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource BrushBorderSubtle}"
                          Background="{DynamicResource BrushSurfaceBg}" Foreground="{DynamicResource BrushTextPrimary}"
                          RowHeaderWidth="0" RowHeight="24" BorderThickness="0">
                    <DataGrid.ColumnHeaderStyle>
                        <Style TargetType="DataGridColumnHeader">
                            <Setter Property="Background" Value="{DynamicResource BrushHeaderBg}"/>
                            <Setter Property="Foreground" Value="{DynamicResource BrushTextPrimary}"/>
                            <Setter Property="FontWeight" Value="SemiBold"/>
                            <Setter Property="Padding" Value="8,5"/>
                            <Setter Property="BorderBrush" Value="{DynamicResource BrushBorderSubtle}"/>
                            <Setter Property="BorderThickness" Value="0,0,1,1"/>
                        </Style>
                    </DataGrid.ColumnHeaderStyle>
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Section" Binding="{Binding Section}" Width="120"/>
                        <DataGridTextColumn Header="Token Key" Binding="{Binding Token}" Width="240"/>
                        <DataGridTemplateColumn Header="Swatch" Width="70">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <Border Width="38" Height="15" Background="{Binding Hex}" BorderBrush="{DynamicResource BrushBorderSubtle}" BorderThickness="1" CornerRadius="2" HorizontalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Hex Value" Binding="{Binding Hex}" Width="*"/>
                    </DataGrid.Columns>
                </DataGrid>
            </TabItem>
        </TabControl>
        <Button x:Name="BtnAuditClose" Grid.Row="2" Content="Close" Width="88" Height="26" HorizontalAlignment="Right" Margin="0,10,0,0"
                Background="{DynamicResource BrushHeaderBg}" Foreground="{DynamicResource BrushTextPrimary}" BorderBrush="{DynamicResource BrushBorderSubtle}" BorderThickness="1"/>
    </Grid>
</Window>
'@
    $msAud = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($auditXaml))
    $audWin = [System.Windows.Markup.XamlReader]::Load($msAud)
    $msAud.Close()
    $audWin.Owner = $window
    if ($appIconFrame) { $audWin.Icon = $appIconFrame }
    Sync-DialogResources $audWin

    $sandboxState.ContrastWindow  = $audWin
    $sandboxState.ContrastGrid    = $audWin.FindName("GridContrast")
    $sandboxState.TokensGrid      = $audWin.FindName("GridAllTokens")
    $sandboxState.ContrastSummary = $audWin.FindName("TxtAuditSummary")

    $chkFail = $audWin.FindName("ChkAuditOnlyFail")
    $chkFail.IsChecked = [bool]$sandboxState.ContrastOnlyFail
    $chkFail.add_Click({
        param($s, $e)
        $sandboxState.ContrastOnlyFail = [bool]$s.IsChecked
        Update-ContrastAuditor ([PSRPMThemeRegistry]::GetPalette($sandboxState.CurrentTheme))
    })
    $audWin.FindName("BtnAuditClose").add_Click({ $sandboxState.ContrastWindow.Close() })
    $audWin.add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $s.Close() }
    })
    $audWin.add_Closed({
        $sandboxState.ContrastWindow = $null
        $sandboxState.ContrastGrid = $null
        $sandboxState.TokensGrid = $null
        $sandboxState.ContrastSummary = $null
    })

    Update-ContrastAuditor ([PSRPMThemeRegistry]::GetPalette($sandboxState.CurrentTheme))
    $audWin.Show()
})

# ------------------------------------------------------------------
# 5. Wire Sandbox Bar Actions, MainWindow Controls & File Watcher
# ------------------------------------------------------------------
$sandboxBar.FindName("BtnSbLoadJson").add_Click({
    $ofd = [Microsoft.Win32.OpenFileDialog]::new()
    $ofd.Title = "Load PSRPM or VS Code Theme JSON/JSONC"
    $ofd.Filter = "Theme JSON files (*.json;*.jsonc)|*.json;*.jsonc|All files (*.*)|*.*"
    $ofd.InitialDirectory = $scriptDir
    if ($ofd.ShowDialog($window) -eq $true) {
        try {
            Import-CustomThemeFile $ofd.FileName
        } catch {
            [System.Windows.MessageBox]::Show($window, $_.Exception.Message, "Theme JSON Load Error", "OK", "Error") | Out-Null
        }
    }
})

function Get-InstalledVsCodeThemes {
    $discovered = [System.Collections.Generic.List[Object]]::new()
    $roots = @(
        (Join-Path $env:USERPROFILE ".vscode\extensions"),
        (Join-Path $env:USERPROFILE ".vscode-insiders\extensions")
    )
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 4194304
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($extDir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $pkgPath = Join-Path $extDir.FullName "package.json"
            if (-not (Test-Path -LiteralPath $pkgPath)) { continue }
            try {
                $pkgRaw = [System.IO.File]::ReadAllText($pkgPath, [System.Text.Encoding]::UTF8)
                $pkgObj = Convert-JsonObjectToHashtable ($jss.DeserializeObject((Remove-JsoncCommentsAndTrailingCommas $pkgRaw)))
                if (-not ($pkgObj -is [hashtable])) { continue }
                $contribs = $pkgObj["contributes"]
                if (-not ($contribs -is [hashtable])) { continue }
                $themesArr = $contribs["themes"]
                if (-not $themesArr) { continue }
                foreach ($tEntry in $themesArr) {
                    if (-not ($tEntry -is [hashtable])) { continue }
                    $rel = [string]$tEntry["path"]
                    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
                    $fullThemePath = Join-Path $extDir.FullName ($rel.TrimStart('.', '/', '\') -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $fullThemePath)) { continue }
                    $lbl = if ($tEntry["label"]) { [string]$tEntry["label"] } elseif ($tEntry["id"]) { [string]$tEntry["id"] } else { [System.IO.Path]::GetFileNameWithoutExtension($fullThemePath) }
                    $uiT = [string]$tEntry["uiTheme"]
                    [void]$discovered.Add([PSCustomObject]@{
                        Label     = $lbl
                        UiTheme   = if ($uiT) { $uiT } else { "vs-dark" }
                        Extension = [string]$pkgObj["name"]
                        FilePath  = $fullThemePath
                    })
                }
            } catch {}
        }
    }
    return $discovered
}

$sandboxBar.FindName("BtnSbLoadVsCode").add_Click({
    $installed = Get-InstalledVsCodeThemes
    if ($installed.Count -eq 0) {
        $ofd = [Microsoft.Win32.OpenFileDialog]::new()
        $ofd.Title = "Import VS Code Theme File (vscodethemes.com / themes/*.json)"
        $ofd.Filter = "VS Code Theme JSON (*.json;*.jsonc)|*.json;*.jsonc|All files (*.*)|*.*"
        $ofd.InitialDirectory = $scriptDir
        if ($ofd.ShowDialog($window) -eq $true) {
            try {
                Import-CustomThemeFile $ofd.FileName
            } catch {
                [System.Windows.MessageBox]::Show($window, $_.Exception.Message, "VS Code Theme Import Error", "OK", "Error") | Out-Null
            }
        }
        return
    }

    $vscPickerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Import VS Code Theme"
        Width="680" Height="460" MinWidth="540" MinHeight="340"
        WindowStartupLocation="CenterOwner"
        Background="{DynamicResource BrushWindowBg}"
        Foreground="{DynamicResource BrushTextPrimary}"
        FontFamily="Segoe UI" FontSize="12">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock DockPanel.Dock="Left" Text="Filter:" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="{DynamicResource BrushTextSecondary}"/>
            <TextBox x:Name="TxtVscSearch" Height="24" Padding="6,2" Background="{DynamicResource BrushSurfaceBg}" Foreground="{DynamicResource BrushTextPrimary}" BorderBrush="{DynamicResource BrushBorderSubtle}"/>
        </DockPanel>
        <DataGrid x:Name="GridVscThemes" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource BrushBorderSubtle}"
                  Background="{DynamicResource BrushSurfaceBg}" Foreground="{DynamicResource BrushTextPrimary}" RowHeaderWidth="0" RowHeight="24">
            <DataGrid.ColumnHeaderStyle>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background" Value="{DynamicResource BrushHeaderBg}"/>
                    <Setter Property="Foreground" Value="{DynamicResource BrushTextPrimary}"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                    <Setter Property="Padding" Value="8,4"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource BrushBorderSubtle}"/>
                    <Setter Property="BorderThickness" Value="0,0,1,1"/>
                </Style>
            </DataGrid.ColumnHeaderStyle>
            <DataGrid.Columns>
                <DataGridTextColumn Header="Theme Label" Binding="{Binding Label}" Width="240"/>
                <DataGridTextColumn Header="Type" Binding="{Binding UiTheme}" Width="90"/>
                <DataGridTextColumn Header="Extension" Binding="{Binding Extension}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
        <DockPanel Grid.Row="2" Margin="0,10,0,0" LastChildFill="False">
            <Button x:Name="BtnVscBrowse" DockPanel.Dock="Left" Content="Browse File..." Padding="10,4" Background="{DynamicResource BrushHeaderBg}" Foreground="{DynamicResource BrushTextPrimary}" BorderBrush="{DynamicResource BrushBorderSubtle}"/>
            <Button x:Name="BtnVscCancel" DockPanel.Dock="Right" Content="Cancel" Width="80" Padding="8,4" Margin="6,0,0,0" Background="{DynamicResource BrushHeaderBg}" Foreground="{DynamicResource BrushTextPrimary}" BorderBrush="{DynamicResource BrushBorderSubtle}"/>
            <Button x:Name="BtnVscImport" DockPanel.Dock="Right" Content="Import Selected" Width="118" Padding="8,4" FontWeight="SemiBold" Background="{DynamicResource BrushBadgeBg}" Foreground="{DynamicResource BrushBadgeFg}" BorderBrush="{DynamicResource BrushAccent}"/>
        </DockPanel>
    </Grid>
</Window>
'@
    $msV = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($vscPickerXaml))
    $pWin = [System.Windows.Markup.XamlReader]::Load($msV)
    $msV.Close()
    $pWin.Owner = $window
    if ($appIconFrame) { $pWin.Icon = $appIconFrame }
    Sync-DialogResources $pWin

    $gridVsc = $pWin.FindName("GridVscThemes")
    $gridVsc.ItemsSource = $installed
    $txtSearch = $pWin.FindName("TxtVscSearch")
    $txtSearch.add_TextChanged({
        $q = $txtSearch.Text.Trim()
        if ([string]::IsNullOrEmpty($q)) {
            $gridVsc.ItemsSource = $installed
        } else {
            $gridVsc.ItemsSource = @($installed | Where-Object { $_.Label -like "*$q*" -or $_.Extension -like "*$q*" })
        }
    })
    $doImport = {
        $sel = $gridVsc.SelectedItem
        if (-not $sel) { return }
        try {
            Import-CustomThemeFile $sel.FilePath
            $pWin.Close()
        } catch {
            [System.Windows.MessageBox]::Show($pWin, $_.Exception.Message, "VS Code Theme Import Error", "OK", "Error") | Out-Null
        }
    }
    $pWin.FindName("BtnVscImport").add_Click($doImport)
    $gridVsc.add_MouseDoubleClick($doImport)
    $pWin.FindName("BtnVscCancel").add_Click({ $pWin.Close() })
    $pWin.FindName("BtnVscBrowse").add_Click({
        $ofd = [Microsoft.Win32.OpenFileDialog]::new()
        $ofd.Title = "Import VS Code Theme File"
        $ofd.Filter = "VS Code Theme JSON (*.json;*.jsonc)|*.json;*.jsonc|All files (*.*)|*.*"
        $ofd.InitialDirectory = $scriptDir
        if ($ofd.ShowDialog($pWin) -eq $true) {
            try {
                Import-CustomThemeFile $ofd.FileName
                $pWin.Close()
            } catch {
                [System.Windows.MessageBox]::Show($pWin, $_.Exception.Message, "VS Code Theme Import Error", "OK", "Error") | Out-Null
            }
        }
    })
    [void]$pWin.ShowDialog()
})

$reloadAction = {
    if ($sandboxState.CustomFilePath -and (Test-Path -LiteralPath $sandboxState.CustomFilePath)) {
        try {
            Import-CustomThemeFile $sandboxState.CustomFilePath
        } catch {
            [System.Windows.MessageBox]::Show($window, $_.Exception.Message, "Theme JSON Reload Error", "OK", "Warning") | Out-Null
        }
    }
}
$sandboxBar.FindName("BtnSbReloadJson").add_Click($reloadAction)

$sandboxBar.FindName("BtnSbExportJson").add_Click({
    $pal = [PSRPMThemeRegistry]::GetPalette($sandboxState.CurrentTheme)
    $sfd = [Microsoft.Win32.SaveFileDialog]::new()
    $sfd.Title = "Export Starter Theme JSON"
    $sfd.Filter = "Theme JSON files (*.json)|*.json"
    $sfd.FileName = ("{0}-custom.json" -f $pal.Name.ToLowerInvariant())
    $sfd.InitialDirectory = $scriptDir
    if ($sfd.ShowDialog($window) -eq $true) {
        $exportObj = @{
            Name        = "$($pal.Name)Custom"
            DisplayName = "$($pal.DisplayName) Custom"
            IsDark      = [bool]$pal.IsDark
            BaseTheme   = [string]$pal.Name
            Brushes     = $pal.Brushes
            Rows        = $pal.Rows
            TabColors   = $pal.TabColors
            Legend      = $pal.Legend
            Banner      = $pal.Banner
        }
        $jsonOut = ConvertTo-PrettyThemeJson -Data $exportObj
        [System.IO.File]::WriteAllText($sfd.FileName, $jsonOut, [System.Text.UTF8Encoding]::new($false))
    }
})

$sandboxBar.FindName("BtnSbToggleFlash").add_Click({
    param($s, $e)
    $sandboxState.FlashEnabled = -not [bool]$sandboxState.FlashEnabled
    $s.Content = if ($sandboxState.FlashEnabled) { "Flash New/Exit: ON" } else { "Flash New/Exit: OFF" }
    if ($sandboxState.FlashEnabled) {
        if ($flashVms.Count -ge 2) {
            $flashVms[0].SetLifecycleState(1)
            $flashVms[1].SetLifecycleState(2)
        }
    } else {
        foreach ($fv in $flashVms) { $fv.SetLifecycleState(0) }
    }
})

$sandboxBar.FindName("BtnSbCycleBanner").add_Click({
    $sandboxState.BannerMode = ([int]$sandboxState.BannerMode + 1) % 4
    Update-BannerVisuals
})

$sandboxBar.FindName("BtnSbTogglePaused").add_Click({
    $sandboxState.IsPaused = -not [bool]$sandboxState.IsPaused
    Apply-SandboxTheme $sandboxState.CurrentTheme
})

# Wire MainWindow's own theme menus, toolbar buttons, legend chips & tabs
$cycleThemeAction = {
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($bn in [PSRPMThemeRegistry]::GetBuiltInNames()) { [void]$order.Add($bn) }
    if ($sandboxState.CustomThemeName -and (-not $order.Contains($sandboxState.CustomThemeName))) {
        [void]$order.Add($sandboxState.CustomThemeName)
    }
    $idx = $order.IndexOf($sandboxState.CurrentTheme)
    $nextIdx = if ($idx -lt 0) { 0 } else { ($idx + 1) % $order.Count }
    Apply-SandboxTheme $order[$nextIdx]
}

$menuPairs = @(
    @("MenuThemeLight", "Light"),
    @("MenuThemeDark", "Dark"),
    @("MenuThemeTokyoNight", "TokyoNight"),
    @("MenuThemeTokyoNightLight", "TokyoNightLight"),
    @("MenuThemeClassic", "Classic"),
    @("MenuThemeHighContrast", "HighContrast")
)
foreach ($mp in $menuPairs) {
    $mi = $window.FindName($mp[0])
    if ($mi) {
        $mi.Tag = $mp[1]
        $mi.add_Click({
            param($s, $e)
            Apply-SandboxTheme ([string]$s.Tag)
        })
    }
}
$mCycle = $window.FindName("MenuThemeCycle")
if ($mCycle) { $mCycle.add_Click($cycleThemeAction) }
$bCycle = $window.FindName("BtnToolbarTheme")
if ($bCycle) { $bCycle.add_Click($cycleThemeAction) }

$mExit = $window.FindName("MenuExit")
if ($mExit) { $mExit.add_Click({ $window.Close() }) }

$btnHigh = $window.FindName("BtnToggleHighlights")
if ($btnHigh) {
    $btnHigh.add_Click({
        $sandboxState.HighlightsEnabled = -not [bool]$sandboxState.HighlightsEnabled
        foreach ($pvm in $procVms) { $pvm.SetCategoryHighlights($sandboxState.HighlightsEnabled) }
    })
}

# Interactive Legend filter & Network sub-mode switching
foreach ($legBtnName in @("BtnLegendAll", "BtnLegendService", "BtnLegendOwn", "BtnLegendPackaged", "BtnLegendClear")) {
    $lb = $window.FindName($legBtnName)
    if (-not $lb) { continue }
    $lb.Tag = $legBtnName
    $lb.add_Click({
        param($s, $e)
        $sandboxState.CategoryFilter = switch ([string]$s.Tag) {
            "BtnLegendService"  { if ($sandboxState.CategoryFilter -eq "Service")  { "" } else { "Service" } }
            "BtnLegendOwn"      { if ($sandboxState.CategoryFilter -eq "Own")      { "" } else { "Own" } }
            "BtnLegendPackaged" { if ($sandboxState.CategoryFilter -eq "Packaged") { "" } else { "Packaged" } }
            default             { "" }
        }
        Update-LegendFilterVisuals
    })
}

$btnSockets = $window.FindName("BtnNetModeSockets")
$btnTime    = $window.FindName("BtnNetModeTimeline")
if ($btnSockets -and $btnTime) {
    $btnSockets.add_Click({
        $btnSockets.IsChecked = $true; $btnTime.IsChecked = $false
        $gridNetSockets.Visibility = [System.Windows.Visibility]::Visible
        $gridNetTimeline.Visibility = [System.Windows.Visibility]::Collapsed
    })
    $btnTime.add_Click({
        $btnSockets.IsChecked = $false; $btnTime.IsChecked = $true
        $gridNetSockets.Visibility = [System.Windows.Visibility]::Collapsed
        $gridNetTimeline.Visibility = [System.Windows.Visibility]::Visible
    })
}

# Keyboard shortcuts (Ctrl+D cycle, F5 reload custom JSON)
$window.add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::D -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        &$cycleThemeAction
        $e.Handled = $true
    } elseif ($e.Key -eq [System.Windows.Input.Key]::F5) {
        &$reloadAction
        $e.Handled = $true
    }
})

# Auto-Watch Timer (350ms UI-thread polling of LastWriteTimeUtc - zero cross-thread locks)
$watchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$watchTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$watchTimer.add_Tick({
    $chk = $sandboxBar.FindName("ChkSbWatch")
    if (-not $chk -or (-not [bool]$chk.IsChecked)) { return }
    $fp = $sandboxState.CustomFilePath
    if (-not $fp -or (-not (Test-Path -LiteralPath $fp))) { return }
    $lwt = [System.IO.File]::GetLastWriteTimeUtc($fp)
    if ($lwt -gt $sandboxState.CustomLastWrite) {
        try {
            Import-CustomThemeFile $fp
        } catch {
            # Ignore transient mid-save write errors while editor is flushing
        }
    }
})

$chkWatch = $sandboxBar.FindName("ChkSbWatch")
if ($chkWatch) {
    $chkWatch.IsChecked = [bool]$Watch
    if ($Watch) { $watchTimer.Start() }
    $chkWatch.add_Click({
        param($s, $e)
        if ([bool]$s.IsChecked) { $watchTimer.Start() } else { $watchTimer.Stop() }
    })
}

$window.add_Closed({
    $watchTimer.Stop()
    foreach ($dlg in @($sandboxState.OpenDialogs)) {
        if ($dlg -and $dlg.IsLoaded) { try { $dlg.Close() } catch {} }
    }
    if ($sandboxState.ContrastWindow -and $sandboxState.ContrastWindow.IsLoaded) {
        try { $sandboxState.ContrastWindow.Close() } catch {}
    }
})

# Initial Theme Application
if (-not [string]::IsNullOrWhiteSpace($ThemeFile)) {
    Import-CustomThemeFile $ThemeFile
} else {
    Apply-SandboxTheme $Theme
}

[void]$window.ShowDialog()
