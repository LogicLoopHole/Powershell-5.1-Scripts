# 01-Invoke-DriverInjection.ps1
# Runs in WinPE Shutdown - AFTER image applied, BEFORE reboot
# Injects offline drivers from USB based on manufacturer/model

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Custom Offline Driver Install" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Get computer system info
$computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct

# Determine manufacturer and model based on vendor
$Manufacturer = $computer.Vendor
if ($Manufacturer -eq "LENOVO") {
    # Lenovo stores readable model name in Version (e.g., "ThinkCentre M920q")
    $ModelName = $computer.Version
} else {
    # Other manufacturers (Xen, HP, Microsoft, etc.) use Name field
    $ModelName = $computer.Name
}

$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -match 'OSDCloudUSB' }).DriveLetter
$Source = "$($USB):\Custom\OfflineDrivers\$Manufacturer\$ModelName"

if (Test-Path $Source) {
    New-Item -Path "C:\Drivers" -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$Source\*" -Destination "C:\Drivers" -Recurse -Force
    Add-WindowsDriver -Path "C:\" -Driver "C:\Drivers" -Recurse -ErrorAction SilentlyContinue | Out-Null

    Write-Host "  Installed drivers:" -ForegroundColor Green
    Get-WindowsDriver -Path "C:\" | Where-Object { $_.Driver -match 'oem' } | ForEach-Object {
        Write-Host "    $($_.Driver) - $($_.ClassName)" -ForegroundColor Gray
    }
}
else {
    Write-Host "  No offline drivers found for $Manufacturer $ModelName" -ForegroundColor Yellow
    Write-Host "  Looked in: $Source" -ForegroundColor Gray
}

Write-Host ""

pause
