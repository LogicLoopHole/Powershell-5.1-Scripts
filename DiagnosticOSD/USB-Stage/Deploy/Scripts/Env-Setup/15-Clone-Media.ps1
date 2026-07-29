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

# 15-Clone-Media.ps1
# Env-Setup - Optional. Clones this booted tool onto another disk, producing bootable
# media identical to the source. Lets the field build spare sticks without going back
# to the build workstation.
#
# Runs after 10-Sync-Content.ps1 so the clone carries share-current content.
#
# DISABLED BY DEFAULT. $CloneEnabled below is reverted by the sync on every boot, which
# makes it a share-side setting rather than a per-stick one - flip it on the share
# before heading out. That is deliberate: cloning stays centrally controlled.
#
# CLONE OR DEPLOY, NEVER BOTH. On success this shuts the machine down so the operator
# cannot walk from here into 10-Initialize-Disk.ps1 and wipe what was just written.
# On failure it throws for the same reason.
#
# WHY A FILE COPY IS ENOUGH:
#   UEFI boots removable media by looking for \EFI\BOOT\BOOTX64.EFI on the FAT32
#   partition, and WinPE's BCD locates boot.wim through a relative boot device element
#   rather than a hardcoded disk signature. Nothing in that tree knows which disk it is
#   sitting on, so no bootsect and no bcdboot are required. This holds because the fleet
#   is UEFI-only; a Legacy BIOS target would need bootsect /nt60 and a copy would not be
#   enough. Build-CaptureUSB.ps1 relies on the same property.
#
# WHY DISK NUMBERS, NOT LABELS:
#   The clone ends up carrying the same WinPE and DeployData labels as the source - it
#   has to, or it is not a clone. Every other script in this suite resolves the USB by
#   label, so while both disks are attached that lookup is ambiguous. Source and target
#   are pinned to disk numbers captured before anything is written, and the shutdown at
#   the end guarantees the operator separates them before any label lookup runs again.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$CloneEnabled = $false   # share-side switch - see header

$TargetBootLetter = 'T'
$TargetDataLetter = 'U'
$SlackMB          = 1024   # free space left on the target beyond copied content

if (-not $CloneEnabled) {
    Write-Host "Media cloning is disabled - skipping."
    return
}

Write-Host "`n=== Clone Tool Media ===" -ForegroundColor Cyan

