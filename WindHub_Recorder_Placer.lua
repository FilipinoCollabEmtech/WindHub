-- WindHub Recorder + Placer — observer-only (no hookmetamethod/getnamecallmethod/SpyQueue)
-- Placements + upgrades observed via workspace.Towers + server->client events
-- Execute on teleport (like Infinite Yield) — re-queue after level retry/teleport
-- 1) Push this file to GitHub (e.g. https://github.com/YOURNAME/WindHub -> raw link below)
-- 2) Replace GH_URL below with your raw link, e.g.
--    https://raw.githubusercontent.com/FilipinoCollabEmtech/WindHub/main/WindHub_Recorder_Placer.lua
local GH_URL = "https://raw.githubusercontent.com/FilipinoCollabEmtech/WindHub/main/WindHub_Recorder_Placer.lua"
pcall(function()
    local q = queue_on_teleport or (syn and syn.queue_on_teleport) or queueonteleport
    if q then q('loadstring(game:HttpGet("' .. GH_URL .. '"))()') end
end)
-- single-instance guard (like Infinite Yield) — if queue_on_teleport fires twice, second load no-ops
if getgenv and getgenv().WindHubLoaded then return end
if getgenv then getgenv().WindHubLoaded = true end
do
    local has = false
    pcall(function() has = game:GetService("CoreGui"):FindFirstChild("WindHub_Placer") ~= nil end)
    if has then return end
    pcall(function() has = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui") and game:GetService("Players").LocalPlayer.PlayerGui:FindFirstChild("WindHub_Placer") ~= nil end)
    if has then return end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local WIND_VERSION = "1.6.66"
local WindUI = nil
do
    local urls = {
        "https://github.com/Footagesus/WindUI/releases/download/" .. WIND_VERSION .. "/main.lua",
        "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
    }
    local err
    for _, u in ipairs(urls) do
        local ok, res = pcall(function() return loadstring(game:HttpGet(u))() end)
        if ok and res and type(res) == "table" and res.CreateWindow then WindUI = res ;break end
        err = res
    end
    assert(WindUI, "[WindHub] WindUI failed: " .. tostring(err))
end
local Window = WindUI:CreateWindow({
    Title = "WindHub - Auto Placer",
    Icon = "wind",
    Author = "Recorder + Placer",
    Folder = "WindHub_Placer",
    Size = UDim2.fromOffset(580, 460),
    Theme = "Dark",
    ToggleKey = Enum.KeyCode.K,
})
local function notify(title, content, dur)
    pcall(function() WindUI:Notify({ Title = title, Content = content, Duration = dur or 3 }) end)
end

local Functions = ReplicatedStorage:WaitForChild("Functions", 10)
local SpawnTower = Functions and Functions:WaitForChild("SpawnTower", 10)
local UpgradeTowerRemote = Functions and Functions:WaitForChild("UpgradeTower", 10)
local ChangeTowerModeRemote = Functions and Functions:WaitForChild("ChangeTowerMode", 10)

local TimerFn
pcall(function()
    TimerFn = ReplicatedStorage:WaitForChild("Network", 5)
        and ReplicatedStorage.Network:WaitForChild("RemoteFunctions", 5)
        and ReplicatedStorage.Network.RemoteFunctions:WaitForChild("GetTimerValue", 5)
end)
local function GetGameTime()
    if TimerFn then
        local ok, v = pcall(function() return TimerFn:InvokeServer() end)
        if ok and tonumber(v) then return tonumber(v) end
        if ok and type(v) == "table" then
            if tonumber(v.Time) then return tonumber(v.Time) end
            if tonumber(v.Value) then return tonumber(v.Value) end
            if tonumber(v.Timer) then return tonumber(v.Timer) end
        end
    end
    return nil
end
-- AntiMacro — server asks Check(p1,p2,p3,p4), client must Respond:FireServer(p1) in ~45s or kick
-- We do NOT set NoAntiMacro (that opts out and you lose chests/rewards). Instead we bot-solve
-- like a player: wait for Check, then FireServer(p1) with the token. No attribute change.
local AntiMacroBypass = false
local function setAntiMacroBypass(on)
    AntiMacroBypass = on and true or false
    pcall(function() LocalPlayer:SetAttribute("NoAntiMacro", false) end)
    if not AntiMacroBypass then return end
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local g = pg and pg:FindFirstChild("AntiMacroCheck")
        if g then g:Destroy() end
    end)
end
pcall(function()
    local am = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("AntiMacro")
    if not am then return end
    local chk = am:FindFirstChild("Check")
    local rsp = am:FindFirstChild("Respond")
    if chk and rsp and chk.OnClientEvent then
        chk.OnClientEvent:Connect(function(p1, p2, p3, p4)
            if not AntiMacroBypass then return end
            -- human-like 0.8-2.2s delay, then bot-solve the RemoteEvent Check -> Respond
            task.delay(0.8 + math.random() * 1.4, function()
                pcall(function() rsp:FireServer(p1) end)
                pcall(function()
                    local pg = LocalPlayer:FindFirstChild("PlayerGui")
                    local g = pg and pg:FindFirstChild("AntiMacroCheck")
                    if g then g:Destroy() end
                end)
            end)
        end)
    end
end)

-- Price + Cash helpers — server truth only, no require
local CashValue = nil
pcall(function()
    local cv = LocalPlayer:FindFirstChild("Cash") or LocalPlayer:WaitForChild("Cash", 2)
    CashValue = cv
end)
LocalPlayer.ChildAdded:Connect(function(c) if c.Name == "Cash" then CashValue = c end end)
local function getCash()
    if CashValue and typeof(CashValue.Value) == "number" then return CashValue.Value end
    local cv = LocalPlayer:FindFirstChild("Cash")
    if cv and tonumber(cv.Value) then return tonumber(cv.Value) end
    return nil
end
local function readTowerPrice(tower)
    local ok, v = pcall(function()
        local cfg = tower:FindFirstChild("Config")
        if cfg then
            local priceObj = cfg:FindFirstChild("Price")
            if priceObj and tonumber(priceObj.Value) then return tonumber(priceObj.Value) end
        end
        local attr = tower:GetAttribute("Price")
        if tonumber(attr) then return tonumber(attr) end
        return nil
    end)
    if ok and tonumber(v) then return tonumber(v) end
    return nil
