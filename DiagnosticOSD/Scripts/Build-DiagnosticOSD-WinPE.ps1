#Requires -RunAsAdministrator
<#
    Build-DiagnosticOSD-WinPE.ps1
    Combines all WinPE build + USB prep steps into one script.
    Run from an elevated PowerShell session.
    No Deployment Tools Environment console required.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------
# CONFIGURATION  -- edit these if your paths differ
# ----------------------------------------------------------
$BuildRoot   = "C:\DiagOSD-Build"
$WinPEDir    = "$BuildRoot\WinPE"
$MountDir    = "$WinPEDir\mount"
$StageDir    = "$BuildRoot\USB-Stage"
$DriversDir  = "$BuildRoot\ExtractedBootDrivers"

$USBWinPE   = "F"   # FAT32 partition drive letter (no colon)
$USBData    = "N"   # NTFS  partition drive letter (no colon)

$ADKRoot    = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
$CopypeCmd  = "$ADKRoot\Windows Preinstallation Environment\copype.cmd"
$OCPath     = "$ADKRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"

# ----------------------------------------------------------
# HELPERS
# ----------------------------------------------------------
function Step([string]$msg) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
}

function OK([string]$msg)   { Write-Host "  OK: $msg" -ForegroundColor Green }
function WARN([string]$msg) { Write-Host "  WARN: $msg" -ForegroundColor Yellow }

function FAIL([string]$msg) {
    Write-Host "  FAIL: $msg" -ForegroundColor Red
    throw $msg
}

function Invoke-Dism([string[]]$DismArgs) {
    & dism.exe @DismArgs
    if ($LASTEXITCODE -ne 0) {
        FAIL "DISM failed (exit $LASTEXITCODE) with args: $($DismArgs -join ' ')"
    }
}

function Invoke-Diskpart([string]$Script) {
    $tmp = [System.IO.Path]::GetTempFileName() + ".txt"
    [System.IO.File]::WriteAllText($tmp, $Script.Trim(), [System.Text.Encoding]::ASCII)
    & diskpart.exe /s $tmp
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) { FAIL "diskpart failed (exit $LASTEXITCODE)" }
}

# ----------------------------------------------------------
# PREFLIGHT -- Verify ADK and WinPE add-on are installed
# ----------------------------------------------------------
Step "Preflight -- Verifying ADK and WinPE add-on paths"

# Try to auto-detect the ADK root if the configured path does not exist
if (-not (Test-Path $ADKRoot)) {
    $Candidates = @(
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit",
        "C:\Program Files\Windows Kits\10\Assessment and Deployment Kit"
    )
    foreach ($C in $Candidates) {
        if (Test-Path $C) {
            $ADKRoot   = $C
            $CopypeCmd = "$ADKRoot\Windows Preinstallation Environment\copype.cmd"
            $OCPath    = "$ADKRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"
            WARN "ADKRoot not at configured path -- using auto-detected: $ADKRoot"
            break
        }
    }
}

if (-not (Test-Path $ADKRoot)) {
    FAIL ("ADK root not found. Install the Windows ADK from:" +
          "`n  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" +
          "`n  Configured path was: $ADKRoot")
}
OK "ADK root found: $ADKRoot"

if (-not (Test-Path $CopypeCmd)) {
    FAIL ("copype.cmd not found -- the WinPE add-on for the ADK is not installed." +
          "`n  The WinPE add-on is a SEPARATE download from the ADK itself." +
          "`n  Download it from the same page as the ADK:" +
          "`n  https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" +
          "`n  Expected path: $CopypeCmd")
}
OK "copype.cmd found: $CopypeCmd"

