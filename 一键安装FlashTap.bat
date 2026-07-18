@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title FlashTap - One-Click Install

echo =============================================
echo   FlashTap - AI Programming Assistant
echo   One-Click Install
echo =============================================
echo.
echo [INFO] This installation takes 10-20 minutes
echo [INFO] Fully automatic, please do not close this window
echo.

rem Check administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Requesting administrator privileges...
    echo [INFO] Original user: %USERNAME%
    rem Write original user info to script directory (NOT %%TEMP%% - different user after elevation!)
    (echo FLASHTAP_ORIGINAL_USER=%USERNAME%)> "%~dp0flashtap-user.txt"
    (echo FLASHTAP_ORIGINAL_PROFILE=%USERPROFILE%)>> "%~dp0flashtap-user.txt"
    echo [INFO] User context saved to: %~dp0flashtap-user.txt
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem Read original user info from script directory (written before elevation)
if exist "%~dp0flashtap-user.txt" (
    echo [INFO] Reading user context from: %~dp0flashtap-user.txt
    for /f "tokens=1,* delims==" %%a in (%~dp0flashtap-user.txt) do (
        set "%%a=%%b"
    )
) else (
    echo [WARNING] User context file not found, using current user
)

rem If original user info was passed (multi-user scenario), use it
if not "%FLASHTAP_ORIGINAL_USER%"=="" (
    echo [INFO] Original user context restored: %FLASHTAP_ORIGINAL_USER%
) else (
    set "FLASHTAP_ORIGINAL_USER=%USERNAME%"
    set "FLASHTAP_ORIGINAL_PROFILE=%USERPROFILE%"
)

echo [INFO] Administrator check passed
echo [INFO] Target user: %FLASHTAP_ORIGINAL_USER%
echo [INFO] Launching main installer...
echo.

rem 切换到脚本目录（提权后工作目录可能是 System32，必须切回来）
cd /d "%~dp0"

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-FlashTap.ps1" -OriginalUsername "%FLASHTAP_ORIGINAL_USER%" -OriginalUserProfile "%FLASHTAP_ORIGINAL_PROFILE%"

echo.
echo Installation finished. Press any key to exit...
pause >nul
exit /b