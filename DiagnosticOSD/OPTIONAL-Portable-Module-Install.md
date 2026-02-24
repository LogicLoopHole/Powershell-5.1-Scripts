# Portable Module Installation

When PSGallery is unavailable, all required PowerShell modules can be installed directly from GitHub. The entire PS 5.1 configuration section in the README can be skipped except for the execution policy.

## Prerequisites Already Available

- PowerShell 7 MSI (install first, check all boxes)
- Windows ADK GUI installer

## Download Modules from GitHub

On each repo page, click Code > Download ZIP:

- OSD: https://github.com/OSDeploy/OSD
- OSDCloud: https://github.com/OSDeploy/OSDCloud
- OSD.Workspace: https://github.com/OSDeploy/OSD.Workspace
- platyPS: https://github.com/PowerShell/platyPS

## Install

1. Set execution policy in PowerShell 5.1 (Admin):

   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

2. Extract each ZIP to a temp location (e.g., C:\Temp\Modules)

3. Rename each extracted folder to match the module name exactly:

   OSD-master -> OSD
   OSDCloud-main -> OSDCloud
   OSD.Workspace-main -> OSD.Workspace
   platyPS-main -> platyPS

4. Move all four folders to: C:\Program Files\PowerShell\Modules\

## Verify

Run in PowerShell 7 as Admin:

   Get-Module -Name OSD, OSDCloud, OSD.Workspace, platyPS -ListAvailable

All four modules should appear with version numbers. If any are missing, verify the folder names match exactly.

## Quick Test

   Set-OSDCloudWorkspace -WorkspacePath "C:\DiagnosticOSD\OSD-WS-TST1"

If this runs without module-not-found errors, the portable install worked.
