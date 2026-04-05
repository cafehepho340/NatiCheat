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

-- Fallback: đọc từ global getgenv().KAITUN_CFG
if not Config and type(getgenv().KAITUN_CFG) == "table" then
    Config = getgenv().KAITUN_CFG
    print("[Kaitun] Da lay config tu getgenv().KAITUN_CFG (loader global)")
end

if not Config then
    warn("[Kaitun] Failed to load config! Using default settings.")
    Config = {
        FarmMode = "Mob",
        MobFarm = { Enabled = true, SelectedMobs = {} },
        BossFarm = { Enabled = false },
        Priority = {"Mob", "Level Farm", "All Mob Farm", "Boss"},
        AutoFeatures = { M1 = true, M1Speed = 0.35, Haki = { Observation = false, Armament = false, Conqueror = false } },
        Movement = { Type = "Tween", Speed = 160, PositionType = "Behind", Distance = 6, IslandTP = true, IslandTPCD = 0.67, TargetTPCD = 0 },
        LevelFarm = { Enabled = true, AutoQuest = true, UseForTargeting = false },
        LevelRules = { Enabled = true, MobSelectFarmLevelMax = 50, MeleeOnlyLevelMax = 200 },
        Misc = { AntiAFK = true, StopConditions = { Level = 0, Money = 0, Gems = 0 } }
    }
end

local SnapshotDefaultWeaponTypes = {}

do
    Config.Misc = Config.Misc or {}
    Config.Misc.StopConditions = Config.Misc.StopConditions or { Level = 0, Money = 0, Gems = 0 }
    Config.LevelFarm = Config.LevelFarm or { Enabled = false, AutoQuest = false, UseForTargeting = false }
    Config.LevelRules = Config.LevelRules or { Enabled = false }
    Config.Instakill = Config.Instakill or { Enabled = false, Type = "V2", HPPercent = 90, MinMaxHP = 100000 }
    Config.MobFarm = Config.MobFarm or {}
    for _, t in ipairs(Config.MobFarm.WeaponTypes or { "Sword", "Melee" }) do
        table.insert(SnapshotDefaultWeaponTypes, t)
    end
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
local PATH = {
    Mobs = workspace:WaitForChild("NPCs", 90),
}
if not PATH.Mobs then
    PATH.Mobs = workspace
end

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
    local npcFolder = PATH.Mobs
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
    SettingsToggle = GetRemote(RS, "RemoteEvents.SettingsToggle"),
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
-- ISLAND / PORTAL (crystal map giống script gốc)
-- ============================================
local IslandCrystals = {
    ["Starter"] = workspace:FindFirstChild("StarterIsland") and workspace.StarterIsland:FindFirstChild("SpawnPointCrystal_Starter"),
    ["Jungle"] = workspace:FindFirstChild("JungleIsland") and workspace.JungleIsland:FindFirstChild("SpawnPointCrystal_Jungle"),
    ["Desert"] = workspace:FindFirstChild("DesertIsland") and workspace.DesertIsland:FindFirstChild("SpawnPointCrystal_Desert"),
    ["Snow"] = workspace:FindFirstChild("SnowIsland") and workspace.SnowIsland:FindFirstChild("SpawnPointCrystal_Snow"),
    ["Sailor"] = workspace:FindFirstChild("SailorIsland") and workspace.SailorIsland:FindFirstChild("SpawnPointCrystal_Sailor"),
    ["Shibuya"] = workspace:FindFirstChild("ShibuyaStation") and workspace.ShibuyaStation:FindFirstChild("SpawnPointCrystal_Shibuya"),
    ["HuecoMundo"] = workspace:FindFirstChild("HuecoMundo") and workspace.HuecoMundo:FindFirstChild("SpawnPointCrystal_HuecoMundo"),
    ["Boss"] = workspace:FindFirstChild("BossIsland") and workspace.BossIsland:FindFirstChild("SpawnPointCrystal_Boss"),
    ["Dungeon"] = workspace:FindFirstChild("Main Temple") and workspace["Main Temple"]:FindFirstChild("SpawnPointCrystal_Dungeon"),
    ["Shinjuku"] = workspace:FindFirstChild("ShinjukuIsland") and workspace.ShinjukuIsland:FindFirstChild("SpawnPointCrystal_Shinjuku"),
    ["Valentine"] = workspace:FindFirstChild("ValentineIsland") and workspace.ValentineIsland:FindFirstChild("SpawnPointCrystal_Valentine"),
    ["Slime"] = workspace:FindFirstChild("SlimeIsland") and workspace.SlimeIsland:FindFirstChild("SpawnPointCrystal_Slime"),
    ["Academy"] = workspace:FindFirstChild("AcademyIsland") and workspace.AcademyIsland:FindFirstChild("SpawnPointCrystal_Academy"),
    ["Judgement"] = workspace:FindFirstChild("JudgementIsland") and workspace.JudgementIsland:FindFirstChild("SpawnPointCrystal_Judgement"),
    ["SoulDominion"] = workspace:FindFirstChild("SoulDominionIsland") and workspace.SoulDominionIsland:FindFirstChild("SpawnPointCrystal_SoulDominion"),
    ["NinjaIsland"] = workspace:FindFirstChild("NinjaIsland") and workspace.NinjaIsland:FindFirstChild("SpawnPointCrystal_Ninja"),
    ["LawlessIsland"] = workspace:FindFirstChild("LawlessIsland") and workspace.LawlessIsland:FindFirstChild("SpawnPointCrystal_Lawless"),
    ["TowerIsland"] = workspace:FindFirstChild("TowerIsland") and workspace.TowerIsland:FindFirstChild("SpawnPointCrystal_Tower"),
}

