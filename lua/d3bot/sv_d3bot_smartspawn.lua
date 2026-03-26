-- ====================================================================
-- D3BOT SMART SPAWN SYSTEM
-- Глобальна система розумного вибору класів для всіх типів зомбі
-- ====================================================================

D3bot.ZS = D3bot.ZS or {}

-- Пріоритети для пробиття барикад (Танки)
D3bot.ZS.BarricadePriority = {
    ["Zombie Gore Blaster"] = 100,
    ["Noxious Ghoul"] = 85,
    ["Lacerator Charging"] = 80,
    ["Elder Ghoul"] = 75,
    ["Wild Poison Zombie"] = 70,
    ["Super Zombie"] = 68,
    ["Poison Zombie"] = 65,
    ["Wraith"] = 60,
    ["Zombie"] = 55,
    ["Skeletal Shambler"] = 52,
    ["Frigid Revenant"] = 50,
    ["Vile Bloated Zombie"] = 48,
    ["Bloated Zombie"] = 45,
    ["Tormented Wraith"] = 43,
    ["Shadow Walker"] = 40,
    ["Skeletal Walker"] = 38,
    ["Ghoul"] = 35,
    ["Classic Zombie"] = 33,
    ["Fresh Dead"] = 30,
    ["Agile Dead"] = 28,
    ["Fast Zombie"] = 20,
    ["Lacerator"] = 18,
    ["Fast Zombie Slingshot"] = 17,
    ["Chem Zombie"] = 15,
    ["Chem Burster"] = 14,
    ["Shadow Lurker"] = 12,
    ["Skeletal Lurker"] = 11,
    ["Eradicator"] = 10,
    ["Poison Headcrab"] = 0,
    ["Barbed Headcrab"] = 0
}

-- Пріоритети для швидкого переслідування
D3bot.ZS.FastAttackerPriority = {
    ["Fast Zombie"] = 100,
    ["Lacerator"] = 98,
    ["Lacerator Charging"] = 95,
    ["Fast Zombie Slingshot"] = 93,
    ["Wraith"] = 90,
    ["Tormented Wraith"] = 88,
    ["Frigid Revenant"] = 70,
    ["Fresh Dead"] = 65,
    ["Agile Dead"] = 63,
    ["Ghoul"] = 60,
    ["Elder Ghoul"] = 58,
    ["Noxious Ghoul"] = 55,
    ["Zombie"] = 40,
    ["Classic Zombie"] = 38,
    ["Shadow Walker"] = 35,
    ["Skeletal Walker"] = 33,
    ["Shadow Lurker"] = 30,
    ["Skeletal Lurker"] = 28,
    ["Bloated Zombie"] = 20,
    ["Vile Bloated Zombie"] = 18,
    ["Poison Zombie"] = 15,
    ["Wild Poison Zombie"] = 13,
    ["Super Zombie"] = 10,
    ["Zombie Gore Blaster"] = 8,
    ["Poison Headcrab"] = 0,
    ["Barbed Headcrab"] = 0
}

-- Глобальний кеш для класів (оновлюється раз на хвилю)
local CachedWave = -1
local CachedFastClasses = {}
local CachedTankClasses = {}
local CachedFastTotalWeight = 0
local CachedTankTotalWeight = 0

function D3bot.ZS.UpdateClassCache()
    local currentWave = GAMEMODE and GAMEMODE:GetWave() or 1
    if CachedWave == currentWave and #CachedFastClasses > 0 then return end

    CachedWave = currentWave
    CachedFastClasses = {}
    CachedTankClasses = {}
    CachedFastTotalWeight = 0
    CachedTankTotalWeight = 0

    local unlockedClasses = D3bot.ZS.GetUnlockedZombieClasses and D3bot.ZS.GetUnlockedZombieClasses() or GAMEMODE.ZombieClasses

    for _, zombieClass in ipairs(unlockedClasses) do
        if not zombieClass.Hidden then
            local fastPri = D3bot.ZS.FastAttackerPriority[zombieClass.Name] or 20
            if fastPri > 0 then
                table.insert(CachedFastClasses, {index = zombieClass.Index, name = zombieClass.Name, priority = fastPri})
                CachedFastTotalWeight = CachedFastTotalWeight + fastPri
            end

            local tankPri = D3bot.ZS.BarricadePriority[zombieClass.Name] or 20
            if tankPri > 0 then
                table.insert(CachedTankClasses, {index = zombieClass.Index, name = zombieClass.Name, priority = tankPri})
                CachedTankTotalWeight = CachedTankTotalWeight + tankPri
            end
        end
    end

    table.sort(CachedFastClasses, function(a, b) return a.priority > b.priority end)
    table.sort(CachedTankClasses, function(a, b) return a.priority > b.priority end)
end

function D3bot.ZS.GetSmartClassIndex(bot, prioritizeSpeed)
    D3bot.ZS.UpdateClassCache() 

    local cache = prioritizeSpeed and CachedFastClasses or CachedTankClasses
    local totalWeight = prioritizeSpeed and CachedFastTotalWeight or CachedTankTotalWeight

    if #cache == 0 then
        return GAMEMODE.DefaultZombieClass or 1
    end

    local roll = math.random() * totalWeight
    local cumulative = 0

    for _, entry in ipairs(cache) do
        cumulative = cumulative + entry.priority
        if roll <= cumulative then
            return entry.index
        end
    end

    return cache[1].index
end

function D3bot.ZS.AreHumansUnreachable(bot)
    local mem = bot.D3bot_Mem
    if not mem then return false end
    
    local target = mem.TgtOrNil
    if IsValid(target) and target:IsPlayer() then
        local dist = bot:GetPos():DistToSqr(target:GetPos())
        if dist > 2250000 then -- 1500 * 1500
            return true
        end
    end
    return false
end