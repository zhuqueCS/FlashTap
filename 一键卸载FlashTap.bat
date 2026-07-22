@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title FlashTap - Full Reset

echo.
echo ╔══════════════════════════════════════════════╗
echo ║     FlashTap - Full Reset / Complete Cleanup ║
echo ╚══════════════════════════════════════════════╝
echo.
echo  [WARNING] This will remove ALL FlashTap components:
echo.
echo    - Ollama engine + models + data + service
echo    - VS Code (user-level) + extensions + settings
echo    - Continue plugin + config
echo    - Python 3.12 (if auto-installed by FlashTap)
echo    - WSL Ubuntu distro (if auto-installed by FlashTap)
echo    - All environment variables (OLLAMA_*)
echo    - All temp files, caches, logs
echo.
echo  [INFO] System-level VS Code/Ollama will be asked individually.
echo  [INFO] WSL feature itself will NOT be disabled.
echo.
echo  Press any key to continue, or close this window to cancel...
pause >nul

rem ============================================================
rem Step 1: Stop all Ollama processes
rem ============================================================
echo.
echo =============================================
echo   Step 1/10: Stop Ollama processes
echo =============================================
taskkill /f /im ollama.exe 2>nul
taskkill /f /im "ollama app.exe" 2>nul
sc stop ollama 2>nul
net stop ollama 2>nul
echo   Done.
echo.

rem ============================================================
rem Step 2: Remove Ollama engine
rem ============================================================
echo =============================================
echo   Step 2/10: Remove Ollama engine
echo =============================================

rem User-level Ollama
set "OLLAMA_USER=%LOCALAPPDATA%\Programs\Ollama"
if exist "%OLLAMA_USER%" (
    echo   Removing user-level Ollama: %OLLAMA_USER%
    rmdir /s /q "%OLLAMA_USER%" 2>nul
    if exist "%OLLAMA_USER%" (
        echo   [WARN] Directory locked, retrying after delay...
        timeout /t 3 /nobreak >nul
        rmdir /s /q "%OLLAMA_USER%" 2>nul
    )
) else (
    echo   No user-level Ollama found.
)

rem System-level Ollama (ask before removing)
set "OLLAMA_SYS=%ProgramFiles%\Ollama"
if exist "%OLLAMA_SYS%" (
    echo.
    echo   [WARNING] System-level Ollama found: %OLLAMA_SYS%
    set /p "REMOVE_SYS_OLLAMA=  Remove system-level Ollama? (y/N): "
    if /i "!REMOVE_SYS_OLLAMA!"=="y" (
        rmdir /s /q "%OLLAMA_SYS%" 2>nul
        echo   System-level Ollama removed.
    ) else (
        echo   Skipped system-level Ollama.
    )
)

rem Ollama Start Menu shortcut
if exist "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Ollama.lnk" (
    del /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Ollama.lnk" 2>nul
    echo   Removed Ollama Start Menu shortcut.
)
if exist "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Ollama.lnk" (
    del /q "%ProgramData%\Microsoft\Windows\Start Menu\Programs\Ollama.lnk" 2>nul
    echo   Removed system Ollama Start Menu shortcut.
)

rem Ollama Desktop shortcut
if exist "%USERPROFILE%\Desktop\Ollama.lnk" (
    del /q "%USERPROFILE%\Desktop\Ollama.lnk" 2>nul
    echo   Removed Ollama Desktop shortcut.
)

echo   Done.
echo.

rem ============================================================
rem Step 3: Remove Ollama models + data
rem ============================================================
echo =============================================
echo   Step 3/10: Remove Ollama models + data
echo =============================================

rem User .ollama directory
if exist "%USERPROFILE%\.ollama" (
    echo   Removing: %USERPROFILE%\.ollama
    rmdir /s /q "%USERPROFILE%\.ollama" 2>nul
)

rem D:\ollama_models
if exist "D:\ollama_models" (
    echo   Removing: D:\ollama_models
    rmdir /s /q "D:\ollama_models" 2>nul
)

