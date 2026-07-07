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

# 40-Write-HostnameUnattend.ps1
# OS-Build - Runs in WinPE post-apply - AFTER image applied, BEFORE reboot.
# Writes C:\Windows\Panther\Unattend.xml, which Windows Setup processes on first boot.
#
# This single answer file now does three jobs:
#   specialize : sets the computer name (from X:\Deploy\Hostname.txt), if provided.
#   oobeSystem : enables the built-in Administrator (via AutoLogon - see note), sets its
#                password BLANK, hides the OOBE pages, and - via FirstLogonCommands - sets
#                the forced-password-change flags IN the first logon session, then reboots.
#                The second boot's logon attempt hits the must-change flag and lands on
#                Windows' native forced-change screen; the engineer sets the password
#                there. No second local account is ever created.
#

Write-Host "`n=== Write Deploy Unattend ===" -ForegroundColor Cyan

# --- Computer name (optional) ------------------------------------------------
$HostnameFile = "X:\Deploy\Hostname.txt"
$ComputerName = $null
if (Test-Path $HostnameFile) {
    $ComputerName = (Get-Content $HostnameFile).Trim()
}
if ([string]::IsNullOrEmpty($ComputerName)) {
    Write-Warning "No hostname provided - Windows will generate a random name. Continuing."
    $ComputerName = $null
}

# Build the specialize block only when a name was provided.
$SpecializeBlock = ""
if ($ComputerName) {
    $SpecializeBlock = @"
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
            publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$ComputerName</ComputerName>
        </component>
    </settings>
"@
}

# --- Full answer file --------------------------------------------------------
$UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
$SpecializeBlock
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64"
            publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
            publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Username>Administrator</Username>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Password>
                    <Value></Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <!-- Byte-for-byte the manually-proven sequence (7/2/2026) - do NOT "improve" these
                 commands. wmic is deprecated and REMOVED on 24H2+: kept because it is the
                 proven-on-this-build invocation; successor when a build change forces it:
                 powershell Set-LocalUser -Name Administrator -PasswordNeverExpires 0
                 Orders 3-5 explicitly kill auto-logon before the reboot. Root cause (observed
                 7/2/2026): an auto-logon attempt INTERCEPTED by the must-change flag does not
                 consume its count, so any budgeted "second logon" survives and fires a blank
                 attempt at a later boot ("user name or password is incorrect" after the
                 engineer set a real password). The second auto-logon never had a job anyway -
                 by definition the flag guarantees it can't complete. So: count=1 (boot 1 is
                 the only auto-logon, and a clean successful one exhausts the count per
                 documented behavior) PLUS explicit deletion here, so no auto-logon state can
                 survive regardless of count semantics. Boot 2 = engineer clicks the
                 Administrator tile, blank password, Enter - the change screen appears (the
                 exact flow of the original manual proof). reg delete on a missing value exits
                 nonzero; FirstLogonCommands proceed regardless - harmless by design. -->
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>cmd /c wmic useraccount where "name='Administrator'" set PasswordExpires=true</CommandLine>
                    <Description>Enable expiry on built-in Administrator (prereq that unlocks the must-change flag)</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>cmd /c net user Administrator /logonpasswordchg:yes</CommandLine>
                    <Description>Must-change-at-next-logon on built-in Administrator (proven manually 7/2/2026)</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <CommandLine>cmd /c reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f</CommandLine>
                    <Description>Disable auto-logon for all future boots (this session is the only one that needed it)</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <CommandLine>cmd /c reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f</CommandLine>
                    <Description>Remove residual auto-logon count (may already be gone - nonzero exit is fine)</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <CommandLine>cmd /c reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f</CommandLine>
                    <Description>Remove stored default password value (may not exist - nonzero exit is fine)</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <CommandLine>cmd /c shutdown /r /t 10</CommandLine>
                    <Description>Reboot so the flag is read at the next logon attempt</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
            <UserAccounts>
                <AdministratorPassword>
                    <Value></Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
        </component>
    </settings>
</unattend>
"@

# --- Write it (UTF-8, NO BOM - a richer answer file is likelier to trip a parser
#     on a BOM than the old one-line hostname file did) -------------------------
$PantherPath = "C:\Windows\Panther"
New-Item -Path $PantherPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$PantherPath\Unattend.xml", $UnattendXml, $Utf8NoBom)

Write-Host "Wrote $PantherPath\Unattend.xml (specialize + oobeSystem + FirstLogonCommands)"
if ($ComputerName) { Write-Host "  Computer name           : $ComputerName" }
Write-Host "  Built-in Administrator  : enabled at first boot via AutoLogon, blank password"
Write-Host "  Boot 1                  : auto-login -> FirstLogonCommands set flags + kill auto-logon -> self-reboot (~1 min)"
Write-Host "  Boot 2                  : sign-in tile; Administrator + blank + Enter -> native forced password-change screen"

# --- Persist hostname for Join-Domain's sanity check -------------------------
if ($ComputerName) {
    $DeployPath = "C:\Deploy"
    New-Item -Path $DeployPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $ComputerName | Out-File -FilePath "$DeployPath\Hostname.txt" -Encoding ascii -Force
    Write-Host "  Saved hostname to $DeployPath\Hostname.txt for domain join"
}

pause
