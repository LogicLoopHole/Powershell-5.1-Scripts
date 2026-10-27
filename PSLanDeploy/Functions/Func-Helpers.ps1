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

		# Color-coded console output. ERROR uses a red Write-Host, not Write-Error, so a log line
		# doesn't print a full exception block (At <script>:<line> char, CategoryInfo, etc.).
		switch ($Level)
			{
				"WARN"  { Write-Host $Message -ForegroundColor Yellow }
				"ERROR" { Write-Host $Message -ForegroundColor Red }
				default { Write-Host $Message }
			}
	}

# Build the admin-share path for a client-local path: C:\Program Files\X -> \\host\C$\Program Files\X
function Get-AdminSharePath
	{
		param(
			[string]$Hostname,
			[string]$LocalPath
		)
		"\\$Hostname\" + ($LocalPath -replace '^([A-Za-z]):', '$1$')
	}

function Get-TargetStatus
	{
		param (
			[string]$Hostname,
			[pscredential]$Credential
		)

		if ( -not (Test-Connection -ComputerName $Hostname -Count 1 -Quiet -ErrorAction SilentlyContinue) )
			{
				return "Offline"
			}

		try
			{
				Test-WSMan -ComputerName $Hostname -ErrorAction Stop | Out-Null

				# Safe guard: only workstations pass (Win32_OperatingSystem.ProductType 1).
				$ic = @{ ComputerName = $Hostname; ErrorAction = 'Stop' }
				if ($Credential) { $ic['Credential'] = $Credential }
				$productType = Invoke-Command @ic -ScriptBlock { (Get-CimInstance -ClassName Win32_OperatingSystem).ProductType }

				if ($productType -ne 1)
					{
						Write-Log "$Hostname is not a workstation (ProductType $productType), marking as unsafe" -Level WARN
						return "Server OS"
					}
				return "Online"
			}
		catch
			{
				Write-Log "$Hostname connection/OS check failed: $($_.Exception.Message)" -Level WARN
				return "WinRM Issue"
			}
	}

# Run robocopy and return its exit code. One implementation, used for both the performance-check core
# copy and the full payload copy; the only difference between the two is the arguments passed in.
#
# It opens robocopy in its own window (the v2 behavior) so the copy and any error are visible while they
# happen. Two details keep it reliable, and both trace to the exit-16 bug in the first v4 test run:
#   - The command line is built as ONE pre-quoted string and passed to -ArgumentList. An argument ARRAY is
#     the exit-16 cause: PowerShell 5.1 joins array elements and re-quotes them unreliably, which splits a
#     spaced path like C:\Program Files\PSLanDeploy into two tokens. A single string is forwarded verbatim.
#   - -Wait gives a completed process and a trustworthy LastExitCode. An earlier attempt without it read a
#     null exit code and silently passed a failed copy, so the wait stays.
function Invoke-Robocopy
	{
		param(
			[string]$Source,
			[string]$DestClient,
			[string[]]$ExtraArgs
		)

		# robocopy argument order: source, destination, then switches. Only quoted when it contains a space,
		# so bare switches and switch-prefixed values (e.g. /XD, C:\...\Files) reach robocopy exactly as given
		# and spaced paths arrive as a single quoted token.
		$parts = @()
		if ($Source -match ' ') { $parts += '"' + $Source + '"' } else { $parts += $Source }
		if ($DestClient -match ' ') { $parts += '"' + $DestClient + '"' } else { $parts += $DestClient }
		$parts += $ExtraArgs
		$argLine = $parts -join ' '

		$proc = Start-Process robocopy.exe -ArgumentList $argLine -Wait -PassThru
		Write-Host "robocopy exit code: $($proc.ExitCode)"
		return $proc.ExitCode
	}

# Remove a client's staged package over the admin share (run as the orchestrator's account). Backstop
# for the task's own cleanup; this catches a stage left behind when a run died before cleaning up.
function Remove-ClientStage
	{
		param([string]$DestClient)
		if (Test-Path $DestClient)
			{
				Remove-Item $DestClient -Recurse -Force -ErrorAction SilentlyContinue
			}
	}
