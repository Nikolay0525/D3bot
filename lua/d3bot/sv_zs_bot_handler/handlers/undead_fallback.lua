D3bot.Handlers.Undead_Fallback = D3bot.Handlers.Undead_Fallback or {}
local HANDLER = D3bot.Handlers.Undead_Fallback

-- Debug flag for nest targeting prints (set to true to enable [D3bot NestTarget] messages)
local DEBUG_NEST_TARGET = false

-- Debug flag for ambush/flee behavior (set to true to enable [D3bot Behavior] messages)
local DEBUG_BEHAVIOR = false

local DEBUG_STRAFE = false

local DEBUG_KEYS = false

--------------------------------------------------------------------------------
-- Configuration for Barricade Ambush Behavior
--------------------------------------------------------------------------------
HANDLER.BarricadeCountdown = 10       -- Seconds before wave ends to trigger barricade ambush
HANDLER.BarricadeAttackRange = 150    -- When human comes within this range, attack
HANDLER.BarricadeSkipRange = 50       -- Don't enter ambush if already this close (practically touching)
HANDLER.BarricadeAmbushTimeout = 30   -- Seconds before ambush times out and tries again
HANDLER.AmbushSearchDelay = 1         -- Seconds between hiding spot search attempts
HANDLER.AmbushBarricadeAvoidDist = 300 -- Minimum distance from nailed props for hiding spot

-- -- List of classes allowed to use the retreat-and-heal behavior
-- HANDLER.RegenClasses = {
--     ["Zombie"] = true,
--     ["Bloated Zombie"] = true,
--     ["Fresh Dead"] = true,
--     ["Skeleton"] = true
-- }

-- HANDLER.RegenHPThreshold = 0.2 -- 20% HP
-- HANDLER.RegenChance = 50       -- 50% chance to trigger
-- HANDLER.RegenPlayerDist = 250  -- Stand up if player is this close

--------------------------------------------------------------------------------
-- Helper: Check if current map is standard ZS (not ZE or Objective)
--------------------------------------------------------------------------------
local function IsStandardZSMap()
	return not GAMEMODE.ZombieEscape and not GAMEMODE.ObjectiveMap
end
--------------------------------------------------------------------------------
-- Helper: Check if wave countdown is in barricade ambush trigger window
--------------------------------------------------------------------------------
local function ShouldTriggerBarricadeAmbush(bot)
    if not GAMEMODE:GetWaveActive() then return false end
    local waveEnd = GAMEMODE:GetWaveEnd()
    if waveEnd <= 0 then return false end  -- Infinite wave or invalid
    local timeLeft = waveEnd - CurTime()

    local mem = bot.D3bot_Mem
    
    if not mem.Volatile.AmbushTimeMultiplier then
        mem.Volatile.AmbushTimeMultiplier = math.Rand(0.8, 1.2)
    end
    
    local triggerTime = HANDLER.BarricadeCountdown * mem.Volatile.AmbushTimeMultiplier

    return timeLeft <= triggerTime and timeLeft > 0
end

--------------------------------------------------------------------------------
-- Helper: Find a hiding spot BEHIND WALLS (world geometry) away from humans
-- Requires actual wall/brush geometry between the spot and humans, not props
--------------------------------------------------------------------------------
local function FindHidingSpot(bot, humanPositions)
	local botPos = bot:GetPos()
	local bestSpot = nil
	local bestScore = -math.huge

	-- Try navmesh first
	local navAreas = navmesh.Find(botPos, 800, 200, 200)

	-- If no navmesh, try trace-based approach to find valid positions
	local searchPositions = {}

	if navAreas and #navAreas > 0 then
		-- Use navmesh areas
		for _, area in ipairs(navAreas) do
			table.insert(searchPositions, area:GetCenter())
		end
	else
		-- Fallback: Generate positions around the bot using traces
		for angle = 0, 359, 30 do
			for dist = 150, 600, 150 do
				local dir = Vector(math.cos(math.rad(angle)), math.sin(math.rad(angle)), 0)
				local targetPos = botPos + dir * dist

				-- Trace down to find ground
				local groundTrace = util.TraceLine({
					start = targetPos + Vector(0, 0, 100),
					endpos = targetPos - Vector(0, 0, 200),
					filter = bot,
					mask = MASK_SOLID_BRUSHONLY
				})

				if groundTrace.Hit and not groundTrace.HitSky then
					-- Check if position is accessible (no wall blocking path)
					local pathTrace = util.TraceLine({
						start = botPos + Vector(0, 0, 32),
						endpos = groundTrace.HitPos + Vector(0, 0, 32),
						filter = bot,
						mask = MASK_SOLID_BRUSHONLY
					})

					if not pathTrace.Hit or pathTrace.Fraction > 0.9 then
						table.insert(searchPositions, groundTrace.HitPos)
					end
				end
			end
		end
	end

	if #searchPositions == 0 then return nil end

	for _, pos in ipairs(searchPositions) do
		local score = 0
		local hiddenBehindWall = false

		-- Check if this spot is hidden from humans BY WORLD GEOMETRY (walls)
		for _, humanPos in ipairs(humanPositions) do
			-- Use MASK_SOLID_BRUSHONLY to only count world geometry as "hiding"
			-- This ensures we're behind actual walls, not props/barricades
			local wallTr = util.TraceLine({
				start = pos + Vector(0, 0, 32),
				endpos = humanPos + Vector(0, 0, 32),
				filter = bot,
				mask = MASK_SOLID_BRUSHONLY  -- World geometry only!
			})

			if wallTr.Hit then
				-- Hidden behind WALL from this human - this is what we want!
				score = score + 100
				hiddenBehindWall = true
			else
				-- Human has direct line of sight (through world), very bad
				score = score - 200
			end

			-- Prefer spots that are close enough to ambush but not too close
			local dist = pos:Distance(humanPos)
			if dist > 200 and dist < 500 then
				score = score + 30  -- Ideal ambush distance
			elseif dist < 200 then
				score = score - 50  -- Too close, might be seen
			end
		end

		-- REQUIRE the spot to be behind at least one wall
		if not hiddenBehindWall then
			score = -math.huge  -- Reject spots not behind walls
		end

		-- Prefer spots near walls/corners (world geometry)
		local wallTraces = 0
		for angle = 0, 315, 45 do
			local dir = Vector(math.cos(math.rad(angle)), math.sin(math.rad(angle)), 0)
			local wallTr = util.TraceLine({
				start = pos + Vector(0, 0, 32),
				endpos = pos + Vector(0, 0, 32) + dir * 100,
				filter = bot,
				mask = MASK_SOLID_BRUSHONLY  -- World geometry only
			})
			if wallTr.Hit then
				wallTraces = wallTraces + 1
			end
		end
		score = score + wallTraces * 20  -- More walls nearby = better corner hiding spot

		if score > bestScore then
			bestScore = score
			bestSpot = pos
		end
	end

	return bestSpot
end

--------------------------------------------------------------------------------
-- Helper: Check if an entity is a barricade (nailed prop, board, etc.)
--------------------------------------------------------------------------------
local function IsBarricadeEntity(ent)
	if not IsValid(ent) then return false end

	-- Check multiple ways to detect barricades:
	-- 1. IsNailed method (common for props)
	if ent.IsNailed and ent:IsNailed() then
		return true
	-- 2. D3bot_IsBarricade method
	elseif ent.D3bot_IsBarricade and ent:D3bot_IsBarricade() then
		return true
	-- 3. Check for common barricade entity classes
	elseif ent:GetClass() == "prop_obj_board" or
	       ent:GetClass() == "prop_deployablebarricade" or
	       string.find(ent:GetClass(), "barricade") then
		return true
	-- 4. Check if prop has nails (ZS specific)
	elseif ent.GetNumNails and ent:GetNumNails() > 0 then
		return true
	end

	return false
end

--------------------------------------------------------------------------------
-- Helper: Check if path from bot to target position goes through any barricades
-- Returns true if path is clear (no barricades blocking)
--------------------------------------------------------------------------------
local function IsPathClearOfBarricades(botPos, targetPos)
	-- Trace from bot to target position
	local tr = util.TraceLine({
		start = botPos + Vector(0, 0, 32),
		endpos = targetPos + Vector(0, 0, 32),
		mask = MASK_SOLID,
		filter = function(ent)
			-- Don't filter out barricades - we want to hit them
			return false
		end
	})

	-- Check if we hit a barricade
	if tr.Hit and tr.Entity and IsBarricadeEntity(tr.Entity) then
		return false -- Path blocked by barricade
	end

	-- Also do a hull trace to catch barricades we might walk into
	local hullTr = util.TraceHull({
		start = botPos + Vector(0, 0, 32),
		endpos = targetPos + Vector(0, 0, 32),
		mins = Vector(-16, -16, 0),
		maxs = Vector(16, 16, 64),
		mask = MASK_SOLID,
		filter = function(ent)
			return false
		end
	})

	if hullTr.Hit and hullTr.Entity and IsBarricadeEntity(hullTr.Entity) then
		return false -- Path blocked by barricade
	end

	return true -- Path is clear
