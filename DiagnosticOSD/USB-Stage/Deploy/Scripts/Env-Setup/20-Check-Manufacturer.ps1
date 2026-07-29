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

# 20-Check-Manufacturer.ps1
# Env-Setup - Validates that a driver folder exists for this model before proceeding.
# Persists Manufacturer, ModelName, MachineType and DriverFolder to X:\Deploy\Hardware.txt
# so 30-Driver-Injection.ps1 can reuse them without re-querying WMI.
#
# FOLDER NAMING
#
#   Normal - one folder named exactly as the model name reports. This is every model,
#   every manufacturer, unless Lenovo ships one model name as multiple platforms:
#       \Drivers\LENOVO\ThinkPad T14 Gen 3
#       \Drivers\HP\HP EliteBook 840 G10 Notebook PC
#
#   Conflict - when one model name covers several driver sets, EVERY variant gets a
#   long name and the plain folder is not created:
#       \Drivers\LENOVO\ThinkPad T14 Gen 6 - 21QC 21QD - Intel
#       \Drivers\LENOVO\ThinkPad T14 Gen 6 - 21QG 21QH - Intel
#       \Drivers\LENOVO\ThinkPad T14 Gen 6 - 21QJ 21QK - AMD
#   Named as Lenovo's Deployment Recipe Card does, model name first, " - " separator,
#   machine types as whole words. The CPU vendor is there for humans.
#
# MATCH ORDER
#
#   1. Folder named exactly the model name. This is the entire path for well-behaved
#      models and every non-Lenovo device - no machine type is read, nothing else is
#      considered, and adding this feature changes nothing about how they resolve.
#   2. Lenovo only, and only when step 1 found nothing: a " - " folder naming this
#      machine's type. Reached only for models deliberately split into variants.
#   3. Anything else is unsupported and reported.
#
#   Matching is exact, or model name followed by " - ". Loose prefix matching would let
#   "ThinkPad T14 Gen 1" claim "ThinkPad T14 Gen 1 AMD" - a different model that matches
#   its own folder by name - and a future "Gen 10".
#
#   The machine type path is scoped to \Drivers\LENOVO\ and gated on the vendor string,
#   so no other manufacturer's folders are enumerated or considered for it.

Add-Type -AssemblyName System.Windows.Forms

Write-Host "`n=== Check Manufacturer ===" -ForegroundColor Cyan

$Computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$Bios     = Get-CimInstance -ClassName Win32_BIOS

$Manufacturer = "$($Computer.Vendor)".Trim()
$IsLenovo     = ($Manufacturer -eq 'LENOVO')

if ($IsLenovo) {
    # Lenovo stores the readable model name in Version ("ThinkPad T14s Gen 3") and the
    # machine type + model in Name ("21QCS00J00").
    $ModelName = "$($Computer.Version)".Trim()
} else {
    # Other manufacturers (HP, Microsoft, etc.) use Name field
    $ModelName = "$($Computer.Name)".Trim()
}

# Machine type is the leading 4 characters of the Lenovo product name - the same key the
# Recipe Card's "Model LIKE '21QC%'" query uses. Not read for other manufacturers.
$MachineType = $null
$RawName     = "$($Computer.Name)".Trim()
if ($IsLenovo -and $RawName.Length -ge 4) {
    $MachineType = $RawName.Substring(0, 4).ToUpper()
}

# ---------------------------------------------------------------------------
# Matcher
# ---------------------------------------------------------------------------

