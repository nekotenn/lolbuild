# 変わり種ビルド：データ取得（例: fetch.ps1 -Champ swain）
param([string]$Champ = 'swain', [string]$Tier = 'all')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'

function Get-Text($url) {
  for ($t = 0; $t -lt 3; $t++) {
    try {
      $wc = New-Object Net.WebClient
      $wc.Encoding = [Text.Encoding]::UTF8
      $wc.Headers.Add('User-Agent', $UA)
      $wc.Headers.Add('Referer', 'https://lolalytics.com/')
      return $wc.DownloadString($url)
    } catch { Start-Sleep -Seconds 2 }
  }
  return $null
}
function Take($arr, $max) {
  if ($null -eq $arr) { return ,@() }
  $a = @($arr)
  if ($a.Count -le $max) { return ,$a }
  return ,($a[0..($max - 1)])
}
function Trim-Build($j) {
  return [ordered]@{
    n  = $j.n
    s  = (Take $j.startSet 30)
    i1 = (Take $j.item1 100); i2 = (Take $j.item2 100); i3 = (Take $j.item3 100)
    i4 = (Take $j.item4 100); i5 = (Take $j.item5 100)
    e  = (Take $j.earlyItem 80)
    r  = $(if ($j.runes) { $j.runes.stats } else { $null })
  }
}

Write-Host "[$Champ] ボットのデータを取りに行きます。数分かかります。"
$ver = (Get-Text 'https://ddragon.leagueoflegends.com/api/versions.json' | ConvertFrom-Json)[0]
$champJson = Get-Text "https://ddragon.leagueoflegends.com/cdn/$ver/data/ja_JP/champion.json" | ConvertFrom-Json
$itemJson  = Get-Text "https://ddragon.leagueoflegends.com/cdn/$ver/data/ja_JP/item.json" | ConvertFrom-Json

$champs = [ordered]@{}
foreach ($p in $champJson.data.PSObject.Properties) {
  $c = $p.Value
  $slug = $c.id.ToLower()
  if ($slug -eq 'monkeyking') { $slug = 'wukong' }
  $champs[[string]$c.key] = [ordered]@{ slug = $slug; name = $c.name; img = $c.id }
}
$items = [ordered]@{}
foreach ($p in $itemJson.data.PSObject.Properties) { $items[$p.Name] = $p.Value.name }

$Q = "v=1&patch=30&c=$Champ&lane=bottom&tier=$Tier&queue=ranked&region=all"
$g = Get-Text "https://a3.lolalytics.com/mega/?ep=build-full&$Q" | ConvertFrom-Json
if ($null -eq $g -or $null -eq $g.n) { throw 'Lolalyticsから全体データが取れませんでした。少し時間をおいて、もう一度実行してください。' }
Write-Host "  全体: $($g.n) 試合"

$roles = @('top', 'jungle', 'middle', 'bottom', 'support')
$enemies = [ordered]@{}
foreach ($vl in $roles) {
  $cj = Get-Text "https://a1.lolalytics.com/mega/?ep=counter&vslane=$vl&$Q" | ConvertFrom-Json
  $list = @($cj.counters)
  Write-Host "  $vl : $($list.Count) 体"
  $i = 0
  foreach ($c in $list) {
    $i++
    $info = $champs[[string]$c.cid]
    if ($null -eq $info) { continue }
    $raw = Get-Text "https://a3.lolalytics.com/mega/?ep=build-full&vs=$($info.slug)&vslane=$vl&$Q"
    if ($null -eq $raw) { continue }
    $j = $raw | ConvertFrom-Json
    if ($null -eq $j.n) { continue }
    $b = Trim-Build $j
    $b['cid'] = [string]$c.cid
    $enemies["$vl|$($info.slug)"] = $b
    Write-Progress -Activity "[$Champ] 敵 $vl" -Status "$i / $($list.Count)  $($info.name)" -PercentComplete ([int](100 * $i / [Math]::Max(1, $list.Count)))
    Start-Sleep -Milliseconds 300
  }
  Write-Progress -Activity "[$Champ] 敵 $vl" -Completed
}

$out = [ordered]@{
  champ = $Champ; tier = $Tier; made = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ver = $ver
  global = (Trim-Build $g); items = $items; champs = $champs; enemies = $enemies
}
$json = $out | ConvertTo-Json -Depth 10 -Compress
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $dir "data_$Champ.json"), $json, $utf8)
Write-Host "[$Champ] 完了: 敵 $($enemies.Count) 体分"
