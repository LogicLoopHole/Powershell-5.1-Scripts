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

$targetHost = "google.com"
$clientHostname = [System.Net.Dns]::GetHostName()
$logFilePath = "C:\temp\WifiNetConnectUptimeTester_$clientHostname.log"
$pingResponseTimes = @()

function Log-Message {
	param ( [string]$Message )
	$timestampedMessage = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " - $Message"
	Add-Content -Path $logFilePath -Value $timestampedMessage
	Write-Output $timestampedMessage
}

function Get-WiFiInfo {
	$interface = netsh wlan show interfaces | Out-String

	$ssid = if ($interface -match "SSID\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$bssid = if ($interface -match "BSSID\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$signal = if ($interface -match "Signal\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$channel = if ($interface -match "Channel\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$rxRate = if ($interface -match "Receive rate \(Mbps\)\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$txRate = if ($interface -match "Transmit rate \(Mbps\)\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }

	try
		{
			$nic = Get-NetAdapter -Name "Wi-Fi" -ErrorAction Stop
			$ipConfig = Get-NetIPAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
			$ip = $ipConfig.IPAddress
		}
	catch
		{
			# Fallback for edge cases
			try
				{
					$ip = (Test-Connection $targetHost -Count 1 -ErrorAction SilentlyContinue).IPV4Address
				}
			catch
				{
					$ip = "Unknown"
				}
		}

	return @{
			SSID = $ssid
			BSSID = $bssid
			Signal = $signal
			Channel	= $channel
			RxRateMbps = $rxRate
			TxRateMbps = $txRate
			IPAddress = $ip
		}
}

function Calculate-Jitter {
	if ($pingResponseTimes.Count -lt 2) { return $null }
	$mean = ($pingResponseTimes | Measure-Object -Average).Average
	# Jitter as standard deviation reference this URL for addtional info  https://www.3rdechelon.net/jittercalc.asp
	$variance = $pingResponseTimes | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Average | Select-Object -ExpandProperty Average
	return [math]::Sqrt($variance)
}

# Start ping background process
$pingProcess = New-Object System.Diagnostics.Process
$pingProcess.StartInfo.FileName = "ping"
$pingProcess.StartInfo.Arguments = "-t $targetHost"
$pingProcess.StartInfo.RedirectStandardOutput = $true
$pingProcess.StartInfo.UseShellExecute = $false
$pingProcess.StartInfo.CreateNoWindow = $true
$pingProcess.Start() | Out-Null

# Initial state tracking variables
$previousConnectionState = $false
$previousNetworkStatus = $false
$previousBSSID = ""	# avoid $null to prevent bogus trips
$previousIP = "" # same thing for IP tracking
$firstRunComplete = $false
$lastLoggedUser = "NoUserLoggedIn"
$currentUser = "NoUserLoggedIn"
Log-Message "Possible Reboot Warning - Script started"

while ($true) # Main monitoring loop
	{
		if (Test-Path $logFilePath)
			{
				$fileSize = (Get-Item $logFilePath).Length
				if ($fileSize -gt 1GB)
					{
						Log-Message "Log reached 1GB. Stopping monitoring."
						exit
					}
			}
			
		# Monitor logged in/active user
		$currentUser = Get-WmiObject Win32_Process -Filter 'Name="explorer.exe"' | ForEach-Object { $_.GetOwner().User } | Select-Object -First 1
		if ($currentUser -ne $lastLoggedUser)
			{
				Log-Message "Active logged in Windows user changed from: $lastLoggedUser to: $currentUser"
				$lastLoggedUser = $currentUser
			}

		# Read one line of ping output
		$pingOutput = $pingProcess.StandardOutput.ReadLine()
		$wifi = Get-WiFiInfo
		$currentBSSID = $wifi.BSSID
		$currentIP = $wifi.IPAddress

		# Determine if currently connected decently
		$newConnectionState = ($wifi.SSID -ne "N/A" -and $wifi.Channel -ne "0" -and $wifi.Channel -ne "N/A")

		# Capture ping response time if present
		if ($pingOutput -match "time=(\d+)ms")
			{
				$pingResponseTimes += [int]$matches[1]
			}
		elseif ($pingOutput -match "time<1ms")
			{
				$pingResponseTimes += 0.5
			}

		# Handle Roaming Detection
		if ($newConnectionState -and $previousBSSID -ne $currentBSSID -and $currentBSSID -ne "" -and $firstRunComplete)
			{
				$jitter = Calculate-Jitter
				$jitterLabel = if ($jitter -ne $null) { "Jitter: $($jitter.ToString("F1")) ms" } else { "N/A" }
				Log-Message "Wi-Fi ROAMING DETECTED. Switched from AP BSSID: $previousBSSID -> $currentBSSID | SSID: $($wifi.SSID) | Channel: $($wifi.Channel) | Signal: $($wifi.Signal) | RX Rate: $($wifi.RxRateMbps) Mbps | TX Rate: $($wifi.TxRateMbps) Mbps | $jitterLabel"
				$pingResponseTimes = @()
			}

		# Handle IP Address Changes
		if ($previousIP -ne $currentIP -and $previousIP -ne "" -and $currentIP -ne "Unknown")
			{
				Log-Message "Wi-Fi IP ADDRESS CHANGED. Old IP: $previousIP | New IP: $currentIP | Wi-Fi SSID: $($wifi.SSID) | AP BSSID: $currentBSSID | Channel: $($wifi.Channel)"
			}

		# Network Connectivity Handling
		if ($pingOutput -match "Reply from" -and $newConnectionState) # Ping replies and Wi-Fi valid — Connection Restored
			{
				if (-not $previousNetworkStatus)
					{
						$jitter = Calculate-Jitter
						$jitterLabel = if ($jitter -ne $null) { "| Jitter: $($jitter.ToString("F1")) ms" } else { "" }
						Log-Message "Destination $targetHost ping RESTORED. Host: $clientHostname | IP: $currentIP | Wi-Fi SSID: $($wifi.SSID) | AP BSSID: $currentBSSID | Channel: $($wifi.Channel) | Signal: $($wifi.Signal) | RX Rate: $($wifi.RxRateMbps) Mbps | TX Rate: $($wifi.TxRateMbps) Mbps | $jitterLabel"
						$pingResponseTimes = @()
					}
				$previousNetworkStatus = $true
				$previousConnectionState = $true
				if (-not $firstRunComplete) { $firstRunComplete = $true }
			}
		# Loss via Wi-Fi degradation
		elseif ($previousConnectionState -and -not $newConnectionState)
			{
				$jitter = Calculate-Jitter
				$jitterLabel = if ($jitter -ne $null) { "| Jitter: $($jitter.ToString("F1")) ms" } else { "" }
				Log-Message "Wi-Fi SIGNAL DEGRADED. Host: $clientHostname | IP: $currentIP | Wi-Fi SSID: $($wifi.SSID) | AP BSSID: $currentBSSID | Channel: $($wifi.Channel) | Signal: $($wifi.Signal) | RX Rate: $($wifi.RxRateMbps) Mbps | TX Rate: $($wifi.TxRateMbps) Mbps | $jitterLabel"
				$pingResponseTimes = @()
				$previousConnectionState = $false
				$previousNetworkStatus = $false
			}
		# Loss via ping timeout while Wi-Fi remains okay
		elseif (-not ($pingOutput -match "Reply from") -and $previousNetworkStatus)
			{
				$jitter = Calculate-Jitter
				$jitterLabel = if ($jitter -ne $null) { "| Jitter: $($jitter.ToString("F1")) ms" } else { "" }
				Log-Message "Destination $targetHost ping LOST (Timeout). Host: $clientHostname | IP: $currentIP | Wi-Fi SSID: $($wifi.SSID) | AP BSSID: $currentBSSID | Channel: $($wifi.Channel) | Signal: $($wifi.Signal) | RX Rate: $($wifi.RxRateMbps) Mbps | TX Rate: $($wifi.TxRateMbps) Mbps | $jitterLabel"
				$pingResponseTimes = @()
				$previousNetworkStatus = $false
			}

		# Update tracked values
		if ($currentBSSID -ne "")
			{
				$previousBSSID = $currentBSSID
			}
		$previousIP = $currentIP

		# Wait before rechecking
		Start-Sleep -Milliseconds 500
	} #end Main loop