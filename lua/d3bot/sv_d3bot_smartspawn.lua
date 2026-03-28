-- ====================================================================
-- D3BOT SMART SPAWN SYSTEM
-- Глобальна система розумного вибору класів для всіх типів зомбі
-- ====================================================================

D3bot.ZS = D3bot.ZS or {}
D3bot.ZS.BotStats = D3bot.ZS.BotStats or {}
D3bot.ZS.DeathLog = D3bot.ZS.DeathLog or {}

-- Прапорець для увімкнення/вимкнення дебагу у консолі
D3bot.ZS.DebugSmartSpawn = false
D3bot.ZS.DebugSoloScanner = false


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

-- ====================================================================
-- ГЛОБАЛЬНИЙ СКАНЕР СОЛО-ГРАВЦІВ (Асинхронний кеш)
-- ====================================================================
D3bot.ZS.SoloPlayers = {}

timer.Create("D3bot_SmartSpawn_SoloScanner", 1.0, 0, function()
    local startTime = SysTime() -- Початок відліку часу
    local loopIterations = 0    -- Загальна кількість ітерацій циклу
    local distChecks = 0        -- Кількість виконаних математичних розрахунків дистанції

    local humans = team.GetPlayers(TEAM_HUMAN)
    local count = #humans
    local grouped = {}
    
    -- Оптимізований попарний перебір
    for i = 1, count do
        loopIterations = loopIterations + 1
        local ply1 = humans[i]
        
        if not grouped[ply1] and IsValid(ply1) and ply1:Alive() then
            local pos1 = ply1:GetPos()
            
            for j = i + 1, count do
                loopIterations = loopIterations + 1
                local ply2 = humans[j]
                
                if not grouped[ply2] and IsValid(ply2) and ply2:Alive() then
                    distChecks = distChecks + 1
                    
                    if pos1:DistToSqr(ply2:GetPos()) < 640000 then 
                        grouped[ply1] = true
                        grouped[ply2] = true
                    end
                end
            end
        end
    end
    
    -- Формування актуального масиву цілей
    local newSoloList = {}
    for i = 1, count do
        local ply = humans[i]
        if IsValid(ply) and ply:Alive() and not grouped[ply] then
            table.insert(newSoloList, ply)
        end
    end
    
    D3bot.ZS.SoloPlayers = newSoloList
    
    -- Розрахунок часу виконання у мілісекундах
    local executionTimeMs = (SysTime() - startTime) * 1000
    
    if D3bot.ZS.DebugSoloScanner then
        DebugPrint("Scanner Stats | Humans: ", count, 
               " | Iterations: ", loopIterations, 
               " | DistChecks: ", distChecks, 
               " | Solos Found: ", #newSoloList,
               " | Time: ", math.Round(executionTimeMs, 4), "ms")
    end
end)

-- Отримання цілі з глобального кешу за O(1)
local function FindGlobalSoloTarget()
    local soloCount = #D3bot.ZS.SoloPlayers
    if soloCount > 0 then
        return D3bot.ZS.SoloPlayers[math.random(soloCount)]
    end
    
    return nil
end

-- ====================================================================
-- ТАБЛИЦІ ПРІОРИТЕТІВ КЛАСІВ
-- ====================================================================
D3bot.ZS.BarricadePriority = {
    ["Wild Poison Zombie"] = 100,
    ["Poison Zombie"] = 100,
    ["Vile Bloated Zombie"] = 100,
    ["Bloated Zombie"] = 100,
    ["Tormented Wraith"] = 10,
    ["Wraith"] = 10,
    ["Zombie Gore Blaster"] = 50,
    ["Eradicator"] = 100,
    ["Zombie"] = 50,
    ["Frigid Revenant"] = 50,
    ["Frigid Ghoul"] = 25,
    ["Noxious Ghoul"] = 50,
    ["Ghoul"] = 25,
    ["Elder Ghoul"] = 25,
    ["Bloodsucker Headcrab"] = 25,
    ["Fast Headcrab"] = 12,
    ["Headcrab"] = 12,
    ["Poison Headcrab"] = 0,
    ["Barbed Headcrab"] = 0
}

