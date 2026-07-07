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

# 20-Apply-Image.ps1
# OS-Build - Applies the WIM image and writes boot configuration.
# Reads $OSDrive and $EFIDrive from X:\Deploy\DeployState.txt.

Write-Host "`n=== Apply Image ===" -ForegroundColor Cyan

# Read drive assignments from state file
$StateFile = "X:\Deploy\DeployState.txt"
if (-not (Test-Path $StateFile)) {
    Write-Warning "DeployState.txt not found at $StateFile. Ensure 10-Initialize-Disk.ps1 completed."
    pause
    return
}

Get-Content $StateFile | ForEach-Object {
    if ($_ -match '^(\w+)=(.+)$') { Set-Variable -Name $Matches[1] -Value $Matches[2] }
}

if (-not $OSDrive -or -not $EFIDrive) { throw "OSDrive or EFIDrive not found in DeployState.txt" }

# Find DeployData volume - WIM lives here
$DeployDrive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $DeployDrive) { throw "DeployData volume not found." }

$WIMPath = "${DeployDrive}:\OS\install.wim"
if (-not (Test-Path $WIMPath)) { throw "OS image not found at $WIMPath" }

Write-Host "Source      : $WIMPath"
Write-Host "Destination : $OSDrive"
Write-Host "This will take several minutes."

# WIMs from SCCM or network shares carry restrictive inherited ACLs that survive
# robocopy and block DISM (Error 5) even as SYSTEM. Reset before apply.
Write-Host "Resetting WIM file permissions..."
icacls $WIMPath /reset /Q
icacls $WIMPath /grant "SYSTEM:(F)" /Q

Expand-WindowsImage -ImagePath $WIMPath -Index 1 -ApplyPath "$OSDrive\"

Write-Host "Image applied successfully."

Write-Host "`nWriting boot configuration to $EFIDrive..."
bcdboot "$OSDrive\Windows" /s $EFIDrive /f UEFI

if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE" }

Write-Host "Boot configuration written."

pause
