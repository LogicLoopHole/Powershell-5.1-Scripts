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

# Optional DC pinning. Add-Computer's -Server takes "DomainName\DCName" format
# (documented example: Domain01\DC01) - NOT a bare FQDN. Leave $null to let the
# DC locator pick one; the home-lab join succeeded without pinning.
$DomainController = $null
# ============================================================================

function Get-BuiltinAdmin {
    # Resolve the built-in Administrator by RID-500, not by name - immune to the
    # GPO rename that happens after domain join.
    Get-LocalUser | Where-Object { $_.SID.Value -match '-500$' } | Select-Object -First 1
}

function Remove-DeployArtifacts {
    # Called only after a confirmed join (or on an already-joined box). Removes the
    # desktop launcher and the C:\Deploy staging folder (which includes this script at
    # C:\Deploy\PostOS\Scripts - PowerShell has already read the file into memory, so
    # deleting it mid-run is safe).
    # The launcher lands on the LOGGED-IN USER's desktop (copied there at first logon by
    # the RunOnce that 50-Configure-RunOnce writes), so $env:USERPROFILE is the live path.
    # The Public/Administrator sweeps cover stale launchers from older stagings; best-effort.
    Remove-Item "$env:USERPROFILE\Desktop\Join Domain.cmd" -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Users\Public\Desktop\Join Domain.cmd" -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Users\Administrator\Desktop\Join Domain.cmd" -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Deploy" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Deployment artifacts removed (desktop launcher, C:\Deploy)."
}

function Reset-PasswordExpiry {
    # Return the built-in to the state we want a domain-joined box left in: expiry OFF
    # (PasswordNeverExpires = true), the MS-default resting state, so the engineer-set
    # password isn't forced to change again on a domain-managed machine before LAPS takes
    # over. Non-fatal: log and continue on failure (LAPS manages the password regardless).
    $Admin = Get-BuiltinAdmin
    if (-not $Admin) {
        Write-Warning "RID-500 account not found - skipping expiry reset."
        return
    }
    try {
        Set-LocalUser -SID $Admin.SID -PasswordNeverExpires $true -ErrorAction Stop
        Write-Host "Password-expiry reset to Never (MS default state) on the built-in Administrator."
    } catch {
        Write-Warning "Could not reset password-expiry (non-fatal - LAPS will manage the password): $($_.Exception.Message)"
    }
}

function Set-RandomAdminPassword {
    # Backstop only: fires when a join succeeded but the account is still blank (engineer
    # never set one at the forced-change screen). Random, never recorded - LAPS owns it after GP.
    $Admin = Get-BuiltinAdmin
    if (-not $Admin) {
        Write-Warning "RID-500 account not found - cannot set backstop password."
        return
    }
    $upper   = [char[]](65..90)
    $lower   = [char[]](97..122)
    $digits  = [char[]](48..57)
    $special = [char[]]'!@#$%^&*()-_=+'
    $all     = $upper + $lower + $digits + $special
    $pw  = -join @(($upper | Get-Random), ($lower | Get-Random), ($digits | Get-Random), ($special | Get-Random))
    $pw += -join (1..20 | ForEach-Object { $all | Get-Random })
    Set-LocalUser -SID $Admin.SID -Password (ConvertTo-SecureString $pw -AsPlainText -Force)
    $pw = $null
    Write-Host "Blank survived to a successful join - random throwaway password applied (LAPS takes over after GP)."
}

Write-Host "`n=== Domain Join ===" -ForegroundColor Cyan
Write-Host "Domain    : $DomainName"
Write-Host "Target OU : $OUPath"

