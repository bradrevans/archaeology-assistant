@echo off
setlocal
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
    "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" "%~dp0manage.py" deploy %*
) else (
    python "%~dp0manage.py" deploy %*
)
