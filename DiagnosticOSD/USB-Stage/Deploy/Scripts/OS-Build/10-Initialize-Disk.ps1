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

# 10-Initialize-Disk.ps1
# OS-Build - Detects firmware type, identifies target disk, partitions and formats.
# Writes $OSDrive and $EFIDrive to X:\Deploy\DeployState.txt on success.

Write-Host "`n=== Initialize Disk ===" -ForegroundColor Cyan

Write-Host "Detecting firmware type..."
$FirmwareType = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -ErrorAction SilentlyContinue).PEFirmwareType
$IsUEFI = ($FirmwareType -eq 2)

if (-not $IsUEFI) {
    Write-Warning "Legacy BIOS detected. This tool requires UEFI firmware."
    Write-Warning "If this machine supports UEFI, verify it is enabled in firmware settings."
    pause
    return
}
Write-Host "Firmware: UEFI"

# Identify disks to exclude
Write-Host "Identifying disks..."

$DeployDrive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $DeployDrive) { throw "DeployData volume not found." }

$SourceDiskNumber = (Get-Partition | Where-Object { $_.DriveLetter -eq $DeployDrive } |
    Select-Object -First 1).DiskNumber

# Exclude active OS disk - hard protection against wiping the machine running this script
$OSDriveLetter = $env:SystemDrive -replace ':',''
$OSDiskNumber  = (Get-Partition | Where-Object { $_.DriveLetter -eq $OSDriveLetter } |
    Select-Object -First 1).DiskNumber

if ($null -ne $OSDiskNumber) {
    Write-Warning "Active OS disk detected (Disk $OSDiskNumber) - this disk will not be presented as a target."
}

# Build target disk list
$TargetDisks = Get-Disk | Where-Object {
    $_.Number -ne $SourceDiskNumber -and
    $_.Number -ne $OSDiskNumber
}

if (-not $TargetDisks) { throw "No target disks available after excluding source and active OS disk." }

# Disk selection
$TargetDiskCount = ($TargetDisks | Measure-Object).Count

if ($TargetDiskCount -gt 1) {
    Write-Warning "Multiple target disks detected - operator must choose:"
    Write-Host ""
    $TargetDisks | ForEach-Object {
        $PartCount = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Measure-Object).Count
        $Labels    = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                      ForEach-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel } |
                      Where-Object { $_ }) -join ', '
        $DirtyFlag = if ($PartCount -gt 0) { " [HAS EXISTING PARTITIONS]" } else { "" }
        Write-Host ("  Disk {0}  {1}  {2} GB  BusType={3}{4}" -f `
            $_.Number, $_.FriendlyName, [math]::Round($_.Size / 1GB, 0), $_.BusType, $DirtyFlag)
        if ($Labels) { Write-Host "           Existing labels: $Labels" }
    }
    Write-Host ""
    $DiskNum = Read-Host "Enter disk number to use as target (ALL DATA WILL BE ERASED)"

    $SelectedDisk = $TargetDisks | Where-Object { $_.Number -eq [int]$DiskNum }
    if (-not $SelectedDisk) {
        Write-Warning "Invalid disk number entered."
        pause
        return
    }
} else {
    $SelectedDisk = $TargetDisks
}

# Confirmation
$PartCount  = (Get-Partition -DiskNumber $SelectedDisk.Number -ErrorAction SilentlyContinue | Measure-Object).Count
$Labels     = (Get-Partition -DiskNumber $SelectedDisk.Number -ErrorAction SilentlyContinue |
               ForEach-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel } |
               Where-Object { $_ }) -join ', '

Write-Host ""
Write-Host "Target disk : $($SelectedDisk.Number) - $($SelectedDisk.FriendlyName)"
Write-Host "Size        : $([math]::Round($SelectedDisk.Size / 1GB, 0)) GB"

if ($PartCount -gt 0) {
    Write-Warning "This disk is not clean - it has $PartCount existing partition(s)."
    if ($Labels) { Write-Warning "Existing labels: $Labels" }
    Write-Warning "All data will be lost."
}

Write-Warning "ALL DATA ON THIS DISK WILL BE ERASED."
$Confirm = Read-Host "Type YES to confirm and continue"

if ($Confirm -ne "YES") {
    Write-Warning "Disk operation cancelled by operator."
    pause
    return
}

# Partition
Write-Host "`nPartitioning disk $($SelectedDisk.Number)..."

$DiskpartFile = "X:\Deploy\diskpart-init.txt"

$DiskpartScript = @"
select disk $($SelectedDisk.Number)
clean
convert gpt
create partition efi size=260
format fs=fat32 quick
assign letter=S
create partition msr size=16
create partition primary
format fs=ntfs quick label=Windows
assign letter=C
shrink desired=990
create partition primary size=990
format fs=ntfs quick label=Recovery
exit
"@

$DiskpartScript | Out-File -FilePath $DiskpartFile -Encoding ascii -Force
diskpart /s $DiskpartFile

if ($LASTEXITCODE -ne 0) { throw "diskpart failed with exit code $LASTEXITCODE" }

Start-Sleep -Seconds 3

# Write state
$OSDrive  = "C:"
$EFIDrive = "S:"

if (-not (Test-Path "$OSDrive\")) {
    throw "OS partition ($OSDrive) not accessible after partitioning."
}

$StateFile = "X:\Deploy\DeployState.txt"
@"
OSDrive=$OSDrive
EFIDrive=$EFIDrive
"@ | Out-File -FilePath $StateFile -Encoding ascii -Force

Write-Host "EFI partition : $EFIDrive"
Write-Host "OS partition  : $OSDrive"
Write-Host "Disk preparation complete."

pause
