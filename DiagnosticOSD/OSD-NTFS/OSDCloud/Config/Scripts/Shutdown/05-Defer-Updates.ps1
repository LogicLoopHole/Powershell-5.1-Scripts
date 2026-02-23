# 04-Defer-Updates.ps1
# Runs in WinPE Shutdown - AFTER Configure-FirstLogon, BEFORE reboot
# Pauses Windows Update for 7 days via offline registry
# GPO/Intune will override these keys once policies apply post-domain-join

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Deferring Windows Updates (7 days)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$HivePath = "C:\Windows\System32\config\SOFTWARE"
$MountKey = "HKLM\OfflineSoftware"
$RegPath  = "$MountKey\Microsoft\WindowsUpdate\UX\Settings"

# Calculate pause window
$StartDate  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$ExpiryDate = (Get-Date).AddDays(7).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Load offline registry hive
Write-Host "  Loading offline SOFTWARE hive..." -ForegroundColor Gray
reg load $MountKey $HivePath 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Failed to load registry hive. Updates will not be deferred." -ForegroundColor Yellow
    pause
    exit 0
}

# Write pause keys
reg add $RegPath /v PauseUpdatesStartTime /t REG_SZ /d $StartDate /f 2>$null
reg add $RegPath /v PauseUpdatesExpiryTime /t REG_SZ /d $ExpiryDate /f 2>$null

# Unload hive
Write-Host "  Unloading hive..." -ForegroundColor Gray
[gc]::Collect()
Start-Sleep -Seconds 1
reg unload $MountKey 2>$null

Write-Host "  Windows Update paused until $ExpiryDate" -ForegroundColor Green
Write-Host "  GPO/Intune policies will override after domain join." -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
pause
