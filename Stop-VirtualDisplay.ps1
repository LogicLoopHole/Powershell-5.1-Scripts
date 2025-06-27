<#
.SYNOPSIS
    Uninstalls the MTT Virtual Display Driver.
.DESCRIPTION
    This script automates the complete removal of the MTT Virtual Display Driver.
	https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.5.2
    It removes the virtual device instance and then deletes the driver package
    from the Windows Driver Store.

    Prerequisites:
    1. Must be run as Administrator.
    2. devcon.exe must be in the same folder as this script.
	
	About devcon.exe:
	This utility is part of the Microsoft Windows Driver Kit (WDK) but is often
	included with vendor-specific hardware utilities (e.g., from NVIDIA, Gigabyte).
	DO NOT download devcon.exe from random third-party websites, only trusted verified sources.
#>

#
# The MIT License (MIT)
#
# Copyright (c) 2025 LogicLoopHole
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

# --- Configuration ---
$hardwareId = "Root\MttVDD"
$originalInfName = "MttVDD.inf"

# --- Script boilerplate and prerequisite checks ---

$scriptRoot = $PSScriptRoot
$devconPath = Join-Path $scriptRoot "devcon.exe"

# Check for Administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator. Please right-click and 'Run with PowerShell' as Administrator."
    if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
    Exit 1
}

# Check if devcon.exe exists
if (-NOT (Test-Path -Path $devconPath)) {
    Write-Error "CRITICAL: devcon.exe was not found in the script directory: $scriptRoot"
    if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
    Exit 1
}

# --- Main Uninstall Logic ---
Write-Host "--- Starting MTT Virtual Display Driver Uninstall ---" -ForegroundColor Yellow

try {
    # Step 1: Remove the virtual device instance using devcon
    Write-Host "Step 1: Searching for and removing device instance with Hardware ID '$hardwareId'..."
    $devconOutput = & $devconPath remove $hardwareId
    
    if ($devconOutput -match "No matching devices found") {
        Write-Host "Device instance not found. It may have already been removed. Proceeding to driver package removal."
    } elseif ($devconOutput -match "Removed") {
        Write-Host "Device instance successfully removed."
    } else {
        # This will catch other messages or silent failures
        Write-Host "Devcon output: $devconOutput"
    }

    # Small pause to let the system process the removal
    Start-Sleep -Seconds 2

    # Step 2: Find and delete the driver package from the Driver Store
    Write-Host "Step 2: Searching for driver package '$originalInfName' to delete..."
    
    # This command finds the driver by its original name and gets its published name (oemXX.inf)
    $driver = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.OriginalFileName -eq $originalInfName }

    if ($driver) {
        $publishedName = $driver.InfName
        Write-Host "Found driver package '$publishedName'. Deleting with pnputil..."
        
        # Use pnputil to force the deletion of the driver package
        pnputil /delete-driver $publishedName /uninstall /force
        
        Write-Host "Driver package '$publishedName' has been deleted."
    } else {
        Write-Host "Driver package '$originalInfName' not found in the Driver Store. Assumed already uninstalled."
    }
    
    Write-Host ""
    Write-Host "--- SUCCESS ---" -ForegroundColor Green
    Write-Host "The MTT Virtual Display Driver has been uninstalled."

}
catch {
    Write-Error "An error occurred during uninstallation."
    Write-Error "Error Details: $($_.Exception.Message)"
    Write-Error "Script execution halted."
}

Write-Host ""
Write-Host "Uninstall script finished."
if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
