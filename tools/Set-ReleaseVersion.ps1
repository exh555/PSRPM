# Requires -Version 5.1
<#
.SYNOPSIS
    Synchronizes the project release version across all PSRPM manifests, UI views, telemetry headers, and documentation.

.PARAMETER NewVersion
    The semantic version string to apply (e.g., 1.6.3).

.PARAMETER ReleaseNotes
    Optional multi-line release notes string to embed into PrivateData.PSData.ReleaseNotes in PSRPM.psd1.

.PARAMETER SkipTest
    Skip executing Test-ReleaseReadiness.ps1 after version synchronization.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$NewVersion,

    [Parameter(Mandatory = $false)]
    [string]$ReleaseNotes,

    [switch]$SkipTest
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " PSRPM Release Version Synchronizer: v$NewVersion" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# 1. PSRPM/PSRPM.psd1
$psd1Path = Join-Path $repoRoot "PSRPM\PSRPM.psd1"
$psd1Content = [System.IO.File]::ReadAllText($psd1Path, $utf8NoBom)
$psd1Content = [System.Text.RegularExpressions.Regex]::Replace($psd1Content, "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion     = '$NewVersion'")
if (-not [string]::IsNullOrWhiteSpace($ReleaseNotes)) {
    $notesBlock = "ReleaseNotes = @'`n$ReleaseNotes`n'@"
    $psd1Content = [System.Text.RegularExpressions.Regex]::Replace($psd1Content, "ReleaseNotes\s*=\s*@'[\s\S]*?'@", $notesBlock)
}
[System.IO.File]::WriteAllText($psd1Path, $psd1Content, $utf8NoBom)
Write-Host "  [OK] Synchronized PSRPM\PSRPM.psd1 -> v$NewVersion" -ForegroundColor Green

# 2. CHANGELOG.md
$changelogPath = Join-Path $repoRoot "CHANGELOG.md"
$clContent = [System.IO.File]::ReadAllText($changelogPath, $utf8NoBom)
if ($clContent -notmatch "## \[$([regex]::Escape($NewVersion))\]") {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $newSection = "## [Unreleased]`n`n## [$NewVersion] - $today"
    $clContent = [System.Text.RegularExpressions.Regex]::Replace($clContent, "## \[Unreleased\]", $newSection)
    [System.IO.File]::WriteAllText($changelogPath, $clContent, $utf8NoBom)
    Write-Host "  [OK] Added [$NewVersion] section to CHANGELOG.md" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] CHANGELOG.md already contains section for [$NewVersion]" -ForegroundColor Yellow
}

# 3. README.md Version Badge
$readmePath = Join-Path $repoRoot "README.md"
$readmeContent = [System.IO.File]::ReadAllText($readmePath, $utf8NoBom)
$readmeContent = [System.Text.RegularExpressions.Regex]::Replace($readmeContent, "badge/version-[^-\s\)]+-0284c7\.svg", "badge/version-$NewVersion-0284c7.svg")
[System.IO.File]::WriteAllText($readmePath, $readmeContent, $utf8NoBom)
Write-Host "  [OK] Synchronized README.md version badge -> $NewVersion" -ForegroundColor Green

# 4. PSRPM/UI/HelpWindow.xaml
$helpXamlPath = Join-Path $repoRoot "PSRPM\UI\HelpWindow.xaml"
$helpContent = [System.IO.File]::ReadAllText($helpXamlPath, $utf8NoBom)
$helpContent = [System.Text.RegularExpressions.Regex]::Replace($helpContent, 'x:Name="TxtHeaderBadge"\s+Text="v[^"]+"', "x:Name=`"TxtHeaderBadge`" Text=`"v$NewVersion`"")
$helpContent = [System.Text.RegularExpressions.Regex]::Replace($helpContent, 'x:Name="TxtAboutVersion"\s+Text="[^"]+"', "x:Name=`"TxtAboutVersion`" Text=`"$NewVersion`"")
[System.IO.File]::WriteAllText($helpXamlPath, $helpContent, $utf8NoBom)
Write-Host "  [OK] Synchronized PSRPM\UI\HelpWindow.xaml badges -> v$NewVersion" -ForegroundColor Green

# 5. PSRPM/Private/DataCollector.ps1 (Protocol Header)
$collectorPath = Join-Path $repoRoot "PSRPM\Private\DataCollector.ps1"
$colContent = [System.IO.File]::ReadAllText($collectorPath, $utf8NoBom)
$colContent = [System.Text.RegularExpressions.Regex]::Replace($colContent, '"colVer":"[^"]+"', "`"colVer`":`"$NewVersion`"")
[System.IO.File]::WriteAllText($collectorPath, $colContent, $utf8NoBom)
Write-Host "  [OK] Synchronized PSRPM\Private\DataCollector.ps1 colVer -> $NewVersion" -ForegroundColor Green

# 6. Verification Gate
if (-not $SkipTest) {
    Write-Host ""
    Write-Host "Executing automated release readiness verification..." -ForegroundColor Yellow
    $testScript = Join-Path $repoRoot "Tests\Test-ReleaseReadiness.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $testScript
    if ($LASTEXITCODE -ne 0) {
        throw "Release readiness verification failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Host "  [SKIP] Automated release readiness test skipped per -SkipTest." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "All assets successfully synchronized to v$NewVersion!" -ForegroundColor Green
