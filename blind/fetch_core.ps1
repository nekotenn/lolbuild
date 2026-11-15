
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UTF8 = New-Object System.Text.UTF8Encoding($false)

$root = $env:BLIND_ROOT
if (-not $root) { $root = (Get-Location).Path }
$dir = Join-Path $root 'BlindData'
$setsDir = Join-Path $dir 'sets'
New-Item -ItemType Directory -Force -Path $dir, $setsDir | Out-Null
# 何かあったときに原因を見られるよう、画面の記録を残す
try { Start-Transcript -Path (Join-Path $dir 'last_run_log.txt') -Force | Out-Null } catch {}
trap {
  Write-Host ''
  Write-Host ('止まりました：' + $_) -ForegroundColor Red
  Write-Host 'BlindDataフォルダの「last_run_log.txt」をチャットに送ってもらえれば、原因を調べられます。' -ForegroundColor Yellow
  try { Stop-Transcript | Out-Null } catch {}
  break
}

function Show-Finish {
  $dj = Join-Path $dir 'data.js'
  $files = @(Get-ChildItem -Path $setsDir -Filter *.json | Sort-Object Name -Descending)
  Write-Host ''
  Write-Host '──────────────────────────────' -ForegroundColor Cyan
  Write-Host ('今入っているデータ：' + $files.Count + '件') -ForegroundColor Cyan
  foreach ($f in $files) {
    $t = [IO.File]::ReadAllText($f.FullName, $UTF8)
    $lm = [regex]::Match($t, '"label":"([^"]*)"')
    Write-Host ('  ・' + $lm.Groups[1].Value)
  }
  Write-Host ''
  Write-Host 'ネット版に入れるファイル：' -ForegroundColor Cyan
  Write-Host ('  ' + $dj)
  Write-Host '  （エクスプローラーで、このファイルを選んだ状態で開きます。ネット版の「📂 データを読み込む」で、このファイルを選ぶか、ページにドラッグしてください）'
  Write-Host '──────────────────────────────' -ForegroundColor Cyan
  try { Start-Process explorer.exe ('/select,"' + $dj + '"') } catch {}
  try { Stop-Transcript | Out-Null } catch {}
}

# ---- 結果ページを書き出す（毎回最新に） ----
$htmlPath = Join-Path $dir 'ブラインド順位.html'
if ($p -and $p.Count -ge 3) { [IO.File]::WriteAllText($htmlPath, $p[2].TrimStart(), $UTF8) }

# ---- キャラの顔（Riot公式の画像を小さくしてPCに保存し、data.jsに入れる） ----
function Get-IconsJson {
  try {
    $v0 = (Invoke-RestMethod 'https://ddragon.leagueoflegends.com/api/versions.json')[0]
    $cj0 = Invoke-RestMethod ("https://ddragon.leagueoflegends.com/cdn/$v0/data/en_US/champion.json")
  } catch { Write-Host '（顔の画像は取れませんでした。数字はそのまま使えます）' -ForegroundColor Yellow; return '{}' }
  $iconDir = Join-Path $dir ('icons\' + $v0)
  New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
  $canDraw = $true
  $resize = $null
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $resize = [scriptblock]::Create(@'
param($bytes)
$src = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
$bmp = New-Object System.Drawing.Bitmap 48, 48
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = 7
$g.DrawImage($src, 0, 0, 48, 48); $g.Dispose()
$ms = New-Object IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$r = $ms.ToArray(); $bmp.Dispose(); $src.Dispose()
, $r
'@)
  } catch { $canDraw = $false }
  $wc = New-Object Net.WebClient
  $parts = @()
  $ids = @($cj0.data.PSObject.Properties | ForEach-Object { $_.Value.id })
  $k = 0
  foreach ($id in $ids) {
    $k++
    $f = Join-Path $iconDir ($id + '.png')
    if (-not (Test-Path -LiteralPath $f)) {
      Write-Progress -Activity 'キャラの顔を取得中（初回だけ）' -Status ("$k / " + $ids.Count + '  ' + $id) -PercentComplete ([int](100 * $k / $ids.Count))
      try {
        $bytes = $wc.DownloadData("https://ddragon.leagueoflegends.com/cdn/$v0/img/champion/$id.png")
        $out = $bytes
        if ($canDraw) {
          try { $out = & $resize $bytes } catch { $out = $bytes; $canDraw = $false }
          if ($null -eq $out) { $out = $bytes }
        }
        [IO.File]::WriteAllBytes($f, $out)
      } catch { continue }
    }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))
    $parts += ('"' + $id + '":"data:image/png;base64,' + $b64 + '"')
  }
  Write-Progress -Activity 'キャラの顔' -Completed
  return '{' + ($parts -join ',') + '}'
}

