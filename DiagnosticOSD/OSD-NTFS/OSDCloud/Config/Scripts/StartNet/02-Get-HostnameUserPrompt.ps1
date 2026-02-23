# 01-Get-HostnameUserPrompt.ps1
# Runs in WinPE StartNet - Collects hostname from user BEFORE imaging begins
# Saves to X:\OSDCloud\Hostname.txt for use by Shutdown scripts

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Hostname Collection" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

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
    }
    else {
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
        if ($newHostname -match '[\\/:*?"<>|.\s]') {
            [System.Windows.Forms.MessageBox]::Show(
                "Hostname contains illegal characters. Avoid: \ / : * ? `" < > | . and spaces",
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

# Save hostname for Shutdown scripts to pick up
$HostnameFile = "X:\OSDCloud\Hostname.txt"
New-Item -Path (Split-Path $HostnameFile) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$newHostname | Out-File -FilePath $HostnameFile -Encoding ascii -Force

Write-Host "Hostname '$newHostname' saved for deployment" -ForegroundColor Green
Write-Host ""

pause