end

local FOLDER = "WindHub_Placer"
pcall(function() if makefolder and not isfolder(FOLDER) then makefolder(FOLDER) end end)
local function sanitize(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[<>:\"/\\|%?%*]", "_")
    if name == "" then name = "placement_1" end
    return name
end
local function filePath(name) return FOLDER .. "/" .. sanitize(name) .. ".json" end
local function listRecordFiles()
    local out = {}
    local ok, files = pcall(function() return listfiles(FOLDER) end)
    if ok and type(files) == "table" then
        for _, f in ipairs(files) do
            local base = tostring(f):match("([^/\\]+)%.json$")
            if base then table.insert(out, base) end
        end
    end
    table.sort(out)
    return out
end
local function saveRecord(name, data)
    local ok, err = pcall(function() writefile(filePath(name), HttpService:JSONEncode(data)) end)
    return ok, err
end
local function loadRecord(name)
    local ok, content = pcall(function() return readfile(filePath(name)) end)
    if not ok or not content then return nil, "readfile failed" end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 then return nil, "bad json" end
    return data, nil
end
-- Settings persistence — everything except Recorder tab
local SETTINGS_FILE = FOLDER .. "/Settings.json"
local function loadSettings()
    local ok, content = pcall(function() return readfile(SETTINGS_FILE) end)
    if not ok or not content or content == "" then return {} end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if ok2 and type(data) == "table" then return data end
    return {}
end
local function saveSettings(data)
    pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(data)) end)
end
local SelectedFile; local AutoPlacing; local CfgAutoUpgrade; local CfgNotify; local CfgIgnoreTime; local CfgAutoRetry; local PlacerDropdown; local AutoPlaceToggle
local _settings = loadSettings()
SelectedFile = _settings.SelectedFile
AutoPlacing = _settings.AutoPlace == true
CfgAutoUpgrade = _settings.AutoUpgrade == true
CfgNotify = _settings.NotifyPlacer == true
CfgIgnoreTime = _settings.IgnoreTime == true
CfgAutoRetry = _settings.AutoRetry == true
AntiMacroBypass = _settings.BypassAntiMacro == true
setAntiMacroBypass(AntiMacroBypass)
local function persistPlacer()
    saveSettings({
        SelectedFile = SelectedFile,
        AutoUpgrade = CfgAutoUpgrade,
        NotifyPlacer = CfgNotify,
        IgnoreTime = CfgIgnoreTime,
        AutoPlace = AutoPlacing,
        AutoRetry = CfgAutoRetry,
        BypassAntiMacro = AntiMacroBypass,
    })
end

local function serializeArg(v)
    if typeof(v) == "CFrame" then return { __type = "CFrame", c = { v:GetComponents() } }
    elseif typeof(v) == "Vector3" then return { __type = "Vector3", x = v.X, y = v.Y, z = v.Z }
    elseif typeof(v) == "Vector2" then return { __type = "Vector2", x = v.X, y = v.Y }
    elseif typeof(v) == "Color3" then return { __type = "Color3", r = v.R, g = v.G, b = v.B }
    elseif typeof(v) == "Instance" then return { __type = "InstanceRef", name = v.Name, class = v.ClassName }
    elseif type(v) == "table" then
        local t = {}
        for k, item in pairs(v) do t[k] = serializeArg(item) end
        return t
    elseif type(v) == "number" or type(v) == "string" or type(v) == "boolean" then return v end
    return { __type = "Unsupported", str = tostring(v) }
end
local function deserializeArg(v)
    if type(v) == "table" and type(v.__type) == "string" then
        if v.__type == "CFrame" and type(v.c) == "table" then return CFrame.new(unpack(v.c))
        elseif v.__type == "Vector3" then return Vector3.new(v.x, v.y, v.z)
        elseif v.__type == "Vector2" then return Vector2.new(v.x, v.y)
        elseif v.__type == "Color3" then return Color3.new(v.r, v.g, v.b)
        elseif v.__type == "InstanceRef" then return nil
        elseif v.__type == "Unsupported" then return nil end
    end
    if type(v) == "table" and v.__type == nil then
        local t = {}
        for k, item in pairs(v) do t[k] = deserializeArg(item) end
        return t
    end
    return v
end
local function describeLocation(args)
    for _, a in ipairs(args) do if typeof(a) == "CFrame" then local p = a.Position ;return string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z) end end
    for _, a in ipairs(args) do if typeof(a) == "Vector3" then return string.format("(%.1f, %.1f, %.1f)", a.X, a.Y, a.Z) end end
    return "?"
end

local FileName = "placement_1"
local Recording = false
local Recorded = {}
local RecStartClock = 0
local RecStartGameTime = nil
local SeenLocations = {}
local RecorderInfo; local PlacerInfo; local refreshPlacerList
local SessionRejected = 0
local function setParagraph(p, title, desc)
    if not p then return end
    pcall(function() p:SetTitle(title) end)
    pcall(function() p:SetDesc(desc) end)
