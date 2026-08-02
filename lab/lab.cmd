@echo off
REM ===========================================================================
REM  CJONS hands-on lab launcher for Windows
REM
REM  Use this instead of lab.ps1 when PowerShell refuses to run the script:
REM    * ExecutionPolicy is Restricted or AllSigned (the Windows default), or
REM    * the files came out of a downloaded .zip, so every file carries the
REM      Mark-of-the-Web and RemoteSigned blocks them.
REM
REM  This wrapper bypasses both for THIS ONE run only.
REM  It does not change any machine-wide or user-wide setting.
REM
REM    lab\lab.cmd          ->  enter the lab shell
REM    lab\lab.cmd build    ->  build the lab image (first time only)
REM    lab\lab.cmd verify   ->  run the full module verification once
REM ===========================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lab.ps1" %*
exit /b %ERRORLEVEL%
