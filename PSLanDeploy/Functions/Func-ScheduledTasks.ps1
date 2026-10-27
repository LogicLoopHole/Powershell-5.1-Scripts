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

# Func-ScheduledTasks.ps1
#
# The task runs as NT AUTHORITY\SYSTEM (LogonType ServiceAccount). No password is supplied, so nothing
# is stored in the target's Credential Manager. SYSTEM runs the already-staged LOCAL package, so it
# needs no network/share rights of its own.

function Test-ExistingScheduledTask
	{
		param(
				[string]$Hostname,
				[pscredential]$Credential,
				[string]$TaskName = "PSADT_Install",
				[string]$TaskPath = "\"
			)

		try
			{
				$ic = @{ ComputerName = $Hostname; ErrorAction = 'Stop' }
				if ($Credential) { $ic['Credential'] = $Credential }

				$result = Invoke-Command @ic -ScriptBlock {
						param([string]$TaskName, [string]$TaskPath)

						Import-Module ScheduledTasks -ErrorAction SilentlyContinue
						$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
						if (-not $task) { return [pscustomobject]@{ Exists = $false; Stale = $false } }

						$info	 = $task | Get-ScheduledTaskInfo
						$running = [string]$task.State -in 'Running', 'Queued'
						if (-not $running)
							{
								# Stale: the run died (reboot, time limit, launch failure) before its
								# self-delete action ran. Clear it so this host can be resent.
								Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
							}
						return [pscustomobject]@{
								Exists		  = $running
								Stale		  = -not $running
								LastTaskResult = $info.LastTaskResult
								LastRunTime	= $info.LastRunTime
							}
					} -ArgumentList $TaskName, $TaskPath

				if ($result.Stale)
					{
						Write-Log "Removed stale $TaskName task on $Hostname (last result $($result.LastTaskResult), last run $($result.LastRunTime)); will resend" -Level WARN
					}
				return [bool]$result.Exists
			}
		catch
			{
				$errorMessage = $_.Exception.Message
				Write-Log ("Failed to check existing task on " + $Hostname + ": " + $errorMessage) -Level WARN
				return $false	# Assume no existing task on error
			}
	}

function Create-ScheduledTask
	{
		param(
				[string]$Hostname,
				[pscredential]$Credential,
				[psobject]$TaskConfig
			)

		try
			{
				$ic = @{ ComputerName = $Hostname; ErrorAction = 'Stop' }
				if ($Credential) { $ic['Credential'] = $Credential }

				$remote = Invoke-Command @ic -ScriptBlock {
						param([pscustomobject] $TaskConfig)

						Import-Module ScheduledTasks -ErrorAction Stop

						# Action 1: run the locally-staged PSADT script.
						# Action 2: delete the staged package, then delete the task. Both run as SYSTEM
						# from cmd.exe (System32), after Action 1 has finished and released its files,
						# so the staging folder is no longer in use. The '&' means the task still
						# self-deletes even if the folder removal fails (a leftover is caught next run).
						$cleanup = "/c rmdir /S /Q `"$($TaskConfig.StagingPath)`" & schtasks.exe /Delete /TN `"$($TaskConfig.Path)$($TaskConfig.Name)`" /F"
						$TaskActions = @(
								New-ScheduledTaskAction -Execute $TaskConfig.PrimaryScriptPath
								New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cleanup
							)

						$TaskTrigger = New-ScheduledTaskTrigger -Once -At $TaskConfig.TriggerTime

						$TaskSettings = New-ScheduledTaskSettingsSet `
							-Compatibility Win8 `
							-Hidden:$true `
							-AllowStartIfOnBatteries `
							-DontStopIfGoingOnBatteries `
							-ExecutionTimeLimit (New-TimeSpan -Hours 2)

						# Run as SYSTEM: no password, nothing stored on the endpoint.
						$TaskPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

						if (Get-ScheduledTask -TaskName $TaskConfig.Name -TaskPath $TaskConfig.Path -ErrorAction SilentlyContinue)
							{
								Write-Warning "Existing Scheduled Task Detected on $using:Hostname! Skipping."
								return @{ Success = $false; Message = "Task already exists" }
							}

						Register-ScheduledTask `
							-TaskName $TaskConfig.Name `
							-TaskPath $TaskConfig.Path `
							-Action $TaskActions `
							-Trigger $TaskTrigger `
							-Settings $TaskSettings `
							-Principal $TaskPrincipal `
							-Description $TaskConfig.Description | Out-Null

						Start-ScheduledTask -TaskName $TaskConfig.Name -TaskPath $TaskConfig.Path | Out-Null

						$taskInfo = Get-ScheduledTask -TaskName $TaskConfig.Name -TaskPath $TaskConfig.Path
						return @{ Success = $true; TaskName = $taskInfo.TaskName; State = [string]$taskInfo.State }
					} -ArgumentList $TaskConfig

				if (-not $remote.Success)
					{
						Write-Log ("Task not created on " + $Hostname + ": " + $remote.Message) -Level WARN
						return @{ Success = $false; Message = $remote.Message }
					}

				Write-Log "Successfully created scheduled task on $Hostname"
				return @{ Success = $true; Message = "Task created successfully" }
			} #end try
		catch
			{
				$errorMessage = $_.Exception.Message
				Write-Log ("Failed to create scheduled task on " + $Hostname + ": " + $errorMessage) -Level ERROR
				return @{ Success = $false; Message = $errorMessage }
			}
	}
