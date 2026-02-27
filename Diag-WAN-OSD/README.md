# Diag-WAN-OSD

A WAN-capable Windows diagnostic imaging tool built on top of [OSDCloud](https://www.osdcloud.com). An alternative to [DiagnosticOSD](../DiagnosticOSD) for environments where internet access is available during imaging.

## Credits

- **OSD PowerShell Module** — [github.com/OSDeploy/OSD](https://github.com/OSDeploy/OSD) (GPL v3)
- **OSDCloud Module** — [github.com/OSDeploy/OSDCloud](https://github.com/OSDeploy/OSDCloud)
- **OSDCloud Documentation** — [osdcloud.com](https://www.osdcloud.com)
- **Recast Software** — [recastsoftware.com](https://www.recastsoftware.com/)

If your environment is cloud-native (Entra ID / Autopilot), use OSDCloud as designed. Diag-WAN-OSD is for environments where WAN is available but a controlled, repeatable diagnostic image is still needed.

> Validated against OSD module version **26.1.28.3** (February 2026). To check your installed version: `(Get-Module OSD -ListAvailable).Version`

---

## What This Is

A lightweight script set that layers on top of OSDCloud to deploy a branded diagnostic image over WAN. Unlike DiagnosticOSD, there is no custom WIM or pre-staged driver pack — OSDCloud downloads the OS and drivers natively. The customization is in the post-install configuration: OOBE bypass, local admin account, update deferral, and feature update pinning to a known version.

Current use case is the same as DiagnosticOSD — isolate whether an issue is client-side or server-side (MDT, SCCM, Intune, etc.) — but suited for environments where WAN is allowed during imaging.

**Status:** Beta. Side effort, maintained when time allows.

> **Disclaimer:** Provided as-is under the MIT license. Validate anything you deploy in your environment.

---

## How It Differs from DiagnosticOSD

| | DiagnosticOSD (USB) | Diag-WAN-OSD |
|---|---|---|
| Media | USB/SSD | ISO |
| OS source | Pre-staged WIM | Downloaded via OSDCloud |
| Drivers | Pre-staged OEM packs | Downloaded via CloudDriver |
| Domain join | Yes (on-prem AD) | No |
| Network required | LAN only | WAN |
| Update control | Offline registry | Policy registry + pin |

---

## Prerequisites

Same build machine requirements as DiagnosticOSD. See the [DiagnosticOSD README](../DiagnosticOSD/README.md) for the full prerequisite walkthrough including PowerShell 5.1 configuration, software installs, and OSD module installation.

---

## Quick Start

### 1. Clone the Repo

```powershell
git clone https://github.com/LogicLoopHole/Powershell-5.1-Scripts.git C:\Powershell-5.1-Scripts
cd C:\Powershell-5.1-Scripts\Diag-WAN-OSD
```

### 2. Create OSDCloud Workspace and ISO

```powershell
New-OSDCloudTemplate -WinRE
New-OSDCloudWorkspace -WorkspacePath "C:\OSD-WS-TST1"
Set-OSDCloudWorkspace -WorkspacePath "C:\OSD-WS-TST1"

Edit-OSDCloudWinPE -CloudDriver IntelNet,LenovoDock,USB,VMware,WiFi `
    -StartOSDCloudGUI `
    -UseDefaultWallpaper `
    -Brand 'TESTING - User Stability Breakfix Tool - Diag-WAN-OSD'

New-OSDCloudISO
```

### 3. Copy Scripts to Workspace

Copy the contents of `Config\` to `C:\OSD-WS-TST1\Media\OSDCloud\Config\`

### 4. Rebuild ISO

```powershell
New-OSDCloudISO
```

Boot the target machine from the ISO. OSDCloud GUI will prompt for OS selection, then image and configure the machine.

---

## Deployment Flow

1. Boot from ISO
2. WinRE initializes, prompts for WiFi if no ethernet
3. StartNet scripts run — hostname prompt
4. OSDCloud GUI — select OS, OSDCloud downloads and images
5. Shutdown scripts run in numbered order:
   - `01-Write-HostnameUnattend.ps1` — writes hostname to unattend
   - `02-Configure-FirstLogon.ps1` — OOBE bypass, local admin, AutoLogon, password change
   - `03-Defer-Updates.ps1` — disables automatic updates via policy registry (offline)
   - `04-Pin-FeatureUpdate.ps1` — pins Windows to current feature version (offline)
6. Machine reboots into Windows
7. AutoLogon fires, power timeouts disabled, password change enforced at lock screen

---

## Post-Install State

- Local admin account `osdadmin` with no password, AutoLogon fires once
- User is immediately prompted to set a password before the desktop is usable
- Windows Update disabled via policy key — self-cleans when GPO/Intune takes over
- Feature update pinned to installed version — prevents OSD from upgrading (e.g., 24H2 to 25H2) during or after OOBE
- No domain join — standalone workgroup machine
- No network at first boot (WiFi from WinRE does not carry over) — prevents background update activity

---

## Gotchas

### WinRE WiFi Does Not Carry Over

The WiFi connection established during WinRE does not persist to the deployed OS. The machine boots with no network. This is intentional — it prevents Windows Update from running in the background at first login. The user can connect manually when ready.

### WinRE ASCII-Only Scripts

Any script that runs in WinRE (StartNet or Shutdown) must use plain ASCII characters. Em dashes, smart quotes, and other non-ASCII characters cause cryptic parse errors. Use standard hyphens in comments and strings.

### PSGallery Outages

If `Edit-OSDCloudWinPE` fails with `End of Central Directory record could not be found`, PSGallery is down. Use `-PSModuleCopy OSD` to bundle the local module instead:

```powershell
Edit-OSDCloudWinPE -PSModuleCopy OSD -CloudDriver IntelNet,LenovoDock,USB,VMware,WiFi ...
```

---

## License

MIT — applies to the scripts in this repository only.

OSDCloud and the OSD PowerShell module are separate projects maintained by [OSDeploy](https://github.com/OSDeploy) under the [GPL v3 license](https://github.com/OSDeploy/OSDCloud/blob/main/LICENSE). Diag-WAN-OSD depends on them but does not include or redistribute their code.
