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
# Deploy-Orchestrator-Helpers.ps1
# Utility functions used by Deploy-Orchestrator.ps1

#region [FILESYSTEM HELPERS]
function Ensure-ParentDirectory {
	param([string]$Path)

	$parent = Split-Path -Parent $Path
	if ($parent -and -not (Test-Path $parent)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
}
#endregion

#region [UTILS: PROGRESS BUFFER]
function Add-ProgressBuffer {
	param([int]$Lines = 8)
	if ($Host -and $Host.Name -like "*ISE*") {
		for ($i = 0; $i -lt $Lines; $i++) { Write-Host "" }
	}
}
#endregion

#region [UTILS: LOGGING]
function Write-Log {
	param(
		[string]$Message,
		[ValidateSet("INFO","WARN","ERROR")]
		[string]$Level = "INFO"
	)

	Ensure-ParentDirectory -Path $LogFile

	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$formatted = "$timestamp $Level $env:COMPUTERNAME $Message"
	$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::AppendAllText($LogFile, "$formatted`n", $utf8NoBom)

	switch ($Level) {
		"WARN"  { Write-Warning  $Message }
		"ERROR" { Write-Error	$Message }
		default { Write-Output   $Message }
	}
}
#endregion

#region [STATE MANAGEMENT]
function ConvertTo-Hashtable {
	param([object]$InputObject)

	if ($null -eq $InputObject) { return @{} }
	if ($InputObject -is [hashtable]) {
		$copy = @{}
		foreach ($k in $InputObject.Keys) { $copy[$k] = ConvertTo-Hashtable $InputObject[$k] }
		return $copy
	}
	if ($InputObject -is [psobject]) {
		$copy = @{}
		foreach ($p in $InputObject.PSObject.Properties) { $copy[$p.Name] = ConvertTo-Hashtable $p.Value }
		return $copy
	}
	if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
		return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
	}
	return $InputObject
}

function Load-State {
	Ensure-ParentDirectory -Path $TrackingDBPath

	if (-not (Test-Path $TrackingDBPath)) {
		return @{}
	}

	try {
		$content = Get-Content $TrackingDBPath -Raw
		if (-not $content.Trim()) { return @{} }

		$json	= if ($SupportsConvertFromJsonDepth) { $content | ConvertFrom-Json -Depth 20 } else { $content | ConvertFrom-Json }
		$results = ConvertTo-Hashtable $json
		if ($results -isnot [hashtable]) { return @{} }
		return $results
	} catch {
		Write-Log "Failed to parse Tracking-DB.json, starting fresh: $_" -Level WARN
		return @{}
	}
}

function Save-State {
	param([hashtable]$StateData)

	try {
		Ensure-ParentDirectory -Path $TrackingDBPath

		$psObj = New-Object PSObject
		foreach ($key in $StateData.Keys) {
			$psObj | Add-Member -MemberType NoteProperty -Name $key -Value $StateData[$key]
		}

		$json = if ($SupportsConvertToJsonDepth) { $psObj | ConvertTo-Json -Depth 10 } else { $psObj | ConvertTo-Json }
		$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
		[System.IO.File]::WriteAllText($TrackingDBPath, $json, $utf8NoBom)
	} catch {
		Write-Log "Failed to save Tracking-DB.json: $_" -Level ERROR
	}
}

function Update-HostResults {
	param(
		[hashtable]$CurrentState,
		[string]$Hostname,
		[hashtable]$UpdateData,
		[string]$DesiredAction = $null
	)

	if (-not $CurrentState.ContainsKey($Hostname)) {
		$CurrentState[$Hostname] = @{
			Hostname		 = $Hostname
			DesiredAction	= if ($DesiredAction) { $DesiredAction } else { $Action }
			ComputerStatus   = "Unknown"
			JobStatus		= "Queued"
			SentTimestamp	= ""
			ReceivedTimestamp= ""
			AttemptCount	 = 0
			ExitCode		 = $null
			PreDeployDetect  = "Unknown"
			PostDeployDetect = "Unknown"
			LastErrorDetail  = ""
		}
	}

	if ($DesiredAction) {
		$UpdateData["DesiredAction"] = $DesiredAction
	}

	foreach ($key in $UpdateData.Keys) {
		$CurrentState[$Hostname][$key] = $UpdateData[$key]
	}

	Save-State -StateData $CurrentState
	return $CurrentState
}
#endregion

