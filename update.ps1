$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($c in @('swain', 'tahmkench')) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'fetch.ps1') -Champ $c
}
Write-Host 'データを新しくしました。ページを再読み込みしてください。'