end

--------------------------------------------------------------------------------
-- Helper: Check if a position is away from all nailed props (barricades)
-- Returns true if position is safe (no barricades nearby)
--------------------------------------------------------------------------------
local function IsPositionAwayFromBarricades(pos, minDist)
	minDist = minDist or HANDLER.AmbushBarricadeAvoidDist
	local minDistSqr = minDist * minDist

	-- Check all entities that might be barricades
	for _, ent in ipairs(ents.GetAll()) do
		if IsBarricadeEntity(ent) then
			local distSqr = pos:DistToSqr(ent:GetPos())
			if distSqr < minDistSqr then
				return false -- Too close to a barricade
			end
		end
	end

	return true -- No barricades nearby
end

--------------------------------------------------------------------------------
-- Helper: Find a hiding spot that is away from barricades AND reachable without
-- going through barricades. This prevents zombies from picking hiding spots
-- on the human side of barricades.
--------------------------------------------------------------------------------
local function FindSafeHidingSpot(bot, humanPositions)
	local botPos = bot:GetPos()

	-- First find a regular hiding spot
	local spot = FindHidingSpot(bot, humanPositions)

	-- If no spot found, return nil
	if not spot then return nil end

	-- Check if this spot is away from barricades AND path is clear (not through barricades)
	if IsPositionAwayFromBarricades(spot) and IsPathClearOfBarricades(botPos, spot) then
		return spot
	end

	-- Spot is invalid (too close to barricades or path goes through barricades)
	-- Try to find a better one - generate positions further away
	local bestSpot = nil
	local bestScore = -math.huge

	for angle = 0, 359, 20 do
		for dist = 400, 800, 100 do
			local dir = Vector(math.cos(math.rad(angle)), math.sin(math.rad(angle)), 0)
			local targetPos = botPos + dir * dist

			-- Trace down to find ground
			local groundTrace = util.TraceLine({
				start = targetPos + Vector(0, 0, 100),
				endpos = targetPos - Vector(0, 0, 200),
				filter = bot,
				mask = MASK_SOLID_BRUSHONLY
			})

			if groundTrace.Hit and not groundTrace.HitSky then
				local testPos = groundTrace.HitPos

				-- Check if accessible (no world geometry blocking)
				local pathTrace = util.TraceLine({
					start = botPos + Vector(0, 0, 32),
					endpos = testPos + Vector(0, 0, 32),
					filter = bot,
					mask = MASK_SOLID_BRUSHONLY
				})

				-- Must be: accessible, away from barricades, AND path doesn't go through barricades
				if (not pathTrace.Hit or pathTrace.Fraction > 0.8) and IsPositionAwayFromBarricades(testPos) and IsPathClearOfBarricades(botPos, testPos) then
					-- Score this position
					local score = 0

					-- Prefer positions hidden from humans
					for _, humanPos in ipairs(humanPositions) do
						local tr = util.TraceLine({
							start = testPos + Vector(0, 0, 32),
							endpos = humanPos + Vector(0, 0, 32),
							filter = bot,
							mask = MASK_SHOT
						})
						if tr.Hit then
							score = score + 50 -- Hidden from human
						end
					end

					-- Prefer positions near walls
					local wallCount = 0
					for wallAngle = 0, 315, 45 do
						local wallDir = Vector(math.cos(math.rad(wallAngle)), math.sin(math.rad(wallAngle)), 0)
						local wallTr = util.TraceLine({
							start = testPos + Vector(0, 0, 32),
							endpos = testPos + Vector(0, 0, 32) + wallDir * 100,
							filter = bot,
							mask = MASK_SOLID
						})
						if wallTr.Hit then wallCount = wallCount + 1 end
					end
					score = score + wallCount * 10

					if score > bestScore then
						bestScore = score
						bestSpot = testPos
					end
				end
			end
		end
	end

	return bestSpot
end

HANDLER.AngOffshoot = 45
HANDLER.BotTgtFixationDistMin = 250

HANDLER.WeaponDodgeBlacklist = {
    ["weapon_zs_fists"] = true,
    ["weapon_zs_hammer"] = true
}

HANDLER.RandomSecondaryAttack = {
	Ghoul = {MinTime = 5, MaxTime = 7},
	["Elder Ghoul"] = {MinTime = 5, MaxTime = 7},
	["Noxious Ghoul"] = {MinTime = 5, MaxTime = 7},
	["Frigid Ghoul"] = {MinTime = 5, MaxTime = 7},
	["Frigid Revenant"] = {MinTime = 5, MaxTime = 7},
	["Vile Bloated Zombie"] = {MinTime = 5, MaxTime = 7},
	["Poison Zombie"] = {MinTime = 5, MaxTime = 7},
	["Wild Poison Zombie"] = {MinTime = 5, MaxTime = 7},
	["Charger"] = {MinTime = 3, MaxTime = 5}
}

HANDLER.SecondaryBallistics = {
    ["Ghoul"] = 0.15,
    ["Elder Ghoul"] = 0.35,
    ["Noxious Ghoul"] = 0.35,
    ["Frigid Ghoul"] = 0.15,
    ["Frigid Revenant"] = 0.15,
    ["Vile Bloated Zombie"] = 0.3,
    ["Poison Zombie"] = 0.4,
    ["Wild Poison Zombie"] = 0.4
}

HANDLER.Fallback = true
--------------------------------------------------------------------------------
-- EmmyLua Type Definitions
--------------------------------------------------------------------------------

---@class Fallback_Volatile : table
---Handler-specific volatile state for fallback handler bots. Auto-reset on spawn/death.
---@field NestSpawnTargetLockTime number? CurTime() until nest spawn target lock expires
---@field BabyStuckTime number? CurTime() when baby bot first became stuck (for 12s timeout)
---@field NextThrowPoisonTime number? CurTime() for next poison throw (Ghoul secondary attack)
---@field NextBabyThrowTime number? CurTime() for next baby throw (Giga Gore/Shadow Child)
---@field NextBabyThrowCheckTime number? CurTime() for next baby throw range check
---@field ShouldThrowBaby boolean? Flag indicating bot should throw a baby
---@field HumanInThrowRange boolean? Flag indicating human is in throw range
---@field NextShadeThrowTime number? CurTime() for next Shade rock throw
---@field NextShadeReloadTime number? CurTime() for next Shade rock creation
---@field NextDevourerGrappleCheckTime number? CurTime() for next Devourer grapple check
---@field BehaviorState string? Current behavior state: "normal", "ambush"
---@field AmbushPosition GVector? Target position for ambush hiding
---@field AmbushWave number? Wave number when ambush was triggered (to detect new wave)
---@field AmbushStartTime number? CurTime() when ambush started (for timeout)
---@field AmbushTriggered boolean? Whether ambush was already triggered this wave
---@field AmbushSearchNextTime number? CurTime() for next hiding spot search attempt
---@field NextBehaviorCheck number? CurTime() for next behavior state check

--------------------------------------------------------------------------------

---Selector function - determines if this handler should be used for a bot.
---@param zombieClassName string The zombie class name
---@param team integer The team number
---@return boolean True if this handler should handle the bot (fallback for all undead)
function HANDLER.SelectorFunction(zombieClassName, team)
	return team == TEAM_UNDEAD
end

local standardParams = {
	["X"] = true, ["Y"] = true, ["Z"] = true,
	["AreaXMax"] = true, ["AreaXMin"] = true,
	["AreaYMax"] = true, ["AreaYMin"] = true,
	["AreaZMax"] = true, ["AreaZMin"] = true
}

local function HasSpecialParams(params)
	if type(params) ~= "table" then return false end
	for key, value in pairs(params) do
		if not standardParams[key] then
			return true
		end
	end
	return false
end

