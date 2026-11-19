@echo off
rem Runs from this script's own folder, wherever the project was extracted.
cd /d "%~dp0"

:restart
call npm start
timeout /t 10 /nobreak >nul
goto restart
