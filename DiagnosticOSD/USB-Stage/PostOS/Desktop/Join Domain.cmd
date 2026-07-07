:: The MIT License (MIT)
::
:: Copyright (c) 2025 LogicLoopHole
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

@echo off
rem Join Domain launcher - STATIC file, lives on the USB at PostOS\Desktop\.
rem Copied to the logged-in user's desktop at first logon by the RunOnce that
rem 50-Configure-RunOnce.ps1 writes. Runs elevated only because the built-in
rem Administrator is exempt from UAC Admin Approval Mode by default
rem (FilterAdministratorToken) - if the account model ever changes away from the
rem built-in, this needs an explicit elevation wrapper.
powershell.exe -ExecutionPolicy Bypass -File "C:\Deploy\PostOS\Scripts\Join-Domain.ps1"
