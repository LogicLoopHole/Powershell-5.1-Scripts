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

# --- Configuration ---
# Ping targets (IP or hostname). All targets are pinged at the same moment every interval.
$targets = @("8.8.8.8")			# e.g. @("10.1.1.20", "fileserver01", "8.8.8.8")
$pingIntervalMs = 1000
$pingTimeoutMs = 4000			# Same as ping.exe: lost = no reply within 4 seconds. While a target is down it's re-pinged
								# about every 5 seconds; LOST is still stamped with when the first unanswered ping was sent.
								# (900 gives 1-second resolution during outages, but also counts replies slower than 0.9 s as lost.)
$clientHostname = [System.Net.Dns]::GetHostName()
$logFilePath = "C:\temp\Net-Uptime-Monitor_$clientHostname.log"

# Processes to monitor (Add names here). Logged per process + user + session: STARTED when it first runs there,
# STOPPED when nothing is left running there. sihost runs once per signed-in session, so it marks logon/logoff.
# Seeing other users' processes needs admin rights, so run as SYSTEM or elevated.
$processNames = @("sihost", "notepad", "taskmgr", "ShellExperienceHost")
$processGraceSec = 2			# Back within this many seconds = a hand-off between instances, not logged as a stop
$logProcessDetails = $true		# Log parent + command line on STARTED lines (command lines can contain secrets)

# --- Storage for tracking states ---
$groups = @{}	# "name | User | Session" -> state while that process runs for that user/session
$procs = @{}	# PID -> each running instance (a handle is held so its exit code stays readable)
$pingStates = @(foreach ($t in $targets) {
	[pscustomobject]@{
		Target = $t; Ping = New-Object System.Net.NetworkInformation.Ping
		Task = $null; Error = $null; SentAt = $null
		Up = $null	# $null until the first result, so the first result is always logged
	}
})

# --- Functions ---

function Log-Message {
	param ( [string]$Message, [datetime]$Time = (Get-Date) )
	# Events are stamped with when they happened (e.g. when a ping was sent), which can be slightly before now
	$fullMsg = "$($Time.ToString('yyyy-MM-dd HH:mm:ss.fff')) - $Message"
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
				$ip = $ipConfig.IPAddress -join ', '	# Joined in case the adapter has more than one IPv4 address
				$adapterDesc = $nic.InterfaceDescription
			}
			else { throw "No Active Route" }
		}
	catch
		{
			# No default route. (The old Test-Connection fallback returned the target's address, not ours.)
			$ip = "Unknown"; $adapterDesc = "No Connection"
		}

	return @{
			SSID = $ssid; BSSID = $bssid; Signal = $signal; Channel = $channel
			RxRateMbps = $rxRate; TxRateMbps = $txRate
			IPAddress = $ip; AdapterDesc = $adapterDesc
		}
}

function Get-ProcessDetail {
	param ( [int]$ProcessId )
	# Parent and command line via CIM, looked up once per new instance
	$me = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
	if (-not $me) { return " | Parent: N/A | Cmd: N/A" }
	$parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($me.ParentProcessId)" -OperationTimeoutSec 5 -ErrorAction SilentlyContinue
	# Windows reuses PIDs, so a "parent" that started after this process is an unrelated process
	$parentName = if ($parent -and $parent.CreationDate -le $me.CreationDate) { $parent.Name } else { "(exited)" }
	return " | Parent: $parentName PID $($me.ParentProcessId) | Cmd: $($me.CommandLine)"
}

function Format-ExitCode {
	param ( $Code )
	if ($null -eq $Code) { return "N/A" }
	return '{0} (0x{0:X8})' -f $Code
}

