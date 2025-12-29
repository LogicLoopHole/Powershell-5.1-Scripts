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

# --- Configuration ---
$targetHost = "8.8.8.8"
$clientHostname = [System.Net.Dns]::GetHostName()
$logFilePath = "C:\temp\Net-Uptime-Monitor_$clientHostname.log"

# Processes to monitor (Add names here)
$processNames = @("notepad", "taskmgr", "ShellExperienceHost") 

# --- storage for tracking states ---
$pingResponseTimes = @()
$processStatus = @{}
# Initialize process status state
foreach ($name in $processNames) { $processStatus[$name] = "FirstRun" }

# --- Functions ---

function Log-Message {
	param ( [string]$Message )
	$timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
	$fullMsg = "$timestamp - $Message"
	# Ensure directory exists before writing
	$logDir = [System.IO.Path]::GetDirectoryName($logFilePath)
	if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
	Add-Content -Path $logFilePath -Value $fullMsg
	Write-Output $fullMsg
}

function Get-NetworkInfo {
	# Get standard Wi-Fi stats (returns N/A if on Ethernet)
	$interface = netsh wlan show interfaces | Out-String
	$ssid = if ($interface -match "SSID\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$bssid = if ($interface -match "BSSID\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$signal = if ($interface -match "Signal\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$channel = if ($interface -match "Channel\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$rxRate = if ($interface -match "Receive rate \(Mbps\)\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }
	$txRate = if ($interface -match "Transmit rate \(Mbps\)\s+:\s+(.*)") { $matches[1].Trim() } else { "N/A" }

	try
		{
			# Identify adapter carrying internet traffic via Routing Table (dest 0.0.0.0/0)
			$activeRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
				Sort-Object RouteMetric | Select-Object -First 1

			if ($activeRoute) {
				$nic = Get-NetAdapter -InterfaceIndex $activeRoute.InterfaceIndex -ErrorAction Stop
				$ipConfig = Get-NetIPAddress -InterfaceIndex $activeRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
				$ip = $ipConfig.IPAddress
				$adapterDesc = $nic.InterfaceDescription
			}
			else { throw "No Active Route" }
		}
	catch
		{
			try { 
				$ip = (Test-Connection $targetHost -Count 1 -ErrorAction SilentlyContinue).IPV4Address 
				$adapterDesc = "Unknown/Fallback Protocol"
			}
			catch { 
				$ip = "Unknown"; $adapterDesc = "No Connection" 
			}
		}

	return @{
			SSID = $ssid; BSSID = $bssid; Signal = $signal; Channel = $channel
			RxRateMbps = $rxRate; TxRateMbps = $txRate
			IPAddress = $ip; AdapterDesc = $adapterDesc
		}
}

function Calculate-Jitter {
	if ($pingResponseTimes.Count -lt 2) { return $null }
	$mean = ($pingResponseTimes | Measure-Object -Average).Average
	$variance = $pingResponseTimes | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Average | Select-Object -ExpandProperty Average
	return [math]::Sqrt($variance)
}

function Check-ProcessStatus {
	param ( [string]$ProcessName )
	
	# Get process (handle array if multiple instances exist)
	$pList = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
	
	if (-not $pList) {
		$currentState = 'Inactive/Not Running'
	}
	else {
		# If any instance is responding, we consider the app "Running"
		$isResponding = ($pList | Where-Object { $_.Responding -eq $true })
		if ($isResponding) { $currentState = 'Running' }
		else { $currentState = 'Not Responding' }
	}

	# Check against previous state
	if ($processStatus[$ProcessName] -ne $currentState) {
		
        # CASE 1: Startup Detection (First Run)
        if ($processStatus[$ProcessName] -eq "FirstRun") {
            # Only log if it is actually running found at startup
            if ($currentState -eq "Running" -or $currentState -eq "Not Responding") {
                Log-Message "PROCESS STARTUP DETECTION: $ProcessName is currently $currentState."
            }
        }
        # CASE 2: Normal State Change
        else {
		    Log-Message "PROCESS STATUS: $ProcessName changed to $currentState."
        }
		
        # Update state
        $processStatus[$ProcessName] = $currentState
	}
}

# --- Initialization ---

# Start ping background process
$pingProcess = New-Object System.Diagnostics.Process
$pingProcess.StartInfo.FileName = "ping"
$pingProcess.StartInfo.Arguments = "-t $targetHost"
$pingProcess.StartInfo.RedirectStandardOutput = $true
$pingProcess.StartInfo.UseShellExecute = $false
$pingProcess.StartInfo.CreateNoWindow = $true
$pingProcess.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8 # Ensure encoding if needed
$pingProcess.Start() | Out-Null

# Initial tracking variables
$previousConnectionState = $false
$previousNetworkStatus = $false # Will be updated immediately by first ping read
$previousBSSID = ""; $previousIP = "" 
$firstRun = $true
$lastLoggedUser = "NoUserLoggedIn"

# Capture initial IP for startup message
$startNetInfo = Get-NetworkInfo
Log-Message "Possible Reboot Warning - Script started. Initial IP: $($startNetInfo.IPAddress) ($($startNetInfo.AdapterDesc))"

# --- Main Loop ---

while ($true)
	{
		# Check Log Size
		if (Test-Path $logFilePath) {
			if ((Get-Item $logFilePath).Length -gt 1GB) {
				Log-Message "Log reached 1GB. Stopping."; exit
			}
		}
			
		# 1. Process Monitoring
		foreach ($proc in $processNames) {
			Check-ProcessStatus -ProcessName $proc
		}

		# 2. User Monitoring
		$currentUser = Get-WmiObject Win32_Process -Filter 'Name="explorer.exe"' | ForEach-Object { $_.GetOwner().User } | Select-Object -First 1
		if (-not $currentUser) { $currentUser = "NoUserLoggedIn" }

		if ($currentUser -ne $lastLoggedUser) {
			Log-Message "Active logged in Windows user changed from: $lastLoggedUser to: $currentUser"
			$lastLoggedUser = $currentUser
		}

		# 3. Read Ping & Network Info
		if ($pingProcess.StandardOutput.EndOfStream -eq $false) {
			$pingOutput = $pingProcess.StandardOutput.ReadLine()
		} else { $pingOutput = "" }

		$netInfo = Get-NetworkInfo
		$currentBSSID = $netInfo.BSSID
		$currentIP = $netInfo.IPAddress
		
		# Determine connection context
		$isWifi = ($netInfo.SSID -ne "N/A" -and $netInfo.Channel -ne "N/A")

		# Capture Ping Time
		if ($pingOutput -match "time=(\d+)ms") { $pingResponseTimes += [int]$matches[1] }
		elseif ($pingOutput -match "time<1ms") { $pingResponseTimes += 0.5 }

		# 4. Roaming Detection (Wifi)
		if ($isWifi -and $previousBSSID -ne $currentBSSID -and $currentBSSID -ne "N/A" -and $previousBSSID -ne "N/A" -and -not $firstRun) {
			$jitter = Calculate-Jitter
			$jitterLabel = if ($jitter -ne $null) { "Jitter: $($jitter.ToString("F1")) ms" } else { "N/A" }
			Log-Message "Wi-Fi ROAMING DETECTED. Switched from AP BSSID: $previousBSSID -> $currentBSSID | SSID: $($netInfo.SSID) | Channel: $($netInfo.Channel) | Signal: $($netInfo.Signal) | Rate: $($netInfo.RxRateMbps)/$($netInfo.TxRateMbps) Mbps | $jitterLabel"
			$pingResponseTimes = @()
		}

		# 5. IP Changes (Any Adapter)
		if ($previousIP -ne $currentIP -and $previousIP -ne "" -and $currentIP -ne "Unknown") {
			Log-Message "IP ADDRESS CHANGED. Adapter: $($netInfo.AdapterDesc) | Old IP: $previousIP | New IP: $currentIP | SSID: $($netInfo.SSID) | BSSID: $currentBSSID"
		}

		# 6. Connectivity State
		if ($pingOutput -match "Reply from") {
			if (-not $previousNetworkStatus) {
				$jitter = Calculate-Jitter
				$jitterLabel = if ($jitter -ne $null) { "| Jitter: $($jitter.ToString("F1")) ms" } else { "" }
				Log-Message "Destination $targetHost ping RESTORED. Host: $clientHostname | IP: $currentIP | Adapter: $($netInfo.AdapterDesc) | SSID: $($netInfo.SSID) | Rate: $($netInfo.RxRateMbps)/$($netInfo.TxRateMbps) Mbps | $jitterLabel"
				$pingResponseTimes = @()
			}
			$previousNetworkStatus = $true
			if ($firstRun) { $firstRun = $false }
		}
		elseif (-not ($pingOutput -match "Reply from") -and $previousNetworkStatus) {
			# Lost Connectivity
			$jitter = Calculate-Jitter
			$jitterLabel = if ($jitter -ne $null) { "| Jitter: $($jitter.ToString("F1")) ms" } else { "" }
			Log-Message "Destination $targetHost ping LOST (Timeout). Host: $clientHostname | IP: $currentIP | Adapter: $($netInfo.AdapterDesc) | SSID: $($netInfo.SSID) | $jitterLabel"
			$pingResponseTimes = @()
			$previousNetworkStatus = $false
		}

		# Update tracked values
		if ($currentBSSID -ne "") { $previousBSSID = $currentBSSID }
		$previousIP = $currentIP

		Start-Sleep -Milliseconds 500
	}