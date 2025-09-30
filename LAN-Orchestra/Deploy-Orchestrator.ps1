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

# Deploy-Orchestrator.ps1
# Entry script that coordinates install/uninstall actions per target

param (
	[string]$UNCAppDir = "\\Example.Domain\ExampleShare\TestDummyAppUNC",
	[ValidateSet("Install","Uninstall")]
	[string]$Action = "Install",
	[int]$MaxConcurrentJobs = 10,
	[int]$MaxRetries = 3,
	[int]$JobPollSeconds = 2
)

#region [GLOBAL PATHS]
$ScriptPath			= Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataPath			  = Join-Path $ScriptPath "Data"
$TargetsFile		   = Join-Path $ScriptPath "Target-Devices.txt"
$TrackingDBPath		= Join-Path $DataPath "Tracking-DB.json"
$LogFile			   = Join-Path $DataPath "Console-Output.log"
$DeployInstallScript   = "install_silent.cmd"
$DeployUninstallScript = "uninstall_silent.cmd"
$DetectionScript	   = "SupportFiles\Detection-Method.ps1"

if (-not (Test-Path $DataPath)) {
	New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
}
#endregion

#region [RUNTIME DEFAULTS]
$SupportsConvertFromJsonDepth = (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue).Parameters.ContainsKey('Depth')
$SupportsConvertToJsonDepth   = (Get-Command ConvertTo-Json   -ErrorAction SilentlyContinue).Parameters.ContainsKey('Depth')
$BatchThrottleMs = 200
$ActiveJobs	  = [hashtable]::Synchronized(@{})
#endregion

# Load helper functions (dot-sourced for simplicity)
. "$ScriptPath\Functions\Deploy-Orchestrator-Helpers.ps1"

#region [MAIN EXECUTION]
Add-ProgressBuffer -Lines 8
Write-Log "PSADT Deployment Orchestrator started"
Write-Log "Desired Action: $Action"

$HostResults = Load-State
$Targets	 = if (Test-Path $TargetsFile) {
	Get-Content -Path $TargetsFile | Where-Object { $_ -and $_.Trim() }
} else {
	@()
}

if ($Targets.Count -eq 0) {
	Write-Log "No targets found in $TargetsFile" -Level WARN
	return
}

$Progress	  = 0
$TotalTargets  = $Targets.Count
$DetectionCode = Load-DetectionCode -AppRootUNC $UNCAppDir -RelDetectScript $DetectionScript
Write-Log "Processing $TotalTargets targets with $($HostResults.Count) existing records"

foreach ($Hostname in $Targets) {
	$Progress++
	Write-Progress -Activity "Processing targets" -Status $Hostname -PercentComplete (($Progress / $TotalTargets) * 100)

	$HostResults = Process-CompletedJobs -Jobs $ActiveJobs -CurrentState $HostResults -Action $Action
	while ($ActiveJobs.Count -ge $MaxConcurrentJobs) {
		Start-Sleep -Seconds $JobPollSeconds
		$HostResults = Process-CompletedJobs -Jobs $ActiveJobs -CurrentState $HostResults -Action $Action
	}

	$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ DesiredAction = $Action }
	$record = $HostResults[$Hostname]

	if ($record.PostDeployDetect -eq "Pass" -and $record.DesiredAction -eq $Action) {
		Write-Log "Skipping $Hostname (already achieved desired state for $Action)"
		continue
	}

	$status = Get-TargetStatus -Hostname $Hostname
	$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ ComputerStatus = $status }
	if ($status -ne "Online") {
		Write-Log "Skipping $Hostname ($status)"
		continue
	}

	try {
		if ([string]::IsNullOrWhiteSpace($DetectionCode)) {
			Write-Log "No detection code loaded; skipping pre-detect on $Hostname" -Level WARN
		} else {
			Write-Log "Running pre-deployment detection on $Hostname"
			$exitCode = Invoke-RemoteDetection -Hostname $Hostname -ScriptContent $DetectionCode -TimeoutSec 90
			$present  = ($exitCode -eq 0)

			Write-Log "Pre-detection: Host=$Hostname Present=$present (Action=$Action)"
			$preSet = if (($Action -eq "Install" -and $present) -or ($Action -eq "Uninstall" -and -not $present)) { "Pass" } else { "Fail" }

			$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
				PreDeployDetect = $preSet
			}

			if (($Action -eq "Install" -and $present) -or ($Action -eq "Uninstall" -and -not $present)) {
				Write-Log "$Hostname already meets desired state for $Action; marking as completed"
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
					PostDeployDetect = "Pass"
					JobStatus		= "Completed"
					ReceivedTimestamp= (Get-Date).ToUniversalTime().ToString("o")
					ExitCode		 = 0
				}
				continue
			}
		}
	} catch {
		Write-Log "Pre-detection failed on $Hostname : $($_.Exception.Message)" -Level WARN
		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
			PreDeployDetect = "Unknown"
			LastErrorDetail = $_.Exception.Message
		}
	}

	$currentRecord = $HostResults[$Hostname]
	$attemptCount  = [int]($currentRecord.AttemptCount)
	if ($attemptCount -ge $MaxRetries -and $currentRecord.JobStatus -eq "Failed") {
		Write-Log "$Hostname exceeded max retries, skipping" -Level WARN
		continue
	}

	$job = Start-DeploymentJob -Hostname $Hostname `
							   -UNCSource $UNCAppDir `
							   -Action $Action `
							   -DeployInstallScript $DeployInstallScript `
							   -DeployUninstallScript $DeployUninstallScript `
							   -DetectionCode $DetectionCode

	if ($job -is [hashtable] -and $job.Outcome -eq "Failure") {
		Write-Log "$Hostname $Action initiation failed: $($job.Message)" -Level ERROR
		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
			JobStatus	   = "Failed"
			LastErrorDetail = $job.Message
		}
		continue
	}

	$ActiveJobs[$Hostname] = $job
	$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
		JobStatus	   = "Sent"
		SentTimestamp   = (Get-Date).ToUniversalTime().ToString("o")
		AttemptCount	= $attemptCount + 1
		LastErrorDetail = ""
	}

	Start-Sleep -Milliseconds (50 + (Get-Random -Minimum 0 -Maximum $BatchThrottleMs))
}

Write-Log "Waiting for all $Action operations to complete..."
do {
	$HostResults = Process-CompletedJobs -Jobs $ActiveJobs -CurrentState $HostResults -Action $Action
	if ($ActiveJobs.Count -gt 0) { Start-Sleep -Seconds $JobPollSeconds }
} while ($ActiveJobs.Count -gt 0)

Write-Log "All $Action operations completed"

#endregion
