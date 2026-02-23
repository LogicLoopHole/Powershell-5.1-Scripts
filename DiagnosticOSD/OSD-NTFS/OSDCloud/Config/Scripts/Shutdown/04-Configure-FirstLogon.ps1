# 03-Configure-FirstLogon.ps1
# Runs in WinPE Shutdown - AFTER hostname unattend, BEFORE reboot
# Adds AutoLogon and FirstLogonCommands to unattend.xml for domain join at first boot

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Configuring Domain Join" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ============================================================================
# CONFIGURATION - Modify these values for your environment
# ============================================================================
$TempAdminUser = "osdadmin"
$TempAdminPass = "OSD@dmin123!"  # Temporary password - account is deleted after domain join
# ============================================================================

$UnattendPath = "C:\Windows\Panther\Unattend.xml"
$ScriptsPath = "C:\OSDCloud\Scripts"
$DomainJoinScript = "Join-Domain.ps1"

# Create scripts directory and copy domain join script
Write-Host "  Setting up FirstLogon scripts..." -ForegroundColor Gray

if (-not (Test-Path $ScriptsPath)) {
    New-Item -Path $ScriptsPath -ItemType Directory -Force | Out-Null
}

# Find and copy the domain join script from USB
$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -match 'OSDCloudUSB' }).DriveLetter
$SourceScript = "$($USB):\Custom\$DomainJoinScript"

if (Test-Path $SourceScript) {
    Copy-Item -Path $SourceScript -Destination "$ScriptsPath\$DomainJoinScript" -Force
    Write-Host "  Copied $DomainJoinScript to $ScriptsPath" -ForegroundColor Green
}
else {
    Write-Host "  WARNING: $DomainJoinScript not found at $SourceScript" -ForegroundColor Yellow
    Write-Host "  Domain join will need to be performed manually" -ForegroundColor Yellow
    exit 0
}

# Check if unattend.xml exists (should have been created by hostname script)
if (-not (Test-Path $UnattendPath)) {
    Write-Host "  WARNING: Unattend.xml not found, creating new one..." -ForegroundColor Yellow
    $ExistingUnattend = $null
}
else {
    # Read existing unattend.xml
    [xml]$ExistingUnattend = Get-Content $UnattendPath -Raw
}

# Build the complete unattend.xml with AutoLogon and FirstLogonCommands
# We need to merge with existing content (hostname in specialize pass)

# Get the hostname from the existing unattend if present
$ComputerName = "*"  # Default to auto-generated
if ($ExistingUnattend) {
    $ShellSetup = $ExistingUnattend.unattend.settings |
        Where-Object { $_.pass -eq "specialize" } |
        Select-Object -ExpandProperty component -ErrorAction SilentlyContinue |
        Where-Object { $_.name -eq "Microsoft-Windows-Shell-Setup" }

    if ($ShellSetup.ComputerName) {
        $ComputerName = $ShellSetup.ComputerName
        Write-Host "  Found existing hostname: $ComputerName" -ForegroundColor Gray
    }
}

# Create the complete unattend.xml
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
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
            publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$TempAdminUser</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>$TempAdminPass</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>$TempAdminUser</Username>
                <Password>
                    <Value>$TempAdminPass</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -ExecutionPolicy Bypass -WindowStyle Normal -File "$ScriptsPath\$DomainJoinScript"</CommandLine>
                    <Description>Join computer to domain</Description>
                    <RequiresUserInput>true</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
            publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
    </settings>
</unattend>
"@

# Write the unattend.xml
$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
Write-Host "  Updated $UnattendPath with AutoLogon configuration" -ForegroundColor Green

# Verify the file
if (Test-Path $UnattendPath) {
    Write-Host "  Unattend.xml successfully configured" -ForegroundColor Green
    Write-Host ""
    Write-Host "  FirstLogon will:" -ForegroundColor Gray
    Write-Host "    1. Auto-logon as '$TempAdminUser'" -ForegroundColor Gray
    Write-Host "    2. Run domain join script" -ForegroundColor Gray
    Write-Host "    3. Prompt for domain credentials" -ForegroundColor Gray
    Write-Host "    4. Join domain and restart" -ForegroundColor Gray
    Write-Host "    5. Remove temporary admin account" -ForegroundColor Gray
}
else {
    Write-Host "  ERROR: Failed to create unattend.xml" -ForegroundColor Red
}

Write-Host ""

pause