rem D:\ollama_data
if exist "D:\ollama_data" (
    echo   Removing: D:\ollama_data
    rmdir /s /q "D:\ollama_data" 2>nul
)

rem LOCALAPPDATA ollama models
if exist "%LOCALAPPDATA%\ollama" (
    echo   Removing: %LOCALAPPDATA%\ollama
    rmdir /s /q "%LOCALAPPDATA%\ollama" 2>nul
)

rem Ollama cached installer in project directory
if exist "%~dp0OllamaSetup.exe" (
    echo   Removing: %~dp0OllamaSetup.exe
    del /q "%~dp0OllamaSetup.exe" 2>nul
)

echo   Done.
echo.

rem ============================================================
rem Step 4: Remove Ollama Windows service
rem ============================================================
echo =============================================
echo   Step 4/10: Remove Ollama Windows service
echo =============================================
sc query ollama 2>nul | findstr /i "SERVICE_NAME" >nul
if %errorlevel% equ 0 (
    echo   Stopping and removing Ollama Windows service...
    sc stop ollama 2>nul
    timeout /t 2 /nobreak >nul
    sc delete ollama 2>nul
    echo   Done.
) else (
    echo   No Ollama Windows service found.
)
echo.

rem ============================================================
rem Step 5: Remove VS Code (user-level)
rem ============================================================
echo =============================================
echo   Step 5/10: Remove VS Code
echo =============================================

rem Kill VS Code processes first
taskkill /f /im Code.exe 2>nul
timeout /t 2 /nobreak >nul

rem User-level VS Code
set "VSCODE_USER=%LOCALAPPDATA%\Programs\Microsoft VS Code"
if exist "%VSCODE_USER%" (
    echo   Removing user-level VS Code: %VSCODE_USER%
    rmdir /s /q "%VSCODE_USER%" 2>nul
    if exist "%VSCODE_USER%" (
        echo   [WARN] Directory locked, retrying after delay...
        timeout /t 3 /nobreak >nul
        rmdir /s /q "%VSCODE_USER%" 2>nul
    )
) else (
    echo   No user-level VS Code found.
)

rem System-level VS Code (ask before removing)
set "VSCODE_SYS=%ProgramFiles%\Microsoft VS Code"
if exist "%VSCODE_SYS%" (
    echo.
    echo   [WARNING] System-level VS Code found: %VSCODE_SYS%
    set /p "REMOVE_SYS_VSCODE=  Remove system-level VS Code? (y/N): "
    if /i "!REMOVE_SYS_VSCODE!"=="y" (
        rmdir /s /q "%VSCODE_SYS%" 2>nul
        echo   System-level VS Code removed.
    ) else (
        echo   Skipped system-level VS Code.
    )
)

rem VS Code Start Menu shortcut
if exist "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Visual Studio Code.lnk" (
    del /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Visual Studio Code.lnk" 2>nul
    echo   Removed VS Code Start Menu shortcut.
)

rem VS Code Desktop shortcut
if exist "%USERPROFILE%\Desktop\Visual Studio Code.lnk" (
    del /q "%USERPROFILE%\Desktop\Visual Studio Code.lnk" 2>nul
    echo   Removed VS Code Desktop shortcut.
)

echo   Done.
echo.

rem ============================================================
rem Step 6: Remove VS Code user data + extensions + Continue
rem ============================================================
echo =============================================
echo   Step 6/10: Remove VS Code user data + extensions
echo =============================================

rem VS Code user config (settings, keybindings, snippets)
if exist "%APPDATA%\Code" (
    echo   Removing VS Code user data: %APPDATA%\Code
    rmdir /s /q "%APPDATA%\Code" 2>nul
) else (
    echo   No VS Code user data found.
)

rem VS Code extensions
if exist "%USERPROFILE%\.vscode" (
    echo   Removing VS Code extensions: %USERPROFILE%\.vscode
    rmdir /s /q "%USERPROFILE%\.vscode" 2>nul
) else (
    echo   No VS Code extensions found.
)

rem VS Code shared storage
if exist "%USERPROFILE%\.vscode-shared" (
    rmdir /s /q "%USERPROFILE%\.vscode-shared" 2>nul
)

