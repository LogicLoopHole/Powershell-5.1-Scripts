# 02-Configure-FirstLogon.ps1
# Runs in WinPE Shutdown - AFTER hostname unattend, BEFORE reboot
# Creates local admin with blank password, bypasses OOBE, forces password change at first unlock
#
# DESIGN NOTES:
# - OOBE is fully bypassed to prevent Windows from running updates or upgrading
#   the OS version during setup (e.g., 24H2 to 25H2)
# - WiFi from WinRE does NOT carry over to the deployed OS. This is intentional.
#   The machine boots with no network, preventing background updates at first login.
#   The user can manually connect to WiFi or plug in ethernet when ready.
# - AutoLogon gets the user to desktop hands-free. A FirstLogonCommands script
#   then flags the account for a mandatory password change and locks the workstation.
#   Windows natively enforces the password change at the Ctrl+Alt+Del unlock screen.
# - Power management is disabled (monitor, disk, sleep) for both AC and battery
#   so the machine never times out during diagnostics.

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Configuring First Logon" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ============================================================================
# CONFIGURATION
# ============================================================================
$TempAdminUser = "osdadmin"
# ============================================================================

$UnattendPath = "C:\Windows\Panther\Unattend.xml"
$ScriptsPath  = "C:\OSDCloud\Scripts"

# Create scripts directory
if (-not (Test-Path $ScriptsPath)) {
    New-Item -Path $ScriptsPath -ItemType Directory -Force | Out-Null
}

# ============================================================================
# CREATE FIRSTLOGON SCRIPT
# ============================================================================
# Runs once at first login via FirstLogonCommands:
# 1. Disable all power timeouts (AC and battery)
# 2. Flag account for mandatory password change
# 3. Lock workstation - Windows enforces password change at unlock

$FirstLogonScript = @"
@REM === Power Management - prevent timeouts during diagnostics ===
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0

@REM === Force password change and lock ===
net user $TempAdminUser /logonpasswordchg:yes
rundll32.exe user32.dll,LockWorkStation
"@

$FirstLogonScript | Out-File -FilePath "$ScriptsPath\FirstLogon.cmd" -Encoding ascii -Force
Write-Host "  Created FirstLogon.cmd" -ForegroundColor Green

# ============================================================================
# CHECK FOR EXISTING HOSTNAME
# ============================================================================
$ComputerName = "*"
if (Test-Path $UnattendPath) {
    [xml]$ExistingUnattend = Get-Content $UnattendPath -Raw
    $ShellSetup = $ExistingUnattend.unattend.settings |
        Where-Object { $_.pass -eq "specialize" } |
        Select-Object -ExpandProperty component -ErrorAction SilentlyContinue |
        Where-Object { $_.name -eq "Microsoft-Windows-Shell-Setup" }
    if ($ShellSetup.ComputerName) {
        $ComputerName = $ShellSetup.ComputerName
        Write-Host "  Found existing hostname: $ComputerName" -ForegroundColor Gray
    }
}

# ============================================================================
# BUILD UNATTEND.XML
# ============================================================================
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
                            <Value></Value>
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
                    <Value></Value>
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
                    <CommandLine>$ScriptsPath\FirstLogon.cmd</CommandLine>
                    <Description>Power management, password change, lock</Description>
                    <RequiresUserInput>false</RequiresUserInput>
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

$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force
Write-Host "  Updated $UnattendPath" -ForegroundColor Green

if (Test-Path $UnattendPath) {
    Write-Host "  Unattend.xml configured:" -ForegroundColor Green
    Write-Host "    - OOBE bypassed (no network, no updates)" -ForegroundColor Gray
    Write-Host "    - Local admin: $TempAdminUser (blank password)" -ForegroundColor Gray
    Write-Host "    - Power timeouts disabled (AC + battery)" -ForegroundColor Gray
    Write-Host "    - AutoLogon once, then forced password change" -ForegroundColor Gray
}
else {
    Write-Host "  ERROR: Failed to create unattend.xml" -ForegroundColor Red
}

Write-Host ""
pause
