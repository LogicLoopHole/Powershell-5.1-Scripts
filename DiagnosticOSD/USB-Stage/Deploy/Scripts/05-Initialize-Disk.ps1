# 05-Initialize-Disk.ps1
# Detects firmware type, identifies target disk, partitions and formats
# Sets $OSDrive and $EFIDrive variables for use by Start-Deployment (dot-sourced scope)

Write-Host "  Detecting firmware type..."

# Detect UEFI vs Legacy BIOS
# PEFirmwareType: 1 = BIOS, 2 = UEFI — populated by wpeinit
$FirmwareType = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -ErrorAction SilentlyContinue).PEFirmwareType
$IsUEFI = ($FirmwareType -eq 2)

if ($IsUEFI) {
    Write-Host "  Firmware: UEFI"
} else {
    Write-Error "Legacy BIOS detected. This tool requires UEFI firmware."
    Write-Warning "If this machine supports UEFI, verify it is enabled in firmware settings."
    pause
    exit 1
}

# ============================================================================
# IDENTIFY TARGET DISK
# ============================================================================
Write-Host "  Identifying target disk..."

# Exclude the USB — find which disk hosts the DeployData partition
# $DeployDrive is set by Start-Deployment before this script is dot-sourced
$USBDiskNumber = (Get-Partition | Where-Object { $_.DriveLetter -eq $DeployDrive } |
    Select-Object -First 1).DiskNumber

$TargetDisks = Get-Disk | Where-Object {
    $_.Number -ne $USBDiskNumber -and $_.BusType -ne 'USB'
}

if (-not $TargetDisks) {
    Write-Error "No suitable target disk found. No non-USB disk is present."
    pause
    exit 1
}

$TargetDiskCount = ($TargetDisks | Measure-Object).Count

if ($TargetDiskCount -gt 1) {
    # Multiple internal disks — operator must choose
    Write-Warning "Multiple non-USB disks detected:"
    $TargetDisks | ForEach-Object {
        Write-Host "  Disk $($_.Number) - $($_.FriendlyName) - $([math]::Round($_.Size / 1GB, 0)) GB"
    }
    Write-Host ""
    $DiskNum = Read-Host "Enter disk number to use as target (ALL DATA WILL BE ERASED)"

    $SelectedDisk = $TargetDisks | Where-Object { $_.Number -eq [int]$DiskNum }
    if (-not $SelectedDisk) {
        Write-Error "Invalid disk number entered."
        pause
        exit 1
    }
} else {
    $SelectedDisk = $TargetDisks
}

Write-Host ""
Write-Host "  Target disk : $($SelectedDisk.Number) - $($SelectedDisk.FriendlyName)"
Write-Host "  Size        : $([math]::Round($SelectedDisk.Size / 1GB, 0)) GB"
Write-Host ""
Write-Warning "ALL DATA ON THIS DISK WILL BE ERASED."
$Confirm = Read-Host "Type YES to confirm and continue"

if ($Confirm -ne "YES") {
    Write-Warning "Disk operation cancelled by operator."
    pause
    exit 1
}

# ============================================================================
# PARTITION
# ============================================================================
Write-Host ""
Write-Host "  Partitioning disk $($SelectedDisk.Number)..."

# Write diskpart script to WinPE scratch space
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

if ($LASTEXITCODE -ne 0) {
    Write-Error "diskpart failed with exit code $LASTEXITCODE"
    pause
    exit 1
}

# Allow volumes to register before attempting to access them
Start-Sleep -Seconds 3

# ============================================================================
# SET DRIVE VARIABLES FOR CALLING SCRIPT
# ============================================================================
$OSDrive  = "C:"
$EFIDrive = "S:"

if (-not (Test-Path "$OSDrive\")) {
    Write-Error "OS partition ($OSDrive) not accessible after partitioning. Check diskpart output above."
    pause
    exit 1
}

# Write drive assignments to state file so Start-Deployment and post-apply scripts
# can read them without relying on dot-source scope
$StateFile = "X:\Deploy\DeployState.txt"
@"
OSDrive=$OSDrive
EFIDrive=$EFIDrive
"@ | Out-File -FilePath $StateFile -Encoding ascii -Force

Write-Host "  EFI partition : $EFIDrive"
Write-Host "  OS partition  : $OSDrive"
Write-Host "  Disk preparation complete."
Write-Host ""
