--[[
    Steal An Egg (107778070777162) - Auto Grab Nearest Best Egg
    Uses WindUI (Footagesus).
    Reads the game's real egg/asset data (ReplicatedStorage.Data.Assets)
    and the field-egg snapshot (ReplicatedStorage.Client.EggState) to decide
    which egg is worth the most, then grabs it when near enough to steal.
    Proximity-only: no walking. If the egg is near and stealable, grab it.
]]
print("whatt")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    pcall(function() LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() end)
    LocalPlayer = LocalPlayer or Players.LocalPlayer
    if not LocalPlayer then pcall(function() LocalPlayer = Players.PlayerAdded:Wait() end) end
end
assert(LocalPlayer, "[StealAnEgg] LocalPlayer not found")

-- WindUI (same loader as WindHub scripts)
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
        if ok and res and type(res) == "table" and res.CreateWindow then WindUI = res break end
        err = res
    end
    assert(WindUI, "[StealAnEgg] WindUI failed: " .. tostring(err))
end

-- Wait for game modules (they may not be replicated yet at execute time)
local function waitModule(...)
    local node = ReplicatedStorage
    for _, name in ipairs({ ... }) do
        node = node:WaitForChild(name, 15)
        if not node then return nil end
    end
    return node
end
local EggStateMod = waitModule("Client", "EggState")
local AssetsMod = waitModule("Data", "Assets")
local RarityMod = waitModule("Data", "Rarity")
local SlotIdMod = waitModule("Shared", "Util", "AreaEggSlotIdentity")
assert(EggStateMod and AssetsMod and RarityMod and SlotIdMod, "[StealAnEgg] game modules not found (wrong game?)")
local EggState = require(EggStateMod)
local Assets = require(AssetsMod)
local Rarity = require(RarityMod)
local AreaEggSlotIdentity = require(SlotIdMod)

-- State before UI so callbacks can see it
local AutoGrabEnabled = false
local AllowedRarityIds = nil -- nil = steal any rarity; table set = only these rarities
local STEAL_RANGE = 6 -- under prompt MaxActivationDistance (8); server denies at the edge
local CarryingUid = nil -- uid we currently hold; server allows one carried egg

-- Hit tab state (Bat: Range 15 + HitTolerance 2, CLIENT_COOLDOWN 0.6 per dumps)
local AutoHitEnabled = false
local AutoTrapEnabled = false
local CombatDebug = true
local HitCount, TrapCount, MissCount = 0, 0, 0
local lastSwing, lastTrap = 0, 0
local HIT_RANGE = 14 -- inside 15+2 with margin for 100%
local HIT_COOLDOWN = 0.65
local TRAP_RANGE = 30
local TRAP_COOLDOWN = 5

-- Speed tab state
local AutoTrailEnabled = false
local ForceSpeedEnabled = false
local SelectedTrailName = "Fastest (auto)"
local WorkingTrailId = nil -- first trail id proven wearable this session
local ForcedSpeed = 16
-- movement-method state (bypass WalkSpeed entirely)
local TPWalkEnabled = false
local FlyEnabled = false
local TweenEggEnabled = false
local ClickTPEnabled = false
local VelWalkEnabled = false
local ForceJumpEnabled = false
local CustomGravityEnabled = false
local JumpPreset = 50
local GravityPreset = 100

-- #region UI
local Window = WindUI:CreateWindow({
    Title = "Steal An Egg",
    Icon = "egg",
    Author = "opencode",
    Folder = "StealAnEgg",
    Size = UDim2.fromOffset(460, 500),
    Theme = "Light",
    ToggleKey = Enum.KeyCode.RightControl,
})

local MainTab = Window:Tab({ Title = "Main", Icon = "egg" })

MainTab:Paragraph({
    Title = "Auto Grab",
    Desc = "Grabs the best egg within steal range. Uses the real asset earning values from the game's own data.",
})

MainTab:Toggle({
    Title = "auto grab nearest best egg",
    Desc = "Find the highest-value egg in steal range and steal it. No walking.",
    Value = false,
    Callback = function(state)
        AutoGrabEnabled = (state == true)
    end,
})

-- Allowed-egg rarity filter (multi-select dropdown).
local RarityIds = {}
do
    local seen = {}
    for _, cfg in pairs(Assets.Directory) do
        local id = cfg.Rarity and cfg.Rarity._id
        local rank = cfg.Rarity and cfg.Rarity.Rank or 0
        if id and not seen[id] then
            seen[id] = true
            table.insert(RarityIds, { id = id, rank = rank, name = cfg.Rarity.DisplayName or id })
        end
    end
    table.sort(RarityIds, function(a, b)
        return a.rank < b.rank
    end)
    for i, entry in ipairs(RarityIds) do
        RarityIds[i] = entry.name
    end
end

MainTab:Dropdown({
    Title = "Steal rarities",
    Desc = "Only steal eggs from the selected rarities. Empty = steal any rarity.",
    Values = RarityIds,
    Multi = true,
    AllowNone = true,
    Callback = function(selected)
        if type(selected) ~= "table" then
            selected = { selected }
        end
        AllowedRarityIds = nil
        if #selected > 0 then
            AllowedRarityIds = {}
            for _, name in ipairs(selected) do
                AllowedRarityIds[name] = true
            end
        end
    end,
})

local StatusLabel = MainTab:Paragraph({ Title = "Status", Desc = "idle" })