local SharedBossTIMap = {}

local function GetNearestIsland(targetPos, npcName)
    if npcName and SharedBossTIMap[npcName] then
        return SharedBossTIMap[npcName]
    end
    local nearestIslandName = "Starter"
    local minDistance = math.huge
    for islandName, crystal in pairs(IslandCrystals) do
        if crystal then
            local dist = (targetPos - crystal:GetPivot().Position).Magnitude
            if dist < minDistance then
                minDistance = dist
                nearestIslandName = islandName
            end
        end
    end
    return nearestIslandName
end

local function TeleportIsland(islandName)
    if not Config.Movement.IslandTP then return false end
    if not islandName or islandName == "" or islandName == "Unknown" then return false end
    if islandName == Shared.CurrentIsland then return false end
    if Remotes.TP_Portal then
        Remotes.TP_Portal:FireServer(islandName)
        task.wait(tonumber(Config.Movement.IslandTPCD) or 0.67)
        Shared.CurrentIsland = islandName
        return true
    end
    return false
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
    LastTargetTP = 0,
    QuestNPC = "",
    CurrentIsland = "",
    Target = nil,
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
-- LEVEL RULES + QUEST (auto nhận quest)
-- ============================================
local function ApplyLevelRules()
    local rules = Config.LevelRules
    if not rules or rules.Enabled == false then return end
    local lv = Plr.Data.Level.Value

    local meleeMax = rules.MeleeOnlyLevelMax or 200
    if lv <= meleeMax then
        Config.MobFarm.WeaponTypes = { "Melee" }
    else
        Config.MobFarm.WeaponTypes = rules.WeaponTypesAfterMelee or SnapshotDefaultWeaponTypes
    end

    local mobMax = rules.MobSelectFarmLevelMax or 50
    if lv <= mobMax then
        Config.MobFarm.Enabled = true
        Config.LevelFarm.AutoQuest = Config.LevelFarm.AutoQuest ~= false
        Config.LevelFarm.UseForTargeting = false
    else
        if rules.DisableMobFarmAfterMobCap ~= false then
            Config.MobFarm.Enabled = false
        end
        Config.LevelFarm.AutoQuest = false
        if rules.EnableLevelFarmAfterMobCap ~= false then
            Config.LevelFarm.Enabled = true
            Config.LevelFarm.UseForTargeting = true
        end
    end
end

local function IsValidTargetFarm(npc)
    if not npc or not npc.Parent then return false end
    local hum = npc:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    local ik = Config.Instakill and Config.Instakill.Enabled
    local minHP = tonumber(Config.Instakill and Config.Instakill.MinMaxHP) or 0
    if ik and hum.MaxHealth >= minHP then
        return hum.Health > 0 or npc == Shared.Target
    end
    return hum.Health > 0
