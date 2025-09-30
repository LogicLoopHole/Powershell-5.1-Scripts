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

<#
.SYNOPSIS
	Displays current status of orchestrated deployments in a searchable GridView window.
.DESCRIPTION
	Pulls tracking data from Tracking-DB.json and renders an Out-GridView report
	showing deployment statuses across targets.
#>

#region [GLOBALS]
$ScriptPath   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DataPath	 = Join-Path $ScriptPath "Data"
$TrackingDBPath = Join-Path $DataPath "Tracking-DB.json"
#endregion

#region [FUNCTIONS]
function Show-DeploymentReport {
	if (-not (Test-Path $TrackingDBPath)) {
		Write-Warning "Tracking database not found at $TrackingDBPath"
		return
	}

	try {
		$Results = Get-Content -Path $TrackingDBPath | ConvertFrom-Json
	} catch {
		Write-Error "Failed to load and parse Tracking-DB.json. Ensure JSON integrity.`n$_"
		return
	}

	if (-not $Results -or $Results.PSObject.Properties.Count -eq 0) {
		Write-Warning "No deployment data found in tracking database"
		return
	}

	$DisplayData = $Results.PSObject.Properties | ForEach-Object {
		$entry = $_.Value

		$SentFormatted	 = Format-TimestampWithTimezone -Timestamp $entry.SentTimestamp
		$ReceivedFormatted = Format-TimestampWithTimezone -Timestamp $entry.ReceivedTimestamp

		[PSCustomObject]@{
			Hostname		   = $entry.Hostname
			ComputerStatus	 = $entry.ComputerStatus
			JobStatus		  = $entry.JobStatus
			PreDeployDetect	= $entry.PreDeployDetect
			PostDeployDetect   = $entry.PostDeployDetect
			ExitCode		   = $entry.ExitCode
			AttemptCount	   = $entry.AttemptCount
			SentTimestampZ	 = $SentFormatted.Sortable
			SentTime		   = $SentFormatted.Display
			ReceivedTimestampZ = $ReceivedFormatted.Sortable
			ReceivedTime	   = $ReceivedFormatted.Display
			LastErrorDetail	= $entry.LastErrorDetail
		}
	}

	$DisplayData | Out-GridView -Title "PSADT Deployment Tracker" -PassThru | Out-Null
}

function Format-TimestampWithTimezone {
	param ([string]$Timestamp)

	if (-not $Timestamp -or $Timestamp -eq "") {
		return @{
			Sortable = ""
			Display  = ""
		}
	}

	try {
		$DateTime	   = [DateTime]::Parse($Timestamp)
		$ArizonaTimezone= [System.TimeZoneInfo]::FindSystemTimeZoneById("US Mountain Standard Time")
		$ArizonaTime	= [System.TimeZoneInfo]::ConvertTimeFromUtc($DateTime.ToUniversalTime(), $ArizonaTimezone)

		@{
			Sortable = $ArizonaTime.ToString("yyyy-MM-dd HH:mm:ss")
			Display  = $ArizonaTime.ToString("h:mm tt")
		}
	} catch {
		@{
			Sortable = $Timestamp
			Display  = $Timestamp
		}
	}
}
#endregion

#region [MAIN EXECUTION]
Show-DeploymentReport
#endregion