end
local function recorderSummary()
    local places, upgrades, pending = 0, 0, 0
    local units, uniqLoc = {}, {}
    local lastConfirmed = nil
    for _, e in ipairs(Recorded) do
        if e.Confirmed then
            if e.Kind == "upgrade" then upgrades = upgrades + 1 else places = places + 1 end
            units[e.Unit] = true
            uniqLoc[e.Unit .. "|" .. e.Loc] = true
            lastConfirmed = e
        else pending = pending + 1 end
    end
    local ucount, lcount = 0, 0
    for _ in pairs(units) do ucount = ucount + 1 end
    for _ in pairs(uniqLoc) do lcount = lcount + 1 end
    local lastStr
    if lastConfirmed then
        local what = lastConfirmed.Kind == "upgrade" and ("upgraded (" .. tostring(lastConfirmed.Method or "?") .. ")") or ("@ " .. lastConfirmed.Loc)
        lastStr = lastConfirmed.Unit .. " " .. what .. " (t=" .. string.format("%.1f", lastConfirmed.Time or lastConfirmed.Elapsed) .. ")"
    elseif Recorded[#Recorded] then local e = Recorded[#Recorded] ;lastStr = e.Unit .. " @ " .. e.Loc .. " (pending...)" else lastStr = "none yet" end
    return "Total actions recorded: " .. (places + upgrades) .. " (" .. upgrades .. " upgrades)" .. (pending > 0 and (" (" .. pending .. " pending)") or ""),
        ("File: %s.json | Placements: %d | Upgrades: %d | Unique units: %d | Unique locations: %d%s\nLast confirmed: %s"):format(sanitize(FileName), places, upgrades, ucount, lcount, SessionRejected > 0 and (" | Rejected: " .. SessionRejected) or "", lastStr)
end
local function refreshRecorderParagraph()
    local t, d = recorderSummary()
    setParagraph(RecorderInfo, t, d)
end

-- observer-only helpers — forward declared for placement observer
local isOwnTower; local getTowerPos; local getTowerLVL
local SeenTowers = {}
local function getTowerTrait(tower)
    local ok, v = pcall(function() return tower:GetAttribute("TraitName") end)
    if ok and v and tostring(v) ~= "" then return tostring(v) end
    if tower:FindFirstChild("Rainbow") then return "Rainbow" end
    if tower:FindFirstChild("Gold") then return "Gold" end
    if tower:FindFirstChild("Silver") then return "Silver" end
    return nil
end
local function getTowerSkin(unit, trait)
    if trait and trait ~= "" then return unit .. " " .. trait end
    return unit
end
local function recordPlacementObserved(tower, isRetry)
    if not Recording then return end
    if SeenTowers[tower] then return end
    if not isOwnTower(tower) then
        if not isRetry and tower.Parent == Workspace:FindFirstChild("Towers") then
            task.delay(0.9, function() recordPlacementObserved(tower, true) end)
        end
        return
    end
    SeenTowers[tower] = true
    local nowGame = GetGameTime()
    local elapsed = os.clock() - RecStartClock
    local unit = tostring(tower.Name)
    local trait = getTowerTrait(tower)
    local skin = getTowerSkin(unit, trait)
    local traits = trait and {trait} or {}
    local pv = getTowerPos(tower)
    local cframe = pv and tower:GetPivot() or CFrame.new()
    local loc = pv and string.format("(%.1f, %.1f, %.1f)", pv.X, pv.Y, pv.Z) or describeLocation({cframe})
    local price = readTowerPrice(tower)
    local serverId = nil
    pcall(function() local idAttr = tower:GetAttribute("ID") ;if idAttr ~= nil then serverId = tostring(idAttr) end end)
    SeenLocations[unit .. "|" .. loc] = true
    local rawArgs = {unit, cframe, false, skin, traits}
    local entry = {
        Time = nowGame, Elapsed = elapsed, Unit = unit, Loc = loc, Confirmed = true,
        Args = (function() local s={} ;for i,a in ipairs(rawArgs) do s[i]=serializeArg(a) end return s end)(),
        Price = price, Skin = skin, Traits = traits,
    }
    if pv then entry.PX, entry.PY, entry.PZ = pv.X, pv.Y, pv.Z end
    if entry.Price == nil then task.delay(0.6, function() local late = readTowerPrice(tower) ;if late then entry.Price = late end end) end
    local cfgOwner = nil
    pcall(function() local cfg = tower:FindFirstChild("Config") ;local o = cfg and cfg:FindFirstChild("Owner") if o then cfgOwner = o.Value end end)
    if cfgOwner then entry.Owner = tostring(cfgOwner) end
    if serverId then entry.ServerID = serverId end
    table.insert(Recorded, entry)
    refreshRecorderParagraph()
end
local function recordPlacement() end
isOwnTower = function(model)
    if typeof(model) ~= "Instance" then return false end
    local okM, isM = pcall(function() return model:IsA("Model") end)
    if not okM or not isM then return false end
    local folder = Workspace:FindFirstChild("Towers")
    if not folder then return false end
    local isDesc = false
    pcall(function() isDesc = model:IsDescendantOf(folder) end)
    if not isDesc and model.Parent ~= folder then return false end
    local ok, val = pcall(function()
        local cfg = model:FindFirstChild("Config", true)
        if cfg then
            local owner = cfg:FindFirstChild("Owner", true)
            if owner and owner.Value ~= nil then return owner.Value end
            local attrOwner = model:GetAttribute("Owner")
            if attrOwner ~= nil then return attrOwner end
        end
        return nil
    end)
    if not ok or val == nil then return false end
    local ownerName = typeof(val) == "Instance" and val.Name or tostring(val)
    return ownerName == LocalPlayer.Name
end
local function sweepConfirmations() return false end
-- Upgrade observer — NO hook
local TowerState = {}
local TowerConns = {}
getTowerLVL = function(tower)
    local ok, v = pcall(function()
        local cfg = tower:FindFirstChild("Config")
        local lvlObj = cfg and cfg:FindFirstChild("LVL")
        if lvlObj and tonumber(lvlObj.Value) ~= nil then return tonumber(lvlObj.Value) end
        local a = tower:GetAttribute("LVL")
        if tonumber(a) ~= nil then return tonumber(a) end
        return nil
    end)
    if ok and tonumber(v) ~= nil then return tonumber(v) end
    return nil
end
getTowerPos = function(tower)
    local ok, pv = pcall(function() return tower:GetPivot() end)
    if ok and pv then return pv.Position end
    return nil
end
local function recordUpgradeObserved(tower, oldLVL, newLVL, oldPrice, newPrice)
    if not Recording then return end
    if not isOwnTower(tower) then return end
    local unit = tostring(tower.Name)
    local pos = getTowerPos(tower)
    local loc = pos and string.format("(%.1f, %.1f, %.1f)", pos.X, pos.Y, pos.Z) or "?"
    local serverId = nil
    pcall(function() local idAttr = tower:GetAttribute("ID") ;if idAttr ~= nil then serverId = tostring(idAttr) end end)
    SeenLocations[unit .. "|" .. loc] = true
    local nowGame = GetGameTime()
    local delta = nil
    if tonumber(oldPrice) and tonumber(newPrice) then local d = newPrice - oldPrice ;if d > 0 then delta = d end end
    local priceForGating = delta or newPrice
    local entry = {
        Kind = "upgrade", Method = ("Upgrade" .. "Tower"), Time = nowGame, Elapsed = os.clock() - RecStartClock,
        Unit = unit, Loc = loc, Confirmed = true, Extra = {}, Price = priceForGating, TotalPrice = newPrice, LVLBefore = oldLVL, LVLAfter = newLVL,
    }
    if pos then entry.PX, entry.PY, entry.PZ = pos.X, pos.Y, pos.Z end
    if serverId then entry.ServerID = serverId end
    table.insert(Recorded, entry)
    refreshRecorderParagraph()
end
local function attachTower(tower)
    if not isOwnTower(tower) then return end
    if TowerState[tower] then return end
    local lvl = getTowerLVL(tower)
    local price = readTowerPrice(tower)
    TowerState[tower] = {lvl = lvl, price = price}
    pcall(function()
        local cfg = tower:FindFirstChild("Config")
        local lvlObj = cfg and cfg:FindFirstChild("LVL")
        if lvlObj and lvlObj.Changed then
            local conn = lvlObj.Changed:Connect(function()
                if not Recording then return end
                local newLVL = getTowerLVL(tower)
                local newPrice = readTowerPrice(tower)
                local st = TowerState[tower]
                if not st then return end
                local oldLVL, oldPrice = st.lvl, st.price
                if newLVL ~= nil and oldLVL ~= nil and newLVL ~= oldLVL then
                    if newLVL > oldLVL then recordUpgradeObserved(tower, oldLVL, newLVL, oldPrice, newPrice) end
                    st.lvl = newLVL
                    st.price = newPrice
                elseif newPrice ~= oldPrice then st.price = newPrice end
            end)
            TowerConns[tower] = TowerConns[tower] or {}
            table.insert(TowerConns[tower], conn)
        end
    end)
end
local function detachTower(tower)
    TowerState[tower] = nil
    local conns = TowerConns[tower]
    if conns then for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end ;TowerConns[tower] = nil end
end
task.spawn(function()
    while true do
        if Recording then
            local folder = Workspace:FindFirstChild("Towers")
            if folder then
                for _, m in ipairs(folder:GetChildren()) do
                    if isOwnTower(m) then
                        if not TowerState[m] then
                            if not SeenTowers[m] then pcall(recordPlacementObserved, m) end
                            attachTower(m)
                        else
                            local newLVL = getTowerLVL(m)
                            local newPrice = readTowerPrice(m)
                            local st = TowerState[m]
                            if st and newLVL ~= nil and st.lvl ~= nil and newLVL ~= st.lvl and newLVL > st.lvl then
                                recordUpgradeObserved(m, st.lvl, newLVL, st.price, newPrice)
                                st.lvl = newLVL
                                st.price = newPrice
                            elseif st and newPrice ~= st.price then st.price = newPrice end
                        end
                    end
                end
            end
        end
        task.wait(0.30)
    end
end)
-- Observer listeners for placements + upgrade tracking (server->client allowed)
do
    local towersFolder = Workspace:FindFirstChild("Towers")
    if towersFolder then
        towersFolder.ChildAdded:Connect(function(model)
            if Recording then
                pcall(recordPlacementObserved, model)
                task.delay(0.9, function() pcall(recordPlacementObserved, model) end)
            end
            task.delay(0.5, function() pcall(attachTower, model) end)
        end)
        towersFolder.ChildRemoved:Connect(function(model) pcall(detachTower, model) ;SeenTowers[model] = nil end)
        for _, m in ipairs(towersFolder:GetChildren()) do pcall(attachTower, m) end
    end
    pcall(function()
        local tp = ReplicatedStorage:FindFirstChild("TowerPlace")
        if tp and tp.OnClientEvent then
            tp.OnClientEvent:Connect(function(...)
                if not Recording then return end
                task.delay(0.35, function()
                    if not Recording then return end
                    local folder = Workspace:FindFirstChild("Towers")
                    if not folder then return end
                    for _, m in ipairs(folder:GetChildren()) do
                        if not SeenTowers[m] and isOwnTower(m) then pcall(recordPlacementObserved, m) end
                    end
                end)
            end)
        end
    end)
    pcall(function()
        local toggleClient = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("toggleClient")
        if toggleClient and toggleClient.OnClientEvent then
            toggleClient.OnClientEvent:Connect(function(tower)
                if not Recording then return end
                if typeof(tower) ~= "Instance" then return end
                task.delay(0.2, function()
                    local newLVL = getTowerLVL(tower)
                    local newPrice = readTowerPrice(tower)
                    local st = TowerState[tower]
                    if st and newLVL ~= nil and st.lvl ~= nil and newLVL ~= st.lvl and newLVL > st.lvl then
                        recordUpgradeObserved(tower, st.lvl, newLVL, st.price, newPrice)
                        st.lvl = newLVL
                        st.price = newPrice
                    end
                end)
            end)
        end
    end)
end

-- Tabs
local MainTab = Window:Tab({ Title = "Main", Icon = "house" })
MainTab:Paragraph({ Title = "WindHub — Main", Desc = "Example file: WindHub_Placer/ez.json — C:\\Users\\Admin\\AppData\\Local\\Real\\workspace\\WindHub_Placer\\ez.json" })
local RetryInfo = MainTab:Paragraph({ Title = "Auto Retry: OFF", Desc = "Retries the level and replays the selected file when it ends." })
local retryCount = 0
MainTab:Toggle({
    Title = "Auto Retry Level",
    Desc = "When the level finishes, automatically retries/teleports to replay the level without pressing the button, then replays the file.",
    Value = CfgAutoRetry,
    Callback = function(state)
        CfgAutoRetry = (state == true)
        persistPlacer()
        pcall(function() RetryInfo:SetTitle("Auto Retry: " .. (CfgAutoRetry and "ON" or "OFF")) end)
        if CfgAutoRetry then notify("Main", "Auto Retry armed — will replay " .. (SelectedFile and (SelectedFile .. ".json") or "selected file") .. " on level end.") end
    end,
})
pcall(function() RetryInfo:SetTitle("Auto Retry: " .. (CfgAutoRetry and "ON" or "OFF")) end)
MainTab:Toggle({
    Title = "Auto Solve AntiMacro",
    Desc = "Bot-solves the 'Are you still there?' Check -> Respond RemoteEvent (45s) like a player. No NoAntiMacro, so chests/rewards still drop. Saves.",
    Value = AntiMacroBypass,
    Callback = function(state)
        setAntiMacroBypass(state)
        persistPlacer()
        notify("Main", "AntiMacro auto-solve " .. (AntiMacroBypass and "ON" or "OFF"))
    end,
})
-- server->client level-end signals (all allowed, no client->server hook)
local function doRetry()
    if not CfgAutoRetry then return end
    retryCount = retryCount + 1
    pcall(function() RetryInfo:SetDesc("Retries: " .. retryCount .. " — retrying level then replaying " .. (SelectedFile or "?") .. ".json") end)
    notify("Main", "Level finished — retrying (#" .. retryCount .. ")", 4)
    task.delay(2.5, function()
        if not CfgAutoRetry then return end
        -- retry the level (server->client allowed, client->server FireServer to replay)
        local retried = false
        pcall(function()
            local rp = ReplicatedStorage:FindFirstChild("ReplayButtonPressed")
            if rp then rp:FireServer() retried = true end
        end)
        if not retried then
            pcall(function()
                local ed = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("EndDecision")
                if ed then ed:FireServer("Replay") retried = true end
            end)
        end
        if not retried then
            pcall(function() if clickReplayButton() then retried = true end end)
        end
        -- after level reload, auto-start placer if we have a file
        task.delay(retried and 6 or 4, function()
            if not CfgAutoRetry or not SelectedFile then return end
            if AutoPlaceToggle and AutoPlaceToggle.Set then
                pcall(function() AutoPlaceToggle:Set(true) end)
                notify("Main", "Auto Retry: started placer for " .. SelectedFile .. ".json")
            else
                AutoPlacing = true
                persistPlacer()
            end
        end)
    end)
end
-- also try to click the on-screen Replay button directly if the RemoteEvent alone doesn't retry
-- You specified: game:GetService("Players").LocalPlayer.PlayerGui.GameGui.EndScreen.Replay
local function getReplayButton()
    local ok, btn = pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local gg = pg and pg:FindFirstChild("GameGui")
        local es = gg and gg:FindFirstChild("EndScreen")
        if not es then return nil end
        -- must be visible per your request: check EndScreen.Visible
        if not es.Visible then return nil end
        local r = es:FindFirstChild("Replay")
        if r and r:IsA("GuiObject") and r.Visible then return r end
        -- fallback: any descendant named Replay under EndScreen
        for _, v in ipairs(es:GetDescendants()) do
            if v.Name == "Replay" and v:IsA("GuiObject") and v.Visible then return v end
        end
        -- fallback: any Replay TextButton under EndScreen
        for _, v in ipairs(es:GetDescendants()) do
            if v:IsA("TextButton") and v.Visible and v.Text:lower():find("replay") then return v end
        end
        return nil
    end)
    if ok and btn then return btn end
    return nil