---Updates the bot movement and input commands every frame.
---Handles movement, attacks, special abilities, and stuck detection.
---@param bot GPlayer The bot player entity
---@param cmd GCUserCmd The user command to populate
---@return nil
function HANDLER.UpdateBotCmdFunction(bot, cmd)
	cmd:ClearButtons()
	cmd:ClearMovement()

	-- Fix knocked down bots from sliding around. (Workaround for the NoxiousNet codebase, as ply:Freeze() got removed from status_knockdown, status_revive, ...)
	-- Bug: We need to check the type of bot.Revive, as there is probably a bug in ZS that sets this value to a function instead of userdata
	if bot.KnockedDown and IsValid(bot.KnockedDown) or bot.Revive and type(bot.Revive) ~= "function" and IsValid(bot.Revive) then
		return
	end

	if not bot:Alive() then
		-- Get back into the game.
		cmd:SetButtons(IN_ATTACK)
		return
	end

	local mem = bot.D3bot_Mem

	bot:D3bot_UpdatePathProgress()

	D3bot.Basics.SuicideOrRetarget(bot)

	local result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance

	result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.PounceAuto(bot, false)

	if not result then
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.WalkAttackAuto(bot, true)
		if not result then
			return
		end
	end

	-- If facesHindrance is true, let the bot search for nearby barricade objects.
	-- But only if the bot didn't do damage for some time.
	if facesHindrance and CurTime() - (bot.D3bot_LastDamage or 0) > 2 then
		local entity, entityPos = bot:D3bot_FindBarricadeEntity(1) -- One random line trace per frame.
		if entity and entityPos then
			-- Don't attack nests - they're zombie spawn points, not obstacles
			if entity:GetClass() == "prop_creepernest" then
				-- Nest is blocking, move around it instead of attacking
				mem.Volatile.NestBlocking = true
				mem.Volatile.NestBlockingTime = CurTime()
			else
				mem.BarricadeAttackEntity, mem.BarricadeAttackPos = entity, entityPos
			end
		end
	end

	-- Handle nest blocking - move in various directions to get around it
	if mem.Volatile.NestBlocking and mem.Volatile.NestBlockingTime then
		if CurTime() - mem.Volatile.NestBlockingTime < 2 then
			-- Cycle through different movement patterns every 0.4 seconds
			local phase = math.floor((CurTime() - mem.Volatile.NestBlockingTime) / 0.4) % 5
			if phase == 0 then
				-- Move backwards + strafe right
				forwardSpeed = -200
				sideSpeed = 150
			elseif phase == 1 then
				-- Pure strafe left
				forwardSpeed = 0
				sideSpeed = -250
			elseif phase == 2 then
				-- Move backwards + strafe left
				forwardSpeed = -200
				sideSpeed = -150
			elseif phase == 3 then
				-- Pure strafe right
				forwardSpeed = 0
				sideSpeed = 250
			else
				-- Move backwards only
				forwardSpeed = -250
				sideSpeed = 0
			end
		else
			-- Clear nest blocking after 2 seconds
			mem.Volatile.NestBlocking = nil
			mem.Volatile.NestBlockingTime = nil
		end
	elseif not facesHindrance then
		-- Clear nest blocking when moving freely
		mem.Volatile.NestBlocking = nil
		mem.Volatile.NestBlockingTime = nil
	end

	--------------------------------------------------------------------------------
	-- BEHAVIOR STATE HANDLING: Ambush behavior (wave end OR barricade retreat)
	-- Only active on standard ZS maps (not ZE or Objective maps)
	--------------------------------------------------------------------------------
	local behaviorState = mem.Volatile.BehaviorState or "normal"

	if IsStandardZSMap() and behaviorState == "ambush" then
		local botPos = bot:GetPos()
		local ambushPos = mem.Volatile.AmbushPosition

		if ambushPos then
			-- Calculate direction to ambush position
			local dirToAmbush = (ambushPos - botPos)
			dirToAmbush.z = 0
			local distToAmbush = dirToAmbush:Length()

			if distToAmbush > 50 then
				-- Move towards hiding spot
				dirToAmbush:Normalize()
				local botAng = bot:EyeAngles()
				local botForward = botAng:Forward()
				botForward.z = 0
				botForward:Normalize()
				local botRight = botAng:Right()
				botRight.z = 0
				botRight:Normalize()

				-- Calculate movement relative to bot's facing direction
				forwardSpeed = dirToAmbush:Dot(botForward) * 300
				sideSpeed = dirToAmbush:Dot(botRight) * 300

				-- Look towards ambush position
				aimAngle = dirToAmbush:Angle()

				-- Don't attack while moving to position
				actions = actions or {}
				actions.Attack = nil
			else
				-- At hiding position - crouch and wait
				forwardSpeed = 0
				sideSpeed = 0
				actions = actions or {}
				actions.Duck = true
				actions.Attack = nil  -- Don't attack until human gets close
			end
		end
	end

	-- ====================================================================
    -- Mechanic of throwing secondary attack in players
    -- ====================================================================
    local zombieClassName = GAMEMODE.ZombieClasses[bot:GetZombieClass()].Name
    local secAttack = HANDLER.RandomSecondaryAttack[zombieClassName]
    
    if secAttack then
        if not mem.Volatile.NextThrowPoisonTime then
            mem.Volatile.NextThrowPoisonTime = CurTime() + secAttack.MinTime + (math.random() * (secAttack.MaxTime - secAttack.MinTime))
        end

        -- ==========================================================
        -- Charger unique logic
        -- ==========================================================
        if zombieClassName == "Charger" then
            if mem.Volatile.ChargeUntil and CurTime() < mem.Volatile.ChargeUntil then
                if IsValid(mem.TgtOrNil) and mem.TgtOrNil:IsPlayer() and mem.TgtOrNil:Alive() then
                    local target = mem.TgtOrNil
                    local botPos = bot:GetPos()
                    local targetPos = target:GetPos()
                    
                    local chargeDir = targetPos - botPos
                    chargeDir.z = 0
                    aimAngle = chargeDir:Angle()
                    
                    actions = actions or {}
                    actions.Attack2 = true
                    actions.MoveForward = true
                end
            else
                if CurTime() >= mem.Volatile.NextThrowPoisonTime then
                    local didCharge = false
                    
                    if IsValid(mem.TgtOrNil) and mem.TgtOrNil:IsPlayer() and mem.TgtOrNil:Alive() then
                        local target = mem.TgtOrNil
                        local botPos = bot:GetPos()
                        local targetPos = target:GetPos()
                        local distSqr = botPos:DistToSqr(targetPos)

                        if distSqr > 22500 and distSqr < 640000 then
                            local tr = util.TraceLine({
                                start = bot:EyePos(),
                                endpos = target:EyePos(),
                                filter = {bot, target},
                                mask = MASK_SHOT
                            })

                            if not tr.Hit then 
                                didCharge = true
                                
                                mem.Volatile.ChargeUntil = CurTime() + 1.5
                                
                                if DEBUG_BEHAVIOR then
                                    print("[D3bot SecAttack] Charger активує РИВОК на " .. target:Nick() .. "!")
                                end
                            end
                        end
                    end

                    if didCharge then
                        mem.Volatile.NextThrowPoisonTime = CurTime() + secAttack.MinTime + (math.random() * (secAttack.MaxTime - secAttack.MinTime))
                    else
                        mem.Volatile.NextThrowPoisonTime = CurTime() + 0.5
                    end
                end
            end

        -- ==========================================================
        -- Using of ballistic for projectiles thrown from SecondaryAttack
        -- ==========================================================
        else
            local ballisticMult = HANDLER.SecondaryBallistics[zombieClassName] or 0.15

            if mem.Volatile.ThrowWindupUntil and CurTime() < mem.Volatile.ThrowWindupUntil then
                if IsValid(mem.TgtOrNil) and mem.TgtOrNil:IsPlayer() and mem.TgtOrNil:Alive() then
                    local target = mem.TgtOrNil
                    local botShootPos = bot:GetShootPos()
                    local targetPos = target:EyePos()
                    
                    local throwDir = targetPos - botShootPos
                    local dist = botShootPos:Distance(targetPos)
                    
                    throwDir.z = throwDir.z + (dist * ballisticMult) 
                    
                    aimAngle = throwDir:Angle()
                    actions = actions or {}
                    actions.Attack2 = true 
                end
            else
                if CurTime() >= mem.Volatile.NextThrowPoisonTime then
                    local didThrow = false
                    
                    if IsValid(mem.TgtOrNil) and mem.TgtOrNil:IsPlayer() and mem.TgtOrNil:Alive() then
                        local target = mem.TgtOrNil
                        local botShootPos = bot:GetShootPos()
                        local targetPos = target:EyePos()
                        local distSqr = botShootPos:DistToSqr(targetPos)

                        if distSqr > 22500 and distSqr < 202500 then
                            local tr = util.TraceLine({
                                start = botShootPos,
                                endpos = targetPos,
                                filter = {bot, target},
                                mask = MASK_SHOT
                            })

                            if not tr.Hit then 
                                didThrow = true
                                mem.Volatile.ThrowWindupUntil = CurTime() + 1.2
                                
                                if DEBUG_BEHAVIOR then
                                    print("[D3bot SecAttack] " .. zombieClassName .. " почав замах! (Балістика: " .. ballisticMult .. ")")
                                end
                            end
                        end
                    end

                    if didThrow then
                        mem.Volatile.NextThrowPoisonTime = CurTime() + secAttack.MinTime + (math.random() * (secAttack.MaxTime - secAttack.MinTime))
                    else
                        mem.Volatile.NextThrowPoisonTime = CurTime() + 0.5
                    end
                end
            end
        end
    end

	-- Giga Gore/Shadow Child: PRIORITIZE throwing babies when at barricades
	-- Max 5 babies per boss, tracked on the bot
	if zombieClassName == "Giga Gore Child" or zombieClassName == "Giga Shadow Child" then
		-- Initialize baby count tracking
		bot.D3bot_BabyCount = bot.D3bot_BabyCount or 0
		local canThrowBaby = bot.D3bot_BabyCount < 5

		-- Check if at a barricade (facing hindrance = blocked by something)
		local isAtBarricade = facesHindrance

		if isAtBarricade and canThrowBaby then
			-- PRIORITY: Throw all 5 babies first, NO melee attacking
			-- Stop ALL melee attacks until babies are depleted
			actions = actions or {}
			actions.Attack = nil -- Never melee while we have babies to throw

			-- Throw baby every 2 seconds
			if (mem.Volatile.NextBabyThrowTime or 0) <= CurTime() then
				mem.Volatile.NextBabyThrowTime = CurTime() + 2.0
				actions.Attack2 = true
			end
		elseif not isAtBarricade then
			-- Check for humans in range (0-700 units)
			if (mem.Volatile.NextBabyThrowCheckTime or 0) <= CurTime() then
				mem.Volatile.NextBabyThrowCheckTime = CurTime() + 0.5

				mem.Volatile.ShouldThrowBaby = false
				mem.Volatile.HumanInThrowRange = false
				local botPos = bot:GetPos()
				for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
					if IsValid(pl) and pl:Alive() and pl:GetObserverMode() == OBS_MODE_NONE and not pl:IsFlagSet(FL_NOTARGET) then
						local distSqr = botPos:DistToSqr(pl:GetPos())
						if distSqr <= 700 * 700 and bot:D3bot_CanSeeTarget(nil, pl) then
							mem.Volatile.HumanInThrowRange = true
							-- 50% chance to throw baby, 50% chance to attack
							if canThrowBaby and math.random(100) <= 50 then
								mem.Volatile.ShouldThrowBaby = true
							end
							break
						end
					end
				end
			end

			if mem.Volatile.ShouldThrowBaby then
				actions = actions or {}
				actions.Attack2 = true
			end
		end
	end

	-- Shade/Frost Shade: Use rock/ice throwing at barricades
	if zombieClassName == "Shade" or zombieClassName == "Frost Shade" then
		local controlClass = zombieClassName == "Frost Shade" and "env_frostshadecontrol" or "env_shadecontrol"

		-- Check if we have a rock held (control entity with valid parent)
		local hasRock = false
		for _, ent in ipairs(ents.FindByClass(controlClass)) do
			if ent:IsValid() and ent:GetOwner() == bot then
				local obj = ent:GetParent()
				if obj:IsValid() then
					hasRock = true
					break
				end
			end
		end

		-- Check if facing a barricade or hindrance
		local shouldThrowRock = facesHindrance or IsValid(mem.BarricadeAttackEntity)

		if shouldThrowRock then
			if hasRock then
				-- Have a rock, throw it at the barricade
				if (mem.Volatile.NextShadeThrowTime or 0) <= CurTime() then
					mem.Volatile.NextShadeThrowTime = CurTime() + 0.7
					actions = actions or {}
					actions.Attack = true
				end
			else
				-- No rock, create one with Reload
				if (mem.Volatile.NextShadeReloadTime or 0) <= CurTime() then
					mem.Volatile.NextShadeReloadTime = CurTime() + 1.2
					actions = actions or {}
					actions.Reload = true
				end
			end
		end
	end

	-- Devourer: Prioritize grapple hook (right-click) when humans are in range
	if zombieClassName == "Devourer" then
		if (mem.Volatile.NextDevourerGrappleCheckTime or 0) <= CurTime() then
			mem.Volatile.NextDevourerGrappleCheckTime = CurTime() + 0.5 -- Check twice per second

			mem.Volatile.ShouldUseGrapple = false
			local botPos = bot:GetPos()
			local botEyePos = bot:EyePos()

			-- Look for humans in grapple range (200-800 units)
			for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
				if IsValid(pl) and pl:Alive() and pl:GetObserverMode() == OBS_MODE_NONE and not pl:IsFlagSet(FL_NOTARGET) then
					local distSqr = botPos:DistToSqr(pl:GetPos())
					-- Optimal grapple range: 200-800 units
					if distSqr >= 200 * 200 and distSqr <= 800 * 800 then
						-- Check line of sight
						local tr = util.TraceLine({
							start = botEyePos,
							endpos = pl:EyePos(),
							filter = {bot, pl},
							mask = MASK_SHOT
						})

						if not tr.Hit or tr.Entity == pl then
							mem.Volatile.ShouldUseGrapple = true
							mem.Volatile.GrappleTarget = pl
							break
						end
					end
				end
			end
		end

		-- Use grapple if we have a valid target
		if mem.Volatile.ShouldUseGrapple and IsValid(mem.Volatile.GrappleTarget) then
			actions = actions or {}
			actions.Attack2 = true
		end
	end

	-- Large bosses (Ass Kicker, Doom Crab, Extinction Crab): Duck when stuck or facing hindrances to fit through doors
	if zombieClassName == "Ass Kicker" or zombieClassName == "Doom Crab" or zombieClassName == "Extinction Crab" then
		if facesHindrance or minorStuck or majorStuck then
			actions = actions or {}
			actions.Duck = true
		end
	end

	-- Doom Crab and Extinction Crab: Open doors instead of attacking them
	if zombieClassName == "Doom Crab" or zombieClassName == "Extinction Crab" then
		if facesHindrance then
			-- Trace to detect if we're facing a door
			local eyePos = bot:EyePos()
			local eyeAng = bot:EyeAngles()
			local traceResult = util.TraceLine({
				start = eyePos,
				endpos = eyePos + eyeAng:Forward() * 100,
				filter = bot,
				mask = MASK_SOLID
			})

			if traceResult.Hit and IsValid(traceResult.Entity) then
				local entClass = traceResult.Entity:GetClass()
				if entClass == "prop_door_rotating" or entClass == "func_door_rotating" or entClass == "func_door" then
					actions = actions or {}
					actions.Use = true
					actions.Attack = nil -- Don't attack the door, just use it
				end
			end
		end
	end

	-- Bosses: use special actions (Reload / Attack2) when a player is close and visible.
	if bot:GetZombieClassTable().Boss then
		if string.StartWith(string.lower(game.GetMap() or ""), "zs") then
			if (mem.Volatile.NextBossSpecialCheckTime or 0) <= CurTime() then
				mem.Volatile.NextBossSpecialCheckTime = CurTime() + 0.2

				mem.Volatile.BossShouldSpecial = false
				local botPos = bot:GetPos()
				for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
					if IsValid(pl) and pl:Alive() and pl:GetObserverMode() == OBS_MODE_NONE and not pl:IsFlagSet(FL_NOTARGET) then
						if botPos:DistToSqr(pl:GetPos()) <= 150 * 150 and bot:D3bot_CanSeeTarget(nil, pl) then
							mem.Volatile.BossShouldSpecial = true
							break
						end
					end
				end
			end

			if mem.Volatile.BossShouldSpecial then
				actions = actions or {}
				actions.Attack2 = true
				actions.Reload = true
			end
		end
	end

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil

	if mem.Volatile.LastCheckedNode ~= nodeOrNil or mem.Volatile.LastCheckedNextNode ~= nextNodeOrNil then
		mem.Volatile.LastCheckedNode = nodeOrNil
		mem.Volatile.LastCheckedNextNode = nextNodeOrNil
		
		local currentParams, nextParams
		if D3bot.UsingSourceNav then
			currentParams = nodeOrNil and nodeOrNil:GetMetaData().Params
			nextParams = nextNodeOrNil and nextNodeOrNil:GetMetaData().Params
		else
			currentParams = nodeOrNil and nodeOrNil.Params
			nextParams = nextNodeOrNil and nextNodeOrNil.Params
		end

		mem.Volatile.DisableDodgingCache = HasSpecialParams(currentParams) or HasSpecialParams(nextParams)
	end

	local disableDodging = mem.Volatile.DisableDodgingCache

	if disableDodging then
		mem.Volatile.DodgeStrafe = 0
		mem.Volatile.BackwardUntil = nil
		mem.Volatile.DuckUntil = nil
		mem.Volatile.DodgeJump = false
		
		if DEBUG_STRAFE then
			print("[D3bot Dodge] " .. bot:Nick() .. " -> Node forces STRAIGHT movement. Dodging logic skipped.")
		end

	elseif IsValid(mem.TgtOrNil) and mem.TgtOrNil:IsPlayer() then

		local target = mem.TgtOrNil
		local targetPos = target:GetPos()
		local botPos = bot:GetPos()
		local distSqr = botPos:DistToSqr(targetPos)
		
		local isBackward = mem.Volatile.BackwardUntil and CurTime() < mem.Volatile.BackwardUntil
		local isStrafing = mem.Volatile.DodgeStrafe and mem.Volatile.DodgeStrafe ~= 0
		local isDodging = isBackward or isStrafing

		local isAttackingBarricade = facesHindrance and IsValid(mem.BarricadeAttackEntity)
		local allowBarricadeStrafe = isAttackingBarricade and (distSqr <= 160000)

		if distSqr < 250000 and (not facesHindrance or isDodging or allowBarricadeStrafe) then
			local wep = target:GetActiveWeapon()
			if IsValid(wep) then
				mem.Volatile.NextDodgeTime = mem.Volatile.NextDodgeTime or 0
				mem.Volatile.NextJumpTime = mem.Volatile.NextJumpTime or 0

				local dirToBot = botPos - targetPos
				dirToBot.z = 0
				dirToBot:Normalize()
				
				local targetAim = target:GetAimVector()
				targetAim.z = 0
				targetAim:Normalize()
				
				-- Якщо скалярний добуток >= 0.5, бот знаходиться в конусі 120 градусів перед гравцем
				local isLookingAtBot = (targetAim:Dot(dirToBot) >= 0.5)
				local isVisible = false

				if isLookingAtBot then
					local tr = util.TraceLine({
						start = botPos + Vector(0, 0, 48),     -- Chest level of the bot
						endpos = targetPos + Vector(0, 0, 48), -- Chest level of the player
						-- Use a function to ignore barricades so the bot can "see" through them
						filter = function(ent)
							if ent == bot or ent == target then return false end
							if IsBarricadeEntity(ent) then return false end -- Ignore barricades for visibility
							return true
						end,
						mask = MASK_OPAQUE                     -- Ray stops only on solid walls
					})
					isVisible = not tr.Hit -- If ray didn't hit a wall (and skipped barricades), path is clear
				end


				-- 1. БЛОК ПРИЙНЯТТЯ РІШЕНЬ
				if CurTime() > mem.Volatile.NextDodgeTime then
					mem.Volatile.DodgeStrafe = 0 
					local tacticName = "None"
					
					local wepClass = string.lower(wep:GetClass())
						
					if not isLookingAtBot or not isVisible then
						mem.Volatile.NextDodgeTime = CurTime() + 0.2
						if DEBUG_STRAFE then
							local reason = not isLookingAtBot and "Не дивиться" or "За стіною"
							print("[D3bot Dodge] " .. bot:Nick() .. " -> " .. reason .. "! Пру прямо.")
						end

					-- ПЕРЕВІРКА НА ЧОРНИЙ СПИСОК
					elseif HANDLER.WeaponDodgeBlacklist[wepClass] then
						-- Зброя безпечна, вимикаємо всі ухиляння і премо вперед
						mem.Volatile.DodgeStrafe = 0
						mem.Volatile.BackwardUntil = nil
						mem.Volatile.NextDodgeTime = CurTime() + 0.5
						
						if DEBUG_STRAFE then
							print("[D3bot Dodge] " .. bot:Nick() .. " -> Ціль з безпечною зброєю ("..wepClass..")! Пру прямо.")
						end

					else
						local isMelee = false
						local wepBase = string.lower(wep.Base or "")
						
						if string.find(wepBase, "melee") or string.find(wepClass, "melee") then
							isMelee = true
						elseif type(wep.IsMelee) == "function" and wep:IsMelee() then
							isMelee = true
						elseif type(wep.IsMelee) == "boolean" and wep.IsMelee then
							isMelee = true
						end

						if isMelee and distSqr < 22500 then
							tacticName = "БЛИЖНІЙ БІЙ"
							local isAttacking = target:KeyDown(IN_ATTACK)
							
							if (isAttacking and math.random() < 0.75) or math.random() < 0.25 then 
								mem.Volatile.BackwardUntil = CurTime() + math.random(2, 4) / 10 
								tacticName = tacticName .. " (ВІДСТРИБ)"
							end
							
							if math.random() < 0.50 then
								mem.Volatile.DodgeStrafe = math.random(-1, 1)
							end

							if CurTime() > mem.Volatile.NextJumpTime and math.random() < 0.25 then
								mem.Volatile.DodgeJump = true
								mem.Volatile.NextJumpTime = CurTime() + math.random(10, 20) / 10 
								tacticName = tacticName .. " (СТРИБОК)"
							end

							if math.random() < 0.25 then
								mem.Volatile.DuckUntil = CurTime() + math.random(3, 4) / 10 
								tacticName = tacticName .. " (ПРИСІД)"
							end

							mem.Volatile.NextDodgeTime = CurTime() + math.random(3, 5) / 10
						else
							tacticName = "ВОГНЕПАЛ (КУЛІ)"
							mem.Volatile.DodgeStrafe = math.random(-1, 1)
							
							if CurTime() > mem.Volatile.NextJumpTime and math.random() < 0.25 then
								mem.Volatile.DodgeJump = true
								mem.Volatile.NextJumpTime = CurTime() + math.random(15, 25) / 10 
								tacticName = tacticName .. " (СТРИБОК)"
							end

							if math.random() < 0.25 then
								mem.Volatile.DuckUntil = CurTime() + math.random(3, 4) / 10 
								tacticName = tacticName .. " (ПРИСІД)"
							end
							mem.Volatile.NextDodgeTime = CurTime() + math.random(1, 3) / 10
						end

						if DEBUG_STRAFE then
							local dir = (mem.Volatile.DodgeStrafe == -1) and "Вліво" or (mem.Volatile.DodgeStrafe == 1) and "Вправо" or "Прямо"
							local ext = (mem.Volatile.DodgeJump and " + СТРИБОК") or ""
							print("[D3bot Dodge] " .. bot:Nick() .. " vs " .. tacticName .. " | Рух: " .. dir .. ext)
						end
					end
				end

				if not isLookingAtBot or not isVisible then
					mem.Volatile.DodgeStrafe = 0
					mem.Volatile.BackwardUntil = nil
				end

				isBackward = mem.Volatile.BackwardUntil and CurTime() < mem.Volatile.BackwardUntil
				isStrafing = mem.Volatile.DodgeStrafe and mem.Volatile.DodgeStrafe ~= 0
				isDodging = isBackward or isStrafing

				local botWep = bot:GetActiveWeapon()
				local botIsAttacking = false
				
				if IsValid(botWep) then
					if type(botWep.IsSwinging) == "function" and botWep:IsSwinging() then botIsAttacking = true end
					if botWep.GetSwingEndTime and botWep:GetSwingEndTime() > CurTime() then botIsAttacking = true end
					
					if (actions.Attack and distSqr < 10000) or actions.Attack2 then botIsAttacking = true end
				end

				if botIsAttacking then
					if not mem.Volatile.NextAttackManeuverReset or CurTime() > mem.Volatile.NextAttackManeuverReset then
						mem.Volatile.NextAttackManeuverReset = CurTime() + 1
						
						if math.random() < 0.25 then
							mem.Volatile.KeepDodgeDuringAttack = true
							
							if DEBUG_STRAFE then
								print("[D3bot Dodge] " .. bot:Nick() .. " -> АТАКА + СТРЕЙФ! Протягом 1 секунди!")
							end
						else
							mem.Volatile.KeepDodgeDuringAttack = false
						end
					end

					if not mem.Volatile.KeepDodgeDuringAttack then
						isDodging = false
						isBackward = false
						isStrafing = false
						
						mem.Volatile.BackwardUntil = nil
						mem.Volatile.DodgeStrafe = 0
						
						if DEBUG_STRAFE then
							print("[D3bot Dodge] " .. bot:Nick() .. " -> АТАКА! Ухиляння скасовано.")
						end
					end
				else
					mem.Volatile.AttackManeuverDecided = false
					mem.Volatile.KeepDodgeDuringAttack = false
				end

				actions = actions or {}
				
				if isDodging then
					if isBackward then
						forwardSpeed = -10000
						sideSpeed = 0
						actions.MoveForward = nil
						actions.MoveBackward = true
						actions.MoveLeft = nil
						actions.MoveRight = nil
					else
						forwardSpeed = 10000
						actions.MoveForward = true
						actions.MoveBackward = nil
					end
					
					if mem.Volatile.DodgeStrafe == -1 then
						sideSpeed = -10000
						actions.MoveLeft = true
						actions.MoveRight = nil
					elseif mem.Volatile.DodgeStrafe == 1 then
						sideSpeed = 10000
						actions.MoveRight = true
						actions.MoveLeft = nil
					end
				end

				if mem.Volatile.DodgeJump and bot:IsOnGround() then
					actions.Jump = true
					mem.Volatile.DodgeJump = false
				end
				
				if mem.Volatile.DuckUntil and CurTime() < mem.Volatile.DuckUntil then
					actions.Duck = true
				else
					actions.Duck = false
				end
			end
		end
	end

	local buttons
	if actions then
		buttons = bit.bor(actions.MoveForward and IN_FORWARD or 0, actions.MoveBackward and IN_BACK or 0, actions.MoveLeft and IN_MOVELEFT or 0, actions.MoveRight and IN_MOVERIGHT or 0, actions.Attack and IN_ATTACK or 0, actions.Attack2 and IN_ATTACK2 or 0, actions.Attack2Hold and IN_ATTACK2 or 0, actions.Reload and IN_RELOAD or 0, actions.Duck and IN_DUCK or 0, actions.Jump and IN_JUMP or 0, actions.Use and IN_USE or 0)
	end

	-- Kill stuck bots, but not if they recently spawned at a nest (give them time to move)
	-- Also don't kill baby bots (spawned by Giga Gore/Shadow Child) - they have separate timeout below
	local recentNestSpawn = mem.Volatile.NestSpawnTargetLockTime and mem.Volatile.NestSpawnTargetLockTime > CurTime()
	--if majorStuck and GAMEMODE:GetWaveActive() and not bot:GetZombieClassTable().Boss and not recentNestSpawn and not bot.D3bot_BabyOwner then bot:Kill() end
	if majorStuck and GAMEMODE:GetWaveActive() and not recentNestSpawn then bot:Kill() end

	-- Baby bot stuck timeout: Kill baby bots after 12 seconds of being stuck (e.g., in container glass they can't break)
	if bot.D3bot_BabyOwner then
		if majorStuck then
			-- Start or continue stuck timer
			mem.Volatile.BabyStuckTime = mem.Volatile.BabyStuckTime or CurTime()
			if CurTime() - mem.Volatile.BabyStuckTime > 12 then
				-- Baby has been stuck for 12+ seconds, kill it
				bot:Kill()
			end
		else
			-- Not stuck, reset timer
			mem.Volatile.BabyStuckTime = nil
		end
	end

	if aimAngle then bot:SetEyeAngles(aimAngle)	cmd:SetViewAngles(aimAngle) end
	if forwardSpeed then cmd:SetForwardMove(forwardSpeed) end
	if sideSpeed then cmd:SetSideMove(sideSpeed) end
	if upSpeed then cmd:SetUpMove(upSpeed) end
	cmd:SetButtons(buttons)

	-- ====================================================================
    -- АБСОЛЮТНИЙ ДЕБАГ ІНПУТІВ (Що реально йде в рушій Source)
    -- ====================================================================
    if DEBUG_KEYS then
        local isDodging = (mem.Volatile.BackwardUntil and CurTime() < mem.Volatile.BackwardUntil) or (mem.Volatile.DodgeStrafe and mem.Volatile.DodgeStrafe ~= 0)
        
        if isDodging then
            local finalBtns = cmd:GetButtons()
            local finalFwd = cmd:GetForwardMove()
            local finalSide = cmd:GetSideMove()
            
            -- Розшифровуємо бітову маску кнопок
            local inW = bit.band(finalBtns, IN_FORWARD) ~= 0 and "W" or "_"
            local inS = bit.band(finalBtns, IN_BACK) ~= 0 and "S" or "_"
            local inA = bit.band(finalBtns, IN_MOVELEFT) ~= 0 and "A" or "_"
            local inD = bit.band(finalBtns, IN_MOVERIGHT) ~= 0 and "D" or "_"
            local inM1 = bit.band(finalBtns, IN_ATTACK) ~= 0 and "M1" or "_"
            
            print(string.format("[INPUT] %s | FwdMove: %6.0f | SideMove: %6.0f | Кнопки: [%s %s %s %s %s]",
                bot:Nick(), finalFwd, finalSide, inW, inS, inA, inD, inM1
            ))
        end
    end
end

-- Helper functions moved to D3bot.ZS in sv_zs_utilities.lua
-- Local aliases for shared functions (for convenience and performance)
local GetFleshCreeperIndex = D3bot.ZS.GetFleshCreeperIndex
local CountFleshCreeperBots = D3bot.ZS.CountFleshCreeperBots
local CanBecomeFleshCreeper = D3bot.ZS.CanBecomeFleshCreeper
local CountOwnBuiltNests = D3bot.ZS.CountOwnBuiltNests
local CountAllBuiltNests = D3bot.ZS.CountAllBuiltNests
local AnySigilCorrupted = D3bot.ZS.AnySigilCorrupted
local HasAnyNests = D3bot.ZS.HasAnyNests
local FindNearestBuiltNest = D3bot.ZS.FindNearestBuiltNest
local FindHumansNearPosition = D3bot.ZS.FindHumansNearPosition
local FindUncorruptedSigils = D3bot.ZS.FindUncorruptedSigils
local FindNearestSigil = D3bot.ZS.FindNearestSigil
local IsSigilCorrupted = D3bot.ZS.IsSigilCorrupted

-- Helper: Select best target for a bot that spawned at a nest
-- Uses bot.NestSpawnBehavior flag:
--   "attack_humans" (90%): Target humans near nest
--   "attack_sigil" (10%): Target sigil NOT near humans
local function SelectNestSpawnTarget(bot, nestPos)
	local behavior = bot.NestSpawnBehavior or "attack_humans"

	-- Find humans near the nest
	local humansNearNest = FindHumansNearPosition(nestPos, 2500)

	-- Find the nearest sigil to the nest
	local nearestSigil, sigilDistSqr = FindNearestSigil(nestPos)

	-- Check if nearest sigil is corrupted (green) - use safe wrapper
	local nearestSigilCorrupted, _ = IsSigilCorrupted(nearestSigil)

	-- Find all uncorrupted (blue) sigils
	local blueSigils = FindUncorruptedSigils(nestPos)

	-- BEHAVIOR: attack_sigil - Target sigil NOT near humans
	if behavior == "attack_sigil" then
		if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> Behavior: attack_sigil") end

		-- Find a blue sigil that has NO humans nearby
		for _, sigilData in ipairs(blueSigils) do
			local sigilPos = sigilData.sigil:GetPos()
			local humansNearSigil = FindHumansNearPosition(sigilPos, 1500)
			if #humansNearSigil == 0 then
				if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> Targeting empty sigil (no humans nearby)") end
				return sigilData.sigil, "sigil_no_humans"
			end
		end

		-- All sigils have humans, just target nearest blue sigil anyway
		if #blueSigils > 0 then
			if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> All sigils have humans, targeting nearest blue sigil") end
			return blueSigils[1].sigil, "blue_sigil_fallback"
		end

		-- No blue sigils, fall through to human targeting
		if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> No blue sigils, falling back to human targeting") end
	end

	-- BEHAVIOR: attack_humans (90%) - Target humans near nest
	if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> Behavior: attack_humans (90%)") end

	-- If there are humans near the nest, target the closest one
	if #humansNearNest > 0 then
		if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> Targeting human near nest:", humansNearNest[1].ply:Nick()) end
		return humansNearNest[1].ply, "human_near_nest"
	end

	-- No humans near nest, find humans near any blue sigil
	for _, sigilData in ipairs(blueSigils) do
		local sigilPos = sigilData.sigil:GetPos()
		local humansNearSigil = FindHumansNearPosition(sigilPos, 1500)
		if #humansNearSigil > 0 then
			if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> Targeting human near blue sigil:", humansNearSigil[1].ply:Nick()) end
			return humansNearSigil[1].ply, "human_near_blue_sigil"
		end
	end

	-- No humans near any sigil, target any human
	local allHumans = D3bot.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN))
	if #allHumans > 0 then
		local target = table.Random(allHumans)
		if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> Targeting random human:", target:Nick()) end
		return target, "random_human_fallback"
	end

	-- If nearest sigil is uncorrupted (blue), target it as last resort
	if nearestSigil and not nearestSigilCorrupted then
		if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> No humans found, targeting sigil near nest") end
		return nearestSigil, "sigil_near_nest"
	end

	if DEBUG_NEST_TARGET then print("[D3bot NestTarget]", bot:Nick(), "-> No valid target found") end
	return nil, nil