function Write-DataJs {
  $items = @()
  Get-ChildItem -Path $setsDir -Filter *.json | Sort-Object Name -Descending | ForEach-Object {
    $items += [IO.File]::ReadAllText($_.FullName, $UTF8)
  }
  $icons = '{}'
  try { $icons = Get-IconsJson } catch { Write-Host '（顔の画像は取れませんでした。数字はそのまま使えます）' -ForegroundColor Yellow }
  if (-not $icons) { $icons = '{}' }
  $js = 'window.DATASETS=[' + ($items -join ",`n") + '];' + "`n" + 'window.ICONS=' + $icons + ';'
  [IO.File]::WriteAllText((Join-Path $dir 'data.js'), $js, $UTF8)
}

$tierName = @{ 'emerald_plus'='エメラルド+'; 'all'='全ランク'; 'diamond_plus'='ダイヤ+'; 'master_plus'='マスター+'; 'platinum_plus'='プラチナ+' }
$lanes = @('top', 'jungle', 'middle', 'bottom', 'support')
$MERGE_DAYS = 5

function Has-Key($d, $k) { if ($null -eq $d) { return $false }; return (@($d.Keys) -contains $k) }
function Get-Val($d, $k) { if (Has-Key $d $k) { return $d[$k] }; return $null }

function Make-Label($kind, $patch, $tier, $start, $date) {
  if ($kind -eq '30d') { $pl = '直近30日' } elseif ($patch) { $pl = 'パッチ ' + $patch } else { $pl = '今のパッチ' }
  $d = $start
  if ($date -ne $start) { $d = $start + '〜' + $date.Substring(5) }
  return $pl + ' / ' + $tierName[$tier] + ' / ' + $d
}

Write-Host ''
Write-Host '=== ブラインド強さ 計算ツール（AIは使いません） ===' -ForegroundColor Cyan
Write-Host ''
Write-Host '何をしますか？'
Write-Host '  1: 直近30日のデータを新しく全部取る'
Write-Host '  2: 今のパッチのデータを新しく全部取る'
Write-Host '  3: 前のデータの足りない分だけ取って付け足す（補強）'
Write-Host '  4: 取らずに結果ページだけ開く'
$c = Read-Host '番号を入れてEnter（そのままEnterで1）'
if ($c -eq '4') { Write-DataJs; Start-Process $htmlPath; Show-Finish; return }

$today = Get-Date -Format 'yyyy-MM-dd'
$todayKey = Get-Date -Format 'yyyyMMdd'
$out = [ordered]@{}
$oldFile = $null; $start = $today; $oldPatch = ''

