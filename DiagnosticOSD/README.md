# DiagnosticOSD — Project Reference

*v1.0-beta — Updated 2026-03-11*

---

## Overview

DiagnosticOSD is a validated, offline-first Windows deployment tool built on a custom WinPE environment using the Windows ADK. It has no runtime dependency on OSDCloud, PSGallery, NuGet, or any network service at deploy time.

The **short-term goal** is a reliable bare-metal diagnostic imaging tool — a known-good, tested baseline to help isolate whether imaging issues originate client-side or in the SCCM/MDT pipeline. DiagnosticOSD and SCCM are intended to coexist during this phase.

The **long-term goal** is a capable standalone replacement for SCCM bare-metal imaging, handling drivers, post-OS application deployment, SCCM agent installation, and domain join in a pipeline that functions independently of any server-side management infrastructure.

> ⚠️ This is an engineering-level tool. Proceed with appropriate caution.

**Assumptions:**

- LAN deployment, DC-connected
- Ethernet available at boot
- Single WIM per USB build

---

## Current Status

**Beta milestone reached 2026-03-11.** Full end-to-end deployment confirmed working on test hardware:

- WinPE boots with Secure Boot enabled
- All 6 WinPE optional components load correctly
- Hardware detection, hostname prompt, disk partitioning, image apply, driver injection, unattend write, first logon config, and update deferral all complete
- Machine reboots, runs through OOBE/specialize, installs injected drivers, and boots into Windows

Domain join (`Join-Domain.ps1`) and the PSADT post-OS pipeline have not yet been validated end-to-end in this build.

---

## Dependency Profile

| Component                | Required           | Source                        | Notes                                |
| ------------------------ | ------------------ | ----------------------------- | ------------------------------------ |
| Windows ADK 23H2         | Build machine only | Microsoft (offline installer) | Deployment Tools + WinPE add-on only |
| Windows ADK WinPE Add-on | Build machine only | Microsoft (offline installer) | Required for WinPE build             |
| PowerShell 5.1           | WinPE runtime      | Built into ADK WinPE          | No install required                  |
| WIM file                 | USB content        | You provide                   | Not in repo                          |
| Driver packs             | USB content        | OEM SCCM packs or extracted   | Not in repo                          |
| PS Gallery               | —                  | **Not required**              | —                                    |
| NuGet provider           | —                  | **Not required**              | —                                    |
| Internet at deploy time  | —                  | **Not required**              | —                                    |

---

## ADK Version

**23H2 ADK (10.1.22631)** is the target for this project.

The ADK version determines the WinPE version, not the OS version being deployed. A WinPE built from the 23H2 ADK deploys any WIM without issue — ADK version and target OS do not need to match.

- Stable, broadly documented, known-good with current Lenovo ThinkPad hardware
- WinPE 23H2 fully supports PS 5.1, WMI, Windows Forms (via NetFX), DISM, and all required components
- Does not require the build machine to run Windows 11 24H2

Rebuild on 24H2 ADK only if specific hardware fails to boot or loses NIC/storage under 23H2 WinPE.

> **ADK Install:** Select "Deployment Tools" and "Windows Preinstallation Environment" only. Uncheck all other components.

---

## WinPE Optional Components

| Package           | Purpose                                                                                             |
| ----------------- | --------------------------------------------------------------------------------------------------- |
| WinPE-WMI         | `Get-CimInstance Win32_ComputerSystemProduct` — model detection                                     |
| WinPE-NetFX       | **Required** — enables Windows Forms and VisualBasic assemblies; without this, all GUI dialogs fail |
| WinPE-PowerShell  | PowerShell 5.1                                                                                      |
| WinPE-DismCmdlets | `Expand-WindowsImage`, `Add-WindowsDriver`, `Get-WindowsDriver`                                     |
| WinPE-StorageWMI  | `Get-Volume`, `Get-Disk`, `Get-Partition`                                                           |
| WinPE-Scripting   | WSH support                                                                                         |

---

## USB / SSD Partition Layout

