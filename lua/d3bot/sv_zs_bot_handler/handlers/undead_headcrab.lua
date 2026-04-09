print("[D3bot] Loading undead_headcrab.lua handler...")

D3bot.Handlers.Undead_Headcrab = D3bot.Handlers.Undead_Headcrab or {}
local HANDLER = D3bot.Handlers.Undead_Headcrab

HANDLER.AngOffshoot = 45
HANDLER.BotTgtFixationDistMin = 250
HANDLER.PounceInterval = 3 -- Let them pounce every few seconds.
HANDLER.PounceIntervalPlusRandom = 5 -- Additional random delay.

HANDLER.Fallback = false
function HANDLER.SelectorFunction(zombieClassName, team)
    return team == TEAM_UNDEAD and string.find(zombieClassName, "Headcrab") ~= nil
end

-- Підключаємо безпечну перевірку печатей
local IsSigilCorrupted = D3bot.ZS and D3bot.ZS.IsSigilCorrupted or function() return false, false end

---Updates the bot move data every frame.
---@param bot GPlayer|table
---@param cmd GCUserCmd
function HANDLER.UpdateBotCmdFunction(bot, cmd)
    cmd:ClearButtons()
    cmd:ClearMovement()

    if not bot:Alive() then
        -- Get back into the game
        cmd:SetButtons(IN_ATTACK)
        return
    end

    bot:D3bot_UpdatePathProgress()
    D3bot.Basics.SuicideOrRetarget(bot)

    local result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.PounceAuto(bot, true)
    if not result then
        result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.WalkAttackAuto(bot)
        if not result then
            return
        end
    end

    -- Trigger a pounce every now and then.
    local mem = bot.D3bot_Mem
    mem.NextPounce = mem.NextPounce or (CurTime() + HANDLER.PounceInterval + math.random() * HANDLER.PounceIntervalPlusRandom)
    if mem.NextPounce <= CurTime() then
        mem.PounceActive, mem.NextPounce = mem.PounceActive or CurTime(), nil
    end

    -- Let the headcrab pounce.
    actions.Duck = nil -- Never let the headcrab duck.
    if mem.PounceActive then
        actions.Attack = true -- Attack/Pounce.
        actions.Jump = nil -- Prevent jumping just because.
        mem.AntiStuckTime = nil -- Disable any anti stuck measures.
        forwardSpeed = 0 -- Prevent bots from sliding around.

        if mem.PounceActive + 1 <= CurTime() then
            mem.PounceActive = nil
        end
    end

    local buttons
    if actions then
        buttons = bit.bor(actions.MoveForward and IN_FORWARD or 0, actions.MoveBackward and IN_BACK or 0, actions.MoveLeft and IN_MOVELEFT or 0, actions.MoveRight and IN_MOVERIGHT or 0, actions.Attack and IN_ATTACK or 0, actions.Attack2 and IN_ATTACK2 or 0, actions.Duck and IN_DUCK or 0, actions.Jump and IN_JUMP or 0, actions.Use and IN_USE or 0)
    end

    if majorStuck and GAMEMODE:GetWaveActive() then bot:Kill() end

    if aimAngle then bot:SetEyeAngles(aimAngle) cmd:SetViewAngles(aimAngle) end
    if forwardSpeed then cmd:SetForwardMove(forwardSpeed) end
    if sideSpeed then cmd:SetSideMove(sideSpeed) end
    if upSpeed then cmd:SetUpMove(upSpeed) end
    cmd:SetButtons(buttons)
end