if ($c -eq '3') {
  $files = @(Get-ChildItem -Path $setsDir -Filter *.json | Sort-Object Name -Descending)
  if ($files.Count -eq 0) { Write-Host 'まだデータがありません。先に 1 か 2 で取ってください。' -ForegroundColor Yellow; return }
  Write-Host ''
  Write-Host 'どのデータを補強しますか？'
  for ($n = 0; $n -lt $files.Count; $n++) {
    $txt0 = [IO.File]::ReadAllText($files[$n].FullName, $UTF8)
    $lm = [regex]::Match($txt0, '"label":"([^"]*)"')
    Write-Host ('  ' + ($n + 1) + ': ' + $lm.Groups[1].Value)
  }
  $sel = Read-Host '番号を入れてEnter（そのままEnterで1）'
  $si = 0; if ($sel -match '^\d+$') { $si = [int]$sel - 1 }
  if ($si -lt 0 -or $si -ge $files.Count) { $si = 0 }
  $oldFile = $files[$si]
  Add-Type -AssemblyName System.Web.Extensions
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.MaxJsonLength = [int]::MaxValue
  $ser.RecursionLimit = 200
  $old = $ser.DeserializeObject([IO.File]::ReadAllText($oldFile.FullName, $UTF8))
  $fp = $oldFile.BaseName.Split('_')
  $kind = (Get-Val $old 'kind'); if (-not $kind) { $kind = $fp[1] }
  $tier = (Get-Val $old 'tier'); if (-not $tier) { $tier = ($fp[2..($fp.Count - 1)] -join '_') }
  $start = (Get-Val $old 'start'); if (-not $start) { $start = (Get-Val $old 'date') }
  $oldPatch = (Get-Val $old 'patch')
  if ($kind -eq '30d') {
    $age = ((Get-Date) - [datetime]::ParseExact($start, 'yyyy-MM-dd', $null)).Days
    if ($age -gt $MERGE_DAYS) {
      Write-Host ''
      Write-Host ("このデータは $age 日前のものです（混ぜてよいのは $MERGE_DAYS 日以内）。1 で新しく取ってください。") -ForegroundColor Yellow
      return
    }
  }
  foreach ($ch0 in (Get-Val $old 'champs')) { $out[[string]$ch0['id']] = $ch0 }
} else {
  Write-Host ''
  Write-Host 'ランク帯は？'
  Write-Host '  1: エメラルド以上   2: 全ランク   3: ダイヤ以上   4: マスター以上   5: プラチナ以上'
  $t = Read-Host '番号を入れてEnter（そのままEnterで1）'
  $tierMap = @{ '1'='emerald_plus'; '2'='all'; '3'='diamond_plus'; '4'='master_plus'; '5'='platinum_plus' }
  $tier = $tierMap[$t]; if (-not $tier) { $tier = 'emerald_plus' }
  $kind = '30d'; if ($c -eq '2') { $kind = 'patch' }
}
$patchQ = ''; if ($kind -eq '30d') { $patchQ = '&patch=30' }

$cacheDir = Join-Path $dir ("cache\" + $todayKey)
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

function Get-Page([string]$url) {
  $key = ($url -replace '^https?://', '') -replace '[^a-zA-Z0-9]', '_'
  $f = Join-Path $cacheDir ($key + '.html')
  if (Test-Path -LiteralPath $f) { return [IO.File]::ReadAllText($f, $UTF8) }
  for ($i = 0; $i -lt 3; $i++) {
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $ua -TimeoutSec 40 -Headers @{ Referer = 'https://lolalytics.com/' }
      $h = $UTF8.GetString($r.RawContentStream.ToArray())
      [IO.File]::WriteAllText($f, $h, $UTF8)
      Start-Sleep -Milliseconds 300
      return $h
    } catch { Start-Sleep -Seconds (4 * ($i + 1)) }
  }
  return $null
}

function To-Text([string]$h) {
  if (-not $h) { return '' }
  $h = [regex]::Replace($h, '(?is)<script.*?</script>|<style.*?</style>', ' ')
  $h = [regex]::Replace($h, '<[^>]+>', ' ')
  $h = [Net.WebUtility]::HtmlDecode($h)
  return [regex]::Replace($h, '\s+', ' ')
}

