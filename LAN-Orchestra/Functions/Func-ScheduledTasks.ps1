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

# Func-ScheduledTasks.ps1

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
				$result = Invoke-Command -ComputerName $Hostname -Credential $Credential -ErrorAction Stop -ScriptBlock {
						param([string]$TaskName, [string]$TaskPath)
						
						Import-Module ScheduledTasks -ErrorAction SilentlyContinue
						$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
						return [bool]$task
					} -ArgumentList $TaskName, $TaskPath
				
				return $result
			}
		catch
			{
				$errorMessage = $_.Exception.Message
				Write-Log ("Failed to check existing task on " + $Hostname + ": " + $errorMessage) -Level WARN
				return $false  # Assume no existing task on error
			}
	}

function Create-ScheduledTask
	{
		param(
				[string]$Hostname,
				[pscredential]$Credential,
				[psobject]$TaskConfig,
				[string]$RunAsUser,
				[securestring]$RunAsPassword
			)
		
		try
			{
				Invoke-Command -ComputerName $Hostname -Credential $Credential -ErrorAction Stop -ScriptBlock {
						param(
								[pscustomobject] $TaskConfig,
								[string] $TaskRunAsUser,
								[securestring] $TaskRunAsSecurePassword
							)
						
						Import-Module ScheduledTasks -ErrorAction Stop
						
						# Create actions: run PSADT script, then delete the task
						$TaskActions = @(
								New-ScheduledTaskAction -Execute $TaskConfig.PrimaryScriptPath
								New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c schtasks.exe /Delete /TN `"$($TaskConfig.Path)$($TaskConfig.Name)`" /F"
							)
						
						# Create trigger for near-immediate execution
						$TaskTrigger = New-ScheduledTaskTrigger -Once -At $TaskConfig.TriggerTime
						
						# Task settings - run with high privileges, no execution time limit
						$TaskSettings = New-ScheduledTaskSettingsSet `
							-Compatibility Win8 `
							-Hidden:$true `
							-AllowStartIfOnBatteries `
							-DontStopIfGoingOnBatteries `
							-ExecutionTimeLimit (New-TimeSpan -Hours 2)
							
						# Check if task already exists
						if (Get-ScheduledTask -TaskName $TaskConfig.Name -TaskPath $TaskConfig.Path -ErrorAction SilentlyContinue)
							{
								Write-Warning "Existing Scheduled Task Detected on $using:Hostname! Skipping."
								return @{
										Success = $false
										Message = "Task already exists"
									}
							}
						
						# Convert secure password for task registration
						$taskPasswordPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TaskRunAsSecurePassword)
						try
							{
								Register-ScheduledTask `
									-TaskName $TaskConfig.Name `
									-TaskPath $TaskConfig.Path `
									-Action $TaskActions `
									-Trigger $TaskTrigger `
									-Settings $TaskSettings `
									-Description $TaskConfig.Description `
									-User $TaskRunAsUser `
									-Password ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($taskPasswordPtr)) `
									-RunLevel Highest

								# Start the task immediately
								Start-ScheduledTask -TaskName $TaskConfig.Name -TaskPath $TaskConfig.Path
								
								# Return success information
								$taskInfo = Get-ScheduledTask -TaskName $TaskConfig.Name -TaskPath $TaskConfig.Path
								return @{
										Success = $true
										TaskName = $taskInfo.TaskName
										State = $taskInfo.State
									}
							}
						finally
							{
								if ($taskPasswordPtr -ne [IntPtr]::Zero)
									{ 
										[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($taskPasswordPtr) 
									}
							}
					} -ArgumentList $TaskConfig, $RunAsUser, $RunAsPassword
				
				Write-Log "Successfully created scheduled task on $Hostname"
				return @{
						Success = $true
						Message = "Task created successfully"
					}
			} #end try
		catch
			{
				$errorMessage = $_.Exception.Message
				Write-Log ("Failed to create scheduled task on " + $Hostname + ": " + $errorMessage) -Level ERROR
				return @{
						Success = $false
						Message = $errorMessage
					}
			}
	}