@echo off
setlocal
cd /d "%~dp0"
echo ===================================================
echo Packaging Archaeology Assistant for Mod.io Upload
echo ===================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Package-Submission.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Packaging failed with error code %ERRORLEVEL%.
    pause
    exit /b %ERRORLEVEL%
)
echo.
pause