$rxRow = [regex]'([^%]{1,90}?)\s?(\d+(?:\.\d+)?)\s?%\s?VS\s?\u0394\s?1\s?[+\-\u2212]?[\d.]+\s?\u2022\s?\u0394\s?2\s?[+\-\u2212]?[\d.]+\s?(\d+(?:\.\d+)?)\s?%\s?VS\s?([\d,]+)\s?Games'
$rxShare = [regex]'\b(?:top|jungle|middle|bottom|support)\s+([\d.]+)\s?%\s+([\d.]+)\s?%\s+([\d.]+)\s?%\s+([\d.]+)\s?%\s+([\d.]+)\s?%'
$rxAvg = [regex]'Average[^:]{0,30}Win Rate:\s?([\d.]+)'
$rxPatch = [regex]'Patch\s+(\d+\.\d+)'

# ---- キャラ一覧（Riot公式のData Dragon） ----
Write-Host ''
Write-Host 'キャラ一覧を取得中...'
try {
  $ver = (Invoke-RestMethod 'https://ddragon.leagueoflegends.com/api/versions.json')[0]
  $cj = Invoke-RestMethod ("https://ddragon.leagueoflegends.com/cdn/$ver/data/en_US/champion.json")
} catch { Write-Host 'キャラ一覧が取れませんでした。ネット接続を確認してください。' -ForegroundColor Red; return }
$champs = @()
foreach ($prop in $cj.data.PSObject.Properties) {
  $v = $prop.Value
  $slug = $v.id.ToLower(); if ($slug -eq 'monkeyking') { $slug = 'wukong' }
  $champs += [pscustomobject]@{ id = $v.id; name = $v.name; slug = $slug }
}
$names = $champs | ForEach-Object { $_.name } | Sort-Object { $_.Length } -Descending

function Resolve-Name([string]$s) {
  $s = $s.Trim()
  foreach ($n in $names) { if ($s.EndsWith($n)) { return $n } }
  $parts = $s -split '(?:\.\s| Games )'
  return $parts[-1].Trim()
}

function Parse-Rows([string]$txt) {
  $rows = @()
  foreach ($m in $rxRow.Matches($txt)) {
    $nm = Resolve-Name $m.Groups[1].Value
    $rows += , @($nm, [double]$m.Groups[2].Value, [double]$m.Groups[3].Value, [int]($m.Groups[4].Value -replace ',', ''))
  }
  return , $rows
}

$base = 'https://lolalytics.com/lol/'
$avg = 0; $patchLabel = ''

# ---- 1) 各キャラのレーン割合（0%でなければ全部取る） ----
$laneList = @()
$i = 0
foreach ($ch in $champs) {
  $i++
  Write-Progress -Activity '1/3 レーン割合を確認中' -Status ("$i / " + $champs.Count + '  ' + $ch.name) -PercentComplete ([int](100 * $i / $champs.Count))
  $txt = To-Text (Get-Page ($base + $ch.slug + '/counters/?tier=' + $tier + $patchQ))
  if (-not $avg) { $am = $rxAvg.Match($txt); if ($am.Success) { $avg = [double]$am.Groups[1].Value } }
  if (-not $patchLabel) { $pm = $rxPatch.Match($txt); if ($pm.Success) { $patchLabel = $pm.Groups[1].Value } }
  $sm = $rxShare.Match($txt)
  for ($k = 0; $k -lt 5; $k++) {
    $share = 0
    if ($sm.Success) { $share = [double]$sm.Groups[$k + 1].Value }
    if ((-not $sm.Success) -or $share -gt 0) { $laneList += [pscustomobject]@{ ch = $ch; lane = $lanes[$k]; share = $share } }
  }
}
Write-Progress -Activity '1/3' -Completed

if ($c -eq '3' -and $kind -eq 'patch' -and $oldPatch -and $patchLabel -and $oldPatch -ne $patchLabel) {
  Write-Host ''
  Write-Host ("パッチが変わっています（前: $oldPatch / 今: $patchLabel）。2 で新しく取ってください。") -ForegroundColor Yellow
  return
}