---Called every frame.
---@param bot GPlayer
function HANDLER.ThinkFunction(bot)
    local mem = bot.D3bot_Mem
    local botPos = bot:GetPos()

    if mem.nextUpdateSurroundingPlayers and mem.nextUpdateSurroundingPlayers < CurTime() or not mem.nextUpdateSurroundingPlayers then
        if not mem.TgtOrNil or IsValid(mem.TgtOrNil) and mem.TgtOrNil:GetPos():Distance(botPos) > HANDLER.BotTgtFixationDistMin then
            mem.nextUpdateSurroundingPlayers = CurTime() + 0.9 + math.random() * 0.2
            local targets = player.GetAll()
            table.sort(targets, function(a, b) return botPos:DistToSqr(a:GetPos()) < botPos:DistToSqr(b:GetPos()) end)
            for k, v in ipairs(targets) do
                if IsValid(v) and botPos:DistToSqr(v:GetPos()) < 500*500 and HANDLER.CanBeTgt(bot, v) and bot:D3bot_CanSeeTarget(nil, v) then
                    bot:D3bot_SetTgtOrNil(v, false, nil)
                    mem.nextUpdateSurroundingPlayers = CurTime() + 5
                    break
                end
                if k > 3 then break end
            end
        end
    end

    if mem.nextCheckTarget and mem.nextCheckTarget < CurTime() or not mem.nextCheckTarget then
        mem.nextCheckTarget = CurTime() + 0.9 + math.random() * 0.2
        if not HANDLER.CanBeTgt(bot, mem.TgtOrNil) then
            HANDLER.RerollTarget(bot)
        end
    end

    if mem.nextUpdateOffshoot and mem.nextUpdateOffshoot < CurTime() or not mem.nextUpdateOffshoot then
        mem.nextUpdateOffshoot = CurTime() + 0.4 + math.random() * 0.2
        bot:D3bot_UpdateAngsOffshoot(HANDLER.AngOffshoot)
    end

    local pathCostFunction = D3bot.ZS.GetSharedPathCostFunction(bot)

    if mem.nextUpdatePath and mem.nextUpdatePath < CurTime() or not mem.nextUpdatePath then
        mem.nextUpdatePath = CurTime() + 0.9 + math.random() * 0.2
        bot:D3bot_UpdatePath(pathCostFunction, nil)
    end
end

---Called when the bot takes damage.
function HANDLER.OnTakeDamageFunction(bot, dmg)
    local attacker = dmg:GetAttacker()
    if not HANDLER.CanBeTgt(bot, attacker) then return end
    local mem = bot.D3bot_Mem
    if IsValid(mem.TgtOrNil) and mem.TgtOrNil:GetPos():DistToSqr(bot:GetPos()) <= math.pow(HANDLER.BotTgtFixationDistMin, 2) then return end
    mem.TgtOrNil = attacker
end

function HANDLER.OnDoDamageFunction(bot, ent, dmg)
    -- Можна додати логіку при нанесенні урону
end

---Called when the bot dies.
function HANDLER.OnDeathFunction(bot)
    bot.DeathClass = D3bot.ZS.GetSmartClassIndex(bot)
    HANDLER.RerollTarget(bot)
end

-----------------------------------
-- Custom functions and settings --
-----------------------------------

local potTargetEntClasses = {"prop_*turret", "prop_arsenalcrate", "prop_manhack*", "prop_obj_sigil"}
local potEntTargets = nil

---Returns whether a target is valid.
function HANDLER.CanBeTgt(bot, target)
    if not target or not IsValid(target) then return false end
    
    -- Атака на людей
    if target:IsPlayer() and target ~= bot and target:Team() ~= TEAM_UNDEAD and target:GetObserverMode() == OBS_MODE_NONE and not target:IsFlagSet(FL_NOTARGET) and target:Alive() then 
        return true 
    end
    
    -- ОНОВЛЕНО: Безпечна перевірка печатей (не атакуємо зелені/зламані)
    if target:GetClass() == "prop_obj_sigil" then
        local corrupted, _ = IsSigilCorrupted(target)
        if corrupted then return false end
        return true
    end
    
    if potEntTargets and table.HasValue(potEntTargets, target) then return true end
    
    return false
end

---Rerolls the bot's target.
function HANDLER.RerollTarget(bot)
    local players = D3bot.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN))
    if #players == 0 and TEAM_UNDEAD then
        players = D3bot.RemoveObsDeadTgts(player.GetAll())
        players = D3bot.From(players):Where(function(k, v) return v:Team() ~= TEAM_UNDEAD end).R
    end
    if #players == 0 then
        players = D3bot.RemoveObsDeadTgts(player.GetAll())
    end
    
    potEntTargets = D3bot.GetEntsOfClss(potTargetEntClasses)
    local potTargets = table.Add(players, potEntTargets)
    bot:D3bot_SetTgtOrNil(table.Random(potTargets), false, nil)
end

return HANDLER