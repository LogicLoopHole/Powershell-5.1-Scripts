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
# Writes $OSDrive, $EFIDrive and recovery partition details to X:\Deploy\DeployState.txt.
#
# Layout produced (Microsoft UEFI/GPT reference layout):
#   1  EFI System        FAT32
#   2  MSR               16 MB, no filesystem
#   3  Windows (C:)      NTFS, remainder of disk less the recovery partition
#   4  Recovery (R:)     NTFS, typed de94bba4-..., hidden, immediately after Windows
#
# The recovery partition is placed LAST so Windows can shrink C: and grow it when a
# future WinRE servicing update needs more room. It is created here but left empty -
# 25-Configure-WinRE.ps1 stages Winre.wim into it after the image is applied.

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

# Microsoft's documented minimum for a custom diskpart layout is 990 MB with 250 MB
# left free. Winre.wim alone is 500-700 MB before drivers and languages are added,
# and WinRE servicing updates (see KB5034441) need headroom on top of that. Do not
# set this below 1024.
$RecoverySizeMB = 2048

# 260 MB is the Microsoft minimum that also works on 4Kn drives. Some OEM firmware
# update utilities want more room on the ESP - raise this if you hit that.
$EFISizeMB = 260

$OSLetter       = 'C'
$EFILetter      = 'S'
$RecoveryLetter = 'R'

# GPT type GUIDs, used for verification. Checking structure by type GUID is reliable;
# checking it by drive letter is not (see the verification section).
$GuidEFI      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$GuidMSR      = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$GuidRecovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

# Attribute mask marking the recovery partition required + suppressing automatic
# drive letter assignment on the deployed OS.
$RecoveryGptAttr = '0x8000000000000001'

Write-Host "`n=== Initialize Disk ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-Diskpart {
    param(
        [string]$Script,
        [string]$FileName,
        [switch]$Quiet
    )

    $Path = "X:\Deploy\$FileName"
    $Script | Out-File -FilePath $Path -Encoding ascii -Force

    $Output = diskpart /s $Path 2>&1
    if (-not $Quiet) { $Output | Write-Host }

    return $Output
}

