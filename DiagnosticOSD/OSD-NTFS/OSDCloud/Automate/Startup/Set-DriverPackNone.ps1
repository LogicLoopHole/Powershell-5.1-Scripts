# Set-DriverPackNone.ps1
# Runs inside Invoke-OSDCloud process via Automate\Startup
# Prevents OSDCloud from downloading OEM DriverPacks
$Global:OSDCloud.DriverPackName = 'None'
Write-Host "  DriverPackName set to 'None' - using Custom\OfflineDrivers instead" -ForegroundColor Green

pause
