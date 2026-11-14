# 変わり種ビルド：ページを出す小さなサーバー＋LoLクライアントからピックを読む
$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'LoLビルド（この窓を閉じると止まります）'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PORT = 8765
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# LoLクライアントは自分のPC内の自己署名証明書なので、確認を外す
function Write-ErrLog($msg) {
  $t = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $msg
  try { Add-Content -Path (Join-Path $dir 'server_log.txt') -Value $t -Encoding UTF8 } catch {}
  try { Add-Content -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'LoLビルド_エラー.txt') -Value $t -Encoding UTF8 } catch {}
}
trap { Write-ErrLog ("止まりました: " + $_.Exception.Message + " @ " + $_.InvocationInfo.PositionMessage); Write-Host 'エラーで止まりました。デスクトップの LoLビルド_エラー.txt を見てください。'; Read-Host 'Enterで閉じる'; exit }
# 自分のPC内のLoLクライアントは自己署名証明書なので確認を外す（PowerShellの別スレッドで落ちないようC#で設定）
try {
  Add-Type -TypeDefinition @"
using System.Net;
public static class LbTrust { public static void Enable() { ServicePointManager.ServerCertificateValidationCallback = delegate { return true; }; } }
"@
  [LbTrust]::Enable()
} catch { Write-ErrLog ('証明書設定に失敗: ' + $_.Exception.Message) }

$script:lcu = $null
function Get-Lcu {
  $p = Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $p -or $null -eq $p.CommandLine) { return $null }
  $port = [regex]::Match($p.CommandLine, '--app-port=(\d+)').Groups[1].Value
  $tok  = [regex]::Match($p.CommandLine, '--remoting-auth-token=([\w-]+)').Groups[1].Value
  if (-not $port -or -not $tok) { return $null }
  return @{ port = $port; auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("riot:$tok")) }
}
function Get-Json($url, $auth) {
  try {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Timeout = 1500
    if ($auth) { $req.Headers.Add('Authorization', $auth) }
    $res = $req.GetResponse()
    $sr = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd(); $sr.Close(); $res.Close()
    return ($t | ConvertFrom-Json)
  } catch { return $null }
}
$POS = @{ 'TOP'='top'; 'JUNGLE'='jungle'; 'MIDDLE'='middle'; 'BOTTOM'='bottom'; 'UTILITY'='support'; 'top'='top'; 'jungle'='jungle'; 'middle'='middle'; 'bottom'='bottom'; 'utility'='support' }

function Get-Picks {
  # 1) ゲーム中（敵5人が全員分かる）
  $list = Get-Json 'https://127.0.0.1:2999/liveclientdata/playerlist' $null
  if ($list) {
    $me = Get-Json 'https://127.0.0.1:2999/liveclientdata/activeplayername' $null
    $meName = [string]$me
    $mine = $list | Where-Object { ($_.riotId -and $_.riotId -eq $meName) -or ($_.summonerName -and $meName.StartsWith($_.summonerName)) } | Select-Object -First 1
    if ($mine) {
      $en = @($list | Where-Object { $_.team -ne $mine.team } | ForEach-Object {
        @{ img = ($_.rawChampionName -replace '^game_character_displayname_', ''); pos = $POS[[string]$_.position] }
      })
      $myImg = ($mine.rawChampionName -replace '^game_character_displayname_', '')
      return @{ source = 'ingame'; meImg = $myImg; enemies = $en }
    }
  }
  # 2) ピック画面（敵がロックした順に分かる）
  if ($null -eq $script:lcu) { $script:lcu = Get-Lcu }
  if ($script:lcu) {
    $s = Get-Json "https://127.0.0.1:$($script:lcu.port)/lol-champ-select/v1/session" $script:lcu.auth
    if ($null -eq $s) {
      $script:lcu = Get-Lcu
      return @{ source = 'client'; enemies = @() }
    }
    if ($s.theirTeam) {
      $en = @($s.theirTeam | Where-Object { $_.championId -gt 0 } | ForEach-Object {
        @{ cid = [string]$_.championId; pos = $POS[[string]$_.assignedPosition] }
      })
      $mine = $s.myTeam | Where-Object { $_.cellId -eq $s.localPlayerCellId } | Select-Object -First 1
      $meCid = if ($mine) { [string]$(if ($mine.championId -gt 0) { $mine.championId } else { $mine.championPickIntent }) } else { '' }
      return @{ source = 'champselect'; meCid = $meCid; enemies = $en }
    }
  }
  return @{ source = 'none'; enemies = @() }
}

