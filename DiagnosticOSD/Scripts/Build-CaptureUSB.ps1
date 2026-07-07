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

#Requires -RunAsAdministrator
<#
    Build-CaptureUSB.ps1
    Builds a minimal WinPE USB for capturing a reference machine image.
    This is a dev/build bench tool - not for field deployment.

    Usage:
        1. Run this script on the build machine to prepare the capture USB
        2. Boot the sysprepped reference VM from the USB
        3. WinPE loads and automatically captures the OS partition to the NTFS partition
        4. Copy the resulting install.wim to the deployment USB under OS\

    The capture USB has two partitions matching the deployment USB layout:
        FAT32 ~1GB  "WinPE"      - boot files only, never written to at runtime
        NTFS  rest  "DeployData" - WIM is written here at capture time (no 4GB limit)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------
$BuildRoot  = "C:\DiagOSD-Build"
$WinPEDir   = "$BuildRoot\CaptureWinPE"
$MountDir   = "$WinPEDir\mount"
$DriversDir = "$BuildRoot\ExtractedBootDrivers"

$USBWinPE  = "F"   # FAT32 partition drive letter (no colon)
$USBData   = "N"   # NTFS  partition drive letter (no colon)

$ADKRoot   = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
$CopypeCmd = "$ADKRoot\Windows Preinstallation Environment\copype.cmd"
$OCPath    = "$ADKRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"

# ----------------------------------------------------------
# HELPERS
# ----------------------------------------------------------
function Invoke-Dism([string[]]$DismArgs) {
    & dism.exe @DismArgs
    if ($LASTEXITCODE -ne 0) { throw "DISM failed (exit $LASTEXITCODE) with args: $($DismArgs -join ' ')" }
}

function Invoke-Diskpart([string]$Script) {
    $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
    [System.IO.File]::WriteAllText($tmp, $Script.Trim(), [System.Text.Encoding]::ASCII)
    & diskpart.exe /s $tmp
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed (exit $LASTEXITCODE)" }
}

# ----------------------------------------------------------
# PREFLIGHT
# ----------------------------------------------------------
Write-Host "`n=== Preflight: ADK and WinPE add-on ===" -ForegroundColor Cyan

if (-not (Test-Path $ADKRoot)) {
    $Candidates = @(
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit",
        "C:\Program Files\Windows Kits\10\Assessment and Deployment Kit"
    )
    foreach ($C in $Candidates) {
        if (Test-Path $C) {
            $ADKRoot   = $C
            $CopypeCmd = "$ADKRoot\Windows Preinstallation Environment\copype.cmd"
            $OCPath    = "$ADKRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"
            Write-Warning "ADKRoot not at configured path - using auto-detected: $ADKRoot"
            break
        }
    }
}

if (-not (Test-Path $ADKRoot))   { throw "ADK root not found at $ADKRoot" }
if (-not (Test-Path $CopypeCmd)) { throw "copype.cmd not found - WinPE add-on is not installed: $CopypeCmd" }
if (-not (Test-Path $OCPath))    { throw "WinPE_OCs not found at $OCPath" }

Write-Host "ADK and WinPE add-on confirmed."

# ----------------------------------------------------------
# CLEANUP
# ----------------------------------------------------------
Write-Host "`n=== Cleanup: stale mounts and prior WinPE folder ===" -ForegroundColor Cyan

$mountInfo = & dism.exe /Get-MountedImageInfo 2>&1
if ($mountInfo -match [regex]::Escape($MountDir)) {
    Write-Warning "Stale mount found at $MountDir - discarding..."
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard
    & dism.exe /Cleanup-Wim
}

if (Test-Path $WinPEDir) {
    Write-Warning "$WinPEDir already exists - removing..."
    Remove-Item $WinPEDir -Recurse -Force
}

# ----------------------------------------------------------
# Step 1 -- copype
# ----------------------------------------------------------
Write-Host "`n=== Step 1: copype amd64 -> $WinPEDir ===" -ForegroundColor Cyan

$DandIEnv = "$ADKRoot\Deployment Tools\DandISetEnv.bat"
if (Test-Path $DandIEnv) {
    & cmd.exe /c "`"$DandIEnv`" && `"$CopypeCmd`" amd64 `"$WinPEDir`""
} else {
    Write-Warning "DandISetEnv.bat not found - calling copype directly (likely to fail)."
    & cmd.exe /c "`"$CopypeCmd`" amd64 `"$WinPEDir`""
}
if ($LASTEXITCODE -ne 0) { throw "copype failed." }

$BootWim = "$WinPEDir\media\sources\boot.wim"
if (-not (Test-Path $BootWim)) { throw "boot.wim not found after copype at $BootWim" }
Write-Host "boot.wim confirmed at $BootWim"

# ----------------------------------------------------------
# Step 2 -- Mount boot.wim
# ----------------------------------------------------------
Write-Host "`n=== Step 2: Mount boot.wim ===" -ForegroundColor Cyan
Invoke-Dism @("/Mount-Image", "/ImageFile:$BootWim", "/Index:1", "/MountDir:$MountDir")
Write-Host "Image mounted at $MountDir"

