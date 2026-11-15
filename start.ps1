# ショートカットから起動：最新版を取得→データが無ければ取得→サーバー起動→ブラウザのタブで開く
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$URL = 'http://localhost:8765/'
try { Start-Transcript -Path (Join-Path $dir 'start_log.txt') -Append | Out-Null } catch {}
# --- 自動アップデート（GitHubの最新版に置き換える。失敗しても今の版で起動する）---
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $RAW = 'https://raw.githubusercontent.com/nekotenn/lolbuild/main/'
  $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
  $files = ($wc.DownloadString($RAW + 'files.txt') -split "`r?`n") | Where-Object { $_ -match '^[\w.-]+$' }
  $n = 0; $selfChanged = $false
  foreach ($f in $files) {
    $tmp = Join-Path $dir ($f + '.new')
    $wc.DownloadFile($RAW + $f + '?t=' + [DateTime]::Now.Ticks, $tmp)
    $old = Join-Path $dir $f
    if (-not (Test-Path $old) -or ((Get-FileHash $tmp).Hash -ne (Get-FileHash $old).Hash)) { Move-Item -Force $tmp $old; $n++; if ($f -eq 'start.ps1') { $selfChanged = $true } } else { Remove-Item $tmp }
  }
  if ($n -gt 0) { Write-Host "最新版に更新しました（$n ファイル）" }
  # 起動手順そのものが新しくなったら、新しい手順で起動し直す（1回だけ）
  if ($selfChanged -and -not $env:LB_RESTARTED) {
    $env:LB_RESTARTED = '1'
    Write-Host '新しい起動手順で起動し直します'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'start.ps1')
    exit
  }
} catch { Write-Host '更新の確認はスキップしました（オフラインなど）' }
# --- デスクトップに「ツール置き場」が無ければ作る ---
try {
  $hub = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ツール置き場.url'
  if (-not (Test-Path $hub)) {
    [IO.File]::WriteAllText($hub, "[InternetShortcut]`r`nURL=https://nekotenn.github.io/lolbuild/tools.html`r`n", [Text.Encoding]::ASCII)
    Write-Host 'デスクトップに「ツール置き場」を作りました'
  }
} catch {}
# --- 週1のデータ更新を登録（毎週日曜10時。PCが切れていたら次に起動したとき動く）---
try {
  $ps = Join-Path $dir 'weekly.ps1'
  if (Test-Path $ps) {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps + '"') -WorkingDirectory $dir
    $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 10:00
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    $null = Register-ScheduledTask -TaskName 'LoLツール 週1データ更新' -Action $act -Trigger $trg -Settings $set -Force
    Unregister-ScheduledTask -TaskName 'LoLビルド データ更新' -Confirm:$false -ErrorAction SilentlyContinue
  }
} catch { Write-Host '週1の自動更新は登録できませんでした' }
foreach ($c in @('swain', 'tahmkench')) {
  $df = Join-Path $dir "data_$c.json"
  $old = $false
  if (Test-Path $df) {
    $head = (Get-Content $df -TotalCount 1 -Encoding UTF8)
    if ($head.Length -gt 300) { $head = $head.Substring(0, 300) }
    $old = (-not $head.Contains('"tier"')) -or (-not (Test-Path (Join-Path $dir "data_$c.js"))) -or ((Get-Item $df).LastWriteTime -lt (Get-Date).AddDays(-8))
  }
  if (-not (Test-Path $df) -or $old) {
    Write-Host "[$c] のデータを新しく取ります（数分）。"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'fetch.ps1') -Champ $c
  }
}
$alive = $false
try { $null = Invoke-WebRequest ($URL + 'ping') -UseBasicParsing -TimeoutSec 1; $alive = $true } catch {}
if ($alive) { Start-Process $URL; exit }
# サーバーは別の窓ではなく、この窓の中で動かす（別の窓だと起動に失敗しても分からないため）
# 先に「少し待ってからページを開く」係を裏で動かしておく
Start-Job -ArgumentList $URL, (Join-Path $dir 'index.html') -ScriptBlock {
  param($u, $fallback)
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    try { $null = Invoke-WebRequest ($u + 'ping') -UseBasicParsing -TimeoutSec 1; Start-Process $u; return } catch {}
  }
  Start-Process $fallback
} | Out-Null
Write-Host 'サーバーを起動します（この窓を閉じると、ピックの自動読み取りが止まります）'
try { & (Join-Path $dir 'server.ps1') }
catch {
  $msg = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' サーバーが止まりました: ' + $_.Exception.Message
  try { Add-Content -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'LoLビルド_エラー.txt') -Value $msg -Encoding UTF8 } catch {}
  Write-Host $msg
  Read-Host 'Enterで閉じる'
}
