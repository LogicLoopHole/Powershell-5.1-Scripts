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

# 50-Configure-RunOnce.ps1
# OS-Build - Runs in WinPE post-apply.
#   1) Stages the USB's entire PostOS\ folder into the offline OS at C:\Deploy\PostOS
#      (a mirror - drop new content on the USB, it rides along with no code changes).
#   2) Writes ONE RunOnce line into the offline SOFTWARE hive that, at first logon,
#      copies C:\Deploy\PostOS\Desktop\* onto the logged-in user's desktop.
#
# WHY THE COPY IS DEFERRED TO RUNONCE (the design's whole point):
#   The copy runs IN the user's first logon session, where %USERPROFILE% resolves to a
#   real, initialized Administrator profile. Writing to the profile desktop offline from
#   WinPE was tried (7/2/2026 deploy) and the file never landed - profile folders written
#   offline don't reliably survive first-logon profile initialization. In-session, the
#   problem doesn't exist - and the icon lands on the Administrator's OWN desktop.
#
# WHY THE RUNONCE COPIES FROM C:\Deploy AND NOT THE USB DIRECTLY:
#   Drive letters vary per machine, and on real hardware the USB may be unplugged before
#   first logon. WinPE stages by volume label (no letter assumption); the RunOnce then has
#   zero removable-media dependency.
#
# CONVENTION - what lands where:
#   USB PostOS\Desktop\*  -> logged-in user's desktop at first logon (launchers, shortcuts,
#                            future PSADT entry points - anything user-facing).
#   USB PostOS\Scripts\*  -> stays at C:\Deploy\PostOS\Scripts (payloads the launchers call).
#   Both "Join Domain.cmd" (Desktop\) and "FirstLogon.cmd" (Scripts\) are STATIC files on
#   the USB - no generation code; edit them on the USB directly. The RunOnce this script
#   writes is one quote-free path pointing at FirstLogon.cmd; add future first-logon
#   actions by editing that file, never this script.
#
# RUNONCE TIMING (self-healing, by observation of the two-boot flow):
#   Boot 1's logon runs FirstLogonCommands (flags + shutdown /r /t 10). If the shell
#   processes RunOnce inside that window, the copy (sub-second) completes and the value is
#   consumed. If the reboot wins the race, the value is NOT consumed and simply fires at
#   the next completed logon - i.e. boot 2, right after the engineer sets the password.
#   Either way the desktop is populated by the time it's usable.
#
# Every reg.exe call is exit-code checked. If 'reg load' fails, the mount key doesn't exist
# and a bare 'reg add' would silently CREATE that path in the live WinPE registry - reporting
# success while nothing reaches the deployed OS (no RunOnce, no desktop, no join path).

Write-Host "`n=== Stage PostOS + Configure First-Logon Desktop Copy ===" -ForegroundColor Cyan

$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $USB) { throw "DeployData volume not found." }

$SourcePostOS = "$($USB):\PostOS"
$DeployPostOS = "C:\Deploy\PostOS"

# --- Sanity: the two files this deployment cannot function without. Throw, don't warn -
#     a machine with no join path is the silent-no-op class this project hunts. -----------
$RequiredFiles = @(
    "$SourcePostOS\Scripts\Join-Domain.ps1",
    "$SourcePostOS\Scripts\FirstLogon.cmd",
    "$SourcePostOS\Desktop\Join Domain.cmd"
)
foreach ($f in $RequiredFiles) {
    if (-not (Test-Path $f)) {
        throw "Required file missing from USB: $f - deployment would have no domain-join path. Fix the USB staging and redeploy."
    }
}

# --- 1) Stage: mirror USB PostOS -> C:\Deploy\PostOS ------------------------------------
New-Item -Path $DeployPostOS -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
Copy-Item -Path "$SourcePostOS\*" -Destination $DeployPostOS -Recurse -Force
if (-not (Test-Path "$DeployPostOS\Scripts\Join-Domain.ps1")) {
    throw "Staging verification failed - $DeployPostOS\Scripts\Join-Domain.ps1 not present after copy."
}
Write-Host "Staged USB PostOS\ -> $DeployPostOS"

# --- 2) RunOnce in the OFFLINE SOFTWARE hive --------------------------------------------
$HivePath = "C:\Windows\System32\config\SOFTWARE"
if (-not (Test-Path $HivePath)) { throw "Offline SOFTWARE hive not found at $HivePath." }

$MountKey = "HKLM\OfflineSoftware"

reg load $MountKey $HivePath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "reg load failed ($LASTEXITCODE) - hive may still be mounted from a prior failed run. A bare 'reg add' now would write into the live WinPE registry and silently produce a deploy with no desktop content."
}

try {
    # The RunOnce value is a SINGLE QUOTE-FREE PATH, by hard-won design. The first
    # attempt embedded the whole xcopy command line (with quoted paths) in the value,
    # and reg.exe died with "Invalid syntax" in WinPE: PowerShell 5.1 passes arguments
    # to native exes by wrapping them in quotes WITHOUT escaping quotes already inside,
    # and the value also ended in \" (trailing backslash before a closing quote =
    # escaped quote to the native parser). Both are documented PS-5.1 hazards. A bare
    # path with no spaces has nothing to mangle - and the actual copy logic lives in
    # PostOS\Scripts\FirstLogon.cmd, a static USB file, where %USERPROFILE% expands at
    # RUN time in the user's session and future first-logon actions are added by
    # editing the file, never this hive write.
    $RunOnceCmd = 'C:\Deploy\PostOS\Scripts\FirstLogon.cmd'
    reg add "$MountKey\Microsoft\Windows\CurrentVersion\RunOnce" /v "DeployDesktopContent" /t REG_SZ /d $RunOnceCmd /f | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg add failed ($LASTEXITCODE) - RunOnce not written."
    }
    Write-Host "RunOnce set: FirstLogon.cmd (copies PostOS\Desktop\* -> logged-in user's desktop)."
}
finally {
    [gc]::Collect()   # release any lingering handle on the mounted hive before unload
    reg unload $MountKey | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "reg unload failed ($LASTEXITCODE) - the hive may remain mounted. A reboot of WinPE clears it; the RunOnce write above already succeeded."
    }
}

Write-Host "Domain join remains a manual desktop action - double-click 'Join Domain' when ready; retry by re-running it."

pause
