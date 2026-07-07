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

# 40-Suppress-FirstLogon-StartMenu.ps1
# Sys-Config - Default User hive tweaks applied to every new profile,
# including domain users on first sign-in.
#
#   StartShownOnUpgrade = 1   Suppresses Windows 11 auto-opening Start
#                             on first user logon (which can cover startup
#                             scripts and tools running in the background).
#
#   ScreenSaveActive = 0      Disables screensaver for all new profiles.
#
# The built-in Administrator's profile is NOT touched by Default User edits -
# its screensaver and power settings are baked into the reference WIM
# (see CAPTURE-GUIDE.md).
#
# reg.exe calls are exit-code checked: a failed 'reg load' followed by a bare 'reg add'
# silently creates the path in the live WinPE registry instead of the offline hive.

Write-Host "`n=== Default User Hive Tweaks ===" -ForegroundColor Cyan

$HivePath    = "C:\Users\Default\NTUSER.DAT"
$MountKey    = "HKLM\OfflineDefaultUser"
$StartPath   = "$MountKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$DesktopPath = "$MountKey\Control Panel\Desktop"

function Invoke-Reg([string[]]$RegArgs) {
    & reg.exe @RegArgs
    if ($LASTEXITCODE -ne 0) { throw "reg.exe $($RegArgs[0]) failed (exit $LASTEXITCODE): $($RegArgs -join ' ')" }
}

if (-not (Test-Path $HivePath)) { throw "Default user hive not found at $HivePath" }

Write-Host "Loading offline Default User hive..."
Invoke-Reg @("load", $MountKey, $HivePath)

Invoke-Reg @("add", $StartPath, "/v", "StartShownOnUpgrade", "/t", "REG_DWORD", "/d", "1", "/f")
Write-Host "Start menu auto-open on first logon suppressed (StartShownOnUpgrade = 1)."

Invoke-Reg @("add", $DesktopPath, "/v", "ScreenSaveActive", "/t", "REG_SZ", "/d", "0", "/f")
Write-Host "Screensaver disabled for all new profiles (ScreenSaveActive = 0)."

# Unload with one retry - a failed unload leaves the hive mounted and un-flushed.
[gc]::Collect(); Start-Sleep -Seconds 1
& reg.exe unload $MountKey
if ($LASTEXITCODE -ne 0) {
    Write-Warning "reg unload failed - retrying in 2 seconds..."
    [gc]::Collect(); Start-Sleep -Seconds 2
    & reg.exe unload $MountKey
    if ($LASTEXITCODE -ne 0) { throw "reg unload failed for $MountKey (exit $LASTEXITCODE) - hive left mounted. Re-run this script." }
}

pause
