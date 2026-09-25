param([string]$Message = "Update")
$repo = "C:\Users\Admin\AppData\Local\Temp\WindHubRepo"
$src = "C:\Users\Admin\Documents\Scripts\WindHub_Recorder_Placer.lua"
$dst = Join-Path $repo "WindHub_Recorder_Placer.lua"
Copy-Item -LiteralPath $src -Destination $dst -Force
Copy-Item -LiteralPath "C:\Users\Admin\Documents\Scripts\WindHub_Loader.lua" -Destination (Join-Path $repo "WindHub_Loader.lua") -Force -ErrorAction SilentlyContinue
Set-Location -LiteralPath $repo
$date = Get-Date -Format "yyyy-MM-dd HH:mm"
$content = Get-Content -LiteralPath $dst -Raw
$content = $content -replace 'local HUB_VERSION = ".*"', ('local HUB_VERSION = "UNSTAMPED @ ' + $date + ' UTC"')
Set-Content -LiteralPath $dst -Value $content -NoNewline
git add -A
git commit -m $Message | Out-Null
$hash = (git rev-parse --short HEAD).Trim()
$content2 = Get-Content -LiteralPath $dst -Raw
$content2 = $content2 -replace 'local HUB_VERSION = ".*"', ('local HUB_VERSION = "' + $hash + ' @ ' + $date + ' UTC"')
Set-Content -LiteralPath $dst -Value $content2 -NoNewline
git add -A
git commit --amend --no-edit | Out-Null
git push 2>&1 | Select-Object -First 5
Copy-Item -LiteralPath $dst -Destination $src -Force
Write-Host "pushed $hash with stamped version"
