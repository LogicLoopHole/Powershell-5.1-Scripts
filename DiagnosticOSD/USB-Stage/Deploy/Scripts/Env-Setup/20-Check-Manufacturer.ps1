#
# The MIT License (MIT)
#
# Copyright (c) 2026 LogicLoopHole
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

# 20-Check-Manufacturer.ps1
# Env-Setup - Validates that driver folder exists for this model before proceeding.
# Persists Manufacturer, ModelName, and DriverFolder to X:\Deploy\Hardware.txt
# so 30-Driver-Injection.ps1 can reuse them without re-querying WMI.

Add-Type -AssemblyName System.Windows.Forms

Write-Host "`n=== Check Manufacturer ===" -ForegroundColor Cyan

$Computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$Bios     = Get-CimInstance -ClassName Win32_BIOS

$Manufacturer = $Computer.Vendor
if ($Manufacturer -eq "LENOVO") {
    # Lenovo stores readable model name in Version (e.g., "ThinkPad T14s Gen 3")
    $ModelName = $Computer.Version
} else {
    # Other manufacturers (HP, Microsoft, etc.) use Name field
    $ModelName = $Computer.Name
}

# Scan all drives D-Z except X (WinPE ramdisk) and C (will be wiped)
$DriverPath   = "\Drivers\$Manufacturer\$ModelName"
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

if (-not $DriverFolder) {
    $message = @"
Please provide screenshot to the Breakfix Engineering Team:

Manufacturer: $Manufacturer
Model Name:   $ModelName
Raw Name:     $($Computer.Name)
Version:      $($Computer.Version)
Serial Number:$($Bios.SerialNumber)

Expected Driver Path: $DriverPath
Searched drives: D-Z (except X)

This model has no matching driver pack. Generic drivers will be used.
Image will be UNSUPPORTED but deployment can continue.
"@
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        "UNSUPPORTED MODEL DETECTED",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null

    Write-Warning "Unsupported model: $Manufacturer $ModelName - continuing without model-specific drivers."
}

Write-Host "Manufacturer  : $Manufacturer"
Write-Host "Model         : $ModelName"
if ($DriverFolder) {
    Write-Host "Driver folder : $($DriverFolder.FullName)"
} else {
    Write-Host "Driver folder : (none - unsupported model)"
}

# Persist for downstream scripts (30-Driver-Injection).
# DriverFolder may be empty - 30 will skip injection in that case.
$ScratchDir   = "X:\Deploy"
$HardwareFile = "$ScratchDir\Hardware.txt"
New-Item -Path $ScratchDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$DriverFolderValue = if ($DriverFolder) { $DriverFolder.FullName } else { "" }
@"
Manufacturer=$Manufacturer
ModelName=$ModelName
DriverFolder=$DriverFolderValue
"@ | Out-File -FilePath $HardwareFile -Encoding ascii -Force

pause
