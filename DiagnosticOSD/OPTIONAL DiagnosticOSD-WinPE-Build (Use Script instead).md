# DiagnosticOSD — WinPE Build Walkthrough
*Draft v1.1*

---

## Overview

This guide produces a bootable USB with two partitions:

| Partition | Label | Format | Drive Letter | Contents |
|---|---|---|---|---|
| 1 | WinPE | FAT32 | F: | Boot files, boot.wim |
| 2 | DeployData | NTFS | N: | Deploy scripts, OS WIM, drivers |

The WinPE image (`boot.wim`) is built once and only rebuilt when boot drivers change or WinPE components need updating. All deployment scripts live on the NTFS partition and can be updated without touching WinPE.

**Secure Boot:** No changes to Secure Boot are required. The EFI boot files copied to the FAT32 partition come directly from the ADK and are signed by Microsoft. Custom WinPE is standard practice for enterprise deployment tools.

---

## Console Reference

Every step specifies which console to use.

| Console | Launched from |
|---|---|
| **Deployment and Imaging Tools Environment** | Start → Windows Kits → Deployment and Imaging Tools Environment → right-click → Run as administrator |
| **PowerShell (elevated)** | Start → PowerShell → right-click → Run as administrator |
| **diskpart** | Type `diskpart` from either console |

Do not paste PowerShell syntax into the Deployment Tools Environment — it is CMD only.

---

## Part 1 — Build the WinPE Image

All commands in Part 1 run in the **Deployment and Imaging Tools Environment (CMD), elevated** unless otherwise noted.

### Step 1.1 — Create WinPE Working Files

`copype` creates its own destination folder. If `C:\DiagOSD-Build\WinPE` already exists from the initial folder setup, delete it first — `copype` will error if the destination exists:

```cmd
rmdir /S /Q C:\DiagOSD-Build\WinPE
copype amd64 C:\DiagOSD-Build\WinPE
```

Expected: output ending with "Successfully staged C:\DiagOSD-Build\WinPE".

Confirm:
```cmd
dir C:\DiagOSD-Build\WinPE\media\sources\boot.wim
```

### Step 1.2 — Mount the WinPE Image

```cmd
DISM /Mount-Image /ImageFile:"C:\DiagOSD-Build\WinPE\media\sources\boot.wim" /Index:1 /MountDir:"C:\DiagOSD-Build\WinPE\mount"
```

Expected: progress bar to 100%, "The operation completed successfully."

---

### Step 1.3 — Add Optional Components

Paste these two `SET` lines at the start of every Deployment Tools Environment session — they are session-only and must be re-entered if the console is closed and reopened:

```cmd
SET OC=C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs
SET MNT=C:\DiagOSD-Build\WinPE\mount
```

Install components in dependency order. Each requires the base `.cab` and the English language `.cab` as a pair.

**1. WinPE-WMI**
```cmd
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\WinPE-WMI.cab"
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\en-us\WinPE-WMI_en-us.cab"
```

**2. WinPE-NetFX** — required for all Windows Forms dialogs
```cmd
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\WinPE-NetFX.cab"
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\en-us\WinPE-NetFX_en-us.cab"
```

**3. WinPE-Scripting**
```cmd
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\WinPE-Scripting.cab"
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\en-us\WinPE-Scripting_en-us.cab"
```

**4. WinPE-PowerShell** — requires WMI + NetFX + Scripting above
```cmd
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\WinPE-PowerShell.cab"
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\en-us\WinPE-PowerShell_en-us.cab"
```

**5. WinPE-StorageWMI** — requires WMI
```cmd
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\WinPE-StorageWMI.cab"
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\en-us\WinPE-StorageWMI_en-us.cab"
```

**6. WinPE-DismCmdlets** — requires PowerShell
```cmd
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\WinPE-DismCmdlets.cab"
DISM /Add-Package /Image:"%MNT%" /PackagePath:"%OC%\en-us\WinPE-DismCmdlets_en-us.cab"
```

**Verify all 12 packages installed:**
```cmd
DISM /Get-Packages /Image:"%MNT%"
```

Expected: 14 packages total — the 2 base WinPE packages that ship with the ADK plus the 12 just installed (6 feature packs + 6 language packs), all showing State: Installed.

---

### Step 1.4 — Add Boot Drivers

```cmd
DISM /Add-Driver /Image:"%MNT%" /Driver:"C:\DiagOSD-Build\ExtractedBootDrivers" /Recurse
```

Skip this step if `ExtractedBootDrivers` is empty. DISM will error on an empty path.

---

### Step 1.5 — Create the WinPE Launcher

Switch to **elevated PowerShell** for Steps 1.5 and 1.6.

The launcher is embedded in WinPE at `X:\Deploy\Launch.ps1`. Its only job is to find the `DeployData` volume by label and call `Start-Deployment.ps1` from it — this avoids hardcoding a drive letter that WinPE may assign differently per machine.

