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
$SharePath   = "\\DiagOSD-Build.Example.Domain\USB-Stage$"
$MapLetter   = 'N'
$MaxAttempts = 3
$NetTimeout  = 60      # seconds to wait for the network to come up
$DevMode     = $true   # sole deliberate bypass

Write-Host "`n=== USB Content Sync ===" -ForegroundColor Cyan

if ($DevMode) {
    Write-Warning "DevMode is enabled - sync can be skipped."
    if ((Read-Host "Skip content sync? [Y/N]") -eq 'Y') {
        Write-Warning "Content sync skipped - USB content may be outdated."
        pause
        return
    }
}

# ---------------------------------------------------------------------------
# Locate the USB
# ---------------------------------------------------------------------------

$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' } |
        Select-Object -First 1).DriveLetter

if (-not $USB) {
    Write-Warning "DeployData volume not found."
    Write-Warning "Verify the USB is connected and its NTFS partition is labeled DeployData."
    throw "Content sync failed - deployment stopped."
}

$Destination = "${USB}:\"
Write-Host "USB NTFS volume: $Destination"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-ShareHost {
    param([string]$ComputerName, [int]$TimeoutMs = 3000)

    # TCP connect to SMB on the file server rather than ICMP to the domain. Pinging the
    # domain name answers from a domain controller - a different host that proves
    # nothing about the share - and plenty of environments drop ICMP to servers.
    $Client = $null
    try {
        $Client = New-Object System.Net.Sockets.TcpClient
        $Async  = $Client.BeginConnect($ComputerName, 445, $null, $null)
        $Ready  = $Async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($Ready) { $Client.EndConnect($Async) }
        return $Ready
    }
    catch { return $false }
    finally { if ($Client) { $Client.Close() } }
}

function Confirm-Retry {
    Write-Host ""
    return ((Read-Host "Type R to retry, anything else to stop") -eq 'R')
}

# ---------------------------------------------------------------------------
# Sync - retried on operator request, never bypassed
# ---------------------------------------------------------------------------

$SyncOK  = $false
$Attempt = $true

