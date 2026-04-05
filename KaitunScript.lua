--[[
    KaitunScript.lua - Script không GUI cho NatiCheat
    Chạy file này (đã có KaitunConfig.lua cùng thư mục)
]]
getgenv().Kaitun_Running = false

repeat task.wait() until game:IsLoaded()
repeat task.wait() until game.GameId ~= 0

-- ============================================
-- LOAD CONFIG
-- ============================================
local ConfigPath = "KaitunConfig.lua"
local Config = nil

local function LoadConfig()
    if isfile and isfile(ConfigPath) then
        local ok, res = pcall(loadstring(readfile(ConfigPath)))
        if ok and res then
            return res
        end
    end
    print("[Kaitun] Config not found or error: " .. ConfigPath)
    return nil
end

Config = LoadConfig()
if not Config then
    warn("[Kaitun] Failed to load config! Using default settings.")
    Config = {
        FarmMode = "Mob",
        MobFarm = { Enabled = true, SelectedMobs = {} },
        BossFarm = { Enabled = false },
        Priority = {"Boss", "Pity Boss", "Summon", "Level Farm", "All Mob Farm", "Mob", "Merchant"},
        AutoFeatures = { M1 = true, M1Speed = 0.35, Haki = { Observation = false, Armament = false, Conqueror = false } },
        Movement = { Type = "Tween", Speed = 180, PositionType = "Front", Distance = 10, IslandTP = true, IslandTPCD = 0.67 },
        Misc = { Notifications = true }
    }
end

-- ============================================
-- CORE SETUP
-- ============================================
local function missing(t, f, fallback)
    if type(f) == t then return f end
    return fallback
end

cloneref = missing("function", cloneref, function(...) return ... end)
getgc = missing("function", getgc or get_gc_objects)
getconnections = missing("function", getconnections or get_signal_cons)

Services = setmetatable({}, {
    __index = function(self, name)
        local success, cache = pcall(function()
            return cloneref(game:GetService(name))
        end)
        if success then rawset(self, name, cache); return cache
        else error("Invalid Service: " .. tostring(name)) end
    end
})

local Players = Services.Players
local Plr = Players.LocalPlayer
local Char = Plr.Character or Plr.CharacterAdded:Wait()
local PGui = Plr:WaitForChild("PlayerGui")
local RS = Services.ReplicatedStorage
local RunService = Services.RunService
local HttpService = Services.HttpService
local UIS = Services.UserInputService
local TweenService = Services.TweenService

local Script_Start_Time = os.time()
local StartStats = {
    Level = Plr.Data.Level.Value,
    Money = Plr.Data.Money.Value,
    Gems = Plr.Data.Gems.Value
}

-- ============================================
-- HELPERS
-- ============================================
local function GetSessionTime()
    local s = os.time() - Script_Start_Time
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    return string.format("%dh %02dm", h, m)
end

local function GetSafeModule(parent, name)
    local obj = parent:FindFirstChild(name)
    if obj and obj:IsA("ModuleScript") then
        local ok, res = pcall(require, obj)
        if ok then return res end
    end
    return nil
end

local function GetRemote(parent, path)
    local cur = parent
    for _, name in ipairs(path:split(".")) do
        if not cur then return nil end
        cur = cur:FindFirstChild(name)
    end
    return cur
end

local function Log(msg)
    local lvl = Plr.Data.Level.Value
    local sess = GetSessionTime()
    print(string.format("[Kaitun %s | Lvl %d | %s] %s", Config.ScriptName or "Kaitun", lvl, sess, msg))
end

local function LogWarn(msg)
    warn(string.format("[Kaitun WARN] %s", msg))
end

local function GetCharacter()
    return Plr.Character or Plr.CharacterAdded:Wait()
end

local function GetRoot()
    local char = GetCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function GetHumanoid()
    local char = GetCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function GetNearestPlayerByDistance(maxDist)
    local root = GetRoot()
    if not root then return nil end
    local nearest, dist = nil, maxDist
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= Plr then
            local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (root.Position - r.Position).Magnitude
                if d < dist then
                    dist = d; nearest = p
                end
            end
        end
    end
    return nearest, dist
end

local function IsNPCAlive(npc)
    if not npc then return false end
    local hum = npc:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health > 0 and npc:FindFirstChild("HumanoidRootPart") ~= nil
end

