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

# 25-Configure-WinRE.ps1
# OS-Build - Runs in WinPE post-apply - AFTER image applied, BEFORE reboot.
# Stages Winre.wim into the dedicated recovery partition and points the offline OS
# at it, so WinRE lives outside the Windows partition as Microsoft specifies.
#
# Numbered 25 so it lands between 20-Apply-Image.ps1 (which must run first - this
# script needs the applied Winre.wim and the applied Reagentc.exe) and
# 30-Driver-Injection.ps1, without renumbering anything else. Start-Deployment.ps1
# sorts by filename, so dropping the file in is the whole install.
#
# Reads OSDrive, RecoveryDrive, RecoveryDisk, RecoveryPartition from
# X:\Deploy\DeployState.txt (set by 10-Initialize-Disk.ps1).
#
# Without this step, first boot finds no usable recovery partition and configures
# WinRE in place at C:\Recovery\WindowsRE. The machine still works and reagentc
# reports WinRE enabled, so it passes a casual check - but the recovery partition
# sits empty and picks up a drive letter, and WinRE cannot be reached on a
# BitLocker-encrypted OS volume.

Write-Host "`n=== Configure WinRE ===" -ForegroundColor Cyan

$RecoveryTypeGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$StateFile = "X:\Deploy\DeployState.txt"
if (-not (Test-Path $StateFile)) {
    Write-Warning "DeployState.txt not found at $StateFile. Ensure 10-Initialize-Disk.ps1 completed."
    pause
    return
}

Get-Content $StateFile | ForEach-Object {
    if ($_ -match '^(\w+)=(.+)$') { Set-Variable -Name $Matches[1] -Value $Matches[2] }
}

if (-not $OSDrive) { throw "OSDrive not found in DeployState.txt" }

if (-not $RecoveryDrive) {
    Write-Warning "RecoveryDrive not found in DeployState.txt - this USB is running an older 10-Initialize-Disk.ps1."
    Write-Warning "Skipping WinRE configuration. WinRE will be configured on the OS partition at first boot."
    pause
    return
}

# ---------------------------------------------------------------------------
# Source image
# ---------------------------------------------------------------------------

$SourceWim = "$OSDrive\Windows\System32\Recovery\Winre.wim"
if (-not (Test-Path $SourceWim)) {
    Write-Warning "Winre.wim not found at $SourceWim."
    Write-Warning "The applied image was likely built with WinRE removed - skipping WinRE configuration."
    pause
    return
}

$WimSizeMB = [math]::Round((Get-Item $SourceWim -Force).Length / 1MB, 0)
Write-Host "Source WinRE image : $SourceWim ($WimSizeMB MB)"

# ---------------------------------------------------------------------------
# Recovery partition
#
# 10-Initialize-Disk.ps1 assigns R: and then applies GPT attribute
# 0x8000000000000001, which suppresses automatic drive letters from the next mount
# onward. The letter normally survives for the rest of this WinPE session; re-assign
# it if something dropped it.
# ---------------------------------------------------------------------------

if (-not (Test-Path "$RecoveryDrive\")) {
    if (-not $RecoveryDisk -or -not $RecoveryPartition) {
        throw "Recovery partition not mounted at $RecoveryDrive and no disk/partition number in DeployState.txt to re-assign it."
    }

    Write-Host "Recovery partition not mounted - re-assigning $RecoveryDrive..."
    $Letter        = $RecoveryDrive -replace ':',''
    $AssignFile    = "X:\Deploy\diskpart-winre-assign.txt"
    @"
select disk $RecoveryDisk
select partition $RecoveryPartition
assign letter=$Letter
exit
"@ | Out-File -FilePath $AssignFile -Encoding ascii -Force

    diskpart /s $AssignFile | Out-Null
    Start-Sleep -Seconds 3
}

if (-not (Test-Path "$RecoveryDrive\")) {
    throw "Recovery partition is not accessible at $RecoveryDrive - cannot stage WinRE."
}

# Confirm we are writing into an actual recovery partition and not some other volume
# that happened to inherit the letter.
#
# Looked up by disk/partition number, NOT by drive letter. Once the no-drive-letter
# GPT attribute is set, the partition stops reporting its letter through the storage
# provider - the same reason 'Get-Partition -DriveLetter S' finds nothing for an ESP.
# A -DriveLetter lookup here would return null on a correctly configured partition.
if ($RecoveryDisk -and $RecoveryPartition) {
    $Partition = Get-Partition -DiskNumber $RecoveryDisk -PartitionNumber $RecoveryPartition -ErrorAction SilentlyContinue
    if ($Partition -and $Partition.GptType -ne "{$RecoveryTypeGuid}") {
        throw "Disk $RecoveryDisk partition $RecoveryPartition is type $($Partition.GptType), not a recovery partition. Refusing to stage WinRE there."
    }

    $Volume = $Partition | Get-Volume -ErrorAction SilentlyContinue
    if ($Volume) {
        $FreeMB = [math]::Round($Volume.SizeRemaining / 1MB, 0)
        if ($FreeMB -lt ($WimSizeMB + 250)) {
            Write-Warning "Recovery partition has $FreeMB MB free for a $WimSizeMB MB image."
            Write-Warning "Microsoft recommends 250 MB free after staging for future WinRE updates. Consider raising `$RecoverySizeMB in 10-Initialize-Disk.ps1."
        }
    }
}

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------

$WinREDir = "$RecoveryDrive\Recovery\WindowsRE"

Write-Host "Staging WinRE to $WinREDir..."
New-Item -Path $WinREDir -ItemType Directory -Force | Out-Null
Copy-Item -Path $SourceWim -Destination "$WinREDir\Winre.wim" -Force

if (-not (Test-Path "$WinREDir\Winre.wim")) {
    throw "Winre.wim copy to $WinREDir failed."
}

# Reagentc from the APPLIED image, not the WinPE copy. The WinPE copy targets the
# X: ramdisk and will not register the location against the offline OS. /path takes
# no trailing backslash.
$Reagentc = "$OSDrive\Windows\System32\Reagentc.exe"
if (-not (Test-Path $Reagentc)) { throw "Reagentc.exe not found at $Reagentc." }

Write-Host "Registering WinRE location against $OSDrive\Windows..."
& $Reagentc /setreimage /path $WinREDir /target "$OSDrive\Windows"

if ($LASTEXITCODE -ne 0) {
    throw "reagentc /setreimage failed with exit code $LASTEXITCODE"
}

# ---------------------------------------------------------------------------
# Verify
#
# Expect a Windows RE location pointing at a \\?\GLOBALROOT\device\harddisk#\partition#
# path - a path under \Windows or C:\Recovery means the registration did not take.
# ---------------------------------------------------------------------------

Write-Host ""
& $Reagentc /info /target "$OSDrive\Windows"

# The letter is dropped for tidiness only. What actually keeps the partition hidden
# on the deployed machine is the GPT attribute set in 10-Initialize-Disk.ps1 - drive
# letters assigned in WinPE live in the ramdisk's mount table and are discarded at
# reboot regardless.
if ($RecoveryDisk -and $RecoveryPartition) {
    $RemoveFile = "X:\Deploy\diskpart-winre-remove.txt"
    @"
select disk $RecoveryDisk
select partition $RecoveryPartition
remove letter=$($RecoveryDrive -replace ':','') noerr
exit
"@ | Out-File -FilePath $RemoveFile -Encoding ascii -Force

    diskpart /s $RemoveFile | Out-Null
}

Write-Host ""
Write-Host "WinRE staged to the recovery partition."

pause
