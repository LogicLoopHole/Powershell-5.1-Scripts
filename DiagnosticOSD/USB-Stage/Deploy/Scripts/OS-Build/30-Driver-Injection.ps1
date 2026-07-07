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

# 30-Driver-Injection.ps1
# OS-Build - Runs in WinPE post-apply - AFTER image applied, BEFORE reboot.
# Injects offline drivers into the offline OS based on manufacturer/model.
# Reads Manufacturer, ModelName, DriverFolder from X:\Deploy\Hardware.txt
# (set by Env-Setup\20-Check-Manufacturer.ps1).

Write-Host "`n=== Offline Driver Injection ===" -ForegroundColor Cyan

$HardwareFile = "X:\Deploy\Hardware.txt"
if (-not (Test-Path $HardwareFile)) {
    Write-Warning "Hardware.txt not found at $HardwareFile. Ensure 20-Check-Manufacturer.ps1 completed."
    pause
    return
}

Get-Content $HardwareFile | ForEach-Object {
    if ($_ -match '^(\w+)=(.*)$') { Set-Variable -Name $Matches[1] -Value $Matches[2] }
}

if (-not $DriverFolder) {
    Write-Warning "No driver folder for $Manufacturer $ModelName - skipping driver injection."
    pause
    return
}
if (-not (Test-Path $DriverFolder)) {
    Write-Warning "Driver folder no longer accessible: $DriverFolder - skipping driver injection."
    pause
    return
}

# Stage drivers locally before injection - Add-WindowsDriver is more reliable
# from a local path than from a USB volume, especially under load.
$DriverStage = "C:\Drivers"
New-Item -Path $DriverStage -ItemType Directory -Force | Out-Null
Copy-Item -Path "$DriverFolder\*" -Destination $DriverStage -Recurse -Force

Add-WindowsDriver -Path "C:\" -Driver $DriverStage -Recurse | Out-Null

Write-Host "Drivers injected for: $Manufacturer $ModelName"
Write-Host "Installed drivers:"
Get-WindowsDriver -Path "C:\" | Where-Object { $_.Driver -match 'oem' } | ForEach-Object {
    Write-Host "  $($_.Driver) - $($_.ClassName)"
}

pause
