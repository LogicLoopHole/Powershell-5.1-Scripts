LAN-Orchestra | ReadMe / Documentation

Overview

LAN-Orchestra is a lightweight deployment automation tool for Windows endpoints that orchestrates application installations remotely via PSAppDeployToolkit (PSADT).
The PSADT package itself is not inlcuded here, see PSADT's main site for additional documentation and binaries https://psappdeploytoolkit.com/
This tool is not affilated with PSADT or their team in any way, nor does it technically require it if you wish to customize this script to use invoke command directly.

Designed to:
    Operate within a local network (LAN).
    Connect remotely to target devices using PowerShell Remoting.
    Execute PSADT-based .exe installers pointing to centralized UNC scripts or app packages.
    Evaluate pre- and post-deployment detection to save redundant work or confirm success.
    Resume interrupted jobs using persistent tracking state.
    Capture key telemetry including exit codes and error messages.
    Log activities clearly with timestamps, status levels.

Directory Structure
UNC Source Package (App Folder)
\\exampleServer\Scripts\PSADT\Toolkit\
├── Files\                           ← Optional payload source files
├── SupportFiles\
│   └── Detection-Method.ps1          ← Custom detection logic
├── Deploy-Application.exe            ← Executed remotely on the target
└── Deploy-Application.ps1            ← PSADT core (edited with intended deployment)

Host Side Orchestration Folder
C:\Temp\LAN-Orchestra\
├── Functions\
│   └── Orchestrator-Helpers.ps1      ← Shared utility functions
├── Data\
│   └── Console-Output.log            ← Single rotating activity log
│   └── Tracking-DB.json              ← Per-device deployment state log
├── Deploy-Orchestrator.ps1           ← Main control entry script (install/uninstall)
├── Status-Update.ps1                 ← Read-only viewer using GridView
├── Target-Devices.txt                ← Line-delimited list of device hostnames/IPs


Deployment Workflow Overview
    Initialization & Load
        Load list of target devices from Target-Devices.txt
        Resume or initialize state via Tracking-DB.json
        Accept user parameter for UNC path to specific app package

    Availability Test Phase
        For each target:
            Ping (Test-Connection)
            WinRM connectivity check (Test-WSMan)

    Pre-Installation Detection
        For unknown/failure status hosts only:
            Remotely evaluates SupportFiles\Detection-Method.ps1
            If Pass, skips full installation (presumes manual install)

    Post-Check Evaluation
        Captures:
            Return code from Deploy-Application.exe
            Exit code from detection method
        Sets final result:
            "Pass" if both succeeded
            "Fail" otherwise

    Persistence
        Updates to Tracking-DB.json after every job completion

    Reporting
        Live progress indicators in GUI
        Detailed logs stored continuously to Console-Output.log
        Optional GridView visualization via StatusUpdate.ps1

Tracking JSON Format (Sample Entry)
{
  "PC001": {
    "Hostname": "PC001",
    "ComputerStatus": "Online",
    "JobStatus": "Completed",
    "SentTimestamp": "2025-09-03T12:30:00Z",
    "ReceivedTimestamp": "2025-09-03T12:33:21Z",
    "AttemptCount": 1,
    "ExitCode": 0,
    "PreDeployDetect": "Fail",
    "PostDeployDetect": "Pass",
    "DetectionResult": "Pass",
    "LastErrorDetail": ""
  }
}

Fields:
Key	Description
ComputerStatus	Unknown, Offline, WinRM Issue, Slow Network, or Online
JobStatus	Queued, Sent, Completed, or Failed
ExitCode	Value returned by Deploy-Application.exe
PreDeployDetect / PostDeployDetect	Pass, Fail, Unknown
LastErrorDetail	Captured exception or stderr message (kept last in schema for viewing)

Logging Format
Log written to Console-Output.log
YYYY-MM-DD HH:MM:SS.ms LEVEL HOSTNAME MESSAGE
Example:
2025-09-03 12:30:15.123 INFO PC001 Starting deployment...
2025-09-03 12:35:02.789 ERROR PC001 Access denied during deployment
Also rendered with color-coded output for console readers:
Write-Warning "Slow connection detected"
Write-Error "Deployment failed"

Optional Features
    Resume previous deployment runs by rerunning script which limits to failed/non-compliant checks
    GridView display for live reporting (via StatusUpdate.ps1)
    Configurable concurrency throttle

Requirements
Dependency	Version / Notes
PowerShell	v5.1+ (Windows PowerShell, not PSCore)
OS Support	Target Windows client with PowerShell remoting enabled

Permissions	Admin-level access to targets and UNC shares
