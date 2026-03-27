-- ====================================================================
-- D3BOT SMART SPAWN SYSTEM
-- Глобальна система розумного вибору класів для всіх типів зомбі
-- ====================================================================

D3bot.ZS = D3bot.ZS or {}
D3bot.ZS.BotStats = D3bot.ZS.BotStats or {}

-- Прапорець для увімкнення/вимкнення дебагу у консолі
D3bot.ZS.DebugSmartSpawn = true

-- Локальна функція для виводу логів
local function DebugPrint(...)
    if not D3bot.ZS.DebugSmartSpawn then return end
    
    local args = {...}
    local outputString = ""
    
    for i = 1, #args do
        outputString = outputString .. tostring(args[i])
    end
    
    MsgC(Color(255, 150, 0), "[D3bot SmartSpawn] ", Color(255, 255, 255), outputString, "\n")
end

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
    ["Vile Bloated Zombie"] = 48,
    ["Bloated Zombie"] = 45,
    ["Tormented Wraith"] = 43,
    ["Ghoul"] = 35,
    ["Classic Zombie"] = 33,
    ["Fresh Dead"] = 30,
    ["Agile Dead"] = 28,
    ["Fast Zombie"] = 20,
    ["Lacerator"] = 18,
    ["Fast Zombie Slingshot"] = 17,
    ["Chem Zombie"] = 15,
    ["Chem Burster"] = 14,
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
    ["Fresh Dead"] = 65,
    ["Agile Dead"] = 63,
    ["Ghoul"] = 60,
    ["Elder Ghoul"] = 58,
    ["Noxious Ghoul"] = 55,
    ["Zombie"] = 40,
    ["Classic Zombie"] = 38,
    ["Bloated Zombie"] = 20,
    ["Vile Bloated Zombie"] = 18,
    ["Poison Zombie"] = 15,
    ["Wild Poison Zombie"] = 13,
    ["Super Zombie"] = 10,
    ["Zombie Gore Blaster"] = 8,
    ["Poison Headcrab"] = 0,
    ["Barbed Headcrab"] = 0
}

D3bot.ZS.BulletResistPriority = {
    ["Skeletal Shambler"] = 100,
    ["Skeletal Walker"] = 90,
    ["Skeletal Lurker"] = 50
    -- Додати інші варіації (наприклад, половинки)
}

D3bot.ZS.MeleeResistPriority = {
    ["Shadow Walker"] = 100,
    ["Frigid Revenant"] = 90,
    ["Shadow Lurker"] = 50
    -- Додати інші варіації
}

-- Пріоритети для подолання вертикальних перешкод (Стрибуни/Лази)
D3bot.ZS.LeaperPriority = {
    ["Fast Zombie"] = 100,
    ["Lacerator"] = 90,
    ["Lacerator Charging"] = 85,
    ["Fast Zombie Slingshot"] = 80,
    ["Agile Dead"] = 70,
    ["Fresh Dead"] = 60
}

local function IsValidBarricade(ent)
    if not IsValid(ent) then return false end
    
    local entClass = ent:GetClass()

    print(entClass)
    
    if entClass == "prop_physics" or entClass == "prop_physics_multiplayer" then
        numNailsCount = ent:GetNumNails()
        print(numNailsCount)
        if numNailsCount > 0 then
            print("baricada")
            return true
        end
        local owner = ent:GetOwner()
        if IsValid(owner) and owner:IsPlayer() then
            print("ne baricada")
            return true
        end
    end
    
    return false
end

-- Хук для відстеження початку переслідування
function D3bot.ZS.OnTargetAcquired(bot, target)
    local stats = D3bot.ZS.BotStats[bot:EntIndex()] or {}
    stats.ChaseStartTime = CurTime()
    stats.CurrentTarget = target
    D3bot.ZS.BotStats[bot:EntIndex()] = stats
    
    if D3bot.ZS.DebugSmartSpawn then
        MsgC(Color(255, 150, 0), "[D3bot SmartSpawn] ", Color(255, 255, 255), "Bot ", bot:EntIndex(), " started chasing ", target:GetName(), "\n")
    end
end

