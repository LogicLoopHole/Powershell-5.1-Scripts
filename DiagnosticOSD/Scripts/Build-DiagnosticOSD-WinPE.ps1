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
    Build-DiagnosticOSD-WinPE.ps1
    Combines all WinPE build + USB prep steps into one script.
    Run from an elevated PowerShell session.
    No Deployment Tools Environment console required.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# CONFIGURATION  -- edit these if your paths differ
# ----------------------------------------------------------
$BuildRoot   = "C:\DiagOSD-Build"
$WinPEDir    = "$BuildRoot\WinPE"
$MountDir    = "$WinPEDir\mount"
$StageDir    = "$BuildRoot\USB-Stage"
$DriversDir  = "$BuildRoot\ExtractedBootDrivers"

$USBWinPE   = "F"   # FAT32 partition drive letter (no colon)
$USBData    = "N"   # NTFS  partition drive letter (no colon)

$ADKRoot    = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
$CopypeCmd  = "$ADKRoot\Windows Preinstallation Environment\copype.cmd"
$OCPath     = "$ADKRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"

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

if (-not (Test-Path $ADKRoot))   { throw "ADK root not found at $ADKRoot. Install the Windows ADK." }
if (-not (Test-Path $CopypeCmd)) { throw "copype.cmd not found - WinPE add-on is not installed: $CopypeCmd" }
if (-not (Test-Path "$ADKRoot\Windows Preinstallation Environment\amd64")) {
    throw "amd64 WinPE architecture files not found. Re-run the WinPE add-on installer with amd64 selected."
}
if (-not (Test-Path $OCPath))    { throw "WinPE_OCs folder not found at $OCPath" }

Write-Host "ADK root       : $ADKRoot"
Write-Host "copype.cmd     : $CopypeCmd"
Write-Host "WinPE_OCs path : $OCPath"

# ----------------------------------------------------------
# CLEANUP
# ----------------------------------------------------------
Write-Host "`n=== Cleanup: stale mounts and prior WinPE folder ===" -ForegroundColor Cyan

$mountInfo = & dism.exe /Get-MountedImageInfo 2>&1
if ($mountInfo -match [regex]::Escape($MountDir)) {
    Write-Warning "Found a mounted image at $MountDir - discarding it now..."
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard
    & dism.exe /Cleanup-Wim
}

if (Test-Path $WinPEDir) {
    Write-Warning "$WinPEDir already exists - removing before copype..."
    Remove-Item $WinPEDir -Recurse -Force
}

# ----------------------------------------------------------
# Step 1.1 -- copype
# ----------------------------------------------------------
Write-Host "`n=== Step 1.1: copype amd64 -> $WinPEDir ===" -ForegroundColor Cyan

# copype.cmd needs env vars set by DandISetEnv.bat. Chain them in one cmd.exe
# session so copype inherits the correct environment.
$DandIEnv = "$ADKRoot\Deployment Tools\DandISetEnv.bat"

if (Test-Path $DandIEnv) {
    & cmd.exe /c "`"$DandIEnv`" && `"$CopypeCmd`" amd64 `"$WinPEDir`""
} else {
    Write-Warning "DandISetEnv.bat not found at $DandIEnv - calling copype directly (likely to fail)."
    & cmd.exe /c "`"$CopypeCmd`" amd64 `"$WinPEDir`""
}
if ($LASTEXITCODE -ne 0) { throw "copype failed." }

$BootWim = "$WinPEDir\media\sources\boot.wim"
if (-not (Test-Path $BootWim)) { throw "boot.wim not found after copype at $BootWim" }
Write-Host "boot.wim confirmed at $BootWim"

# ----------------------------------------------------------
# Step 1.2 -- Mount boot.wim
# ----------------------------------------------------------
Write-Host "`n=== Step 1.2: Mount boot.wim ===" -ForegroundColor Cyan
Invoke-Dism @("/Mount-Image", "/ImageFile:$BootWim", "/Index:1", "/MountDir:$MountDir")
Write-Host "Image mounted at $MountDir"

# ----------------------------------------------------------
# Step 1.3 -- Add optional components
# ----------------------------------------------------------
Write-Host "`n=== Step 1.3: Add optional components ===" -ForegroundColor Cyan