```
USB / SSD
│
├── [FAT32 ~1GB — "WinPE"]
│   ├── Boot\                        # ADK bootmgr files
│   ├── EFI\                         # UEFI boot support
│   └── sources\
│       └── boot.wim                 # Custom WinPE (ADK-built, drivers injected)
│           └── Windows\System32\
│               └── startnet.cmd     # Entry point → calls Launch.ps1
│
└── [NTFS — "DeployData"]
    ├── Deploy\
    │   ├── Launch.ps1               # WinPE entry point — locates DeployData by label
    │   ├── Start-Deployment.ps1     # Master orchestration script
    │   └── Scripts\
    │       ├── 01-Sync-Content.ps1  # (currently disabled during testing)
    │       ├── 02-Check-Manufacturer.ps1
    │       ├── 03-Get-HostnameUserPrompt.ps1
    │       ├── 05-Initialize-Disk.ps1
    │       ├── 10-Invoke-DriverInjection.ps1
    │       ├── 20-Write-HostnameUnattend.ps1
    │       ├── 30-Configure-FirstLogon.ps1
    │       └── 40-Defer-Updates.ps1
    ├── OS\
    │   └── <your.wim>               # Not in repo
    ├── Drivers\
    │   └── <Vendor>\<Model>\        # OEM driver packs, expanded
    └── PostOS\
        ├── PSADT\
        │   ├── Deploy-SCCMAgent\
        │   └── Deploy-<AppName>\
        └── Scripts\
            └── Join-Domain.ps1      # Runs at first logon
```

**WinPE scratch path:** `X:\Deploy\` is used for inter-script state. `Hostname.txt` carries the collected hostname into post-apply scripts. `DeployState.txt` carries `$OSDrive` and `$EFIDrive` from disk initialization into the master orchestrator.

---

## Deployment Boot Flow

```
Power On
  └─► UEFI selects USB boot device
        └─► FAT32 bootmgr
              └─► WinPE loads (boot.wim)
                    └─► wpeinit  [NIC init, DHCP]
                          └─► startnet.cmd
                                └─► X:\Deploy\Launch.ps1
                                      Locates DeployData volume by label
                                      └─► Start-Deployment.ps1
                                            │
                                            ├─► [PRE-IMAGING]
                                            │     01 - Sync USB content from share (disabled)
                                            │     02 - Validate hardware model / driver folder
                                            │     03 - Collect hostname from operator
                                            │
                                            ├─► [DISK & IMAGE]
                                            │     05 - Detect UEFI, partition, format
                                            │          └─► writes X:\Deploy\DeployState.txt
                                            │     Expand-WindowsImage (inline)
                                            │     bcdboot (inline)
                                            │
                                            └─► [POST-APPLY — offline OS]
                                                  10 - Inject drivers (DISM offline)
                                                  20 - Write hostname to unattend.xml
                                                  30 - Configure first logon (AutoLogon + temp admin)
                                                  40 - Defer Windows Update (offline registry)
                                                  Reboot
                                                    └─► Windows Specialize / OOBE
                                                          └─► AutoLogon (temp local admin, 1 logon)
                                                                └─► Join-Domain.ps1
                                                                      Credential prompt
                                                                      Add-Computer
                                                                      Remove AutoLogon + temp admin
                                                                      Reboot (domain-joined)
```

---

## Script Structure

Phase scripts are called via `Invoke-Phase` in `Start-Deployment.ps1`, which dot-sources them internally for clean error handling and consistent output formatting.

```powershell
function Invoke-Phase {
    param([string]$Name, [string]$Script)
    # Finds script, dot-sources it, wraps in try/catch, exits on failure
}

