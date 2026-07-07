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

# 10-Sync-Content.ps1
# Env-Setup - Mirrors USB NTFS content against the OSD-NTFS$ LAN share using robocopy.
# Files added to share are added to USB, files removed from share are removed from USB.
# DEFERRED SUBSYSTEM (see GAMEPLAN.md M6): failures currently WARN and continue so dev time
# goes to the deploy path. Revisit blocking semantics when the share work lands.

Write-Host "`n=== USB Content Sync ===" -ForegroundColor Cyan

# CONFIGURATION
$Domain      = "Example.Domain"
$SharePath   = "\\DiagOSD-Build.Example.Domain\OSD-NTFS$"
$DriveLetter = "N:"
$DevMode     = $true   # Intended state until M6 - sync is deferred, skip prompt stays available

if ($DevMode) {
    Write-Warning "DevMode is enabled - sync can be skipped."
    $Skip = Read-Host "Skip content sync? [Y/N]"
    if ($Skip -eq 'Y') {
        Write-Warning "Content sync skipped - USB content may be outdated."
        pause
        return
    }
}

# Find USB NTFS volume by label
$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $USB) { throw "DeployData volume not found." }
$USBRoot = "$($USB):\"
Write-Host "USB NTFS volume: $USBRoot"

# Network check
Write-Host "Checking network connectivity to $Domain..."
if (-not (Test-Connection -ComputerName $Domain -Count 2 -Quiet)) {
    Write-Warning "Cannot reach $Domain. Verify wired ethernet connection."
    pause
    return
}
Write-Host "$Domain is reachable."

# Authentication - failure blocks imaging
$DefaultUser = "$Domain\"
$Cred        = $null
$MaxAttempts = 3
$Attempt     = 0
$Connected   = $false

while ($Attempt -lt $MaxAttempts) {
    $Attempt++
    Write-Host "Authentication attempt $Attempt of $MaxAttempts"

    $Cred = Get-Credential -Message "Enter credentials to update this tool (Attempt $Attempt of $MaxAttempts)" -UserName $DefaultUser
    if ($null -eq $Cred) {
        Write-Warning "Credential prompt cancelled."
        continue
    }

    $Username = $Cred.UserName
    $Password = $Cred.GetNetworkCredential().Password

    Write-Host "Mapping $DriveLetter to $SharePath..."
    net use $DriveLetter $SharePath /user:$Username $Password

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Successfully mapped $DriveLetter"
        $Connected = $true
        break
    }
    Write-Warning "Authentication failed. Check credentials and try again."
    $Cred = $null
}

if (-not $Connected) {
    Write-Warning "Authentication failed after $MaxAttempts attempts. Only authorized personnel may use this tool."
    pause
    return
}

# Sync
# /MIR will DELETE files on USB not present on the share. The share is the single source of truth.
Write-Host "`nSyncing $DriveLetter\ -> $USBRoot"
Write-Host "Large transfers will resume if interrupted.`n"

robocopy "$DriveLetter\" "$USBRoot" /MIR /Z /R:10 /W:15 /DCOPY:T /NP

$SyncResult = $LASTEXITCODE
if ($SyncResult -eq 0) {
    Write-Host "USB is already in sync. No changes needed."
} elseif ($SyncResult -lt 8) {
    Write-Host "USB content sync complete."
} else {
    Write-Warning "USB sync failed (exit code: $SyncResult). USB content may be incomplete."
}

Write-Host "Disconnecting $DriveLetter..."
net use $DriveLetter /delete /y
Write-Host "Done."

pause
