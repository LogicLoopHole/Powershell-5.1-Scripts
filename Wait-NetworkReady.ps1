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

$Target      = 'example.com'
$MaxAttempts = 30                    # total tries before giving up (~3 min)
$RenewEvery  = 6                     # release/renew DHCP on every Nth failed try

for ($i = 1; $i -le $MaxAttempts; $i++)
    {
        if (Test-Connection -ComputerName $Target -Count 1 -Quiet)
            {
                Write-Host "Network ready on attempt $i."
                exit 0
            }
        Write-Host "Attempt $i/$MaxAttempts - no response."

        if ($i % $RenewEvery -eq 0)
            {
                Write-Host "Nudging DHCP (release/renew)..."
                Invoke-CimMethod -ClassName Win32_NetworkAdapterConfiguration -MethodName ReleaseDHCPLeaseAll | Out-Null
                Invoke-CimMethod -ClassName Win32_NetworkAdapterConfiguration -MethodName RenewDHCPLeaseAll   | Out-Null
            }
        Start-Sleep -Seconds 3
    }
Write-Host "No connectivity after $MaxAttempts attempts - failing the task sequence."
exit 1