# --- Already joined: nothing to do but tidy up. -------------------------------------
# Deliberately does NOT touch the password: post-join the account is (or soon will be)
# GPO-renamed and LAPS-managed - overwriting it here would only create drift.
$CurrentDomain = (Get-CimInstance Win32_ComputerSystem).Domain
if ($CurrentDomain -eq $DomainName) {
    Write-Host "Computer is already joined to $DomainName."
    Remove-DeployArtifacts
    $Reboot = [System.Windows.Forms.MessageBox]::Show(
        "Computer is already joined to $DomainName.`n`nRestart now?",
        "Already Domain Joined",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($Reboot -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
    return
}

# --- Confirm the engineer is ready (they've already set the password at the forced-change
#     screen; this is just "join now?"). ------------------------------------------------
$Ready = [System.Windows.Forms.MessageBox]::Show(
    "Join this machine to $DomainName now?`n`n" +
    "(Troubleshoot first if needed - you can re-run 'Join Domain' from the desktop any time.)",
    "Ready to Join Domain?",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if ($Ready -ne [System.Windows.Forms.DialogResult]::Yes) {
    Write-Host "Join deferred by operator. Re-run 'Join Domain' from the desktop when ready."
    return
}

# --- Hostname sanity check ------------------------------------------------------------
$HostnameFile = "C:\Deploy\Hostname.txt"
if (Test-Path $HostnameFile) {
    $SavedHostname   = (Get-Content $HostnameFile).Trim()
    $CurrentHostname = $env:COMPUTERNAME
    Write-Host "Saved hostname   : $SavedHostname"
    Write-Host "Current hostname : $CurrentHostname"
    if ($SavedHostname -ne $CurrentHostname) {
        Write-Warning "Hostname mismatch - unattend.xml may not have applied correctly."
    }
}

# --- Domain credentials (up to 3 attempts) --------------------------------------------
$CredentialPrompt = "Enter credentials to join '$DomainName'`n`nFormat: DOMAIN\username or username@domain.com"
$Credential  = $null
$MaxAttempts = 3
$Attempt     = 0

while ($null -eq $Credential -and $Attempt -lt $MaxAttempts) {
    $Attempt++
    Write-Host "Credential prompt attempt $Attempt of $MaxAttempts..."
    $Credential = Get-Credential -Message $CredentialPrompt

    if ($null -eq $Credential) {
        $Retry = [System.Windows.Forms.MessageBox]::Show(
            "Domain join credentials are required.`n`nDo you want to try again?",
            "Credentials Required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($Retry -eq [System.Windows.Forms.DialogResult]::No) {
            Write-Warning "User chose not to retry. Exiting without domain join (nothing changed - re-run the icon when ready)."
            pause
            return
        }
    }
}

if ($null -eq $Credential) {
    Write-Warning "Failed to obtain credentials after $MaxAttempts attempts."
    [System.Windows.Forms.MessageBox]::Show(
        "Could not obtain domain credentials.`n`nThe computer will NOT be joined.`nNothing changed - re-run 'Join Domain' from the desktop when ready.",
        "Domain Join Failed",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    pause
    return
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
if ($DomainController) { $JoinParams.Server = $DomainController }

try {
    $Joined = $false
    try {
        Add-Computer @JoinParams
        $Joined = $true
    }
    catch {
        # "The account already exists" (FailToJoinDomainFromWorkgroup) - observed 7/2/2026
        # when the computer object survived a previous deploy of this hostname. Mechanism:
        # Add-Computer with -OUPath must CREATE the account in that OU, so a pre-existing
        # account fails the call. The rejoin path is to retry WITHOUT -OUPath, which reuses
        # the existing object where it lives - desirable for reimages, since the object
        # keeps its OU, group memberships, and LAPS state.
        # (Message-text match is en-US; our images are en-US only.)
        if ($_.Exception.Message -match 'account already exists') {
            Write-Warning "Computer account '$env:COMPUTERNAME' already exists in AD (likely a previous deploy of this hostname)."
            $Reuse = [System.Windows.Forms.MessageBox]::Show(
                "A computer account named '$env:COMPUTERNAME' already exists in Active Directory (likely from a previous deploy or reimage).`n`n" +
                "Reuse the existing account and rejoin?`n`n" +
                "Yes - rejoin using the existing object (it stays in its current OU and keeps its group memberships).`n" +
                "No  - cancel; nothing has changed. Delete or rename the AD object (or pick a different hostname) and re-run 'Join Domain'.",
                "Computer Account Already Exists",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($Reuse -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Host "Rejoin declined by operator. Nothing changed - re-run 'Join Domain' when ready."
                pause
                return
            }
            Write-Host "Retrying join, reusing the existing computer account (no -OUPath)..."
            $JoinParams.Remove('OUPath')
            Add-Computer @JoinParams   # a failure here falls to the outer catch
            $Joined = $true
        }
        else {
            throw   # not the existing-account case - let the outer catch handle it
        }
    }
    Write-Host "Successfully joined '$DomainName'."

    # Backstop: only if the account is STILL blank at join time (engineer bypassed or the
    # forced-change mechanism failed). Detection is a real credential test - does an empty
    # password authenticate? - NOT PasswordLastSet: the 7/2/2026 deploy proved the unattend's
    # own blank write stamps PasswordLastSet at first boot, so that field is non-null on
    # every deployed box and can never indicate "blank". (Old check was a dead branch.)
    # The test uses an INTERACTIVE logon type deliberately: the "blank passwords -> console
    # logon only" policy blocks NETWORK-type logons for blank, so a network-style check
    # (e.g. PrincipalContext.ValidateCredentials) false-negatives on exactly the case we
    # need to catch. Interactive is the logon class the policy permits for blank.
    $Admin = Get-BuiltinAdmin
    $BlankStillWorks = $false
    if ($Admin) {
        try {
            $sig = @'
[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool LogonUser(string user, string domain, string pass, int logonType, int logonProvider, out System.IntPtr token);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(System.IntPtr handle);
'@
            $LogonApi = Add-Type -MemberDefinition $sig -Name 'BlankPwCheck' -Namespace 'DeployTool' -PassThru
            $tok = [IntPtr]::Zero
            # 2 = LOGON32_LOGON_INTERACTIVE, 0 = LOGON32_PROVIDER_DEFAULT
            $BlankStillWorks = $LogonApi::LogonUser($Admin.Name, $env:COMPUTERNAME, '', 2, 0, [ref]$tok)
            if ($tok -ne [IntPtr]::Zero) { $LogonApi::CloseHandle($tok) | Out-Null }
        } catch {
            Write-Warning "Blank-password check failed ($($_.Exception.Message)) - assuming blank as the safe default."
            $BlankStillWorks = $true   # fail toward the backstop: worst case is one unnecessary random password, which LAPS replaces anyway
        }
    }
    if ($Admin -and $BlankStillWorks) {
        Set-RandomAdminPassword
    } else {
        Write-Host "Engineer-set local admin password left in place (recovery net until LAPS)."
    }

    # LAST password action before reboot: return expiry to the MS default (off), so the
    # domain-joined machine isn't left with a live expiry clock. Best-effort, non-fatal.
    Reset-PasswordExpiry

    Remove-DeployArtifacts

    [System.Windows.Forms.MessageBox]::Show(
        "Successfully joined domain: $DomainName`n`nThe computer will now restart.",
        "Domain Join Successful",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Restart-Computer -Force
}
catch {
    # Let the native error surface in the console; show the operator the reason too.
    # Deliberately does NOT reset expiry - a failed join leaves the box exactly as-is
    # (password + flag intact) for troubleshooting.
    $_
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to join domain: $DomainName`n`nError: $($_.Exception.Message)`n`nNothing changed - fix the issue and re-run 'Join Domain' from the desktop.",
        "Domain Join Failed",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    pause
}
