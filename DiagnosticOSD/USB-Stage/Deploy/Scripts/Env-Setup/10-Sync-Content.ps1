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
# Env-Setup - Mirrors USB NTFS content against the LAN share using robocopy.
# Files added to the share are added to the USB, files removed from the share are
# removed from the USB. A failed sync stops the deployment; the operator may retry.

# CONFIGURATION
$Domain      = "Example.Domain"
$SharePath   = "\\DiagOSD-Build.Example.Domain\USB-Stage$"
$MapLetter   = 'N'
$MaxAttempts = 3
$DevMode     = $true

Write-Host "`n=== USB Content Sync ===" -ForegroundColor Cyan

if ($DevMode) {
    Write-Warning "DevMode is enabled - sync can be skipped."
    if ((Read-Host "Skip content sync? [Y/N]") -eq 'Y') {
        Write-Warning "Content sync skipped - USB content may be outdated."
        pause
        return
    }
}

$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' } |
        Select-Object -First 1).DriveLetter

if (-not $USB) {
    Write-Warning "DeployData volume not found."
    Write-Warning "Verify the USB is connected and its NTFS partition is labeled DeployData."
    throw "Content sync failed - deployment stopped."
}

$Destination = "${USB}:\"
Write-Host "USB NTFS volume: $Destination"

function Confirm-Retry {
    Write-Host ""
    return ((Read-Host "Type R to retry, anything else to stop") -eq 'R')
}

$SyncOK  = $false
$Attempt = $true

while ($Attempt) {
    $Attempt = $false
    Remove-PSDrive -Name $MapLetter -Force -ErrorAction SilentlyContinue

    # Read-Host, not Get-Credential: WinPE has no credential UI to render.
    # -Persist is required or robocopy, a separate process, cannot see the drive.
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
            Write-Warning $_.Exception.Message
        }
    }

    if (-not $Connected) {
        if (-not $Cancelled) {
            Write-Warning "Could not connect to $SharePath after $MaxAttempts attempts."
        }
        $Attempt = Confirm-Retry
        continue
    }

    # /XD: System Volume Information and $RECYCLE.BIN exist only on the destination, so
    # /MIR would try to purge them every run. Logs holds the open transcript.
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

        Write-Host "`nSyncing ${MapLetter}:\ -> $Destination`n"
        & robocopy @RoboArgs
        $Code = $LASTEXITCODE
    }
    finally {
        Remove-PSDrive -Name $MapLetter -Force -ErrorAction SilentlyContinue
    }

    # Robocopy exit codes are a bit field - under 8 is success, 8 and above is failure.
    if ($Code -ge 8) {
        Write-Warning "Robocopy failed (exit $Code) - the USB does not match the share."
        $Attempt = Confirm-Retry
        continue
    }

    Write-Host "USB content sync complete (exit $Code)."
    $SyncOK = $true
}

if (-not $SyncOK) {
    Write-Warning "Content sync did not complete - nothing has been written to this machine's disk."
    Write-Host "Fix the issue above, then reboot or run X:\Deploy\Launch.ps1 to start over."
    throw "Content sync failed - deployment stopped."
}

pause
