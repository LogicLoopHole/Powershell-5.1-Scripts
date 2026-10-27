:: The MIT License (MIT)
::
:: Copyright (c) 2026 LogicLoopHole
::
:: Permission is hereby granted, free of charge, to any person obtaining a copy
:: of this software and associated documentation files (the "Software"), to deal
:: in the Software without restriction, including without limitation the rights
:: to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
:: copies of the Software, and to permit persons to whom the Software is
:: furnished to do so, subject to the following conditions:
::
:: The above copyright notice and this permission notice shall be included in all
:: copies or substantial portions of the Software.
::
:: THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
:: IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
:: FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
:: AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
:: LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
:: OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
:: SOFTWARE.
::

REM Defense in depth: refuse to run on anything that isn't a workstation (ProductType 1).
REM The orchestrator already enforces this; this guards the package if it is ever launched
REM by other means. Exits non-zero on a non-workstation or a failed query.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "exit [int]((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1)"
if errorlevel 1 (
    echo Refusing to run: not a workstation.
    exit /b 1
)

REM example using PSADT 4.1.5
"%~dp0Invoke-AppDeployToolkit.exe" -DeploymentType Uninstall -DeployMode Silent -SuppressRebootPassThru
