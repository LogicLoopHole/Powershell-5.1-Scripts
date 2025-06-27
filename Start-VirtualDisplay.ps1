<#
.SYNOPSIS
    Installs the MTT Virtual Display Driver.
.DESCRIPTION
    This script attempts to automate the installation of the MTT Virtual Display Driver.
	https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/25.5.2
    It stages the driver in the Windows Driver Store and then creates the
    virtual device instance using devcon.exe. For user transparency and security,
	this script intentionally preserves the Windows GUI confirmation prompt,
	allowing the user to manually approve or deny the driver installation.

    Prerequisites:
    1. Must be run as Administrator.
    2. The script must be in the same folder as:
       - The driver zip file ('Signed-Driver-v24.12.24-x64.zip')
       - devcon.exe

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
$driverZipFile = "Signed-Driver-v24.12.24-x64.zip"
$infName = "MttVDD.inf"
$hardwareId = "Root\MttVDD"

# --- Script boilerplate and prerequisite checks ---

# Get the directory where this script is located
$scriptRoot = $PSScriptRoot

# Define full paths for our prerequisites and temporary work area
$devconPath = Join-Path $scriptRoot "devcon.exe"
$zipPath = Join-Path $scriptRoot $driverZipFile
$tempDir = Join-Path $scriptRoot "temp_driver"

# Check for Administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator. Please right-click and 'Run with PowerShell' as Administrator."
    # Pause to allow user to see the error before the window closes
    if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
    Exit 1
}

# Check if devcon.exe exists
if (-NOT (Test-Path -Path $devconPath)) {
    Write-Error "CRITICAL: devcon.exe was not found in the script directory: $scriptRoot"
    if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
    Exit 1
}

# Check if the driver zip file exists
if (-NOT (Test-Path -Path $zipPath)) {
    Write-Error "CRITICAL: The driver zip file '$driverZipFile' was not found in the script directory: $scriptRoot"
    if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
    Exit 1
}


# --- Main Installation Logic ---

Write-Host "--- Starting MTT Virtual Display Driver Installation ---" -ForegroundColor Green

try {
    # Step 1: Create a clean temporary directory for the driver files
    Write-Host "Step 1: Preparing temporary working directory..."
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
    New-Item -Path $tempDir -ItemType Directory | Out-Null

    # Step 2: Extract the driver from the zip file
    Write-Host "Step 2: Extracting driver files from '$driverZipFile'..."
    Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

    # Step 3: Stage the driver package in the Windows Driver Store
    Write-Host "Step 3: Staging driver with pnputil..."
    $infPath = Join-Path $tempDir $infName
    pnputil /add-driver $infPath
    # Small pause to ensure the system has processed the change
    Start-Sleep -Seconds 2

    # Step 4: Create the virtual device instance using devcon
    Write-Host "Step 4: Creating device instance with devcon..."
    # Use the call operator (&) to execute the command with its path
    & $devconPath install $infPath $hardwareId

    Write-Host ""
    Write-Host "--- SUCCESS ---" -ForegroundColor Green
    Write-Host "The MTT Virtual Display Driver has been installed successfully."
    Write-Host "You can verify the installation in Device Manager under 'Display adapters'."
}
catch {
    # If any command fails, this block will execute
    Write-Error "An error occurred during installation."
    Write-Error "Error Details: $($_.Exception.Message)"
    Write-Error "Script execution halted."
}
finally {
    # Step 5: Clean up the temporary directory. This runs whether successful or not.
    Write-Host "Step 5: Cleaning up temporary files..."
    if (Test-Path -Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Installation script finished."
# Pause to allow user to see the final messages
if ($Host.Name -eq "ConsoleHost") { Read-Host -Prompt "Press Enter to exit" }
