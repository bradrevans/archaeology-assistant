@echo off
setlocal
cd /d "%~dp0"
echo ===================================================
echo Packaging Archaeology Assistant for Mod.io Upload
echo ===================================================
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
    "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" "%~dp0manage.py" package %*
) else (
    python "%~dp0manage.py" package %*
)
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Packaging failed with error code %ERRORLEVEL%.
    pause
    exit /b %ERRORLEVEL%
)
echo.
pause
