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

# Start-PSLanDeploy.ps1  (PSLanDeploy, v4)
# Server-side push model: stage the package to each workstation, then run it there as SYSTEM via a
# self-deleting scheduled task. Detection runs over WinRM as a passive pre-check; the push runs as
# the account you launched this script with (expected to be admin on the clients, as in v2).
#
# Run this from the deployment server in an interactive session as the client-admin domain account.
# That account's logon supplies the rights for the WinRM detection and the robocopy push, so no
# password is prompted or stored by default. Supply -Credential only if the console account is NOT
# the account that should reach the clients.

param (
	[string]$UNCAppDir = "\\Example.Domain\ExampleShare\TestDummyAppUNC",
	[ValidateSet("Install","Uninstall")]
	[string]$Action = "Install",
	[pscredential]$Credential,								# optional; omitted = use the logged-on identity
	[string]$StagingRoot = "C:\Program Files\PSLanDeploy",	# client-local staging folder (default-safe ACL)
	[int]$PerfCheckBudgetSec = 60							# core-copy time budget; slower hosts are skipped and retried
)
$ScriptPath	= Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataPath = Join-Path $ScriptPath "Data"
$TargetsFile = Join-Path $ScriptPath "Target-Devices.txt"
$TrackingDBPath = Join-Path $DataPath "Tracking-DB.json"
$LogFile = Join-Path $DataPath "Console-Output.log"
$DeployInstallScript = "install_silent.cmd"
$DeployUninstallScript = "uninstall_silent.cmd"
$DetectionScript = "SupportFiles\Detection-Method.ps1"

# Load helper functions (dot-sourced for simplicity)
. "$ScriptPath\Functions\Func-Helpers.ps1"
. "$ScriptPath\Functions\Func-ScheduledTasks.ps1"
. "$ScriptPath\Functions\Func-StateManagement.ps1"

Add-ProgressBuffer -Lines 8
Write-Log "PSLanDeploy Orchestrator started"
Write-Log "Desired Action: $Action"
if ($Credential) { Write-Log "Using supplied credential: $($Credential.UserName)" }
else			 { Write-Log "Using logged-on identity: $env:USERDOMAIN\$env:USERNAME" }

$HostResults = Load-State -TrackingDBPath $TrackingDBPath

# Safety net for the one-Data-folder-per-run workflow: refuse to mix an Uninstall into an Install
# folder (or vice versa). Rename/clear the Data folder to switch actions. Delete this block if you
# deliberately want to reuse one folder across actions.
$otherAction = @($HostResults.Values | Where-Object { $_.DesiredAction -and $_.DesiredAction -ne $Action })
if ($otherAction.Count -gt 0)
	{
		Write-Log "Data folder holds $($otherAction.Count) record(s) from a '$($otherAction[0].DesiredAction)' run. Rename or clear Data before running '$Action'." -Level ERROR
		exit 1
	}

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
# Wrap so a crash (exit 2) or a script that never calls exit (exit 3) can't be read as present(0)/absent(1).
$wrappedDetection = "try {`r`n$detectionCode`r`n} catch { exit 2 }`r`nexit 3"
$scriptBase64 = [Convert]::ToBase64String( [Text.Encoding]::Unicode.GetBytes($wrappedDetection) )

# Validate a supplied credential against the domain (needs no rights on any particular machine).
# With no -Credential we run as the logged-on user, which is already a valid session.
if ($Credential)
	{
		try
			{
				Add-Type -AssemblyName System.DirectoryServices.AccountManagement
				$nc = $Credential.GetNetworkCredential()
				$ctxArgs = if ($nc.Domain) { @('Domain', $nc.Domain) } else { @('Domain') }
				$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList $ctxArgs
				$credsValid = $ctx.ValidateCredentials($nc.UserName, $nc.Password)
				$ctx.Dispose()
			}
		catch
			{
				Write-Log "Could not validate credentials against the domain: $($_.Exception.Message)" -Level ERROR
				exit 1
			}
		if (-not $credsValid)
			{
				Write-Log "Domain rejected the password for $($Credential.UserName). Exiting." -Level ERROR
				exit 1
			}
		Write-Log "Credential validation successful"
	}

