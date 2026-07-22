@echo off
cd /d "%~dp0"
title FlashTap Installer

REM Unblock all files (Mark-of-the-Web from GitHub ZIP / browser download)
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem '%~dp0' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

REM Detect admin rights (dual method for Win10/Win11 compatibility)
set ADMIN=0
net session >nul 2>&1 && set ADMIN=1
if %ADMIN%==0 whoami /groups 2>nul | findstr /i "S-1-16-12288" >nul 2>&1 && set ADMIN=1

if %ADMIN%==0 (
    echo =============================================
    echo   FlashTap - ERROR
    echo =============================================
    echo.
    echo No administrator privileges detected.
    echo.
    echo HOW TO FIX:
    echo   1. Close this window
    echo   2. Right-click this BAT file
    echo   3. Select "Run as Administrator"
    echo   4. Click "Yes" in UAC dialog
    echo.
    echo This window will close in 10 seconds...
    timeout /t 10 >nul
    exit /b 1
)

echo =============================================
echo   FlashTap - Installing...
echo =============================================
echo.
echo Admin OK. User: %USERNAME%
echo Installing to: %USERPROFILE%
echo.

echo Running pre-flight check...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0preflight-check.ps1"
echo.

echo Running main installer...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-FlashTap.ps1"
set RC=%errorlevel%

echo.
if %RC% neq 0 (
    echo =============================================
    echo   Done with errors (code: %RC%)
    echo   See install.log for details
    echo =============================================
) else (
    echo =============================================
    echo   Installation complete!
    echo   See install.log for details
    echo =============================================
)
echo.
echo Press any key to close...
pause >nul
exit /b %RC%
