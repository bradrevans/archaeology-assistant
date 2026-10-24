@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-Plugin.ps1" -Deploy %*
