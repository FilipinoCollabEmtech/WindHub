-- WindHub Loader — queue on teleport + load
-- 1. Push WindHub_Recorder_Placer.lua to GitHub (e.g. https://github.com/YOURNAME/WindHub)
-- 2. Replace GH_URL below with your RAW link:
--    https://raw.githubusercontent.com/FilipinoCollabEmtech/WindHub/main/WindHub_Recorder_Placer.lua
local GH_URL = "https://raw.githubusercontent.com/FilipinoCollabEmtech/WindHub/main/WindHub_Recorder_Placer.lua"
if getgenv and getgenv().WindHubLoaderLoaded then return end
if getgenv then getgenv().WindHubLoaderLoaded = true end
pcall(function()
    local q = queue_on_teleport or (syn and syn.queue_on_teleport) or queueonteleport
    if q then q('loadstring(game:HttpGet("' .. GH_URL .. '"))()') end
end)
if getgenv and getgenv().WindHubLoaded then return end
loadstring(game:HttpGet(GH_URL))()