```powershell
$LauncherContent = @'
# X:\Deploy\Launch.ps1
$Drive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter

if (-not $Drive) {
    Write-Error "DeployData volume not found. Verify USB is connected and NTFS partition is labeled 'DeployData'."
    pause
    exit 1
}

$MasterScript = "${Drive}:\Deploy\Start-Deployment.ps1"

if (-not (Test-Path $MasterScript)) {
    Write-Error "Start-Deployment.ps1 not found at $MasterScript"
    pause
    exit 1
}

& $MasterScript
'@

$LauncherContent | Out-File -FilePath "C:\DiagOSD-Build\WinPE\mount\Deploy\Launch.ps1" -Encoding ascii -Force
Write-Host "Launcher written."
```

---

### Step 1.6 — Write startnet.cmd

`startnet.cmd` is the WinPE entry point — it runs automatically after `wpeinit` initializes hardware on boot.

```powershell
$StartnetContent = @'
@echo off
wpeinit
powershell.exe -ExecutionPolicy Bypass -File "X:\Deploy\Launch.ps1"
'@

$StartnetContent | Out-File -FilePath "C:\DiagOSD-Build\WinPE\mount\Windows\System32\startnet.cmd" -Encoding ascii -Force
Get-Content "C:\DiagOSD-Build\WinPE\mount\Windows\System32\startnet.cmd"
```

Expected output — exactly three lines:
```
@echo off
wpeinit
powershell.exe -ExecutionPolicy Bypass -File "X:\Deploy\Launch.ps1"
```

---

### Step 1.7 — Unmount and Commit

Switch back to the **Deployment and Imaging Tools Environment (CMD)**. Re-paste the `SET MNT=` line if the console was reopened.

```cmd
DISM /Unmount-Image /MountDir:"C:\DiagOSD-Build\WinPE\mount" /Commit
```

Expected: two progress bars (Saving image, Unmounting image), "The operation completed successfully."

Do not interrupt. If the commit fails:
```cmd
DISM /Unmount-Image /MountDir:"C:\DiagOSD-Build\WinPE\mount" /Discard
DISM /Cleanup-Wim
```
Then restart from Step 1.2.

---

## Part 2 — Prepare the USB

### Step 2.1 — Identify the USB Disk Number

Run in **elevated PowerShell**:

```powershell
Get-Disk | Select-Object Number, FriendlyName, Size, BusType
```

Identify the USB by size and BusType `USB`. Note the disk number.

> Verify the disk number carefully before proceeding. The diskpart commands below destroy all data on the selected disk.

---

### Step 2.2 — Partition the USB

```cmd
diskpart
```

Replace `X` with your USB disk number:

```
list disk
select disk X
clean
convert gpt
create partition primary size=1024
format fs=fat32 quick label=WinPE
assign letter=F
create partition primary
format fs=ntfs quick label=DeployData
assign letter=N
exit
```

Verify in **elevated PowerShell**:

```powershell
Get-Volume | Where-Object { $_.FileSystemLabel -in @('WinPE','DeployData') }
```

Expected: `F` for WinPE (FAT32, ~1020 MB) and `N` for DeployData (NTFS, remainder).

> If `F:` is already in use, substitute any available letter in the diskpart `assign` command and the xcopy command below. `N:` should be free on most systems but check first.

---

### Step 2.3 — Copy WinPE Boot Files to FAT32 Partition

In the **Deployment and Imaging Tools Environment (CMD)**:

```cmd
xcopy C:\DiagOSD-Build\WinPE\media\* F:\ /E /H /F
```

---

### Step 2.4 — Copy Staging Content to NTFS Partition

In **elevated PowerShell**:

```powershell
robocopy "C:\DiagOSD-Build\USB-Stage\" "N:\" /E /NP
```

---

### Step 2.5 — Verify

```powershell
Test-Path "F:\sources\boot.wim"
Test-Path "F:\EFI\Microsoft\Boot\BCD"
Test-Path "N:\Deploy\Scripts\02-Check-Manufacturer.ps1"
```

All three should return `True`.

---

## Part 3 — Test Boot

Boot the target machine from the USB. Expected sequence:

1. UEFI selects the USB FAT32 partition
2. WinPE loads
3. `wpeinit` runs — NIC initializes, DHCP assigns
4. `startnet.cmd` calls `X:\Deploy\Launch.ps1`
5. Launcher finds `N:\` and looks for `Start-Deployment.ps1`

Until `Start-Deployment.ps1` exists on the NTFS partition, the launcher will display "not found" and pause — this is expected and confirms WinPE, PowerShell, and volume detection are all working correctly.

---

## Rebuild Reference

| Change | Steps required |
|---|---|
| Script update (any .ps1 on NTFS) | Re-run Step 2.4 only — no WinPE rebuild |
| New driver added to NTFS Drivers\ | Re-run Step 2.4 only |
| New boot driver needed in WinPE | Steps 1.2 → 1.4 → 1.7 → 2.3 |
| startnet.cmd or launcher changed | Steps 1.2 → 1.6 → 1.7 → 2.3 |
| New WinPE component needed | Steps 1.2 → 1.3 → 1.7 → 2.3 |
| Full rebuild from scratch | Steps 1.1 → 2.5 |

---

*DiagnosticOSD is provided as-is under the MIT license. Validate everything in your environment before production use.*