end

local function IsSmartMatch(npcName, targetMobType)
    local n = npcName:gsub("%d+$", ""):lower()
    local t = (targetMobType or ""):lower()
    if n == t then return true end
    if t ~= "" and t:find(n, 1, true) == 1 then return true end
    if n ~= "" and n:find(t, 1, true) == 1 then return true end
    return false
end

local function GetBestMobCluster(mobNamesDictionary)
    if type(mobNamesDictionary) ~= "table" then return nil end
    local allMobs = {}
    local clusterRadius = 35
    for _, npc in pairs(PATH.Mobs:GetChildren()) do
        if npc:IsA("Model") and npc:FindFirstChildOfClass("Humanoid") then
            local cleanName = npc.Name:gsub("%d+$", "")
            if mobNamesDictionary[cleanName] and IsValidTargetFarm(npc) then
                table.insert(allMobs, npc)
            end
        end
    end
    if #allMobs == 0 then return nil end
    local bestMob = allMobs[1]
    local maxNearby = 0
    for _, mobA in ipairs(allMobs) do
        local nearbyCount = 0
        local posA = mobA:GetPivot().Position
        for _, mobB in ipairs(allMobs) do
            if (posA - mobB:GetPivot().Position).Magnitude <= clusterRadius then
                nearbyCount = nearbyCount + 1
            end
        end
        if nearbyCount > maxNearby then
            maxNearby = nearbyCount
            bestMob = mobA
        end
    end
    return bestMob
end

local function EnsureQuestSettings()
    local ok, settings = pcall(function()
        return PGui.SettingsUI.MainFrame.Frame.Content.SettingsTabFrame
    end)
    if not ok or not settings then return end
    local tog1 = settings:FindFirstChild("Toggle_EnableQuestRepeat", true)
    if tog1 and tog1.SettingsHolder.Off.Visible and Remotes.SettingsToggle then
        Remotes.SettingsToggle:FireServer("EnableQuestRepeat", true)
        task.wait(0.3)
    end
    local tog2 = settings:FindFirstChild("Toggle_AutoQuestRepeat", true)
    if tog2 and tog2.SettingsHolder.Off.Visible and Remotes.SettingsToggle then
        Remotes.SettingsToggle:FireServer("AutoQuestRepeat", true)
    end
end

local function GetBestQuestNPC()
    local QuestModule = Modules.Quests
    if type(QuestModule.RepeatableQuests) ~= "table" then return "QuestNPC1" end
    local playerLevel = Plr.Data.Level.Value
    local bestNPC = "QuestNPC1"
    local highestLevel = -1
    for npcId, questData in pairs(QuestModule.RepeatableQuests) do
        local reqLevel = questData.recommendedLevel or 0
        if playerLevel >= reqLevel and reqLevel > highestLevel then
            highestLevel = reqLevel
            bestNPC = npcId
        end
    end
    return bestNPC
end

local function UpdateQuestKaitun()
    if not Config.LevelFarm.Enabled or not Config.LevelFarm.AutoQuest then return end
    if not Remotes.QuestAccept or not Remotes.QuestAbandon then return end
    local questUIHolder = PGui:FindFirstChild("QuestUI")
    if not questUIHolder then return end
    local questUI = questUIHolder:FindFirstChild("Quest")
    if not questUI then return end

    EnsureQuestSettings()
    local targetNPC = GetBestQuestNPC()

    if Shared.QuestNPC ~= targetNPC or not questUI.Visible then
        Remotes.QuestAbandon:FireServer("repeatable")
        local abandonTimeout = 0
        while questUI.Visible and abandonTimeout < 15 do
            task.wait(0.2)
            abandonTimeout = abandonTimeout + 1
        end
        Remotes.QuestAccept:FireServer(targetNPC)
        local acceptTimeout = 0
        while not questUI.Visible and acceptTimeout < 20 do
            task.wait(0.2)
            acceptTimeout = acceptTimeout + 1
            if acceptTimeout % 5 == 0 then
                Remotes.QuestAccept:FireServer(targetNPC)
            end
        end
        if questUI.Visible then
            Shared.QuestNPC = targetNPC
        end
    end
end

