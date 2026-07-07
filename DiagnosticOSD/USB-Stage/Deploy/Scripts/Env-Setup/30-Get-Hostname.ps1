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

# 30-Get-Hostname.ps1
# Env-Setup - Runs in WinPE pre-imaging - Collects hostname from operator BEFORE imaging begins
# Saves to X:\Deploy\Hostname.txt for use by post-apply scripts

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

Write-Host "`n=== Hostname Collection ===" -ForegroundColor Cyan

$validHostname = $false
while ($validHostname -eq $false) {
    $newHostname = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter device asset tag hostname (H + 7 digits, e.g., H1234567)",
        "Hostname Input",
        "H1234567"
    )

    # User pressed Cancel or empty input - re-prompt
    if ([string]::IsNullOrEmpty($newHostname)) { continue }

    if ($newHostname -match "^H\d{7}$") {
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            $newHostname,
            "Is this hostname correct?",
            [System.Windows.Forms.MessageBoxButtons]::YesNo
        )
        if ($confirmation -eq [System.Windows.Forms.DialogResult]::Yes) {
            $validHostname = $true
        }
    } else {
        # Validate length (max 15 characters for NetBIOS)
        if ($newHostname.Length -gt 15) {
            [System.Windows.Forms.MessageBox]::Show(
                "Hostname cannot exceed 15 characters. You entered $($newHostname.Length) characters.",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            continue
        }

        # Validate no illegal characters
        if ($newHostname -match '[\\/:*?"<>|.&\s]') {
            [System.Windows.Forms.MessageBox]::Show(
                "Hostname contains illegal characters. Avoid: \ / : * ? `" < > | . & and spaces",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            continue
        }

        $warning = [System.Windows.Forms.MessageBox]::Show(
            "You entered a non-standard hostname: $newHostname`n`nAre you sure you want to use this?",
            "Non-Standard Hostname",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($warning -eq [System.Windows.Forms.DialogResult]::Yes) {
            $validHostname = $true
        }
    }
}

# Save hostname to WinPE scratch path for post-apply scripts
$ScratchDir   = "X:\Deploy"
$HostnameFile = "$ScratchDir\Hostname.txt"
New-Item -Path $ScratchDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$newHostname | Out-File -FilePath $HostnameFile -Encoding ascii -Force

Write-Host "Hostname '$newHostname' confirmed and saved."

pause
