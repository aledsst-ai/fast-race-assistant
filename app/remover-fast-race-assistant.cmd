@echo off
setlocal EnableExtensions
set "FAST_RA_LINK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\FAST-Race-Assistant.lnk"
if exist "%FAST_RA_LINK%" del /F /Q "%FAST_RA_LINK%" >nul 2>nul
taskkill /FI "WINDOWTITLE eq FAST Race Assistant" /T /F >nul 2>nul
echo Inicializacao automatica removida.
pause
