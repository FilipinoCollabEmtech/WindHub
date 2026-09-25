param([string]$Message = "Update")
$repo = "C:\Users\Admin\AppData\Local\Temp\WindHubRepo"
$src = "C:\Users\Admin\Documents\Scripts\WindHub_Recorder_Placer.lua"
$dst = Join-Path $repo "WindHub_Recorder_Placer.lua"
Copy-Item -LiteralPath $src -Destination $dst -Force
Copy-Item -LiteralPath "C:\Users\Admin\Documents\Scripts\WindHub_Loader.lua" -Destination (Join-Path $repo "WindHub_Loader.lua") -Force -ErrorAction SilentlyContinue
Set-Location -LiteralPath $repo
$date = Get-Date -Format "yyyy-MM-dd HH:mm"
$content = Get-Content -LiteralPath $dst -Raw
$content = $content -replace 'local HUB_VERSION = ".*"', ('local HUB_VERSION = "' + $date + ' UTC"')
Set-Content -LiteralPath $dst -Value $content -NoNewline
git add -A
git commit -m $Message 2>&1 | Select-Object -First 3
git push 2>&1 | Select-Object -First 5
$hash = (git rev-parse --short HEAD).Trim()
Copy-Item -LiteralPath $dst -Destination $src -Force
Write-Host "pushed OK"
Write-Host $hash
Write-Host $date
