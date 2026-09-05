@echo off
setlocal EnableExtensions

set "FAST_RA_INSTALL=%LOCALAPPDATA%\FAST\RaceAssistant"
set "FAST_RA_DATA=%FAST_RA_INSTALL%\data"
set "FAST_RA_STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "FAST_RA_LINK=%FAST_RA_STARTUP%\FAST-Race-Assistant.lnk"

if not exist "%FAST_RA_INSTALL%" mkdir "%FAST_RA_INSTALL%" >nul 2>nul
if not exist "%FAST_RA_DATA%" mkdir "%FAST_RA_DATA%" >nul 2>nul

if /I not "%~dp0"=="%FAST_RA_INSTALL%\" (
  copy /Y "%~dp0fast-race-assistant.ps1" "%FAST_RA_INSTALL%\fast-race-assistant.ps1" >nul
  copy /Y "%~dp0version.json" "%FAST_RA_INSTALL%\version.json" >nul
  copy /Y "%~f0" "%FAST_RA_INSTALL%\iniciar-fast-race-assistant.cmd" >nul
  copy /Y "%~dp0componente-interno-fast.vbs" "%FAST_RA_INSTALL%\componente-interno-fast.vbs" >nul
  copy /Y "%~dp0remover-fast-race-assistant.cmd" "%FAST_RA_INSTALL%\remover-fast-race-assistant.cmd" >nul
  if exist "%~dp0fast-emblem.png" copy /Y "%~dp0fast-emblem.png" "%FAST_RA_INSTALL%\fast-emblem.png" >nul
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$shell = New-Object -ComObject WScript.Shell; $shortcut = $shell.CreateShortcut($env:FAST_RA_LINK); $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'; $shortcut.Arguments = [char]34 + (Join-Path $env:FAST_RA_INSTALL 'componente-interno-fast.vbs') + [char]34; $shortcut.WorkingDirectory = $env:FAST_RA_INSTALL; $shortcut.WindowStyle = 7; $shortcut.Description = 'Auxiliar FAST de colagem sequencial, produzido por Fael Verstappen'; $shortcut.Save()" >nul 2>nul

start "" "%SystemRoot%\System32\wscript.exe" "%FAST_RA_INSTALL%\componente-interno-fast.vbs"
exit /b 0
