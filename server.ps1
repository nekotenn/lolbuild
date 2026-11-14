# 変わり種ビルド：ページを出す小さなサーバー＋LoLクライアントからピックを読む
$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'LoLビルド（この窓を閉じると止まります）'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PORT = 8765
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# LoLクライアントは自分のPC内の自己署名証明書なので、確認を外す
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

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

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$PORT/")
try { $listener.Start() } catch { Write-Host 'すでに起動しています。'; Start-Sleep 2; exit }
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
        Write-Host ('貼り付けたデータを保存しました: data_' + $m.Groups[1].Value + '.json')
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
      } else { $resp.StatusCode = 400; $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    }
    elseif ($path -eq '/picks') { $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Picks | ConvertTo-Json -Depth 5 -Compress)) }
    else {
      $name = if ($path -eq '/') { 'index.html' } else { [IO.Path]::GetFileName($path) }
      $file = Join-Path $dir $name
      if (($name -match '^(index\.html|data_[a-z]+\.json)$') -and (Test-Path $file)) {
        $bytes = [IO.File]::ReadAllBytes($file); $type = $TYPES[[IO.Path]::GetExtension($file)]
      } else { $resp.StatusCode = 404; $bytes = [Text.Encoding]::UTF8.GetBytes('{}') }
    }
    $resp.ContentType = $type
    $resp.Headers.Add('Cache-Control', 'no-store')
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch { $resp.StatusCode = 500 }
  finally { $resp.Close() }
}