# Enabled on the share only means cloning is available on this trip, not that it is
# wanted on this machine. Declining continues into a normal deployment; accepting
# commits to clone-or-deploy and ends in a shutdown.
Write-Warning "Media cloning is enabled."
if ((Read-Host "Clone this tool to another disk? [Y/N]") -ne 'Y') {
    Write-Host "Clone declined - continuing with deployment."
    return
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-Diskpart {
    param([string]$Script, [string]$FileName, [switch]$Quiet)

    $Path = "X:\Deploy\$FileName"
    $Script | Out-File -FilePath $Path -Encoding ascii -Force

    $Output = diskpart /s $Path 2>&1
    if (-not $Quiet) { $Output | Write-Host }
    return $Output
}

function Test-DriveLetterInUse {
    param([string]$Letter)

    if (Test-Path "${Letter}:\") { return $true }
    if ($null -ne (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Clear-DriveLetter {
    # Duplicated from 10-Initialize-Disk.ps1. If a third copy ever appears, factor these
    # out into a shared module rather than maintaining three.
    param([string]$Letter, [string[]]$ProtectedLetters)

    if (-not (Test-DriveLetterInUse -Letter $Letter)) { return }

    if ($ProtectedLetters -contains $Letter) {
        throw "Drive letter ${Letter}: is held by the source media. Cannot proceed."
    }

    $Vol  = Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue
    $Desc = if ($Vol) { "'$($Vol.FileSystemLabel)' ($($Vol.FileSystem))" } else { "an unidentified volume" }
    Write-Host "  ${Letter}: is in use by $Desc - releasing it."

    Invoke-Diskpart -FileName "diskpart-free-$Letter.txt" -Quiet -Script @"
select volume $Letter
remove letter=$Letter noerr
exit
"@ | Out-Null

    Start-Sleep -Seconds 2
    if (Test-DriveLetterInUse -Letter $Letter) {
        throw "Could not release drive letter ${Letter}:."
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

function Invoke-Robocopy {
    # Returns $true when robocopy reported success. Exit codes are a bit field: under 8
    # is success of some flavour, 8+ is a real failure, 16 means it never ran.
    param([string[]]$Arguments, [string]$What)

    & robocopy @Arguments
    $Code = $LASTEXITCODE

    if ($Code -ge 16) {
        Write-Warning "$What FAILED - robocopy could not run (exit $Code)."
        return $false
    }
    if ($Code -ge 8) {
        Write-Warning "$What FAILED - one or more files could not be copied (exit $Code)."
        Write-Warning "On removable media this usually means a failing or counterfeit device."
        return $false
    }
    Write-Host "$What complete (exit $Code)."
    return $true
}

# ---------------------------------------------------------------------------
# Source - resolved once, by disk number, before anything is written
# ---------------------------------------------------------------------------

$SourceDataVolume = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' } |
                    Select-Object -First 1
if (-not $SourceDataVolume) { throw "DeployData volume not found - cannot identify the source media." }

$SourceDataPartition = Get-Partition -DriveLetter $SourceDataVolume.DriveLetter -ErrorAction SilentlyContinue |
                       Select-Object -First 1
if (-not $SourceDataPartition) { throw "Could not resolve the DeployData partition." }

$SourceDisk = [int]$SourceDataPartition.DiskNumber

$SourcePartitions = @(Get-Partition -DiskNumber $SourceDisk -ErrorAction SilentlyContinue)
$SourceBootVolume = $null

foreach ($Part in $SourcePartitions) {
    $Vol = Get-Volume -Partition $Part -ErrorAction SilentlyContinue
    if ($Vol -and $Vol.FileSystem -eq 'FAT32' -and $Vol.DriveLetter) {
        $SourceBootVolume    = $Vol
        $SourceBootPartition = $Part
        break
    }
}

if (-not $SourceBootVolume) {
    throw "No FAT32 boot volume found on source disk $SourceDisk. Expected the WinPE partition."
}

$SourceBootRoot = "$($SourceBootVolume.DriveLetter):\"
$SourceDataRoot = "$($SourceDataVolume.DriveLetter):\"

$BootPartitionMB = [math]::Ceiling($SourceBootPartition.Size / 1MB)
$BootUsedMB      = [math]::Ceiling(($SourceBootVolume.Size - $SourceBootVolume.SizeRemaining) / 1MB)
$DataUsedMB      = [math]::Ceiling(($SourceDataVolume.Size - $SourceDataVolume.SizeRemaining) / 1MB)

# The boot partition is matched to the source rather than scaled. It is never touched by
# the sync - only DeployData is - so its contents cannot grow after the clone is made.
$TargetBootMB = [math]::Max(1024, $BootPartitionMB)
$RequiredMB   = $TargetBootMB + $DataUsedMB + $SlackMB

Write-Host ""
Write-Host "Source disk        : $SourceDisk"
Write-Host "  Boot ($SourceBootRoot)      : $BootUsedMB MB used in a $BootPartitionMB MB partition"
Write-Host "  Data ($SourceDataRoot)      : $DataUsedMB MB used"
Write-Host "Target must be at least $([math]::Round($RequiredMB / 1024, 1)) GB."

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------

$TargetDisks = Get-Disk | Where-Object { $_.Number -ne $SourceDisk }
if (-not $TargetDisks) { throw "No disks available other than the source. Connect the destination media." }

Write-Host "`nAvailable destination disks:`n"
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
$DiskNum = Read-Host "Enter disk number to clone ONTO (ALL DATA WILL BE ERASED)"

$SelectedDisk = $TargetDisks | Where-Object { $_.Number -eq [int]$DiskNum } | Select-Object -First 1
if (-not $SelectedDisk) { throw "Invalid disk number entered." }

$TargetNum   = [int]$SelectedDisk.Number
$TargetSizeMB = [math]::Floor($SelectedDisk.Size / 1MB)

if ($TargetSizeMB -lt $RequiredMB) {
    throw ("Disk $TargetNum is {0} GB. At least {1} GB is required for this tool's content." -f `
           [math]::Round($TargetSizeMB / 1024, 1), [math]::Round($RequiredMB / 1024, 1))
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

$Labels = (Get-Partition -DiskNumber $TargetNum -ErrorAction SilentlyContinue |
           ForEach-Object { (Get-Volume -Partition $_ -ErrorAction SilentlyContinue).FileSystemLabel } |
           Where-Object { $_ }) -join ', '

Write-Host ""
Write-Host "Destination : Disk $TargetNum - $($SelectedDisk.FriendlyName)"
Write-Host "Size        : $([math]::Round($SelectedDisk.Size / 1GB, 0)) GB"
Write-Host "BusType     : $($SelectedDisk.BusType)"
Write-Host "State       : $(Get-DiskStateDescription -Disk $SelectedDisk)"
if ($Labels) { Write-Warning "Existing labels: $Labels" }

if ($SelectedDisk.BusType -ne 'USB') {
    Write-Warning "This is not a USB device. If it is this machine's internal drive, cloning will destroy its contents."
}

Write-Warning "ALL DATA ON DISK $TargetNum WILL BE ERASED."
if ((Read-Host "Type YES to confirm and continue") -ne 'YES') {
    throw "Clone cancelled by operator - deployment stopped."
}

# ---------------------------------------------------------------------------
# Prepare the target
#
# Same conditional handling as 10-Initialize-Disk.ps1: a brand-new SSD or a fresh USB
# can arrive RAW, offline or read-only, and diskpart's clean cannot touch it until that
# is cleared. Each step is a no-op on media that is already usable.
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

Write-Host "`nReclaiming drive letters..."
$Protected = @([string]$SourceBootVolume.DriveLetter, [string]$SourceDataVolume.DriveLetter)
foreach ($Letter in @($TargetBootLetter, $TargetDataLetter)) {
    Clear-DriveLetter -Letter $Letter -ProtectedLetters $Protected
}

# ---------------------------------------------------------------------------
# Partition
#
# Layout matches Build-CaptureUSB.ps1 exactly: a plain primary FAT32 partition for boot
# (not an ESP - UEFI's removable-media rule finds \EFI\BOOT\BOOTX64.EFI on it either
# way) followed by NTFS taking the remainder, which is what makes any target size work.
# ---------------------------------------------------------------------------

Write-Host "`nPartitioning disk $TargetNum..."

$Output = Invoke-Diskpart -FileName "diskpart-clone.txt" -Script @"
select disk $TargetNum
online disk noerr
attributes disk clear readonly noerr
clean
convert gpt
create partition primary size=$TargetBootMB
format fs=fat32 quick label="WinPE"
assign letter=$TargetBootLetter
create partition primary
format fs=ntfs quick label="DeployData"
assign letter=$TargetDataLetter
exit
"@

if ($LASTEXITCODE -ne 0) {
    if ($Output -match 'not free to be assigned') {
        throw "diskpart could not assign ${TargetBootLetter}: or ${TargetDataLetter}: - another volume claimed one after they were released."
    }
    throw "diskpart failed with exit code $LASTEXITCODE"
}

Start-Sleep -Seconds 3

$TargetBootRoot = "${TargetBootLetter}:\"
$TargetDataRoot = "${TargetDataLetter}:\"

if (-not (Test-Path $TargetBootRoot)) { throw "Target boot partition not reachable at $TargetBootRoot." }
if (-not (Test-Path $TargetDataRoot)) { throw "Target data partition not reachable at $TargetDataRoot." }

# ---------------------------------------------------------------------------
# Copy
#
# Robocopy includes hidden and system files by default, which matters - bootmgr carries
# both attributes, and a clone missing it looks perfect and will not boot.
# (Build-CaptureUSB.ps1 passes /H to xcopy for the same reason.)
# ---------------------------------------------------------------------------

Write-Host "`nCopying boot partition: $SourceBootRoot -> $TargetBootRoot"
$BootOK = Invoke-Robocopy -What "Boot partition copy" -Arguments @(
    $SourceBootRoot
    $TargetBootRoot
    '/E'
    '/Z'
    '/R:2'
    '/W:5'
    '/NP'
)

if (-not $BootOK) { throw "Clone failed while copying the boot partition - deployment stopped." }

Write-Host "`nCopying data partition: $SourceDataRoot -> $TargetDataRoot"
$DataOK = Invoke-Robocopy -What "Data partition copy" -Arguments @(
    $SourceDataRoot
    $TargetDataRoot
    '/E'
    '/Z'
    '/R:2'
    '/W:5'
    '/NP'
    '/XD'
    (Join-Path $SourceDataRoot 'Logs')
    (Join-Path $SourceDataRoot 'System Volume Information')
    (Join-Path $SourceDataRoot '$RECYCLE.BIN')
)

if (-not $DataOK) { throw "Clone failed while copying the data partition - deployment stopped." }

# ---------------------------------------------------------------------------
# Verify
#
# Three passes, cheapest first:
#   1. The two files that decide whether the media boots at all. Same check array as
#      Build-CaptureUSB.ps1.
#   2. A robocopy /L pass over each partition. With /E and no /MIR, exit code 0 means
#      nothing remains to be copied - i.e. every source file is present on the target at
#      matching size and timestamp. Non-zero means something did not land.
#   3. SHA256 of boot.wim on both sides. Passes 1 and 2 compare metadata, not content,
#      so a flaky stick that accepted a write and stored garbage still looks clean. This
#      is the one file where corruption means unbootable media, and it is small enough
#      to hash. install.wim is deliberately not hashed - it would add many minutes and a
#      bad apply fails loudly at deploy time anyway.
# ---------------------------------------------------------------------------

Write-Host "`nVerifying clone..."

$BootFiles = @(
    @{ Path = Join-Path $TargetBootRoot 'sources\boot.wim';       Label = 'WinPE boot image' },
    @{ Path = Join-Path $TargetBootRoot 'EFI\Microsoft\Boot\BCD'; Label = 'EFI BCD boot config' }
)

foreach ($Check in $BootFiles) {
    if (Test-Path $Check.Path) { Write-Host ("  [found]    {0}" -f $Check.Label) }
    else { throw ("Verification failed: {0} missing at {1} - the clone will not boot." -f $Check.Label, $Check.Path) }
}

Write-Host "  Comparing boot partition..."
& robocopy $SourceBootRoot $TargetBootRoot /E /L /NP /NJH /NJS | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Verification failed: boot partition differs from the source (robocopy /L exit $LASTEXITCODE)."
}
Write-Host "  [ok]       Boot partition matches source"

Write-Host "  Comparing data partition..."
& robocopy $SourceDataRoot $TargetDataRoot /E /L /NP /NJH /NJS `
    /XD (Join-Path $SourceDataRoot 'Logs') `
        (Join-Path $SourceDataRoot 'System Volume Information') `
        (Join-Path $SourceDataRoot '$RECYCLE.BIN') | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Verification failed: data partition differs from the source (robocopy /L exit $LASTEXITCODE)."
}
Write-Host "  [ok]       Data partition matches source"

$SourceWim = Join-Path $SourceBootRoot 'sources\boot.wim'
$TargetWim = Join-Path $TargetBootRoot 'sources\boot.wim'

Write-Host "  Hashing boot.wim on both devices (this takes a moment)..."
$SourceHash = (Get-FileHash -Path $SourceWim -Algorithm SHA256).Hash
$TargetHash = (Get-FileHash -Path $TargetWim -Algorithm SHA256).Hash

if ($SourceHash -ne $TargetHash) {
    Write-Warning "Source : $SourceHash"
    Write-Warning "Target : $TargetHash"
    throw "Verification failed: boot.wim does not match. The destination device is unreliable - discard it."
}
Write-Host "  [ok]       boot.wim SHA256 matches"

# ---------------------------------------------------------------------------
# Done - shut down rather than reboot
#
# Both disks now answer to the WinPE and DeployData labels. Powering off forces the
# operator to separate them before any label-based lookup runs again, and stops this
# machine booting into media it just created. The throw covers the seconds between
# wpeutil returning and the power actually dropping - without it the orchestrator would
# march on into 20-Check-Manufacturer.ps1.
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Clone complete and verified." -ForegroundColor Green
Write-Host "Disk $TargetNum is now bootable tool media identical to this one."
Write-Host ""
Write-Warning "Both devices now carry the WinPE and DeployData labels."
Write-Warning "Remove one before booting either, or the deployment will pick between them at random."
Write-Host ""
Write-Host "The machine will shut down. Label the new media before it goes in a drawer."
pause

wpeutil shutdown
throw "Clone complete - shutting down. Deployment intentionally not run."