end
local function clickReplayButton()
    local btn = getReplayButton()
    if not btn then return false end
    pcall(function()
        if firesignal then firesignal(btn.Activated) else btn:Activate() end
        local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
        if ok and vim and btn.AbsolutePosition then
            vim:SendMouseButtonEvent(btn.AbsolutePosition.X + btn.AbsoluteSize.X/2, btn.AbsolutePosition.Y + btn.AbsoluteSize.Y/2, 0, true, game, 0)
            vim:SendMouseButtonEvent(btn.AbsolutePosition.X + btn.AbsoluteSize.X/2, btn.AbsolutePosition.Y + btn.AbsoluteSize.Y/2, 0, false, game, 0)
        end
    end)
    return true
end
pcall(function()
    local ed = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("EndDecision")
    if ed and ed.OnClientEvent then ed.OnClientEvent:Connect(function(...) if CfgAutoRetry then task.delay(1, doRetry) end end) end
end)
pcall(function()
    local rp = ReplicatedStorage:FindFirstChild("ReplayButtonPressed")
    if rp then
        -- server->client may be OnClientEvent OR client->server FireServer — listen to both where possible
        if rp.OnClientEvent then pcall(function() rp.OnClientEvent:Connect(function(...) if CfgAutoRetry then task.delay(1, doRetry) end end) end) end
        -- also watch EndScreen.Replay appearing (your path: PlayerGui.GameGui.EndScreen.Replay)
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if pg then pg.DescendantAdded:Connect(function(obj)
            if not CfgAutoRetry then return end
            local ok, isReplay = pcall(function()
                if not obj:IsA("GuiObject") or not obj.Visible then return false end
                if obj.Name == "Replay" then return true end
                if obj:IsA("TextButton") and obj.Text:lower():find("replay") then
                    -- ensure it's under EndScreen
                    local par = obj.Parent
                    while par and par ~= pg do
                        if par.Name == "EndScreen" then return true end
                        par = par.Parent
                    end
                end
                return false
            end)
            if ok and isReplay then task.delay(0.6, doRetry) end
        end) end
    end
end)
-- retry only when the Replay button is actually visible (as you asked) — no timer fallback that fires mid-game
task.spawn(function()
    while true do
        task.wait(1)
        if CfgAutoRetry then
            local hasReplayBtn = false
            pcall(function() hasReplayBtn = getReplayButton() ~= nil end)
            if hasReplayBtn then doRetry() end
        end
    end
end)

