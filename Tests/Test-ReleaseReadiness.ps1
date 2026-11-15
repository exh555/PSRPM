# Requires -Version 5.1
# Test-ReleaseReadiness.ps1 - Validates that PSRPM is fully documented, synchronized, and ready for publication

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " PSRPM Release Readiness & Version Synchronization Checker" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$root = Split-Path -Parent $PSScriptRoot
$psd1Path = Join-Path $root "PSRPM\PSRPM.psd1"
$readmePath = Join-Path $root "README.md"
$changelogPath = Join-Path $root "CHANGELOG.md"
$testScript = Join-Path $root "Tests\Test-PSRPMEngine.ps1"

# 1. Validate Module Manifest
Write-Host "[CHECK 1] Validating PSRPM.psd1 manifest..." -ForegroundColor Yellow
$manifest = Test-ModuleManifest -Path $psd1Path -ErrorAction Stop
$modVer = $manifest.Version.ToString()
Write-Host "  [PASS] Manifest is valid. ModuleVersion: $modVer" -ForegroundColor Green

# 2. Validate ReleaseNotes in Manifest
Write-Host "[CHECK 2] Validating PrivateData.PSData.ReleaseNotes..." -ForegroundColor Yellow
$manifestData = Import-PowerShellDataFile -Path $psd1Path
$relNotes = $manifestData.PrivateData.PSData.ReleaseNotes
if ([string]::IsNullOrWhiteSpace($relNotes)) {
    throw "PrivateData.PSData.ReleaseNotes is empty in $psd1Path"
}
Write-Host "  [PASS] ReleaseNotes present ($($relNotes.Split("`n").Count) lines)." -ForegroundColor Green

# 3. Validate CHANGELOG.md
Write-Host "[CHECK 3] Validating CHANGELOG.md synchronization..." -ForegroundColor Yellow
if (-not (Test-Path $changelogPath)) {
    throw "CHANGELOG.md not found at $changelogPath"
}
$changelogContent = Get-Content -Path $changelogPath -Raw
if ($changelogContent -notmatch "## \[$modVer\]") {
    throw "CHANGELOG.md does not contain section for version [$modVer]"
}
Write-Host "  [PASS] CHANGELOG.md contains documentation for version [$modVer]." -ForegroundColor Green

# 4. Validate README.md Version References
Write-Host "[CHECK 4] Validating README.md version references..." -ForegroundColor Yellow
$readmeContent = Get-Content -Path $readmePath -Raw
if ($readmeContent -notmatch "badge/version-$modVer") {
    throw "README.md badge does not match manifest version $modVer"
}
if ($readmeContent -notmatch ('\*\*PSRPM \(`v' + [regex]::Escape($modVer) + '`\)\*\*')) {
    throw "README.md comparison table header does not match manifest version v$modVer"
}
if ($readmeContent -notmatch ('SemVer \(`' + [regex]::Escape($modVer) + '`\)')) {
    throw "README.md changelog footer does not match manifest version $modVer"
}
Write-Host "  [PASS] README.md badge, table header, and footer match version $modVer." -ForegroundColor Green

# 5. Validate HelpWindow.xaml, PSRPM.psm1, and docs/USER_GUIDE.md Version Synchronization
Write-Host "[CHECK 5] Validating HelpWindow.xaml, PSRPM.psm1, and USER_GUIDE.md version synchronization..." -ForegroundColor Yellow
$helpXamlPath = Join-Path $root "PSRPM\UI\HelpWindow.xaml"
$helpXamlContent = Get-Content -Path $helpXamlPath -Raw
if ($helpXamlContent -notmatch "x:Name=`"TxtHeaderBadge`"\s+Text=`"v$modVer`"") {
    throw "HelpWindow.xaml TxtHeaderBadge does not match manifest version v$modVer"
}
if ($helpXamlContent -notmatch "x:Name=`"TxtAboutVersion`"\s+Text=`"$modVer`"") {
    throw "HelpWindow.xaml TxtAboutVersion does not match manifest version $modVer"
}
$psm1Path = Join-Path $root "PSRPM\PSRPM.psm1"
$psm1Content = Get-Content -Path $psm1Path -Raw
if ($psm1Content -notmatch '\$script:AppVersion\s*=\s*"' + [regex]::Escape($modVer) + '"') {
    throw "PSRPM.psm1 AppVersion fallback does not match manifest version $modVer"
}
$userGuidePath = Join-Path $root "docs\USER_GUIDE.md"
if (Test-Path $userGuidePath) {
    $ugContent = Get-Content -Path $userGuidePath -Raw
    if ($ugContent -notmatch "Version details \(v$([regex]::Escape($modVer))\)") {
        throw "docs/USER_GUIDE.md About Tab version does not match manifest version v$modVer"
    }
}
Write-Host "  [PASS] HelpWindow.xaml, PSRPM.psm1, and docs/USER_GUIDE.md match manifest version $modVer." -ForegroundColor Green

# 6. Run Automated Engine Verification Suite
Write-Host "[CHECK 6] Running Automated 12-Suite Verification..." -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $testScript
if ($LASTEXITCODE -ne 0) {
    throw "Automated verification suite failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " PSRPM v$modVer IS 100% READY FOR PUBLICATION!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
