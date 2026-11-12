# windows-widgets installer: AutoHotkey v2 (portable, from the official AutoHotkey GitHub release) + both widgets.
# Run in PowerShell (no admin rights needed):
#   irm https://raw.githubusercontent.com/777rigaoffice777-hash/windows-widgets/main/install.ps1 | iex
# Uses only basic cmdlets, so it also works in PowerShell Constrained Language Mode (Smart App Control).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo   = 'https://raw.githubusercontent.com/777rigaoffice777-hash/windows-widgets/main'
$ahkVer = '2.0.31'
$zipSha = 'CA1A595ACA4528755D8D4CD7FED23D497A37BD9A0B6892072612D68DEE1BD00A'   # AutoHotkey_2.0.31.zip
$exeSha = '5073EE85DA091653C7C6CE32CACDA3A0B4BFB51649823C10015BA0BD71ACB73C'   # AutoHotkey64.exe inside it
$ahkDir = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2'
$ahk    = Join-Path $ahkDir 'AutoHotkey64.exe'
$tmp    = Join-Path $env:TEMP 'windows-widgets-setup'

try {
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Write-Host 'Установка виджетов «Блокировка экрана» и «Календарь недель»'
    Write-Host ''

    if (Test-Path $ahk) {
        Write-Host "1/3  AutoHotkey уже установлен."
    } else {
        Write-Host "1/3  Скачиваю AutoHotkey $ahkVer с официального GitHub..."
        $zip = Join-Path $tmp 'AutoHotkey.zip'
        Invoke-WebRequest -UseBasicParsing "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$ahkVer/AutoHotkey_$ahkVer.zip" -OutFile $zip
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $zipSha) { throw 'контрольная сумма архива AutoHotkey не совпала, установка остановлена' }
        New-Item -ItemType Directory -Force $ahkDir | Out-Null
        tar.exe -xf $zip -C $ahkDir AutoHotkey64.exe license.txt
        if (-not (Test-Path $ahk)) { throw 'не удалось распаковать AutoHotkey' }
        if ((Get-FileHash $ahk -Algorithm SHA256).Hash -ne $exeSha) { throw 'контрольная сумма AutoHotkey64.exe не совпала, установка остановлена' }
    }

    Write-Host '2/3  Скачиваю виджеты...'
    $files = @()
    foreach ($n in 'LockToggle', 'WeekCalendar') {
        $f = Join-Path $tmp "$n.ahk"
        Invoke-WebRequest -UseBasicParsing "$repo/$n/$n.ahk" -OutFile $f
        $files += $f
    }

    Write-Host '3/3  Устанавливаю и запускаю...'
    foreach ($f in $files) {
        # Not "Start-Process -Wait": it would also wait for the widget that --install starts (it never exits).
        $p = Start-Process -FilePath $ahk -ArgumentList "`"$f`"", '--install' -PassThru
        Wait-Process -Id $p.Id -Timeout 60 -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0) { throw "виджет $(Split-Path $f -Leaf) не установился (код $($p.ExitCode))" }
    }

    Write-Host ''
    Write-Host 'Готово! Виджеты уже на рабочем столе и сами запускаются при входе в Windows.'
    Write-Host 'Обновления приходят сами раз в день. Настройки — правой кнопкой мыши по виджету.'
} catch {
    Write-Host ''
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Сделайте, пожалуйста, снимок этого окна и пришлите его.'
}