Invoke-Phase "Manufacturer Check"  "02-Check-Manufacturer.ps1"
Invoke-Phase "Hostname Collection" "03-Get-HostnameUserPrompt.ps1"
Invoke-Phase "Disk Initialization" "05-Initialize-Disk.ps1"
# ... image apply and bcdboot inline ...
Invoke-Phase "Driver Injection"    "10-Invoke-DriverInjection.ps1"
# etc.
```

**Variable sharing between phases** uses file-based state in `X:\Deploy\` rather than dot-source scope propagation. Dot-sourcing inside a function does not propagate variables to the calling script's scope, so any variable a phase script needs to export is written to a file and read back by the orchestrator or subsequent scripts directly.

| State File                  | Written by           | Contains                | Read by                |
| --------------------------- | -------------------- | ----------------------- | ---------------------- |
| `X:\Deploy\Hostname.txt`    | `03-Get-Hostname...` | Confirmed hostname      | `20-Write-Hostname...` |
| `X:\Deploy\DeployState.txt` | `05-Initialize-Disk` | `OSDrive=`, `EFIDrive=` | `Start-Deployment.ps1` |

Each phase script is independently readable and testable. No hidden scope dependency between scripts.

---

## Disk Partition Layout (Target Disk)

| Partition  | Type    | Size      | Format | Label    | Drive |
| ---------- | ------- | --------- | ------ | -------- | ----- |
| EFI System | EFI     | 260 MB    | FAT32  | SYSTEM   | S:    |
| MSR        | MSR     | 16 MB     | RAW    | —        | —     |
| OS         | Primary | Remainder | NTFS   | Windows  | C:    |
| Recovery   | Primary | 990 MB    | NTFS   | Recovery | —     |

Recovery partition included to mirror production layout and support "Reset this PC".

---

## Phase Detail

### Pre-Imaging

**01 — Sync Content** *(currently disabled during testing)*
Mirrors the `DeployData` NTFS partition against a LAN share using robocopy `/MIR`. Prompts for domain credentials (up to 3 attempts). Blocks imaging on auth failure or sync error.

**02 — Check Manufacturer**
Detects hardware model via WMI. Lenovo: `Win32_ComputerSystemProduct.Version`. Others: `.Name`. Validates matching driver folder exists under `Drivers\<Vendor>\<Model>\`. Hard stops with a Windows Forms error dialog on unsupported hardware — dialog format (Manufacturer, Model, Serial, expected path) is designed for screenshot-to-ticket workflows. Script re-queries WMI directly so it has no dependency on shared scope.

**03 — Get Hostname**
Windows Forms `InputBox` for hostname entry. Validates `^H\d{7}$` (standard format) with a non-standard override path. Confirmation dialog before accepting. Result written to `X:\Deploy\Hostname.txt`.

### Disk and Image

**05 — Initialize Disk**
Detects firmware type via `PEFirmwareType` registry key, hard stops on Legacy BIOS. Identifies target disk by excluding the USB (matched by `$DeployDrive` from calling scope). Operator confirmation required before wipe. Runs diskpart for GPT layout. Writes `X:\Deploy\DeployState.txt` on success so `$OSDrive` and `$EFIDrive` are available to the orchestrator.

**Image Apply** *(inline in Start-Deployment.ps1)*
`Expand-WindowsImage` with `-Index 1`. Hardcoded index is appropriate for single-edition captured enterprise WIMs — confirm index count if using a full Microsoft install.wim.

**bcdboot** *(inline in Start-Deployment.ps1)*
`bcdboot C:\Windows /s S: /f UEFI`. Checks `$LASTEXITCODE` and hard stops on failure.

### Post-Apply (Offline OS)

**10 — Driver Injection**
Re-queries WMI for manufacturer/model directly (no scope dependency). Locates `DeployData` volume by label. Copies driver folder to `C:\Drivers\` staging before injecting — avoids drive letter shift issues during injection. Uses `Add-WindowsDriver -Recurse`. Lists injected drivers on completion.

**20 — Write Hostname Unattend**
Reads hostname from `X:\Deploy\Hostname.txt`. Writes specialize-pass `unattend.xml` to `C:\Windows\Panther\`.

**30 — Configure First Logon**
Writes oobeSystem `unattend.xml` — AutoLogon (1 count), temp local admin account, OOBE suppression, `FirstLogonCommands` pointing to `Join-Domain.ps1`. Copies `Join-Domain.ps1` from `PostOS\Scripts\` on the USB to `C:\Deploy\Scripts\`.

**40 — Defer Updates**
Offline registry edit to defer Windows Update 7 days. GPO/policy overrides after domain join.

### Post-OS

**Join-Domain.ps1**
Runs at first logon via AutoLogon + FirstLogonCommands. Prompts for domain credentials (up to 3 attempts). Joins to configured domain, OU, and DC. On success: removes AutoLogon keys, removes temp admin account, forced reboot into domain-joined session. Logs to `C:\Deploy\Logs\`.

**PSADT Pipeline** *(planned, not yet validated)*
Sequential PSADT package calls post-domain-join. Each package blocks until complete. Adding or removing a deployment step is one folder and one call line.

---

## Console Output and Error Handling

| Situation                       | Method                             |
| ------------------------------- | ---------------------------------- |
| Normal progress / phase headers | `Write-Host`                       |
| Non-fatal warnings              | `Write-Warning`                    |
| Fatal errors                    | `Write-Error` → `pause` → `exit 1` |

On unhandled fatal error the script exits and the WinPE command prompt is available. Console scroll buffer retains full error detail. Each phase script includes a `pause` at completion during active development — these can be removed once a phase is fully validated.

---

## Extracting Boot Drivers from SCCM

The SCCM boot image contains validated boot drivers for the fleet. Extract them into an independently owned staging folder and inject into the DiagnosticOSD WinPE. Read-only against SCCM source.

```powershell
$SCCMBootWim = "\\<SiteServer>\SMS_<SiteCode>\osd\boot\x64\boot.wim"
$MountDir    = "C:\Temp\SCCMMount"
$DriverOut   = "C:\DiagnosticOSD-Build\ExtractedBootDrivers"

New-Item -ItemType Directory -Path $MountDir, $DriverOut -Force