$Amd64WinPEPath = "$ADKRoot\Windows Preinstallation Environment\amd64"
if (-not (Test-Path $Amd64WinPEPath)) {
    # List what architectures are actually present to help diagnose
    $PERoot = "$ADKRoot\Windows Preinstallation Environment"
    $FoundArchs = if (Test-Path $PERoot) {
        (Get-ChildItem $PERoot -Directory | Select-Object -ExpandProperty Name) -join ", "
    } else {
        "(WinPE root directory not found)"
    }
    FAIL ("amd64 WinPE architecture files not found." +
          "`n  Expected: $Amd64WinPEPath" +
          "`n  Architectures present: $FoundArchs" +
          "`n  Re-run the WinPE add-on installer and ensure 'amd64' is selected.")
}
OK "amd64 WinPE architecture files found."

if (-not (Test-Path $OCPath)) {
    FAIL ("WinPE_OCs folder not found at: $OCPath" +
          "`n  The WinPE add-on installation may be incomplete. Re-install it.")
}
OK "WinPE_OCs folder found: $OCPath"

# ----------------------------------------------------------
# PART 0 -- CLEANUP (handles stuck or partial mounts)
# ----------------------------------------------------------
Step "Part 0 -- Cleanup and safety checks"

$mountInfo = & dism.exe /Get-MountedImageInfo 2>&1
if ($mountInfo -match [regex]::Escape($MountDir)) {
    WARN "Found a mounted image at $MountDir -- discarding it now..."
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard
    & dism.exe /Cleanup-Wim
    OK "Stale mount discarded and WIM cleaned up."
} else {
    OK "No stuck mounts found."
}

if (Test-Path $WinPEDir) {
    WARN "$WinPEDir already exists -- removing before copype..."
    Remove-Item $WinPEDir -Recurse -Force
    OK "Removed $WinPEDir."
}

# ----------------------------------------------------------
# PART 1 -- BUILD THE WINPE IMAGE
# ----------------------------------------------------------

# Step 1.1 -- Create WinPE working files
Step "Step 1.1 -- copype amd64 -> $WinPEDir"

if (-not (Test-Path $CopypeCmd)) { FAIL "copype.cmd not found at: $CopypeCmd" }

# copype.cmd needs env vars (WinPERoot, OSCDImgRoot, etc.) set by DandISetEnv.bat --
# the same script the Deployment Tools Environment runs on launch.
# Chain them in one cmd.exe session so copype inherits the correct environment.
$DandIEnv = "$ADKRoot\Deployment Tools\DandISetEnv.bat"

if (Test-Path $DandIEnv) {
    OK "Found DandISetEnv.bat -- chaining with copype for correct ADK environment."
    & cmd.exe /c "`"$DandIEnv`" && `"$CopypeCmd`" amd64 `"$WinPEDir`""
} else {
    WARN "DandISetEnv.bat not found at: $DandIEnv"
    WARN "Calling copype directly -- this will likely fail with 'architecture not found'."
    WARN "Check that the ADK Deployment Tools component is installed."
    & cmd.exe /c "`"$CopypeCmd`" amd64 `"$WinPEDir`""
}
if ($LASTEXITCODE -ne 0) { FAIL "copype failed." }

$BootWim = "$WinPEDir\media\sources\boot.wim"
if (-not (Test-Path $BootWim)) { FAIL "boot.wim not found after copype." }
OK "boot.wim confirmed at $BootWim"

# Step 1.2 -- Mount the WinPE image
Step "Step 1.2 -- Mount boot.wim"

Invoke-Dism @("/Mount-Image", "/ImageFile:$BootWim", "/Index:1", "/MountDir:$MountDir")
OK "Image mounted at $MountDir"

# Step 1.3 -- Add optional components
Step "Step 1.3 -- Add optional components"

$Components = @(
    "WinPE-WMI",
    "WinPE-NetFX",
    "WinPE-Scripting",
    "WinPE-PowerShell",
    "WinPE-StorageWMI",
    "WinPE-DismCmdlets"
)

foreach ($Comp in $Components) {
    Write-Host "  Adding $Comp..." -ForegroundColor Gray
    Invoke-Dism @("/Add-Package", "/Image:$MountDir", "/PackagePath:$OCPath\$Comp.cab")
    Invoke-Dism @("/Add-Package", "/Image:$MountDir", "/PackagePath:$OCPath\en-us\${Comp}_en-us.cab")
    OK "$Comp installed."
}