local function GetNPCs()
    local npcs = {}
    local npcFolder = workspace:FindFirstChild("NPCs")
    if npcFolder then
        for _, npc in pairs(npcFolder:GetChildren()) do
            if IsNPCAlive(npc) then
                table.insert(npcs, npc)
            end
        end
    end
    return npcs
end

local function GetNearestNPC(maxDist)
    local root = GetRoot()
    if not root then return nil end
    local nearest, bestDist = nil, maxDist
    for _, npc in pairs(GetNPCs()) do
        local r = npc:FindFirstChild("HumanoidRootPart")
        if r then
            local d = (root.Position - r.Position).Magnitude
            if d < bestDist then
                bestDist = d; nearest = npc
            end
        end
    end
    return nearest, bestDist
end

local function TeleportTo(pos)
    local root = GetRoot()
    if not root then return end
    if Config.Movement.Type == "Tween" then
        local dist = (root.Position - pos).Magnitude
        local speed = Config.Movement.Speed or 180
        local tween = TweenService:Create(root, TweenInfo.new(dist / speed, Enum.EasingStyle.Linear), {CFrame = CFrame.new(pos)})
        tween:Play()
    else
        root.CFrame = CFrame.new(pos)
    end
end

local function CheckArmHaki()
    local char = GetCharacter()
    return char and char:FindFirstChild("ArmourHaki") ~= nil
end

local function CheckObsHaki()
    local char = GetCharacter()
    return char and char:FindFirstChild("ObservationHaki") ~= nil
end

local function IsBusy()
    local hum = GetHumanoid()
    if not hum then return false end
    local state = hum:GetState()
    return state == Enum.HumanoidStateType.FallingDown or state == Enum.HumanoidStateType.GettingUp
        or state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.Seated
        or state == Enum.HumanoidStateType.Dead
end

-- ============================================
-- REMOTES
-- ============================================
local Remotes = {
    M1 = GetRemote(RS, "CombatSystem.Remotes.RequestHit"),
    EquipWeapon = GetRemote(RS, "Remotes.EquipWeapon"),
    UseSkill = GetRemote(RS, "AbilitySystem.Remotes.RequestAbility"),
    ArmHaki = GetRemote(RS, "RemoteEvents.HakiRemote"),
    ObserHaki = GetRemote(RS, "RemoteEvents.ObservationHakiRemote"),
    ConquerorHaki = GetRemote(RS, "Remotes.ConquerorHakiRemote"),
    TP_Portal = GetRemote(RS, "Remotes.TeleportToPortal"),
    OpenMerchant = GetRemote(RS, "Remotes.MerchantRemotes.OpenMerchantUI"),
    MerchantBuy = GetRemote(RS, "Remotes.MerchantRemotes.PurchaseMerchantItem"),
    StockUpdate = GetRemote(RS, "Remotes.MerchantRemotes.MerchantStockUpdate"),
    SummonBoss = GetRemote(RS, "Remotes.RequestSummonBoss"),
    QuestAccept = GetRemote(RS, "RemoteEvents.QuestAccept"),
    QuestAbandon = GetRemote(RS, "RemoteEvents.QuestAbandon"),
    ReqInventory = GetRemote(RS, "Remotes.RequestInventory"),
}

-- ============================================
-- MODULES
-- ============================================
local Modules = {
    BossConfig = GetSafeModule(RS.Modules, "BossConfig") or {Bosses = {}},
    Merchant = GetSafeModule(RS.Modules, "MerchantConfig") or {ITEMS = {}},
    WeaponClass = GetSafeModule(RS.Modules, "WeaponClassification") or {Tools = {}},
    Fruits = GetSafeModule(RS.Modules, "FruitPowerConfig") or {Powers = {}},
    Title = GetSafeModule(RS.Modules, "TitlesConfig") or {},
    Quests = GetSafeModule(RS.Modules, "QuestConfig") or {RepeatableQuests = {}, Questlines = {}},
}

-- ============================================
-- ISLAND / PORTAL SYSTEM
-- ============================================
local IslandMap = {
    ["Starter"] = {CFrame = CFrame.new(0, 27, 0), Portal = nil},
    ["Jungle"] = {CFrame = CFrame.new(2000, 27, 0), Portal = nil},
    ["Desert"] = {CFrame = CFrame.new(4000, 27, 0), Portal = nil},
    ["Snow"] = {CFrame = CFrame.new(6000, 27, 0), Portal = nil},
    ["Sailor"] = {CFrame = CFrame.new(8000, 27, 0), Portal = nil},
    ["Shibuya"] = {CFrame = CFrame.new(10000, 27, 0), Portal = nil},
    ["HuecoMundo"] = {CFrame = CFrame.new(12000, 27, 0), Portal = nil},
    ["Boss"] = {CFrame = CFrame.new(14000, 27, 0), Portal = nil},
    ["Dungeon"] = {CFrame = CFrame.new(16000, 27, 0), Portal = nil},
}

