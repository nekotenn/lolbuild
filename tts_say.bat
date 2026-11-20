@echo off
chcp 65001 >nul
rem 英語の台本（.txt）をこのファイルの上にドラッグ＆ドロップ → 同じ場所に .wav ができる
set "UV=%USERPROFILE%\.local\bin\uv.exe"
if not exist "%~dp0tts_ready.txt" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tts_setup.ps1"
"%UV%" run --python 3.12 --with kokoro-onnx --with soundfile "%~dp0tts_en.py" --file "%~1" --out "%~dpn1.wav" %2 %3 %4 %5
pause
