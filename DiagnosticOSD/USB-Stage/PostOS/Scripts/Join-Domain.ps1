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

# Join-Domain.ps1
# A desktop icon the engineer runs manually when a pre-join machine is ready to join.
# NOT auto-triggered - there is no auto-run and no on-logon entry. Retry = double-click again.
# Lives at C:\Deploy\PostOS\Scripts (staged from the USB by 50-Configure-RunOnce); the
# "Join Domain.cmd" launcher is a static USB file (PostOS\Desktop\) copied onto the
# logged-in user's desktop at first logon by a RunOnce.
#
# Password model (forced change happens BEFORE this script ever runs):
#   The deploy unattend's FirstLogonCommands (40-Write-HostnameUnattend.ps1) set
#   password-expiry + must-change on the built-in Administrator IN the first logon session,
#   then reboot; boot 2's logon hits the flag and forces Windows' own native change-password
#   screen. The engineer sets a per-machine password there before reaching a usable desktop.
#   So by the time this icon is clicked, the local admin password is normally already set by
#   the engineer - this script does NOT collect or change it. The password is never typed
#   into this script, its memory, or any file. (The flags do NOT ride in the WIM: the
#   unattend's own blank-password write at first boot clears a pre-baked must-change bit -
#   proven on the 7/2/2026 deploy.)
#
#   Post-join password handling:
#     - Reset password-expiry to Never (the MS default state) as the LAST action before the
#       success reboot, so a domain-joined machine is left in the expected default. Best
#       effort: a failure to reset is logged, not fatal (LAPS rotates the password anyway).
#     - Backstop: if the engineer somehow never set a password and blank survived to a
#       successful join, a random discarded password lands so blank never persists on-domain.
#
# Failure model: any join failure leaves the password and the expiry flag exactly as they
# are, so the machine stays accessible for troubleshooting. A failed join deliberately does
# NOT reset expiry - if the box is troubleshot long enough for the flag to fire, the engineer
# (who knows the password) just sets a new one; harmless and self-correcting. Re-run the icon.
# If the computer account already exists in AD (previous deploy/reimage of this hostname),
# the script offers to reuse it and rejoins without -OUPath - the object stays in its
# current OU and keeps group memberships/LAPS state.

#Requires -RunAsAdministrator

Add-Type -AssemblyName System.Windows.Forms

# ============================================================================
# CONFIGURATION - Modify these values for your environment
# ============================================================================
# DNS form - must match what (Get-CimInstance Win32_ComputerSystem).Domain reports
# after a join, or the already-joined check will false-negative and re-attempt.
$DomainName = "Example.Domain"
$OUPath     = "CN=Computers,DC=Example,DC=Domain" # Target OU for computer object
$UseLegacyAccountReuse = $true
# ============================================================================

$LsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$LsaName = 'NetJoinLegacyAccountReuse'


function Ask($Text, $Title) {
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes'
}

function Say($Text, $Title, $Icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $Icon) | Out-Null
}

function Restore-LegacyAccountReuse($Prior) {
    if (-not $UseLegacyAccountReuse) { return }
    try {
        if ($null -eq $Prior) {
            Remove-ItemProperty -Path $LsaPath -Name $LsaName -ErrorAction Stop
            Write-Host "$LsaName removed (restored to absent)."
        }
        else {
            Set-ItemProperty -Path $LsaPath -Name $LsaName -Value $Prior -ErrorAction Stop
            Write-Host "$LsaName restored to $Prior."
        }
    }
    catch {
        Write-Warning "Could not restore $LsaName - REMOVE IT MANUALLY: $($_.Exception.Message)"
    }
}

function Reset-PasswordExpiry {
    $Admin = Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
    if (-not $Admin) {
        Write-Warning "RID-500 account not found - skipping expiry reset."
        return
    }
    try {
        Set-LocalUser -SID $Admin.SID -PasswordNeverExpires $true -ErrorAction Stop
        Write-Host "Password-expiry reset to Never on the built-in Administrator."
    }
    catch {
        Write-Warning "Could not reset password-expiry (non-fatal - LAPS will manage it): $($_.Exception.Message)"
    }
}

