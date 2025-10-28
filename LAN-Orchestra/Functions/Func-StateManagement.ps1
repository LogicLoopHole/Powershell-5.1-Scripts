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

# Func-StateManagement.ps1

function ConvertTo-Hashtable
	{
		param([object]$InputObject)

		if ($null -eq $InputObject) { return @{} }
		if ($InputObject -is [hashtable])
			{
				$copy = @{}
				foreach ($k in $InputObject.Keys) { $copy[$k] = ConvertTo-Hashtable $InputObject[$k] }
				return $copy
			}
		if ($InputObject -is [psobject])
			{
				$copy = @{}
				foreach ($p in $InputObject.PSObject.Properties) { $copy[$p.Name] = ConvertTo-Hashtable $p.Value }
				return $copy
			}
		if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string])
			{
				return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
			}
		return $InputObject
	}

function Load-State
	{
		param([string]$TrackingDBPath)
		
		Ensure-ParentDirectory -Path $TrackingDBPath

		if ( -not (Test-Path $TrackingDBPath) )
			{
				return @{}
			}

		try
			{
				$content = Get-Content $TrackingDBPath -Raw
				if (-not $content.Trim()) { return @{} }

				# Check if we have depth support
				$SupportsConvertFromJsonDepth = (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue).Parameters.ContainsKey('Depth')
				$json = if ($SupportsConvertFromJsonDepth) { $content | ConvertFrom-Json -Depth 20 } else { $content | ConvertFrom-Json }
				$results = ConvertTo-Hashtable $json
				if ($results -isnot [hashtable]) { return @{} }
				return $results
			}
		catch
			{
				Write-Log "Failed to parse Tracking-DB.json, starting fresh: $($_.Exception.Message)" -Level WARN
				return @{}
			}
	}

function Save-State
	{
		param(
			[hashtable]$StateData,
			[string]$TrackingDBPath
		)

		try
			{
				Ensure-ParentDirectory -Path $TrackingDBPath

				$psObj = New-Object PSObject
				foreach ($key in $StateData.Keys)
					{
						$psObj | Add-Member -MemberType NoteProperty -Name $key -Value $StateData[$key]
					}

				# Check if we have depth support
				$SupportsConvertToJsonDepth = (Get-Command ConvertTo-Json -ErrorAction SilentlyContinue).Parameters.ContainsKey('Depth')
				$json = if ($SupportsConvertToJsonDepth) { $psObj | ConvertTo-Json -Depth 10 } else { $psObj | ConvertTo-Json }
				$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
				[System.IO.File]::WriteAllText($TrackingDBPath, $json, $utf8NoBom)
			}
		catch
			{
				Write-Log "Failed to save Tracking-DB.json: $($_.Exception.Message)" -Level ERROR
			}
	}

function Update-HostResults
	{
		param(
			[hashtable]$CurrentState,
			[string]$Hostname,
			[hashtable]$UpdateData,
			[string]$DesiredAction = $null,
			[string]$TrackingDBPath
		)

		if ( -not $CurrentState.ContainsKey($Hostname) )
			{
				$CurrentState[$Hostname] = @{
					Hostname		  = $Hostname
					DesiredAction	 = if ($DesiredAction) { $DesiredAction } else { "Install" }
					ComputerStatus	= "Unknown"
					JobStatus		 = "Queued"
					SentTimestamp	 = ""
					AttemptCount	  = 0
					PreDeployDetect   = "Unknown"
					LastErrorDetail   = ""
				}
			}

		if ($DesiredAction)
			{
				$UpdateData["DesiredAction"] = $DesiredAction
			}

		foreach ($key in $UpdateData.Keys)
			{
				$CurrentState[$Hostname][$key] = $UpdateData[$key]
			}

		Save-State -StateData $CurrentState -TrackingDBPath $TrackingDBPath
		return $CurrentState
	}