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

# 10-Disable-FastBoot.ps1
# Sys-Config - Disables Fast Boot (Hybrid Shutdown) via offline registry.
# Fast Boot hibernates the kernel on shutdown - not a true power cycle.
# This causes stale driver states and masks startup/shutdown problems.
#
# reg.exe calls are exit-code checked: a failed 'reg load' followed by a bare 'reg add'
# silently creates the path in the live WinPE registry instead of the offline OS.

Write-Host "`n=== Disable Fast Boot ===" -ForegroundColor Cyan

$HivePath = "C:\Windows\System32\config\SYSTEM"
$MountKey = "HKLM\OfflineSystem"
$RegPath  = "$MountKey\ControlSet001\Control\Session Manager\Power"

function Invoke-Reg([string[]]$RegArgs) {
    & reg.exe @RegArgs
    if ($LASTEXITCODE -ne 0) { throw "reg.exe $($RegArgs[0]) failed (exit $LASTEXITCODE): $($RegArgs -join ' ')" }
}

Write-Host "Loading offline SYSTEM hive..."
Invoke-Reg @("load", $MountKey, $HivePath)

Invoke-Reg @("add", $RegPath, "/v", "HiberbootEnabled", "/t", "REG_DWORD", "/d", "0", "/f")
Write-Host "Fast boot disabled (HiberbootEnabled = 0)."

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
