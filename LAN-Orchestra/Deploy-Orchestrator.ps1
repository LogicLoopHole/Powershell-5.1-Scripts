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
# Entry script that coordinates install/uninstall actions per target using Scheduled Tasks

param (
	[string]$UNCAppDir = "\\Example.Domain\ExampleShare\TestDummyAppUNC",
	[ValidateSet("Install","Uninstall")]
	[string]$Action = "Install",
	[pscredential]$Credential = (Get-Credential -Message "Enter domain credentials for scheduled task execution" -UserName "$env:USERDOMAIN\$env:USERNAME")
)
$ScriptPath	= Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataPath = Join-Path $ScriptPath "Data"
$TargetsFile = Join-Path $ScriptPath "Target-Devices.txt"
$TrackingDBPath = Join-Path $DataPath "Tracking-DB.json"
$LogFile = Join-Path $DataPath "Console-Output.log"
$DeployInstallScript = "install_silent.cmd"
$DeployUninstallScript = "uninstall_silent.cmd"
$DetectionScript = "SupportFiles\Detection-Method.ps1"
$SupportsConvertFromJsonDepth = (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue).Parameters.ContainsKey('Depth')
$SupportsConvertToJsonDepth = (Get-Command ConvertTo-Json   -ErrorAction SilentlyContinue).Parameters.ContainsKey('Depth')

# Load helper functions (dot-sourced for simplicity)
. "$ScriptPath\Functions\Func-Helpers.ps1"
. "$ScriptPath\Functions\Func-ScheduledTasks.ps1"
. "$ScriptPath\Functions\Func-StateManagement.ps1"

Add-ProgressBuffer -Lines 8
Write-Log "PSADT Deployment Orchestrator started"
Write-Log "Desired Action: $Action"

$HostResults = Load-State -TrackingDBPath $TrackingDBPath
$Targets = if (Test-Path $TargetsFile) { Get-Content -Path $TargetsFile | Where-Object { $_ -and $_.Trim() } } else { @() }

if ($Targets.Count -eq 0)
	{
		Write-Log "No targets found in $TargetsFile" -Level WARN
		return
	}
$Progress = 0
$TotalTargets  = $Targets.Count
Write-Log "Processing $TotalTargets targets with $($HostResults.Count) existing records"
$detectionScriptPath = Join-Path $UNCAppDir $DetectionScript
if ( -not (Test-Path $detectionScriptPath) )
	{
		Write-Log "Detection script not found: $detectionScriptPath" -Level ERROR
		exit 1
	}
$detectionCode = Get-Content -Path $detectionScriptPath -Raw
try
	{
		Invoke-Command -ComputerName localhost -Credential $Credential -ErrorAction Stop -ScriptBlock { Get-Date } | Out-Null
		Write-Log "Credential validation successful"
	}
catch
	{
		Write-Log "Credentials failed local validation. Exiting." -Level ERROR
		exit 1
	}