$Components = @(
    "WinPE-WMI",
    "WinPE-NetFX",
    "WinPE-Scripting",
    "WinPE-PowerShell",
    "WinPE-StorageWMI",
    "WinPE-DismCmdlets"
)

foreach ($Comp in $Components) {
    Write-Host "Adding $Comp..."
    Invoke-Dism @("/Add-Package", "/Image:$MountDir", "/PackagePath:$OCPath\$Comp.cab")
    Invoke-Dism @("/Add-Package", "/Image:$MountDir", "/PackagePath:$OCPath\en-us\${Comp}_en-us.cab")
}

$PkgList = & dism.exe /Get-Packages /Image:"$MountDir"
$InstalledCount = ($PkgList | Select-String "State : Installed").Count
Write-Host "Installed package count: $InstalledCount (expected 14)"
if ($InstalledCount -lt 14) {
    Write-Warning "Fewer packages than expected - review DISM output above."
}

# ----------------------------------------------------------
# Step 1.4 -- Add boot drivers
# ----------------------------------------------------------
Write-Host "`n=== Step 1.4: Add boot drivers ===" -ForegroundColor Cyan

$DriverFiles = Get-ChildItem $DriversDir -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue
if ((Test-Path $DriversDir) -and $DriverFiles) {
    Invoke-Dism @("/Add-Driver", "/Image:$MountDir", "/Driver:$DriversDir", "/Recurse")
    Write-Host "Boot drivers added."
} else {
    Write-Warning "No .inf files found in $DriversDir - skipping driver injection."
}

# ----------------------------------------------------------
# Step 1.5 -- Write Launch.ps1 into the mounted image
# ----------------------------------------------------------
Write-Host "`n=== Step 1.5: Write X:\Deploy\Launch.ps1 into mount ===" -ForegroundColor Cyan

$DeployDir = "$MountDir\Deploy"
New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null

$LauncherLines = @(
    "# X:\Deploy\Launch.ps1",
    '$Drive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq ''DeployData'' }).DriveLetter',
    "",
    'if (-not $Drive) {',
    '    Write-Error "DeployData volume not found. Verify USB is connected and NTFS partition is labeled DeployData."',
    '    pause',
    '    return',
    '}',
    "",
    '$MasterScript = "${Drive}:\Deploy\Start-Deployment.ps1"',
    "",
    'if (-not (Test-Path $MasterScript)) {',
    '    Write-Error "Start-Deployment.ps1 not found at $MasterScript"',
    '    pause',
    '    return',
    '}',
    "",
    '& $MasterScript'
)

[System.IO.File]::WriteAllLines(
    "$DeployDir\Launch.ps1",
    $LauncherLines,
    [System.Text.Encoding]::ASCII
)
Write-Host "Launch.ps1 written to $DeployDir\Launch.ps1"

# ----------------------------------------------------------
# Step 1.6 -- Write startnet.cmd
# ----------------------------------------------------------
Write-Host "`n=== Step 1.6: Write startnet.cmd ===" -ForegroundColor Cyan

$StartnetPath = "$MountDir\Windows\System32\startnet.cmd"

$StartnetLines = @(
    "@echo off",
    "wpeinit",
    "powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Launch.ps1"
)

[System.IO.File]::WriteAllLines(
    $StartnetPath,
    $StartnetLines,
    [System.Text.Encoding]::ASCII
)

Write-Host "startnet.cmd contents:"
Get-Content $StartnetPath | ForEach-Object { Write-Host "  $_" }

# ----------------------------------------------------------
# Step 1.7 -- Unmount and commit
# ----------------------------------------------------------
Write-Host "`n=== Step 1.7: Unmount and commit (do not interrupt) ===" -ForegroundColor Cyan

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
# Step 2.1 -- Identify USB
# ----------------------------------------------------------
Write-Host "`n=== Step 2.1: Identify USB disk ===" -ForegroundColor Cyan

$OSDriveLetter  = $env:SystemDrive -replace ':',''
$OSDiskNumber   = (Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } |
                   Select-Object -First 1).DiskNumber

Write-Host "Available disks (active OS disk excluded):"
if ($null -ne $OSDiskNumber) {
    Write-Warning "Active OS disk (Disk $OSDiskNumber) is excluded and will not be listed."
}