D3bot.ZS.FastAttackerPriority = {
    ["Lacerator"] = 100,
    ["Fast Zombie"] = 100,
    ["Agile Dead"] = 25,
    ["Charger"] = 100,
    ["Tormented Wraith"] = 25,
    ["Wraith"] = 25,
    ["Frigid Revenant"] = 75,
    ["Frigid Ghoul"] = 50,
    ["Noxious Ghoul"] = 75,
    ["Ghoul"] = 50,
    ["Elder Ghoul"] = 50,
    ["Zombie Gore Blaster"] = 10,
    ["Eradicator"] = 20,
    ["Zombie"] = 10,
    ["Bloodsucker Headcrab"] = 50,
    ["Fast Headcrab"] = 25,
    ["Headcrab"] = 25,
    ["Poison Headcrab"] = 0,
    ["Barbed Headcrab"] = 0
}

D3bot.ZS.BulletResistPriority = {
    ["Skeletal Shambler"] = 100,
    ["Skeletal Walker"] = 90,
    ["Skeletal Lurker"] = 45
}

D3bot.ZS.MeleeResistPriority = {
    ["Frigid Revenant"] = 100,
    ["Shadow Walker"] = 90,
    ["Shadow Lurker"] = 45
}

D3bot.ZS.LeaperPriority = {
    ["Fast Zombie"] = 100,
    ["Lacerator"] = 100,
    ["Agile Dead"] = 25,
}

local function IsValidBarricade(ent)
    if not IsValid(ent) then return false end
    
    local entClass = ent:GetClass()
    
    if entClass == "prop_physics" or entClass == "prop_physics_multiplayer" then
        if ent.IsNailed and ent:IsNailed() then return true end
        
        local owner = ent:GetOwner()
        if IsValid(owner) and owner:IsPlayer() then return true end
    end
    
    return false
end

function D3bot.ZS.OnTargetAcquired(bot, target)
    local stats = D3bot.ZS.BotStats[bot:EntIndex()] or {}
    stats.ChaseStartTime = CurTime()
    stats.CurrentTarget = target
    D3bot.ZS.BotStats[bot:EntIndex()] = stats
    
    DebugPrint("Bot ", bot:EntIndex(), " started chasing ", target:GetName())
end

-- ====================================================================
-- АНАЛІЗАТОР КОНТЕКСТУ СПАВНУ
-- ====================================================================
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
        DebugPrint("I chased for too long fast+0.5")
    end
    
    -- 2. Велика дистанція смерті
    if stats.DeathDistance and stats.DeathDistance > 800 then
        fastScore = fastScore + 0.5
        DebugPrint("I was killed from a long distance fast+0.5")
    end
    
    -- 3. Дельта висоти
    if stats.ZDiscrepancy and stats.ZDiscrepancy > 150 then
        leaperScore = 1.0 + (stats.ZDiscrepancy / 100) 
        tankScore = tankScore * 0.2
        DebugPrint("DeltaZ > 150 tank score * 0.2 leaper + 1")
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

    if humansNearby >= 1 and propsNearby >= 2 then
        tankScore = tankScore + 1.0
        DebugPrint("Humans around props are nailed i found barricades tank+1")
    elseif humansNearby == 0 then
        fastScore = fastScore + 0.6
        DebugPrint("Humans around not found no barricades fast + 0.6")
    end

    -- 6. Глобальне полювання на соло-гравців (75% ймовірність ініціалізації)
    stats.HuntTarget = nil
    if math.random() <= 0.75 then
        local huntTarget = FindGlobalSoloTarget()
        if IsValid(huntTarget) then
            fastScore = fastScore + 5.0
            leaperScore = leaperScore + 2.0
            tankScore = tankScore * 0.1
            
            stats.HuntTarget = huntTarget
            DebugPrint("GLOBAL HUNT | Bot ", bot:EntIndex(), " selected isolated target: ", huntTarget:GetName(), ". Fast+++ Tank---")
        end
    end

    -- 7. Виявлення зони знищення (Killzone Density)
    local recentDeathsInArea = 0
    local currentTime = CurTime()
    local deathLogTimeWindow = 20
    local deathLogRadiusSqr = 40000 
    
    for i = #D3bot.ZS.DeathLog, 1, -1 do
        local deathRecord = D3bot.ZS.DeathLog[i]
        
        if currentTime - deathRecord.time > deathLogTimeWindow then
            table.remove(D3bot.ZS.DeathLog, i)
        else
            if deathRecord.pos:DistToSqr(lastPos) <= deathLogRadiusSqr then
                recentDeathsInArea = recentDeathsInArea + 1
            end
        end
    end
    
    if recentDeathsInArea >= 3 then
        tankScore = tankScore + (recentDeathsInArea * 0.5)
        fastScore = fastScore * 0.3 
        DebugPrint("Killzone detected. Deaths in area: ", recentDeathsInArea, " | tank+ fast-")
    end
    
    -- 8. Активація резистів
    if stats.KilledByMeleeCount and stats.KilledByMeleeCount >= 2 then
        meleeResScore = 1.0 + ((stats.KilledByMeleeCount - 2) * 1.5)
        DebugPrint("Humans killed me from melee over 2 times meleeres+")
    end
    
    if stats.KilledByBulletCount and stats.KilledByBulletCount >= 3 then
        bulletResScore = 1.0 + ((stats.KilledByBulletCount - 3) * 0.8)
        DebugPrint("Humans killed me from bullet over 3 times bulletres+")
    end

    -- 9. Швидка смерть після встановлення зорового контакту (Burst damage)
    if stats.LoSDuration and stats.LoSDuration < 3.0 then
        tankScore = tankScore + 0.8
        fastScore = fastScore * 0.4 
        DebugPrint("Instant death in LoS (", math.Round(stats.LoSDuration, 2), "s). tank+ fast-")
    end
    
    DebugPrint("Context for bot ", bot:EntIndex(), ": Fast=", fastScore, " Tank=", tankScore, " MeleeRes=", meleeResScore, " BulletRes=", bulletResScore, " Leaper=", leaperScore)
    return fastScore, tankScore, meleeResScore, bulletResScore, leaperScore