$PkgList = & dism.exe /Get-Packages /Image:"$MountDir"
$InstalledCount = ($PkgList | Select-String "State : Installed").Count
Write-Host "  Installed package count: $InstalledCount (expected 14)" -ForegroundColor Gray
if ($InstalledCount -lt 14) {
    WARN "Fewer packages than expected -- review DISM output above."
}

# Step 1.4 -- Add boot drivers
Step "Step 1.4 -- Add boot drivers"

$DriverFiles = Get-ChildItem $DriversDir -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue
if ((Test-Path $DriversDir) -and $DriverFiles) {
    Invoke-Dism @("/Add-Driver", "/Image:$MountDir", "/Driver:$DriversDir", "/Recurse")
    OK "Boot drivers added."
} else {
    WARN "No .inf files found in $DriversDir -- skipping driver injection."
}

# Step 1.5 -- Write the WinPE launcher into the mounted image
Step "Step 1.5 -- Write X:\Deploy\Launch.ps1 into mount"

$DeployDir = "$MountDir\Deploy"
New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null

$LauncherLines = @(
    "# X:\Deploy\Launch.ps1",
    '$Drive = (Get-Volume | Where-Object { $_.FileSystemLabel -eq ''DeployData'' }).DriveLetter',
    "",
    'if (-not $Drive) {',
    '    Write-Error "DeployData volume not found. Verify USB is connected and NTFS partition is labeled DeployData."',
    '    pause',
    '    exit 1',
    '}',
    "",
    '$MasterScript = "${Drive}:\Deploy\Start-Deployment.ps1"',
    "",
    'if (-not (Test-Path $MasterScript)) {',
    '    Write-Error "Start-Deployment.ps1 not found at $MasterScript"',
    '    pause',
    '    exit 1',
    '}',
    "",
    '& $MasterScript'
)

[System.IO.File]::WriteAllLines(
    "$DeployDir\Launch.ps1",
    $LauncherLines,
    [System.Text.Encoding]::ASCII
)
OK "Launch.ps1 written to $DeployDir\Launch.ps1"

# Step 1.6 -- Write startnet.cmd
Step "Step 1.6 -- Write startnet.cmd"

$StartnetPath = "$MountDir\Windows\System32\startnet.cmd"

$StartnetLines = @(
    "@echo off",
    "wpeinit",
    "powershell.exe -ExecutionPolicy Bypass -File X:\Deploy\Launch.ps1"
)

[System.IO.File]::WriteAllLines(
    $StartnetPath,
    $StartnetLines,
    [System.Text.Encoding]::ASCII
)

Write-Host "  startnet.cmd contents:" -ForegroundColor Gray
Get-Content $StartnetPath | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
OK "startnet.cmd written."

# Step 1.7 -- Unmount and commit
Step "Step 1.7 -- Unmount and commit (do not interrupt)"

try {
    Invoke-Dism @("/Unmount-Image", "/MountDir:$MountDir", "/Commit")
    OK "Image committed and unmounted successfully."
} catch {
    WARN "Commit failed -- discarding and cleaning up."
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard
    & dism.exe /Cleanup-Wim
    FAIL "WinPE build failed at unmount/commit. Fix the issue and restart from Step 1.2."
}

# ----------------------------------------------------------
# PART 2 -- PREPARE THE USB
# ----------------------------------------------------------
Step "Part 2 -- Prepare the USB"

Write-Host ""
Write-Host "  Available disks:" -ForegroundColor Yellow

Get-Disk | ForEach-Object {
    $SizeGB = [math]::Round($_.Size / 1GB, 1)
    Write-Host ("  Disk {0}  {1}  {2} GB  BusType={3}" -f $_.Number, $_.FriendlyName, $SizeGB, $_.BusType)
}

Write-Host ""
$DiskNum = Read-Host "  Enter the USB disk NUMBER from the list above (WARNING: all data will be erased)"