function Test-DriveLetterInUse {
    param([string]$Letter)

    # Test both ways. Get-Volume misses some partition types, Test-Path misses
    # letters that are registered but not currently mountable.
    if (Test-Path "${Letter}:\") { return $true }
    if ($null -ne (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Clear-DriveLetter {
    param(
        [string]$Letter,
        [string]$ProtectedLetter
    )

    if (-not (Test-DriveLetterInUse -Letter $Letter)) { return }

    if ($Letter -eq $ProtectedLetter) {
        throw ("Drive letter ${Letter}: is held by the DeployData volume. " +
               "This deployment cannot proceed - the running scripts and the open transcript live there. " +
               "Reassign DeployData to another letter or rebuild the USB, then retry.")
    }

    $Vol = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
    $Desc = if ($Vol) { "'$($Vol.FileSystemLabel)' ($($Vol.FileSystem))" } else { "an unidentified volume" }
    Write-Host "  ${Letter}: is in use by $Desc - releasing it."

    Invoke-Diskpart -FileName "diskpart-free-$Letter.txt" -Quiet -Script @"
select volume $Letter
remove letter=$Letter noerr
exit
"@ | Out-Null

    Start-Sleep -Seconds 2

    if (Test-DriveLetterInUse -Letter $Letter) {
        throw "Could not release drive letter ${Letter}: - it is still in use. See the volume map above."
    }
}

function Get-DiskStateDescription {
    param($Disk)

    $States = @()
    if ($Disk.PartitionStyle -eq 'RAW') { $States += 'UNINITIALIZED' }
    if ($Disk.IsOffline)                { $States += 'OFFLINE' }
    if ($Disk.IsReadOnly)               { $States += 'READ-ONLY' }

    $PartCount = (Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($PartCount -gt 0) { $States += "$PartCount EXISTING PARTITION(S)" }

    if ($States.Count -eq 0) { return 'clean' }
    return ($States -join ', ')
}

# ---------------------------------------------------------------------------
# Firmware
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Volume map
#
# Printed before anything is touched. WinPE letters this machine's volumes in
# discovery order, and the deployment USB presents TWO of them (FAT32 "WinPE" plus
# NTFS "DeployData"), so C: is frequently already taken before this script starts.
# When a run fails on a drive letter, this map is what explains it in the transcript.
# ---------------------------------------------------------------------------

Write-Host "`nCurrent volume map:"
Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
    Write-Host ("  {0}:  {1,-14} {2,-6} {3,8} GB" -f `
        $_.DriveLetter, $_.FileSystemLabel, $_.FileSystem, [math]::Round($_.Size / 1GB, 1))
}

# ---------------------------------------------------------------------------
# Disk identification
# ---------------------------------------------------------------------------

Write-Host "`nIdentifying disks..."

$DeployVolume = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' } | Select-Object -First 1
if (-not $DeployVolume) { throw "DeployData volume not found." }
$DeployDrive = [string]$DeployVolume.DriveLetter

# Query by drive letter rather than piping an unfiltered Get-Partition.
#
# An unfiltered Get-Partition walks every disk in the machine. A RAW (uninitialized)
# or offline disk has no partition table, so the provider raises a non-terminating
# error - and because Start-Deployment.ps1 sets $ErrorActionPreference = "Stop",
# that error becomes fatal and the script dies before it ever reaches the operator
# prompt. This is the failure seen on brand-new SSDs and freshly created VM disks.
$SourceDiskNumber = (Get-Partition -DriveLetter $DeployDrive -ErrorAction SilentlyContinue |
    Select-Object -First 1).DiskNumber

# Exclude active OS disk - hard protection against wiping the machine running this script
$OSDriveLetter = $env:SystemDrive -replace ':',''
$OSDiskNumber  = (Get-Partition -DriveLetter $OSDriveLetter -ErrorAction SilentlyContinue |
    Select-Object -First 1).DiskNumber

if ($null -ne $OSDiskNumber) {
    Write-Warning "Active OS disk detected (Disk $OSDiskNumber) - this disk will not be presented as a target."
}

# Build target disk list. RAW and offline disks are deliberately left IN the list -
# they are valid targets, they just need preparing first.
$TargetDisks = Get-Disk | Where-Object {
    $_.Number -ne $SourceDiskNumber -and
    $_.Number -ne $OSDiskNumber
}

if (-not $TargetDisks) { throw "No target disks available after excluding source and active OS disk." }

# ---------------------------------------------------------------------------
# Disk selection
# ---------------------------------------------------------------------------

$TargetDiskCount = ($TargetDisks | Measure-Object).Count

if ($TargetDiskCount -gt 1) {
    Write-Warning "Multiple target disks detected - operator must choose:"
    Write-Host ""
    $TargetDisks | ForEach-Object {
        $Labels = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                   ForEach-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel } |
                   Where-Object { $_ }) -join ', '
        Write-Host ("  Disk {0}  {1}  {2} GB  BusType={3}  [{4}]" -f `
            $_.Number, $_.FriendlyName, [math]::Round($_.Size / 1GB, 0), $_.BusType,
            (Get-DiskStateDescription -Disk $_))
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
    $SelectedDisk = $TargetDisks | Select-Object -First 1
}

$TargetNum = [int]$SelectedDisk.Number

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

$Labels = (Get-Partition -DiskNumber $TargetNum -ErrorAction SilentlyContinue |
           ForEach-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel } |
           Where-Object { $_ }) -join ', '

Write-Host ""
Write-Host "Target disk : $TargetNum - $($SelectedDisk.FriendlyName)"
Write-Host "Size        : $([math]::Round($SelectedDisk.Size / 1GB, 0)) GB"
Write-Host "State       : $(Get-DiskStateDescription -Disk $SelectedDisk)"

if ($Labels) { Write-Warning "Existing labels: $Labels" }

Write-Warning "ALL DATA ON THIS DISK WILL BE ERASED."
$Confirm = Read-Host "Type YES to confirm and continue"

if ($Confirm -ne "YES") {
    Write-Warning "Disk operation cancelled by operator."
    pause
    return
}

# ---------------------------------------------------------------------------
# Prepare the disk
#
# A brand-new SSD or a freshly created VM disk arrives RAW, and depending on the
# hypervisor and the WinPE SAN policy it may also be offline and/or read-only.
# Diskpart's 'clean' cannot touch an offline or read-only disk, so this has to be
# cleared first. Every step is conditional - a disk that is already online and
# partitioned takes exactly the same path it always did.
# ---------------------------------------------------------------------------

Write-Host "`nPreparing disk $TargetNum..."

$Disk = Get-Disk -Number $TargetNum

if ($Disk.IsOffline) {
    Write-Host "  Disk is offline - bringing online."
    Set-Disk -Number $TargetNum -IsOffline $false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $Disk = Get-Disk -Number $TargetNum
}

if ($Disk.IsReadOnly) {
    Write-Host "  Disk is read-only - clearing read-only attribute."
    Set-Disk -Number $TargetNum -IsReadOnly $false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $Disk = Get-Disk -Number $TargetNum
}

if ($Disk.PartitionStyle -eq 'RAW') {
    Write-Host "  Disk is uninitialized (RAW) - initializing as GPT."
    Initialize-Disk -Number $TargetNum -PartitionStyle GPT -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------------------
# Reclaim the drive letters this layout needs
#
# WinPE hands out letters in volume discovery order. The deployment USB contributes
# two lettered volumes of its own - the FAT32 "WinPE" boot partition and the NTFS
# "DeployData" partition - so on many machines C: is already spoken for by the time
# this script runs, and 'assign letter=C' fails with
#     "The specified drive letter is not free to be assigned."
# taking the whole diskpart script down with it. Which volume gets C: depends purely
# on enumeration order, which is why the same USB works on one machine and not the next.
#
# Releasing the letter is safe: WinPE runs from the X: ramdisk and the FAT32 boot
# partition is not read at runtime. DeployData is protected because the running
# scripts and the open transcript live on it.
# ---------------------------------------------------------------------------

Write-Host "`nReclaiming drive letters..."
foreach ($Letter in @($OSLetter, $EFILetter, $RecoveryLetter)) {
    Clear-DriveLetter -Letter $Letter -ProtectedLetter $DeployDrive
}

# ---------------------------------------------------------------------------
# Partition
# ---------------------------------------------------------------------------

Write-Host "`nPartitioning disk $TargetNum..."

# 'online disk' and 'attributes disk clear readonly' are repeated here with noerr as
# a backstop - they no-op harmlessly if the Set-Disk calls above already handled it,
# and they cover WinPE builds where the Storage cmdlets are only partially present.
#
# 'shrink' takes both desired and minimum. With desired alone diskpart will happily
# shrink by less than asked; with minimum set it fails loudly instead. The recovery
# partition is then created with no size so it consumes exactly the freed space and
# leaves no trailing gap.
$DiskpartOutput = Invoke-Diskpart -FileName "diskpart-init.txt" -Script @"
select disk $TargetNum
online disk noerr
attributes disk clear readonly noerr
clean
convert gpt
create partition efi size=$EFISizeMB
format fs=fat32 quick label="System"
assign letter=$EFILetter
create partition msr size=16
create partition primary
format fs=ntfs quick label="Windows"
assign letter=$OSLetter
shrink desired=$RecoverySizeMB minimum=$RecoverySizeMB
create partition primary
format fs=ntfs quick label="Windows RE tools"
assign letter=$RecoveryLetter
set id="$($GuidRecovery.Trim('{','}'))"
gpt attributes=$RecoveryGptAttr
exit
"@

if ($LASTEXITCODE -ne 0) {
    if ($DiskpartOutput -match 'not free to be assigned') {
        throw ("diskpart could not assign a required drive letter. Something claimed " +
               "${OSLetter}:, ${EFILetter}: or ${RecoveryLetter}: after they were released - " +
               "compare the volume map above against the diskpart output.")
    }
    throw "diskpart failed with exit code $LASTEXITCODE"
}

Start-Sleep -Seconds 3

# ---------------------------------------------------------------------------
# Verify
#
# Diskpart routinely exits 0 even when individual commands inside the script failed,
# so the exit code above is necessary but not sufficient.
#
# Structure is verified by GPT type GUID, never by drive letter. An EFI System
# Partition does not report a drive letter through the storage provider even after
# diskpart successfully assigns one - Windows hides the ESP by design - so
# 'Get-Partition -DriveLetter S' returns nothing on a perfectly good layout. The
# same is true of the recovery partition once its no-drive-letter attribute is set.
# Usability is verified separately with Test-Path, which is what actually matters
# for bcdboot and for staging WinRE.
# ---------------------------------------------------------------------------

Write-Host "`nVerifying partition layout..."

$Parts = @(Get-Partition -DiskNumber $TargetNum -ErrorAction SilentlyContinue)
if ($Parts.Count -lt 4) {
    throw "Expected 4 partitions on disk $TargetNum, found $($Parts.Count). Check the diskpart output above."
}

$EfiPart = $Parts | Where-Object { $_.GptType -eq $GuidEFI } | Select-Object -First 1
if (-not $EfiPart) { throw "No EFI system partition on disk $TargetNum." }
if (-not (Test-Path "${EFILetter}:\")) {
    throw "EFI partition exists but is not reachable at ${EFILetter}: - bcdboot will fail in 20-Apply-Image.ps1."
}

$MsrPart = $Parts | Where-Object { $_.GptType -eq $GuidMSR } | Select-Object -First 1
if (-not $MsrPart) { Write-Warning "No MSR partition found on disk $TargetNum." }

$OSPart = $Parts | Where-Object { $_.DriveLetter -eq $OSLetter } | Select-Object -First 1
if (-not $OSPart) {
    if (Test-Path "${OSLetter}:\") {
        throw "${OSLetter}: exists but is not on target disk $TargetNum. Aborting before an image is written to the wrong device."
    }
    throw "No ${OSLetter}: volume on disk $TargetNum after partitioning."
}

$RecPart = $Parts | Where-Object { $_.GptType -eq $GuidRecovery } | Select-Object -First 1
if (-not $RecPart) {
    throw "Recovery partition was not created with type $GuidRecovery. Check the diskpart output above."
}
if ($RecPart.Size -lt 1GB) {
    Write-Warning ("Recovery partition is only {0} MB - WinRE servicing updates may fail. Raise `$RecoverySizeMB." -f [math]::Round($RecPart.Size / 1MB, 0))
}

$RecoveryDrive = "${RecoveryLetter}:"
if (-not (Test-Path "$RecoveryDrive\")) {
    Write-Warning "Recovery partition not reachable at $RecoveryDrive - 25-Configure-WinRE.ps1 will re-assign it."
}

# ---------------------------------------------------------------------------
# Write state
# ---------------------------------------------------------------------------

$OSDrive  = "${OSLetter}:"
$EFIDrive = "${EFILetter}:"

$StateFile = "X:\Deploy\DeployState.txt"
@"
OSDrive=$OSDrive
EFIDrive=$EFIDrive
RecoveryDrive=$RecoveryDrive
RecoveryDisk=$TargetNum
RecoveryPartition=$($RecPart.PartitionNumber)
"@ | Out-File -FilePath $StateFile -Encoding ascii -Force

Write-Host ""
Write-Host "EFI partition      : $EFIDrive  (partition $($EfiPart.PartitionNumber))"
Write-Host "OS partition       : $OSDrive  (partition $($OSPart.PartitionNumber))"
Write-Host "Recovery partition : $RecoveryDrive  ($([math]::Round($RecPart.Size / 1MB, 0)) MB, disk $TargetNum partition $($RecPart.PartitionNumber))"
Write-Host "Disk preparation complete."

pause