function D3bot.ZS.CalculateSpawnContext(bot)
    local stats = D3bot.ZS.BotStats[bot:EntIndex()] or {}
    local fastScore = 1.0
    local tankScore = 1.0
    local meleeResScore = 0.0
    local bulletResScore = 0.0
    local leaperScore = 0.0
    
    local lastPos = stats.LastDeathPos or bot:GetPos()
    
    -- 1. Тривале переслідування
    if stats.ChaseDuration and stats.ChaseDuration > 15 then
        fastScore = fastScore + 0.5
    end
    
    -- 2. Велика дистанція смерті
    if stats.DeathDistance and stats.DeathDistance > 800 then
        fastScore = fastScore + 0.5
    end
    
    -- 8. Дельта висоти
    if stats.ZDiscrepancy and stats.ZDiscrepancy > 150 then
        leaperScore = 1.0 + (stats.ZDiscrepancy / 100) 
        tankScore = tankScore * 0.2
    end
    
    -- 4 & 5. Аналіз скупчення людей та барикад
    local humansNearby = 0
    local propsNearby = 0
    
    
    for _, ent in ipairs(ents.FindInSphere(lastPos, 500)) do
        if ent:IsPlayer() and ent:Team() == TEAM_HUMAN and ent:Alive() then
            humansNearby = humansNearby + 1
        elseif IsValidBarricade(ent) then
            propsNearby = propsNearby + 1
        end
    end
    
    print(humansNearby)
    print(propsNearby)

    if humansNearby >= 1 and propsNearby >= 2 then
        tankScore = tankScore + 1.0
    elseif humansNearby == 0 then
        fastScore = fastScore + 0.6
    end
    
    -- 6. Активація резистів
    if stats.KilledByMeleeCount and stats.KilledByMeleeCount >= 2 then
        meleeResScore = 1.0 + ((stats.KilledByMeleeCount - 2) * 1.5)
    end
    
    if stats.KilledByBulletCount and stats.KilledByBulletCount >= 3 then
        bulletResScore = 1.0 + ((stats.KilledByBulletCount - 3) * 0.8)
    end
    
    DebugPrint("Context for bot ", bot:EntIndex(), ": Fast=", fastScore, " Tank=", tankScore, " MeleeRes=", meleeResScore, " BulletRes=", bulletResScore, " Leaper=", leaperScore)
    return fastScore, tankScore, meleeResScore, bulletResScore, leaperScore
end

-- Глобальний кеш для класів
local CachedWave = -1
local CachedAvailableClasses = {}

