# DiagnosticOSD

A bandwidth-conscious, validated Windows diagnostic imaging tool built on top of [OSDCloud](https://www.osdcloud.com).

## Credits

This effort builds on the shoulders of the OSDCloud community:

- **OSD PowerShell Module** — [github.com/OSDeploy/OSD](https://github.com/OSDeploy/OSD) (GPL v3)
- **OSDCloud Module** — [github.com/OSDeploy/OSDCloud](https://github.com/OSDeploy/OSDCloud)
- **OSDCloud Documentation** — [osdcloud.com](https://www.osdcloud.com)
- **Recast Software** — [recastsoftware.com](https://www.recastsoftware.com/)

If your environment is cloud-native (Entra ID / Autopilot without on-prem AD dependencies), use OSDCloud as designed — it handles that use case natively. DiagnosticOSD primarily exists for environments where a cloud-native approach isn't viable.

### Design Inspiration

Recast Software's own [OSDCloud with ConfigMgr overview](https://www.recastsoftware.com/resources/osd-cloud-with-configmgr/) identifies two key trade-offs with cloud-based OSD: the requirement for internet access and significant bandwidth, and reduced control over what gets applied — making regression testing and change management difficult when core components are vendor-controlled. DiagnosticOSD was designed specifically to address these gaps.

> Validated against OSD module version **26.1.28.3** (February 2026). To check your installed version: `(Get-Module OSD -ListAvailable).Version`

---

## What This Is

A set of scripts and a folder structure pattern that layers on top of OSDCloud to provide validated, bandwidth-reduced Windows deployment from a USB drive (or SSD). You bring your own WIM and your own drivers — the OS and drivers are pre-staged on the media rather than downloaded during imaging.

The current use case is a **diagnostic tool** to help identify whether an issue exists client-side or server-side (MDT, SCCM, Intune, etc.) by deploying a known-good image with tested drivers, allowing you to isolate variables during troubleshooting.

This was built to fill a gap: MDT is no longer available for download, SCCM/MECM is aging, and Autopilot expects your OEM to handle bare metal provisioning — which in practice means bloatware, vendor-specific issues, and inconsistencies across models.

**Status:** Beta. This is a side effort maintained by one person when time allows.

> **⚠️ Disclaimer:** This is provided as-is under the MIT license. Use at your own risk — you are responsible for validating anything you deploy in your environment.

---

## Features

- **Bandwidth-reduced imaging** — WIM, drivers, and scripts are pre-staged on the USB. The only LAN activity during deployment is an optional content sync and domain join.
- **Validated drivers** — expanded OEM driver packs in dedicated folders, tested before deployment. You know what you're deploying.
- **Multi-model support** — per-model driver folders under `Custom\OfflineDrivers\<Vendor>\<Model>\`, validated at boot before imaging starts. Initial testing puts 30 models at roughly 100 GB, so an external SSD may be more practical than a USB flash drive at scale (both work — SSD is faster).
- **Model validation** — StartNet script checks for a matching driver folder before proceeding. Unsupported hardware gets a clear error, not a half-built image.
- **Unattended OOBE** — hostname prompt during WinRE, then hands-off through OOBE, AutoLogon, and domain join.
- **On-prem AD join** — credential prompt at first logon, joins legacy Active Directory domain.
- **OSDCloud-native integration** — uses `Automate\Startup\`, `Config\Scripts\StartNet\`, and `Config\Scripts\Shutdown\` paths that OSDCloud scans natively.

---

## Architecture

The USB/SSD has two partitions created by `New-OSDCloudUSB`. All custom content currently lives on the NTFS data partition:

```
USB / SSD
├── [NTFS — "OSDCloudUSB"] ─────────────────────────
│   ├── Custom\                          # Our content (OSDCloud ignores this)
│   │   ├── MinBootDrivers\              # WinRE boot drivers (injected at build time)
│   │   ├── OfflineDrivers\              # Post-install drivers applied via DISM
│   │   │   └── <Vendor>\<Model>\        # One folder per supported hardware model
│   │   └── Join-Domain.ps1              # AD join script (runs at first logon)
│   │
│   └── OSDCloud\                        # OSDCloud-native paths (auto-scanned)
│       ├── Automate\Startup\            # Runs inside OSDCloud engine process
│       │   └── Set-DriverPackNone.ps1
│       ├── Config\Scripts\
│       │   ├── StartNet\                # Pre-imaging scripts (model check, sync, hostname)
│       │   └── Shutdown\                # Post-imaging scripts (drivers, unattend, domain)
│       └── OS\
│           └── <your-wim-file>.wim      # Not included — bring your own
│
└── [FAT32 — "WinPE"] ──────────────────────────────
    └── (WinRE boot files, managed by OSDCloud)
```

The `Custom\` vs `OSDCloud\` separation is intentional. OSDCloud natively scans `OSDCloud\` paths on all drives — our scripts hook into that. `Custom\` is for content OSDCloud doesn't know about, referenced only by our own scripts.

---

## Prerequisites

**Reference:** [OSD.Workspace Wiki — Recommended Client Configuration](https://github.com/OSDeploy/OSD.Workspace/wiki#recommended-client-configuration)

> **Important:** OSDCloud build machine must run **Windows 11 24H2** with matching **24H2 ADK** (10.1.26100.2454). Older Windows WIMs can still be deployed. All commands must be run as Administrator.

### Windows PowerShell 5.1 Configuration

*Reference: [Windows PowerShell 5.1 Wiki](https://github.com/OSDeploy/OSD.Workspace/wiki/Windows-PowerShell-5.1)*

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

if ($(Get-PackageProvider).Name -notcontains 'NuGet') {
    Install-PackageProvider -Name NuGet -Force -Verbose
}

if ((Get-PSRepository -Name 'PSGallery').InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Write-Host "PowerShell Gallery (PSGallery) has been set to Trusted."
} else {
    Write-Host "PowerShell Gallery (PSGallery) is already Trusted."
}

Install-Module -Name PowerShellGet -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -Verbose
Install-Module -Name PackageManagement -Force -Scope AllUsers -AllowClobber -SkipPublisherCheck -Verbose
```

### Additional Software

| Component     | Wiki Method | What I Did Instead                                                                                  |
| ------------- | ----------- | --------------------------------------------------------------------------------------------------- |
| PowerShell 7  | winget      | **MSI installer** (`PowerShell-7.5.4-win-x64.msi`) — winget broken. Check all boxes during install. |
| Git + VS Code | winget      | **Ninite** — bypasses winget user ID prompt                                                         |
| Windows ADK   | PowerShell  | **GUI installer** — PowerShell install doesn't work, uncheck all except Deployment Tools            |
| MDT           | Listed      | **Not installed** — not required                                                                    |
| Hyper-V       | Listed      | **Not installed** — not required                                                                    |

### OSD PowerShell Modules (Run in PowerShell 7 as Admin)

*Reference: [OSD PowerShell Modules Wiki](https://github.com/OSDeploy/OSD.Workspace/wiki/OSD-PowerShell-Modules)*

```powershell
Install-Module -Name OSD.Workspace -SkipPublisherCheck
Install-Module -Name platyPS -SkipPublisherCheck
Install-Module -Name OSD -SkipPublisherCheck
Install-Module -Name OSDCloud -SkipPublisherCheck
```

---

## Quick Start

### 1. Get the Template

Clone the repo and use the `DiagnosticOSD` folder as your starting template:

```powershell
git clone https://github.com/LogicLoopHole/Powershell-5.1-Scripts.git
cd Powershell-5.1-Scripts\DiagnosticOSD
```

Copy the `DiagnosticOSD` folder to your build machine (e.g., `C:\DiagnosticOSD`). The folder structure is your template:

```
C:\DiagnosticOSD\
├── OSD-NTFS\          (USB content — customize scripts, add your drivers + WIM)
└── OSD-WS-TST1\       (created by OSDCloud workspace commands below)
```

### 2. Add Your Content (Not Included in Repo)

- Place your custom WIM in `OSD-NTFS\OSDCloud\OS\`
- Place expanded OEM driver packs in `OSD-NTFS\Custom\OfflineDrivers\<Vendor>\<Model>\`
- Place WinRE boot drivers (if needed) in `OSD-NTFS\Custom\MinBootDrivers\`

### 3. Create OSDCloud Workspace and USB

```powershell
# One-time workspace setup
New-OSDCloudTemplate -WinRE
New-OSDCloudWorkspace -WorkspacePath "C:\DiagnosticOSD\OSD-WS-TST1"

# Build WinRE and create USB (wipe USB first!)
Set-OSDCloudWorkspace -WorkspacePath "C:\DiagnosticOSD\OSD-WS-TST1"
Edit-OSDCloudWinPE -DriverPath 'C:\DiagnosticOSD\OSD-NTFS\Custom\MinBootDrivers' `
    -StartOSDCloud "-ZTI -FindImageFile -Restart"
New-OSDCloudUSB

# Copy custom content to USB NTFS partition
# Copy entire OSD-NTFS\* to the OSDCloudUSB NTFS volume root

# Sync WinRE modules (run last)
Update-OSDCloudUSB
```

### 4. Deploy

Boot target machine from USB → follow prompts → machine images, installs drivers, joins domain.

### Important Warnings

- `New-OSDCloudUSB` is **additive only** — always wipe/delete USB partitions before recreating
- `Custom\`, `Automate\`, and `OS\` must be copied manually to the USB — `New-OSDCloudUSB` does not copy these
- `Update-OSDCloudUSB` (without parameters) syncs the WinRE boot partition and offline PowerShell modules — run this last

---

## Adding a New Hardware Model

1. Download the OEM SCCM driver pack for your model
2. Extract/expand it
3. Create the folder: `Custom\OfflineDrivers\<Vendor>\<Model>\`
4. Copy the expanded driver folders into it

The model folder name must match what WMI reports. For Lenovo, this is `Win32_ComputerSystemProduct.Version` (e.g., "ThinkPad T14s Gen 3"), not the product code. For Microsoft Surface and other vendors, check `Win32_ComputerSystemProduct.Name`. Run this on the target hardware to find out:

```powershell
Get-CimInstance Win32_ComputerSystemProduct | Select-Object Vendor, Name, Version
```

**Lenovo driver packs:** The [Lenovo Recipe Card](https://download.lenovo.com/cdrt/ddrc/RecipeCardWeb.html) is useful for looking up models and finding links to SCCM driver packs.

---

## Gotchas

These are things learned the hard way. If you're building on OSDCloud, they may save you time.

### StartNet Scripts Run in a Separate Process

Scripts in `OSDCloud\Config\Scripts\StartNet\` are executed in a **separate PowerShell process** from `Start-OSDCloud`. Global variables set in StartNet scripts are not visible to the OSDCloud engine. If you need to set `$Global:OSDCloud` variables (like `DriverPackName`), use `OSDCloud\Automate\Startup\` instead — those scripts run inside the `Invoke-OSDCloud` process.

### Lenovo WMI Model Names

Lenovo uses `Win32_ComputerSystemProduct.Version` for the human-readable model name. Every other property (`Name`, `Model` on `Win32_ComputerSystem`) returns the internal product code (e.g., "21BSS1H900"). If your driver folder matching isn't working on Lenovo, this is probably why.

### New-OSDCloudUSB Is Additive Only

`New-OSDCloudUSB` adds files but never removes them. Always wipe/delete USB partitions before recreating. Otherwise old content accumulates.

### PSGallery Outages

If `Edit-OSDCloudWinPE` fails with `End of Central Directory record could not be found`, PSGallery is having issues. Use `-PSModuleCopy OSD` to bundle the locally installed module instead:

```powershell
Edit-OSDCloudWinPE -PSModuleCopy OSD -DriverPath '...' -StartOSDCloud "..."
```

---

## Deployment Flow

1. Boot from USB/SSD
2. WinRE initializes, prompts for WiFi if no ethernet
3. StartNet scripts run in numbered order (model check → content sync → hostname prompt)
4. OSDCloud images the WIM to disk
5. Shutdown scripts run in numbered order (driver injection → hostname unattend → first logon config)
6. Machine reboots into Windows → AutoLogon → domain join → restart

---

## Known Limitations

- `-FindImageFile` prompts for WIM selection even with `-ZTI` ([OSD #287](https://github.com/OSDeploy/OSD/issues/287)). Minor with a single WIM but not true zero-touch.
- Tested on Lenovo ThinkPad hardware with on-prem Active Directory. Limited testing in virtual machines (XCP-ng / VMware). Other vendors should work with the correct WMI property for model name but are untested.
- For cloud-native environments (Entra ID / Autopilot), use [OSDCloud natively](https://www.osdcloud.com) — it is designed for that use case.

---

## License

MIT — applies to the scripts and folder structure in this repository only.

OSDCloud and the OSD PowerShell module are separate projects maintained by [OSDeploy](https://github.com/OSDeploy) under the [GPL v3 license](https://github.com/OSDeploy/OSDCloud/blob/main/LICENSE). DiagnosticOSD depends on them but does not include or redistribute their code.
