# Start-Deployment.ps1
# Master orchestrator - lives on N:\Deploy\ (NTFS partition)
# Dot-sources all phase scripts so variables are shared across phases
# Called by X:\Deploy\Launch.ps1 after WinPE locates the DeployData volume

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# ============================================================================
# SHARED SCOPE - variables set here are available to all dot-sourced scripts
# ============================================================================

# Drive letter of the DeployData NTFS partition - detected by the launcher
# and inherited from the calling scope. Fallback in case of standalone run.
if (-not $DeployDrive) {
    $DeployDrive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
}

if (-not $DeployDrive) {
    Write-Error "DeployData volume not found. Cannot continue."
    pause
    exit 1
}

$ScriptsPath = "${DeployDrive}:\Deploy\Scripts"

# Variables populated by phase scripts and used by later phases:
#   $Manufacturer   - set by 02-Check-Manufacturer.ps1
#   $ModelName      - set by 02-Check-Manufacturer.ps1
#   $ComputerName   - set by 03-Get-HostnameUserPrompt.ps1
#   $OSDrive        - set by 05-Initialize-Disk.ps1
#   $EFIDrive       - set by 05-Initialize-Disk.ps1

# ============================================================================
# HELPER
# ============================================================================
function Invoke-Phase {
    param(
        [string]$Name,
        [string]$Script
    )
    $FullPath = Join-Path $ScriptsPath $Script
    Write-Host ""
    Write-Host "========================================="
    Write-Host "  $Name"
    Write-Host "========================================="

    if (-not (Test-Path $FullPath)) {
        Write-Error "Phase script not found: $FullPath"
        pause
        exit 1
    }

    try {
        . $FullPath
    }
    catch {
        Write-Error "Phase failed [$Name]: $_"
        pause
        exit 1
    }
}

# ============================================================================
# PRE-IMAGING
# ============================================================================
# Invoke-Phase "Content Sync"          "01-Sync-Content.ps1"  # TEMP: skipped during initial testing
Invoke-Phase "Manufacturer Check"    "02-Check-Manufacturer.ps1"
Invoke-Phase "Hostname Collection"   "03-Get-HostnameUserPrompt.ps1"

# ============================================================================
# DISK AND IMAGE
# ============================================================================
Invoke-Phase "Disk Initialization"   "05-Initialize-Disk.ps1"

# Read drive assignments written by 05-Initialize-Disk.ps1
# (dot-sourcing inside Invoke-Phase does not propagate variables to this scope)
$StateFile = "X:\Deploy\DeployState.txt"
if (-not (Test-Path $StateFile)) {
    Write-Error "DeployState.txt not found after disk initialization. Phase script may have failed silently."
    pause
    exit 1
}
Get-Content $StateFile | ForEach-Object {
    if ($_ -match '^(\w+)=(.+)$') {
        Set-Variable -Name $Matches[1] -Value $Matches[2]
    }
}

if (-not $OSDrive -or -not $EFIDrive) {
    Write-Error "OSDrive or EFIDrive not set after reading DeployState.txt. Cannot continue."
    pause
    exit 1
}

# Apply the OS image
Write-Host ""
Write-Host "========================================="
Write-Host "  Apply OS Image"
Write-Host "========================================="

$WIMPath = "${DeployDrive}:\OS\install.wim"
if (-not (Test-Path $WIMPath)) {
    Write-Error "OS image not found at $WIMPath"
    pause
    exit 1
}

Write-Host "  Applying image from $WIMPath..."
Write-Host "  Destination: $OSDrive"
Write-Host "  This will take several minutes."
Write-Host ""

# Reset ACLs on the WIM before applying.
# WIMs sourced from SCCM or network shares carry restrictive inherited ACLs
# that survive robocopy and block DISM (Error 5) even running as SYSTEM.
Write-Host "  Resetting WIM file permissions..."
icacls $WIMPath /reset /Q
icacls $WIMPath /grant "SYSTEM:(F)" /Q
Write-Host "  Permissions reset."
Write-Host ""

try {
    Expand-WindowsImage -ImagePath $WIMPath -Index 1 -ApplyPath "$OSDrive\" -ErrorAction Stop
}
catch {
    Write-Error "Image apply failed: $_"
    pause
    exit 1
}

Write-Host ""
Write-Host "  Image applied successfully."

# Write boot files to EFI partition
Write-Host "  Writing boot configuration to $EFIDrive..."
bcdboot "$OSDrive\Windows" /s $EFIDrive /f UEFI

if ($LASTEXITCODE -ne 0) {
    Write-Error "bcdboot failed with exit code $LASTEXITCODE"
    pause
    exit 1
}

Write-Host "  Boot configuration written."

# ============================================================================
# POST-APPLY (offline OS - C:\ is accessible, Windows is not yet running)
# ============================================================================
Invoke-Phase "Driver Injection"      "10-Invoke-DriverInjection.ps1"
Invoke-Phase "Hostname Unattend"     "20-Write-HostnameUnattend.ps1"
Invoke-Phase "First Logon Config"    "30-Configure-FirstLogon.ps1"
Invoke-Phase "Defer Updates"         "40-Defer-Updates.ps1"

# ============================================================================
# COMPLETE
# ============================================================================
Write-Host ""
Write-Host "========================================="
Write-Host "  Deployment Complete"
Write-Host "========================================="
Write-Host ""
Write-Host "  Computer : $ComputerName"
Write-Host "  Model    : $Manufacturer $ModelName"
Write-Host ""
Write-Host "  Remove the USB drive, then press any key to restart."
pause

Restart-Computer -Force
