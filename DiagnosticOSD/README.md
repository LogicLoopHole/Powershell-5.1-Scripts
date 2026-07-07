# DiagnosticOSD — Project Reference

*v2.0-beta — Updated 2026-07-02*

---

## Overview

DiagnosticOSD is a validated, offline-first Windows deployment tool built on a custom WinPE environment using the Windows ADK. It has no runtime dependency on OSDCloud, PSGallery, NuGet, or any network service at deploy time.

The **short-term goal** is a reliable bare-metal diagnostic imaging tool — a known-good, tested baseline to help isolate whether imaging issues originate client-side or in the SCCM/MDT pipeline. DiagnosticOSD and SCCM are intended to coexist during this phase.

The **long-term goal** is a capable standalone replacement for SCCM bare-metal imaging, handling drivers, post-OS application deployment, SCCM agent installation, and domain join in a pipeline that functions independently of any server-side management infrastructure.

> ⚠️ This is an engineering-level tool. Proceed with appropriate caution.

**Assumptions:**

- LAN deployment, DC-connected (domain join is manual and retryable — pre-join operation is fully offline-capable)
- Ethernet available at boot
- Single WIM per USB build
- UEFI targets only (Legacy BIOS hard-stops by design)

---

## Current Status

**v2.0 beta milestone reached 2026-07-02.** Full pipeline confirmed end-to-end on VMs and on two physical hardware models: imaging, driver injection, the forced-password-change flow, and domain join — including rejoin of a pre-existing AD computer account and full deploy-artifact self-cleanup.

Not yet validated in this build: the content-sync share workflow (`10-Sync-Content`, deliberately deferred; ships warn-and-continue with `$DevMode = $true`) and the PSADT post-OS pipeline (planned).

---

## Dependency Profile

| Component                | Required           | Source                             | Notes                                |
| ------------------------ | ------------------ | ---------------------------------- | ------------------------------------ |
| Windows ADK 23H2         | Build machine only | Microsoft (offline installer)      | Deployment Tools + WinPE add-on only |
| Windows ADK WinPE Add-on | Build machine only | Microsoft (offline installer)      | Required for WinPE build             |
| PowerShell 5.1           | WinPE runtime      | Built into ADK WinPE               | No install required                  |
| WIM file                 | USB content        | You capture (see CAPTURE-GUIDE.md) | Not in repo                          |
| Driver packs             | USB content        | OEM SCCM packs or extracted        | Not in repo                          |
| PS Gallery               | —                  | **Not required**                   | —                                    |
| NuGet provider           | —                  | **Not required**                   | —                                    |
| Internet at deploy time  | —                  | **Not required**                   | —                                    |

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
    │   ├── Start-Deployment.ps1     # Master orchestration (transcript → Logs\)
    │   └── Scripts\
    │       ├── Env-Setup\           # 10-Sync-Content, 20-Check-Manufacturer, 30-Get-Hostname
    │       ├── OS-Build\            # 10-Initialize-Disk, 20-Apply-Image, 30-Driver-Injection,
    │       │                        # 40-Write-HostnameUnattend, 50-Configure-RunOnce, 60-Defer-Updates
    │       └── Sys-Config\          # 10-Disable-FastBoot, 20-Cached-Creds-Notification,
    │                                # 30-Verbose-Logon, 40-Suppress-FirstLogon-StartMenu
    ├── OS\
    │   └── install.wim              # Not in repo — you capture it
    ├── Drivers\
    │   └── <Vendor>\<Model>\        # OEM driver packs, expanded
    ├── PostOS\
    │   ├── Desktop\Join Domain.cmd  # Static launcher — copied to the desktop at first logon
    │   ├── Scripts\                 # Join-Domain.ps1, FirstLogon.cmd (RunOnce target)
    │   └── PSADT\                   # (planned)
    └── Logs\                        # Deploy transcripts