#region [TARGET & DETECTION]
function Get-TargetStatus {
	param ([string]$Hostname)

	if (-not (Test-Connection -ComputerName $Hostname -Count 1 -Quiet -ErrorAction SilentlyContinue))
		{
			return "Offline"
		}

	try
		{
			Test-WSMan -ComputerName $Hostname -ErrorAction Stop | Out-Null
			#safe guard check if target is a server
			$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
			if ($osInfo.ProductType -eq 3)
				{
					Write-Warning "Target device has server OS detected, STOPPING script as safe guard."
					Pause
					exit
				}
			return "Online"
		}	
	catch
		{
			return "WinRM Issue"
		}
}

function Load-DetectionCode {
	param(
		[string]$AppRootUNC,
		[string]$RelDetectScript
	)

	$path = Join-Path $AppRootUNC $RelDetectScript
	try {
		if (Test-Path $path) {
			$code = Get-Content -Path $path -Raw -Encoding UTF8
			Write-Log "Loaded detection script from UNC: $path"
			return $code
		} else {
			Write-Log "Detection script not found at: $path" -Level WARN
			Pause
			exit
		}
	} catch {
		Write-Log "Failed to load detection script from $path : $($_.Exception.Message)" -Level WARN
		Pause
		exit
	}
}

function Invoke-RemoteDetection {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string]$Hostname,
		[Parameter(Mandatory)] [object]$ScriptContent,
		[int]$TimeoutSec = 90
	)

	if ($null -eq $ScriptContent) { $ScriptContent = "" }
	if ($ScriptContent -isnot [string]) {
		$ScriptContent = [string]::Join([Environment]::NewLine, @($ScriptContent))
	}
	if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
		Write-Log "No detection script content available to run on $Hostname" -Level WARN
		return 1
	}

	$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptContent))
	$job = Invoke-Command -ComputerName $Hostname -AsJob -ErrorAction Stop -ScriptBlock {
		param($b64)
		try {
			$proc = Start-Process -FilePath "powershell.exe" `
								  -ArgumentList "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",$b64 `
								  -Wait -PassThru -NoNewWindow
			[int]$proc.ExitCode
		} catch {
			99999
		}
	} -ArgumentList $encoded

	if (Wait-Job -Id $job.Id -Timeout $TimeoutSec) {
		try {
			$code = Receive-Job -Id $job.Id -ErrorAction Stop
			return [int]$code
		} finally {
			Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
		}
	} else {
		Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
		return 408
	}
}
#endregion

#region [DEPLOYMENT]
function Invoke-RemoteNetworkTest {
    param(
        [string]$UNCSource,
        [string]$Hostname
    )

    $sourceFolder = Join-Path -Path $UNCAppDir -ChildPath "PSAppDeployToolkit"
    $destBase = "C:\Windows\Temp"
    $destFolder = Join-Path -Path $destBase -ChildPath "PSAppDeployToolkit"
    if (Test-Path -Path $destFolder) {
        Remove-Item -Path $destFolder -Recurse -Force
    }

    # Robocopy command to copy from UNC to local temp dir
    $robocopyCommand = "robocopy '$sourceFolder' '$destFolder' /E /Z /MT:8 /R:3 /W:5 /NP /TEE"
    $netTestJob = Start-Job -ScriptBlock {
        param($cmd)
        Invoke-Expression $cmd
    } -ArgumentList $robocopyCommand

    # Wait for completion (timeout 6 seconds) or stop if too slow to avoid wasting bandwidth
    try {
        if (Wait-Job -Job $netTestJob -Timeout 6) {
            Receive-Job -Job $netTestJob | Out-Null
            Write-Host "Network speed test successfully completed"
            return $true
        } else {
            Stop-Job -Job $netTestJob
            Write-Warning "Slow Network Detected, PreDeployDetect is FailSlowNetwork"
            return $false
        }
    } catch {
        # If Wait-Job throws an error due to null job or other reasons
        Write-Warning "An unexpected error occurred: $_"
        return $false
    }

    # Cleanup temp folder after test (even if job failed)
    Remove-Item -Path $destFolder -Recurse -Force -ErrorAction SilentlyContinue
}

