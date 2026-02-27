# 02-Write-HostnameUnattend.ps1
# Runs in WinPE Shutdown - AFTER image applied, BEFORE reboot
# Reads hostname from StartNet script and writes to unattend.xml

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Writing Hostname to Unattend.xml" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$HostnameFile = "X:\OSDCloud\Hostname.txt"

if (Test-Path $HostnameFile) {
    $ComputerName = (Get-Content $HostnameFile -ErrorAction SilentlyContinue).Trim()

    if (-not [string]::IsNullOrEmpty($ComputerName)) {
        # Write unattend.xml with ComputerName in specialize pass
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

        # Ensure Panther directory exists
        $PantherPath = "C:\Windows\Panther"
        if (-not (Test-Path $PantherPath)) {
            New-Item -Path $PantherPath -ItemType Directory -Force | Out-Null
        }

        # Write the unattend.xml
        $UnattendXml | Out-File -FilePath "$PantherPath\Unattend.xml" -Encoding utf8 -Force
        Write-Host "  Hostname '$ComputerName' written to $PantherPath\Unattend.xml" -ForegroundColor Green

        # Also save hostname to C:\OSDCloud for the domain join script later
        $OSDCloudPath = "C:\OSDCloud"
        if (-not (Test-Path $OSDCloudPath)) {
            New-Item -Path $OSDCloudPath -ItemType Directory -Force | Out-Null
        }
        $ComputerName | Out-File -FilePath "$OSDCloudPath\Hostname.txt" -Encoding ascii -Force
        Write-Host "  Hostname also saved to $OSDCloudPath\Hostname.txt for domain join" -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Hostname file was empty" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  WARNING: No hostname file found at $HostnameFile" -ForegroundColor Yellow
    Write-Host "  Computer will use Windows-generated name (DESKTOP-XXXXXXX)" -ForegroundColor Yellow
}

Write-Host ""

pause
