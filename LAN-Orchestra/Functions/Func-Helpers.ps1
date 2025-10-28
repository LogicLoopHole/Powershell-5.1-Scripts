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

# Func-Helpers.ps1

function Ensure-ParentDirectory
	{
		param([string]$Path)

		$parent = Split-Path -Parent $Path
		if ($parent -and -not (Test-Path $parent) )
			{
				New-Item -ItemType Directory -Path $parent -Force | Out-Null
			}
	}

function Add-ProgressBuffer
	{
		param([int]$Lines = 8)
		if ($Host -and $Host.Name -like "*ISE*")
			{
				for ($i = 0; $i -lt $Lines; $i++) { Write-Host "" }
			}
	}

function Write-Log
	{
		param(
			[string]$Message,
			[ValidateSet("INFO","WARN","ERROR")]
			[string]$Level = "INFO"
		)

		if ( -not (Test-Path Variable:Global:LogFile -ErrorAction SilentlyContinue) )
			{
				$scriptRoot = Split-Path -Parent $PSScriptRoot
				if (-not $scriptRoot) { $scriptRoot = $PWD }
				$Global:LogFile = Join-Path $scriptRoot "Data\Console-Output.log"
			}

		Ensure-ParentDirectory -Path $Global:LogFile

		$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
		$formatted = "$timestamp $Level $env:COMPUTERNAME $Message"
		$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
		[System.IO.File]::AppendAllText($Global:LogFile, "$formatted`n", $utf8NoBom)

		switch ($Level)
			{
				"WARN"  { Write-Warning  $Message }
				"ERROR" { Write-Error	$Message }
				default { Write-Output   $Message }
			}
	}

function Get-TargetStatus
	{
		param ([string]$Hostname)

		if ( -not (Test-Connection -ComputerName $Hostname -Count 1 -Quiet -ErrorAction SilentlyContinue) )
			{
				return "Offline"
			}

		try
			{
				Test-WSMan -ComputerName $Hostname -ErrorAction Stop | Out-Null
				# Safe guard check if target is a server
				$osInfo = Invoke-Command -ComputerName $Hostname -ScriptBlock {
						Get-CimInstance -ClassName Win32_OperatingSystem
					} -ErrorAction Stop
					
				if ($osInfo.ProductType -eq 3)
					{
						Write-Warning "Target device $Hostname has server OS detected, marking as unsafe."
						return "Server OS"
					}
				return "Online"
			}
		catch
			{
				return "WinRM Issue"
			}
	}

#region [DEPRECATED FUNCTIONS - PLACEHOLDERS GO HERE]
function Invoke-RemoteNetworkTest {
	# This function was used to test network speed before deployment but is no longer needed.
	# Future concept of subnet block or file transfer based testing may be considered but are not planned.
	param(
		[string]$UNCSource,
		[string]$Hostname
	)
	
	# Placeholder - always return true since we're removing this check
	Write-Log "Network speed test skipped (deprecated function)" -Level WARN
	return $true
}
#endregion