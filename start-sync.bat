@echo off
cd /d "%~dp0deployment\local-mysql-sync"

:restart
call npm start
echo Worker stopped. Restarting in 10 seconds...
timeout /t 10 /nobreak >nul
goto restart
