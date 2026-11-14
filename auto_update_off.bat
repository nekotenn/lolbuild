@echo off
chcp 65001 >nul
schtasks /delete /f /tn "LoLビルド データ更新"
pause
