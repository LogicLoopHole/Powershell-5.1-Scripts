# 10-Invoke-DriverInjection.ps1
# Runs in WinPE post-apply - AFTER image applied, BEFORE reboot
# Injects offline drivers from USB into the offline OS based on manufacturer/model

Write-Host "========================================="
Write-Host "  Offline Driver Injection"
Write-Host "========================================="

# Get computer system info
$computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct

# Determine manufacturer and model based on vendor
$Manufacturer = $computer.Vendor
if ($Manufacturer -eq "LENOVO") {
    # Lenovo stores readable model name in Version (e.g., "ThinkPad T14s Gen 3")
    $ModelName = $computer.Version
} else {
    # Other manufacturers (HP, Microsoft, etc.) use Name field
    $ModelName = $computer.Name
}

# Find USB NTFS volume by label
$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $USB) {
    Write-Warning "ERROR: DeployData volume not found. Cannot inject drivers."
    pause
    exit 1
}

$Source = "$($USB):\Drivers\$Manufacturer\$ModelName"

if (Test-Path $Source) {
    # Stage drivers to local disk before injection
    # Injecting directly from USB can cause issues if the drive letter shifts
    $DriverStage = "C:\Drivers"
    New-Item -Path $DriverStage -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$Source\*" -Destination $DriverStage -Recurse -Force

    # Inject into offline OS
    Add-WindowsDriver -Path "C:\" -Driver $DriverStage -Recurse -ErrorAction SilentlyContinue | Out-Null

    Write-Host "  Drivers injected for: $Manufacturer $ModelName"
    Write-Host "  Installed drivers:"
    Get-WindowsDriver -Path "C:\" | Where-Object { $_.Driver -match 'oem' } | ForEach-Object {
        Write-Host "    $($_.Driver) - $($_.ClassName)"
    }
} else {
    Write-Warning "  No driver folder found for $Manufacturer $ModelName"
    Write-Warning "  Looked in: $Source"
}

Write-Host ""

pause
