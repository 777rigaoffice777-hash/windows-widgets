@echo off
chcp 65001 >nul
title Установка виджетов
cd /d "%~dp0"
echo Установка виджетов «Блокировка экрана» и «Календарь недель»
echo.
if not exist "%~dp0AutoHotkey64.exe" goto notextracted
if not exist "%~dp0LockToggle.ahk" goto notextracted
if not exist "%~dp0WeekCalendar.ahk" goto notextracted

set "AHKDIR=%LOCALAPPDATA%\Programs\AutoHotkey\v2"
set "AHK=%AHKDIR%\AutoHotkey64.exe"
if exist "%AHK%" goto haveahk
echo 1/2  Копирую AutoHotkey в папку программ...
mkdir "%AHKDIR%" 2>nul
copy /y "%~dp0AutoHotkey64.exe" "%AHK%" >nul
copy /y "%~dp0license.txt" "%AHKDIR%\license.txt" >nul
if not exist "%AHK%" goto failed
:haveahk

echo 2/2  Устанавливаю и запускаю виджеты...
start "" /wait "%AHK%" "%~dp0LockToggle.ahk" --install
if errorlevel 1 goto failed
start "" /wait "%AHK%" "%~dp0WeekCalendar.ahk" --install
if errorlevel 1 goto failed

echo.
echo Готово! Виджеты уже на рабочем столе и сами запускаются при входе в Windows.
echo Обновления приходят сами раз в день. Настройки — правой кнопкой мыши по виджету.
echo Эту папку теперь можно удалить.
goto end

:notextracted
echo Сначала распакуйте архив: правой кнопкой мыши по архиву — «Извлечь все…»,
echo затем откройте этот файл в распакованной папке.
goto end

:failed
echo.
echo Не получилось установить. Сделайте, пожалуйста, снимок этого окна и пришлите его.

:end
echo.
echo Окно закроется через 60 секунд.
timeout /t 60 >nul