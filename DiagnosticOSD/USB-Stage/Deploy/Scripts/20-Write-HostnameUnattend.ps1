# 20-Write-HostnameUnattend.ps1
# Runs in WinPE post-apply - AFTER image applied, BEFORE reboot
# Reads hostname and writes to unattend.xml in specialize pass

Write-Host "========================================="
Write-Host "  Writing Hostname to Unattend.xml"
Write-Host "========================================="

# Prefer in-scope variable set by 03-Get-HostnameUserPrompt (dot-sourced execution)
# Fall back to file if running standalone or variable is not in scope
if (-not $ComputerName) {
    $HostnameFile = "X:\Deploy\Hostname.txt"
    if (Test-Path $HostnameFile) {
        $ComputerName = (Get-Content $HostnameFile -ErrorAction SilentlyContinue).Trim()
    }
}

if (-not [string]::IsNullOrEmpty($ComputerName)) {
    $UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
            publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$ComputerName</ComputerName>
        </component>
    </settings>
</unattend>
"@

    $PantherPath = "C:\Windows\Panther"
    if (-not (Test-Path $PantherPath)) {
        New-Item -Path $PantherPath -ItemType Directory -Force | Out-Null
    }

    $UnattendXml | Out-File -FilePath "$PantherPath\Unattend.xml" -Encoding utf8 -Force
    Write-Host "  Hostname '$ComputerName' written to $PantherPath\Unattend.xml"

    # Also persist hostname to the offline OS for the domain join script
    $DeployPath = "C:\Deploy"
    if (-not (Test-Path $DeployPath)) {
        New-Item -Path $DeployPath -ItemType Directory -Force | Out-Null
    }
    $ComputerName | Out-File -FilePath "$DeployPath\Hostname.txt" -Encoding ascii -Force
    Write-Host "  Hostname saved to $DeployPath\Hostname.txt for domain join"
} else {
    Write-Warning "  No hostname available. Computer will use a Windows-generated name."
}

Write-Host ""

pause
