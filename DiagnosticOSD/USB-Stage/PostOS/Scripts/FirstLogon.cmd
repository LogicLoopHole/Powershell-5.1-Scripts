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
rem FirstLogon.cmd - STATIC file, lives on the USB at PostOS\Scripts\.
rem Target of the single RunOnce line 50-Configure-RunOnce.ps1 writes. Runs at the
rem first COMPLETED logon, in the logged-in user's session, so %USERPROFILE% expands
rem to the real, initialized Administrator profile (the whole reason the desktop copy
rem is deferred to first logon instead of written offline from WinPE).
rem
rem Add future first-logon actions HERE - edit this file on the USB; the RunOnce line
rem in the offline hive never changes again.
rem
rem The log below doubles as the timing probe: its timestamp records whether the
rem RunOnce fired at boot 1 (inside the FirstLogonCommands reboot window) or boot 2
rem (after the password change) - the observe-don't-assume item on the checklist.

robocopy "C:\Deploy\PostOS\Desktop" "%USERPROFILE%\Desktop" /E > C:\Deploy\FirstLogon.log 2>&1
