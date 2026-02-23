# 01-Check-Updates.ps1
# Runs in WinRE StartNet - BEFORE imaging, BEFORE manufacturer check
# Mirrors USB NTFS content against the OSD-NTFS$ LAN share using robocopy
# Files added to share are added to USB, files removed from share are removed from USB
# Prompts for domain credentials - imaging is BLOCKED if network or authentication fails

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  USB Content Sync (Check-Updates)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ============================================================================
# CONFIGURATION - Modify these values for your environment
# ============================================================================
$Domain      = "Example.Domain"
$SharePath   = "\\OSDCloud.Example.Domain\OSD-NTFS$"
$DriveLetter = "N:"
# ============================================================================

# Find USB NTFS volume
$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -match 'OSDCloudUSB' }).DriveLetter
if (-not $USB) {
    Write-Host "" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  ERROR: OSDCloudUSB volume not found" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  Verify USB drive is connected and the" -ForegroundColor Red
    Write-Host "  NTFS partition is labeled 'OSDCloudUSB'." -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    while ($true) { Start-Sleep -Seconds 60 }
}
$USBRoot = "$($USB):\"
Write-Host "  USB NTFS volume: $USBRoot" -ForegroundColor Gray

# ============================================================================
# NETWORK CHECK - Verify domain is reachable before prompting for credentials
# ============================================================================
Write-Host "  Checking network connectivity to $Domain..." -ForegroundColor Gray

$PingResult = Test-Connection -ComputerName $Domain -Count 2 -Quiet -ErrorAction SilentlyContinue

if (-not $PingResult) {
    Write-Host "" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  ERROR: Cannot reach $Domain" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  This tool requires a wired ethernet" -ForegroundColor Red
    Write-Host "  connection. Verify cable is connected" -ForegroundColor Red
    Write-Host "  and retry." -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    while ($true) { Start-Sleep -Seconds 60 }
}

Write-Host "  $Domain is reachable." -ForegroundColor Green

# ============================================================================
# AUTHENTICATION - Failure blocks imaging
# ============================================================================
$DefaultUser = "$Domain\"
$Cred = $null
$MaxAttempts = 3
$Attempt = 0
$Connected = $false

while ($Attempt -lt $MaxAttempts) {
    $Attempt++
    Write-Host "  Authentication attempt $Attempt of $MaxAttempts" -ForegroundColor Gray

    try {
        $Cred = Get-Credential -Message "Enter credentials to update this tool (Attempt $Attempt of $MaxAttempts)" -UserName $DefaultUser

        if ($null -eq $Cred) {
            # User clicked Cancel
            Write-Host "  Credential prompt cancelled." -ForegroundColor Yellow
            continue
        }

        $Username = $Cred.UserName
        $Password = $Cred.GetNetworkCredential().Password

        Write-Host "  Mapping $DriveLetter to $SharePath..." -ForegroundColor Cyan
        net use $DriveLetter $SharePath /user:$Username $Password 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Successfully mapped $DriveLetter" -ForegroundColor Green
            $Connected = $true
            break
        }
        else {
            Write-Host "  Authentication failed. Check credentials and try again." -ForegroundColor Red
            $Cred = $null
        }
    }
    catch {
        Write-Host "  Credential entry failed: $_" -ForegroundColor Yellow
    }
}

# If authentication failed after all attempts, BLOCK imaging
if (-not $Connected) {
    Write-Host "" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  ERROR - Authentication Failed" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  Failed to authenticate to $SharePath" -ForegroundColor Red
    Write-Host "  after $MaxAttempts attempts." -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "  Only authorized beta testers may use" -ForegroundColor Red
    Write-Host "  this tool." -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    while ($true) { Start-Sleep -Seconds 60 }
}

# ============================================================================
# SYNC - Mirror share content to USB (NTFS partition only)
# ============================================================================
# /MIR     = Mirror (1:1 sync - adds, updates, AND deletes to match source)
# /Z       = Restartable mode (resumes interrupted transfers at byte level)
# /R:10    = 10 retries per file on failure
# /W:15    = 15 seconds between retries (gives network time to reconnect)
# /DCOPY:T = Preserve directory timestamps
# /NP      = Suppress per-file progress % (cleaner in small console)
#
# /MIR will DELETE files on USB not present on the share.
# The share (OSD-NTFS$) is the single source of truth.

Write-Host "" -ForegroundColor Gray
Write-Host "  Syncing $DriveLetter\ -> $USBRoot" -ForegroundColor Cyan
Write-Host "  Large file transfers will attempt to resume if interrupted." -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray

robocopy "$DriveLetter\" "$USBRoot" /MIR /Z /R:10 /W:15 /DCOPY:T /NP

$SyncResult = $LASTEXITCODE

# Robocopy exit codes:
#   0 = No changes needed (already in sync)
#   1 = Files were copied successfully
#   2 = Extra files/dirs on destination were deleted
#   3 = Files copied + extras deleted
#   4-7 = Combinations of the above
#   8+ = ERRORS - copy failures, permissions, network loss, etc.

Write-Host "" -ForegroundColor Gray

if ($SyncResult -eq 0) {
    Write-Host "  USB is already in sync. No changes needed." -ForegroundColor Green
}
elseif ($SyncResult -lt 8) {
    Write-Host "  USB content sync complete." -ForegroundColor Green
}
else {
    Write-Host "" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  ERROR: USB sync failed (exit code: $SyncResult)" -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    Write-Host "  USB content may be incomplete or corrupt." -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "  Restart and retry. If the issue persists," -ForegroundColor Red
    Write-Host "  reformat the USB with the latest build." -ForegroundColor Red
    Write-Host "  =========================================" -ForegroundColor Red
    # Disconnect before blocking
    net use $DriveLetter /delete /y 2>$null
    while ($true) { Start-Sleep -Seconds 60 }
}

# Disconnect network drive
Write-Host "  Disconnecting $DriveLetter..." -ForegroundColor Gray
net use $DriveLetter /delete /y 2>$null
Write-Host "  Done." -ForegroundColor Green

Write-Host "" -ForegroundColor Gray
pause
