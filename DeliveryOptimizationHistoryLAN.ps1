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

# Ensure C:\temp directory exists
$TempDir = "C:\temp"
if ( !(Test-Path $TempDir) ) { New-Item -ItemType Directory -Path $TempDir | Out-Null }

# Load hostnames from file
$HostnameFile = "$TempDir\hostnames.txt"
if (Test-Path $HostnameFile)
	{
		$HostnameList = Get-Content $HostnameFile | Where-Object { $_.Trim() -ne "" }
		Write-Host "Loaded $($HostnameList.Count) hostnames from $HostnameFile"
	}
else
	{
		Write-Error "Hostname file not found: $HostnameFile"
		exit
	}

function Test-HostnameOnline
	{
		param([string]$Hostname)
		
		try
			{
				$result = Test-Connection -ComputerName $Hostname -Count 1 -Quiet -ErrorAction Stop
				return $result
			}
		catch
			{
				return $false
			}
	}

# Function to collect DO data from remote machine
function Get-RemoteDOData
	{
		param([string]$ComputerName)
		
		try
			{
				Write-Host "Collecting DO data from $ComputerName..."
				$scriptBlock = {
					try
						{
							$logs = Get-DeliveryOptimizationLog
							return $logs
						}
					catch
						{
							Write-Error "Failed to get DO logs from $env:COMPUTERNAME: $($_.Exception.Message)"
							return @()
						}
				}
				
				$remoteLogs = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
				Write-Host "Retrieved $($remoteLogs.Count) log entries from $ComputerName"
				return $remoteLogs
			}
		catch
			{
				Write-Warning "Failed to connect to $ComputerName - $($_.Exception.Message)"
				return @()
			}
	}

# Collect DO data from all online machines
$AllDOLogs = @()
$processedMachines = 0
$OnlineMachines = @()
$OfflineMachines = @()

foreach ($hostname in $HostnameList)
	{
		$processedMachines++
		Write-Host "Processing machine $processedMachines of $($HostnameList.Count): $hostname"
		
		# Test if machine is online first
		if (Test-HostnameOnline -Hostname $hostname)
			{
				$OnlineMachines += $hostname
				
				$remoteLogs = Get-RemoteDOData -ComputerName $hostname
				if ($remoteLogs.Count -gt 0)
					{
						# Add machine name to each log entry
						$remoteLogs | Add-Member -MemberType NoteProperty -Name "SourceMachine" -Value $hostname -PassThru
						$AllDOLogs += $remoteLogs
					}
			}
		else
			{
				$OfflineMachines += $hostname
				Write-Warning "Device $hostname is offline - skipping"
			}
	}

Write-Host "Total DO log entries collected from all machines: $($AllDOLogs.Count)"

# Process the collected data
$PeerCorrelationFile = "$TempDir\DORemotePeerCorrelation.csv"

# Process InternalAnnounce entries (transfer data)
$InternalAnnounce = $AllDOLogs | Where-Object {($_.Function -eq "CAnnounceSequencer::_InternalAnnounce")}
$TransferData = foreach ($entry in $InternalAnnounce)
	{
		try
			{
				$cleanMessage = $entry.Message -replace "Swarm.*announce request:",""
				$json = $cleanMessage | ConvertFrom-Json
				
				[PSCustomObject]@{
					SourceMachine = $entry.SourceMachine
					TimeCreated = $entry.TimeCreated
					ReportedIp = if ($json.PSObject.Properties.Name -contains "ReportedIp") { $json.ReportedIp } else { $null }
					Uploaded = if ($json.PSObject.Properties.Name -contains "Uploaded") { $json.Uploaded } else { $null }
					Downloaded = if ($json.PSObject.Properties.Name -contains "Downloaded") { $json.Downloaded } else { $null }
					DownloadedCdn = if ($json.PSObject.Properties.Name -contains "DownloadedCdn") { $json.DownloadedCdn } else { $null }
					ContentId = if ($json.PSObject.Properties.Name -contains "ContentId") { $json.ContentId } else { $null }
				}
			}
		catch
			{
				Write-Warning "Failed to parse InternalAnnounce JSON from machine $($entry.SourceMachine)"
			}
	}

