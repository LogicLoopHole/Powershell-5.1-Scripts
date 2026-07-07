# DiagnosticOSD — Reference VM Capture Guide

Building a deployable `install.wim` from a clean Windows 11 install on a throwaway VM. Run once per WIM build; re-do only when the reference image needs updating.

Tested with Windows 11 Enterprise 23H2.

> **Account note:** deployed machines get the built-in Administrator **enabled with a blank password via the deploy-time unattend** (`40-Write-HostnameUnattend.ps1`), and the account is renamed + LAPS-managed after domain join. The Administrator *password* you set in step 2 is **only for building the reference image** — it's wiped by generalize and never reaches a deployed machine (the deploy unattend enables the account blank). **Nothing password-related is set on the reference VM anymore.** The forced-password-change flags are set at deploy time by the unattend's `FirstLogonCommands` (in the first logon session, then a self-reboot → change screen on boot 2). They deliberately do NOT ride in the WIM: the deploy unattend's own blank-password write at first boot clears any pre-baked must-change bit — proven on the 7/2/2026 deploy, where the WIM-baked expiry survived generalize but the change screen never appeared.

---

## 1. Install Windows on the reference VM

**Before booting:** disconnect the VM's network adapter (uncheck "Connected" / "Connect at Power On"). Forces OOBE down the local path, avoids surprise Windows Update activity, and skips network OOBE pages.

Boot from the ISO and start Setup.

**Windows 11 compatibility bypass (VM without TPM 2.0 / Secure Boot):** at the "This PC can't run Windows 11" screen, `Shift+F10` for cmd, then:

```
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f
```

Close cmd. If the Setup back arrow isn't shown, click the **X** top-right to return to Setup's start screen, then **Install now** again. These keys live only in the Setup-time WinPE RAM hive — they aren't carried into the installed OS or the captured WIM.

**OOBE:** region/keyboard yours; network should skip with the NIC disabled; at "Who's going to use this device?" enter a throwaway name (e.g. `setupuser`, deleted in step 2); password anything; decline privacy / 365 / pin-to-start.

---

## 2. Enable Administrator and delete the throwaway account

Elevated cmd. Activate the built-in Administrator (password here is **build-time only**):

```
net user Administrator YourBuildPassword /active:yes
```

(Substitute any value for `YourBuildPassword` - no angle brackets, cmd treats `<`/`>` as
redirection. This password exists only to sign in on the reference VM: generalize disables
the account and wipes it, and the deploy unattend re-enables it **blank** at first boot -
it is overwritten by design, never in conflict, and never reaches a deployed machine.)

Sign out of the throwaway, sign in as `Administrator`. Delete the throwaway **profile** via GUI (more complete than `rmdir` — it removes the `ProfileList` registry entries too):

1. `Win+R` → `sysdm.cpl` → **Advanced** → **User Profiles** → **Settings**
2. Select the throwaway profile → **Delete** → confirm

Then delete the account and verify only built-in stubs remain:

```
net user <throwaway-name> /delete
net user
```

Expected: `Administrator`, `DefaultAccount`, `Guest`, `WDAGUtilityAccount`. Nothing else.

---

## 3. Configure baseline (optional)

Anything consistent on every deployed machine that doesn't belong in a deploy-side script: regional/locale/time zone, org privacy defaults, removing consumer apps, Start pins, Windows features. Keep it minimal — the more you bake in, the more often you rebuild.

---

## 4. Power settings (optional)

Suppress sleep/hibernate/screen-off on every deployed machine — the active scheme persists through sysprep into the WIM, so this is the right place for it (no deploy-side script, no first-boot timing risk). Run as Administrator:

```
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /hibernate off
```

Screensaver off for the Administrator profile (other profiles are handled at deploy time by `40-Suppress-FirstLogon-StartMenu.ps1`):

```
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f
```

Verify with `powercfg /query` (Sleep after / Turn off display after both zero on the active scheme).