local RecorderTab = Window:Tab({ Title = "Recorder", Icon = "mic" })
local PlacerTab = Window:Tab({ Title = "Placer", Icon = "play" })
RecorderTab:Input({
    Title = "File Name",
    Desc = "Name of the auto placer file (saved as .json).",
    Value = FileName,
    Placeholder = "e.g. placement_1",
    Callback = function(text) FileName = sanitize(text ~= "" and text or "placement_1") ;refreshRecorderParagraph() end,
})
RecorderTab:Toggle({
    Title = "Record Placements",
    Desc = "Records every placement AND every upgrade (level + mode), with time, unit name and unique location.",
    Value = false,
    Callback = function(state)
        Recording = state and true or false
        if Recording then
            Recorded = {}
            SeenLocations = {}
            SessionRejected = 0
            for k in pairs(SeenTowers) do SeenTowers[k] = nil end
            RecStartClock = os.clock()
            RecStartGameTime = GetGameTime()
            for k in pairs(TowerState) do TowerState[k] = nil end
            for k, conns in pairs(TowerConns) do for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end end
            for k in pairs(TowerConns) do TowerConns[k] = nil end
            pcall(function()
                local folder = Workspace:FindFirstChild("Towers")
                if folder then for _, m in ipairs(folder:GetChildren()) do if isOwnTower(m) then attachTower(m) end end end
            end)
            notify("Recorder", "Recording started → " .. sanitize(FileName) .. ".json")
        else
            sweepConfirmations()
            local kept, dropped = {}, 0
            for _, e in ipairs(Recorded) do if e.Confirmed then table.insert(kept, e) else dropped = dropped + 1 end end
            Recorded = kept
            if #Recorded > 0 then
                local payload = { GameId = game.PlaceId, File = sanitize(FileName), SavedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), Actions = Recorded }
                local ok, err = saveRecord(FileName, payload)
                if ok then
                    local msg = "Saved " .. #Recorded .. " confirmed action(s) → " .. sanitize(FileName) .. ".json"
                    if dropped > 0 then msg = msg .. " (" .. dropped .. " unconfirmed pruned)" end
                    notify("Recorder", msg)
                else notify("Recorder", "Save failed: " .. tostring(err), 5) end
            else
                local msg = "Recording stopped — nothing confirmed"
                if dropped > 0 then msg = msg .. " (" .. dropped .. " unconfirmed attempt(s) pruned)" end
                notify("Recorder", msg .. ".")
            end
            pcall(refreshPlacerList)
        end
        refreshRecorderParagraph()
    end,
})
RecorderInfo = RecorderTab:Paragraph({ Title = "Total actions recorded: 0", Desc = "Start the toggle above, then place units normally." })
RecorderTab:Button({
    Title = "Clear Current Recording",
    Desc = "Discards actions captured in this session (no file written).",
    Callback = function() Recorded = {} ;SeenLocations = {} refreshRecorderParagraph() notify("Recorder", "Session cleared.") end,
})
if SelectedFile and not table.find(listRecordFiles(), SelectedFile) then SelectedFile = nil persistPlacer() end
local function currentFiles()
    local files = listRecordFiles()
    if #files == 0 then return { "No files found" } end
    return files
