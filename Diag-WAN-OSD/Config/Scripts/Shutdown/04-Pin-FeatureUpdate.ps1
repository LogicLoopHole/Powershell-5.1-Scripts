# 06-Pin-FeatureUpdate.ps1
# Runs in WinPE Shutdown - AFTER Defer-Updates
# Pins Windows to a specific feature update version via offline registry
# Prevents OOBE or Windows Update from upgrading to a newer version (e.g., 25H2)
# Uses the same GPO policy path as "Select target Feature Update version"
# GPO/Intune will override these keys once policies apply post-domain-join

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Pinning Feature Update Version" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ============================================================================
# CONFIGURATION
# ============================================================================
$TargetVersion = "24H2"
# ============================================================================

$HivePath = "C:\Windows\System32\config\SOFTWARE"
$MountKey = "HKLM\OfflineSoftware"
$PolicyPath = "$MountKey\Policies\Microsoft\Windows\WindowsUpdate"

# Load offline registry hive
Write-Host "  Loading offline SOFTWARE hive..." -ForegroundColor Gray
reg load $MountKey $HivePath 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Failed to load registry hive. Version will not be pinned." -ForegroundColor Yellow
    pause
    exit 0
}

# TargetReleaseVersion = 1 enables the pin
# TargetReleaseVersionInfo = "24H2" sets the ceiling
# ProductVersion = "Windows 11" ensures correct product targeting
reg add $PolicyPath /v TargetReleaseVersion /t REG_DWORD /d 1 /f 2>$null
reg add $PolicyPath /v TargetReleaseVersionInfo /t REG_SZ /d $TargetVersion /f 2>$null
reg add $PolicyPath /v ProductVersion /t REG_SZ /d "Windows 11" /f 2>$null

# Unload hive
Write-Host "  Unloading hive..." -ForegroundColor Gray
[gc]::Collect()
Start-Sleep -Seconds 1
reg unload $MountKey 2>$null

Write-Host "  Windows pinned to $TargetVersion." -ForegroundColor Green
Write-Host "  Feature update upgrades beyond $TargetVersion are blocked." -ForegroundColor Gray
Write-Host "  GPO/Intune will override after domain join." -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
pause
