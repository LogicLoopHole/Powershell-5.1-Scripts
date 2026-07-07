#
# The MIT License (MIT)
#
# Copyright (c) 2026 LogicLoopHole
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# The MIT License (MIT)
#
# Copyright (c) 2026 LogicLoopHole
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

#

# Start-Deployment.ps1
# Orchestrator - called by X:\Deploy\Launch.ps1 after WinPE locates DeployData volume.
# Runs the contents of each Scripts subfolder in filename sort order.
# Add, remove, or reorder scripts on the USB without touching this file.
# Inter-script state is passed via X:\Deploy\DeployState.txt (drives) and X:\Deploy\Hardware.txt (model info).
#
# A transcript of every run is written to <USB>:\Logs\ - WinPE's X: is a ramdisk, so
# anything not written to the USB vanishes at reboot. When a deploy fails mid-flight,
# read the transcript before theorizing.

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

if (-not $DeployDrive) {
    $DeployDrive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
}
if (-not $DeployDrive) { throw "DeployData volume not found." }

# Persistent transcript on the USB (survives reboot, unlike X:)
$LogDir = "${DeployDrive}:\Logs"
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$LogFile = Join-Path $LogDir ("Deploy_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogFile -ErrorAction SilentlyContinue | Out-Null

$ScriptsRoot = "${DeployDrive}:\Deploy\Scripts"
$Folders     = @("Env-Setup", "OS-Build", "Sys-Config")

function Read-State {
    $StateFile = "X:\Deploy\DeployState.txt"
    if (Test-Path $StateFile) {
        Get-Content $StateFile | ForEach-Object {
            if ($_ -match '^(\w+)=(.+)$') {
                Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
            }
        }
    }
}

function Invoke-Folder {
    param([string]$FolderPath)

    $Scripts = Get-ChildItem -Path $FolderPath -Filter "*.ps1" -ErrorAction SilentlyContinue |
               Sort-Object Name

    if (-not $Scripts) {
        Write-Host "No scripts found in $FolderPath - skipping."
        return
    }

    foreach ($Script in $Scripts) {
        & $Script.FullName
        Read-State
    }
}

try {
    Write-Host "`n=== DiagnosticOSD Deployment ===" -ForegroundColor Cyan
    Write-Host "Deploy drive : ${DeployDrive}:"
    Write-Host "Transcript   : $LogFile"

    foreach ($Folder in $Folders) {
        $FolderPath = Join-Path $ScriptsRoot $Folder
        if (-not (Test-Path $FolderPath)) {
            throw "Expected scripts folder not found: $FolderPath"
        }
        Write-Host "`n=== $Folder ===" -ForegroundColor Cyan
        Invoke-Folder -FolderPath $FolderPath
        Read-State
    }

    Write-Host "`nRemove USB and press Enter to reboot."
    pause
}
finally {
    # Runs on success AND on a thrown error, so the transcript is always flushed
    # to the USB before the console (and X:) disappears.
    try { Stop-Transcript | Out-Null } catch { }
}

Restart-Computer -Force