# ----------------------------------------------------------
# Step 3 -- Add optional components
# ----------------------------------------------------------
# WinPE-NetFX is a required dependency of WinPE-PowerShell and must precede it.
# WinPE-Scripting is not needed - no WSH usage in capture logic.
Write-Host "`n=== Step 3: Add optional components ===" -ForegroundColor Cyan

$Components = @(
    "WinPE-WMI",
    "WinPE-NetFX",
    "WinPE-PowerShell",
    "WinPE-StorageWMI",
    "WinPE-DismCmdlets"
)

foreach ($Comp in $Components) {
    Write-Host "Adding $Comp..."
    Invoke-Dism @("/Add-Package", "/Image:$MountDir", "/PackagePath:$OCPath\$Comp.cab")
    Invoke-Dism @("/Add-Package", "/Image:$MountDir", "/PackagePath:$OCPath\en-us\${Comp}_en-us.cab")
}

# ----------------------------------------------------------
# Step 4 -- Add boot drivers
# ----------------------------------------------------------
Write-Host "`n=== Step 4: Add boot drivers ===" -ForegroundColor Cyan

$DriverFiles = Get-ChildItem $DriversDir -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue
if ((Test-Path $DriversDir) -and $DriverFiles) {
    Invoke-Dism @("/Add-Driver", "/Image:$MountDir", "/Driver:$DriversDir", "/Recurse")
    Write-Host "Boot drivers added."
} else {
    Write-Warning "No .inf files found in $DriversDir - skipping driver injection."
}

# ----------------------------------------------------------
# Step 5 -- Bake capture script into WinPE
# ----------------------------------------------------------
Write-Host "`n=== Step 5: Write capture logic into WinPE ===" -ForegroundColor Cyan

# The capture script runs inline via startnet.cmd - no operator input required after boot.
# Logic: find the DeployData volume, find the Windows partition on the internal disk, capture it.
# IMPORTANT: $ErrorActionPreference = 'Stop' is set inside the embedded script so
# New-WindowsImage failures halt visibly instead of continuing past errors.

$StartnetPath = "$MountDir\Windows\System32\startnet.cmd"

$CaptureScript = @'
$ErrorActionPreference = 'Stop'

wpeinit

$OutputLabel = 'DeployData'
$WIMName     = 'DiagnosticOSD'
$WIMDesc     = 'DiagnosticOSD Reference Image'
$OutputFile  = 'install.wim'

Write-Host "`n=== DiagnosticOSD - Reference Image Capture ===" -ForegroundColor Cyan

# Locate DeployData NTFS volume
$DataVol = Get-Volume | Where-Object { $_.FileSystemLabel -eq $OutputLabel }
if (-not $DataVol) {
    Write-Error "DeployData volume not found. Verify USB is connected."
    pause
    return
}
$DataDrive  = "$($DataVol.DriveLetter):"
$OutputPath = "$DataDrive\$OutputFile"
Write-Host "Output : $OutputPath"

# Identify USB disk to exclude it from capture candidates
$USBDiskNum = (Get-Partition | Where-Object { $_.DriveLetter -eq $DataVol.DriveLetter } |
    Select-Object -First 1).DiskNumber

# Find the Windows partition on any non-USB disk (matching by ntoskrnl.exe is more
# reliable than volume label, which may be generic on a sysprepped image)
$WindowsVol = Get-Disk |
    Where-Object { $_.Number -ne $USBDiskNum } |
    ForEach-Object { Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue } |
    ForEach-Object { Get-Volume -Partition $_ -ErrorAction SilentlyContinue } |
    Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\ntoskrnl.exe") } |
    Select-Object -First 1

if (-not $WindowsVol) {
    Write-Error "No Windows installation found on internal disk."
    pause
    return
}
$SourceDrive = "$($WindowsVol.DriveLetter):"
Write-Host "Source : $SourceDrive"

if (Test-Path $OutputPath) {
    Write-Warning "Existing WIM found at $OutputPath - it will be overwritten."
    $Confirm = Read-Host "Type YES to overwrite, anything else to abort"
    if ($Confirm -ne 'YES') {
        Write-Warning "Capture aborted by operator."
        pause
        return
    }
    Remove-Item $OutputPath -Force
}

Write-Host "`nCapturing $SourceDrive to $OutputPath"
Write-Warning "This will take several minutes - do not remove USB or power off."

New-WindowsImage `
    -ImagePath   $OutputPath `
    -CapturePath "$SourceDrive\" `
    -Name        $WIMName `
    -Description $WIMDesc

Write-Host "`nCapture complete: $OutputPath"
Write-Host "Copy $OutputFile to the deployment USB under OS\ before deploying."
Write-Host "`nShutting down in 10 seconds (Ctrl+C to cancel)..."
Start-Sleep -Seconds 10
wpeutil shutdown
'@