local function GetNearestIsland(pos)
    local nearest, bestDist = nil, math.huge
    for name, data in pairs(IslandMap) do
        local d = (pos - data.CFrame.Position).Magnitude
        if d < bestDist then bestDist = d; nearest = name end
    end
    return nearest
end

local function GetIslandPos(name)
    local data = IslandMap[name]
    return data and data.CFrame.Position or Vector3.new(0, 27, 0)
end

local function TeleportIsland(islandName)
    if not Config.Movement.IslandTP then return false end
    local pos = GetIslandPos(islandName)
    local root = GetRoot()
    if not root then return false end
    if (root.Position - pos).Magnitude < 50 then return false end
    TeleportTo(pos)
    return true
end

-- ============================================
-- WEAPON SYSTEM
-- ============================================
local Shared = {
    MobIdx = 1,
    AllMobIdx = 1,
    WeapRotationIdx = 1,
    LastWeapSwitch = 0,
    LastIslandTP = 0,
}

local WeaponCache = { Sword = {}, Melee = {}, Fruit = {}, Gun = {} }

local function SyncInventory()
    if Remotes.ReqInventory then
        Remotes.ReqInventory:FireServer()
        task.wait(1)
    end
end

local function CacheWeapons()
    WeaponCache = { Sword = {}, Melee = {}, Fruit = {}, Gun = {} }
    if Plr.Data and Plr.Data.Inventory then
        for _, item in pairs(Plr.Data.Inventory:GetChildren()) do
            if item:IsA("ModuleScript") then
                local data = require(item)
                local t = data and data.ToolType or "Unknown"
                if WeaponCache[t] then
                    table.insert(WeaponCache[t], item.Name)
                end
            end
        end
    end
    Log("Weapons cached: Sword=" .. #WeaponCache.Sword .. " Melee=" .. #WeaponCache.Melee)
end

local function GetToolType(name)
    for t, names in pairs(WeaponCache) do
        for _, n in pairs(names) do
            if n == name then return t end
        end
    end
    return "Unknown"
end

local function EquipWeapon(name)
    if not name then return end
    local char = GetCharacter()
    if not char then return end
    for _, tool in pairs(char:GetChildren()) do
        if tool:IsA("Tool") and tool.Name == name then
            if Remotes.EquipWeapon then
                Remotes.EquipWeapon:FireServer(name)
            end
            return true
        end
    end
    return false
end

local function SwitchWeapon()
    if not Config.MobFarm.WeaponRotation then return end
    local now = tick()
    if now - Shared.LastWeapSwitch < (Config.MobFarm.SwitchDelay or 4) then return end
    
    local types = Config.MobFarm.WeaponTypes or {"Sword", "Melee"}
    local current = nil
    local char = GetCharacter()
    if char then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then current = tool.Name end
    end
    
    Shared.WeapRotationIdx = Shared.WeapRotationIdx + 1
    if Shared.WeapRotationIdx > #types then Shared.WeapRotationIdx = 1 end
    
    local targetType = types[Shared.WeapRotationIdx]
    local list = WeaponCache[targetType] or {}
    if #list > 0 then
        local idx = math.random(1, #list)
        EquipWeapon(list[idx])
        Shared.LastWeapSwitch = now
        Log("Switched to: " .. targetType .. " - " .. list[idx])
    end
end

-- ============================================
-- MOB TARGETING
-- ============================================
local function GetMobTarget()
    local selected = Config.MobFarm.SelectedMobs or {}
    if #selected == 0 then return nil end
    
    if Shared.MobIdx > #selected then Shared.MobIdx = 1 end
    local targetName = selected[Shared.MobIdx]
    
    local root = GetRoot()
    if not root then return nil end
    
    local bestNPC, bestDist = nil, 300
    for _, npc in pairs(GetNPCs()) do
        if npc.Name:lower():find(targetName:lower()) then
            local r = npc:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (root.Position - r.Position).Magnitude
                if d < bestDist then bestDist = d; bestNPC = npc end
            end
        end
    end
    
    if not bestNPC then
        Shared.MobIdx = Shared.MobIdx + 1
        return nil
    end
    
    return bestNPC, GetNearestIsland(bestNPC:GetPivot().Position)
end

local function GetAllMobTarget()
    local root = GetRoot()
    if not root then return nil end
    
    local bestNPC, bestDist = nil, 300
    for _, npc in pairs(GetNPCs()) do
        local hum = npc:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then
            local r = npc:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (root.Position - r.Position).Magnitude
                if d < bestDist then bestDist = d; bestNPC = npc end
            end
        end
    end
    return bestNPC, bestNPC and GetNearestIsland(bestNPC:GetPivot().Position)
end

-- ============================================
-- BOSS TARGETING
-- ============================================
local function GetBossTarget()
    local selected = Config.BossFarm.SelectedBosses or {}
    local allBosses = Config.BossFarm.AllBosses or false
    local root = GetRoot()
    if not root then return nil end
    
    local bestNPC, bestDist = nil, 300
    for _, npc in pairs(GetNPCs()) do
        local hum = npc:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then
            local isBoss = npc.Name:lower():find("boss") and not npc.Name:lower():find("mini")
            if isBoss then
                if allBosses or (#selected == 0) or table.find(selected, npc.Name) then
                    local r = npc:FindFirstChild("HumanoidRootPart")
                    if r then
                        local d = (root.Position - r.Position).Magnitude
                        if d < bestDist then bestDist = d; bestNPC = npc end
                    end
                end
            end
        end
    end
    return bestNPC, bestNPC and GetNearestIsland(bestNPC:GetPivot().Position)
end

-- ============================================
-- MAIN FARM LOOP
-- ============================================
local function RunFarm()
    local target, island = nil, nil
    local mode = Config.FarmMode or "Mob"
    
    -- Try priority system
    local priorities = Config.Priority or {"Mob"}
    for _, taskType in ipairs(priorities) do
        if taskType == "Mob" and Config.MobFarm.Enabled then
            local t, i = GetMobTarget()
            if t then target, island = t, i; break end
        elseif taskType == "All Mob Farm" and Config.MobFarm.Enabled then
            local t, i = GetAllMobTarget()
            if t then target, island = t, i; break end
        elseif taskType == "Boss" and Config.BossFarm.Enabled then
            local t, i = GetBossTarget()
            if t then target, island = t, i; break end
        end
    end
    
    -- Fallback if no priority target
    if not target then
        target, island = GetMobTarget()
        if not target then
            target, island = GetAllMobTarget()
        end
    end
    
    if not target then
        task.wait(0.5)
        return
    end
    
    local npcRoot = target:FindFirstChild("HumanoidRootPart")
    if not npcRoot then return end
    
    -- Teleport island if needed
    local now = tick()
    if island and Config.Movement.IslandTP and (now - Shared.LastIslandTP) > (Config.Movement.IslandTPCD or 1) then
        if TeleportIsland(island) then
            Shared.LastIslandTP = now
            task.wait(1)
        end
    end
    
    -- Move to target
    local playerRoot = GetRoot()
    if playerRoot then
        local targetPos = npcRoot.Position
        local posType = Config.Movement.PositionType or "Front"
        local dist = Config.Movement.Distance or 10
        
        local finalPos
        if posType == "Above" then
            finalPos = targetPos + Vector3.new(0, dist, 0)
        elseif posType == "Below" then
            finalPos = targetPos + Vector3.new(0, -dist, 0)
        else
            finalPos = targetPos + Vector3.new(0, 0, -dist)
        end
        
        TeleportTo(finalPos)
    end
    
    -- Instakill check (basic)
    if Config.Instakill and Config.Instakill.Enabled then
        local hum = target:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health < hum.MaxHealth * 0.3 then
            -- Already damaged target, teleport on top
            local playerRoot = GetRoot()
            if playerRoot then
                playerRoot.CFrame = CFrame.new(npcRoot.Position + Vector3.new(0, 300, 0))
            end
        end
    end
    
    -- Switch weapon periodically
    SwitchWeapon()
end

-- ============================================
-- AUTO M1
-- ============================================
local function RunAutoM1()
    if not Config.AutoFeatures.M1 then return end
    if IsBusy() then return end
    if Remotes.M1 then
        Remotes.M1:FireServer()
    end
end

-- ============================================
-- AUTO HAKI
-- ============================================
local function RunAutoHaki()
    local haki = Config.AutoFeatures.Haki or {}
    
    if haki.Observation and not CheckObsHaki() then
        if Remotes.ObserHaki then Remotes.ObserHaki:FireServer("Toggle") end
    end
    
    if haki.Armament and not CheckArmHaki() then
        if Remotes.ArmHaki then Remotes.ArmHaki:FireServer("Toggle") end
    end
    
    if haki.Conqueror then
        if Remotes.ConquerorHaki then Remotes.ConquerorHaki:FireServer("Activate") end
    end
end

-- ============================================
-- CONSOLE STATUS LOOP
-- ============================================
local LastLevel = StartStats.Level
task.spawn(function()
    while getgenv().Kaitun_Running do
        task.wait(5)
        
        local currentLevel = Plr.Data.Level.Value
        local currentMoney = Plr.Data.Money.Value
        local currentGems = Plr.Data.Gems.Value
        local sessTime = GetSessionTime()
        
        -- Check level up
        if currentLevel > LastLevel then
            local gained = currentLevel - StartStats.Level
            Log("LEVEL UP! Lvl " .. currentLevel .. " (+" .. gained .. " total)")
            LastLevel = currentLevel
            
            -- Stop condition
            if Config.Misc.StopConditions.Level > 0 and currentLevel >= Config.Misc.StopConditions.Level then
                Log("Reached target level " .. currentLevel .. "! Stopping...")
                getgenv().Kaitun_Running = false
                break
            end
        end
        
        -- Status print
        local mode = Config.FarmMode or "None"
        local target = "None"
        local npc = GetNearestNPC(500)
        if npc then target = npc.Name end
        
        print(string.format("[Status] Mode: %s | Target: %s | Level: %d | Session: %s",
            mode, target, currentLevel, sessTime))
        
        -- Check stop conditions
        if Config.Misc.StopConditions.Money > 0 and currentMoney >= Config.Misc.StopConditions.Money then
            Log("Reached target money! Stopping...")
            getgenv().Kaitun_Running = false
            break
        end
        
        if Config.Misc.StopConditions.Gems > 0 and currentGems >= Config.Misc.StopConditions.Gems then
            Log("Reached target gems! Stopping...")
            getgenv().Kaitun_Running = false
            break
        end
    end
end)

-- ============================================
-- ANTI-AFK
-- ============================================
if Config.Misc.AntiAFK ~= false then
    task.spawn(function()
        local VirtualUser = Services.VirtualUser
        while getgenv().Kaitun_Running do
            task.wait(30)
            local myUser = VirtualUser
            if myUser then
                pcall(function()
                    myUser:CaptureController()
                    myUser:ClickButton2(Vector2.new())
                end)
            end
        end
    end)
end

-- ============================================
-- MAIN LOOPS
-- ============================================
local MainLoop = nil
local M1Loop = nil
local HakiLoop = nil

function StartLoops()
    Log("Starting Kaitun Script...")
    Log("Mode: " .. (Config.FarmMode or "Mob"))
    Log("Priority: " .. table.concat(Config.Priority or {}, ", "))
    
    -- Init
    SyncInventory()
    CacheWeapons()
    task.wait(2)
    
    -- Main farm loop
    MainLoop = task.spawn(function()
        while getgenv().Kaitun_Running do
            pcall(RunFarm)
            task.wait(0.1)
        end
    end)
    
    -- Auto M1
    if Config.AutoFeatures.M1 then
        M1Loop = task.spawn(function()
            while getgenv().Kaitun_Running do
                pcall(RunAutoM1)
                task.wait(Config.AutoFeatures.M1Speed or 0.35)
            end
        end)
    end
    
    -- Auto Haki
    local haki = Config.AutoFeatures.Haki or {}
    if haki.Observation or haki.Armament or haki.Conqueror then
        HakiLoop = task.spawn(function()
            while getgenv().Kaitun_Running do
                pcall(RunAutoHaki)
                task.wait(0.5)
            end
        end)
    end
    
    Log("All loops started successfully!")
end

function StopLoops()
    Log("Stopping Kaitun Script...")
    getgenv().Kaitun_Running = false
end

-- ============================================
-- START
-- ============================================
Log("========================================")
Log("Kaitun Script Loaded")
Log("Script: " .. (Config.ScriptName or "NatiCheat") .. " v" .. (Config.Version or "1.0"))
Log("Level: " .. StartStats.Level .. " | Money: " .. StartStats.Money .. " | Gems: " .. StartStats.Gems)
Log("========================================")
Log("Starting in 2 seconds...")

task.wait(2)

getgenv().Kaitun_Running = true
StartLoops()