end

---Called every frame.
---@param bot GPlayer
function HANDLER.ThinkFunction(bot)
	local mem = bot.D3bot_Mem

	local botPos = bot:GetPos()

	-- Nest spawn targeting: Check if bot just spawned near a nest
	-- This runs once per spawn to set initial target based on NestSpawnBehavior flag
	if not mem.Volatile.NestSpawnChecked then
		mem.Volatile.NestSpawnChecked = true  -- Only check once per life
		mem.Volatile.NestSpawnCheckTime = CurTime()  -- Track when check happened to prevent double-reset

		-- Check if bot has NestSpawnBehavior flag (set by handle.lua)
		local hasBehaviorFlag = bot.NestSpawnBehavior ~= nil

		-- Find the nearest built nest to the bot
		local nearestNest, nestDistSqr = FindNearestBuiltNest(botPos)

		-- If spawned within 500 units of a nest OR has behavior flag, use nest-based targeting
		if (nearestNest and nestDistSqr < 500 * 500) or hasBehaviorFlag then
			local nestPos = nearestNest and nearestNest:GetPos() or botPos
			local target, targetType = SelectNestSpawnTarget(bot, nestPos)

			-- Clear the behavior flag after using it
			bot.NestSpawnBehavior = nil

			if target then
				bot:D3bot_SetTgtOrNil(target, false, nil)
				bot:D3bot_UpdatePath(nil, nil)

				-- Validate path was created successfully
				if not mem.NextNodeOrNil and not mem.RemainingNodes then
					-- Path failed - don't lock, let normal targeting take over
					mem.Volatile.NestSpawnTarget = nil
					mem.Volatile.NestSpawnTargetType = nil
					mem.Volatile.NestSpawnTargetLockTime = nil
				else
					mem.Volatile.NestSpawnTarget = target
					mem.Volatile.NestSpawnTargetType = targetType
					-- Lock target for 5 seconds to prevent other logic from overriding
					mem.Volatile.NestSpawnTargetLockTime = CurTime() + 5
				end
			end
		else
			-- No nest spawn, clear the flag if any
			bot.NestSpawnBehavior = nil
		end
	end

	-- If bot has a locked nest spawn target, don't let other targeting override it
	local hasLockedNestTarget = mem.Volatile.NestSpawnTargetLockTime and mem.Volatile.NestSpawnTargetLockTime > CurTime()
	if hasLockedNestTarget then
		-- Check if the locked target is still valid
		if not IsValid(mem.Volatile.NestSpawnTarget) or (mem.Volatile.NestSpawnTarget.Alive and not mem.Volatile.NestSpawnTarget:Alive()) then
			-- Target died or became invalid, unlock early
			mem.Volatile.NestSpawnTargetLockTime = nil
			mem.Volatile.NestSpawnTarget = nil
			mem.Volatile.NestSpawnTargetType = nil
			hasLockedNestTarget = false
		end

		-- Check if bot has no valid path (stuck from spawn)
		if hasLockedNestTarget and not mem.NextNodeOrNil and not mem.NodeOrNil then
			mem.Volatile.NestSpawnTargetLockTime = nil
			mem.Volatile.NestSpawnTarget = nil
			mem.Volatile.NestSpawnTargetType = nil
			hasLockedNestTarget = false
		end

		-- Check if bot hasn't moved much since spawn (stuck detection)
		if hasLockedNestTarget then
			if not mem.Volatile.NestSpawnStartPos then
				mem.Volatile.NestSpawnStartPos = botPos
				mem.Volatile.NestSpawnStartTime = CurTime()
			elseif CurTime() - mem.Volatile.NestSpawnStartTime > 3 then  -- After 3 seconds
				local distMoved = botPos:Distance(mem.Volatile.NestSpawnStartPos)
				if distMoved < 50 then  -- Hasn't moved 50 units in 3 seconds
					mem.Volatile.NestSpawnTargetLockTime = nil
					mem.Volatile.NestSpawnTarget = nil
					mem.Volatile.NestSpawnTargetType = nil
					mem.Volatile.NestSpawnStartPos = nil
					mem.Volatile.NestSpawnStartTime = nil
					hasLockedNestTarget = false
				end
			end
		end
	end

	-- NOTE: Suicide triggers for Flesh Creeper class switching have been REMOVED.
	-- Rule: Bots can ONLY become Flesh Creeper through NATURAL death (killed by human),
	-- not by suiciding to switch class. The 80% chance is handled in handle.lua PlayerDeath hook.
	-- This prevents unexpected random suicides when nests are destroyed or sigils corrupted.

	--------------------------------------------------------------------------------
	-- BEHAVIOR STATE MANAGEMENT: Barricade Ambush (triggers when wave countdown reaches last 10 seconds)
	-- Only active on standard ZS maps (not ZE or Objective maps)
	-- Behavior: Retreat and hide behind wall/corner, wait for human within 150 units, then ATTACK!
	-- Has 30 second timeout, then returns to normal and can try again
	--------------------------------------------------------------------------------
	if IsStandardZSMap() and not bot:GetZombieClassTable().Boss then
		-- Check behavior state periodically (every 0.5 seconds)
		if (mem.Volatile.NextBehaviorCheck or 0) <= CurTime() then
			mem.Volatile.NextBehaviorCheck = CurTime() + 0.5

			local currentState = mem.Volatile.BehaviorState or "normal"
			local currentWave = GAMEMODE:GetWave()

			-- Get positions of nearby humans
			local humanPositions = {}
			local nearestHumanDist = math.huge
			for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
				if IsValid(pl) and pl:Alive() and pl:GetObserverMode() == OBS_MODE_NONE then
					local humanPos = pl:GetPos()
					table.insert(humanPositions, humanPos)
					local dist = botPos:Distance(humanPos)
					if dist < nearestHumanDist then
						nearestHumanDist = dist
					end
				end
			end

			-- BARRICADE TRIGGER: Ambush when wave countdown reaches last 10 seconds
			-- Don't enter ambush if already in true melee range (within 50 units of human)
			if ShouldTriggerBarricadeAmbush(bot) and currentState == "normal" and not mem.Volatile.AmbushTriggered and nearestHumanDist > HANDLER.BarricadeSkipRange then
				-- Mark which wave this ambush started in
				mem.Volatile.AmbushTriggered = true
				mem.Volatile.AmbushWave = currentWave
				mem.Volatile.AmbushStartTime = CurTime()
				mem.Volatile.BehaviorState = "ambush"
				mem.Volatile.AmbushPosition = nil  -- Don't set position yet, will search with delay
				mem.Volatile.AmbushSearchNextTime = CurTime() + HANDLER.AmbushSearchDelay  -- Delay before first search
				if DEBUG_BEHAVIOR then print("[D3bot Behavior]", bot:Nick(), "-> State: AMBUSH (wave", currentWave, "ending in", math.floor(GAMEMODE:GetWaveEnd() - CurTime()), "sec)") end

			-- Mark as triggered even if too close to ambush (prevents re-checking this wave)
			elseif ShouldTriggerBarricadeAmbush(bot) and currentState == "normal" and not mem.Volatile.AmbushTriggered and nearestHumanDist <= HANDLER.BarricadeSkipRange then
				mem.Volatile.AmbushTriggered = true
				mem.Volatile.AmbushWave = currentWave
				if DEBUG_BEHAVIOR then print("[D3bot Behavior]", bot:Nick(), "-> Too close to humans (" .. math.floor(nearestHumanDist) .. " units), skipping ambush this wave") end

			-- Search for hiding spot with delay (only if in ambush and no position yet)
			elseif currentState == "ambush" and not mem.Volatile.AmbushPosition and mem.Volatile.AmbushSearchNextTime and CurTime() >= mem.Volatile.AmbushSearchNextTime then
				-- Search for a safe hiding spot away from barricades
				if #humanPositions > 0 then
					local safeSpot = FindSafeHidingSpot(bot, humanPositions)
					if safeSpot then
						mem.Volatile.AmbushPosition = safeSpot
						mem.Volatile.AmbushSearchNextTime = nil  -- Stop searching
						if DEBUG_BEHAVIOR then print("[D3bot Behavior]", bot:Nick(), "-> Hiding spot found (away from barricades)") end
					else
						-- No safe spot found, try again after delay
						mem.Volatile.AmbushSearchNextTime = CurTime() + HANDLER.AmbushSearchDelay
						if DEBUG_BEHAVIOR then print("[D3bot Behavior]", bot:Nick(), "-> Searching for safe hiding spot...") end
					end
				end

			-- Check if ambush should end (only after hiding spot is found)
			elseif currentState == "ambush" and mem.Volatile.AmbushPosition then
				local shouldEndAmbush = false
				local endReason = ""
				local allowRetry = false

				-- End if bot can SEE a human (line of sight) - ATTACK!
				-- Uses MASK_SHOT so barricades/props also block sight
				local canSeeHuman = false
				local seenHumanDist = math.huge
				for _, human in ipairs(team.GetPlayers(TEAM_SURVIVOR)) do
					if IsValid(human) and human:Alive() then
						local humanPos = human:GetPos()
						-- Trace from bot's eye level to human
						local tr = util.TraceLine({
							start = botPos + Vector(0, 0, 48),  -- Bot eye height
							endpos = humanPos + Vector(0, 0, 48),  -- Human eye height
							filter = {bot, human},  -- Ignore bot and target human
							mask = MASK_SHOT  -- Blocked by world AND props/barricades
						})
						-- If trace didn't hit anything, bot can see the human
						if not tr.Hit then
							canSeeHuman = true
							local dist = botPos:Distance(humanPos)
							if dist < seenHumanDist then
								seenHumanDist = dist
							end
						end
					end
				end

				if canSeeHuman then
					shouldEndAmbush = true
					endReason = "human in sight (" .. math.floor(seenHumanDist) .. " units) - ATTACK!"
				-- Timeout after 30 seconds - return to normal and allow retry
				elseif mem.Volatile.AmbushStartTime and CurTime() - mem.Volatile.AmbushStartTime > HANDLER.BarricadeAmbushTimeout then
					shouldEndAmbush = true
					endReason = "ambush timeout (" .. HANDLER.BarricadeAmbushTimeout .. " sec) - will try again"
					allowRetry = true
				end

				if shouldEndAmbush then
					mem.Volatile.BehaviorState = "normal"
					mem.Volatile.AmbushPosition = nil
					mem.Volatile.AmbushStartTime = nil
					mem.Volatile.AmbushSearchNextTime = nil
					-- Allow retry on timeout so bot can ambush again
					if allowRetry then
						mem.Volatile.AmbushTriggered = nil
					end
					if DEBUG_BEHAVIOR then print("[D3bot Behavior]", bot:Nick(), "-> State: NORMAL -", endReason) end
				end

			-- Timeout check even if no hiding spot found (prevent infinite searching)
			elseif currentState == "ambush" and not mem.Volatile.AmbushPosition then
				if mem.Volatile.AmbushStartTime and CurTime() - mem.Volatile.AmbushStartTime > HANDLER.BarricadeAmbushTimeout then
					mem.Volatile.BehaviorState = "normal"
					mem.Volatile.AmbushPosition = nil
					mem.Volatile.AmbushStartTime = nil
					mem.Volatile.AmbushSearchNextTime = nil
					mem.Volatile.AmbushTriggered = nil  -- Allow retry
					if DEBUG_BEHAVIOR then print("[D3bot Behavior]", bot:Nick(), "-> State: NORMAL - search timeout, will try again") end
				end
			end

			-- Reset ambush trigger when a new wave starts (allows re-ambush next wave end)
			if mem.Volatile.AmbushWave and currentWave > mem.Volatile.AmbushWave then
				mem.Volatile.AmbushTriggered = nil
				mem.Volatile.AmbushWave = nil
				mem.Volatile.AmbushTimeMultiplier = nil 
			end
		end
	end

	-- Only update surrounding players target if we don't have a locked nest spawn target
	if not hasLockedNestTarget then
		if mem.nextUpdateSurroundingPlayers and mem.nextUpdateSurroundingPlayers < CurTime() or not mem.nextUpdateSurroundingPlayers then
			mem.nextUpdateSurroundingPlayers = CurTime() + 0.9 + math.random() * 0.2
			
			local currentTarget = mem.TgtOrNil
			local hasValidTarget = IsValid(currentTarget)
			local distToCurrentSqr = hasValidTarget and botPos:DistToSqr(currentTarget:GetPos()) or math.huge
			
			-- Check if bot is "fixed" on current target (distance < 250)
			local isFixed = hasValidTarget and distToCurrentSqr <= math.pow(HANDLER.BotTgtFixationDistMin, 2)

			local targets = player.GetAll()
			table.sort(targets, function(a, b) return botPos:DistToSqr(a:GetPos()) < botPos:DistToSqr(b:GetPos()) end)
			
			for k, v in ipairs(targets) do
				if IsValid(v) and HANDLER.CanBeTgt(bot, v) then
					local distToNewSqr = botPos:DistToSqr(v:GetPos())
					
					if not isFixed then
						-- OLD LOGIC: If not fixed, grab anyone within 500 units
						if distToNewSqr < 500 * 500 and bot:D3bot_CanSeeTarget(nil, v) then
                            bot:D3bot_SetTgtOrNil(v, false, nil)
                            mem.nextUpdateSurroundingPlayers = CurTime() + 5
                            break
                        end
					else
						-- NEW LOGIC: We ARE fixed, but this new guy is VERY close (< 150 units) AND closer than our current target
						if v ~= currentTarget and distToNewSqr < distToCurrentSqr then
							if bot:D3bot_CanSeeTarget(nil, v, true) then -- ignoreBarricades = true
                                bot:D3bot_SetTgtOrNil(v, false, nil)
                                --bot:D3bot_UpdatePath(nil, nil)
                                mem.nextUpdateSurroundingPlayers = CurTime() + 5
                                break
                            end
						end
					end
				end
				-- Only check the 3 closest players to save CPU performance
				if k > 3 then break end
			end
		end
	end

	-- Only reroll target if we don't have a locked nest spawn target
	if not hasLockedNestTarget then
		if mem.nextCheckTarget and mem.nextCheckTarget < CurTime() or not mem.nextCheckTarget then
			mem.nextCheckTarget = CurTime() + 0.9 + math.random() * 0.2
			if not HANDLER.CanBeTgt(bot, mem.TgtOrNil) then
				HANDLER.RerollTarget(bot)
			end
		end
	end

	if mem.nextUpdateOffshoot and mem.nextUpdateOffshoot < CurTime() or not mem.nextUpdateOffshoot then
		mem.nextUpdateOffshoot = CurTime() + 0.4 + math.random() * 0.2
		bot:D3bot_UpdateAngsOffshoot(HANDLER.AngOffshoot)
	end

	local pathCostFunction = D3bot.ZS.GetSharedPathCostFunction(bot)

	if mem.nextUpdatePath and mem.nextUpdatePath < CurTime() or not mem.nextUpdatePath then
		mem.nextUpdatePath = CurTime() + 0.9 + math.random() * 0.2
		bot:D3bot_UpdatePath( pathCostFunction, nil )
	end