# --- 自分の試合結果を、LoLクライアントの戦績から自動で記録する ---
function Update-History {
  $file = Join-Path $dir 'history.json'
  $hist = @()
  if (Test-Path $file) { try { $hist = @([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $hist = @() } }
  if ($null -eq $script:lcu) { $script:lcu = Get-Lcu }
  if ($null -eq $script:lcu) { return $hist }
  $base = "https://127.0.0.1:$($script:lcu.port)"
  $me = Get-Json "$base/lol-summoner/v1/current-summoner" $script:lcu.auth
  $list = Get-Json "$base/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=30" $script:lcu.auth
  if ($null -eq $me -or $null -eq $list) { return $hist }
  $known = @{}; foreach ($h in $hist) { $known[[string]$h.id] = $true }
  $added = 0
  foreach ($g in @($list.games.games)) {
    if ($known[[string]$g.gameId]) { continue }
    $full = Get-Json "$base/lol-match-history/v1/games/$($g.gameId)" $script:lcu.auth
    if ($null -eq $full) { continue }
    $myPart = ($full.participantIdentities | Where-Object { $_.player.puuid -eq $me.puuid -or $_.player.summonerId -eq $me.summonerId } | Select-Object -First 1).participantId
    $mine = $full.participants | Where-Object { $_.participantId -eq $myPart } | Select-Object -First 1
    if ($null -eq $mine) { continue }
    $st = $mine.stats
    $items = @($st.item0, $st.item1, $st.item2, $st.item3, $st.item4, $st.item5) | Where-Object { $_ -gt 0 } | ForEach-Object { [string]$_ }
    $enemies = @($full.participants | Where-Object { $_.teamId -ne $mine.teamId } | ForEach-Object { [string]$_.championId })
    $allies  = @($full.participants | Where-Object { $_.teamId -eq $mine.teamId -and $_.participantId -ne $myPart } | ForEach-Object { [string]$_.championId })
    $hist += [ordered]@{ id = [string]$g.gameId; at = $full.gameCreation; queue = $full.queueId; champ = [string]$mine.championId; win = [bool]$st.win
      items = $items; enemies = $enemies; allies = $allies; k = $st.kills; d = $st.deaths; a = $st.assists; min = [math]::Round($full.gameDuration / 60) }
    $added++
  }
  if ($added -gt 0) {
    [IO.File]::WriteAllText($file, (ConvertTo-Json @($hist) -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))
    Write-Host "試合結果を $added 件記録しました"
  }
  return $hist
}

$listener = $null
foreach ($pre in @("http://localhost:$PORT/", "http://127.0.0.1:$PORT/")) {
  try { $l = New-Object Net.HttpListener; $l.Prefixes.Add($pre); $l.Start(); $listener = $l; break }
  catch { Write-ErrLog ("$pre で起動できません: " + $_.Exception.Message) }
}
if ($null -eq $listener) {
  try { $null = Invoke-WebRequest "http://localhost:$PORT/ping" -UseBasicParsing -TimeoutSec 1; Write-Host 'すでに起動しています。'; Start-Sleep 2; exit } catch {}
  Write-Host 'サーバーを起動できませんでした。デスクトップの LoLビルド_エラー.txt を見てください。'
  Read-Host 'Enterで閉じる'; exit
}
Write-Host "起動しました： http://localhost:$PORT/"
Write-Host 'この窓を閉じるとページの自動読み取りが止まります。'

$TYPES = @{ '.html'='text/html; charset=utf-8'; '.json'='application/json; charset=utf-8'; '.js'='text/javascript; charset=utf-8' }
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $path = $ctx.Request.Url.AbsolutePath
  $resp = $ctx.Response
  try {
    $bytes = $null; $type = 'application/json; charset=utf-8'
    if ($path -eq '/ping') { $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}') }
    elseif ($path -eq '/save' -and $ctx.Request.HttpMethod -eq 'POST') {
      $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
      $body = $sr.ReadToEnd(); $sr.Close()
      $m = [regex]::Match($body, '"champ"\s*:\s*"([a-z]+)"')
      if ($m.Success -and $body.Contains('"enemies"')) {
        [IO.File]::WriteAllText((Join-Path $dir ('data_' + $m.Groups[1].Value + '.json')), $body, (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $dir ('data_' + $m.Groups[1].Value + '.js')), ("window.LB_DATA=window.LB_DATA||{};window.LB_DATA['" + $m.Groups[1].Value + "']=" + $body + ';'), (New-Object Text.UTF8Encoding $false))
        Write-Host ('貼り付けたデータを保存しました: data_' + $m.Groups[1].Value + '.json')
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
      } else { $resp.StatusCode = 400; $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    }
    elseif ($path -eq '/history') { $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @(Update-History) -Depth 6 -Compress)) }
    elseif ($path -eq '/picks') { $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Picks | ConvertTo-Json -Depth 5 -Compress)) }
    else {
      $name = if ($path -eq '/') { 'index.html' } else { [IO.Path]::GetFileName($path) }
      $file = Join-Path $dir $name
      if (($name -match '^(index\.html|data_[a-z]+\.(json|js))$') -and (Test-Path $file)) {
        $bytes = [IO.File]::ReadAllBytes($file); $type = $TYPES[[IO.Path]::GetExtension($file)]
      } else { $resp.StatusCode = 404; $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    }
    $resp.ContentType = $type
    $resp.Headers.Add('Cache-Control', 'no-store')
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch { $resp.StatusCode = 500 }
  finally { $resp.Close() }
}
