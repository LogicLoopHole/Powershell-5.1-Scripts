# 02-Check-Manufacturer.ps1
# Validates that driver folder exists for this model before proceeding

Add-Type -AssemblyName System.Windows.Forms

# Get computer system info
$computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$bios     = Get-CimInstance -ClassName Win32_BIOS

# Determine manufacturer and model based on vendor
$Manufacturer = $computer.Vendor
if ($Manufacturer -eq "LENOVO") {
    # Lenovo stores readable model name in Version (e.g., "ThinkPad T14s Gen 3")
    $ModelName = $computer.Version
} else {
    # Other manufacturers (HP, Microsoft, etc.) use Name field
    $ModelName = $computer.Name
}

# Scan all drives D-Z except X (WinPE ramdisk) and C (will be wiped)
$DriverPath = "\Drivers\$Manufacturer\$ModelName"
$DriverFolder = $null

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

# Check if driver folder was found
if (-not $DriverFolder) {
    $message = @"
Please provide screenshot to the Breakfix Engineering Team:

Manufacturer: $Manufacturer
Model Name:   $ModelName
Raw Name:     $($computer.Name)
Version:      $($computer.Version)
Serial Number:$($bios.SerialNumber)

Expected Driver Path: $DriverPath
Searched drives: D-Z (except X)

DO NOT PROCEED! Your image will be UNSUPPORTED.
"@
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        "UNSUPPORTED MODEL DETECTED",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    exit 1
}

# Model is supported - store for use by later phases
Write-Host "Manufacturer : $Manufacturer"
Write-Host "Model        : $ModelName"
Write-Host "Driver folder: $($DriverFolder.FullName)"

pause