end

---Called when the bot takes damage.
---@param bot GPlayer
---@param dmg GCTakeDamageInfo
function HANDLER.OnTakeDamageFunction(bot, dmg)
	local attacker = dmg:GetAttacker()
	if not HANDLER.CanBeTgt(bot, attacker) then return end
	local mem = bot.D3bot_Mem

	-- Don't change target if we have a locked nest spawn target
	if mem.Volatile.NestSpawnTargetLockTime and mem.Volatile.NestSpawnTargetLockTime > CurTime() then return end
    
    -- If already fixed on a player, check if the new attacker is significantly closer
    if IsValid(mem.TgtOrNil) and mem.TgtOrNil:IsPlayer() then
        local currentDist = bot:GetPos():DistToSqr(mem.TgtOrNil:GetPos())
        local newDist = bot:GetPos():DistToSqr(attacker:GetPos())
        
        -- Only switch if current target is far and new one is very close
        if currentDist <= math.pow(HANDLER.BotTgtFixationDistMin, 2) and newDist > currentDist then 
            return 
        end
    end

	mem.TgtOrNil = attacker
	--bot:Say("Ouch! Fuck you "..attacker:GetName().."! I'm gonna kill you!")
end

---Called when the bot damages something.
---@param bot GPlayer -- The bot that caused the damage.
---@param ent GEntity -- The entity that took damage.
---@param dmg GCTakeDamageInfo -- Information about the damage.
function HANDLER.OnDoDamageFunction(bot, ent, dmg)
	local mem = bot.D3bot_Mem

	-- If the zombie hits a barricade prop, store that hit position for the next attack.
	if ent and ent:IsValid() and ent:D3bot_IsBarricade() then
		mem.BarricadeAttackEntity, mem.BarricadeAttackPos = ent, dmg:GetDamagePosition()
	end

	--ClDebugOverlay.Sphere(GetPlayerByName("D3"), dmg:GetDamagePosition(), 2, 1, Color(255,255,255), false)
	--bot:Say("Gotcha!")
