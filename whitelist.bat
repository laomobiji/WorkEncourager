@echo off
REM ============================================================
REM  WorkEncourager - add itself to Windows Defender whitelist
REM  (fix antivirus false positives for this unsigned script)
REM  Run: double-click. UAC prompt = click Yes.
REM ============================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set "HERE=%~dp0"
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%HERE%'; Add-MpPreference -ExclusionPath \"$env:APPDATA\WorkEncourager\""
if %errorlevel% equ 0 (
    echo.
    echo [OK] Added to Windows Defender whitelist:
    echo      %HERE%
    echo      %APPDATA%\WorkEncourager
) else (
    echo.
    echo [FAIL] Could not set Defender exclusions.
    echo        If you use 360/Huorong/etc, add the whitelist manually in its settings.
)
echo.
pause