foreach ($Hostname in $Targets)
	{
		$Progress++
		Write-Progress -Activity "Processing targets" -Status $Hostname -PercentComplete ( ($Progress / $TotalTargets) * 100)
		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ DesiredAction = $Action } -TrackingDBPath $TrackingDBPath
		$record = $HostResults[$Hostname]
		if ($record.JobStatus -eq "Completed" -and $record.DesiredAction -eq $Action)
			{
				Write-Log "Skipping $Hostname (already completed $Action successfully)"
				continue
			}
		if ($record.PostDeployDetect -eq "Pass" -and $record.DesiredAction -eq $Action)
			{
				Write-Log "Skipping $Hostname (already achieved desired state for $Action)"
				continue
			}
		$status = Get-TargetStatus -Hostname $Hostname
		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ ComputerStatus = $status } -TrackingDBPath $TrackingDBPath
		if ($status -ne "Online")
			{
				Write-Log "Skipping $Hostname ($status)"
				continue
			}
		try
			{
				Write-Log "Running pre-deployment detection on $Hostname"
				$exitCode = try {
						$scriptBase64 = [Convert]::ToBase64String( [Text.Encoding]::Unicode.GetBytes($detectionCode) )						
						Invoke-Command -ComputerName $Hostname -HideComputerName -Credential $Credential {
								param($scriptBase64)
								$proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $scriptBase64 -PassThru -Wait -NoNewWindow
								return [int]$proc.ExitCode
							} -ArgumentList $scriptBase64
					} #end: try
				catch
					{
						$errorMessage = $_.Exception.Message
						Write-Log "Pre-detection failed on $Hostname : $errorMessage" -Level WARN
						99
					}
				$present  = ($exitCode -eq 0)
				Write-Log "Pre-detection: Host=$Hostname Present=$present (Action=$Action)"
				$preSet = if ( ($Action -eq "Install" -and $present) -or ($Action -eq "Uninstall" -and -not $present) ) { "Pass" } else { "Fail" }
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						PreDeployDetect = $preSet
					} -TrackingDBPath $TrackingDBPath
				if ( ($Action -eq "Install" -and $present) -or ($Action -eq "Uninstall" -and -not $present) ) {
						Write-Log "$Hostname already meets desired state for $Action; marking as completed"
						$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
								JobStatus		 = "Completed"
								ReceivedTimestamp = (Get-Date).ToUniversalTime().ToString("o")
							} -TrackingDBPath $TrackingDBPath
						continue
					}
			}
		catch
			{
				$errorMessage = $_.Exception.Message
				Write-Log "Pre-detection failed on $Hostname : $errorMessage" -Level WARN
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						PreDeployDetect = "Unknown"
						LastErrorDetail = $errorMessage
					} -TrackingDBPath $TrackingDBPath
			}
		$currentRecord = $HostResults[$Hostname]
		$attemptCount  = [int]($currentRecord.AttemptCount)
		# $networkTest = Invoke-RemoteNetworkTest -UNCSource $UNCAppDir -Hostname $Hostname #Network speed test removed (deprecated)
		$taskName = if ($Action -eq "Install") { "PSADT_Install" } else { "PSADT_Uninstall" }
		if (Test-ExistingScheduledTask -Hostname $Hostname -Credential $Credential -TaskName $taskName)
			{
				Write-Log "Existing scheduled task detected on $Hostname, marking as InProgress" -Level WARN
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						JobStatus = "InProgress"
					} -TrackingDBPath $TrackingDBPath
				continue
			}
		$scriptToRun = if ($Action -eq "Install") { $DeployInstallScript } else { $DeployUninstallScript }
		$fullScriptPath = Join-Path $UNCAppDir $scriptToRun
		$TaskConfig = [pscustomobject]@{
				Name			  = $taskName
				Description	   = "LAN Orchestra PSADT Scheduled Task - Runs $Action then removes itself to cleanup"
				PrimaryScriptPath = $fullScriptPath
				TriggerTime	   = (Get-Date).AddSeconds(30)  # Start 30 seconds from now
				Path			  = '\'
			}
		$taskResult = Create-ScheduledTask -Hostname $Hostname -Credential $Credential -TaskConfig $TaskConfig -RunAsUser $Credential.UserName -RunAsPassword $Credential.Password
		if (-not $taskResult.Success)
			{
				Write-Log "$Hostname $Action task creation failed: $($taskResult.Message)" -Level ERROR
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						JobStatus	   = "Failed"
						LastErrorDetail = $taskResult.Message
					} -TrackingDBPath $TrackingDBPath
				continue
			}
		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
				JobStatus	   = "Sent"
				SentTimestamp   = (Get-Date).ToUniversalTime().ToString("o")
				AttemptCount	= $attemptCount + 1
				LastErrorDetail = ""
			} -TrackingDBPath $TrackingDBPath
		Write-Log "Successfully scheduled $Action task on $Hostname (Attempt #$($attemptCount + 1))"
	} #end: foreach ($Hostname in $Targets)
Write-Log "All $Action scheduling operations completed!"
Write-Log "Run this script again in an hour or so to check deployment status via detection."