end

---Called when the bot dies.
function HANDLER.OnDeathFunction(bot)
    bot.DeathClass = D3bot.ZS.GetSmartClassIndex(bot)
    HANDLER.RerollTarget(bot)
end

-----------------------------------
-- Custom functions and settings --
-----------------------------------

local potTargetEntClasses = {"prop_*turret", "prop_arsenalcrate", "prop_ressuplybox", "prop_remantler", "prop_manhack*", "prop_obj_sigil"}
local potEntTargets = nil

---Returns whether a target is valid.
---@param bot GPlayer
---@param target GPlayer|GEntity|any
function HANDLER.CanBeTgt(bot, target)
	if not target or not IsValid(target) then return end

	-- Can target humans
	if target:IsPlayer() and target ~= bot and target:Team() ~= TEAM_UNDEAD and target:GetObserverMode() == OBS_MODE_NONE and not target:IsFlagSet(FL_NOTARGET) and target:Alive() then return true end

	-- Can target uncorrupted sigils (blue sigils) - use safe wrapper
	if target:GetClass() == "prop_obj_sigil" then
		local corrupted, _ = IsSigilCorrupted(target)
		if corrupted then
			return false -- Don't target corrupted (green) sigils
		end
		return true -- Target uncorrupted sigils
	end

	-- Can target other entity types in potEntTargets list
	if potEntTargets and table.HasValue(potEntTargets, target) then return true end

	return false
