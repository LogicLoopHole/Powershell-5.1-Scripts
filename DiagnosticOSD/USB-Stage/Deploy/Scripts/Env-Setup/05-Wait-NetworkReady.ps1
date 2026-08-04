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

# 00-Wait-NetworkReady.ps1
# Env-Setup - Waits for network before 10-Sync-Content.ps1 runs, nudging DHCP if it stalls.
# Warns and continues on failure; sync is the gate and owns the retry.

$Target      = 'Example.Domain'
$MaxAttempts = 30                    # total tries before giving up (~3 min)
$RenewEvery  = 6                     # release/renew DHCP on every Nth failed try

Write-Host "`n=== Wait for Network ===" -ForegroundColor Cyan

$Ready = $false

for ($i = 1; $i -le $MaxAttempts; $i++) {
    # -ErrorAction SilentlyContinue: -Quiet returns $false but still emits a resolver
    # error, which the orchestrator's Stop preference would turn into a hard failure.
    if (Test-Connection -ComputerName $Target -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "Network ready on attempt $i."
        $Ready = $true
        break
    }
    Write-Host "Attempt $i/$MaxAttempts - no response."

    if ($i % $RenewEvery -eq 0) {
        Write-Host "Nudging DHCP (release/renew)..."
        $Release = Invoke-CimMethod -ClassName Win32_NetworkAdapterConfiguration -MethodName ReleaseDHCPLeaseAll
        $Renew   = Invoke-CimMethod -ClassName Win32_NetworkAdapterConfiguration -MethodName RenewDHCPLeaseAll
        Write-Host "  Release returned $($Release.ReturnValue), renew returned $($Renew.ReturnValue). 0 = success."
    }

    Start-Sleep -Seconds 3

    # Piped to Write-Host so stderr cannot surface as an error record under Stop preference.
    & ipconfig /flushdns 2>&1 | Write-Host
}

if (-not $Ready) {
    Write-Warning "No connectivity to $Target after $MaxAttempts attempts."
    Write-Warning "Content sync runs next and will report the problem with a retry option."
}

pause