$SelectedDisk = Get-Disk -Number $DiskNum
if ($SelectedDisk.BusType -ne 'USB') {
    WARN ("Disk {0} reports BusType={1}, not USB." -f $DiskNum, $SelectedDisk.BusType)
    $Confirm = Read-Host "  Are you SURE this is the correct disk? Type YES to continue"
    if ($Confirm -ne 'YES') { FAIL "Aborted by user." }
}

# Step 2.2 -- Partition the USB
Step "Step 2.2 -- Partition USB disk $DiskNum"

$DiskpartScript = @"
list disk
select disk $DiskNum
clean
convert gpt
create partition primary size=1024
format fs=fat32 quick label=WinPE
assign letter=$USBWinPE
create partition primary
format fs=ntfs quick label=DeployData
assign letter=$USBData
exit
"@

Invoke-Diskpart $DiskpartScript

Start-Sleep -Seconds 3

$Volumes = Get-Volume | Where-Object { $_.FileSystemLabel -in @('WinPE', 'DeployData') }
if ($Volumes.Count -ne 2) {
    FAIL ("Expected 2 volumes (WinPE + DeployData) but found {0}. Check diskpart output above." -f $Volumes.Count)
}
OK ("WinPE (FAT32, {0}:) and DeployData (NTFS, {1}:) created." -f $USBWinPE, $USBData)

# Step 2.3 -- Copy WinPE boot files to FAT32 partition
Step "Step 2.3 -- Copy WinPE boot files to ${USBWinPE}:\"

& cmd.exe /c "xcopy `"$WinPEDir\media\*`" `"${USBWinPE}:\`" /E /H /F"
if ($LASTEXITCODE -ne 0) { FAIL "xcopy of WinPE media failed." }
OK "WinPE boot files copied to ${USBWinPE}:\"

# Step 2.4 -- Copy staging content to NTFS partition
Step "Step 2.4 -- Copy staging content to ${USBData}:\"

if (-not (Test-Path $StageDir)) {
    WARN "$StageDir not found -- skipping. Add deploy scripts later and robocopy manually."
} else {
    & robocopy.exe "$StageDir" "${USBData}:\" /E /NP
    if ($LASTEXITCODE -gt 7) { FAIL "robocopy failed with exit code $LASTEXITCODE." }
    OK "Staging content copied to ${USBData}:\"
}

# Step 2.5 -- Verify
Step "Step 2.5 -- Verify USB contents"

$Checks = @(
    @{ Path = "${USBWinPE}:\sources\boot.wim";                        Label = "WinPE boot image" },
    @{ Path = "${USBWinPE}:\EFI\Microsoft\Boot\BCD";                  Label = "EFI BCD boot config" },
    @{ Path = "${USBData}:\Deploy\Scripts\02-Check-Manufacturer.ps1"; Label = "Deploy script (optional)" }
)

foreach ($Check in $Checks) {
    if (Test-Path $Check.Path) {
        OK ("{0} found at {1}" -f $Check.Label, $Check.Path)
    } else {
        WARN ("{0} not found at {1} (may be expected)" -f $Check.Label, $Check.Path)
    }
}

# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Build complete. Expected boot sequence on target:" -ForegroundColor Green
Write-Host "    1. UEFI selects FAT32 USB partition" -ForegroundColor Green
Write-Host "    2. WinPE loads and wpeinit runs" -ForegroundColor Green
Write-Host "    3. startnet.cmd calls X:\Deploy\Launch.ps1" -ForegroundColor Green
Write-Host "    4. Launcher finds DeployData volume" -ForegroundColor Green
Write-Host "    5. Start-Deployment.ps1 is called from N:\Deploy\" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host "  NOTE: If Start-Deployment.ps1 does not exist yet," -ForegroundColor Green
Write-Host "  the launcher will pause with a not-found message." -ForegroundColor Green
Write-Host "  This is expected and confirms WinPE is working." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
