@echo off
rem vacate.cmd - starts vacate.ps1 with Windows PowerShell (D62).
rem -ExecutionPolicy Bypass applies to this one process only; the system policy is not changed.
rem Example:  vacate scan    or    vacate plan -Run .\runs\20261120-101500
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vacate.ps1" %*
exit /b %ERRORLEVEL%