local function GetLevelFarmTarget()
    if not Config.LevelFarm.Enabled or not Config.LevelFarm.UseForTargeting then return nil end
    pcall(UpdateQuestKaitun)

    local questValid = false
    local targetMobType = nil
    local questUIHolder = PGui:FindFirstChild("QuestUI")
    local questFrame = questUIHolder and questUIHolder:FindFirstChild("Quest")
    if questFrame and questFrame.Visible then
        local qData = Modules.Quests.RepeatableQuests and Modules.Quests.RepeatableQuests[Shared.QuestNPC]
        if qData and qData.requirements and qData.requirements[1] then
            targetMobType = qData.requirements[1].npcType
            questValid = true
        end
    end

    local matches = {}
    for _, npc in pairs(PATH.Mobs:GetChildren()) do
        if npc:IsA("Model") and npc:FindFirstChildOfClass("Humanoid") and IsValidTargetFarm(npc) then
            local cleanName = npc.Name:gsub("%d+$", "")
            local shouldInclude = false
            if questValid and targetMobType then
                if IsSmartMatch(npc.Name, targetMobType) then shouldInclude = true end
            else
                local name = npc.Name:lower()
                if not name:find("boss") and not name:find("merchant") then
                    shouldInclude = true
                end
            end
            if shouldInclude then matches[cleanName] = true end
        end
    end

    local bestMob = GetBestMobCluster(matches)
    if bestMob then
        local clean = bestMob.Name:gsub("%d+$", "")
        return bestMob, GetNearestIsland(bestMob:GetPivot().Position, clean)
    end
    return nil
end

local function MoveToFarmPosition(target)
    local root = GetRoot()
    if not root or not target then return end
    local npcRoot = target:FindFirstChild("HumanoidRootPart")
    if not npcRoot then return end

    local now = tick()
    local tCD = tonumber(Config.Movement.TargetTPCD) or 0
    if tCD > 0 and (now - Shared.LastTargetTP) < tCD then return end
    Shared.LastTargetTP = now

    local targetPivot = target:GetPivot()
    local targetPos = targetPivot.Position
    local distVal = tonumber(Config.Movement.Distance) or 6
    local posType = Config.Movement.PositionType or "Behind"

    local ik = target:FindFirstChild("IK_Active")
    if ik and Config.Instakill and Config.Instakill.Enabled and (Config.Instakill.Type or "V2") == "V2" then
        local startTime = ik:GetAttribute("TriggerTime") or 0
        if tick() - startTime >= 3 then
            root.CFrame = CFrame.new(targetPos + Vector3.new(0, 300, 0))
            root.AssemblyLinearVelocity = Vector3.zero
            return
        end
    end

    local finalPos
    if posType == "Above" then
        finalPos = targetPos + Vector3.new(0, distVal, 0)
    elseif posType == "Below" then
        finalPos = targetPos + Vector3.new(0, -distVal, 0)
    else
        finalPos = (targetPivot * CFrame.new(0, 0, distVal)).Position
    end

    local finalDest = CFrame.lookAt(finalPos, targetPos)
    local moveType = Config.Movement.Type or "Tween"
    if moveType == "Teleport" then
        root.CFrame = finalDest
    else
        local dist = (root.Position - finalPos).Magnitude
        local speed = tonumber(Config.Movement.Speed) or 160
        TweenService:Create(root, TweenInfo.new(dist / math.max(speed, 1), Enum.EasingStyle.Linear), { CFrame = finalDest }):Play()
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
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

    local bestNPC, bestDist = nil, 500
    for _, npc in pairs(PATH.Mobs:GetChildren()) do
        if npc:IsA("Model") and npc.Name:lower():find(targetName:lower()) and IsValidTargetFarm(npc) then
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

    local clean = bestNPC.Name:gsub("%d+$", "")
    return bestNPC, GetNearestIsland(bestNPC:GetPivot().Position, clean)
end

local function GetAllMobTarget()
    local root = GetRoot()
    if not root then return nil end

    local bestNPC, bestDist = nil, 500
    for _, npc in pairs(PATH.Mobs:GetChildren()) do
        local hum = npc:FindFirstChildOfClass("Humanoid")
        if hum and IsValidTargetFarm(npc) then
            local r = npc:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (root.Position - r.Position).Magnitude
                if d < bestDist then bestDist = d; bestNPC = npc end
            end
        end
    end
    if not bestNPC then return nil end
    local clean = bestNPC.Name:gsub("%d+$", "")
    return bestNPC, GetNearestIsland(bestNPC:GetPivot().Position, clean)