while ($Attempt) {
    $Attempt = $false
    Remove-PSDrive -Name $MapLetter -Force -ErrorAction SilentlyContinue

    # --- Network ------------------------------------------------------------
    # wpeinit brings the NIC up asynchronously and DHCP may not have finished by the
    # time this runs, so this waits rather than failing on the first miss.

    Write-Host "`nWaiting for $ShareHost (SMB/445)..."
    $Deadline  = (Get-Date).AddSeconds($NetTimeout)
    $Reachable = $false

    while (-not $Reachable) {
        $Reachable = Test-ShareHost -ComputerName $ShareHost
        if ($Reachable -or (Get-Date) -ge $Deadline) { break }
        Start-Sleep -Seconds 5
        Write-Host "  still waiting..."
    }

    if (-not $Reachable) {
        Write-Warning "Cannot reach $ShareHost on port 445 after $NetTimeout seconds."
        Write-Warning "Check the wired ethernet connection, and that DHCP has issued an address."
        $Attempt = Confirm-Retry
        continue
    }
    Write-Host "$ShareHost is reachable."

    # --- Authentication -----------------------------------------------------
    # Read-Host rather than Get-Credential: WinPE ships no credential UI provider, so
    # Get-Credential has no dialog to render and either throws or hangs.
    #
    # New-PSDrive takes the PSCredential object directly, so the password never becomes
    # a command-line argument - no breakage on & ^ | " or spaces, and nothing sensitive
    # in a process command line.
    #
    # -Persist is REQUIRED. Without it the drive exists only inside this PowerShell
    # session and robocopy, a separate process, cannot see it. The mapping lives in the
    # WinPE ramdisk registry and is gone at reboot; it never reaches the deployed OS.
    #
    # A blank username cancels rather than burning an attempt - pressing Enter twice
    # should not silently consume the retries.

    $Connected = $false
    $Cancelled = $false

    for ($i = 1; $i -le $MaxAttempts -and -not $Connected -and -not $Cancelled; $i++) {
        Write-Host "`nAuthentication attempt $i of $MaxAttempts"

        $User = Read-Host "Username (blank to cancel)"
        if (-not $User) {
            Write-Warning "Cancelled at the username prompt."
            $Cancelled = $true
            break
        }
        if ($User -notmatch '[\\@]') { $User = "$Domain\$User" }

        $Pass = Read-Host "Password for $User" -AsSecureString
        $Cred = New-Object System.Management.Automation.PSCredential($User, $Pass)

        try {
            New-PSDrive -Name $MapLetter -PSProvider FileSystem -Root $SharePath `
                        -Credential $Cred -Persist -ErrorAction Stop | Out-Null
            $Connected = $true
            Write-Host "Mapped ${MapLetter}: to $SharePath"
        }
        catch {
            Write-Warning "Authentication failed: $($_.Exception.Message)"
        }
    }

    if (-not $Connected) {
        if (-not $Cancelled) {
            Write-Warning "Could not authenticate to $SharePath after $MaxAttempts attempts."
            Write-Warning "Check the username and password, and that the account can reach this share."
        }
        $Attempt = Confirm-Retry
        continue
    }

    # --- Mirror -------------------------------------------------------------
    # Exclusions, and why each is there:
    #   System Volume Information - present on the destination because it is a volume
    #     root, never on the source. /MIR tries to purge it every run. Whether that
    #     fails (false failure) or succeeds (pointless metadata churn) depends on the
    #     volume; neither is wanted.
    #   $RECYCLE.BIN - same story if the USB has ever been written from a full session.
    #   Logs - the transcript is open by the time Env-Setup runs, so this keeps /MIR
    #     from trying to purge a file it cannot delete. Harmless no-op if
    #     Start-Transcript is removed from Start-Deployment.ps1.
    #
    # /R:2 /W:5 rather than /R:10 /W:15 - an unavailable file costs 10 seconds instead
    # of 150. On a spotty link that is the difference between a report and a stall.
    # /Z is kept: it resumes interrupted large transfers, which matters for install.wim.
    #
    # Arguments are passed as an array so PowerShell quotes each one - required for
    # "System Volume Information" and anything else containing spaces.

    try {
        $RoboArgs = @(
            "${MapLetter}:\"
            $Destination
            '/MIR'
            '/Z'
            '/R:2'
            '/W:5'
            '/DCOPY:T'
            '/NP'
            '/XD'
            (Join-Path $Destination 'System Volume Information')
            (Join-Path $Destination '$RECYCLE.BIN')
            (Join-Path $Destination 'Logs')
        )

        Write-Host "`nSyncing ${MapLetter}:\ -> $Destination"
        Write-Host "Large transfers will resume if interrupted.`n"

        & robocopy @RoboArgs
        $Code = $LASTEXITCODE
    }
    finally {
        Remove-PSDrive -Name $MapLetter -Force -ErrorAction SilentlyContinue
        Write-Host "`nDisconnected ${MapLetter}:"
    }

    # --- Result -------------------------------------------------------------
    # Robocopy exit codes are a bit field. Under 8 is success of some flavour, 8 and
    # above is a real failure, and 16 means it never ran. Splitting those apart keeps
    # transient network trouble distinguishable from a bad path or refused credentials.

    if ($Code -ge 16) {
        Write-Warning "Robocopy could not run (exit $Code)."
        Write-Warning "Usually an unreachable share, a bad path, or credentials the share refused."
        $Attempt = Confirm-Retry
        continue
    }
    if ($Code -ge 8) {
        Write-Warning "One or more files could not be copied (exit $Code)."
        Write-Warning "Usually a dropped link mid-transfer. The USB does not match the share."
        $Attempt = Confirm-Retry
        continue
    }

    if ($Code -eq 0) { Write-Host "USB already matches the share. Nothing to do." }
    else             { Write-Host "USB content sync complete (exit $Code)." }

    $SyncOK = $true
}

# ---------------------------------------------------------------------------
# Outcome
# ---------------------------------------------------------------------------

if (-not $SyncOK) {
    Write-Host ""
    Write-Warning "Content sync did not complete - the USB does not match the share."
    Write-Warning "Nothing has been written to this machine's disk."
    Write-Host "Fix the issue above, then reboot or run X:\Deploy\Launch.ps1 to start over."
    throw "Content sync failed - deployment stopped."
}

pause