end

-- ====================================================================
-- ВИБІР КЛАСУ ТА КЕШУВАННЯ
-- ====================================================================
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
    local baseFallbackWeight = 5.0 -- Константа базової ймовірності
    
    for _, entry in ipairs(CachedAvailableClasses) do
        local dynamicPriority = baseFallbackWeight +
                                (entry.fastPri * fastScore) + 
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

-- 1. Реєстрація смерті та збір даних
hook.Add("DoPlayerDeath", "D3bot_SmartSpawn_DeathAnalytics", function(victim, attacker, dmginfo)
    if not victim:IsBot() then return end 

    local inflictor = dmginfo:GetInflictor()
    local stats = D3bot.ZS.BotStats[victim:EntIndex()] or {}
    local victimPos = victim:GetPos()
    stats.LastDeathPos = victimPos
    
    table.insert(D3bot.ZS.DeathLog, { pos = victimPos, time = CurTime() })
    
    if stats.ChaseStartTime then
        stats.ChaseDuration = CurTime() - stats.ChaseStartTime
        stats.ChaseStartTime = nil 
    else
        stats.ChaseDuration = 0
    end
    
    if stats.LoSStartTime then
        stats.LoSDuration = CurTime() - stats.LoSStartTime
        stats.LoSStartTime = nil
    else
        stats.LoSDuration = nil
    end
    
    -- Просторова аналітика ТА розширений аналіз зброї
    if IsValid(attacker) and attacker:IsPlayer() and attacker ~= victim and attacker:Team() == TEAM_HUMAN then
        -- Обчислення дистанції
        local attackerPos = attacker:GetPos()
        stats.DeathDistance = victimPos:Distance(attackerPos)
        stats.ZDiscrepancy = attackerPos.z - victimPos.z
        
        -- Обчислення типу зброї
        local weapon = inflictor
        if inflictor == attacker then
            weapon = attacker:GetActiveWeapon()
        end
        
        if IsValid(weapon) and weapon:IsWeapon() then
            local weaponClass = weapon:GetClass()
            local isMelee = weapon.IsMelee or string.find(weaponClass, "melee") or weaponClass == "weapon_crowbar"
            
            if isMelee then
                stats.KilledByMeleeCount = (stats.KilledByMeleeCount or 0) + 1
                stats.KilledByBulletCount = 0 
            else
                stats.KilledByBulletCount = (stats.KilledByBulletCount or 0) + 1
                stats.KilledByMeleeCount = 0 
            end
        end
    else
        -- Смерть від геометрії карти, самогубство або friendly fire
        stats.DeathDistance = 0
        stats.ZDiscrepancy = 0
    end

    DebugPrint("DEATH RECORDED | Bot: ", victim:EntIndex(), 
               " | Dist: ", math.Round(stats.DeathDistance or 0, 1), 
               " | Z-Delta: ", math.Round(stats.ZDiscrepancy or 0, 1), 
               " | MeleeStreak: ", stats.KilledByMeleeCount or 0, 
               " | BulletStreak: ", stats.KilledByBulletCount or 0)

    D3bot.ZS.BotStats[victim:EntIndex()] = stats
end)