end

---Rerolls the bot's target.
---@param bot GPlayer
function HANDLER.RerollTarget(bot)
	-- Get humans or non zombie players or any players in this order.
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

-- ====================================================================
-- ДЕБАГ: ТЕСТ АНІМАЦІЇ НА ГРАВЦЕВІ
-- ====================================================================
concommand.Add("d3bot_test_dance", function(ply, cmd, args)
    if not IsValid(ply) then return end
    
    local taunt = "taunt_dance"
    local seqID = ply:LookupSequence(taunt)
    
    if seqID and seqID > 0 then
        ply:ChatPrint("Знайдено секвенцію " .. taunt .. " з ID: " .. seqID)
        
        -- 1. Спроба програти на сервері (як ми робили боту)
        ply:AddVCDSequenceToGestureSlot(GESTURE_SLOT_CUSTOM, seqID, 0, true)
        
        -- 2. Спроба примусово змусити твій клієнт це побачити (як ми робили боту)
        local code = string.format([[
            local p = Entity(%d)
            if IsValid(p) then
                p:AddVCDSequenceToGestureSlot(5, %d, 0, true)
            end
        ]], ply:EntIndex(), seqID)
        BroadcastLua(code)
        
        ply:ChatPrint("Ти маєш танцювати прямо зараз! (Перевір від 3-ї особи)")
    else
        ply:ChatPrint("Помилка: Твоя поточна модель не має анімації " .. taunt .. "!")
    end
end)
-- ====================================================================