function D3bot.ZS.UpdateClassCache()
    local currentWave = GAMEMODE and GAMEMODE:GetWave() or 1
    if CachedWave == currentWave and #CachedAvailableClasses > 0 then return end

    CachedWave = currentWave
    CachedAvailableClasses = {}

    local unlockedClasses = D3bot.ZS.GetUnlockedZombieClasses and D3bot.ZS.GetUnlockedZombieClasses() or GAMEMODE.ZombieClasses

    for _, zombieClass in ipairs(unlockedClasses) do
        if not zombieClass.Hidden then
            table.insert(CachedAvailableClasses, {
                index = zombieClass.Index,
                name = zombieClass.Name,
                fastPri = D3bot.ZS.FastAttackerPriority[zombieClass.Name] or 0,
                tankPri = D3bot.ZS.BarricadePriority[zombieClass.Name] or 0,
                meleeResPri = D3bot.ZS.MeleeResistPriority[zombieClass.Name] or 0,
                bulletResPri = D3bot.ZS.BulletResistPriority[zombieClass.Name] or 0,
                leaperPri = D3bot.ZS.LeaperPriority[zombieClass.Name] or 0
            })
        end
    end
    DebugPrint("Class cache updated for wave ", currentWave, ". Total active classes: ", #CachedAvailableClasses)
end

function D3bot.ZS.GetSmartClassIndex(bot)
    D3bot.ZS.UpdateClassCache() 

    local fastScore, tankScore, meleeResScore, bulletResScore, leaperScore = D3bot.ZS.CalculateSpawnContext(bot)
    
    local combinedPool = {}
    local totalDynamicWeight = 0
    
    for _, entry in ipairs(CachedAvailableClasses) do
        local dynamicPriority = (entry.fastPri * fastScore) + 
                                (entry.tankPri * tankScore) + 
                                (entry.meleeResPri * meleeResScore) + 
                                (entry.bulletResPri * bulletResScore) +
                                (entry.leaperPri * leaperScore)
                                
        if dynamicPriority > 0 then
            table.insert(combinedPool, {index = entry.index, name = entry.name, priority = dynamicPriority})
            totalDynamicWeight = totalDynamicWeight + dynamicPriority
        end
    end
    
    if #combinedPool == 0 then
        DebugPrint("Warning: Combined pool is empty for bot ", bot:EntIndex(), ". Returning default class.")
        return GAMEMODE.DefaultZombieClass or 1
    end
    
    local roll = math.random() * totalDynamicWeight
    local cumulative = 0

    for _, entry in ipairs(combinedPool) do
        cumulative = cumulative + entry.priority
        if roll <= cumulative then
            DebugPrint("Bot ", bot:EntIndex(), " spawned as [", entry.name, "] (Index: ", entry.index, ") | Target Weight: ", math.Round(entry.priority, 2), " / ", math.Round(totalDynamicWeight, 2))
            return entry.index
        end
    end

    return combinedPool[1].index
end

-- Хук смерті бота для збору аналітики
hook.Add("PlayerDeath", "D3bot_SmartSpawn_DeathAnalytics", function(victim, inflictor, attacker)
    -- Використовуємо нативну функцію рушія для визначення бота
    if not victim:IsBot() then return end 
    
    local stats = D3bot.ZS.BotStats[victim:EntIndex()] or {}
    local victimPos = victim:GetPos()
    stats.LastDeathPos = victimPos
    
    if stats.ChaseStartTime then
        stats.ChaseDuration = CurTime() - stats.ChaseStartTime
        stats.ChaseStartTime = nil 
    else
        stats.ChaseDuration = 0
    end
    
    if IsValid(attacker) and attacker:IsPlayer() then
        local attackerPos = attacker:GetPos()
        stats.DeathDistance = victimPos:Distance(attackerPos)
        stats.ZDiscrepancy = attackerPos.z - victimPos.z
    else
        stats.DeathDistance = 0
        stats.ZDiscrepancy = 0
    end
    
    -- Коригування інфліктора (отримання фактичної зброї)
    local weapon = inflictor
    if IsValid(attacker) and attacker:IsPlayer() and inflictor == attacker then
        weapon = attacker:GetActiveWeapon()
    end
    
    -- Розширений аналіз зброї
    if IsValid(weapon) and weapon:IsWeapon() then
        local weaponClass = weapon:GetClass()
        -- Багато зброї ближнього бою в ZS не мають прапорця IsMelee, тому шукаємо по імені класу
        local isMelee = weapon.IsMelee or string.find(weaponClass, "melee") or weaponClass == "weapon_crowbar"
        
        if isMelee then
            stats.KilledByMeleeCount = (stats.KilledByMeleeCount or 0) + 1
            stats.KilledByBulletCount = 0 
        else
            stats.KilledByBulletCount = (stats.KilledByBulletCount or 0) + 1
            stats.KilledByMeleeCount = 0 
        end
    end
    
    D3bot.ZS.BotStats[victim:EntIndex()] = stats
    
    DebugPrint("DEATH RECORDED | Bot: ", victim:EntIndex(), 
               " | Dist: ", math.Round(stats.DeathDistance, 1), 
               " | Z-Delta: ", math.Round(stats.ZDiscrepancy, 1), 
               " | MeleeStreak: ", stats.KilledByMeleeCount or 0, 
               " | BulletStreak: ", stats.KilledByBulletCount or 0)
end)

-- Глобальний монітор зміни цілей
local nextThink = 0
hook.Add("Think", "D3bot_SmartSpawn_TargetTracker", function()
    -- Оптимізація: перевірка раз на 0.5 секунди, цього достатньо для ШІ
    if CurTime() < nextThink then return end
    nextThink = CurTime() + 0.5

    -- D3bot у ZS використовують fake clients (player)
    for _, bot in ipairs(player.GetAll()) do
        if bot:IsBot() and bot.IsD3bot and bot:IsD3bot() and bot:Alive() then
            local mem = bot.D3bot_Mem
            if mem then
                local currentTarget = mem.TgtOrNil
                local stats = D3bot.ZS.BotStats[bot:EntIndex()] or {}
                local previousTarget = stats.CurrentTarget
                
                -- Виявлення переходу стану: з'явилася нова валідна ціль (гравець)
                if IsValid(currentTarget) and currentTarget:IsPlayer() and currentTarget:Alive() then
                    if previousTarget ~= currentTarget then
                        -- Ціль змінилася або з'явилася вперше
                        D3bot.ZS.OnTargetAcquired(bot, currentTarget)
                    end
                else
                    -- Ціль втрачена або мертва, не скидаємо ChaseStartTime, 
                    -- але очищаємо CurrentTarget, щоб зафіксувати нову при появі
                    if previousTarget ~= nil then
                        stats.CurrentTarget = nil
                        D3bot.ZS.BotStats[bot:EntIndex()] = stats
                    end
                end
            end
        end
    end
end)