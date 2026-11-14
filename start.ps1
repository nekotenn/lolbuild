# ショートカットから起動：最新版を取得→データが無ければ取得→サーバー起動→ブラウザのタブで開く
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$URL = 'http://localhost:8765/'
# --- 自動アップデート（GitHubの最新版に置き換える。失敗しても今の版で起動する）---
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $RAW = 'https://raw.githubusercontent.com/nekotenn/lolbuild/main/'
  $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
  $files = ($wc.DownloadString($RAW + 'files.txt') -split "`r?`n") | Where-Object { $_ -match '^[\w.-]+$' }
  $n = 0
  foreach ($f in $files) {
    $tmp = Join-Path $dir ($f + '.new')
    $wc.DownloadFile($RAW + $f + '?t=' + [DateTime]::Now.Ticks, $tmp)
    $old = Join-Path $dir $f
    if (-not (Test-Path $old) -or ((Get-FileHash $tmp).Hash -ne (Get-FileHash $old).Hash)) { Move-Item -Force $tmp $old; $n++ } else { Remove-Item $tmp }
  }
  if ($n -gt 0) { Write-Host "最新版に更新しました（$n ファイル）" }
} catch { Write-Host '更新の確認はスキップしました（オフラインなど）' }
# --- デスクトップに「ツール置き場」が無ければ作る ---
try {
  $hub = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ツール置き場.url'
  if (-not (Test-Path $hub)) {
    [IO.File]::WriteAllText($hub, "[InternetShortcut]`r`nURL=https://nekotenn.github.io/lolbuild/tools.html`r`n", [Text.Encoding]::ASCII)
    Write-Host 'デスクトップに「ツール置き場」を作りました'
  }
} catch {}
foreach ($c in @('swain', 'tahmkench')) {
  if (-not (Test-Path (Join-Path $dir "data_$c.json"))) {
    Write-Host "初回なので [$c] のデータを取ります。"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'fetch.ps1') -Champ $c
  }
}
$alive = $false
try { $null = Invoke-WebRequest ($URL + 'ping') -UseBasicParsing -TimeoutSec 1; $alive = $true } catch {}
if (-not $alive) {
  Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $dir 'server.ps1') + '"') -WorkingDirectory $dir
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 400
    try { $null = Invoke-WebRequest ($URL + 'ping') -UseBasicParsing -TimeoutSec 1; $alive = $true; break } catch {}
  }
}
if ($alive) { Start-Process $URL }
else {
  # サーバーが動かないときも、ページだけは開く（ピックの自動読み取りと戦績記録は止まる）
  Write-Host 'サーバーが起動しなかったので、ページを直接開きます。'
  Start-Process (Join-Path $dir 'index.html')
}
