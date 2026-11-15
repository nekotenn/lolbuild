# 週1のデータ更新（タスクスケジューラから自動で動く）
# 1) スウェイン・タムケンチのデータ  2) ブラインド（直近30日・エメラルド以上）  3) ブラインドのページを最新版に
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RAW = 'https://raw.githubusercontent.com/nekotenn/lolbuild/main/'
$UTF8 = New-Object System.Text.UTF8Encoding($false)
try { Start-Transcript -Path (Join-Path $dir 'weekly_log.txt') -Force | Out-Null } catch {}
Write-Host ('開始 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))

# ---- 1) スウェイン・タムケンチ ----
foreach ($c in @('swain', 'tahmkench')) {
  try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'fetch.ps1') -Champ $c } catch { Write-Host "[$c] 失敗: $_" }
}

# ---- 2) ブラインド ----
$root = Join-Path $env:USERPROFILE 'Downloads'
$bd = Join-Path $root 'BlindData'
$env:BLIND_ROOT = $root
# 質問には自動で答え（1: 直近30日 → 1: エメラルド以上）、ページやフォルダは開かない。別のPowerShellで動かす（途中で止まってもここは続く）
try {
  $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
  $core = $wc.DownloadString($RAW + 'blind/fetch_core.ps1?t=' + [DateTime]::Now.Ticks).TrimStart([char]0xFEFF)
  $pre = @'
$global:LB_ANS = New-Object System.Collections.Queue
'1', '1' | ForEach-Object { $global:LB_ANS.Enqueue($_) }
function Read-Host { param([Parameter(ValueFromRemainingArguments = $true)]$a) if ($global:LB_ANS.Count) { return $global:LB_ANS.Dequeue() } return '' }
function Start-Process { param([Parameter(ValueFromRemainingArguments = $true)]$a) }
'@
  $tmp = Join-Path $env:TEMP 'lol_blind_weekly.ps1'
  [IO.File]::WriteAllText($tmp, $pre + "`n" + $core, (New-Object System.Text.UTF8Encoding($true)))
  & powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
} catch { Write-Host "ブラインドの取得で失敗: $_" }

# 古いデータは消さずに sets_old へ移す（ランク帯ごとに一番新しい1つだけ残す。data.jsが大きくなりすぎないように）
try {
  $sets = Join-Path $bd 'sets'; $old = Join-Path $bd 'sets_old'
  New-Item -ItemType Directory -Force -Path $old | Out-Null
  $files = @(Get-ChildItem -Path $sets -Filter *.json | Sort-Object Name -Descending)
  $seen = @{}
  foreach ($f in $files) {
    $p = $f.BaseName.Split('_'); $key = ($p[1..($p.Count - 1)] -join '_')
    if ($seen[$key]) { Move-Item -Force $f.FullName (Join-Path $old $f.Name) } else { $seen[$key] = 1 }
  }
  # data.js を作り直す（顔の画像は今のdata.jsのものを使う）
  $dj = Join-Path $bd 'data.js'
  $icons = '{}'
  if (Test-Path $dj) { $t = [IO.File]::ReadAllText($dj, $UTF8); $i = $t.IndexOf('window.ICONS='); if ($i -ge 0) { $icons = $t.Substring($i + 13).TrimEnd().TrimEnd(';') } }
  $items = @(Get-ChildItem -Path $sets -Filter *.json | Sort-Object Name -Descending | ForEach-Object { [IO.File]::ReadAllText($_.FullName, $UTF8) })
  if ($items.Count) { [IO.File]::WriteAllText($dj, 'window.DATASETS=[' + ($items -join ",`n") + '];' + "`n" + 'window.ICONS=' + $icons + ';', $UTF8) }
} catch { Write-Host "整理で失敗: $_" }

# ---- 3) ブラインドのページを最新版に ----
try {
  $wc = New-Object Net.WebClient
  $wc.DownloadFile($RAW + 'blind/index.html?t=' + [DateTime]::Now.Ticks, (Join-Path $bd 'ブラインド順位.html'))
} catch { Write-Host "ページ更新で失敗: $_" }

Write-Host ('終了 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))
try { Stop-Transcript | Out-Null } catch {}