function Start-DeploymentJob {
	param (
		[string]$Hostname,
		[string]$UNCSource,
		[string]$Action,
		[string]$DeployInstallScript,
		[string]$DeployUninstallScript,
		[string]$DetectionCode
	)

	$timestampSuffix = Get-Date -Format "yyyyMMddHHmmssfff"
	$jobName		 = "Deploy_${Hostname}_$timestampSuffix"
	$tempName		= "PSADT_{0}_{1}" -f ($Hostname -replace '[^\w\-]','_'), $timestampSuffix
	$targetTempPath  = "C:\Windows\Temp\$tempName"
	$adminSharePath  = "\\$Hostname\C`$\Windows\Temp\$tempName"

	try {
		Invoke-Command -ComputerName $Hostname -ScriptBlock {
			param($Path)
			if (Test-Path $Path) {
				Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
			}
			New-Item -ItemType Directory -Path $Path -Force | Out-Null
		} -ArgumentList $targetTempPath -ErrorAction Stop

		$robocopyArgs = @($UNCSource, $adminSharePath, "/E", "/R:2", "/W:5")
		$proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru
		if ($proc.ExitCode -ge 8) { throw "Robocopy failed with exit code $($proc.ExitCode)" }
	} catch {
		return @{
			Outcome = "Failure"
			ExitCode = -1
			Message  = "File copy failed: $($_.Exception.Message)"
		}
	}

	$job = Invoke-Command -ComputerName $Hostname -AsJob -JobName $jobName -ScriptBlock {
		param($TempPath, $Action, $InstallScript, $UninstallScript, $DetCode)
		try {
			$deployScript = if ($Action -eq "Uninstall") { $UninstallScript } else { $InstallScript }
			$deployExe	= Join-Path $TempPath $deployScript
			if (-not (Test-Path $deployExe)) { throw "$deployScript not found in $TempPath" }

			$deployProc = Start-Process -FilePath $deployExe -Wait -NoNewWindow -PassThru
			$deployExit = $deployProc.ExitCode

			$presentAfter = $false
			if (-not [string]::IsNullOrWhiteSpace($DetCode)) {
				$encDetect = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($DetCode))
				$detectProc = Start-Process -FilePath "powershell.exe" `
											-ArgumentList "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",$encDetect `
											-Wait -PassThru -NoNewWindow
				$detectionExit = $detectProc.ExitCode
				$presentAfter  = ($detectionExit -eq 0)
			}

			return [pscustomobject]@{
				Outcome	  = "Success"
				ExitCode	 = $deployExit
				PresentAfter = $presentAfter
				Message	  = ""
			}
		} catch {
			return [pscustomobject]@{
				Outcome	  = "Failure"
				ExitCode	 = -1
				PresentAfter = $false
				Message	  = $_.Exception.Message
			}
		} finally {
			if (Test-Path $TempPath) {
				Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue
			}
		}
	} -ArgumentList $targetTempPath, $Action, $DeployInstallScript, $DeployUninstallScript, $DetectionCode -ErrorAction Stop

	return $job
}

function Process-CompletedJobs {
	param (
		[hashtable]$Jobs,
		[hashtable]$CurrentState,
		[string]$Action
	)

	if (-not $Jobs -or $Jobs.Count -eq 0) {
		return $CurrentState
	}

	$completedEntries = $Jobs.GetEnumerator() | Where-Object {
		$_.Value -and $_.Value.State -in @("Completed", "Failed", "Stopped")
	}

	foreach ($entry in $completedEntries) {
		$hostname = $entry.Key
		$job	  = $entry.Value

		try {
			$result = Receive-Job -Job $job -ErrorAction Stop
		} catch {
			$result = [pscustomobject]@{
				Outcome	  = "Failure"
				ExitCode	 = -1
				PresentAfter = $false
				Message	  = "Job receive failed: $($_.Exception.Message)"
			}
		} finally {
			Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
		}

		$postPass = $null
		if ($result.Outcome -eq "Success") {
			if ($Action -eq "Install") {
				$postPass = [bool]$result.PresentAfter
			} else {
				$postPass = -not [bool]$result.PresentAfter
			}
		}

		$updateData = @{
			JobStatus		 = if ($result.Outcome -eq "Success") { "Completed" } else { "Failed" }
			ReceivedTimestamp = (Get-Date).ToUniversalTime().ToString("o")
			ExitCode		  = $result.ExitCode
			LastErrorDetail   = $result.Message
		}

		if ($null -ne $postPass) {
			$updateData["PostDeployDetect"] = if ($postPass) { "Pass" } else { "Fail" }
		}

		$CurrentState = Update-HostResults -CurrentState $CurrentState -Hostname $hostname -UpdateData $updateData
		$Jobs.Remove($hostname)
	}

	return $CurrentState
}
#endregion