-- #region Hit tab (BatSwing.Trigger, proven bare FireServer)
local HitTab = Window:Tab({ Title = "Hit", Icon = "swords" })
HitTab:Paragraph({
    Title = "Auto Hit",
    Desc = "Swings your equipped Bat at players in range. Fires only when a hit is guaranteed.",
})
HitTab:Toggle({
    Title = "Auto hit players",
    Desc = "Equip Bat, face nearest player within 14 studs, swing on cooldown.",
    Value = false,
    Callback = function(state)
        AutoHitEnabled = (state == true)
    end,
})
HitTab:Toggle({
    Title = "Auto trap carriers",
    Desc = "Places a Trap ahead of carriers and egg-stealers within 30 studs.",
    Value = false,
    Callback = function(state)
        AutoTrapEnabled = (state == true)
    end,
})
HitTab:Toggle({
    Title = "Combat debug",
    Desc = "Toast every hit/miss/trap with data (tool, distance, HP).",
    Value = true,
    Callback = function(state)
        CombatDebug = (state == true)
    end,
})
local HitStatus = HitTab:Paragraph({ Title = "Hits", Desc = "idle" })
local TrapStatus = HitTab:Paragraph({ Title = "Traps", Desc = "idle" })

-- #region Speed tab (every speed source found in dumps)
local SpeedTab = Window:Tab({ Title = "Speed", Icon = "zap" })
SpeedTab:Paragraph({
    Title = "Speed",
    Desc = "Every way: trails (2.5x-20x) + treadmill SpeedPower (permanent, manual videos) + force WalkSpeed + TPWalk + Fly. Robux SpeedBoost tiers excluded.",
})
local TrailNames = { "Fastest (auto)" }
local TrailByName = {}
do
    local ok, Trails = pcall(function() return require(ReplicatedStorage.Data.Trails) end)
    if ok and Trails then
        local list = {}
        for id, cfg in pairs(Trails) do
            if type(id) == "string" and type(cfg) == "table" and tonumber(cfg.SpeedMultiplier) then
                table.insert(list, { id = id, name = cfg.DisplayName or id, mult = tonumber(cfg.SpeedMultiplier) })
            end
        end
        table.sort(list, function(a, b) return a.mult > b.mult end)
        for _, t in ipairs(list) do
            local disp = string.format("%s (%.1fx)", t.name, t.mult)
            TrailByName[disp] = t.id
            table.insert(TrailNames, disp)
        end
    end
end
SpeedTab:Dropdown({
    Title = "Trail",
    Desc = "Pick a trail or let it use your fastest wearable one.",
    Values = TrailNames,
    Value = "Fastest (auto)",
    Callback = function(selected)
        if type(selected) == "table" then selected = selected[1] end
        SelectedTrailName = tostring(selected or "Fastest (auto)")
    end,
})
SpeedTab:Toggle({
    Title = "Auto trail",
    Desc = "Keeps your fastest wearable trail equipped (server validates ownership).",
    Value = false,
    Callback = function(state)
        AutoTrailEnabled = (state == true)
    end,
})
SpeedTab:Dropdown({
    Title = "WalkSpeed preset",
    Desc = "Target WalkSpeed for the force toggle. Governor may fight it.",
    Values = { "16", "32", "50", "100", "150", "200" },
    Value = "16",
    Callback = function(selected)
        if type(selected) == "table" then selected = selected[1] end
        ForcedSpeed = tonumber(selected) or 16
    end,
})
SpeedTab:Toggle({
    Title = "Force WalkSpeed",
    Desc = "Re-applies WalkSpeed every 0.25s. Server governor may revert/rubber-band.",
    Value = false,
    Callback = function(state)
        ForceSpeedEnabled = (state == true)
    end,
})
SpeedTab:Toggle({
    Title = "TPWalk",
    Desc = "Teleports you along WASD at Move speed. Ignores WalkSpeed/governor completely.",
    Value = false,
    Callback = function(state)
        TPWalkEnabled = (state == true)
    end,
})
SpeedTab:Toggle({
    Title = "Fly",
    Desc = "CFrame fly: WASD + Space up / Ctrl or C down, at Move speed. No physics objects.",
    Value = false,
    Callback = function(state)
        FlyEnabled = (state == true)
    end,
})
SpeedTab:Toggle({
    Title = "Tween to egg",
    Desc = "Smooth-tweens to the nearest matching egg until in steal range, then the grab loop takes it.",
    Value = false,
    Callback = function(state)
        TweenEggEnabled = (state == true)
    end,
})
SpeedTab:Toggle({
    Title = "Click teleport (Ctrl+Click)",
    Desc = "Hold LeftControl and left-click anywhere to teleport there.",
    Value = false,
    Callback = function(state)
        ClickTPEnabled = (state == true)
    end,
})
SpeedTab:Toggle({
    Title = "Velocity walk",
    Desc = "Drives velocity at Move speed or your boosted WalkSpeed, whichever is higher.",
    Value = false,
    Callback = function(state)
        VelWalkEnabled = (state == true)
    end,
})
SpeedTab:Dropdown({
    Title = "Jump preset",
    Desc = "Target JumpPower for the force toggle.",
    Values = { "50", "100", "200", "300", "500" },
    Value = "50",
    Callback = function(selected)
        if type(selected) == "table" then selected = selected[1] end
        JumpPreset = tonumber(selected) or 50
    end,
})
SpeedTab:Toggle({
    Title = "Force JumpPower",
    Desc = "Keeps JumpPower at the preset (higher = further jumps).",
    Value = false,
    Callback = function(state)
        ForceJumpEnabled = (state == true)
    end,
})
SpeedTab:Dropdown({
    Title = "Gravity preset",
    Desc = "Lower gravity = floatier, faster-feeling movement.",
    Values = { "196.2", "100", "50", "25", "0" },
    Value = "100",
    Callback = function(state)
        if type(state) == "table" then state = state[1] end
        GravityPreset = tonumber(state) or 100
    end,
})
SpeedTab:Toggle({
    Title = "Custom Gravity",
    Desc = "Keeps workspace.Gravity at the preset (client-side).",
    Value = false,
    Callback = function(state)
        CustomGravityEnabled = (state == true)
        if not CustomGravityEnabled then
            pcall(function() workspace.Gravity = 196.2 end)
        end
    end,
})
local SpeedStatus = SpeedTab:Paragraph({ Title = "Speed", Desc = "idle" })
-- #endregion
-- #endregion