```

**Adding a hardware model:** drop the extracted driver pack at `Drivers\<Vendor>\<Model>\` — detection and injection find it by WMI at deploy time, no code changes. Unsupported models warn and continue.

---

## Deployment Flow

1. **Boot the USB** → WinPE runs `Start-Deployment.ps1`: hardware check, hostname prompt, partition, apply WIM, inject drivers, write the deploy-time unattend, stage post-OS content, defer updates → reboot. Full transcript lands in `Logs\` on the USB.
2. **Boot 1** — fully silent: specialize runs, no OOBE pages, a single one-time auto-logon sets the password-change flags and the machine self-reboots (~1 min).
3. **Boot 2** — the machine boots on its own to Windows' **native forced password-change screen**. The first thing the engineer touches is defining the local admin password.
4. **Desktop** — a **Join Domain** icon is waiting. When ready, it prompts for domain credentials and joins (offering to reuse an existing AD computer account if this hostname was deployed before), cleans up all deploy artifacts including itself, and reboots domain-joined. A failed join changes nothing — re-run the icon to retry.

### Local admin password model

Only the **built-in Administrator** is used — no second local account ever exists, so there is nothing unmanaged to find or clean up. The account is enabled blank by the deploy-time unattend and force-changed through Windows' own secure UI before the engineer controls anything else, so every machine gets a unique, engineer-defined password with no cleartext anywhere. On a successful join the account is returned to default password settings and routine post-OS maintenance takes over its management; if a machine somehow reaches a successful join still blank, a random throwaway password is applied as a backstop.

---

## Reference Image Capture

`CAPTURE-GUIDE.md` walks the full workflow for producing an `install.wim` if you don't already have one: clean Windows 11 install on a throwaway VM, account cleanup, optional baseline settings, sysprep, and capture via the `Build-CaptureUSB.ps1` output. It ends with a gate-by-gate verification checklist for the first deployment of a new WIM.

---

## Extracting Boot Drivers from SCCM

The SCCM boot image contains validated boot drivers for the fleet. Extract them into an independently owned staging folder and inject into the DiagnosticOSD WinPE. Read-only against SCCM source.

```powershell
$SCCMBootWim = "\\<SiteServer>\SMS_<SiteCode>\osd\boot\x64\boot.wim"
$MountDir    = "C:\Temp\SCCMMount"
$DriverOut   = "C:\DiagOSD-Build\ExtractedBootDrivers"

New-Item -ItemType Directory -Path $MountDir, $DriverOut -Force

DISM /Mount-Image /ImageFile:"$SCCMBootWim" /Index:1 /MountDir:"$MountDir" /ReadOnly
DISM /Image:"$MountDir" /Export-Driver /Destination:"$DriverOut"
DISM /Unmount-Image /MountDir:"$MountDir" /Discard
```

`ExtractedBootDrivers` is a versioned artifact independent of SCCM. Re-extract when the SCCM boot image is updated for new hardware.

---

## USB Duplication Strategy

Initial USB production uses a `dd`-style full-disk image of the validated development USB, written via an existing SCCM task sequence pattern used for Linux thin client imaging. SCCM treats this as an opaque image write with no awareness of partition layout or content.

Incremental content updates (scripts, drivers, WIM) are handled by `10-Sync-Content.ps1` once enabled. Full re-imaging from the `dd` source is reserved for rebuilds or new drive stock.

---

## Known Constraints & Warnings

- **⚠ Build-box drive letters `F:` and `N:` must be free** when running either Build script — the USB partitioning assigns them by design. If another deployment/capture USB, an attached virtual disk, or a mapped drive holds either letter, diskpart fails mid-partition with *"The specified drive letter is not free to be assigned"* and leaves the stick half-built. Detach other deploy media / free the letters before building; recovery is just re-running after they're free.
- **`wmic` is removed on Windows 11 24H2+** — the first-logon commands use it. The PowerShell swap is documented in-line in `40-Write-HostnameUnattend.ps1` for when the reference image moves past 23H2.

---

## Repo and Licensing

- **License:** MIT — scripts and folder structure only
- **Placeholders:** `Example.Domain` (use DNS form for the real value), `OU=...,DC=Example,DC=Domain`, `\\DiagOSD-Build.Example.Domain\OSD-NTFS$`, `H1234567`
- **Excluded from repo (`.gitignore`):** WIM files, expanded driver packs, deploy transcripts, any file containing real environment values

---

*DiagnosticOSD is provided as-is under the MIT license. You are responsible for validating anything deployed in your environment.*