end

-- ============================================
-- BOSS TARGETING
-- ============================================
local function GetBossTarget()
    local selected = Config.BossFarm.SelectedBosses or {}
    local allBosses = Config.BossFarm.AllBosses or false
    local root = GetRoot()
    if not root then return nil end

    local bestNPC, bestDist = nil, 500
    for _, npc in pairs(PATH.Mobs:GetChildren()) do
        local hum = npc:FindFirstChildOfClass("Humanoid")
        if hum and IsValidTargetFarm(npc) then
            local isBoss = npc.Name:lower():find("boss") and not npc.Name:lower():find("mini")
            if isBoss then
                local clean = npc.Name:gsub("%d+$", "")
                if allBosses or (#selected == 0) or table.find(selected, clean) or table.find(selected, npc.Name) then
                    local r = npc:FindFirstChild("HumanoidRootPart")
                    if r then
                        local d = (root.Position - r.Position).Magnitude
                        if d < bestDist then bestDist = d; bestNPC = npc end
                    end
                end
            end
        end
    end
    if not bestNPC then return nil end
    local clean = bestNPC.Name:gsub("%d+$", "")
    return bestNPC, GetNearestIsland(bestNPC:GetPivot().Position, clean)
end

-- ============================================
-- MAIN FARM LOOP
-- ============================================
local function RunFarm()
    ApplyLevelRules()
    local target, island = nil, nil
    local priorities = Config.Priority or { "Mob" }

    for _, taskType in ipairs(priorities) do
        if taskType == "Mob" and Config.MobFarm.Enabled then
            local t, i = GetMobTarget()
            if t then target, island = t, i; break end
        elseif taskType == "All Mob Farm" and Config.MobFarm.Enabled then
            local t, i = GetAllMobTarget()
            if t then target, island = t, i; break end
        elseif taskType == "Boss" and Config.BossFarm and Config.BossFarm.Enabled then
            local t, i = GetBossTarget()
            if t then target, island = t, i; break end
        elseif taskType == "Level Farm" then
            local t, i = GetLevelFarmTarget()
            if t then target, island = t, i; break end
        end
    end

    if not target then
        Shared.Target = nil
        task.wait(0.35)
        return
    end

    Shared.Target = target

    local cleanName = target.Name:gsub("%d+$", "")
    if not island then
        island = GetNearestIsland(target:GetPivot().Position, cleanName)
    end

    local now = tick()
    if island and Config.Movement.IslandTP and (now - Shared.LastIslandTP) > (tonumber(Config.Movement.IslandTPCD) or 0.67) then
        if TeleportIsland(island) then
            Shared.LastIslandTP = now
            task.wait(0.5)
        end
    end

    MoveToFarmPosition(target)
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
            local sc = Config.Misc and Config.Misc.StopConditions
            if sc and sc.Level > 0 and currentLevel >= sc.Level then
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
        local sc2 = Config.Misc and Config.Misc.StopConditions
        if sc2 and sc2.Money > 0 and currentMoney >= sc2.Money then
            Log("Reached target money! Stopping...")
            getgenv().Kaitun_Running = false
            break
        end
        
        if sc2 and sc2.Gems > 0 and currentGems >= sc2.Gems then
            Log("Reached target gems! Stopping...")
            getgenv().Kaitun_Running = false
            break
        end
    end
end)

-- ============================================
-- ANTI-AFK
-- ============================================
if (Config.Misc and Config.Misc.AntiAFK) ~= false then
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
                local sp = tonumber(Config.AutoFeatures.M1Speed)
                if sp == nil then sp = 0.35 end
                task.wait(math.max(0.03, sp))
            end
        end)
    end

    task.spawn(function()
        while getgenv().Kaitun_Running do
            task.wait(5)
            pcall(function()
                ApplyLevelRules()
                if Config.LevelFarm.AutoQuest then
                    UpdateQuestKaitun()
                end
            end)
        end
    end)
    
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
