# PSLanDeploy

PSLanDeploy pushes an application to Windows workstations across a LAN and installs it on each one
as SYSTEM, using [PSAppDeployToolkit](https://psappdeploytoolkit.com/) (PSADT) packages. It runs
from a single deployment server, keeps per-device state so interrupted runs pick up where they left
off, and skips machines that are offline, non-client, or already in the desired state.

PSADT itself is not included. See the PSADT site for binaries and documentation. This project is not
affiliated with PSADT.

## How it works

Targets are processed one at a time. For each host:

1. Skip it unless it's a reachable workstation.
2. Run the detection script over PowerShell Remoting; if the host already matches the desired state, do nothing.
3. Stage the package to the client. A slow or busy machine is skipped and retried on a later run.
4. Create a scheduled task that installs (or uninstalls) as SYSTEM, then cleans up after itself.

Re-run the script periodically; detection confirms the result on the next pass.

## Requirements

| Dependency | Notes |
|---|---|
| PowerShell | 5.1+ (Windows PowerShell) on the deployment server |
| Targets | Windows workstations with PowerShell Remoting (WinRM) enabled |
| Transport | WinRM + SMB admin share (`C$`), server to client |
| Permissions | Run as a domain account that is local admin on the targets |
| PSADT | v4.x package, referenced by `-UNCAppDir` |

## Directory structure

Source package  (UNC share, passed as `-UNCAppDir`)

```
\\server\share\MyApp\
├── Files\                        ← payload source files (can be large)
├── SupportFiles\
│   └── Detection-Method.ps1      ← detection logic (exit 0 = present, 1 = absent)
├── Invoke-AppDeployToolkit.exe   ← PSADT executable
├── install_silent.cmd            ← runs PSADT Install
└── uninstall_silent.cmd          ← runs PSADT Uninstall
```

Orchestrator  (on the deployment server)

```
...\PSLanDeploy\
├── Functions\
│   ├── Func-Helpers.ps1          ← status checks, staging, shared utilities
│   ├── Func-ScheduledTasks.ps1   ← scheduled task create / cleanup
│   └── Func-StateManagement.ps1  ← tracking DB load / save
├── Data\                         ← Console-Output.log + Tracking-DB.json (auto-created)
├── Examples\                     ← sample detection method + silent .cmd wrappers
├── Start-PSLanDeploy.ps1         ← main entry (Install / Uninstall)
├── Show-DeploymentReport.ps1     ← read-only status viewer
└── Target-Devices.txt            ← one hostname per line
```

Each target stages the package under `C:\Program Files\PSLanDeploy` and runs it there as SYSTEM.

## Status

Activity is logged to `Data\Console-Output.log` and per-device state to `Data\Tracking-DB.json`.
`Show-DeploymentReport.ps1` opens that state in a sortable grid. It's read-only and safe to run while
a deployment is in progress.
