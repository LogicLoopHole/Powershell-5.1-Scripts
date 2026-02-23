# 01-Check-Manufacturer.ps1
# Validates that driver folder exists for this model before proceeding

Add-Type -AssemblyName System.Windows.Forms

# Get computer system info
$computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$bios = Get-CimInstance -ClassName Win32_BIOS

# Determine manufacturer and model based on vendor
$Manufacturer = $computer.Vendor
if ($Manufacturer -eq "LENOVO") {
    # Lenovo stores readable model name in Version (e.g., "ThinkCentre M920q")
    $ModelName = $computer.Version
} else {
    # Other manufacturers (Xen, HP, Microsoft, etc.) use Name field
    $ModelName = $computer.Name
}

# Use OSDCloud's Find-OSDCloudFile to locate driver folder across all drives
# This searches D-Z (except X:) for the path \Custom\OfflineDrivers\<Manufacturer>\<Model>
$DriverPath = "\Custom\OfflineDrivers\$Manufacturer\$ModelName"
$DriverFolder = Find-OSDCloudFile -Name "*" -Path $DriverPath | Select-Object -First 1

# Alternative: Manual scan if Find-OSDCloudFile doesn't work for folders
if (-not $DriverFolder) {
    # Scan all drives D-Z except X (WinPE) and C (will be wiped)
    $Drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Name -match '^[D-W]$|^[Y-Z]$'
    }

    foreach ($Drive in $Drives) {
        $TestPath = Join-Path -Path "$($Drive.Root)" -ChildPath $DriverPath
        if (Test-Path -Path $TestPath) {
            $DriverFolder = Get-Item -Path $TestPath
            break
        }
    }
}

# Check if driver folder was found
if (-not $DriverFolder) {
    $message = @"
Please provide screenshot to the Breakfix Engineering Team:

Manufacturer: $Manufacturer
Model Name: $ModelName
Raw Name: $($computer.Name)
Version: $($computer.Version)
Serial Number: $($bios.SerialNumber)

Expected Driver Path: $DriverPath
Searched drives: D-Z (except X)

DO NOT PROCEED! Your image will be UNSUPPORTED.
"@
    [System.Windows.Forms.MessageBox]::Show($message, "UNSUPPORTED MODEL DETECTED", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)

    # Halt deployment
    exit 1
}

# Model is supported - continue
Write-Host "Driver folder found: $($DriverFolder.FullName)" -ForegroundColor Green

pause