# ---- 2) 相性データ（敵5ロール）。持っている分は飛ばす ----
$tasks = @()
$total = 0
foreach ($e in $laneList) {
  $key = $e.ch.id
  $have = $null
  if ((Has-Key $out $key) -and (Has-Key $out[$key]['lanes'] $e.lane)) { $have = $out[$key]['lanes'][$e.lane]['vs'] }
  if ($have -and (Has-Key $have $e.lane) -and $null -ne $have[$e.lane] -and @($have[$e.lane]).Count -eq 0) { continue }
  $need = 0
  foreach ($vl in $lanes) { if (-not ((Has-Key $have $vl) -and $null -ne $have[$vl])) { $need++ } }
  if ($need -eq 0) { continue }
  $tasks += [pscustomobject]@{ e = $e; have = $have }
  $total += $need
}

$j = 0; $fail = 0
foreach ($tk in $tasks) {
  $e = $tk.e; $key = $e.ch.id
  if (-not (Has-Key $out $key)) { $out[$key] = [ordered]@{ id = $e.ch.id; name = $e.ch.name; lanes = [ordered]@{} } }
  $vs = [ordered]@{}
  if ($tk.have) { foreach ($hk in @($tk.have.Keys)) { $vs[$hk] = $tk.have[$hk] } }
  $order = @($e.lane) + @($lanes | Where-Object { $_ -ne $e.lane })
  foreach ($vl in $order) {
    if ((Has-Key $vs $vl) -and $null -ne $vs[$vl]) { continue }
    $j++
    Write-Progress -Activity '2/3 敵との相性を取得中（待つだけでOK）' -Status ("$j / $total  " + $e.ch.name + ' ' + $e.lane + ' vs ' + $vl) -PercentComplete ([int](100 * [Math]::Min(1, $j / [Math]::Max(1, $total))))
    $url = $base + $e.ch.slug + '/counters/?lane=' + $e.lane + '&vslane=' + $vl + '&tier=' + $tier + $patchQ
    $html = Get-Page $url
    if ($null -eq $html) { $vs[$vl] = $null; $fail++; continue }
    $vs[$vl] = Parse-Rows (To-Text $html)
    if ($vl -eq $e.lane -and @($vs[$vl]).Count -eq 0) { break }
  }
  $share = $e.share
  if ($share -eq 0 -and (Has-Key $out[$key]['lanes'] $e.lane)) { $share = $out[$key]['lanes'][$e.lane]['share'] }
  $keepTeam = $null
  if ((Has-Key $out[$key]['lanes'] $e.lane) -and (Has-Key $out[$key]['lanes'][$e.lane] 'team')) { $keepTeam = $out[$key]['lanes'][$e.lane]['team'] }
  $newLane = [ordered]@{ share = $share; vs = $vs }
  if ($null -ne $keepTeam) { $newLane['team'] = $keepTeam }
  $out[$key]['lanes'][$e.lane] = $newLane
}
Write-Progress -Activity '2/3' -Completed