---

## 5. Sysprep

Elevated cmd as Administrator:

```
%SystemRoot%\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

- `/generalize` — strips SID, hardware drivers, activation, profile state, event logs (and disables the built-in Administrator — the deploy-time unattend re-enables it via AutoLogon).
- `/oobe` — next boot runs the specialize pass, then OOBE. Our `Panther\Unattend.xml` skips the OOBE pages, enables the built-in blank, and its `FirstLogonCommands` set the change flags + self-reboot; boot 2 lands on the forced-change screen. **No audit mode.**
- `/shutdown` — powers off after sysprep completes.

> ⚠️ **Do not boot the reference VM again after sysprep completes** — booting consumes the sysprep state. If you do, re-run sysprep before capturing.

---

## 6. Capture

Boot the (shut-down) reference VM from your `Build-CaptureUSB.ps1` output. The baked-in capture script runs automatically: finds the DeployData partition, finds the Windows partition by `ntoskrnl.exe`, captures to `install.wim`, prompts before overwriting an existing WIM. ~5–15 minutes.

---

## 7. Stage

Copy `install.wim` from the capture USB to the deployment USB at `OS\install.wim`, replacing the existing WIM.

---

## Quick verification (first deployment with the new WIM)

The two-boot flow, gate by gate:

- **Boot 1: auto-signs-in as Administrator** (unattend AutoLogon, count=2) — no audit-mode desktop, no sysprep dialog, no OOBE pages to click. **The desktop appears briefly, then the machine self-reboots within ~1 minute** — that's `FirstLogonCommands` setting the change flags and issuing `shutdown /r /t 10`. Don't interfere. *(If boot 1 does NOT self-reboot and you sit at a stable desktop, FLC didn't fire: check the FLC block reached the answer file — `type C:\Windows\Panther\unattend.xml` — and `C:\Windows\Panther\UnattendGC\setupact.log`. Fix the USB copy of 40, redeploy — **no recapture needed**.)*
- **No account-creation screen.** *(Suppressed by the `<AutoLogon>` block in `40-Write-HostnameUnattend.ps1` — hide flags alone cannot suppress this page on client SKUs. If it reappears, that block is missing or the answer file wasn't consumed: check `setupact.log`, fix the USB copy of 40, redeploy — no recapture needed.)*
- **Boot 2 — THE KEY CHECK:** the logon attempt hits the must-change flag and lands on Windows' **native forced-change screen** ("The user's password must be changed before signing in"). Set a password there (old password blank). *(**Observe, don't assume:** whether boot 2's automatic logon surfaces this prompt directly or falls to the sign-in tile first — where clicking Administrator with blank brings it up, one click away — is undocumented. Both are a pass; record which happened. The mechanism itself is proven: the same flags + reboot produced this screen manually on a deployed box, 7/2/2026.)*
- After setting the password, you reach the **Administrator desktop**.
- `whoami` returns `Administrator` (not `setupuser`).
- The hostname from `30-Get-Hostname` is what `hostname` reports.
- **"Join Domain.cmd" is on the desktop** (staged to Public\Desktop — the path proven across builds; Join-Domain deletes it on a successful join). It does NOT auto-run — double-click it when ready; it asks "Join now?", prompts for domain credentials, joins, resets expiry to Never, removes the launcher, and reboots. Re-run it to retry.
- Reboot freely before joining — every pre-join boot is a normal sign-in with the password you set (AutoLogon is spent), which is the intended troubleshooting access.

Most common failure cause if the box lands somewhere unexpected: sysprep was skipped, or the VM was booted after sysprep completed (consuming the state). For the password flow specifically, the failure classes are separable: no self-reboot on boot 1 = FLC didn't run (answer file); self-reboot happened but no change prompt on boot 2 = flag didn't stick (pull `net user Administrator` and `C:\Windows\Panther\UnattendGC\*.log` before touching anything).
