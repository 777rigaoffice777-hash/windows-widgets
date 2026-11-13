# Builds release\windows-widgets.zip: official AutoHotkey 2.0.31 (hash-checked) + both widgets + installer.
# Usage (from the repo root):  pwsh -File release\build-release.ps1
# Then:  gh release create vN release\windows-widgets.zip   (the install link always points to the latest release)
$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$out    = Join-Path $PSScriptRoot 'windows-widgets.zip'
$work   = Join-Path ([IO.Path]::GetTempPath()) 'ww-build'
$ahkVer = '2.0.31'
$zipSha = 'CA1A595ACA4528755D8D4CD7FED23D497A37BD9A0B6892072612D68DEE1BD00A'
$exeSha = '5073EE85DA091653C7C6CE32CACDA3A0B4BFB51649823C10015BA0BD71ACB73C'

if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$bundle = Join-Path $work 'windows-widgets'
New-Item -ItemType Directory -Force $bundle | Out-Null
$ahkZip = Join-Path $work 'ahk.zip'
Invoke-WebRequest -UseBasicParsing "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$ahkVer/AutoHotkey_$ahkVer.zip" -OutFile $ahkZip
if ((Get-FileHash $ahkZip).Hash -ne $zipSha) { throw 'AutoHotkey zip hash mismatch' }
& (Join-Path $env:WINDIR 'System32\tar.exe') -xf $ahkZip -C $bundle AutoHotkey64.exe license.txt   # Windows tar, not Git's GNU tar
if ((Get-FileHash (Join-Path $bundle 'AutoHotkey64.exe')).Hash -ne $exeSha) { throw 'AutoHotkey64.exe hash mismatch' }
Copy-Item (Join-Path $PSScriptRoot 'install-widgets.cmd'), (Join-Path $PSScriptRoot 'README.txt') $bundle
Copy-Item (Join-Path $root 'LockToggle\LockToggle.ahk'), (Join-Path $root 'WeekCalendar\WeekCalendar.ahk') $bundle
Compress-Archive -Path $bundle -DestinationPath $out -Force
Remove-Item $work -Recurse -Force
Get-Item $out | Select-Object FullName, Length