# Process ConnectionComplete entries (peer connections)
$ConnectionComplete = $AllDOLogs | Where-Object {($_.Function -eq "CConnMan::ConnectionComplete")}
$PeerData = foreach ($entry in $ConnectionComplete)
	{
		try
			{
				$peerIPMatches = $entry.Message | Select-String -Pattern "\d{1,3}(\.\d{1,3}){3}" -AllMatches
				$peerIP = if ($peerIPMatches.Matches.Count -gt 0) { $peerIPMatches.Matches[0].Value } else { $null }
				
				if ($peerIP)
					{
						# Check if it's a private IP address (RFC1918)
						$isPrivateIP = $false
						try
							{
								$ipAddress = [System.Net.IPAddress]::Parse($peerIP)
								$bytes = $ipAddress.GetAddressBytes()
								
								# Check for private IP ranges:
								# 10.0.0.0 - 10.255.255.255 (10/8 prefix)
								# 172.16.0.0 - 172.31.255.255 (172.16/12 prefix)
								# 192.168.0.0 - 192.168.255.255 (192.168/16 prefix)
								
								if ($bytes[0] -eq 10)
									{
										$isPrivateIP = $true  # 10.x.x.x
									}
								elseif ($bytes[0] -eq 172 -and ($bytes[1] -ge 16 -and $bytes[1] -le 31))
									{
										$isPrivateIP = $true  # 172.16.x.x - 172.31.x.x
									}
								elseif ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
									{
										$isPrivateIP = $true  # 192.168.x.x
									}
							}
						catch
							{
								# If parsing fails, assume it's not private
								$isPrivateIP = $false
							}
						
						if ($isPrivateIP)
							{
								[PSCustomObject]@{
									SourceMachine = $entry.SourceMachine
									TimeCreated = $entry.TimeCreated
									PeerIP = $peerIP
								}
							}
					}
			}
		catch
			{
				Write-Warning "Failed to extract PeerIP from ConnectionComplete on machine $($entry.SourceMachine)"
			}
	}

# Create correlation report showing transfers with nearby private peer connections
$CorrelationData = @()
$processedEntries = 0

$TransferData | ForEach-Object {
	$transferEntry = $_
	$processedEntries++
	
	# Show progress
	if ($processedEntries % 50 -eq 0)
		{
			Write-Host "Processed $processedEntries of $($TransferData.Count) entries..."
		}
	
	# Find private peer connections within 5 minutes of this transfer
	# Only look for peers from other machines (not the same machine)
	$timeWindowStart = $transferEntry.TimeCreated.AddMinutes(-5)
	$timeWindowEnd = $transferEntry.TimeCreated.AddMinutes(5)
	$nearbyPrivatePeers = $PeerData | Where-Object {
		$_.SourceMachine -ne $transferEntry.SourceMachine -and
		$_.TimeCreated -ge $timeWindowStart -and 
		$_.TimeCreated -le $timeWindowEnd
	}
	
	if ($nearbyPrivatePeers)
		{
			$peerInfo = ( $nearbyPrivatePeers | Sort-Object -Unique PeerIP | ForEach-Object { $_.PeerIP	} ) -join ", "
			
			$CorrelationData += [PSCustomObject]@{
				"Event Time" = $transferEntry.TimeCreated
				"Source Machine" = $transferEntry.SourceMachine
				"Local IP" = $transferEntry.ReportedIp
				"Uploaded MB" = [math]::Round($transferEntry.Uploaded / 1MB, 2)
				"Downloaded MB" = [math]::Round($transferEntry.Downloaded / 1MB, 2)
				"Downloaded CDN MB" = [math]::Round($transferEntry.DownloadedCdn / 1MB, 2)
				"Private Peers (5min window)" = $peerInfo
				"Peer Count" = $nearbyPrivatePeers.Count
			}
		}
}

$CorrelationData | Export-Csv -Path $PeerCorrelationFile -NoTypeInformation
Write-Host "Exported $($CorrelationData.Count) entries with cross-machine peer correlations to $PeerCorrelationFile"
Write-Host "Sample of cross-machine peer correlation report:"
$CorrelationData | Select-Object -First 10 | Format-Table -AutoSize

Write-Host "=== Offline Machines Summary ==="
if ($OfflineMachines.Count -gt 0)
	{
		Write-Host "The following $($OfflineMachines.Count) machines were offline and skipped:"
		$OfflineMachines | ForEach-Object { Write-Host "  - $_" }
	}
else
	{
		Write-Host "All machines were online and processed successfully!"
	}

Write-Host "Online machines processed: $($OnlineMachines.Count)"
Write-Host "Offline machines skipped: $($OfflineMachines.Count)"
Write-Host "Total machines in list: $($HostnameList.Count)"

Write-Host "Script completed"