Get-Disk | Where-Object { $_.Number -ne $OSDiskNumber } | ForEach-Object {
    $SizeGB = [math]::Round($_.Size / 1GB, 1)
    Write-Host ("  Disk {0}  {1}  {2} GB  BusType={3}" -f $_.Number, $_.FriendlyName, $SizeGB, $_.BusType)
}

Write-Host ""
$DiskNum = Read-Host "Enter the USB disk NUMBER from the list above (WARNING: all data will be erased)"

if ([int]$DiskNum -eq $OSDiskNumber) { throw "Disk $DiskNum is the active OS disk and cannot be used." }

$SelectedDisk = Get-Disk -Number $DiskNum
if ($SelectedDisk.BusType -ne 'USB') {
    Write-Warning ("Disk {0} reports BusType={1}, not USB." -f $DiskNum, $SelectedDisk.BusType)
    $Confirm = Read-Host "Are you SURE this is the correct disk? Type YES to continue"
    if ($Confirm -ne 'YES') {
        Write-Warning "Aborted by operator."
        return
    }
}

# ----------------------------------------------------------
# Step 2.2 -- Partition the USB
# ----------------------------------------------------------
Write-Host "`n=== Step 2.2: Partition USB disk $DiskNum ===" -ForegroundColor Cyan

$DiskpartScript = @"
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

Invoke-Diskpart $DiskpartScript

Start-Sleep -Seconds 3

$Volumes = Get-Volume | Where-Object { $_.FileSystemLabel -in @('WinPE', 'DeployData') }
if ($Volumes.Count -ne 2) {
    throw ("Expected 2 volumes (WinPE + DeployData) but found {0}. Check diskpart output above." -f $Volumes.Count)
}
Write-Host ("WinPE (FAT32, {0}:) and DeployData (NTFS, {1}:) created." -f $USBWinPE, $USBData)

# ----------------------------------------------------------
# Step 2.3 -- Copy WinPE boot files to FAT32
# ----------------------------------------------------------
Write-Host "`n=== Step 2.3: Copy WinPE boot files to ${USBWinPE}:\ ===" -ForegroundColor Cyan

& cmd.exe /c "xcopy `"$WinPEDir\media\*`" `"${USBWinPE}:\`" /E /H /F"
if ($LASTEXITCODE -ne 0) { throw "xcopy of WinPE media failed." }

# ----------------------------------------------------------
# Step 2.4 -- Copy staging content to NTFS
# ----------------------------------------------------------
Write-Host "`n=== Step 2.4: Copy staging content to ${USBData}:\ ===" -ForegroundColor Cyan

if (-not (Test-Path $StageDir)) {
    Write-Warning "$StageDir not found - skipping. Add deploy scripts later and robocopy manually."
} else {
    & robocopy.exe "$StageDir" "${USBData}:\" /E /NP
    if ($LASTEXITCODE -gt 7) { throw "robocopy failed with exit code $LASTEXITCODE." }
}

# ----------------------------------------------------------
# Step 2.5 -- Verify
# ----------------------------------------------------------
Write-Host "`n=== Step 2.5: Verify USB contents ===" -ForegroundColor Cyan

$Checks = @(
    @{ Path = "${USBWinPE}:\sources\boot.wim";                                  Label = "WinPE boot image" },
    @{ Path = "${USBWinPE}:\EFI\Microsoft\Boot\BCD";                            Label = "EFI BCD boot config" },
    @{ Path = "${USBData}:\Deploy\Scripts\Env-Setup\20-Check-Manufacturer.ps1"; Label = "Deploy scripts staged" },
    @{ Path = "${USBData}:\OS\install.wim";                                    Label = "OS image (install.wim)" },
    @{ Path = "${USBData}:\PostOS\Scripts\Join-Domain.ps1";                   Label = "Join-Domain payload" }
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
Write-Host "`n=== Build complete ===" -ForegroundColor Cyan
Write-Host "Expected boot sequence on target:"
Write-Host "  1. UEFI selects FAT32 USB partition"
Write-Host "  2. WinPE loads and wpeinit runs"
Write-Host "  3. startnet.cmd calls X:\Deploy\Launch.ps1"
Write-Host "  4. Launcher finds DeployData volume"
Write-Host "  5. Start-Deployment.ps1 is called from N:\Deploy\"
