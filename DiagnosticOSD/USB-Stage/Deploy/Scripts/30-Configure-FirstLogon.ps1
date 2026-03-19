# 30-Configure-FirstLogon.ps1
# Runs in WinPE post-apply - AFTER hostname unattend, BEFORE reboot
# Adds AutoLogon and FirstLogonCommands to unattend.xml for domain join at first boot

Write-Host "========================================="
Write-Host "  Configuring First Logon"
Write-Host "========================================="

# ============================================================================
# CONFIGURATION - Modify these values for your environment
# ============================================================================
$TempAdminUser = "osdadmin"
$TempAdminPass = "OSD@dmin123!"  # Temporary - account is removed after domain join
# ============================================================================

$UnattendPath  = "C:\Windows\Panther\Unattend.xml"
$ScriptsPath   = "C:\Deploy\Scripts"
$DomainJoinScript = "Join-Domain.ps1"

# Create scripts directory on the offline OS
Write-Host "  Setting up first logon scripts..."
if (-not (Test-Path $ScriptsPath)) {
    New-Item -Path $ScriptsPath -ItemType Directory -Force | Out-Null
}

# Find USB NTFS volume by label
$USB = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DeployData' }).DriveLetter
if (-not $USB) {
    Write-Warning "  ERROR: DeployData volume not found."
    exit 1
}

$SourceScript = "$($USB):\PostOS\Scripts\$DomainJoinScript"

if (Test-Path $SourceScript) {
    Copy-Item -Path $SourceScript -Destination "$ScriptsPath\$DomainJoinScript" -Force
    Write-Host "  Copied $DomainJoinScript to $ScriptsPath"
} else {
    Write-Warning "  $DomainJoinScript not found at $SourceScript"
    Write-Warning "  Domain join will need to be performed manually."
    exit 0
}

# Read ComputerName from existing unattend if available
# Prefer in-scope variable; fall back to parsing the XML
if (-not $ComputerName) {
    if (Test-Path $UnattendPath) {
        [xml]$ExistingUnattend = Get-Content $UnattendPath -Raw
        $ShellSetup = $ExistingUnattend.unattend.settings |
            Where-Object { $_.pass -eq "specialize" } |
            Select-Object -ExpandProperty component -ErrorAction SilentlyContinue |
            Where-Object { $_.name -eq "Microsoft-Windows-Shell-Setup" }
        if ($ShellSetup.ComputerName) {
            $ComputerName = $ShellSetup.ComputerName
        }
    }
}

if (-not $ComputerName) { $ComputerName = "*" }

Write-Host "  Hostname: $ComputerName"

# Write complete unattend.xml including specialize, oobeSystem, AutoLogon, FirstLogonCommands
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

$UnattendXml | Out-File -FilePath $UnattendPath -Encoding utf8 -Force

if (Test-Path $UnattendPath) {
    Write-Host "  Unattend.xml configured successfully."
    Write-Host "  First logon will:"
    Write-Host "    1. Auto-logon as '$TempAdminUser'"
    Write-Host "    2. Run domain join script"
    Write-Host "    3. Prompt for domain credentials"
    Write-Host "    4. Join domain and restart"
    Write-Host "    5. Remove temporary admin account"
} else {
    Write-Error "  Failed to write unattend.xml"
}

Write-Host ""

pause
