# 01-Sync-Content.ps1
# Runs in WinPE pre-imaging - BEFORE manufacturer check
# Mirrors USB NTFS content against the OSD-NTFS$ LAN share using robocopy
# Files added to share are added to USB, files removed from share are removed from USB
# Prompts for domain credentials - imaging is BLOCKED if network or authentication fails

Write-Host "========================================="
Write-Host "  USB Content Sync"
Write-Host "========================================="

# ============================================================================
# CONFIGURATION - Modify these values for your environment
# ============================================================================
$Domain      = "Example.Domain"
$SharePath   = "\\OSDCloud.Example.Domain\OSD-NTFS$"
$DriveLetter = "N:"
# ============================================================================

# Find USB NTFS volume by label
$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $USB) {
    Write-Warning "ERROR: DeployData volume not found."
    Write-Warning "Verify USB drive is connected and the NTFS partition is labeled 'DeployData'."
    while ($true) { Start-Sleep -Seconds 60 }
}
$USBRoot = "$($USB):\"
Write-Host "  USB NTFS volume: $USBRoot"

# ============================================================================
# NETWORK CHECK
# ============================================================================
Write-Host "  Checking network connectivity to $Domain..."

$PingResult = Test-Connection -ComputerName $Domain -Count 2 -Quiet -ErrorAction SilentlyContinue

if (-not $PingResult) {
    Write-Warning "ERROR: Cannot reach $Domain"
    Write-Warning "Verify wired ethernet connection and retry."
    while ($true) { Start-Sleep -Seconds 60 }
}

Write-Host "  $Domain is reachable."

# ============================================================================
# AUTHENTICATION - Failure blocks imaging
# ============================================================================
$DefaultUser = "$Domain\"
$Cred        = $null
$MaxAttempts = 3
$Attempt     = 0
$Connected   = $false

while ($Attempt -lt $MaxAttempts) {
    $Attempt++
    Write-Host "  Authentication attempt $Attempt of $MaxAttempts"

    try {
        $Cred = Get-Credential -Message "Enter credentials to update this tool (Attempt $Attempt of $MaxAttempts)" -UserName $DefaultUser

        if ($null -eq $Cred) {
            Write-Warning "  Credential prompt cancelled."
            continue
        }

        $Username = $Cred.UserName
        $Password = $Cred.GetNetworkCredential().Password

        Write-Host "  Mapping $DriveLetter to $SharePath..."
        net use $DriveLetter $SharePath /user:$Username $Password 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Successfully mapped $DriveLetter"
            $Connected = $true
            break
        } else {
            Write-Warning "  Authentication failed. Check credentials and try again."
            $Cred = $null
        }
    }
    catch {
        Write-Warning "  Credential entry failed: $_"
    }
}

if (-not $Connected) {
    Write-Warning "ERROR: Authentication failed after $MaxAttempts attempts."
    Write-Warning "Failed to authenticate to $SharePath"
    Write-Warning "Only authorized personnel may use this tool."
    while ($true) { Start-Sleep -Seconds 60 }
}

# ============================================================================
# SYNC
# ============================================================================
# /MIR     = Mirror (adds, updates, AND deletes to match source)
# /Z       = Restartable mode
# /R:10    = 10 retries per file
# /W:15    = 15 seconds between retries
# /DCOPY:T = Preserve directory timestamps
# /NP      = Suppress per-file progress %
#
# /MIR will DELETE files on USB not present on the share.
# The share is the single source of truth.

Write-Host ""
Write-Host "  Syncing $DriveLetter\ -> $USBRoot"
Write-Host "  Large transfers will resume if interrupted."
Write-Host ""

robocopy "$DriveLetter\" "$USBRoot" /MIR /Z /R:10 /W:15 /DCOPY:T /NP

$SyncResult = $LASTEXITCODE

# Robocopy exit codes:
#   0-7 = Success (various combinations of copied/skipped/deleted)
#   8+  = Errors

Write-Host ""

if ($SyncResult -eq 0) {
    Write-Host "  USB is already in sync. No changes needed."
} elseif ($SyncResult -lt 8) {
    Write-Host "  USB content sync complete."
} else {
    Write-Warning "ERROR: USB sync failed (exit code: $SyncResult)"
    Write-Warning "USB content may be incomplete. Restart and retry."
    Write-Warning "If issue persists, reformat the USB with the latest build."
    net use $DriveLetter /delete /y 2>$null
    while ($true) { Start-Sleep -Seconds 60 }
}

# Disconnect
Write-Host "  Disconnecting $DriveLetter..."
net use $DriveLetter /delete /y 2>$null
Write-Host "  Done."
Write-Host ""

pause