-- #region helpers
local function Root()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function Humanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

-- Effective move speed: never slower than your real (trail/boosted) WalkSpeed,
-- so methods work out of the box even when the preset is still 16.
local function MoveSpeed()
    local hum = Humanoid()
    local ws = hum and tonumber(hum.WalkSpeed) or 16
    return math.max(ForcedSpeed, ws or 16)
end

local function SetStatus(text)
    if StatusLabel then
        pcall(function() StatusLabel:SetTitle("Status") end)
        pcall(function() StatusLabel:SetDesc(text) end)
    end
end

-- Value of an egg's potential pet. Primary: earning rate. Secondary: rarity rank.
local function EggValue(record)
    local cfg = Assets.Directory[record.AssetCategory]
    if not cfg then
        return 0
    end
    local rate = cfg.EarningRate or 0
    local rank = (cfg.Rarity and cfg.Rarity.Rank) or 0
    local scale = record.AssetScale or 1
    local mutations = #(record.Mutations or {})
    -- Mutations make an egg dramatically more valuable; scale/size adds small weight.
    return (rate or 0) * (1 + 0.5 * (rank - 1)) + (mutations * math.max(rate / 100, 1)) + scale
end

-- Display rarity of the egg's asset (Common, Rare, Legendary, ...).
local function EggRarityName(record)
    local cfg = Assets.Directory[record.AssetCategory]
    return cfg and cfg.Rarity and (cfg.Rarity.DisplayName or cfg.Rarity._id) or nil
end

local function EggPosition(record)
    if record.BottomCFrame then
        return record.BottomCFrame.Position
    end
    if record.BoundsCFrame then
        return record.BoundsCFrame.Position
    end
    return nil
end
-- #endregion