function Check-Processes {
	param ( [switch]$Startup )
	# One snapshot of every watched instance, keyed by PID. If the snapshot itself fails, skip this pass
	# so a hiccup is never mistaken for every process exiting.
	try { $list = @(Get-Process -Name $processNames -IncludeUserName -ErrorAction SilentlyContinue) } catch { return }
	$now = Get-Date
	$current = @{}
	foreach ($p in $list) { $current[$p.Id] = $p }

	# Instances that ended. Not logged on their own (another instance may carry on), except error exits
	# such as crashes, which are logged even when another instance takes over.
	foreach ($id in @($procs.Keys)) {
		if ($current.ContainsKey($id)) { continue }
		$t = $procs[$id]; $g = $groups[$t.Key]
		# (PowerShell returns $null rather than throwing when a property can't be read, so check values, not just errors)
		$exitTime = $null; $exitCode = $null
		if ($t.HasHandle) { try { $exitTime = $t.Process.ExitTime; $exitCode = $t.Process.ExitCode } catch { } }
		if (-not $exitTime) { $exitTime = $now }
		if ($null -ne $exitCode -and $exitCode -lt 0) { Log-Message "PROCESS ERROR EXIT: $($t.Key) | PID $id | Exit code: $(Format-ExitCode $exitCode)" -Time $exitTime }
		$g.Running--
		if (-not $g.LastExit -or $exitTime -ge $g.LastExit) { $g.LastExit = $exitTime; $g.LastCode = $exitCode }
		$t.Process.Dispose(); $procs.Remove($id)
	}

	# New instances. Logged only when the process wasn't already running for that user/session.
	foreach ($id in $current.Keys) {
		if ($procs.ContainsKey($id)) { continue }
		$p = $current[$id]
		$user = if ($p.UserName) { $p.UserName } else { "Unknown" }
		$key = "$($p.ProcessName) | User: $user | Session: $($p.SessionId)"
		# Hold a handle so the exit code/time stay readable (also stops Windows reusing the PID meanwhile)
		$hasHandle = $false; try { $hasHandle = $null -ne $p.Handle } catch { }
		$start = $null; try { $start = $p.StartTime } catch { }
		$procs[$id] = [pscustomobject]@{ Process = $p; HasHandle = $hasHandle; Key = $key }
		if ($groups.ContainsKey($key)) { $groups[$key].Running++; continue }	# Extra instance or hand-off
		$groups[$key] = [pscustomobject]@{ Running = 1; Since = $start; LastExit = $null; LastCode = $null }
		$detail = if ($logProcessDetails) { Get-ProcessDetail $id } else { "" }
		if ($Startup) {
			$started = if ($start) { $start.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { "N/A" }
			Log-Message "PROCESS STARTUP DETECTION: $key | PID $id | Started: $started$detail"
		}
		else { Log-Message "PROCESS STARTED: $key | PID $id$detail" -Time $(if ($start) { $start } else { $now }) }
	}

	# Stopped: nothing left running for that user/session for longer than the grace period.
	# Stamped with when the last instance exited, with that instance's exit code.
	foreach ($key in @($groups.Keys)) {
		$g = $groups[$key]
		if ($g.Running -gt 0 -or ($now - $g.LastExit).TotalSeconds -lt $processGraceSec) { continue }
		$ran = "N/A"
		if ($g.Since) { $span = $g.LastExit - $g.Since; $ran = '{0}:{1:mm\:ss}' -f [int][math]::Floor($span.TotalHours), $span }
		Log-Message "PROCESS STOPPED: $key | Ran: $ran | Exit code: $(Format-ExitCode $g.LastCode)" -Time $g.LastExit
		$groups.Remove($key)
	}
}

# --- Initialization ---

$previousBSSID = ""; $previousIP = ""

# Capture initial IP for startup message
$startNetInfo = Get-NetworkInfo
Log-Message "Possible Reboot Warning - Script started. Initial IP: $($startNetInfo.IPAddress) ($($startNetInfo.AdapterDesc)) | Targets: $($targets -join ', ')"

# Log what is already running (and start tracking it)
Check-Processes -Startup

# --- Main Loop ---

while ($true)
	{
		$tickStart = Get-Date

		# Check Log Size
		if (Test-Path $logFilePath) {
			if ((Get-Item $logFilePath).Length -gt 1GB) {
				Log-Message "Log reached 1GB. Stopping."; exit
			}
		}

		# 1. Send Pings: every target at the same moment. A target whose previous ping is still in flight
		#    (timeout longer than the interval, slow DNS lookup) is skipped until that ping finishes.
		foreach ($s in $pingStates) {
			if ($s.Task) { continue }
			$s.SentAt = Get-Date
			try { $s.Task = $s.Ping.SendPingAsync($s.Target, $pingTimeoutMs) }
			catch { $s.Error = $_.Exception.GetBaseException().Message }
		}

		# 2. Process Monitoring (runs while the pings are in flight)
		Check-Processes

		# 3. Network Info
		$netInfo = Get-NetworkInfo
		$currentBSSID = $netInfo.BSSID
		$currentIP = $netInfo.IPAddress
		$isWifi = ($netInfo.SSID -ne "N/A" -and $netInfo.Channel -ne "N/A")

		# 4. Roaming Detection (Wifi)
		if ($isWifi -and $previousBSSID -ne $currentBSSID -and $currentBSSID -ne "N/A" -and $previousBSSID -ne "N/A" -and $previousBSSID -ne "") {
			Log-Message "Wi-Fi ROAMING DETECTED. Switched from AP BSSID: $previousBSSID -> $currentBSSID | SSID: $($netInfo.SSID) | Channel: $($netInfo.Channel) | Signal: $($netInfo.Signal) | Rate: $($netInfo.RxRateMbps)/$($netInfo.TxRateMbps) Mbps"
		}

		# 5. IP Changes (Any Adapter)
		if ($previousIP -ne $currentIP -and $previousIP -ne "" -and $currentIP -ne "Unknown") {
			Log-Message "IP ADDRESS CHANGED. Adapter: $($netInfo.AdapterDesc) | Old IP: $previousIP | New IP: $currentIP | SSID: $($netInfo.SSID) | BSSID: $currentBSSID"
		}

		# Update tracked values
		if ($currentBSSID -ne "") { $previousBSSID = $currentBSSID }
		$previousIP = $currentIP

		# 6. Wait out the rest of the interval (pings normally finish within it)
		$sleepMs = [int]($pingIntervalMs - ((Get-Date) - $tickStart).TotalMilliseconds)
		if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }

		# 7. Connectivity State: log each finished ping, stamped with when it was sent so the order
		#    across targets is preserved. A ping still in flight is picked up on a later pass.
		foreach ($s in $pingStates) {
			if ($s.Error) { $ok = $false; $reason = $s.Error; $s.Error = $null }
			elseif ($s.Task -and $s.Task.IsCompleted) {
				if ($s.Task.IsFaulted) { $ok = $false; $reason = $s.Task.Exception.InnerException.GetBaseException().Message }	# e.g. DNS failure
				else { $reply = $s.Task.Result; $ok = ($reply.Status -eq 'Success'); $reason = $reply.Status }
				$s.Task = $null
			}
			else { continue }

			if ($ok -and $s.Up -ne $true) {
				Log-Message "Destination $($s.Target) ping RESTORED. Host: $clientHostname | IP: $currentIP | Adapter: $($netInfo.AdapterDesc) | SSID: $($netInfo.SSID) | Rate: $($netInfo.RxRateMbps)/$($netInfo.TxRateMbps) Mbps" -Time $s.SentAt
			}
			elseif (-not $ok -and $s.Up -ne $false) {
				Log-Message "Destination $($s.Target) ping LOST ($reason). Host: $clientHostname | IP: $currentIP | Adapter: $($netInfo.AdapterDesc) | SSID: $($netInfo.SSID)" -Time $s.SentAt
			}
			$s.Up = $ok
		}
	}
