#
# The MIT License (MIT)
#
# Copyright (c) 2025 LogicLoopHole
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


# Usage: select the example you'd like and uncomment the block by removing the <# and #>

<# # MSI GUID Check Example
$msiGuid = "{GUID-HERE}"
$installedMsi = Get-CimInstance -ClassName Win32_Product | Where-Object {$_.IdentifyingNumber -eq $msiGuid}
if ($installedMsi)
	{
		Write-Host "SUCCESS: MSI with GUID found."
		exit 0
	}
else
	{
		Write-Host "FAIL: MSI not installed."
		exit 1
	} #>

<# # Multiple MSI GUID Check Example
$msiGuids = @("{GUID-1}", "{GUID-2}", "{GUID-3}")
$foundMsi = Get-CimInstance -ClassName Win32_Product | Where-Object {$_.IdentifyingNumber -in $msiGuids}
if ($foundMsi)
	{
		Write-Host "SUCCESS: One of the required MSI GUIDs is present."
		exit 0
	}
else
	{
		Write-Host "FAIL: None of the MSI GUIDs found."
		exit 1
	} #>

<# # File Existence Check Example (Flag file)
$filepath = "$env:ProgramFiles\DummyApp\installed.flag"
if (Test-Path $filepath)
	{
		Write-Host "SUCCESS: DummyApp is installed."
		exit 0
	}
else
	{
		Write-Host "FAIL: DummyApp not found."
		exit 1
	} #>

<# # File Existence Check Example (Executable)
$filepath = "C:\Program Files\SomeApp\App.exe"
if (Test-Path $filepath)
	{
		Write-Host "SUCCESS: SomeApp's main executable is present."
		exit 0
	}
else
	{
		Write-Host "FAIL: SomeApp's executable missing."
		exit 1
	} #>

<# # Installation Date Check Example (File creation time)
$requiredDate = Get-Date "2024-01-01"
$appInstallPath = "C:\Program Files\SomeApp\App.exe"
if (Test-Path $appInstallPath)
	{
		$installTime = (Get-Item $appInstallPath).CreationTime
		if ($installTime -ge $requiredDate)
			{
				Write-Host "SUCCESS: Installation date is after required."
				exit 0
			}
		else
			{
				Write-Host "FAIL: Installed before required date."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: App not found."
		exit 1
	} #>

<# # Registry InstallDate Check Example (Registry value)
$regPath = "HKLM:\Software\Company\App"
$installKey = Get-ItemProperty -Path $regPath -Name "InstallDate" -ErrorAction SilentlyContinue
if ($installKey)
	{
		if ( ($installKey.InstallDate | Get-Date).AddDays(0) -ge (Get-Date "2024-01-01") )
			{
				Write-Host "SUCCESS: Install date is recent."
				exit 0
			}
		else
			{
				Write-Host "FAIL: Install date too old."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: InstallDate key not found."
		exit 1
	} #>

<# # Application Version Check Example (Executable version)
$requiredVersion = [version]"2.5.1"
$appPath = "C:\Program Files\SomeApp\App.exe"
if (Test-Path $appPath)
	{
		$installedVersion = (Get-Item $appPath).VersionInfo.FileVersionRaw
		if ($installedVersion -ge $requiredVersion)
			{
				Write-Host "SUCCESS: App version meets requirement."
				exit 0
			}
		else
			{
				Write-Host "FAIL: App version too low."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: App not found."
		exit 1
	} #>

<# # Registry Version Check Example (Registry value)
$regPath = "HKLM:\Software\Company\App"
$requiredVersion = [System.Version]"3.2.0"
$installedKey = Get-ItemProperty -Path $regPath -Name "AppVersion" -ErrorAction SilentlyContinue
if ($installedKey)
	{
		if ([System.Version]::Parse($installedKey.AppVersion) -ge $requiredVersion)
			{
				Write-Host "SUCCESS: Registry version meets requirement."
				exit 0
			}
		else
			{
				Write-Host "FAIL: Registry version too low."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: Registry key not found."
		exit 1
	} #>

<# # Service Status Check Example (Service running)
$serviceName = "SomeService"
$serviceStatus = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($serviceStatus)
	{
		if ($serviceStatus.Status -eq 'Running')
			{
				Write-Host "SUCCESS: Service is running."
				exit 0
			}
		else
			{
				Write-Host "FAIL: Service not running."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: Service not found."
		exit 1
	} #>

<# # Registry Key Existence Example (Key present)
$regPath = "HKLM:\Software\Company\App"
if (Test-Path $regPath)
	{
		Write-Host "SUCCESS: Registry key found."
		exit 0
	}
else
	{
		Write-Host "FAIL: Registry key missing."
		exit 1
	} #>

<# # File Content Check Example (Config contains setting)
$filepath = "C:\Program Files\SomeApp\Config.cfg"
if (Test-Path $filepath)
	{
		if ( (Get-Content $filepath | Select-String -Pattern "Setting=Enabled") )
			{
				Write-Host "SUCCESS: Config contains required setting."
				exit 0
			}
		else
			{
				Write-Host "FAIL: Config missing required setting."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: Config file not found."
		exit 1
	} #>

<# # Registry Value Content Check Example (String contains setting)
$regKey = Get-ItemProperty -Path "HKLM:\Software\Company\App" -Name "ConfigString" -ErrorAction SilentlyContinue
if ($regKey)
	{
		if ($regKey.ConfigString -like "*RequiredSetting*")
			{
				Write-Host "SUCCESS: Config string contains required setting."
				exit 0
			}
		else
			{
				Write-Host "FAIL: Config string missing required setting."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: Registry key not found."
		exit 1
	} #>

<# # File Size Check Example (Minimum size)
$requiredSizeInBytes = 1048576 # e.g., 1 MB
$filePath = "C:\Program Files\SomeApp\App.exe"
if (Test-Path $filePath)
	{
		if ((Get-Item $filePath).Length -ge $requiredSizeInBytes)
		{
			Write-Host "SUCCESS: File size is sufficient."
			exit 0
		}
		else
			{
				Write-Host "FAIL: File size too small."
				exit 1
			}
	}
else
	{
		Write-Host "FAIL: File not found."
		exit 1
	}
 #>