# ---- 3) 味方との相性（Lolalyticsの裏のデータ。1キャラ1レーンにつき1回で味方4ロール分） ----
$keyName = @{}; $slugOf = @{}
foreach ($prop in $cj.data.PSObject.Properties) { $keyName[[string]$prop.Value.key] = $prop.Value.name }
foreach ($ch in $champs) { $slugOf[$ch.id] = $ch.slug }
$api = 'https://a1.lolalytics.com/mega/?ep=build-team&v=1&queue=ranked&region=all&tier=' + $tier
if ($kind -eq '30d') { $api += '&patch=30' } elseif ($patchLabel) { $api += '&patch=' + $patchLabel }
$teamTasks = @()
foreach ($key in @($out.Keys)) {
  $lanesObj = $out[$key]['lanes']
  foreach ($ln in @($lanesObj.Keys)) {
    $lo = $lanesObj[$ln]
    $same = $null; if (Has-Key $lo['vs'] $ln) { $same = $lo['vs'][$ln] }
    if ($null -eq $same -or @($same).Count -eq 0) { continue }
    if ((Has-Key $lo 'team') -and $null -ne $lo['team']) { continue }
    $teamTasks += [pscustomobject]@{ key = $key; lane = $ln }
  }
}
$tj = 0; $teamFail = 0
foreach ($tt in $teamTasks) {
  $tj++
  Write-Progress -Activity '3/3 味方との相性を取得中' -Status ("$tj / " + $teamTasks.Count + '  ' + $tt.key + ' ' + $tt.lane) -PercentComplete ([int](100 * $tj / [Math]::Max(1, $teamTasks.Count)))
  $lo = $out[$tt.key]['lanes'][$tt.lane]
  $sl = $slugOf[$tt.key]; if (-not $sl) { $sl = ([string]$tt.key).ToLower() }
  $h = Get-Page ($api + '&c=' + $sl + '&lane=' + $tt.lane)
  $jj = $null
  if ($h) { try { $jj = $h | ConvertFrom-Json } catch { $jj = $null } }
  if ($null -eq $jj) { $lo['team'] = $null; $teamFail++; continue }
  $tm = [ordered]@{}
  if ($jj.team) {
    foreach ($r in $lanes) {
      $arr = $jj.team.$r
      if ($null -eq $arr) { continue }
      $rows = @()
      foreach ($x in $arr) {
        $nm = $keyName[[string]$x[0]]; if (-not $nm) { continue }
        $rows += , @($nm, [double]$x[1], [Math]::Round([double]$x[1] - [double]$x[2], 2), [int]$x[5])
      }
      $tm[$r] = $rows
    }
  }
  $lo['team'] = $tm
}
Write-Progress -Activity '3/3' -Completed
$fail += $teamFail

# 新しく取った割合で、既存レーンの割合も最新にする
foreach ($e in $laneList) {
  $key = $e.ch.id
  if ($e.share -gt 0 -and (Has-Key $out $key) -and (Has-Key $out[$key]['lanes'] $e.lane)) { $out[$key]['lanes'][$e.lane]['share'] = $e.share }
}

$champOut = @($out.Values | Where-Object { @($_['lanes'].Keys).Count -gt 0 })
if ($champOut.Count -eq 0) {
  Write-Host ''
  Write-Host 'データが読み取れませんでした。Lolalyticsのページの形が変わった可能性があります。' -ForegroundColor Red
  return
}
if (-not $avg) { $avg = 51.5 }
$patchSave = $patchLabel; if (-not $patchSave) { $patchSave = $oldPatch }
$set = [ordered]@{
  label = (Make-Label $kind $patchSave $tier $start $today)
  kind = $kind; tier = $tier; start = $start; date = $today; patch = $patchSave
  avg = $avg; ddver = $ver; champs = $champOut
}
$json = $set | ConvertTo-Json -Depth 12 -Compress
if ($oldFile) { $savePath = $oldFile.FullName } else { $savePath = Join-Path $setsDir ($todayKey + '_' + $kind + '_' + $tier + '.json') }
[IO.File]::WriteAllText($savePath, $json, $UTF8)
Write-DataJs

Write-Host ''
if ($c -eq '3') { Write-Host ('補強完了：' + ($j + $tj) + 'ページ分を付け足しました。') -ForegroundColor Green }
else { Write-Host ('完了：' + $champOut.Count + 'キャラ分を保存しました。') -ForegroundColor Green }
if ($fail -gt 0) { Write-Host ('取れなかったページが ' + $fail + ' 件あります。あとで 3（補強）を選べば、その分だけ取り直せます。') -ForegroundColor Yellow }
Write-Host '結果ページを開きます。'
Start-Process $htmlPath
Show-Finish