DISM /Mount-Image /ImageFile:"$SCCMBootWim" /Index:1 /MountDir:"$MountDir" /ReadOnly
DISM /Image:"$MountDir" /Export-Driver /Destination:"$DriverOut"
DISM /Unmount-Image /MountDir:"$MountDir" /Discard
```

`ExtractedBootDrivers` is a versioned artifact independent of SCCM. Re-extract when the SCCM boot image is updated for new hardware.

---

## USB Duplication Strategy

Initial USB production uses a `dd`-style full-disk image of the validated development USB, written via an existing SCCM task sequence pattern used for Linux thin client imaging. SCCM treats this as an opaque image write with no awareness of partition layout or content.

Incremental content updates (scripts, drivers, WIM) are handled by `01-Sync-Content.ps1` once re-enabled. Full re-imaging from the `dd` source is reserved for rebuilds or new drive stock.

---

## Issues Resolved

| Issue                                                    | Resolution                                                                        |
| -------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `copype` fails if `WinPE` folder already exists          | `rmdir /S /Q` before `copype`                                                     |
| DISM `Error 5 / Access Denied` on image apply            | Replaced `DISM.exe /Apply-Image` with `Expand-WindowsImage` PowerShell cmdlet     |
| Recovery partition creation fails                        | Added `shrink desired=990` after OS partition before creating Recovery            |
| PS 7 null-conditional `?.` syntax in PS 5.1 WinPE        | Removed from all scripts                                                          |
| Drive letter conflict on build VM                        | FAT32 USB partition changed to `F:`                                               |
| `$OSDrive` / `$EFIDrive` empty after disk initialization | `Invoke-Phase` dot-source runs inside function scope; fixed via `DeployState.txt` |
| PSGallery dependency at WinPE build time                 | Eliminated — no PS Gallery dependency anywhere in the pipeline                    |

---

## Remaining Work

| Item                            | Priority | Notes                                                                                    |
| ------------------------------- | -------- | ---------------------------------------------------------------------------------------- |
| Validate `Join-Domain.ps1`      | High     | Not yet tested in this build; domain join + temp admin removal + reboot flow unconfirmed |
| Re-enable `01-Sync-Content.ps1` | Medium   | Currently commented out; validate share auth and robocopy behaviour before enabling      |
| PSADT pipeline validation       | Medium   | Folder structure exists; sequential install flow not yet exercised                       |
| Multi-model driver validation   | Medium   | Only tested on one model; Lenovo `Version` vs other `.Name` path needs coverage          |
| USB duplication via SCCM TS     | Low      | `dd`-style TS exists for thin clients; adapt and test for DiagnosticOSD USB              |
| Remove per-phase `pause` calls  | Low      | Useful during validation; remove from confirmed phases before production                 |

---

## Simplification Candidates

Now that the pipeline is working, a few things are worth tidying in a low-risk pass:

**`02-Check-Manufacturer.ps1` — remove `pause` at end.** The phase already hard-stops on unsupported hardware. The pause on the success path slows down unattended runs with no benefit once the script is validated.

**`10-Invoke-DriverInjection.ps1` — de-duplicate WMI query.** This script re-queries `Win32_ComputerSystemProduct` from scratch because it can't rely on scope from `02-Check-Manufacturer`. That's correct and intentional, but the identical detection logic lives in two files. If `02` wrote `Manufacturer` and `ModelName` to `DeployState.txt` alongside the drive letters, `10` could read them instead — one WMI query, one source of truth. Low priority unless the duplication causes a maintenance problem.

**`03-Get-HostnameUserPrompt.ps1` — `$ComputerName` variable is unused downstream.** The variable is set but post-apply scripts read from `Hostname.txt` directly, and the final summary printout in `Start-Deployment.ps1` was removed. The `$ComputerName` assignment can be dropped to reduce confusion about what the script actually exports.

**`01-Sync-Content.ps1` — consider enabling with a skip prompt.** Rather than commenting it out, a `Read-Host "Sync content from LAN? [Y/N]"` at the top lets operators skip it situationally without requiring a script edit or USB re-burn.

---

## Repo and Licensing

- **License:** MIT — scripts and folder structure only
- **Placeholders:** `Example.Domain`, `DC01.Example.Domain`, `CN=Computers,DC=Example,DC=Domain`, `\\OSDCloud.Example.Domain\OSD-NTFS$`, `osdadmin`
- **Excluded from repo (`.gitignore`):** WIM files, expanded driver packs, any file containing real environment values

---

*DiagnosticOSD is provided as-is under the MIT license. You are responsible for validating anything deployed in your environment.*