end
PlacerDropdown = PlacerTab:Dropdown({
    Title = "Recorded Files",
    Desc = "Pick a recorded placement file to replay.",
    Values = currentFiles(),
    Value = SelectedFile,
    Callback = function(option)
        if type(option) == "table" then option = option[1] end
        option = tostring(option or "")
        if option == "No files found" then SelectedFile = nil else SelectedFile = option end
        pcall(function() PlacerInfo:SetDesc(SelectedFile and ("Selected: " .. SelectedFile .. ".json") or "No file selected.") end)
        persistPlacer()
    end,
})
function refreshPlacerList()
    local files = listRecordFiles()
    if PlacerDropdown then
        pcall(function() PlacerDropdown:Refresh(files) end)
        pcall(function() if PlacerDropdown.RefreshValues then PlacerDropdown:RefreshValues(files) end end)
    end
    if SelectedFile then
        local stillThere = false
        for _, f in ipairs(files) do if f == SelectedFile then stillThere = true ;break end end
        if not stillThere then SelectedFile = nil end
    end
    notify("Placer", #files > 0 and ("Found " .. #files .. " file(s).") or "No record files found.")
end
PlacerTab:Button({ Title = "Refresh Files", Desc = "Re-scan for newer recorded files.", Callback = function() refreshPlacerList() end })
PlacerInfo = PlacerTab:Paragraph({ Title = "Auto Place: OFF", Desc = "Select a file above, then enable Auto Place." })
local function placerStatus(placed, total, upDone, upTotal)
    setParagraph(PlacerInfo, "Auto Place: " .. (AutoPlacing and "ON" or "OFF"), ("File: %s | Placed %d/%d | Upgraded %d/%d"):format(SelectedFile and (SelectedFile .. ".json") or "none", placed or 0, total or 0, upDone or 0, upTotal or 0))
end
local function replayArgs(entry)
    if type(entry.Args) ~= "table" then return nil end
    local out = {}
    for i, a in ipairs(entry.Args) do
        local v = deserializeArg(a)
        if v == nil and a and a.__type == "InstanceRef" then return nil end
        out[i] = v
    end
    return out
end
local UPGRADE_MAX_ATTEMPTS = 40
local UPGRADE_RETRY_DELAY = 0.8
local function findLiveTower(unit, px, py, pz)
    local towersFolder = Workspace:FindFirstChild("Towers")
    if not towersFolder then return nil end
    for _, m in ipairs(towersFolder:GetChildren()) do
        if m.Name == unit and isOwnTower(m) then
            return m
        end
    end
    return nil
end
local function fireUpgrade(entry, live)
    if entry.Method == ("Change" .. "TowerMode") then
        if not ChangeTowerModeRemote then return false, nil end
        local extra = {}
        for i, a in ipairs(entry.Extra or {}) do extra[i] = deserializeArg(a) end
        if #extra == 0 and entry.Skin then extra = {entry.Skin} end
        return pcall(function() return ChangeTowerModeRemote:InvokeServer(live, unpack(extra)) end)
    end
    if not UpgradeTowerRemote then return false, nil end
    -- try live ID first (ManagerHandler path), then skin string (Cobalt path), then no-arg
    local liveId, skin = nil, nil
    pcall(function() liveId = live:GetAttribute("ID") end)
    pcall(function() skin = entry.Skin or live:GetAttribute("Skin") end)
    local tries = {}
    if liveId ~= nil then table.insert(tries, {live, liveId}) end
    if skin ~= nil and skin ~= liveId then table.insert(tries, {live, skin}) end
    if #tries == 0 then table.insert(tries, {live}) end
    -- also include Extra if recorded had it
    if entry.Extra and #entry.Extra > 0 then
        local extra = {}
        for i, a in ipairs(entry.Extra) do extra[i] = deserializeArg(a) end
        table.insert(tries, 1, {live, unpack(extra)})
    end
    for _, args in ipairs(tries) do
        local ok, res = pcall(function() return UpgradeTowerRemote:InvokeServer(unpack(args)) end)
        if ok and res ~= nil and res ~= false then return true, res end
        if ok and res == nil then -- some executors return nil on success, treat as success if no error
            -- check if LVL actually bumped will be confirmed by observer poll
            return true, res
        end
    end
    return false, nil
end
local function fmtMoney(n) local v = tonumber(n) ;if not v then return "?" end return "$" .. tostring(math.floor(v)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "") end
local function fmtTimePair(expected, actual) return string.format("expected %.1fs → actual %.1fs (Δ %+.1fs)", expected or 0, actual or 0, (actual or 0) - (expected or 0)) end
PlacerTab:Toggle({
    Title = "Auto Upgrade",
    Desc = "Also replays recorded level + mode upgrades at their times. Retries until accepted (waits for cash), up to 25 tries each.",
    Value = CfgAutoUpgrade,
    Callback = function(state) CfgAutoUpgrade = (state == true) ;persistPlacer() ;if state and not AutoPlacing then notify("Placer", "Auto Upgrade armed — it runs while Auto Place is ON.") end end,
})
PlacerTab:Toggle({
    Title = "Notify Placer",
    Desc = "Send a notification per successful action with expected vs actual time and price. Off by default.",
    Value = CfgNotify,
    Callback = function(state) CfgNotify = (state == true) ;persistPlacer() end,
})
PlacerTab:Toggle({
    Title = "Place ASAP (Ignore Time)",
    Desc = "When ON, places as soon as you can afford it, ignoring recorded time. Still shows expected vs actual Δ in notifications.",
    Value = CfgIgnoreTime,
    Callback = function(state) CfgIgnoreTime = (state == true) ;persistPlacer() end,
})
AutoPlaceToggle = PlacerTab:Toggle({
    Title = "Auto Place",
    Desc = "Places units from the file when game time >= recorded time.",
    Value = AutoPlacing,
    Callback = function(state)
        AutoPlacing = state and true or false
        persistPlacer()
        if not AutoPlacing then placerStatus() ;return end
        if not SelectedFile then notify("Placer", "Select a recorded file first.", 4) ;AutoPlacing = false persistPlacer() return end
        if not SpawnTower then notify("Placer", "SpawnTower remote not found.", 5) ;AutoPlacing = false persistPlacer() return end
        task.spawn(function()
            local data, err = loadRecord(SelectedFile)
            if not data then notify("Placer", "Load failed: " .. tostring(err), 5) ;AutoPlacing = false placerStatus() persistPlacer() return end
            local places, upgrades = {}, {}
            for _, e in ipairs(data.Actions or data.actions or {}) do
                if e.Kind == "upgrade" then if e.Confirmed ~= false then table.insert(upgrades, e) end
                elseif e.Confirmed ~= false and type(e.Args) == "table" then table.insert(places, e) end
            end
            local function sortByTime(t) table.sort(t, function(a,b) return (a.Elapsed or a.Time or 0) < (b.Elapsed or b.Time or 0) end) end
            sortByTime(places) ;sortByTime(upgrades)
            local doUpgrades = CfgAutoUpgrade and #upgrades > 0
            local upgradesAfterPlaces = #places > 0 and #upgrades > 0 and (upgrades[1].Elapsed or upgrades[1].Time or 0) > (places[#places].Elapsed or places[#places].Time or 0)
            notify("Placer", "Auto placing " .. #places .. " placement(s)" .. (doUpgrades and (" + " .. #upgrades .. " upgrade(s)") or "") .. " from " .. SelectedFile .. ".json" .. (CfgIgnoreTime and " [ASAP]" or "") .. (upgradesAfterPlaces and " [placements first]" or ""))
            local playStartClock = os.clock()
            local playStartGame = GetGameTime()
            local firstTime = (places[1] and places[1].Time) or (upgrades[1] and upgrades[1].Time)
            local useGameTime = playStartGame ~= nil and firstTime ~= nil
            local function timeReady(entry)
                if CfgIgnoreTime then return true end
                if useGameTime then local nowGame = GetGameTime() ;return nowGame ~= nil and entry.Time ~= nil and nowGame >= entry.Time end
                return (os.clock() - playStartClock) >= (entry.Elapsed or 0)
            end
            local placed, placeIdx = 0, 1
            local upDone = 0
            local upState = {}
            for i = 1, #upgrades do upState[i] = { attempts = 0, nextRetry = 0, done = false } end
            local function upTotal() return doUpgrades and #upgrades or 0 end
            -- identity map for upgrades: which live tower was placed at which recorded spot
            local placedByPos = {}
            local function posKey(px,py,pz)
                if px == nil then return nil end
                return string.format("%.1f_%.1f_%.1f", px, py, pz)
            end
            local function findLiveTowerForUpgrade(entry)
                local k = posKey(entry.PX, entry.PY, entry.PZ)
                if k and placedByPos[k] and placedByPos[k].Parent then return placedByPos[k] end
                -- strict: only the tower placed this run at this recorded spot — never
                -- fall back to an old tower, otherwise upgrades run before placements
                return nil
            end
            placerStatus(placed, #places, upDone, upTotal())
            while AutoPlacing and (placeIdx <= #places or (doUpgrades and upDone < #upgrades)) do
                if placeIdx <= #places and timeReady(places[placeIdx]) then
                    local entry = places[placeIdx]
                    local need = tonumber(entry.Price)
                    local have = getCash()
                    if need and have ~= nil and have < need then
                        setParagraph(PlacerInfo, "Auto Place: ON (waiting cash)", ("Need %s have %s for %s @ %s — waiting..."):format(fmtMoney(need), fmtMoney(have), entry.Unit, entry.Loc))
                    else
                        local expected = entry.Elapsed or entry.Time or 0
                        local actual = useGameTime and (GetGameTime() or expected) or (os.clock() - playStartClock)
                        -- skip if this exact spot already has your tower (prevents "You can't place there!" spam)
                        local occupied = false
                        do
                            local folder = Workspace:FindFirstChild("Towers")
                            if folder and entry.PX ~= nil then
                                for _, m in ipairs(folder:GetChildren()) do
                                    if m.Name == entry.Unit and isOwnTower(m) then
                                        local okp, pv = pcall(function() return m:GetPivot() end)
                                        if okp and pv then
                                            local dx = pv.Position.X - entry.PX
                                            local dy = pv.Position.Y - entry.PY
                                            local dz = pv.Position.Z - entry.PZ
                                            if dx*dx+dy*dy+dz*dz < 2*2 then occupied = true break end
                                        end
                                    end
                                end
                            end
                        end
                        local args = replayArgs(entry)
                        local success = false
                        local ok, res
                        if occupied then
                            success = true
                        elseif args then
                            ok, res = pcall(function() return SpawnTower:InvokeServer(unpack(args)) end)
                            if ok and res ~= nil and res ~= false then
                                local stillThere = false
                                pcall(function() if typeof(res) == "Instance" and res.Parent then stillThere = true end end)
                                success = stillThere or typeof(res) ~= "Instance"
                                if typeof(res) == "Instance" and isOwnTower(res) then success = true end
                            else
                                -- strict: nil/false from server means rejected (e.g. "You can't place there!") — don't count as success
                                success = false
                                -- small cooldown to avoid spam
                                task.wait(0.5)
                            end
                        end
                        if success then
                            placed = placed + 1
                            -- log identity for upgrades: which live tower was placed at this recorded spot
                            local liveTower = nil
                            if typeof(res) == "Instance" and pcall(function() return liveTower or res:IsA("Model") end) and isOwnTower(res) then
                                liveTower = res
                            else
                                -- fallback: find the newest own tower of this unit not yet mapped
                                local folder = Workspace:FindFirstChild("Towers")
                                if folder then
                                    for _, m in ipairs(folder:GetChildren()) do
                                        if m.Name == entry.Unit and isOwnTower(m) then
                                            local k2 = posKey(entry.PX, entry.PY, entry.PZ)
                                            if k2 and not placedByPos[k2] then liveTower = m break end
                                        end
                                    end
                                    if not liveTower then
                                        for _, m in ipairs(folder:GetChildren()) do
                                            if m.Name == entry.Unit and isOwnTower(m) and not placedByPos[posKey(entry.PX, entry.PY, entry.PZ)] then liveTower = m break end
                                        end
                                    end
                                end
                            end
                            if liveTower then
                                local k = posKey(entry.PX, entry.PY, entry.PZ)
                                if k then placedByPos[k] = liveTower end
                                local sid = nil
                                pcall(function() sid = liveTower:GetAttribute("ID") end)
                                if CfgNotify then
                                    -- extra identity log when placing Pog Cat etc
                                    print(("[WindHub] placed %s @ %s -> live %s id=%s"):format(entry.Unit, entry.Loc, liveTower.Name, tostring(sid)))
                                end
                            end
                        end
                        if CfgNotify and success then
                            local priceStr = entry.Price and fmtMoney(entry.Price) or "?"
                            notify("Placed " .. entry.Unit, ("%s | %s | %s"):format(entry.Loc, fmtTimePair(expected, actual), priceStr), 4)
                        end
                        placeIdx = placeIdx + 1
                        placerStatus(placed, #places, upDone, upTotal())
                    end
                end
                if doUpgrades then
                    local now = os.clock()
                    for i, entry in ipairs(upgrades) do
                        local st = upState[i]
                        if not st.done and timeReady(entry) and now >= st.nextRetry then
                            if upgradesAfterPlaces and placed < #places then
                                st.nextRetry = now + 0.6
                            else
                                local needUp = tonumber(entry.Price)
                                local haveUp = getCash()
                                if needUp and haveUp ~= nil and haveUp < needUp then st.nextRetry = now + 0.6
                                else
                                    local live = findLiveTowerForUpgrade(entry)
                                    if not live then
                                        -- tower not yet spawned (placements pending) — wait, don't burn attempts
                                        st.nextRetry = now + 0.6
                                else
                                    st.attempts = st.attempts + 1
                                    local ok, res = fireUpgrade(entry, live)
                                local success = ok and res ~= nil and res ~= false
                                if success then
                                    st.done = true
                                    upDone = upDone + 1
                                    placerStatus(placed, #places, upDone, #upgrades)
                                    if CfgNotify then
                                        local expectedUp = entry.Elapsed or entry.Time or 0
                                        local actualUp = useGameTime and (GetGameTime() or expectedUp) or (os.clock() - playStartClock)
                                        local priceStr = entry.Price and fmtMoney(entry.Price) or "?"
                                        notify("Upgraded " .. entry.Unit .. " (" .. tostring(entry.Method or "?") .. ")", ("%s | %s | %s"):format(entry.Loc, fmtTimePair(expectedUp, actualUp), priceStr), 4)
                                    end
                                elseif st.attempts >= UPGRADE_MAX_ATTEMPTS then
                                    st.done = true
                                    upDone = upDone + 1
                                    placerStatus(placed, #places, upDone, #upgrades)
                                else st.nextRetry = now + UPGRADE_RETRY_DELAY end
                                end
                            end
                        end
                    end
                end
                end
                if not AutoPlacing then break end
                task.wait(0.15)
            end
            AutoPlacing = false
            placerStatus(placed, #places, upDone, upTotal())
            persistPlacer()
            local msg = "Finished: placed " .. placed .. "/" .. #places
            if doUpgrades then msg = msg .. ", upgraded " .. upDone .. "/" .. #upgrades end
            notify("Placer", msg .. ".")
        end)
    end,
})
refreshRecorderParagraph()
local HUB_VERSION = "2026-09-25 01:14 UTC — EndScreen.Replay pinned (e028f17)"
print("[WindHub] v" .. HUB_VERSION .. " loaded. Files → " .. FOLDER .. "/")
print("[WindHub] raw: https://raw.githubusercontent.com/FilipinoCollabEmtech/WindHub/main/WindHub_Recorder_Placer.lua")
pcall(function() WindUI:Notify({ Title = "WindHub " .. HUB_VERSION, Content = "Loaded — " .. FOLDER .. "/", Duration = 4 }) end)