-- #region main loop
-- Proximity-only steal: no walking, no planting, no hatching.
-- If the best egg is near and stealable, grab it.
task.spawn(function()
    while task.wait(0.8) do
        local ok, err = pcall(function()
            if not AutoGrabEnabled then return end
            local root = Root()
            local humanoid = Humanoid()
            if not root or not humanoid then return end

            -- Fresh snapshot of every field egg.
            local snapshot = EggState.SyncFieldEggs()
            local records = snapshot and snapshot.Records or {}
            if #records == 0 then
                SetStatus("no eggs in field")
                return
            end

            -- Hands check the way the game does it (ForestGuardRuntime):
            -- a field record with State == "Carried" + our CarrierUserId.
            local carried = nil
            for _, record in ipairs(records) do
                if record.State == "Carried" and record.CarrierUserId == LocalPlayer.UserId then carried = record break end
            end
            local carriedValue = carried and EggValue(carried) or 0
            local carriedName = carried and ((Assets.Directory[carried.AssetCategory] and Assets.Directory[carried.AssetCategory].DisplayName) or carried.AssetCategory) or nil

            -- Usable eggs: sitting in a nest, not carried, not claimed, in the
            -- selected rarity filter (if any), AND within steal range (no walking).
            local myPos = root.Position
            local candidates = {}
            for _, record in ipairs(records) do
                local usable = record.State == "Slot"
                if usable and AllowedRarityIds then
                    local rarityName = EggRarityName(record)
                    if not rarityName or not AllowedRarityIds[rarityName] then
                        usable = false
                    end
                end
                if usable then
                    local pos = EggPosition(record)
                    if not pos or (pos - myPos).Magnitude > STEAL_RANGE then
                        usable = false
                    end
                end
                if usable then
                    table.insert(candidates, record)
                end
            end
            if #candidates == 0 then
                SetStatus("no eggs in steal range")
                return
            end

            -- Pick the best egg by value, then the nearest among those near the top.
            local bestValueGap = 0.8 -- accept eggs within 80% of the max value
            local maxValue = 0
            for _, record in ipairs(candidates) do
                local v = EggValue(record)
                if v > maxValue then
                    maxValue = v
                end
            end
            local best, bestDist = nil, math.huge
            for _, record in ipairs(candidates) do
                local v = EggValue(record)
                if v >= maxValue * bestValueGap then
                    local pos = EggPosition(record)
                    local d = pos and (pos - myPos).Magnitude or math.huge
                    if d < bestDist then
                        best, bestDist = record, d
                    end
                end
            end
            local function statusLine(extra)
                local hold = carriedName and ("holding " .. carriedName .. " (" .. string.format("%.0f", carriedValue) .. ")") or "hands free"
                SetStatus(string.format("%d in range | best %s (%.0f) | %s%s", #candidates, best and ((Assets.Directory[best.AssetCategory] and Assets.Directory[best.AssetCategory].DisplayName) or best.AssetCategory) or "-", best and EggValue(best) or 0, hold, extra and (" | " .. extra) or ""))
            end
            if not best then
                statusLine("no match")
                return
            end

            local display = Assets.Directory[best.AssetCategory]
            local name = (display and display.DisplayName) or best.AssetCategory
            local bestVal = EggValue(best)

            if carried then
                if bestVal <= carriedValue * 1.1 then
                    statusLine("keeping")
                    return
                end
                -- Better egg in range: drop current, steal better next tick.
                EggState.DropFieldEgg("PlayerRequest")
                statusLine("dropped " .. carriedName .. " for " .. name)
                return
            end

            -- Hands free and in range: grab directly, no movement.
            statusLine("stealing...")
            local firstKey = nil
            if best.Uid and best.AreaId and best.NestId and AreaEggSlotIdentity.LooksLikeFirstAreaUid(best.Uid) then
                firstKey = AreaEggSlotIdentity.SlotKey(best.AreaId, best.NestId)
            end
            local ok, err = EggState.CarryFieldEgg(best.Uid, firstKey)
            if ok then
                local rarityTxt = EggRarityName(best) or "?"
                local muts = #(best.Mutations or {})
                local filterTxt = AllowedRarityIds and ("filter: " .. rarityTxt) or "filter: any"
                pcall(function()
                    WindUI:Notify({ Title = "Grabbed " .. name, Content = string.format("%s | value %.0f | %d mutations | %s", rarityTxt, bestVal, muts, filterTxt), Duration = 4 })
                end)
                statusLine("grabbed!")
            else
                statusLine("carry denied: " .. tostring(err))
            end
        end)
        if not ok then SetStatus("error: " .. tostring(err):sub(1, 80)) end
    end
end)
-- #endregion

-- #region hit helpers (BatController.Client conditions)
local NetCache = {}
local function NetRemote(name)
    if NetCache[name] ~= nil then return NetCache[name] end
    local node = ReplicatedStorage:FindFirstChild("Packages")
    node = node and node:FindFirstChild("Networking")
    node = node and node:WaitForChild(name, 8)
    NetCache[name] = node
    return node
end

local function SetHitStatus(text)
    if HitStatus then
        pcall(function() HitStatus:SetDesc(text) end)
    end
end

-- Returns tool + whether it is already equipped (in Character).
local function FindTool(pattern)
    local char = LocalPlayer.Character
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") and t.Name:match(pattern) then return t, true end
        end
    end
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if t:IsA("Tool") and t.Name:match(pattern) then return t, false end
        end
    end
    return nil, false
end

local function CombatNotify(title, content)
    if CombatDebug then
        pcall(function()
            WindUI:Notify({ Title = title, Content = content, Duration = 3 })
        end)
    end
end

local function SetTrapStatus(text)
    if TrapStatus then
        pcall(function() TrapStatus:SetDesc(text) end)
    end
end

-- Per-tool RangeBonus from Gears configs (BatControllerData). Effective swing
-- range = 15 + 2 + bonus; we fire with 1 stud margin.
local BAT_RANGE_BONUS = {
    Staff = 20.625, Axe = 18.75, Katana = 16.875, Cosmic = 15,
    Prehistoric = 13.125, Abyss = 11.25, Volcano = 9.375, Snow = 7.5,
    Jungle = 5.625, Desert = 3.75, Lake = 1.875,
}
local function ClassifyMelee(tool)
    if not tool then return nil end
    if tool:FindFirstChild("Controller") then
        local n = tool.Name:lower()
        if n:find("swatter", 1, true) or n:find("scrambler", 1, true) then
            return "slap", 0 -- ToolController Slap: remote unpinned, tried anyway
        end
        return "bat", 0
    end
    local n = tool.Name
    if n:match("[Bb]at") or n:match("[Kk]atana") or n:match("[Aa]xe") or n:match("[Ss]taff") then
        return "bat", 0
    end
    return nil
end

local function MeleeRange(tool)
    local kind = ClassifyMelee(tool)
    if not kind then return nil end
    local bonus = 0
    for key, val in pairs(BAT_RANGE_BONUS) do
        if tool.Name:find(key) then bonus = val break end
    end
    return 15 + 2 + bonus - 1, kind, bonus
end

-- Any melee tool (any Bat/Axe/Katana/Staff with Controller child or matching name).
local function FindMeleeTool()
    local char = LocalPlayer.Character
    local bp = LocalPlayer:FindFirstChild("Backpack")
    local function scan(parent, equipped)
        if not parent then return nil end
        for _, t in ipairs(parent:GetChildren()) do
            if t:IsA("Tool") and ClassifyMelee(t) then return t, equipped end
        end
        return nil
    end
    local tool, eq = scan(char, true)
    if tool then return tool, eq end
    return scan(bp, false)
end

-- Enemy stealing an egg = within 10 studs of any Slot egg (not just carrying).
local function NearestStealer(records, maxDist)
    local root = Root()
    if not root then return nil, math.huge end
    local best, bestD, bestEgg = nil, maxDist, nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then
                for _, record in ipairs(records) do
                    if record.State == "Slot" then
                        local pos = EggPosition(record)
                        if pos and (pos - hrp.Position).Magnitude <= 10 then
                            local d = (hrp.Position - root.Position).Magnitude
                            if d <= bestD then best, bestD, bestEgg = p, d, record end
                            break
                        end
                    end
                end
            end
        end
    end
    return best, bestD, bestEgg
end

local function NearestEnemy(maxDist)
    local root = Root()
    if not root then return nil, math.huge end
    local best, bestD = nil, maxDist
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then
                local d = (hrp.Position - root.Position).Magnitude
                if d <= bestD then best, bestD = p, d end
            end
        end
    end
    return best, bestD
end
-- #endregion

local swingSeq = 0
-- Mirrors ToolGameplayGuard.IsInsideSafeZone: root inside a SafeZone-tagged part.
local function IsInSafeZone(player)
    local char = player and player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local pos = hrp.Position
    local ok, tagged = pcall(function()
        return game:GetService("CollectionService"):GetTagged("SafeZone")
    end)
    if not ok or not tagged then return false end
    for _, part in ipairs(tagged) do
        if part and part:IsA("BasePart") and part:IsDescendantOf(workspace) then
            local rel = part.CFrame:PointToObjectSpace(pos)
            local s = part.Size
            if math.abs(rel.X) <= s.X / 2 and math.abs(rel.Y) <= s.Y / 2 and math.abs(rel.Z) <= s.Z / 2 then
                return true
            end
        end
    end
    return false
end
-- Trace id exactly like BatController: "UserId:seq:serverTimeMs" (per your Cobalt).
local function SwingTraceId()
    swingSeq = swingSeq + 1
    local ms = 0
    pcall(function() ms = math.floor(workspace:GetServerTimeNow() * 1000) end)
    return ("%d:%d:%d"):format(LocalPlayer.UserId, swingSeq, ms)
end
-- #region hit loop (counts only server-confirmed hits; never blocks on verifies)
local pendingHits = {} -- {player, hp, pos, t0}: HP drop or fling within window = HIT
local pendingTraps = {} -- {uid, carrierId, t0}: egg turns Dropped = trapped
local lastHitText = "idle"
local trapState = "idle"
task.spawn(function()
    while task.wait(0.25) do
        local ok, err = pcall(function()
            if not AutoHitEnabled and not AutoTrapEnabled then return end
            local root = Root()
            local humanoid = Humanoid()
            if not root or not humanoid or humanoid.Health <= 0 then return end
            if workspace:GetAttribute("PvPDisabled") == true then
                SetHitStatus("PvP disabled")
                return
            end
            if IsInSafeZone(LocalPlayer) then
                SetHitStatus("in safe zone (tools blocked)")
                return
            end
            local now = os.clock()
            -- resolve pending hit confirms (HP drop or flung > 8) without blocking
            for i = #pendingHits, 1, -1 do
                local ph = pendingHits[i]
                local age = now - ph.t0
                local plr = ph.player
                if plr and plr.Character then
                    local hum = plr.Character:FindFirstChildOfClass("Humanoid")
                    local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
                    if hum and hrp then
                        if hum.Health < ph.hp - 1 then
                            HitCount = HitCount + 1
                            lastHitText = "HIT " .. plr.Name
                            CombatNotify("HIT " .. plr.Name, string.format("%s (%s) | %.0fm | HP %.0f->%.0f", ph.tool or "?", ph.kind or "?", ph.dist or 0, ph.hp, hum.Health))
                            table.remove(pendingHits, i)
                        elseif (hrp.Position - ph.pos).Magnitude > 8 then
                            HitCount = HitCount + 1
                            lastHitText = "HIT " .. plr.Name .. " (flung)"
                            CombatNotify("HIT " .. plr.Name .. " (flung)", string.format("%s (%s) | %.0fm", ph.tool or "?", ph.kind or "?", ph.dist or 0))
                            table.remove(pendingHits, i)
                        elseif age > 2.5 then
                            MissCount = MissCount + 1
                            lastHitText = "MISS " .. plr.Name .. " (moved?)"
                            CombatNotify("MISS " .. plr.Name, string.format("%s | %.0fm | no HP drop/fling in 2.5s", ph.tool or "?", ph.dist or 0))
                            table.remove(pendingHits, i)
                        end
                    else
                        HitCount = HitCount + 1
                        lastHitText = "HIT " .. plr.Name .. " (down)"
                        table.remove(pendingHits, i)
                    end
                elseif age > 1 then
                    table.remove(pendingHits, i)
                end
            end
            -- one field snapshot per tick, shared by trap place + trap resolve
            local records = nil
            if AutoTrapEnabled then
                local snapshot = EggState.SyncFieldEggs()
                records = snapshot and snapshot.Records or {}
                for i = #pendingTraps, 1, -1 do
                    local pt = pendingTraps[i]
                    local age = now - pt.t0
                    if pt.mode == "freeze" then
                        local done = false
                        if pt.player and pt.player.Character then
                            local cr = pt.player.Character:FindFirstChild("HumanoidRootPart")
                            if cr and (cr.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude < 2 then
                                TrapCount = TrapCount + 1
                                trapState = "trapped (frozen) " .. pt.player.Name
                                CombatNotify("TRAPPED " .. pt.player.Name, "stealer frozen still")
                                done = true
                            end
                        else
                            done = true -- left/died: drop silently
                        end
                        if done or age > 5 then
                            if not done then trapState = "no effect (still moving)" end
                            table.remove(pendingTraps, i)
                        end
                    else
                        local found, dropped = false, false
                        for _, record in ipairs(records) do
                            if record.Uid == pt.uid then
                                found = true
                                if record.State == "Dropped" then dropped = true end
                                break
                            end
                        end
                        if dropped then
                            TrapCount = TrapCount + 1
                            trapState = "trapped! egg dropped"
                            CombatNotify("TRAPPED (egg dropped)", "carrier " .. tostring(pt.pname or "?"))
                            table.remove(pendingTraps, i)
                        elseif not found or age > 8 then
                            if age > 8 then trapState = "no effect" end
                            table.remove(pendingTraps, i)
                        end
                    end
                end
            end
            -- unified equip manager: ONE tool decision per tick (bat/trap equip-fighting meant nothing ever fired)
            local batToolD = FindMeleeTool()
            local trapToolD = FindTool("^Trap")
            local wantKindD = nil
            do
                if AutoTrapEnabled and (now - lastTrap) >= TRAP_COOLDOWN and trapToolD ~= nil and records ~= nil then
                    for _, record in ipairs(records) do
                        if record.State == "Carried" and record.CarrierUserId and record.CarrierUserId ~= LocalPlayer.UserId then
                            local pos = EggPosition(record)
                            if pos and (pos - root.Position).Magnitude <= TRAP_RANGE then wantKindD = "trap" break end
                        end
                    end
                    if not wantKindD and NearestStealer(records, TRAP_RANGE) then wantKindD = "trap" end
                end
                if not wantKindD and AutoHitEnabled and (now - lastSwing) >= HIT_COOLDOWN and batToolD then
                    local rr = MeleeRange(batToolD) or HIT_RANGE
                    if NearestEnemy(rr) then wantKindD = "bat" end
                end
                if AutoHitEnabled and (now - lastSwing) >= HIT_COOLDOWN and not batToolD then
                    lastHitText = "no melee tool (Bat/Axe/Katana/Staff)"
                end
                if AutoTrapEnabled and (now - lastTrap) >= TRAP_COOLDOWN and not trapToolD then
                    trapState = "no Trap tool"
                end
            end
            if wantKindD == "bat" then
                local bat, equipped = FindMeleeTool()
                if not bat then
                    lastHitText = "no melee tool (Bat/Axe/Katana/Staff)"
                elseif not equipped then
                    humanoid:EquipTool(bat) -- must be equipped or server rejects; swing next tick
                    lastHitText = "equipping " .. bat.Name .. "..."
                else
                    local range, kind = MeleeRange(bat)
                    range = range or HIT_RANGE
                    local target, dist = NearestEnemy(range)
                    if not target or not target.Character then
                        lastHitText = "no target in " .. string.format("%.0f", range) .. " (" .. bat.Name .. ")"
                    else
                        local hrp = target.Character:FindFirstChild("HumanoidRootPart")
                        local hum = target.Character:FindFirstChildOfClass("Humanoid")
                        if hrp and hum then
                            root.CFrame = CFrame.lookAt(root.Position, Vector3.new(hrp.Position.X, root.Position.Y, hrp.Position.Z))
                            local trig = NetRemote("RE/BatSwing/Trigger")
                            if trig then
                                pcall(function() trig:FireServer(target, SwingTraceId()) end)
                                lastSwing = os.clock()
                                table.insert(pendingHits, { player = target, hp = hum.Health, pos = hrp.Position, t0 = os.clock(), tool = bat.Name, kind = kind or "?", dist = dist })
                                if #pendingHits > 5 then table.remove(pendingHits, 1) end
                                lastHitText = "swung " .. bat.Name .. " at " .. target.Name .. "..."
                            else
                                lastHitText = "no swing remote"
                            end
                        end
                    end
                end
            end
            if wantKindD == "trap" and records then
                local trapTool, equipped = FindTool("^Trap")
                if not trapTool then
                    trapState = "no Trap tool"
                elseif not equipped then
                    humanoid:EquipTool(trapTool) -- must replicate equipped first; place next tick
                    trapState = "equipping trap..."
                else
                    -- carriers first, then players caught stealing (near a Slot egg)
                    local victim, victimKind, eggUid, aimPos = nil, nil, nil, nil
                    for _, record in ipairs(records) do
                        if record.State == "Carried" and record.CarrierUserId and record.CarrierUserId ~= LocalPlayer.UserId then
                            local pos = EggPosition(record)
                            if pos and (pos - root.Position).Magnitude <= TRAP_RANGE then
                                for _, p in ipairs(Players:GetPlayers()) do
                                    if p.UserId == record.CarrierUserId and p.Character then
                                        local cr = p.Character:FindFirstChild("HumanoidRootPart")
                                        if cr then
                                            victim, victimKind, eggUid = p, "carrier", record.Uid
                                            aimPos = cr.Position + cr.AssemblyLinearVelocity * 0.4
                                            break
                                        end
                                    end
                                end
                                if victim then break end
                            end
                        end
                    end
                    if not victim then
                        local stealer = NearestStealer(records, TRAP_RANGE)
                        if stealer and stealer.Character then
                            local cr = stealer.Character:FindFirstChild("HumanoidRootPart")
                            if cr then
                                victim, victimKind = stealer, "stealer"
                                aimPos = cr.Position + cr.AssemblyLinearVelocity * 0.4
                            end
                        end
                    end
                    if not victim then
                        trapState = "no carrier/stealer in " .. TRAP_RANGE
                    else
                        local toolTrig = NetRemote("RE/ToolTrigger/Trigger")
                        local askPlace = NetRemote("RE/TrapPlacement/AskPlace")
                        if toolTrig and askPlace then
                            -- traps sit on the ground: raycast down from the aim point
                            local ground = aimPos
                            pcall(function()
                                local rp = RaycastParams.new()
                                rp.FilterType = Enum.RaycastFilterType.Exclude
                                rp.FilterDescendantsInstances = { LocalPlayer.Character }
                                local res = workspace:Raycast(aimPos + Vector3.new(0, 5, 0), Vector3.new(0, -60, 0), rp)
                                if res and res.Position then ground = res.Position end
                            end)
                            pcall(function() toolTrig:FireServer(trapTool) end)
                            pcall(function()
                                askPlace:FireServer("Trap", Vector3.new(ground.X, ground.Y, ground.Z))
                            end)
                            lastTrap = os.clock()
                            table.insert(pendingTraps, { mode = (victimKind == "carrier") and "egg" or "freeze", uid = eggUid, player = victim, pname = victim.Name, t0 = os.clock() })
                            if #pendingTraps > 5 then table.remove(pendingTraps, 1) end
                            trapState = "trap placed for " .. victim.Name .. " (" .. victimKind .. "), watching..."
                            CombatNotify("Trap placed", victim.Name .. " (" .. victimKind .. ")")
                        else
                            trapState = "no trap remotes"
                        end
                    end
                end
            end
            local tgtTxt = ""
            do
                local t = NearestEnemy(HIT_RANGE)
                if t and t.Character then
                    local hrp = t.Character:FindFirstChild("HumanoidRootPart")
                    if hrp then tgtTxt = " | target " .. t.Name .. " (" .. string.format("%.1f", (hrp.Position - root.Position).Magnitude) .. ")" end
                end
            end
            local cdTxt = (now - lastSwing) >= HIT_COOLDOWN and "ready" or "cooling"
            SetHitStatus(string.format("shots %d | hits %d | miss %d | %s | cd %s%s", HitCount + MissCount, HitCount, MissCount, lastHitText, cdTxt, tgtTxt))
            SetTrapStatus(string.format("traps %d | %s", TrapCount, trapState))
        end)
        if not ok then SetHitStatus("error: " .. tostring(err):sub(1, 80)) end
    end
end)
-- #endregion

-- #region speed loop (trail multipliers + forced WalkSpeed)
local function SetSpeedStatus(text)
    if SpeedStatus then
        pcall(function() SpeedStatus:SetDesc(text) end)
    end
end

local function WearTrailByName(name)
    local id = TrailByName[name]
    if not id then return false end
    local remote = NetRemote("RF/Trailwear/AskChoose")
    if not remote then return false end
    local ok, res = pcall(function() return remote:InvokeServer(id) end)
    return ok and res ~= nil and res ~= false
end

local function DiscoverFastestTrail()
    if WorkingTrailId then
        local ok = pcall(function()
            local remote = NetRemote("RF/Trailwear/AskChoose")
            return remote and remote:InvokeServer(WorkingTrailId)
        end)
        if ok then return WorkingTrailId end
        WorkingTrailId = nil
    end
    local sorted = {}
    for name, id in pairs(TrailByName) do table.insert(sorted, name) end
    -- sort by multiplier desc using display suffix
    table.sort(sorted, function(a, b)
        local ma = tonumber(a:match("%(([%d%.]+)x%)")) or 0
        local mb = tonumber(b:match("%(([%d%.]+)x%)")) or 0
        return ma > mb
    end)
    for _, name in ipairs(sorted) do
        local id = TrailByName[name]
        local remote = NetRemote("RF/Trailwear/AskChoose")
        if remote then
            local ok, res = pcall(function() return remote:InvokeServer(id) end)
            if ok and res ~= nil and res ~= false then
                WorkingTrailId = id
                return id
            end
        end
    end
    return nil
end

local function WornTrailId()
    local remote = NetRemote("RF/Trailwear/AskWornSnapshot")
    if not remote then return nil end
    local ok, snap = pcall(function() return remote:InvokeServer() end)
    if not ok or type(snap) ~= "table" then return nil end
    for k, v in pairs(snap) do
        local plr = nil
        pcall(function() plr = Players:GetPlayerByUserId(tonumber(k)) end)
        if plr == LocalPlayer then return v end
    end
    return nil
end

task.spawn(function()
    while task.wait(2) do
        local ok, err = pcall(function()
            if AutoTrailEnabled then
                local want = SelectedTrailName
                if want == "Fastest (auto)" then
                    local id = DiscoverFastestTrail()
                    want = id
                    if not want then
                        SetSpeedStatus("no wearable trail found")
                        return
                    end
                    -- map id back to display name for status
                    for n, i in pairs(TrailByName) do
                        if i == want then want = n break end
                    end
                else
                    want = nil
                    for n, _ in pairs(TrailByName) do
                        if n == SelectedTrailName or n:find(SelectedTrailName, 1, true) then want = n break end
                    end
                    if want then WearTrailByName(want) end
                end
                local worn = WornTrailId()
                local hum = Humanoid()
                local ws = hum and math.floor(hum.WalkSpeed) or -1
                SetSpeedStatus(string.format("ws %d | worn %s | want %s | tpwalk %s fly %s", ws, tostring(worn), tostring(want), TPWalkEnabled and "on" or "off", FlyEnabled and "on" or "off"))
            end
            if ForceSpeedEnabled then
                local hum = Humanoid()
                if hum and hum.Health > 0 and math.abs(hum.WalkSpeed - ForcedSpeed) > 0.5 then
                    hum.WalkSpeed = ForcedSpeed
                end
            end
        end)
        if not ok then SetSpeedStatus("error: " .. tostring(err):sub(1, 80)) end
    end
end)
-- #endregion

-- #region movement methods (TPWalk / Fly)
RunService.Heartbeat:Connect(function(dt)
    if not TPWalkEnabled then return end
    pcall(function()
        local hum = Humanoid()
        local root = Root()
        if hum and root and hum.Health > 0 and hum.MoveDirection.Magnitude > 0.1 then
            root.CFrame = root.CFrame + hum.MoveDirection * MoveSpeed() * dt
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end)
end)

RunService.RenderStepped:Connect(function(dt)
    if not FlyEnabled then return end
    pcall(function()
        local hum = Humanoid()
        local root = Root()
        if hum and root and hum.Health > 0 then
            local dir = hum.MoveDirection
            local up = 0
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then up = 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.C) then up = up - 1 end
            local flat = Vector3.new(dir.X, 0, dir.Z)
            if flat.Magnitude > 0.1 then flat = flat.Unit else flat = Vector3.zero end
            local sp = MoveSpeed()
            local move = flat * sp * dt + Vector3.new(0, up * sp * dt, 0)
            if move.Magnitude > 0 then
                root.CFrame = root.CFrame + move
            end
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end)
end)

-- #endregion

-- #region executor tricks (tween / click TP / velocity walk / jump / gravity)
local activeTween, tweenUid = nil, nil
task.spawn(function()
    while task.wait(0.5) do
        local ok = pcall(function()
            if not TweenEggEnabled then
                if activeTween then pcall(function() activeTween:Cancel() end) activeTween, tweenUid = nil, nil end
                return
            end
            local root = Root()
            if not root then return end
            local snapshot = EggState.SyncFieldEggs()
            local records = snapshot and snapshot.Records or {}
            local best, bestD = nil, math.huge
            for _, record in ipairs(records) do
                if record.State == "Slot" then
                    local usable = true
                    if AllowedRarityIds then
                        local rn = EggRarityName(record)
                        if not rn or not AllowedRarityIds[rn] then usable = false end
                    end
                    if usable then
                        local pos = EggPosition(record)
                        if pos then
                            local d = (pos - root.Position).Magnitude
                            if d < bestD and d > STEAL_RANGE then best, bestD = record, d end
                        end
                    end
                end
            end
            if not best then
                if activeTween then pcall(function() activeTween:Cancel() end) activeTween, tweenUid = nil, nil end
                return
            end
            if tweenUid ~= best.Uid or not activeTween then
                if activeTween then pcall(function() activeTween:Cancel() end) end
                local pos = EggPosition(best)
                local dist = (pos - root.Position).Magnitude
                local tw = TweenService:Create(root, TweenInfo.new(math.max(0.2, dist / 250), Enum.EasingStyle.Linear), { CFrame = CFrame.new(pos) * CFrame.new(0, 3, 0) })
                activeTween, tweenUid = tw, best.Uid
                tw:Play()
            end
        end)
        if not ok then
            if activeTween then pcall(function() activeTween:Cancel() end) activeTween, tweenUid = nil, nil end
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if not ClickTPEnabled or gpe then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        pcall(function()
            local mouse = LocalPlayer:GetMouse()
            local root = Root()
            if mouse and root then
                root.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0))
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end)
    end
end)

-- RenderStepped = last write before replication, so the humanoid controller can't overwrite it.
RunService.RenderStepped:Connect(function()
    if not VelWalkEnabled then return end
    pcall(function()
        local hum, root = Humanoid(), Root()
        if hum and root and hum.Health > 0 then
            local dir = hum.MoveDirection
            local vel = root.AssemblyLinearVelocity
            local sp = MoveSpeed()
            if dir.Magnitude > 0.1 then
                root.AssemblyLinearVelocity = Vector3.new(dir.X * sp, vel.Y, dir.Z * sp)
            else
                root.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
            end
        end
    end)
end)

task.spawn(function()
    while task.wait(1) do
        pcall(function()
            if ForceJumpEnabled then
                local hum = Humanoid()
                if hum and hum.Health > 0 then
                    hum.UseJumpPower = true
                    if math.abs(hum.JumpPower - JumpPreset) > 1 then
                        hum.JumpPower = JumpPreset
                    end
                end
            end
            if CustomGravityEnabled then
                if workspace.Gravity ~= GravityPreset then
                    workspace.Gravity = GravityPreset
                end
            end
        end)
    end
end)
-- #endregion

print("[StealAnEgg] loaded")