-- 2. Глобальний монітор телеметрії (тільки відстеження видимості)
local nextThink = 0
hook.Add("Think", "D3bot_SmartSpawn_TargetTracker", function()
    if CurTime() < nextThink then return end
    nextThink = CurTime() + 0.5

    for _, bot in ipairs(player.GetAll()) do
        if bot:IsBot() and bot:Alive() and bot.D3bot_Mem then
            local mem = bot.D3bot_Mem
            local stats = D3bot.ZS.BotStats[bot:EntIndex()] or {}
            
            local currentTarget = mem.TgtOrNil
            local previousTarget = stats.CurrentTarget
            
            if IsValid(currentTarget) and currentTarget:IsPlayer() and currentTarget:Alive() then
                if previousTarget ~= currentTarget then
                    D3bot.ZS.OnTargetAcquired(bot, currentTarget)
                end
                
                if bot:Visible(currentTarget) then
                    if not stats.LoSStartTime then
                        stats.LoSStartTime = CurTime()
                        D3bot.ZS.BotStats[bot:EntIndex()] = stats
                    end
                else
                    if stats.LoSStartTime then
                        stats.LoSStartTime = nil
                        D3bot.ZS.BotStats[bot:EntIndex()] = stats
                    end
                end
            else
                if previousTarget ~= nil then
                    stats.CurrentTarget = nil
                    stats.LoSStartTime = nil
                    D3bot.ZS.BotStats[bot:EntIndex()] = stats
                end
            end
        end
    end
end)

-- 3. Виконання глобального полювання після респауну
hook.Add("PlayerSpawn", "D3bot_SmartSpawn_InitialTarget", function(bot)
    if not bot:IsBot() then return end
    
    timer.Simple(0.1, function()
        if not IsValid(bot) then return end
        
        local stats = D3bot.ZS.BotStats[bot:EntIndex()]
        if not stats then return end
        
        local hunt = stats.HuntTarget
        if IsValid(hunt) and hunt:Alive() and hunt:Team() == TEAM_HUMAN and bot.D3bot_Mem then
            bot:D3bot_SetTgtOrNil(hunt, false, nil)
            DebugPrint("HUNT EXECUTED | Bot ", bot:EntIndex(), " deployed against ", hunt:GetName())
        end
        
        stats.HuntTarget = nil
        D3bot.ZS.BotStats[bot:EntIndex()] = stats
    end)
end)

-- ====================================================================
-- ОЧИЩЕННЯ ПАМ'ЯТІ ПРИ ПЕРЕЗАПУСКУ РАУНДУ
-- ====================================================================
hook.Add("PostCleanupMap", "D3bot_SmartSpawn_RoundReset", function()
    D3bot.ZS.BotStats = {}
    D3bot.ZS.DeathLog = {}
    D3bot.ZS.SoloPlayers = {}

    -- Скидання кешу класів для уникнення помилок при зміні хвиль
    CachedWave = -1
    CachedAvailableClasses = {}
    
    DebugPrint("ROUND RESTART | All bot memory, streaks, and caches have been purged.")
end)

-- Резервний хук для специфіки Zombie Survival (у разі софт-рестарту без Cleanup)
hook.Add("PreRestartRound", "D3bot_SmartSpawn_ZSRoundReset", function()
    D3bot.ZS.BotStats = {}
    D3bot.ZS.DeathLog = {}
    D3bot.ZS.SoloPlayers = {}
    CachedWave = -1
    CachedAvailableClasses = {}
end)