function Remove-DeployArtifacts {
    # Called only after a confirmed join. PowerShell has already read this script into
    # memory, so deleting C:\Deploy (which contains it) mid-run is safe.
    "$env:USERPROFILE\Desktop", "C:\Users\Public\Desktop" | ForEach-Object {
        Remove-Item "$_\Join Domain.cmd" -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "C:\Deploy" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Deployment artifacts removed (desktop launcher, C:\Deploy)."
}


Write-Host "`n=== Domain Join ===" -ForegroundColor Cyan
Write-Host "Domain    : $DomainName"
Write-Host "Target OU : $OUPath"

# --- Already joined: nothing to do but tidy up. ---------------------------------------
if ((Get-CimInstance Win32_ComputerSystem).Domain -eq $DomainName) {
    Write-Host "Computer is already joined to $DomainName."
    Remove-DeployArtifacts
    if (Ask "Computer is already joined to $DomainName.`n`nRestart now?" "Already Domain Joined") {
        Restart-Computer -Force
    }
    return
}

# --- Hostname sanity check ------------------------------------------------------------
$HostNotice   = ""
$HostnameFile = "C:\Deploy\Hostname.txt"
if (Test-Path $HostnameFile) {
    $Saved = (Get-Content $HostnameFile).Trim()
    Write-Host "Saved hostname   : $Saved"
    Write-Host "Current hostname : $env:COMPUTERNAME"
    if ($Saved -ne $env:COMPUTERNAME) {
        Write-Warning "Hostname mismatch - unattend.xml may not have applied correctly."
        $HostNotice = "WARNING - hostname mismatch.`n" +
                      "Expected '$Saved' but this machine is '$env:COMPUTERNAME'.`n" +
                      "unattend.xml may not have applied correctly.`n`n"
    }
}

# --- Confirm the engineer is ready ----------------------------------------------------
$Prompt = $HostNotice +
          "Join this machine to $DomainName now?`n`n" +
          "(Troubleshoot first if needed - you can re-run 'Join Domain' from the desktop any time.)"
if (-not (Ask $Prompt "Ready to Join Domain?")) {
    Write-Host "Join deferred by operator. Re-run 'Join Domain' from the desktop when ready."
    return
}

# --- Domain credentials ---------------------------------------------------------------
$Credential = Get-Credential -Message "Enter credentials to join '$DomainName'`n`nFormat: DOMAIN\username or username@domain.com"
if (-not $Credential) {
    Write-Warning "No credentials supplied. Nothing changed - re-run 'Join Domain' when ready."
    pause
    return
}

# --- Apply the legacy account-reuse key, capturing whatever was there first -----------
$PriorReuse = $null
if ($UseLegacyAccountReuse) {
    $PriorReuse = (Get-ItemProperty -Path $LsaPath -Name $LsaName -ErrorAction SilentlyContinue).$LsaName
    New-ItemProperty -Path $LsaPath -Name $LsaName -PropertyType DWord -Value 1 -Force | Out-Null
    $Was = if ($null -eq $PriorReuse) { 'absent' } else { $PriorReuse }
    Write-Host "$LsaName set to 1 (prior value: $Was)."
}

# --- Join -----------------------------------------------------------------------------
Write-Host "Attempting to join '$DomainName'..."
$JoinParams = @{
    DomainName  = $DomainName
    Credential  = $Credential
    OUPath      = $OUPath
    Force       = $true
    ErrorAction = "Stop"
}

try {
    try {
        Add-Computer @JoinParams
    }
    catch {
        if ($_.Exception.Message -notmatch 'account already exists') { throw }

        Write-Warning "Computer account '$env:COMPUTERNAME' already exists in AD (likely a previous deploy of this hostname)."
        $ReusePrompt = "A computer account named '$env:COMPUTERNAME' already exists in Active Directory.`n`n" +
                       "Yes - rejoin using the existing object (it keeps its current OU and group memberships).`n" +
                       "No  - cancel; nothing changes. Delete or rename the AD object, or pick a different hostname."
        if (-not (Ask $ReusePrompt "Computer Account Already Exists")) {
            Write-Host "Rejoin declined by operator. Nothing changed - re-run 'Join Domain' when ready."
            pause
            return
        }
        Write-Host "Retrying join, reusing the existing computer account (no -OUPath)..."
        $JoinParams.Remove('OUPath')
        Add-Computer @JoinParams
    }
}
catch {
    $_
    Say ("Failed to join domain: $DomainName`n`nError: $($_.Exception.Message)`n`n" +
         "Nothing changed - fix the issue and re-run 'Join Domain' from the desktop.") `
        "Domain Join Failed" 'Error'
    pause
    return
}
finally {
    Restore-LegacyAccountReuse $PriorReuse
}

Write-Host "Successfully joined '$DomainName'."
Reset-PasswordExpiry
Remove-DeployArtifacts
Say "Successfully joined domain: $DomainName`n`nThe computer will now restart." "Domain Join Successful"
Restart-Computer -Force
