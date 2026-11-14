@echo off
chcp 65001 >nul
schtasks /create /f /tn "LoLビルド データ更新" /sc weekly /d SUN /st 10:00 /tr "\"%~dp0update_auto.bat\""
if errorlevel 1 (echo 登録できませんでした。) else (echo 毎週日曜10時にデータを自動で取り直すよう登録しました。PCが起動していないと飛ばされます。)
pause