rem VS Code cached installer
if exist "%TEMP%\VSCodeUserSetup-x64-latest.exe" (
    del /q "%TEMP%\VSCodeUserSetup-x64-latest.exe" 2>nul
    echo   Removed VS Code cached installer.
)

rem VS Code install log
if exist "%TEMP%\vscode-install-log.log" (
    del /q "%TEMP%\vscode-install-log.log" 2>nul
)

echo   Done.
echo.

rem ============================================================
rem Step 7: Remove Continue config
rem ============================================================
echo =============================================
echo   Step 7/10: Remove Continue config
echo =============================================
if exist "%USERPROFILE%\.continue" (
    echo   Removing: %USERPROFILE%\.continue
    rmdir /s /q "%USERPROFILE%\.continue" 2>nul
) else (
    echo   No Continue config found.
)
echo   Done.
echo.

rem ============================================================
rem Step 8: Remove Python (if auto-installed by FlashTap)
rem ============================================================
echo =============================================
echo   Step 8/10: Remove Python 3.12 (FlashTap auto-install)
echo =============================================

rem FlashTap installs Python 3.12.7 with InstallAllUsers=1 to ProgramFiles
set "PY312=%ProgramFiles%\Python312"
if exist "%PY312%" (
    echo   Found Python 3.12 (system-level): %PY312%
    set /p "REMOVE_PYTHON=  Remove Python 3.12? (y/N): "
    if /i "!REMOVE_PYTHON!"=="y" (
        rmdir /s /q "%PY312%" 2>nul
        echo   Python 3.12 removed.
    ) else (
        echo   Skipped Python 3.12.
    )
) else (
    echo   No Python 3.12 found in ProgramFiles.
)

rem Python cached installer
if exist "%TEMP%\python-3.12.7-amd64.exe" (
    del /q "%TEMP%\python-3.12.7-amd64.exe" 2>nul
    echo   Removed Python cached installer.
)

rem Python user-level install
set "PY312_USER=%LOCALAPPDATA%\Programs\Python\Python312"
if exist "%PY312_USER%" (
    echo   Found Python 3.12 (user-level): %PY312_USER%
    set /p "REMOVE_PYTHON_USER=  Remove user-level Python 3.12? (y/N): "
    if /i "!REMOVE_PYTHON_USER!"=="y" (
        rmdir /s /q "%PY312_USER%" 2>nul
        echo   User-level Python 3.12 removed.
    ) else (
        echo   Skipped user-level Python 3.12.
    )
)

echo   Done.
echo.

rem ============================================================
rem Step 9: Remove WSL distro (if auto-installed by FlashTap)
rem ============================================================
echo =============================================
echo   Step 9/10: Remove WSL Ubuntu distro
echo =============================================

rem Check if WSL is available
wsl.exe --status >nul 2>&1
if %errorlevel% neq 0 (
    echo   WSL not available, skipping.
    goto :skip_wsl
)

rem List installed distros
echo   Installed WSL distros:
wsl.exe --list --quiet 2>nul

echo.
set /p "REMOVE_WSL=  Remove Ubuntu WSL distro? (y/N): "
if /i "!REMOVE_WSL!"=="y" (
    echo   Unregistering Ubuntu...
    wsl.exe --unregister Ubuntu 2>nul
    if %errorlevel% equ 0 (
        echo   Ubuntu distro removed.
    ) else (
        echo   Ubuntu not found or already removed.
    )

    rem Also try Ubuntu-22.04 and Ubuntu-24.04
    wsl.exe --unregister Ubuntu-22.04 2>nul
    wsl.exe --unregister Ubuntu-24.04 2>nul
) else (
    echo   Skipped WSL distro removal.
)

:skip_wsl
echo   Done.
echo.

rem ============================================================
rem Step 10: Remove environment variables + temp files + logs
rem ============================================================
echo =============================================
echo   Step 10/10: Remove env vars + temp + logs
echo =============================================

rem --- Environment variables ---
echo   Cleaning environment variables...

