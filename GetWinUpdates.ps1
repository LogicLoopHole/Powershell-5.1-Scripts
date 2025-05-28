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


# Configuration
$AppName = "Intel® Graphics Software"
$IgnoreCategories = @(
    #"Example1",
    #"Example2", 
    "Microsoft Defender Antivirus"
)

# Get reference application installation time (earliest event)
$ReferenceTime = $null
try
	{
		$AppEvent = Get-WinEvent -LogName Application -ErrorAction SilentlyContinue | 
			Where-Object { $_.ProviderName -like "MsiInstaller" -and $_.Message -match $AppName } |
			Sort-Object TimeCreated | Select-Object -First 1
		
		if ($AppEvent)
			{
				$ReferenceTime = $AppEvent.TimeCreated
				Write-Host "$AppName reference time found (earliest): $($ReferenceTime.ToString())" -ForegroundColor Green
			}
		else
			{
				Write-Host "$AppName installation event not found. All updates will be marked the same." -ForegroundColor Yellow
			}
	}
catch
	{
		Write-Host "Error accessing event log: $($_.Exception.Message)" -ForegroundColor Red
	}

# Get update history
$Session = New-Object -ComObject Microsoft.Update.Session
$Searcher = $Session.CreateUpdateSearcher()
$HistoryCount = $Searcher.GetTotalHistoryCount()
$Updates = $Searcher.QueryHistory(0,$HistoryCount)

# Process updates with filtering
$Updates | Select-Object Title,
    @{l='Category'; e={$($_.Categories).Name}},
    @{l='Date'; e={$_.Date.ToLocalTime()}},
    @{l='TimeFrame'; e={
        $updateTime = $_.Date.ToLocalTime()
        if ($ReferenceTime -and $updateTime -gt $ReferenceTime)
			{
				"After"
			}
		else
			{
				"Before"
			}
		}
	}	|
    Where-Object { 
        $categoryNames = $_.Category
        $shouldIgnore = $false
        
        # Check if any of the update's categories match our ignore list
        foreach ($ignoreCategory in $IgnoreCategories)
			{
				if ($categoryNames -match $ignoreCategory)
					{
						$shouldIgnore = $true
						break
					}
			}
        
        -not $shouldIgnore
		}	|
    Sort-Object Date -Descending |
    Out-GridView
