# 英語の読み上げ（Kokoro）を入れる。start.ps1 が裏で1回だけ動かす。手で動かしてもよい
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
try { Start-Transcript -Path (Join-Path $dir 'tts_setup_log.txt') -Append | Out-Null } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$uv = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
if (-not (Test-Path $uv)) {
  Write-Host 'uv（Pythonを自動で用意する道具）を入れます'
  Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
}
if (-not (Test-Path $uv)) { $c = Get-Command uv -ErrorAction SilentlyContinue; if ($c) { $uv = $c.Source } }
if (-not (Test-Path $uv)) { Write-Host 'uvが入りませんでした'; exit 1 }
$out = Join-Path $dir 'tts_test.wav'
& $uv run --python 3.12 --with kokoro-onnx --with soundfile (Join-Path $dir 'tts_en.py') --text 'Setup complete. The English voice is ready.' --out $out
if (Test-Path $out) { Set-Content -Path (Join-Path $dir 'tts_ready.txt') -Value (Get-Date).ToString('s') -Encoding UTF8; Write-Host '英語の声の準備ができました' }