rem User-level env vars (setx sets user-level, reg delete is more reliable)
reg delete "HKCU\Environment" /v OLLAMA_HOST /f 2>nul
reg delete "HKCU\Environment" /v OLLAMA_ORIGINS /f 2>nul
reg delete "HKCU\Environment" /v OLLAMA_MAX_VRAM /f 2>nul
reg delete "HKCU\Environment" /v OLLAMA_NUM_PARALLEL /f 2>nul
reg delete "HKCU\Environment" /v OLLAMA_MODELS /f 2>nul
reg delete "HKCU\Environment" /v OLLAMA_HOME /f 2>nul

rem Also clear via setx (belt and suspenders)
setx OLLAMA_HOST "" 2>nul
setx OLLAMA_ORIGINS "" 2>nul
setx OLLAMA_MAX_VRAM "" 2>nul
setx OLLAMA_NUM_PARALLEL "" 2>nul
setx OLLAMA_MODELS "" 2>nul
setx OLLAMA_HOME "" 2>nul

rem System-level env vars (if FlashTap set them with /M)
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v OLLAMA_HOST /f 2>nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v OLLAMA_ORIGINS /f 2>nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v OLLAMA_MAX_VRAM /f 2>nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v OLLAMA_NUM_PARALLEL /f 2>nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v OLLAMA_MODELS /f 2>nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v OLLAMA_HOME /f 2>nul

echo   Environment variables cleaned.

rem --- FlashTap project temp files ---
echo   Cleaning FlashTap temp files...

if exist "%~dp0.flashtap-env.txt" del /q "%~dp0.flashtap-env.txt" 2>nul
if exist "%~dp0flashtap-user.txt" del /q "%~dp0flashtap-user.txt" 2>nul
if exist "%~dp0.wsl-distro-name" del /q "%~dp0.wsl-distro-name" 2>nul
if exist "%~dp0.ollama_latest_version" del /q "%~dp0.ollama_latest_version" 2>nul

rem --- Log files ---
if exist "%~dp0install.log" del /q "%~dp0install.log" 2>nul
if exist "%~dp0vscode-install.log" del /q "%~dp0vscode-install.log" 2>nul
if exist "%~dp0download.log" del /q "%~dp0download.log" 2>nul
if exist "%~dp0configure.log" del /q "%~dp0configure.log" 2>nul
if exist "%~dp0cpp-env.log" del /q "%~dp0cpp-env.log" 2>nul
if exist "%~dp0OldLogs" rmdir /s /q "%~dp0OldLogs" 2>nul

rem --- Model download cache ---
if exist "%~dp0models" (
    echo   Removing model cache: %~dp0models
    rmdir /s /q "%~dp0models" 2>nul
)

rem --- VS Code workspace file ---
if exist "%~dp0FlashTap-CPP.code-workspace" del /q "%~dp0FlashTap-CPP.code-workspace" 2>nul

rem --- Python __pycache__ ---
if exist "%~dp0__pycache__" rmdir /s /q "%~dp0__pycache__" 2>nul

echo   Done.
echo.

rem ============================================================
rem Final summary
rem ============================================================
echo.
echo ╔══════════════════════════════════════════════╗
echo ║        FlashTap Full Reset Complete!         ║
echo ╚══════════════════════════════════════════════╝
echo.
echo   Removed components:
echo     [OK] Ollama engine + models + service
echo     [OK] VS Code (user-level) + extensions + settings
echo     [OK] Continue plugin + config
echo     [OK] Environment variables (OLLAMA_*)
echo     [OK] All temp files, caches, logs
echo.
echo   Interactive choices (your decisions above):
echo     - System-level Ollama: !REMOVE_SYS_OLLAMA!
echo     - System-level VS Code: !REMOVE_SYS_VSCODE!
echo     - Python 3.12: !REMOVE_PYTHON!
echo     - WSL Ubuntu: !REMOVE_WSL!
echo.
echo   To reinstall, run: 一键安装FlashTap.bat
echo.
echo   [TIP] If you want a completely clean test, also:
echo     1. Restart the computer (release file locks + refresh PATH)
echo     2. Check Add/Remove Programs for any leftover entries
echo.
pause
exit /b