@echo off
title PyroGuard - Camera secure link (keep open)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-camera-tunnel.ps1" %*
pause
