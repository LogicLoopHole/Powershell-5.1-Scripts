# 05-Defer-Updates.ps1
# Runs in WinPE Shutdown - BEFORE reboot
# Disables automatic Windows Update via offline registry policy keys
# Uses the GPO policy path, not UX Settings - OOBE will not overwrite these
# GPO/Intune will override these keys once policies apply post-domain-join

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Deferring Windows Updates" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$HivePath = "C:\Windows\System32\config\SOFTWARE"
$MountKey = "HKLM\OfflineSoftware"
$PolicyPath = "$MountKey\Policies\Microsoft\Windows\WindowsUpdate\AU"

# Load offline registry hive
Write-Host "  Loading offline SOFTWARE hive..." -ForegroundColor Gray
reg load $MountKey $HivePath 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Failed to load registry hive. Updates will not be deferred." -ForegroundColor Yellow
    pause
    exit 0
}

# Create policy key path and disable automatic updates
# NoAutoUpdate = 1 is the same key GPO uses to disable automatic updates
# OOBE does not reset policy keys - only GPO/Intune can override them
reg add $PolicyPath /v NoAutoUpdate /t REG_DWORD /d 1 /f 2>$null

# Unload hive
Write-Host "  Unloading hive..." -ForegroundColor Gray
[gc]::Collect()
Start-Sleep -Seconds 1
reg unload $MountKey 2>$null

Write-Host "  Automatic updates disabled via policy." -ForegroundColor Green
Write-Host "  GPO/Intune will override after domain join." -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
pause