foreach ($Hostname in $Targets)
	{
		$Progress++
		Write-Progress -Activity "Processing targets" -Status $Hostname -PercentComplete ( ($Progress / $TotalTargets) * 100)

		# Decide skips from the PREVIOUS record, before we stamp this run's action/package onto it.
		$prev = $HostResults[$Hostname]
		if ($prev -and $prev.JobStatus -eq "Completed" -and $prev.DesiredAction -eq $Action -and $prev.Package -eq $UNCAppDir)
			{
				Write-Log "Skipping $Hostname (already completed $Action of this package)"
				continue
			}

		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ DesiredAction = $Action; Package = $UNCAppDir } -TrackingDBPath $TrackingDBPath

		$status = Get-TargetStatus -Hostname $Hostname -Credential $Credential
		$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ ComputerStatus = $status } -TrackingDBPath $TrackingDBPath
		if ($status -ne "Online")
			{
				Write-Log "Skipping $Hostname ($status)"
				continue
			}

		$clientStageUNC	= Get-AdminSharePath -Hostname $Hostname -LocalPath $StagingRoot
		$scriptToRun	= if ($Action -eq "Install") { $DeployInstallScript } else { $DeployUninstallScript }
		$clientScriptLocal = Join-Path $StagingRoot $scriptToRun		# path the SYSTEM task runs on the client
		$clientScriptUNC   = Join-Path $clientStageUNC $scriptToRun	# same file, seen from the server for verification

		# --- Passive detection gate: no files are copied if the host already meets the desired state ---
		try
			{
				Write-Log "Running pre-deployment detection on $Hostname"
				$ic = @{ ComputerName = $Hostname; HideComputerName = $true; ErrorAction = 'Stop' }
				if ($Credential) { $ic['Credential'] = $Credential }
				$exitCode = Invoke-Command @ic -ScriptBlock {
						param($scriptBase64)
						$proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $scriptBase64 -PassThru -Wait -NoNewWindow
						return [int]$proc.ExitCode
					} -ArgumentList $scriptBase64
				if ($exitCode -ne 0 -and $exitCode -ne 1)
					{
						throw "Detection gave no verdict (exit code '$exitCode'; 2 = script error, 3 = script never called exit)"
					}
				$present = ($exitCode -eq 0)
				Write-Log "Pre-detection: Host=$Hostname Present=$present (Action=$Action)"
				$preSet = if ( ($Action -eq "Install" -and $present) -or ($Action -eq "Uninstall" -and -not $present) ) { "Pass" } else { "Fail" }
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ PreDeployDetect = $preSet } -TrackingDBPath $TrackingDBPath

				if ( ($Action -eq "Install" -and $present) -or ($Action -eq "Uninstall" -and -not $present) )
					{
						Write-Log "$Hostname already meets desired state for $Action; marking as completed"
						Remove-ClientStage -DestClient $clientStageUNC	# tidy any leftover stage from a prior run
						$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
								JobStatus		 = "Completed"
								PostDeployDetect  = "Pass"
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
				continue	# an Unknown host is left for the next run rather than deployed blind
			}

		$currentRecord = $HostResults[$Hostname]
		$attemptCount  = [int]($currentRecord.AttemptCount)

		# --- Don't stack a second task on top of a running one ---
		$taskName = if ($Action -eq "Install") { "PSADT_Install" } else { "PSADT_Uninstall" }
		if (Test-ExistingScheduledTask -Hostname $Hostname -Credential $Credential -TaskName $taskName)
			{
				Write-Log "Existing scheduled task detected on $Hostname, marking as InProgress" -Level WARN
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{ JobStatus = "InProgress" } -TrackingDBPath $TrackingDBPath
				continue
			}

		# --- Performance check: copy the package CORE (Files excluded) and time it. The core is the
		#     first stage of the real copy, so nothing here is wasted; a host that takes too long is
		#     skipped and retried next run. robocopy output is visible as it runs. ---
		$filesDir = Join-Path $UNCAppDir "Files"
		Write-Log "Staging core to $Hostname (performance check)"
		$coreStart = Get-Date
		$coreExit  = Invoke-Robocopy -Source $UNCAppDir -DestClient $clientStageUNC -ExtraArgs @('/E','/XD',$filesDir,'/R:1','/W:1','/MT:8')
		$coreSecs  = [math]::Round(((Get-Date) - $coreStart).TotalSeconds, 1)
		if ($coreExit -ge 8)
			{
				Write-Log "$Hostname core copy failed (robocopy exit $coreExit, ${coreSecs}s); see robocopy output above" -Level ERROR
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						JobStatus	   = "Failed"
						LastErrorDetail = "robocopy core copy exit $coreExit"
					} -TrackingDBPath $TrackingDBPath
				continue
			}
		if ($coreSecs -gt $PerfCheckBudgetSec)
			{
				Write-Log "$Hostname too slow (core took ${coreSecs}s, budget ${PerfCheckBudgetSec}s); skipping, will retry next run" -Level WARN
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						ComputerStatus  = "Performance"
						LastErrorDetail = "core copy ${coreSecs}s exceeded ${PerfCheckBudgetSec}s budget"
					} -TrackingDBPath $TrackingDBPath
				continue
			}
		Write-Log "$Hostname core staged in ${coreSecs}s; sending payload"

		# --- Full send: the rest of the package, including the Files payload (robocopy output visible). ---
		$pushExit = Invoke-Robocopy -Source $UNCAppDir -DestClient $clientStageUNC -ExtraArgs @('/E','/R:2','/W:5','/MT:8')
		if ($pushExit -ge 8)
			{
				Write-Log "$Hostname payload push failed (robocopy exit $pushExit); see robocopy output above" -Level ERROR
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						JobStatus	   = "Failed"
						LastErrorDetail = "robocopy payload push exit $pushExit"
					} -TrackingDBPath $TrackingDBPath
				continue
			}
		if ( -not (Test-Path $clientScriptUNC) )
			{
				Write-Log "$Hostname staged package is missing $scriptToRun after push" -Level ERROR
				$HostResults = Update-HostResults -CurrentState $HostResults -Hostname $Hostname -UpdateData @{
						JobStatus	   = "Failed"
						LastErrorDetail = "Staged package missing $scriptToRun"
					} -TrackingDBPath $TrackingDBPath
				continue
			}

		# --- Create the SYSTEM task that runs the locally-staged package ---
		$TaskConfig = [pscustomobject]@{
				Name			  = $taskName
				Description	   = "PSLanDeploy PSADT Scheduled Task - Runs $Action as SYSTEM then removes itself"
				PrimaryScriptPath = $clientScriptLocal
				StagingPath	   = $StagingRoot	# task removes this folder after running (cleanup)
				TriggerTime	   = (Get-Date).AddSeconds(30)
				Path			  = '\'
			}
		$taskResult = Create-ScheduledTask -Hostname $Hostname -Credential $Credential -TaskConfig $TaskConfig
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
Write-Log "Run this script again in an hour or so to confirm deployment status via detection."
