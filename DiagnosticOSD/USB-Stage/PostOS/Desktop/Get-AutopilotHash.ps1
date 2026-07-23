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

# Get-AutopilotHash.ps1
#
# Runs under the local Administrator profile BEFORE domain join, so it prompts for domain
# credentials to reach the UNC drop share. One file per machine, named by serial - not an
# append to a shared batch file, which concurrent writes from a deployment floor corrupt.
# Merge-AutopilotCsv.ps1 collapses the drop folder into one import file later.
#
# Why not Microsoft's Get-WindowsAutopilotInfo.ps1: it's still at 3.9, published
# 6 Jul 2023, and its capture logic is the same single CIM call used below - unchanged
# in substance since v1.4. Every later fix (3.6 MSGraph->MgGraph, 3.8 AddToGroup deps,
# 3.9 MgGraph scopes) is in the -Online upload path we don't use. Skipping the script
# also skips Install-Script, NuGet, PSGallery trust and the internet dependency.

Add-Type -AssemblyName System.Windows.Forms

# ============================================================================
# CONFIGURATION
# ============================================================================
$DropFolder = "\\server\share\AutopilotDrop"

# Always-written local copy, so there's something to grab by hand if the drop fails.
$LocalFolder = "$env:USERPROFILE\Desktop"

# Group tag. Setting it here beats adding it in the console later - it drives dynamic
# group membership (rule matches "[OrderID]:<tag>") and therefore profile assignment,
# so the device lands in the right group the moment it imports.
$GroupTag = $null                                # e.g. "Site-HQ"

# Deferred - flip to $true to also paint the serial/model/next-steps onto the wallpaper.
# (The hash itself is a ~4000-char blob and can never go on screen.)
$SetWallpaper = $false
# ============================================================================


function Write-AutopilotCsv($Path, $Serial, $Hash, $Tag) {
    # Hand-built, unquoted, ASCII. Do not replace with Export-Csv.
    $header = 'Device Serial Number,Windows Product ID,Hardware Hash'
    $row    = "$Serial,,$Hash"
    if ($Tag) {
        $header += ',Group Tag'
        $row    += ",$Tag"
    }
    Set-Content -Path $Path -Value @($header, $row) -Encoding ASCII -Force
}