function Find-DriverFolder {
    # Returns an object with Status ('Match','Ambiguous','None'), Folder and Candidates.
    param(
        [string]$VendorRoot,
        [string]$ModelName,
        [string]$MachineType
    )

    $Result = [PSCustomObject]@{
        Status     = 'None'
        Folder     = $null
        Candidates = @()
        Reason     = $null
    }

    $All = @(Get-ChildItem -Path $VendorRoot -Directory -ErrorAction SilentlyContinue)
    if ($All.Count -eq 0) { return $Result }

    $Exact  = @($All | Where-Object { $_.Name -eq $ModelName })
    $Scoped = @($All | Where-Object { $_.Name -like "$ModelName - *" })

    $Result.Candidates = @(@($Exact) + @($Scoped) | Select-Object -ExpandProperty Name)

    # 1. Exact model name.
    if ($Exact.Count -ge 1) {
        # Diagnostic only, no effect on the result. Both forms present for one model
        # means the folder discipline slipped somewhere - the plain folder is supposed
        # to be removed when variants are created. Delete this block if it is noise.
        if ($Scoped.Count -gt 0) {
            Write-Warning "Both '$ModelName' and $($Scoped.Count) variant folder(s) exist for this model. Using the exact match; variants will never be reached."
        }
        $Result.Status = 'Match'
        $Result.Folder = $Exact[0]
        return $Result
    }

    # 2. Lenovo variant folders, matched on machine type.
    if ($Scoped.Count -gt 0) {
        if (-not $MachineType) {
            $Result.Status = 'Ambiguous'
            $Result.Reason = "This model is split into variant folders but no machine type is available to choose between them."
            return $Result
        }

        $Pattern = "\b$([regex]::Escape($MachineType))\b"
        $ByType  = @($Scoped | Where-Object { $_.Name -match $Pattern })

        if ($ByType.Count -eq 1) {
            $Result.Status = 'Match'
            $Result.Folder = $ByType[0]
            return $Result
        }
        if ($ByType.Count -gt 1) {
            $Result.Status = 'Ambiguous'
            $Result.Reason = "More than one folder names machine type $MachineType."
            return $Result
        }

        $Result.Status = 'Ambiguous'
        $Result.Reason = "This model is split into variant folders and none names machine type $MachineType."
        return $Result
    }

    return $Result
}

# ---------------------------------------------------------------------------
# Search
#
# Scan all drives D-Z except X (WinPE ramdisk) and C (will be wiped). Each drive is
# evaluated independently so two drives carrying the same driver tree do not read as an
# ambiguous match.
# ---------------------------------------------------------------------------

$DriverFolder = $null
$Ambiguous    = $null
$Candidates   = @()

$Drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
    $_.Name -match '^[D-W]$|^[Y-Z]$'
}

foreach ($Drive in $Drives) {
    $VendorRoot = Join-Path -Path "$($Drive.Root)" -ChildPath "Drivers\$Manufacturer"
    if (-not (Test-Path -Path $VendorRoot)) { continue }

    $Found = Find-DriverFolder -VendorRoot $VendorRoot -ModelName $ModelName -MachineType $MachineType

    if ($Found.Candidates.Count -gt 0) { $Candidates += $Found.Candidates }

    if ($Found.Status -eq 'Match') {
        $DriverFolder = $Found.Folder
        break
    }
    if ($Found.Status -eq 'Ambiguous') {
        $Ambiguous = $Found.Reason
        break
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

if (-not $DriverFolder) {
    $CandidateText = if ($Candidates.Count -gt 0) {
        "Folders considered:`n  " + (($Candidates | Select-Object -Unique) -join "`n  ")
    } else {
        "No folder for this model was found on any drive."
    }

    $Problem = if ($Ambiguous) { $Ambiguous } else { "No matching driver pack." }

    $message = @"
Please provide screenshot to the Breakfix Engineering Team:

Manufacturer: $Manufacturer
Model Name:   $ModelName
Raw Name:     $RawName
Machine Type: $(if ($MachineType) { $MachineType } else { 'n/a' })
Version:      $($Computer.Version)
Serial Number:$($Bios.SerialNumber)

Expected Driver Path: \Drivers\$Manufacturer\$ModelName
Searched drives: D-Z (except X)

$Problem

$CandidateText

Generic drivers will be used.
Image will be UNSUPPORTED but deployment can continue.
"@
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        "UNSUPPORTED MODEL DETECTED",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null

    Write-Warning "Unsupported model: $Manufacturer $ModelName - continuing without model-specific drivers."
    if ($Ambiguous) { Write-Warning $Ambiguous }
}

Write-Host "Manufacturer  : $Manufacturer"
Write-Host "Model         : $ModelName"
if ($MachineType) { Write-Host "Machine type  : $MachineType" }
if ($DriverFolder) {
    Write-Host "Driver folder : $($DriverFolder.FullName)"
} else {
    Write-Host "Driver folder : (none - unsupported model)"
}

# Persist for downstream scripts (30-Driver-Injection).
# DriverFolder may be empty - 30 will skip injection in that case.
$ScratchDir   = "X:\Deploy"
$HardwareFile = "$ScratchDir\Hardware.txt"
New-Item -Path $ScratchDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$DriverFolderValue = if ($DriverFolder) { $DriverFolder.FullName } else { "" }
$MachineTypeValue  = if ($MachineType)  { $MachineType }           else { "" }
@"
Manufacturer=$Manufacturer
ModelName=$ModelName
MachineType=$MachineTypeValue
DriverFolder=$DriverFolderValue
"@ | Out-File -FilePath $HardwareFile -Encoding ascii -Force

pause
