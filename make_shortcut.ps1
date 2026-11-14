# デスクトップに「LoLビルド」のショートカットを作る
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$desk = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desk 'LoLビルド.lnk'))
$lnk.TargetPath = Join-Path $dir 'start.bat'
$lnk.WorkingDirectory = $dir
$lnk.WindowStyle = 7
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$lnk.Save()
Write-Host 'デスクトップに「LoLビルド」を作りました。'