function Set-InfoWallpaper($Serial, $Model, $CsvPath) {
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp    = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g      = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(14, 22, 36))
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 30)
    $fLabel = New-Object System.Drawing.Font('Segoe UI', 13)
    $fBig   = New-Object System.Drawing.Font('Consolas', 40, [System.Drawing.FontStyle]::Bold)
    $fMono  = New-Object System.Drawing.Font('Consolas', 15)
    $fNote  = New-Object System.Drawing.Font('Segoe UI', 13)
    $dim    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 160, 190))
    $white  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $accent = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(105, 200, 255))
    $green  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 220, 150))

    $x = 90; $y = 110
    $g.DrawString('Autopilot Hardware Hash Captured', $fTitle, $white, $x, $y);       $y += 80
    $g.DrawString('SERIAL NUMBER', $fLabel, $dim, $x, $y);                            $y += 28
    $g.DrawString($Serial, $fBig, $accent, $x, $y);                                   $y += 80
    $g.DrawString('MODEL', $fLabel, $dim, $x, $y);                                    $y += 26
    $g.DrawString($Model, $fMono, $white, $x, $y);                                    $y += 50
    $g.DrawString('CSV FILE', $fLabel, $dim, $x, $y);                                 $y += 26
    $g.DrawString($CsvPath, $fMono, $white, $x, $y);                                  $y += 50
    $g.DrawString('CAPTURED', $fLabel, $dim, $x, $y);                                 $y += 26
    $g.DrawString((Get-Date -Format 'yyyy-MM-dd HH:mm'), $fMono, $white, $x, $y);     $y += 70
    $g.DrawString('Do NOT reset this PC until Intune shows Profile status: Assigned.', $fNote, $green, $x, $y)

    # Unique filename per run: Windows caches the transcoded wallpaper, so reusing one
    # path can leave a stale image on screen after a re-run.
    $folder = "$env:LOCALAPPDATA\AutopilotHWID"
    if (-not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
    $img = Join-Path $folder "hwid-$(Get-Date -Format 'yyyyMMdd-HHmmss').png"
    $bmp.Save($img, [System.Drawing.Imaging.ImageFormat]::Png)

    $fTitle.Dispose(); $fLabel.Dispose(); $fBig.Dispose(); $fMono.Dispose(); $fNote.Dispose()
    $dim.Dispose(); $white.Dispose(); $accent.Dispose(); $green.Dispose()
    $g.Dispose(); $bmp.Dispose()

    # SPI_SETDESKWALLPAPER (20), SPIF_UPDATEINIFILE|SPIF_SENDWININICHANGE (3). Applies to
    # the CURRENT USER - if launched with different admin creds it lands on that profile.
    $sig = @'
[DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
    $api = Add-Type -MemberDefinition $sig -Name 'Wallpaper' -Namespace 'AutopilotTool' -PassThru
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0'
    $api::SystemParametersInfo(20, 0, $img, 3) | Out-Null
}


Write-Host "`n=== Autopilot Hardware Hash ===" -ForegroundColor Cyan

# --- Capture --------------------------------------------------------
$Serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
$Cs     = Get-CimInstance -ClassName Win32_ComputerSystem
$Model  = "$($Cs.Manufacturer) $($Cs.Model)".Trim()

$Hash = (Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' `
                         -ClassName 'MDM_DevDetail_Ext01' `
                         -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
                         -ErrorAction SilentlyContinue).DeviceHardwareData

if ([string]::IsNullOrWhiteSpace($Hash)) {
    # Seen on some VMs and platforms that don't expose the MDM DevDetail CSP. Fail loudly
    # rather than writing an empty CSV that fails silently at import time.
    Write-Warning "No hardware hash returned. Usual causes: not elevated, or a VM/platform without the MDM DevDetail CSP."
    [System.Windows.Forms.MessageBox]::Show(
        "Could not read the hardware hash from this machine.`n`nConfirm this ran as administrator. Some VMs and platforms do not expose the required MDM CSP.",
        "Hash Capture Failed", 'OK', 'Error') | Out-Null
    pause
    return
}

Write-Host "Serial : $Serial"
Write-Host "Model  : $Model"
Write-Host "Hash   : $($Hash.Length) characters captured."
if ($GroupTag) { Write-Host "Tag    : $GroupTag" }

# --- Write local copy (always) --------------------------------------------------------
if (-not (Test-Path $LocalFolder)) { New-Item -Path $LocalFolder -ItemType Directory -Force | Out-Null }
$LocalPath = Join-Path $LocalFolder "$Serial.csv"
Write-AutopilotCsv $LocalPath $Serial $Hash $GroupTag
Write-Host "Local copy : $LocalPath"

# --- Drop to the share ----------------------------------------------------------------
# Runs as the local Administrator before domain join, so there is no domain session and
# the share needs explicit credentials. Set-Content/Copy-Item CANNOT do this: the
# FileSystem provider ignores -Credential for UNC paths. New-PSDrive is what actually
# authenticates the SMB session.
# Prompted after the local copy is written, so a cancelled or fumbled credential never
# costs the capture. Cancel = skip the drop, keep the desktop copy. No retry loop:
# re-run the icon, the capture is idempotent.
$Dropped = $false
if ($DropFolder) {
    $Cred = Get-Credential -Message "Credentials for the drop share:`n$DropFolder`n`nFormat: DOMAIN\username"
    if ($null -eq $Cred) {
        Write-Warning "Credential prompt cancelled - the desktop copy will need collecting by hand."
    }
    else {
        try {
            New-PSDrive -Name APDrop -PSProvider FileSystem -Root $DropFolder -Credential $Cred -ErrorAction Stop | Out-Null
            Write-AutopilotCsv "APDrop:\$Serial.csv" $Serial $Hash $GroupTag
            Write-Host "Dropped to : $DropFolder"
            $Dropped = $true
        }
        catch {
            # System error 1219 means an SMB session to that server already exists under
            # different credentials - clear it with:  net use \\server /delete
            Write-Warning "Could not write to '$DropFolder' - the desktop copy will need collecting by hand: $($_.Exception.Message)"
        }
        finally {
            Remove-PSDrive -Name APDrop -Force -ErrorAction SilentlyContinue
            $Cred = $null
        }
    }
}

if ($SetWallpaper) {
    try { Set-InfoWallpaper $Serial $Model $LocalPath; Write-Host "Wallpaper updated." }
    catch { Write-Warning "Could not set the wallpaper (non-fatal): $($_.Exception.Message)" }
}

$Delivery = if ($Dropped) {
    "The file has been dropped to the share - no action needed to deliver it."
} else {
    "NOT delivered to the share. Copy $Serial.csv from the desktop to the Intune admin."
}

[System.Windows.Forms.MessageBox]::Show(
    "Hardware hash captured.`n`nSerial: $Serial`nModel : $Model`n`n$Delivery`n`n" +
    "Do NOT reset this PC until Intune shows Profile status: Assigned.",
    "Autopilot Hash Captured", 'OK', 'Information') | Out-Null