# Write capture logic to a ps1 inside the WinPE image, call it from startnet.cmd
$CaptureScriptDir  = "$MountDir\Deploy"
$CaptureScriptPath = "$CaptureScriptDir\Capture.ps1"
New-Item -ItemType Directory -Path $CaptureScriptDir -Force | Out-Null
[System.IO.File]::WriteAllText($CaptureScriptPath, $CaptureScript, [System.Text.Encoding]::ASCII)

$StartnetLines = @(
    "@echo off",
    "powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Capture.ps1"
)
[System.IO.File]::WriteAllLines($StartnetPath, $StartnetLines, [System.Text.Encoding]::ASCII)

Write-Host "startnet.cmd:"
Get-Content $StartnetPath | ForEach-Object { Write-Host "  $_" }

# ----------------------------------------------------------
# Step 6 -- Unmount and commit
# ----------------------------------------------------------
Write-Host "`n=== Step 6: Unmount and commit (do not interrupt) ===" -ForegroundColor Cyan

try {
    Invoke-Dism @("/Unmount-Image", "/MountDir:$MountDir", "/Commit")
    Write-Host "Image committed and unmounted."
} catch {
    Write-Warning "Commit failed - discarding and cleaning up."
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard
    & dism.exe /Cleanup-Wim
    throw
}

# ----------------------------------------------------------
# Prepare USB
# ----------------------------------------------------------
Write-Host "`n=== Prepare USB ===" -ForegroundColor Cyan

$OSDriveLetter = $env:SystemDrive -replace ':',''
$OSDiskNumber  = (Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } |
                  Select-Object -First 1).DiskNumber

Write-Host "Available disks (active OS disk excluded):"
if ($null -ne $OSDiskNumber) {
    Write-Warning "Active OS disk (Disk $OSDiskNumber) is excluded."
}

Get-Disk | Where-Object { $_.Number -ne $OSDiskNumber } | ForEach-Object {
    $SizeGB = [math]::Round($_.Size / 1GB, 1)
    Write-Host ("  Disk {0}  {1}  {2} GB  BusType={3}" -f $_.Number, $_.FriendlyName, $SizeGB, $_.BusType)
}

Write-Host ""
$DiskNum = Read-Host "Enter the USB disk NUMBER (WARNING: all data will be erased)"

if ([int]$DiskNum -eq $OSDiskNumber) { throw "Disk $DiskNum is the active OS disk." }

$SelectedDisk = Get-Disk -Number $DiskNum
if ($SelectedDisk.BusType -ne 'USB') {
    Write-Warning ("Disk {0} reports BusType={1}, not USB" -f $DiskNum, $SelectedDisk.BusType)
    $Confirm = Read-Host "Are you SURE this is the correct disk? Type YES to continue"
    if ($Confirm -ne 'YES') {
        Write-Warning "Aborted by operator."
        return
    }
}

Write-Host "`n=== Partitioning USB disk $DiskNum (FAT32 boot + NTFS capture) ===" -ForegroundColor Cyan

Invoke-Diskpart @"
list disk
select disk $DiskNum
clean
convert gpt
create partition primary size=1024
format fs=fat32 quick label=WinPE
assign letter=$USBWinPE
create partition primary
format fs=ntfs quick label=DeployData
assign letter=$USBData
exit
"@

Start-Sleep -Seconds 3

$Volumes = Get-Volume | Where-Object { $_.FileSystemLabel -in @('WinPE','DeployData') }
if ($Volumes.Count -ne 2) {
    throw ("Expected 2 volumes but found {0}. Check diskpart output above." -f $Volumes.Count)
}
Write-Host ("WinPE (FAT32, {0}:) and DeployData (NTFS, {1}:) created." -f $USBWinPE, $USBData)

Write-Host "`n=== Copying WinPE boot files to ${USBWinPE}:\ ===" -ForegroundColor Cyan
& cmd.exe /c "xcopy `"$WinPEDir\media\*`" `"${USBWinPE}:\`" /E /H /F"
if ($LASTEXITCODE -ne 0) { throw "xcopy of WinPE media failed." }

# ----------------------------------------------------------
# Verify
# ----------------------------------------------------------
Write-Host "`n=== Verify ===" -ForegroundColor Cyan

$Checks = @(
    @{ Path = "${USBWinPE}:\sources\boot.wim";       Label = "WinPE boot image" },
    @{ Path = "${USBWinPE}:\EFI\Microsoft\Boot\BCD"; Label = "EFI BCD boot config" }
)
foreach ($Check in $Checks) {
    if (Test-Path $Check.Path) {
        Write-Host ("  [found]    {0}" -f $Check.Label)
    } else {
        Write-Warning ("{0} not found at {1}" -f $Check.Label, $Check.Path)
    }
}

# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------
Write-Host "`n=== Capture USB ready ===" -ForegroundColor Cyan
Write-Host "To capture a reference image:"
Write-Host "  1. Prep and sysprep the reference VM per CAPTURE-GUIDE.md"
Write-Host "  2. Boot the reference VM from this USB"
Write-Host "  3. WinPE will capture automatically to DeployData (${USBData}:)"
Write-Host "  4. Copy install.wim from ${USBData}:\ to the deployment USB under OS\"
