print("[D3bot] Loading undead_fleshcreeper.lua handler...")

-- Fleshcreeper Bot Handler
-- Logic:
-- 1. Find a sigil with humans nearby (or use human positions if no sigils exist)
-- 2. Don't build nests in front of barricaded props with nails
-- 3. Build 2 zombie nests along D3bot path to humans (400-1000 units from target), stay still until complete
-- 4. If can't build, move around/back from humans (and sigil if exists)
-- 5. Once 2 nests built: 90% switch to attack class, 10% stay as Flesh Creeper and attack
-- 6. If nests destroyed, swap back to Fleshcreeper and rebuild
-- 7. If sigil turns green (corrupted), destroy ANY nests near that green sigil (within 1500 units)
-- 8. Repeat
--
-- COMPATIBILITY:
-- This handler is compatible with ZS versions that don't have sigils.
-- When no sigils exist (prop_obj_sigil), the bot will:
--   - Use human positions as reference points for nest building
--   - Find build positions based on D3bot pathing from zombie spawns to humans
--   - Back off from humans instead of sigils when repositioning
-- The IsSigilCorrupted() wrapper safely handles sigils without the GetSigilCorrupted method.

D3bot.Handlers.Undead_Fleshcreeper = D3bot.Handlers.Undead_Fleshcreeper or {}
local HANDLER = D3bot.Handlers.Undead_Fleshcreeper

-- IMPORTANT: This must be false to be selected before the fallback handler
HANDLER.Fallback = false

-- Configuration
HANDLER.MaxFleshCreeperBots = 1 -- Maximum number of Flesh Creeper bots allowed at once
HANDLER.NestsRequired = 2 -- Number of nests to build before switching (global limit is 2, personal limit is 2)
HANDLER.BarricadeAvoidDistance = 150 -- Distance to avoid barricades when building
HANDLER.GasAvoidDistance = 500 -- Distance to avoid zombie gas when building (increased to prevent stuck)
HANDLER.OpportunisticBuildDistance = 700 -- If within this distance of human while moving, build immediately at current position

-- Gas-aware nest placement (coroutine-based strategic positioning)
HANDLER.GasAwarePlacement = true -- Enable gas-aware nest placement scoring
HANDLER.GasComplementaryMinDist = 500 -- Minimum distance from gas for complementary coverage
HANDLER.GasComplementaryMaxDist = 1200 -- Maximum distance for ideal complementary coverage
HANDLER.GasComplementaryIdealDist = 800 -- Ideal distance from gas for best scoring

-- Barricade damage effectiveness rankings (higher = better at destroying barricades)
-- Used when humans are behind barricades
HANDLER.BarricadePriority = {
	-- Best barricade destroyers (have MeleeDamageVsProps or high damage)
	-- NOTE: No bosses in this list - bosses come from game's forceboss system only
	["Zombie Gore Blaster"] = 100, -- MeleeDamageVsProps = 28
	["Noxious Ghoul"] = 85,        -- MeleeDamageVsProps = 24
	["Lacerator Charging"] = 80,   -- MeleeDamageVsProps = 23
	["Elder Ghoul"] = 75,          -- MeleeDamageVsProps = 22
	-- High damage zombies (good general attackers)
	["Wild Poison Zombie"] = 70,   -- MeleeDamage = 45
	["Super Zombie"] = 68,         -- MeleeDamage = 45
	["Poison Zombie"] = 65,        -- MeleeDamage = 40
	["Wraith"] = 60,               -- MeleeDamage = 43
	["Zombie"] = 55,               -- MeleeDamage = 35
	["Skeletal Shambler"] = 52,    -- MeleeDamage = 33
	["Frigid Revenant"] = 50,      -- MeleeDamage = 32
	["Vile Bloated Zombie"] = 48,  -- MeleeDamage = 32
	["Bloated Zombie"] = 45,       -- MeleeDamage = 31
	["Tormented Wraith"] = 43,     -- Variable damage
	["Shadow Walker"] = 40,        -- MeleeDamage = 30
	["Skeletal Walker"] = 38,      -- MeleeDamage = 27
	["Ghoul"] = 35,                -- MeleeDamage = 23
	["Classic Zombie"] = 33,       -- MeleeDamage = 25
	["Fresh Dead"] = 30,           -- MeleeDamage = 20
	["Agile Dead"] = 28,           -- MeleeDamage = 20
	["Fast Zombie"] = 20,
	["Lacerator"] = 18,
	["Fast Zombie Slingshot"] = 17,
	["Chem Zombie"] = 15,
	["Chem Burster"] = 14,
	["Shadow Lurker"] = 12,
	["Skeletal Lurker"] = 11,
	["Eradicator"] = 10         -- Low priority - can rebuild nests if selected
}

-- Fast attacker priority (used when humans are unreachable/running)
-- Prioritizes speed and mobility over raw damage
HANDLER.FastAttackerPriority = {
	-- Best fast attackers (high speed, climbing, pouncing)
	["Fast Zombie"] = 100,         -- Speed 255, can climb and pounce
	["Lacerator"] = 98,            -- Speed based on Fast Zombie, can climb
	["Lacerator Charging"] = 95,   -- Fast with charging ability
	["Fast Zombie Slingshot"] = 93,
	["Wraith"] = 90,               -- Can phase through, fast
	["Tormented Wraith"] = 88,     -- Wraith variant
	-- Medium speed zombies
	["Frigid Revenant"] = 70,
	["Fresh Dead"] = 65,
	["Agile Dead"] = 63,
	["Ghoul"] = 60,
	["Elder Ghoul"] = 58,
	["Noxious Ghoul"] = 55,
	-- Slower but still mobile
	["Zombie"] = 40,
	["Classic Zombie"] = 38,
	["Shadow Walker"] = 35,
	["Skeletal Walker"] = 33,
	["Shadow Lurker"] = 30,
	["Skeletal Lurker"] = 28,
	-- Slow zombies (low priority for chasing)
	["Bloated Zombie"] = 20,
	["Vile Bloated Zombie"] = 18,
	["Poison Zombie"] = 15,
	["Wild Poison Zombie"] = 13,
	["Super Zombie"] = 10,
	["Zombie Gore Blaster"] = 8        -- Low priority - can rebuild nests if selected
}

-- Attack mode constants for post-build
local ATTACK_MODE_HUMANS = 1
local ATTACK_MODE_BARRICADES = 2
local ATTACK_MODE_SIGILS = 3

-- Bot states (used by coroutine implementation for UpdateBotCmdFunction)
local STATE_FINDING_SIGIL = 1
local STATE_MOVING_TO_BUILD = 2
local STATE_BUILDING = 3
local STATE_ATTACKING = 4
local STATE_DESTROYING_NEST = 5
local STATE_BACKING_OFF = 6
local STATE_FOLLOWING_LEADER = 7
local STATE_REPAIRING_NEST = 8

--------------------------------------------------------------------------------
-- EmmyLua Type Definitions
--------------------------------------------------------------------------------

---@class FleshCreeper_Volatile : table
---Handler-specific volatile state for Flesh Creeper bots. Auto-reset on spawn/death.
---@field FleshcreeperState integer? Current state machine state (STATE_FINDING_SIGIL, STATE_MOVING_TO_BUILD, etc.)
---@field AttackMode integer? Attack mode when in STATE_ATTACKING (ATTACK_MODE_HUMANS, ATTACK_MODE_BARRICADES, ATTACK_MODE_SIGILS)
---@field BuildPosition GVector? Target position where bot is trying to build a nest
---@field TargetSigil GEntity? The sigil entity being targeted for nest building
---@field CorruptedSigil GEntity? Corrupted (green) sigil being processed for nest destruction
---@field NestToDestroy GEntity? Nest entity queued for destruction
---@field NestTooFarDestroy boolean? Flag indicating nest destruction is due to being too far from humans
---@field LeaderBot GPlayer? Reference to the lead Flesh Creeper bot (for follower coordination)
---@field LeaderNest GEntity? The leader's nest entity being helped with
---@field LeaderNestPos GVector? Position of leader's nest
---@field MoveStartTime number? CurTime() when movement to build position started (for timeout detection)
---@field BuildStartTime number? CurTime() when nest building started
---@field BuildFailedAttempts integer? Counter for failed build attempts at current position
---@field LastNestBuiltTime number? CurTime() when last nest was successfully built (for post-build cooldown)
---@field NextNestBuildTime number? CurTime() when next nest build attempt is allowed
---@field NextOpportunisticCheck number? CurTime() for next opportunistic build position check
---@field NextRelocationCheck number? CurTime() for next human relocation check
---@field NestRelocationCooldown number? CurTime() until nest relocation is allowed again
---@field RebuildNearHuman boolean? Flag to prioritize building near humans after nest destruction
---@field RelocateTarget GPlayer? Human player that triggered relocation
---@field RelocateType string? Type of relocation ("green_sigil", "isolated", "blue_uncovered")
---@field StuckCounter integer? Counter for stuck detection cycles
---@field LastMovePos GVector? Last recorded position for stuck detection
---@field LastMoveTime number? CurTime() of last movement check
---@field LastTargetDist number? Last distance to target (for chase detection)
---@field ChasingCounter integer? Counter for unsuccessful chase attempts
---@field StuckAttackEntity GEntity? Entity being attacked while stuck
---@field StuckAttackPos GVector? Position of entity being attacked while stuck
---@field StuckAttackTime number? CurTime() when stuck attack started
---@field StuckNoObstacleTime number? CurTime() when stuck with no visible obstacle
---@field D3botStuckStrafeTime number? CurTime() for D3bot strafe anti-stuck behavior
---@field StuckJumpTime number? CurTime() when stuck jump was initiated
---@field StuckJumpPhase number? 0=jump, 1=forward after jump
---@field NestBlocking boolean? Flag indicating a nest is blocking path
---@field NestBlockingTime number? CurTime() when nest blocking was detected
---@field NestBlockingCycles integer? Counter for cycles blocked by same nest
---@field BlockingNestEntity GEntity? The specific nest entity blocking path
---@field BarricadeBlocking boolean? Flag indicating a barricade is blocking path
---@field BarricadeBlockingTime number? CurTime() when barricade blocking was detected
---@field BarricadeBlockingBuild boolean? Flag to build near blocking barricade
---@field BarricadeBlockPos GVector? Position of blocking barricade for build targeting
---@field PropBlocking boolean? Flag indicating a prop is blocking path
---@field PropBlockingTime number? CurTime() when prop blocking was detected
---@field BackoffEndTime number? CurTime() when backoff state should end
---@field AttackTargetTime number? CurTime() for attack target refresh
---@field FollowUpdateTime number? CurTime() for follower position update
---@field RecentSpawnProtectionTime number? CurTime() until spawn protection expires
---@field PathCostFunction function? Custom path cost function for A* pathfinding
---@field BehaviorCoroutine thread? The coroutine handling bot behavior (when UseCoroutines=true)
---@field InterruptFlag string? Set to interrupt the coroutine ("restart" to restart behavior, "cancel" to stop)
---@field NestToRepair GEntity? Nest entity queued for repair (closest to humans, below health threshold)
---@field NestRepairHealthPercent number? Health percentage (0-1) of the nest being repaired

--------------------------------------------------------------------------------
-- Debug print helper (must be defined before all functions that use it)
local DEBUG_FLESHCREEPER = true    
local DEBUG_STUCK = false 

---Prints debug messages with Flesh Creeper bot identification prefix.
---@param botOrMsg GPlayer|any First argument - either a bot player for identification or a message part
---@param ... any Additional message parts to print
---@return nil
local function DebugPrint(botOrMsg, ...)
	if DEBUG_FLESHCREEPER then
		-- Check if first arg is a bot player - if so, show which Flesh Creeper number
		local prefix = "[FleshCreeper]"
		local args = {...}

		if botOrMsg and type(botOrMsg) == "Player" or (type(botOrMsg) == "table" and botOrMsg.IsPlayer and botOrMsg:IsPlayer()) then
			-- First arg is a bot, determine its number
			local fcNum = "?"
			local fcCount = 0
			for _, ply in ipairs(player.GetAll()) do
				if IsValid(ply) and ply:IsBot() and ply:Alive() and ply:Team() == TEAM_UNDEAD then
					local class = ply:GetZombieClassTable()
					if class and class.Name == "Flesh Creeper" then
						fcCount = fcCount + 1
						if ply == botOrMsg then
							fcNum = tostring(fcCount)
							break
						end
					end
				end
			end
			prefix = "[FleshCreeper " .. fcNum .. "]"
		else
			-- First arg is not a bot, include it in the message
			table.insert(args, 1, botOrMsg)
		end

		print(prefix, unpack(args))
	end
end

---Prints debug messages with Flesh Creeper bot identification prefix.
---@param botOrMsg GPlayer|any First argument - either a bot player for identification or a message part
---@param ... any Additional message parts to print
---@return nil
local function StuckPrint(botOrMsg, ...)
	if DEBUG_STUCK then
		-- Check if first arg is a bot player - if so, show which Flesh Creeper number
		local prefix = "[FleshCreeper]"
		local args = {...}

		if botOrMsg and type(botOrMsg) == "Player" or (type(botOrMsg) == "table" and botOrMsg.IsPlayer and botOrMsg:IsPlayer()) then
			-- First arg is a bot, determine its number
			local fcNum = "?"
			local fcCount = 0
			for _, ply in ipairs(player.GetAll()) do
				if IsValid(ply) and ply:IsBot() and ply:Alive() and ply:Team() == TEAM_UNDEAD then
					local class = ply:GetZombieClassTable()
					if class and class.Name == "Flesh Creeper" then
						fcCount = fcCount + 1
						if ply == botOrMsg then
							fcNum = tostring(fcCount)
							break
						end
					end
				end
			end
			prefix = "[FleshCreeper " .. fcNum .. "]"
		else
			-- First arg is not a bot, include it in the message
			table.insert(args, 1, botOrMsg)
		end

		print(prefix, unpack(args))
	end
end

---Clears stuck detection variables for mid-life resets.
---Note: These are all in mem.Volatile and auto-reset on spawn/death.
---@param mem D3bot_Mem The bot's memory table
---@return nil
local function ClearStuckDetection(mem)
	local vol = mem.Volatile
	vol.LastMovePos = nil
	vol.LastMoveTime = nil
	vol.StuckCounter = nil
	vol.StuckWarningTime = nil
	vol.ChasingCounter = nil
	vol.LastTargetDist = nil
	vol.StuckAttackTime = nil
	vol.NestBlocking = nil
	vol.NestBlockingTime = nil
	vol.BarricadeBlocking = nil
	vol.BarricadeBlockingTime = nil
	vol.PropBlocking = nil
	vol.PropBlockingTime = nil
	vol.D3botStuckStrafeTime = nil
	vol.StuckNoObstacleTime = nil
	vol.StuckJumpTime = nil
	vol.StuckJumpPhase = nil
end

-- Helper functions moved to D3bot.ZS in sv_zs_utilities.lua:
-- D3bot.ZS.IsValidHumanTarget(pl) - Check if a human player is a valid target
-- D3bot.ZS.IsSigilCorrupted(sigil) - Safe wrapper for sigil corruption check
-- D3bot.ZS.SigilsExist() - Check if sigils exist in this gamemode
-- D3bot.ZS.GetClosestHuman(pos) - Get the closest human to a position
-- D3bot.ZS.IsIgnorableProp(ent) - Check if a prop should be ignored
-- D3bot.ZS.GetFleshCreeperIndex() - Get the Flesh Creeper class index
-- D3bot.ZS.GetUnlockedZombieClasses() - Get unlocked zombie classes
-- D3bot.ZS.GetZombieSpawnPoints() - Get zombie spawn points
-- D3bot.ZS.IsNearBarricade(pos, distance) - Check if position is near a barricade
-- D3bot.ZS.IsNearZombieSpawn(pos, distance) - Check if position is near zombie spawn
-- D3bot.ZS.IsNearGas(pos, distance) - Check if position is near gas
-- D3bot.ZS.IsNearHumanPath(pos, pathWidth) - Check if position is on human walking path
-- D3bot.ZS.IsHiddenFromHumans(pos, checkDist) - Check if position is hidden from humans
-- D3bot.ZS.CountAllBuiltNests() - Count all built nests globally
-- D3bot.ZS.FindNearestBuiltNest(pos) - Find the nearest built nest
-- D3bot.ZS.FindUncorruptedSigils(pos) - Find uncorrupted sigils
-- D3bot.ZS.FindNearestSigil(pos) - Find the nearest sigil

-- Local aliases for frequently used shared functions (for convenience and performance)
local IsValidHumanTarget = D3bot.ZS.IsValidHumanTarget
local IsSigilCorrupted = D3bot.ZS.IsSigilCorrupted
local GetClosestHuman = D3bot.ZS.GetClosestHuman
local IsIgnorableProp = D3bot.ZS.IsIgnorableProp

---Selector function - determines if this handler should be used for a bot.
---@param zombieClassName string The zombie class name
---@param team integer The team number
---@return boolean True if this handler should handle the bot (Flesh Creeper on undead team)
function HANDLER.SelectorFunction(zombieClassName, team)
	return team == TEAM_UNDEAD and zombieClassName == "Flesh Creeper"
end

-- Local aliases for more shared functions
local GetUnlockedZombieClasses = D3bot.ZS.GetUnlockedZombieClasses

---Checks if humans are unreachable (running away or no valid path).
---@param bot GPlayer The bot player
---@return boolean True if humans appear unreachable
local function AreHumansUnreachable(bot)
	if not IsValid(bot) then return false end

	local mem = bot.D3bot_Mem
	if not mem then return false end

	-- Check if bot has been stuck trying to reach humans
	if mem.Volatile.StuckCounter and mem.Volatile.StuckCounter >= 3 then
		return true
	end

	-- Check if target is too far away and bot can't find path
	local target = mem.TgtOrNil
	if IsValid(target) and target:IsPlayer() then
		local dist = bot:GetPos():Distance(target:GetPos())
		-- If target is far and we've been chasing for a while without getting closer
		if dist > 1500 and mem.Volatile.LastTargetDist and dist >= mem.Volatile.LastTargetDist then
			mem.Volatile.ChasingCounter = (mem.Volatile.ChasingCounter or 0) + 1
			if mem.Volatile.ChasingCounter >= 5 then
				return true
			end
		else
			mem.Volatile.ChasingCounter = 0
		end
		mem.Volatile.LastTargetDist = dist
	end

	return false
end

local CachedWave = -1
local CachedFastClasses = {}
local CachedTankClasses = {}
local CachedFastTotalWeight = 0
local CachedTankTotalWeight = 0

-- Функція оновлення кешу (викликається ТІЛЬКИ при зміні хвилі)
local function UpdateClassCache()
    local currentWave = GAMEMODE:GetWave() or 1
    if CachedWave == currentWave and #CachedFastClasses > 0 then return end

    CachedWave = currentWave
    CachedFastClasses = {}
    CachedTankClasses = {}
    CachedFastTotalWeight = 0
    CachedTankTotalWeight = 0

    local unlockedClasses = GetUnlockedZombieClasses()

    for _, zombieClass in ipairs(unlockedClasses) do
		local fastPri = HANDLER.FastAttackerPriority[zombieClass.Name] or 20
		if fastPri > 0 then
			table.insert(CachedFastClasses, {index = zombieClass.Index, name = zombieClass.Name, priority = fastPri})
			CachedFastTotalWeight = CachedFastTotalWeight + fastPri
		end

		local tankPri = HANDLER.BarricadePriority[zombieClass.Name] or 20
		if tankPri > 0 then
			table.insert(CachedTankClasses, {index = zombieClass.Index, name = zombieClass.Name, priority = tankPri})
			CachedTankTotalWeight = CachedTankTotalWeight + tankPri
		end
    end

    table.sort(CachedFastClasses, function(a, b) return a.priority > b.priority end)
    table.sort(CachedTankClasses, function(a, b) return a.priority > b.priority end)
end

---Gets a random attack class index using highly optimized cached weighted selection.
---@param prioritizeSpeed boolean True = use FastAttackerPriority, false = use BarricadePriority
---@return integer classIndex The selected zombie class index
local function GetRandomAttackClassIndex(prioritizeSpeed)
    UpdateClassCache()

    local cache = prioritizeSpeed and CachedFastClasses or CachedTankClasses
    local totalWeight = prioritizeSpeed and CachedFastTotalWeight or CachedTankTotalWeight

    if #cache == 0 then
        local defaultClass = GAMEMODE.ZombieClasses[GAMEMODE.DefaultZombieClass]
        return defaultClass and defaultClass.Index or 1
    end

    local roll = math.random() * totalWeight
    local cumulative = 0

    for _, entry in ipairs(cache) do
        cumulative = cumulative + entry.priority
        if roll <= cumulative then
            local mode = prioritizeSpeed and "FastAttacker" or "BarricadeDestroyer"
            DebugPrint("Selected", mode, "class:", entry.name, "with priority:", entry.priority)
            return entry.index
        end
    end

    return cache[1].index
end

---Gets all alive Flesh Creeper bots, sorted by UserID for consistent ordering.
---@return GPlayer[] Array of alive Flesh Creeper bot players
local function GetAllFleshCreeperBots()
	local fleshCreepers = {}
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply:IsBot() and ply:Alive() and ply:Team() == TEAM_UNDEAD then
			local class = ply:GetZombieClassTable()
			if class and class.Name == "Flesh Creeper" then
				table.insert(fleshCreepers, ply)
			end
		end
	end
	-- Sort by UserID to have consistent ordering (for fallback)
	table.sort(fleshCreepers, function(a, b) return a:UserID() < b:UserID() end)
	return fleshCreepers
end

-- Persistent leader storage - leader stays until they die
local CurrentFleshCreeperLeader = nil

-- Track how the leader died (for follower behavior)
-- true = leader suicided after finishing 2 nests → followers should also suicide
-- false = leader was killed by human (or nests incomplete) → follower becomes new leader
local LeaderDiedBySuicideWith2Nests = false

-- Track leader's attack mode and death class for follower mirroring
local LeaderAttackMode = nil
local LeaderDeathClass = nil

---Updates leader state tracking (called when leader changes attack mode or class).
---@param attackMode integer? The attack mode (ATTACK_MODE_HUMANS, etc.)
---@param deathClass integer? The death class index
local function UpdateLeaderState(attackMode, deathClass)
	LeaderAttackMode = attackMode
	LeaderDeathClass = deathClass
	DebugPrint("Leader state updated - AttackMode:", attackMode, "DeathClass:", deathClass)
end

---Gets the leader's current attack mode and death class for follower mirroring.
---@return integer?, integer? attackMode, deathClass
local function GetLeaderState()
	return LeaderAttackMode, LeaderDeathClass
end

---Checks if the current leader is still valid (alive and still a Flesh Creeper).
---@return boolean True if current leader is valid
local function IsLeaderStillValid()
	if not IsValid(CurrentFleshCreeperLeader) then return false end
	if not CurrentFleshCreeperLeader:Alive() then return false end
	if CurrentFleshCreeperLeader:Team() ~= TEAM_UNDEAD then return false end
	local class = CurrentFleshCreeperLeader:GetZombieClassTable()
	if not class or class.Name ~= "Flesh Creeper" then return false end
	return true
end

-- Distance threshold for considering two creepers at "similar" distance (use random selection)
local SIMILAR_DISTANCE_THRESHOLD = 200

---Selects a new leader (whichever creeper is closest to any human via path distance).
---If two creepers are at similar distance (within threshold), randomly choose one.
---@param creepers GPlayer[] Array of Flesh Creeper bot players
---@return GPlayer? The selected leader bot, or nil if no creepers
local function SelectNewLeader(creepers)
	-- Get all valid humans
	local humans = {}
	for _, human in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if IsValidHumanTarget(human) then
			table.insert(humans, human)
		end
	end

	-- If no humans, fallback to random creeper
	if #humans == 0 then
		return table.Random(creepers)
	end

	-- Calculate minimum distance from each creeper to any human
	local creeperDistances = {}
	for _, creeper in ipairs(creepers) do
		local minDist = math.huge
		local creeperPos = creeper:GetPos()

		for _, human in ipairs(humans) do
			local dist = creeperPos:Distance(human:GetPos())
			if dist < minDist then
				minDist = dist
			end
		end

		table.insert(creeperDistances, {creeper = creeper, dist = minDist})
		DebugPrint("SelectNewLeader: Creeper", creeper:Nick(), "distance to human:", math.floor(minDist))
	end

	-- Sort by distance (closest first)
	table.sort(creeperDistances, function(a, b) return a.dist < b.dist end)

	-- Check if top creepers are at similar distance (within threshold)
	if #creeperDistances >= 2 then
		local distDiff = math.abs(creeperDistances[1].dist - creeperDistances[2].dist)
		if distDiff <= SIMILAR_DISTANCE_THRESHOLD then
			-- Similar distance - randomly choose between the closest ones
			local similarCreepers = {creeperDistances[1].creeper, creeperDistances[2].creeper}
			local chosen = table.Random(similarCreepers)
			DebugPrint("SelectNewLeader: Similar distance (diff:", math.floor(distDiff), "), randomly chose:", chosen:Nick())
			return chosen
		end
	end

	local chosen = creeperDistances[1].creeper
	DebugPrint("SelectNewLeader: Closest creeper to human is", chosen:Nick(), "at distance", math.floor(creeperDistances[1].dist))
	return chosen
end

---Gets the lead Flesh Creeper bot (persistent until leader dies).
---@return GPlayer? The lead Flesh Creeper bot, or nil if none exist
local function GetLeadFleshCreeper()
	local creepers = GetAllFleshCreeperBots()
	if #creepers == 0 then
		CurrentFleshCreeperLeader = nil
		return nil
	end
	if #creepers == 1 then
		CurrentFleshCreeperLeader = creepers[1]
		return creepers[1]
	end

	-- Check if current leader is still valid
	if IsLeaderStillValid() then
		-- Make sure leader is still in the creepers list (still a Flesh Creeper bot)
		for _, creeper in ipairs(creepers) do
			if creeper == CurrentFleshCreeperLeader then
				return CurrentFleshCreeperLeader -- Leader is still valid, keep them
			end
		end
	end

	-- Leader is invalid (dead, switched class, or doesn't exist) - select new leader
	local newLeader = SelectNewLeader(creepers)
	CurrentFleshCreeperLeader = newLeader
	DebugPrint("New Flesh Creeper leader selected:", newLeader and newLeader:Nick() or "none")
	return newLeader
end

---Checks if this bot is the lead Flesh Creeper.
---@param bot GPlayer The bot player to check
---@return boolean True if this bot is the leader
local function IsLeadFleshCreeper(bot)
	local leader = GetLeadFleshCreeper()
	return leader == bot
end

---Finds a blue (uncorrupted) sigil to target for nest building.
---Priority 1: Sigil with humans nearby (within 2000 units)
---Priority 2: Any uncorrupted sigil (closest to bot)
---@param bot GPlayer The bot player
---@return GEntity? The target sigil entity, or nil if no sigils exist
local function FindTargetSigil(bot)
	local sigils = ents.FindByClass("prop_obj_sigil")
	local bestSigilWithHumans = nil
	local bestScoreWithHumans = 0
	local closestSigilNoHumans = nil
	local closestDistNoHumans = math.huge
	local botPos = bot:GetPos()

	DebugPrint("FindTargetSigil - Found", #sigils, "sigils")

	-- No sigils in map - return nil (caller handles human-based targeting)
	if #sigils == 0 then
		DebugPrint("FindTargetSigil - No sigils in map, returning nil")
		return nil
	end

	for _, sigil in ipairs(sigils) do
		if not IsValid(sigil) then continue end
		-- Skip corrupted (green) sigils - use safe wrapper
		local corrupted, _ = IsSigilCorrupted(sigil)
		DebugPrint("  Sigil at", sigil:GetPos(), "corrupted:", corrupted)
		if corrupted then continue end

		local sigilPos = sigil:GetPos()
		local distFromBot = botPos:Distance(sigilPos)
		local humanCount = 0
		local closestHumanDist = math.huge

		-- Count humans near this sigil (within 2000 units)
		for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
			if IsValidHumanTarget(pl) then
				local dist = pl:GetPos():Distance(sigilPos)
				if dist < 2000 then
					humanCount = humanCount + 1
					if dist < closestHumanDist then
						closestHumanDist = dist
					end
				end
			end
		end

		DebugPrint("  -> Uncorrupted sigil, humans nearby:", humanCount, "dist from bot:", math.floor(distFromBot))

		if humanCount > 0 then
			-- Priority 1: Sigil with humans nearby
			-- Score based on human presence (more humans = better)
			local distBonus = math.max(0, (3000 - distFromBot) / 30) -- Up to 100 bonus for being close
			local score = humanCount * 100 + (2000 - closestHumanDist) + distBonus

			DebugPrint("  -> Score:", math.floor(score))
			if score > bestScoreWithHumans then
				bestScoreWithHumans = score
				bestSigilWithHumans = sigil
			end
		else
			-- Priority 2: Track closest sigil without humans as fallback
			if distFromBot < closestDistNoHumans then
				closestDistNoHumans = distFromBot
				closestSigilNoHumans = sigil
			end
		end
	end

	local result = bestSigilWithHumans or closestSigilNoHumans
	DebugPrint("FindTargetSigil result:", IsValid(result) and result:GetPos() or "nil")

	-- Return sigil with humans first, then fall back to closest sigil without humans
	return result
end

-- Local aliases for shared functions from sv_zs_utilities.lua
-- Position checking
local IsNearBarricade = D3bot.ZS.IsNearBarricade
local IsNearUnnailedProp = D3bot.ZS.IsNearUnnailedProp
local IsNearZombieSpawn = D3bot.ZS.IsNearZombieSpawn
local IsNearGas = D3bot.ZS.IsNearGas
local IsNearHumanPath = D3bot.ZS.IsNearHumanPath
local IsHiddenFromHumans = D3bot.ZS.IsHiddenFromHumans
local GetZombieSpawnPoints = D3bot.ZS.GetZombieSpawnPoints
local HasClearFloor = D3bot.ZS.HasClearFloor
local IsTooCloseToNest = D3bot.ZS.IsTooCloseToNest
-- Nest functions
local CountOwnBuiltNests = D3bot.ZS.CountOwnBuiltNests
local CountAllBuiltNests = D3bot.ZS.CountAllBuiltNests
local GetAnyBuiltNest = D3bot.ZS.GetAnyBuiltNest
local GetNestNearCorruptedSigil = D3bot.ZS.GetNestNearCorruptedSigil
-- Barricade functions
local FindBarricadesNearPosition = D3bot.ZS.FindBarricadesNearPosition
local FindNearestBarricade = D3bot.ZS.FindNearestBarricade
local IsPathBlockedByBarricade = D3bot.ZS.IsPathBlockedByBarricade
-- Sigil functions
local GetCorruptedSigil = D3bot.ZS.GetCorruptedSigil
local HasUncorruptedSigil = D3bot.ZS.HasUncorruptedSigil
local AreHumansNearSigil = D3bot.ZS.AreHumansNearSigil
local AreHumansNearAnyBlueSigil = D3bot.ZS.AreHumansNearAnyBlueSigil
-- Human targeting functions
local FindHumansNearGreenOrIsolated = D3bot.ZS.FindHumansNearGreenOrIsolated
local FindHumanNotCoveredByNest = D3bot.ZS.FindHumanNotCoveredByNest
-- Gas-aware nest placement functions
local GetGasSpawnerPositions = D3bot.ZS.GetGasSpawnerPositions
local CalculateGasCoverageScore = D3bot.ZS.CalculateGasCoverageScore

-- Blacklist expiry time in seconds (positions become available again after this)
local BLACKLIST_EXPIRY_TIME = 120

---Blacklists a build position so the bot won't try to build there again.
---@param bot GPlayer The bot player
---@param pos GVector Position to blacklist
---@param reason string? Optional reason for blacklisting
local function BlacklistPosition(bot, pos, reason)
	local mem = bot.D3bot_Mem
	if not mem then return end

	mem.BlacklistedBuildPositions = mem.BlacklistedBuildPositions or {}
	table.insert(mem.BlacklistedBuildPositions, {
		pos = pos,
		time = CurTime(),
		reason = reason or "unknown"
	})
	DebugPrint("Blacklisted position:", pos, "reason:", reason or "unknown")
end

---Checks if a position is blacklisted (bot died there multiple times).
---@param bot GPlayer The bot player
---@param pos GVector Position to check
---@return boolean True if position is blacklisted
local function IsPositionBlacklisted(bot, pos)
	local mem = bot.D3bot_Mem
	if not mem or not mem.BlacklistedBuildPositions then return false end

	local currentTime = CurTime()
	local validBlacklist = {}
	local isBlacklisted = false

	for _, entry in ipairs(mem.BlacklistedBuildPositions) do
		if currentTime - entry.time < BLACKLIST_EXPIRY_TIME then
			table.insert(validBlacklist, entry)
			if pos:Distance(entry.pos) < 500 then
				isBlacklisted = true
			end
		end
	end

	mem.BlacklistedBuildPositions = validBlacklist
	return isBlacklisted
end

---Finds a good position to build nest using navmesh PATH DISTANCE.
---Priority 1: Near humans by path distance (but hidden from them)
---Priority 2: Near sigil by path distance
---Priority 3: Near blocking barricade so spawned zombies can attack it
---@param bot GPlayer The bot looking for a build position
---@param targetSigil GEntity? Target sigil entity (can be nil for no-sigil mode)
---@param blockingBarricade GEntity? Barricade blocking the path (triggers barricade-priority mode)
---@return GVector? The best build position, or nil if none found
local function FindBuildPosition(bot, targetSigil, blockingBarricade)
	local botPos = bot:GetPos()
	local mapNavMesh = D3bot.MapNavMesh
	local GetPathDistance = D3bot.ZS.GetPathDistance

	-- Collect all valid humans
	local humans = {}
	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if IsValidHumanTarget(pl) then
			table.insert(humans, {ply = pl, pos = pl:GetPos()})
		end
	end

	if #humans == 0 then
		DebugPrint("FindBuildPosition: No humans found")
		return nil
	end

	-- Get gas spawner positions for gas-aware placement (coroutine-based strategic positioning)
	local gasPositions = nil
	if HANDLER.GasAwarePlacement then
		gasPositions = GetGasSpawnerPositions()
		if #gasPositions > 0 then
			DebugPrint("FindBuildPosition: Found", #gasPositions, "gas spawners for coverage optimization")
		end
	end

	-- Get sigil position if available
	local sigilPos = IsValid(targetSigil) and targetSigil:GetPos() or nil

	-- Get blocking barricade position if available
	local barricadePos = IsValid(blockingBarricade) and blockingBarricade:GetPos() or nil
	if barricadePos then
		DebugPrint("FindBuildPosition: Barricade blocking path at", barricadePos, "- prioritizing positions near barricade")
	end

	-- Helper function to validate a position (returns testPos if valid, nil otherwise)
	-- When barricadeNearby=true, we allow positions near barricades (for barricade-priority mode)
	local function ValidatePosition(testPos, requireHidden, requireOffHumanPath, barricadeNearby)
		-- Trace down to find ground
		local tr = util.TraceLine({
			start = testPos + Vector(0, 0, 100),
			endpos = testPos - Vector(0, 0, 100),
			mask = MASK_SOLID_BRUSHONLY
		})

		if not (tr.Hit and tr.HitWorld) then return nil end

		testPos = tr.HitPos + Vector(0, 0, 10)

		-- Check not too close to humans (match game: GAMEMODE.CreeperNestDistBuild = 420)
		local minHumanDist = 420
		local maxHumanDist = 900
		local closestDist = math.huge

		for _, humanData in ipairs(humans) do
			local dist = humanData.pos:Distance(testPos)
			if dist < closestDist then
				closestDist = dist
			end
			if dist < minHumanDist then
				return nil -- Занадто близько до людини
			end
		end

		if closestDist > maxHumanDist then
			return nil -- Занадто далеко (запобігає циклічному руйнуванню)
		end

		-- Check if position is blacklisted (nest was shot there before)
		if IsPositionBlacklisted(bot, testPos) then return nil end

		-- Check not near barricades, unnailed props, zombie spawns, or gas
		-- Exception: when barricadeNearby=true, we allow positions near barricades
		if not barricadeNearby and IsNearBarricade(testPos, HANDLER.BarricadeAvoidDistance) then return nil end
		if not barricadeNearby and IsNearUnnailedProp(testPos, HANDLER.BarricadeAvoidDistance) then return nil end -- Avoid unnailed props too
		if IsNearZombieSpawn(testPos, 256) then return nil end -- Match game: GAMEMODE.CreeperNestDistBuildZSpawn = 256
		if IsNearGas(testPos, HANDLER.GasAvoidDistance) then return nil end

		-- Check not too close to existing nests (match game: GAMEMODE.CreeperNestDistBuildNest = 192)
		for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
			if IsValid(nest) and testPos:Distance(nest:GetPos()) < HANDLER.MinNestDistance then
				return nil -- Too close to existing nest
			end
		end

		-- ALWAYS check if hidden from humans - nests in line of sight get destroyed quickly
		if not IsHiddenFromHumans(testPos, 1500) then
			return nil -- Position is visible to humans
		end

		-- Check if position is OFF the human walking path (if required)
		-- Nests on human paths get destroyed quickly
		if requireOffHumanPath and IsNearHumanPath(testPos, 150) then
			return nil -- Position is on human walking path
		end

		return testPos
	end

	-- Collect existing nest positions for path-through-nest penalty
	local existingNests = {}
	for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(nest) and nest.GetNestBuilt and nest:GetNestBuilt() then
			table.insert(existingNests, nest:GetPos())
		end
	end

	-- Score a position based on path distance to humans, barricades, and sigils
	-- LOWER path distance to humans = BETTER (but not too close by Euclidean)
	-- When barricadePos is set, prioritize proximity to barricade
	-- HIDDEN positions get bonus
	-- OFF human path positions get bonus
	-- PENALTY for positions that require passing near existing nests
	local function ScorePosition(testPos, isHidden, isOffHumanPath)
		local score = 0

		-- Find shortest PATH distance to any human
		local bestHumanPathDist = math.huge
		for _, humanData in ipairs(humans) do
			local pathDist = GetPathDistance(testPos, humanData.pos)
			if pathDist and pathDist < bestHumanPathDist then
				bestHumanPathDist = pathDist
			end
		end

		-- BARRICADE PRIORITY MODE: When blocked by barricade, prioritize positions near it
		-- so spawned zombies can attack the barricade
		if barricadePos then
			local barricadeDist = testPos:Distance(barricadePos)
			local barricadePathDist = GetPathDistance(testPos, barricadePos)

			-- Ideal range: 200-500 units from barricade (close enough for spawned zombies to attack)
			if barricadeDist >= 200 and barricadeDist <= 500 then
				score = score + 300 -- MAJOR bonus for ideal barricade proximity
				-- Closer to 350 is best
				score = score + math.max(0, 100 - math.abs(barricadeDist - 350) / 2)
			elseif barricadeDist < 200 then
				score = score + 150 -- Still good, very close
			elseif barricadeDist <= 800 then
				score = score + 100 -- Acceptable distance
			end

			-- Additional bonus for short path to barricade
			if barricadePathDist and barricadePathDist < 600 then
				score = score + math.max(0, 100 - barricadePathDist / 6) -- Up to 100 bonus
			end

			-- Human proximity is secondary when in barricade mode
			if bestHumanPathDist < math.huge then
				if bestHumanPathDist >= 400 and bestHumanPathDist <= 1500 then
					score = score + 50 -- Bonus for being near humans too
				end
			end
		else
			-- NORMAL MODE: Primary scoring based on path to humans
			-- This means zombies spawning here can reach humans quickly
			-- AGGRESSIVE: Prefer positions closer to humans (just above 420 game limit)
			if bestHumanPathDist < math.huge then
				-- Ideal range: 420-900 path distance (as close as possible while valid)
				if bestHumanPathDist >= 420 and bestHumanPathDist <= 900 then
					score = score + 200 -- Ideal range bonus
					-- Closer to 450 is best (just above 420 minimum)
					score = score + math.max(0, 100 - math.abs(bestHumanPathDist - 450) / 3)
				elseif bestHumanPathDist > 900 and bestHumanPathDist <= 1500 then
					score = score + 100 -- Acceptable but farther
				elseif bestHumanPathDist > 1500 then
					score = score + 20 -- Too far, low priority
				else
					score = score + 50 -- Too close (< 420 path), invalid
				end
			end
		end

		-- Secondary scoring: Sigil proximity by path (if sigil exists and no barricade priority)
		if sigilPos and not barricadePos then
			local sigilPathDist = GetPathDistance(testPos, sigilPos)
			if sigilPathDist and sigilPathDist < 1500 then
				score = score + math.max(0, 50 - sigilPathDist / 30) -- Up to 50 bonus for being near sigil
			end
		end

		-- MAJOR bonus for hidden positions (humans can't see/shoot the nest)
		if isHidden then
			score = score + 150
		end

		-- Bonus for positions OFF the human walking path (won't be stumbled upon)
		if isOffHumanPath then
			score = score + 100
		end

		-- PENALTY for positions that require passing near existing nests (Option 3)
		-- If a nest is between the bot and the candidate position, the FC might get stuck
		for _, nestPos in ipairs(existingNests) do
			-- Check if nest is roughly between bot and candidate position
			local botToCandidateDist = botPos:Distance(testPos)
			local botToNestDist = botPos:Distance(nestPos)
			local nestToCandidateDist = nestPos:Distance(testPos)

			-- Nest is "between" if it's closer to both bot and candidate than they are to each other
			-- and the sum of distances through nest is close to direct distance (within 200 units tolerance)
			if botToNestDist < botToCandidateDist and nestToCandidateDist < botToCandidateDist then
				local pathThroughNest = botToNestDist + nestToCandidateDist
				-- If going through nest is similar to direct path (within 300 units), it's blocking
				if pathThroughNest < botToCandidateDist + 300 then
					-- Nest is in the way - apply penalty proportional to how "in the way" it is
					local penalty = 150 -- Significant penalty
					score = score - penalty
					DebugPrint("ScorePosition: Nest blocking path to position, penalty:", penalty)
					break -- Only penalize once even if multiple nests
				end
			end
		end

		-- GAS-AWARE NEST PLACEMENT: Score based on complementary coverage with gas spawners
		-- Nests should complement gas clouds, not overlap with them
		if HANDLER.GasAwarePlacement and gasPositions and #gasPositions > 0 then
			local gasScore = CalculateGasCoverageScore(testPos, gasPositions, humans)
			score = score + gasScore
			if gasScore ~= 0 then
				DebugPrint("ScorePosition: Gas coverage score:", gasScore, "for position", testPos)
			end
		end

		return score, bestHumanPathDist
	end

	-- Collect candidate positions from navmesh nodes
	local candidatePositions = {}
	local checkedNodes = {}

	-- BARRICADE PRIORITY MODE: Search for positions near the blocking barricade first
	if barricadePos then
		local barricadeNode = mapNavMesh:GetNearestNodeOrNil(barricadePos)
		if barricadeNode then
			-- Explore nodes around the barricade (within 800 units)
			local nodesToCheck = {barricadeNode}
			local nodeIndex = 1

			while nodeIndex <= #nodesToCheck and nodeIndex <= 40 do -- Limit search
				local node = nodesToCheck[nodeIndex]
				nodeIndex = nodeIndex + 1

				if not checkedNodes[node] then
					checkedNodes[node] = true
					local nodePos = node.Pos

					-- Only consider nodes 200-800 units from barricade
					local distToBarricade = nodePos:Distance(barricadePos)
					if distToBarricade >= 200 and distToBarricade <= 800 then
						-- Must still be 420+ units away from humans
						local tooClose = false
						for _, hData in ipairs(humans) do
							if nodePos:Distance(hData.pos) < 420 then
								tooClose = true
								break
							end
						end

						if not tooClose then
							table.insert(candidatePositions, nodePos)
						end
					end

					-- Add linked nodes to search
					if node.LinkByLinkedNode then
						for linkedNode, _ in pairs(node.LinkByLinkedNode) do
							if not checkedNodes[linkedNode] and linkedNode.Pos:Distance(barricadePos) < 800 then
								table.insert(nodesToCheck, linkedNode)
							end
						end
					end
				end
			end
		end
		DebugPrint("FindBuildPosition: Found", #candidatePositions, "barricade-adjacent candidates")
	end

	-- NORMAL MODE or supplement: Get nodes near humans and along paths to them
	for _, humanData in ipairs(humans) do
		local humanNode = mapNavMesh:GetNearestNodeOrNil(humanData.pos)
		if humanNode then
			-- Explore nodes around humans (within 2000 units)
			local nodesToCheck = {humanNode}
			local nodeIndex = 1

			while nodeIndex <= #nodesToCheck and nodeIndex <= 50 do -- Limit search
				local node = nodesToCheck[nodeIndex]
				nodeIndex = nodeIndex + 1

				if not checkedNodes[node] then
					checkedNodes[node] = true
					local nodePos = node.Pos

					-- Only consider nodes 400+ units away from humans (Euclidean)
					local tooClose = false
					for _, hData in ipairs(humans) do
						if nodePos:Distance(hData.pos) < 400 then
							tooClose = true
							break
						end
					end

					if not tooClose then
						table.insert(candidatePositions, nodePos)
					end

					-- Add linked nodes to search
					if node.LinkByLinkedNode then
						for linkedNode, _ in pairs(node.LinkByLinkedNode) do
							if not checkedNodes[linkedNode] and linkedNode.Pos:Distance(humanData.pos) < 2000 then
								table.insert(nodesToCheck, linkedNode)
							end
						end
					end
				end
			end
		end
	end

	DebugPrint("FindBuildPosition: Found", #candidatePositions, "total candidate nodes to evaluate")

	-- Score all candidates
	local scoredCandidates = {}
	local allowBarricadeNearby = barricadePos ~= nil -- Allow positions near barricades when in barricade mode
	for _, testPos in ipairs(candidatePositions) do
		-- First check if position is valid at all
		local isHidden = IsHiddenFromHumans(testPos, 1500)
		local isOffHumanPath = not IsNearHumanPath(testPos, 150)

		-- Validate basic requirements (barricadeNearby=true when in barricade mode)
		local validPos = ValidatePosition(testPos, false, false, allowBarricadeNearby)
		if validPos then
			local score, humanPathDist = ScorePosition(validPos, isHidden, isOffHumanPath)
			table.insert(scoredCandidates, {
				pos = validPos,
				score = score,
				humanPathDist = humanPathDist,
				isHidden = isHidden,
				isOffHumanPath = isOffHumanPath
			})
		end
	end

	-- Sort by score (highest first)
	table.sort(scoredCandidates, function(a, b) return a.score > b.score end)

	DebugPrint("FindBuildPosition: Scored", #scoredCandidates, "valid candidates")

	-- First pass: Find HIDDEN + OFF-PATH positions (safest)
	for _, candidate in ipairs(scoredCandidates) do
		if candidate.isHidden and candidate.isOffHumanPath then
			DebugPrint("Found HIDDEN+OFF-PATH nest position:", candidate.pos, "score:", candidate.score, "humanPathDist:", math.floor(candidate.humanPathDist))
			return candidate.pos
		end
	end

	-- Second pass: Find HIDDEN positions (still safe)
	for _, candidate in ipairs(scoredCandidates) do
		if candidate.isHidden then
			DebugPrint("Found HIDDEN nest position:", candidate.pos, "score:", candidate.score, "humanPathDist:", math.floor(candidate.humanPathDist))
			return candidate.pos
		end
	end

	-- Third pass: Find OFF-PATH positions (acceptable)
	for _, candidate in ipairs(scoredCandidates) do
		if candidate.isOffHumanPath then
			DebugPrint("Found OFF-PATH nest position:", candidate.pos, "score:", candidate.score, "humanPathDist:", math.floor(candidate.humanPathDist))
			return candidate.pos
		end
	end

	-- Fourth pass: Any valid position with good score
	if #scoredCandidates > 0 then
		local best = scoredCandidates[1]
		DebugPrint("Found nest position (fallback):", best.pos, "score:", best.score, "humanPathDist:", math.floor(best.humanPathDist))
		return best.pos
	end

	-- FALLBACK: Use original direction-based logic if path-based failed
	DebugPrint("FindBuildPosition: Path-based search failed, using direction fallback")

	-- Use closest human as reference
	local referencePos = humans[1].pos
	local targetDir = (referencePos - botPos)
	targetDir.z = 0
	if targetDir:LengthSqr() > 1 then
		targetDir:Normalize()
	else
		targetDir = Vector(1, 0, 0)
	end

	-- Direction-based fallback: search in directions from bot toward humans
	local distances = {600, 700, 800, 900, 1000}
	local angleOffsets = {0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180}

	-- First pass: Hidden positions
	for _, buildDist in ipairs(distances) do
		for _, angleOffset in ipairs(angleOffsets) do
			local rad = math.rad(angleOffset)
			local cosA, sinA = math.cos(rad), math.sin(rad)
			local rotatedDir = Vector(
				targetDir.x * cosA - targetDir.y * sinA,
				targetDir.x * sinA + targetDir.y * cosA,
				0
			)

			local testPos = botPos + rotatedDir * buildDist
			local validPos = ValidatePosition(testPos, true, true) -- hidden + off path
			if validPos then
				DebugPrint("Found HIDDEN direction-based position:", validPos)
				return validPos
			end
		end
	end

	-- Second pass: Visible positions (direction-based)
	for _, buildDist in ipairs(distances) do
		for _, angleOffset in ipairs(angleOffsets) do
			local rad = math.rad(angleOffset)
			local cosA, sinA = math.cos(rad), math.sin(rad)
			local rotatedDir = Vector(
				targetDir.x * cosA - targetDir.y * sinA,
				targetDir.x * sinA + targetDir.y * cosA,
				0
			)

			local testPos = botPos + rotatedDir * buildDist
			local validPos = ValidatePosition(testPos, false, false) -- visible is ok
			if validPos then
				DebugPrint("Found visible direction-based position:", validPos)
				return validPos
			end
		end
	end

	-- Last resort: bot's current position if within valid range of humans
	if #humans > 0 then
		local distToHuman = botPos:Distance(humans[1].pos)
		if distToHuman > 420 and distToHuman < 1200 then
			local validPos = ValidatePosition(botPos, false, false)
			if validPos then
				return validPos
			end
		end
	end

	return nil
end

-- Minimum distance from existing nests
HANDLER.MinNestDistance = 200

-- NOTE: IsTooCloseToNest and HasClearFloor are now provided by D3bot.ZS (sv_zs_utilities.lua)
-- Local aliases are defined above near the other shared function aliases
-- NOTE: BlacklistPosition and IsPositionBlacklisted are defined earlier in this file

---Finds an alternative open build position away from nests and obstacles.
---Searches in expanding rings around the center position.
---Prioritizes positions hidden from humans (behind walls).
---@param bot GPlayer The bot player
---@param centerPos GVector Center position to search from
---@param searchRadius number? Search radius (defaults to 500)
---@return GVector? Best open build position, or nil if none found
local function FindOpenBuildPosition(bot, centerPos, searchRadius)
	searchRadius = searchRadius or 500
	local botPos = bot:GetPos()

	-- Helper function to validate open position
	local function ValidateOpenPosition(groundPos, requireHidden)
		-- Check not too close to any nest
		local tooClose, _ = IsTooCloseToNest(groundPos, HANDLER.MinNestDistance + 50)
		if tooClose then return false end

		-- OPTION 3: Check if position is blacklisted (bot died too many times going there)
		if IsPositionBlacklisted(bot, groundPos) then
			return false
		end

		-- Check not too close to humans (match game: GAMEMODE.CreeperNestDistBuild = 420)
		for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
			if IsValidHumanTarget(pl) and pl:GetPos():Distance(groundPos) < 420 then
				return false
			end
		end

		-- Check not near barricades, unnailed props, zombie spawns, or gas
		if IsNearBarricade(groundPos, HANDLER.BarricadeAvoidDistance) then return false end
		if IsNearUnnailedProp(groundPos, HANDLER.BarricadeAvoidDistance) then return false end -- Avoid unnailed props too
		if IsNearZombieSpawn(groundPos, 256) then return false end -- Match game: GAMEMODE.CreeperNestDistBuildZSpawn = 256
		if IsNearGas(groundPos, HANDLER.GasAvoidDistance) then return false end

		-- ALWAYS check if hidden from humans - nests in line of sight get destroyed quickly
		if not IsHiddenFromHumans(groundPos, 1500) then
			return false
		end

		return true
	end

	-- Find HIDDEN positions only (behind walls)
	for radius = 100, searchRadius, 75 do
		local startAngle = math.random(0, 359)
		for offset = 0, 330, 30 do
			local angle = (startAngle + offset) % 360
			local rad = math.rad(angle)
			local testPos = centerPos + Vector(math.cos(rad) * radius, math.sin(rad) * radius, 0)

			local hasClear, groundPos = HasClearFloor(testPos)
			if hasClear and groundPos and ValidateOpenPosition(groundPos, true) then
				DebugPrint("Found HIDDEN open build position at radius:", radius, "angle:", angle)
				return groundPos
			end
		end
	end

	-- No hidden position found - return nil (don't build in line of sight)
	DebugPrint("FindOpenBuildPosition: No hidden position found, skipping build")
	return nil
end

-- CountOwnBuiltNests now uses D3bot.ZS.CountOwnBuiltNests (aliased above)

---Tags nearby unowned nests with this bot's OwnerUID.
---Only tags UNBUILT nests to prevent new spawns from claiming existing nests.
---@param bot GPlayer The bot player
---@return nil
local function TagNearbyUnownedNests(bot)
	if not IsValid(bot) then return end
	local uid = bot:UniqueID()
	local botPos = bot:GetPos()
	local tagDistance = 150 -- Nests within this distance will be tagged

	for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
		-- Only tag unbuilt nests (still being constructed) that have no owner
		if IsValid(ent) and not ent.OwnerUID and not ent:GetNestBuilt() then
			-- Unowned, unbuilt nest found, check if it's close to this bot
			local dist = ent:GetPos():Distance(botPos)
			if dist < tagDistance then
				ent.OwnerUID = uid
				DebugPrint("Tagged unbuilt nest with OwnerUID:", uid, "at distance:", math.floor(dist))
			end
		end
	end
end

---Gets bot's own nest that needs building.
---@param bot GPlayer The bot player
---@return GEntity? The unbuilt nest entity, or nil if none
local function GetUnbuiltNest(bot)
    local uid = bot:UniqueID()
    local botPos = bot:GetPos()
    for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
        if IsValid(ent) and ent.OwnerUID == uid and not ent:GetNestBuilt() then
            if ent:GetPos():Distance(botPos) < 150 then
                return ent
            end
        end
    end
    return nil
end

---Gets the leader's nest that is being built (unbuilt nest with min progress).
---@param leader GPlayer The leader bot player
---@param minProgressPercent number? Minimum progress % required (defaults to 5)
---@return GEntity? nest The nest entity if found
---@return GVector? pos The nest position if found
local function GetLeaderNestInProgress(leader, minProgressPercent)
	if not IsValid(leader) then return nil, nil end
	local uid = leader:UniqueID()
	minProgressPercent = minProgressPercent or 5  -- Default 5%

	for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(nest) and nest.OwnerUID == uid then
			-- Check if nest is being built (not fully built yet)
			if not nest:GetNestBuilt() then
				local health = nest:GetNestHealth() or 0
				local maxHealth = nest:GetNestMaxHealth() or 200
				local progressPercent = (health / maxHealth) * 100

				if progressPercent >= minProgressPercent then
					return nest, nest:GetPos()
				end
			end
		end
	end
	return nil, nil
end

-- Distance to consider a nest "near" a corrupted sigil
HANDLER.NestCorruptedSigilDistance = 1500

-- NOTE: The following functions are now provided by D3bot.ZS (sv_zs_utilities.lua):
-- GetCorruptedSigil, GetNestNearCorruptedSigil, HasUncorruptedSigil,
-- AreHumansNearSigil, AreHumansNearAnyBlueSigil, FindHumansNearGreenOrIsolated,
-- FindHumanNotCoveredByNest
-- Local aliases are defined above near the other shared function aliases

-- NOTE: GetNestNearCorruptedSigil uses default 1500 distance; to use HANDLER.NestCorruptedSigilDistance,
-- call it as: GetNestNearCorruptedSigil(sigil, HANDLER.NestCorruptedSigilDistance)

-- NOTE: GetAnyNestToDestroy is now GetAnyBuiltNest in D3bot.ZS
local GetAnyNestToDestroy = GetAnyBuiltNest

-- Nest damage threshold for repair (percentage of max health)
local NEST_REPAIR_THRESHOLD = 0.95 -- Repair if below 95% health

---Gets the nest with the closest path distance to any human.
---This nest should be protected from destruction and repaired if damaged.
---@return GEntity? nest The nest closest to humans
---@return number? pathDist The path distance to nearest human
local function GetNestClosestToHumans()
	local nests = ents.FindByClass("prop_creepernest")
	local humans = team.GetPlayers(TEAM_HUMAN)

	if #nests == 0 or #humans == 0 then return nil, nil end

	local bestNest = nil
	local bestDist = math.huge

	for _, nest in ipairs(nests) do
		if IsValid(nest) and nest.GetNestBuilt and nest:GetNestBuilt() then
			local nestPos = nest:GetPos()

			-- Find shortest path distance to any human
			for _, human in ipairs(humans) do
				if IsValid(human) and human:Alive() then
					local pathDist = D3bot.ZS.GetPathDistance(nestPos, human:GetPos())
					if pathDist and pathDist < bestDist then
						bestDist = pathDist
						bestNest = nest
					elseif not pathDist then
						-- Fallback to Euclidean if path fails
						local euclideanDist = nestPos:Distance(human:GetPos()) * 1.1
						if euclideanDist < bestDist then
							bestDist = euclideanDist
							bestNest = nest
						end
					end
				end
			end
		end
	end

	return bestNest, bestDist < math.huge and bestDist or nil
end

---Checks if a nest is damaged and needs repair.
---@param nest GEntity The nest to check
---@return boolean needsRepair True if nest health is below threshold
---@return number? healthPercent Current health percentage (0-1)
local function IsNestDamaged(nest)
	if not IsValid(nest) or not nest.GetNestBuilt or not nest:GetNestBuilt() then
		return false, nil
	end

	local health = nest:GetNestHealth() or 0
	local maxHealth = nest:GetNestMaxHealth() or 200

	if maxHealth <= 0 then return false, nil end

	local healthPercent = health / maxHealth

	return healthPercent < NEST_REPAIR_THRESHOLD, healthPercent
end

---Gets the closest nest to humans if it needs repair.
---@return GEntity? nest The nest needing repair (if any)
---@return number? healthPercent Current health percentage
---@return number? pathDist Path distance to nearest human
function HANDLER.GetClosestNestNeedingRepair()
    local nests = ents.FindByClass("prop_creepernest")
    local humans = team.GetPlayers(TEAM_HUMAN)

    if #nests == 0 or #humans == 0 then 
        return nil, nil, nil 
    end

    local bestNest = nil
    local bestDist = math.huge
    local bestHealthPercent = 1

    for _, nest in ipairs(nests) do
        local needsRepair, healthPercent = IsNestDamaged(nest)
        
        if needsRepair then
            local nestPos = nest:GetPos()
            local minHumanDist = math.huge
            
            for _, human in ipairs(humans) do
                if IsValid(human) and human:Alive() then
                    local pathDist = D3bot.ZS.GetPathDistance(nestPos, human:GetPos())
                    if not pathDist then
                        pathDist = nestPos:Distance(human:GetPos()) * 1.1
                    end
                    
                    if pathDist < minHumanDist then
                        minHumanDist = pathDist
                    end
                end
            end
            
            if minHumanDist < bestDist then
                bestDist = minHumanDist
                bestNest = nest
                bestHealthPercent = healthPercent
            end
        end
    end

    if bestNest then
        return bestNest, bestHealthPercent, bestDist < math.huge and bestDist or nil
    end

    return nil, nil, nil
end

local NEST_TOO_FAR_DISTANCE = 900
local NEST_TOO_FAR_DISTANCE_SQR = NEST_TOO_FAR_DISTANCE * NEST_TOO_FAR_DISTANCE

local function GetFurthestInvalidNest()
    local humans = team.GetPlayers(TEAM_HUMAN)
    if #humans == 0 then return nil end

    local furthestNest = nil
    local maxDistSqr = 0

    for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
        if IsValid(nest) and nest.GetNestBuilt and nest:GetNestBuilt() then
            local nestPos = nest:GetPos()
            local closestHumanDistSqr = math.huge

            for _, human in ipairs(humans) do
                if IsValid(human) and human:Alive() and D3bot.ZS.IsValidHumanTarget(human) then
                    local dist = nestPos:DistToSqr(human:GetPos())
                    if dist < closestHumanDistSqr then
                        closestHumanDistSqr = dist
                    end
                end
            end

            if closestHumanDistSqr >= NEST_TOO_FAR_DISTANCE_SQR and closestHumanDistSqr > maxDistSqr then
                maxDistSqr = closestHumanDistSqr
                furthestNest = nest
            end
        end
    end

    if furthestNest then
        return furthestNest, math.sqrt(maxDistSqr)
    end

    return nil
end

---Updates the bot movement and input commands every frame.
---Handles movement, building inputs, and stuck detection during navigation.
---@param bot GPlayer The bot player entity
---@param cmd GCUserCmd The user command to populate
---@return nil
function HANDLER.UpdateBotCmdFunction(bot, cmd)
	cmd:ClearButtons()
	cmd:ClearMovement()

	-- Fix knocked down bots
	if bot.KnockedDown and IsValid(bot.KnockedDown) or bot.Revive and type(bot.Revive) ~= "function" and IsValid(bot.Revive) then
		return
	end

	if not bot:Alive() then
		cmd:SetButtons(IN_ATTACK)
		return
	end

	local mem = bot.D3bot_Mem

	-- Debug: Check if state was unexpectedly cleared
	if mem.Volatile.FleshcreeperState == nil then
		DebugPrint("WARNING: FleshcreeperState was nil! D3bot_Mem might have been reset.")
	end

	mem.Volatile.FleshcreeperState = mem.Volatile.FleshcreeperState or STATE_FINDING_SIGIL

	-- Skip path updates when building - we want to stay still
	if mem.Volatile.FleshcreeperState ~= STATE_BUILDING then
		bot:D3bot_UpdatePathProgress()
	end

	local result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance

	if mem.Volatile.FleshcreeperState ~= STATE_ATTACKING and mem.Volatile.FleshcreeperState ~= STATE_DESTROYING_NEST then
        local botPos = bot:GetPos()

        if (mem.Volatile.NextThreatCheckTime or 0) < CurTime() then
            mem.Volatile.NextThreatCheckTime = CurTime() + 0.25

            local closestHuman = nil
            local closestDist = math.huge

            for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
                if IsValidHumanTarget(pl) then
                    local dist = botPos:Distance(pl:GetPos())
                    if dist < closestDist then
                        closestDist = dist
                        closestHuman = pl
                    end
                end
            end

            if closestDist < 150 and IsValid(closestHuman) then
                if not mem.Volatile.ThreatResponseUntil or CurTime() > mem.Volatile.ThreatResponseUntil then
                    
                    local attackDuration = math.random(10, 20) / 10 
                    mem.Volatile.ThreatAttackUntil = CurTime() + attackDuration
                    mem.Volatile.ThreatResponseUntil = mem.Volatile.ThreatAttackUntil + 2.0
                    mem.Volatile.ThreatTarget = closestHuman

                    -- "ЗАБУВАЄМО" БУДІВНИЦТВО (як при OnTakeDamage)
                    if mem.Volatile.BuildPosition then
                        BlacklistPosition(bot, mem.Volatile.BuildPosition, "threat_detected")
                    end
                    BlacklistPosition(bot, bot:GetPos(), "threat_pos")
                    
                    mem.Volatile.InterruptFlag = true
                    mem.Volatile.BuildPosition = nil
                    mem.Volatile.BuildStartTime = nil
                    mem.Volatile.TargetSigil = nil
                    mem.Volatile.FleshcreeperState = STATE_FINDING_SIGIL
                    
                    DebugPrint(bot, "ГРАВЕЦЬ ПОРУЧ! СПОЧАТКУ Б'Ю, ПОТІМ ТІКАЮ!")
                end
            end
        end

        -- Виконання послідовної тактики: Бій -> Втеча
        if mem.Volatile.ThreatResponseUntil and CurTime() < mem.Volatile.ThreatResponseUntil then
            local target = mem.Volatile.ThreatTarget
            if IsValid(target) and target:Alive() then
                local botPos = bot:GetPos()
                local threatActions = {}
                local threatForwardSpeed = 10000 -- Завжди премо на повній швидкості
                local threatAimAngle = angle_zero

                -- ПЕРЕВІРКА ФАЗИ: Бій чи Втеча?
                local isFighting = CurTime() < (mem.Volatile.ThreatAttackUntil or 0)

                if isFighting then
                    -- ФАЗА БОЮ: Цілимося в центр гравця і атакуємо
                    local dirTo = target:WorldSpaceCenter() - bot:GetShootPos()
                    threatAimAngle = dirTo:Angle()
                    threatActions.Attack = true
                    threatActions.MoveForward = true
                else
                    -- ФАЗА ВТЕЧІ: Розвертаємось спиною і дьорпаємо в небо
                    local dirAway = botPos - target:GetPos()
                    dirAway.z = 0 
                    dirAway:Normalize()
                    threatAimAngle = dirAway:Angle()
                    threatAimAngle.pitch = -45
                    
                    threatActions.MoveForward = true
                    threatActions.Reload = true
                    threatActions.Jump = true
                end

                local buttons = bit.bor(
                    threatActions.MoveForward and IN_FORWARD or 0,
                    threatActions.Attack and IN_ATTACK or 0,
                    threatActions.Reload and IN_RELOAD or 0,
                    threatActions.Jump and IN_JUMP or 0
                )

                bot:SetEyeAngles(threatAimAngle)
                cmd:SetViewAngles(threatAimAngle)
                cmd:SetForwardMove(threatForwardSpeed)
                cmd:SetSideMove(0)
                cmd:SetUpMove(0)
                cmd:SetButtons(buttons)

                return -- Важливо: перериваємо стандартний рух
            end
        end
    end

	-- State machine logic
	if mem.Volatile.FleshcreeperState == STATE_BUILDING then
		-- Must be on ground to build (weapon's SecondaryAttack requires it)
		if not bot:IsOnGround() then
			-- Wait until we land - just stand still
			cmd:SetForwardMove(0)
			cmd:SetSideMove(0)
			return
		end

		-- Stay still and hold right-click to build
		actions = {}
		actions.Attack2 = true -- Hold secondary attack to build

		-- Manually trigger weapon's SecondaryAttack for bots to start building
		-- (KeyDown doesn't work properly with bot cmd:SetButtons inputs)
		local wep = bot:GetActiveWeapon()
		if IsValid(wep) and wep.SecondaryAttack and wep.GetRightClickStart then
			local rightClickStart = wep:GetRightClickStart()
			if rightClickStart == 0 then
				-- Trigger SecondaryAttack to set RightClickStart
				wep:SecondaryAttack()
			end
			-- The weapon's Think() now checks D3bot_Mem.FleshcreeperState for bots
		end

		-- Tag any nearby unowned nests with this bot's OwnerUID
		TagNearbyUnownedNests(bot)

		-- Aim forward and slightly down to build nest on ground
		local unbuiltNest = GetUnbuiltNest(bot)
		if IsValid(unbuiltNest) then
			local nestPos = unbuiltNest:GetPos()
			aimAngle = (nestPos - bot:EyePos()):Angle()
		else
			-- Aim forward and down when creating new nest
			aimAngle = bot:EyeAngles()
			aimAngle.pitch = 30 -- Look down to place nest
		end

		forwardSpeed = 0
		sideSpeed = 0
		result = true
	elseif mem.Volatile.FleshcreeperState == STATE_REPAIRING_NEST then
		-- Repair damaged nest (closest to humans)
		local nestToRepair = mem.Volatile.NestToRepair
		if IsValid(nestToRepair) then
			-- Hold Attack2 to repair (same mechanic as building)
			actions = {}
			actions.Attack2 = true

			-- The Flesh Creeper weapon needs SecondaryAttack triggered
			local wep = bot:GetActiveWeapon()
			if IsValid(wep) and wep.SecondaryAttack and wep.GetRightClickStart then
				local rightClickStart = wep:GetRightClickStart()
				if rightClickStart == 0 then
					-- Trigger SecondaryAttack to set RightClickStart
					wep:SecondaryAttack()
				end
				-- The weapon's Think() checks D3bot_Mem.FleshcreeperState for bots
			end

			-- Aim at the nest being repaired
			local nestPos = nestToRepair:GetPos()
			aimAngle = (nestPos - bot:EyePos()):Angle()

			forwardSpeed = 0
			sideSpeed = 0
			result = true
			local nestHealth = nestToRepair:GetNestHealth() or 0
			local nestMaxHealth = nestToRepair:GetNestMaxHealth() or 200
			local healthPct = nestMaxHealth > 0 and math.floor((nestHealth / nestMaxHealth) * 100) or 0
			DebugPrint("Repairing nest, health:", healthPct .. "%")
		else
			-- Nest no longer valid, return to normal behavior
			mem.Volatile.NestToRepair = nil
			mem.Volatile.FleshcreeperState = STATE_FINDING_SIGIL
			return
		end
	elseif mem.Volatile.FleshcreeperState == STATE_DESTROYING_NEST then
		-- Attack nests near corrupted sigil
		local nestToDestroy = mem.Volatile.NestToDestroy
		if IsValid(nestToDestroy) then
			result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.WalkAttackAuto(bot)
			if not result then return end
		else
			mem.Volatile.FleshcreeperState = STATE_FINDING_SIGIL
			return
		end
	elseif mem.Volatile.FleshcreeperState == STATE_FINDING_SIGIL or mem.Volatile.FleshcreeperState == STATE_MOVING_TO_BUILD then
		-- Movement for finding sigil and moving to build position
		-- Allow attacking obstacles when stuck

		-- Custom stuck detection based on position not changing
		local botPos = bot:GetPos()
		local isCustomStuck = false

		if not mem.Volatile.LastMovePos then
			mem.Volatile.LastMovePos = botPos
			mem.Volatile.LastMoveTime = CurTime()
			mem.Volatile.StuckCounter = 0
		else
			local movedDist = botPos:Distance(mem.Volatile.LastMovePos)
			if movedDist < 15 then -- Bot hasn't moved much (increased threshold)
				mem.Volatile.StuckCounter = (mem.Volatile.StuckCounter or 0) + 1
				-- Consider stuck after ~0.5 seconds of not moving (reduced from 30 to 15 frames)
				if mem.Volatile.StuckCounter > 15 then
					isCustomStuck = true
					-- Print stuck message once when we first detect stuck
					if mem.Volatile.StuckCounter == 16 then
						StuckPrint(bot, "STUCK DETECTED! Counter:", mem.Volatile.StuckCounter, "MovedDist:", math.floor(movedDist))
					end
				end
			else
				-- Bot is moving, reset stuck counter
				if (mem.Volatile.StuckCounter or 0) > 0 then
					StuckPrint(bot, "Moving again, reset stuck counter. MovedDist:", math.floor(movedDist))
				end
				mem.Volatile.StuckCounter = 0
				mem.Volatile.LastMovePos = botPos
				mem.Volatile.LastMoveTime = CurTime()
			end
		end

		-- Debug state (more frequent when stuck)
		local stateName = mem.Volatile.FleshcreeperState == STATE_FINDING_SIGIL and "FINDING_SIGIL" or "MOVING_TO_BUILD"
		local debugInterval = isCustomStuck and 0.5 or 2
		if not mem.lastDebugMoveTime or CurTime() - mem.lastDebugMoveTime > debugInterval then
			mem.lastDebugMoveTime = CurTime()
			StuckPrint(bot, "UpdateBotCmd:", stateName, "StuckCounter:", mem.Volatile.StuckCounter or 0, "isCustomStuck:", isCustomStuck and "YES" or "no")
		end

		-- Use WalkAttackAuto which properly handles pathfinding
		-- DontAttackTgt should already be set by D3bot_SetTgtOrNil with dontAttack=true
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.WalkAttackAuto(bot)

		if not result then
			-- WalkAttackAuto failed, try fallback direct walk
			local targetPos = mem.Volatile.BuildPosition or (mem.Volatile.TargetSigil and IsValid(mem.Volatile.TargetSigil) and mem.Volatile.TargetSigil:GetPos())

			-- No sigil fallback: walk toward closest human
			if not targetPos then
				local closestHuman, _ = GetClosestHuman(bot:GetPos())
				if closestHuman then
					targetPos = closestHuman:GetPos()
				end
			end

			if targetPos then
				result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.Walk(bot, targetPos, nil, false, 100)
			end
			if not result then return end
		end

		-- Allow attacking obstacles when stuck (use custom detection OR D3bot detection)
		local isStuck = isCustomStuck or facesHindrance or minorStuck or majorStuck

		if actions then
			if isStuck then
				StuckPrint(bot, "Stuck state active! isCustomStuck:", isCustomStuck, "facesHindrance:", facesHindrance, "minorStuck:", minorStuck, "majorStuck:", majorStuck)

				-- JUMP FIRST THEN FORWARD: When stuck, try jumping first to clear obstacle
				if not mem.Volatile.StuckJumpTime then
					-- Start jump phase
					mem.Volatile.StuckJumpTime = CurTime()
					mem.Volatile.StuckJumpPhase = 0
					StuckPrint(bot, "Stuck - initiating jump first")
				end

				local jumpElapsed = CurTime() - mem.Volatile.StuckJumpTime
				if mem.Volatile.StuckJumpPhase == 0 then
					-- Phase 0: Jump (first 0.3 seconds)
					if jumpElapsed < 0.3 then
						actions.Jump = true
						forwardSpeed = 0 -- Don't move forward while jumping up
						StuckPrint(bot, "Stuck jump phase 0: jumping")
					else
						-- Transition to forward phase
						mem.Volatile.StuckJumpPhase = 1
						StuckPrint(bot, "Stuck jump phase 1: moving forward")
					end
				end

				if mem.Volatile.StuckJumpPhase == 1 then
					-- Phase 1: Move forward after jump (0.3-0.6 seconds)
					if jumpElapsed < 0.6 then
						actions.Jump = false
						forwardSpeed = 400 -- Move forward aggressively
						StuckPrint(bot, "Stuck jump phase 1: forward burst")
					else
						-- Reset jump cycle - can try again if still stuck
						mem.Volatile.StuckJumpTime = nil
						mem.Volatile.StuckJumpPhase = nil
						StuckPrint(bot, "Stuck jump cycle complete, resetting")
					end
				end

				-- Bot is stuck - allow attacking to clear the obstacle
				-- Find nearby barricade or prop to attack
				if not mem.Volatile.StuckAttackEntity or not IsValid(mem.Volatile.StuckAttackEntity) then
					local entity, entityPos = bot:D3bot_FindBarricadeEntity(1)
					if entity and entityPos then
						local entClass = entity:GetClass()
						-- Don't attack nests - they're spawn points, not obstacles to destroy
						if entClass == "prop_creepernest" then
							StuckPrint(bot, "Found nest via barricade detection, ignoring and moving around")
							mem.Volatile.NestBlocking = true
							mem.Volatile.NestBlockingTime = CurTime()
							-- Reset cycle counter if a different nest is blocking
							if mem.Volatile.BlockingNestEntity ~= entity then
								mem.Volatile.NestBlockingCycles = nil
							end
							mem.Volatile.BlockingNestEntity = entity -- Store for potential destruction
						-- Don't attack nailed props when finding sigil - move around instead
						elseif (entClass == "prop_physics" or entClass == "prop_physics_multiplayer") and
						       entity.GetNumNails and entity:GetNumNails() > 0 then
							StuckPrint(bot, "Found nailed prop via barricade detection, ignoring and moving around")
							mem.Volatile.BarricadeBlocking = true
							mem.Volatile.BarricadeBlockingTime = CurTime()
						else
							mem.Volatile.StuckAttackEntity = entity
							mem.Volatile.StuckAttackPos = entityPos
							mem.Volatile.StuckAttackTime = CurTime()
							StuckPrint(bot, "Found barricade to attack:", entClass)
						end
					end

					-- If no valid attack target yet, try to find any solid entity in front using traces
					if not mem.Volatile.StuckAttackEntity or not IsValid(mem.Volatile.StuckAttackEntity) then
						-- No barricade found, try to find any solid entity in front using multiple traces
						local eyePos = bot:GetShootPos()
						local forward = bot:GetAimVector()
						local foundObstacle = false

						-- Try traces in multiple directions (forward, forward-down, forward-up, sides)
						local traceDirections = {
							forward * 100,
							(forward + Vector(0, 0, -0.3)):GetNormalized() * 100,
							(forward + Vector(0, 0, 0.3)):GetNormalized() * 100,
						}

						for _, dir in ipairs(traceDirections) do
							local tr = util.TraceLine({
								start = eyePos,
								endpos = eyePos + dir,
								filter = bot,
								mask = MASK_SOLID
							})

							if tr.Hit then
								local hitEnt = tr.Entity
								-- Check if it's an attackable entity (prop_physics, func_breakable, etc.)
								if IsValid(hitEnt) then
									local entClass = hitEnt:GetClass()
									-- Don't attack nests - they're not obstacles, move around them
									if entClass == "prop_creepernest" then
										StuckPrint("Ignoring nest obstacle, will move around it")
										mem.Volatile.NestBlocking = true
										mem.Volatile.NestBlockingTime = CurTime()
										-- Reset cycle counter if a different nest is blocking
										if mem.Volatile.BlockingNestEntity ~= hitEnt then
											mem.Volatile.NestBlockingCycles = nil
										end
										mem.Volatile.BlockingNestEntity = hitEnt -- Store for potential destruction
									-- Ignore tables, chairs, and other non-barricade props
									elseif IsIgnorableProp(hitEnt) then
										StuckPrint("Ignoring prop (table/furniture):", entClass, hitEnt:GetModel())
										mem.Volatile.PropBlocking = true
										mem.Volatile.PropBlockingTime = CurTime()
									-- Attack barricades OR breakable brush entities (func_breakable for glass, func_physbox)
									elseif hitEnt:D3bot_IsBarricade() or entClass == "func_breakable" or entClass == "func_physbox" then
										mem.Volatile.StuckAttackEntity = hitEnt
										mem.Volatile.StuckAttackPos = tr.HitPos
										mem.Volatile.StuckAttackTime = CurTime()
										StuckPrint("Found attackable obstacle via trace:", entClass)
										foundObstacle = true
										break
									else
										-- Other unknown entity - move around
										StuckPrint("Ignoring unknown entity:", entClass)
										mem.Volatile.PropBlocking = true
										mem.Volatile.PropBlockingTime = CurTime()
									end
								elseif tr.HitWorld then
									-- Hit world geometry, can't attack but at least we know something's there
									StuckPrint("Hit world geometry, can't attack")
								end
							end
						end

						if not foundObstacle then
							-- Try a hull trace in front of the bot
							local hullTrace = util.TraceHull({
								start = eyePos,
								endpos = eyePos + forward * 80,
								mins = Vector(-16, -16, -16),
								maxs = Vector(16, 16, 16),
								filter = bot,
								mask = MASK_SOLID
							})

							if hullTrace.Hit and IsValid(hullTrace.Entity) then
								local hitEnt = hullTrace.Entity
								local entClass = hitEnt:GetClass()
								StuckPrint("Hull trace found:", entClass)
								-- Don't attack nests - move around them instead
								if entClass == "prop_creepernest" then
									StuckPrint("Ignoring nest in hull trace, will move around it")
									mem.Volatile.NestBlocking = true
									mem.Volatile.NestBlockingTime = CurTime()
									-- Reset cycle counter if a different nest is blocking
									if mem.Volatile.BlockingNestEntity ~= hitEnt then
										mem.Volatile.NestBlockingCycles = nil
									end
									mem.Volatile.BlockingNestEntity = hitEnt -- Store for potential destruction
								-- Ignore tables, chairs, and other non-barricade props
								elseif IsIgnorableProp(hitEnt) then
									StuckPrint("Ignoring prop in hull trace (table/furniture):", entClass)
									mem.Volatile.PropBlocking = true
									mem.Volatile.PropBlockingTime = CurTime()
								-- Attack barricades OR breakable brush entities (func_breakable for glass, func_physbox)
								elseif hitEnt:D3bot_IsBarricade() or entClass == "func_breakable" or entClass == "func_physbox" then
									mem.Volatile.StuckAttackEntity = hitEnt
									mem.Volatile.StuckAttackPos = hullTrace.HitPos
									mem.Volatile.StuckAttackTime = CurTime()
									StuckPrint("Will attack breakable obstacle:", entClass)
								elseif entClass ~= "worldspawn" and not hitEnt:IsPlayer() then
									-- Other unknown entity - move around
									StuckPrint("Ignoring unknown entity in hull trace:", entClass)
									mem.Volatile.PropBlocking = true
									mem.Volatile.PropBlockingTime = CurTime()
								end
							else
								StuckPrint("No obstacle found in any trace direction")
							end
						end
					end
				end

				-- Attack the obstacle if we have one
				if IsValid(mem.Volatile.StuckAttackEntity) then
					-- Aim at the obstacle
					local attackPos = mem.Volatile.StuckAttackPos or mem.Volatile.StuckAttackEntity:GetPos()
					aimAngle = (attackPos - bot:GetShootPos()):Angle()
					actions.Attack = true
					StuckPrint("Attacking obstacle:", mem.Volatile.StuckAttackEntity:GetClass())

					-- Clear stuck target after 5 seconds (try a different approach)
					if mem.Volatile.StuckAttackTime and CurTime() - mem.Volatile.StuckAttackTime > 5 then
						StuckPrint("Stuck attack timeout, clearing target")
						mem.Volatile.StuckAttackEntity = nil
						mem.Volatile.StuckAttackPos = nil
						mem.Volatile.StuckAttackTime = nil
					end
				else
					-- No attackable obstacle found
					actions.Attack = false

					-- Track how long we've been stuck without finding an obstacle
					if not mem.Volatile.StuckNoObstacleTime then
						mem.Volatile.StuckNoObstacleTime = CurTime()
					end

					-- If stuck for more than 8 seconds OR StuckCounter > 50, abandon build position
					local stuckTooLong = CurTime() - mem.Volatile.StuckNoObstacleTime > 8
					local stuckTooManyCycles = (mem.Volatile.StuckCounter or 0) > 50
					if stuckTooLong or stuckTooManyCycles then
						DebugPrint("Stuck too long without obstacle (time:", stuckTooLong, "cycles:", stuckTooManyCycles, "), abandoning build position")
						mem.Volatile.StuckNoObstacleTime = nil
						mem.Volatile.BuildFailedAttempts = (mem.Volatile.BuildFailedAttempts or 0) + 3 -- Force position change
						mem.Volatile.FleshcreeperState = STATE_FINDING_SIGIL
						mem.Volatile.BuildPosition = nil
						mem.Volatile.TargetSigil = nil -- Force finding new sigil
						ClearStuckDetection(mem)
					end

					-- If a nest is blocking, move in various directions to get around it
					if mem.Volatile.NestBlocking and mem.Volatile.NestBlockingTime and CurTime() - mem.Volatile.NestBlockingTime < 2 then
						-- Cycle through different movement patterns every 0.4 seconds
						local phase = math.floor((CurTime() - mem.Volatile.NestBlockingTime) / 0.4) % 5
						if phase == 0 then
							-- Move backwards + strafe right
							forwardSpeed = -250
							sideSpeed = 350
							StuckPrint("Nest blocking - moving backwards + right")
						elseif phase == 1 then
							-- Pure strafe left (aggressive)
							forwardSpeed = 0
							sideSpeed = -450
							StuckPrint("Nest blocking - moving left")
						elseif phase == 2 then
							-- Move backwards + strafe left
							forwardSpeed = -250
							sideSpeed = -350
							StuckPrint("Nest blocking - moving backwards + left")
						elseif phase == 3 then
							-- Pure strafe right (aggressive)
							forwardSpeed = 0
							sideSpeed = 450
							StuckPrint("Nest blocking - moving right")
						else
							-- Move backwards only
							forwardSpeed = -300
							sideSpeed = 0
							StuckPrint("Nest blocking - moving backwards")
						end
					elseif mem.Volatile.NestBlocking then
						-- Track nest blocking cycles - if blocked for too long, destroy the nest
						mem.Volatile.NestBlockingCycles = (mem.Volatile.NestBlockingCycles or 0) + 1
						StuckPrint("Nest blocking timeout, cycle:", mem.Volatile.NestBlockingCycles)

						-- After 3 cycles (6 seconds total), destroy the blocking nest
						-- BUT only if less than 2 nests exist (don't destroy if we need both nests)
						local currentNestCount = CountAllBuiltNests()
						if mem.Volatile.NestBlockingCycles >= 3 and IsValid(mem.Volatile.BlockingNestEntity) and currentNestCount < HANDLER.NestsRequired then
							StuckPrint("NEST BLOCKING TOO LONG - Switching to STATE_DESTROYING_NEST")
							mem.Volatile.FleshcreeperState = STATE_DESTROYING_NEST
							mem.Volatile.NestToDestroy = mem.Volatile.BlockingNestEntity
							mem.Volatile.NestBlockingCycles = nil
							mem.Volatile.NestBlocking = nil
							mem.Volatile.NestBlockingTime = nil
							mem.Volatile.BlockingNestEntity = nil
						else
							-- Reset for next cycle, keep tracking
							-- If 2 nests exist, just move around instead of destroying
							if currentNestCount >= HANDLER.NestsRequired then
								StuckPrint("Nest blocking but 2 nests exist - moving around instead of destroying")
							end
							mem.Volatile.NestBlocking = nil
							mem.Volatile.NestBlockingTime = nil
							-- NOTE: Don't call ClearStuckDetection - preserve StuckNoObstacleTime for abandon timeout
							mem.Volatile.StuckCounter = nil -- Allow position movement detection to reset
						end
					elseif mem.Volatile.BarricadeBlocking and mem.Volatile.BarricadeBlockingTime and CurTime() - mem.Volatile.BarricadeBlockingTime < 2 then
						-- If a nailed prop is blocking, move around it (don't attack)
						local phase = math.floor((CurTime() - mem.Volatile.BarricadeBlockingTime) / 0.4) % 5
						if phase == 0 then
							forwardSpeed = -250
							sideSpeed = 400
							StuckPrint("Barricade blocking - moving backwards + right")
						elseif phase == 1 then
							forwardSpeed = 0
							sideSpeed = -450
							StuckPrint("Barricade blocking - strafing left")
						elseif phase == 2 then
							forwardSpeed = -250
							sideSpeed = -400
							StuckPrint("Barricade blocking - moving backwards + left")
						elseif phase == 3 then
							forwardSpeed = 0
							sideSpeed = 450
							StuckPrint("Barricade blocking - strafing right")
						else
							forwardSpeed = -350
							sideSpeed = 0
							StuckPrint("Barricade blocking - moving backwards")
						end
					elseif mem.Volatile.BarricadeBlocking then
						-- Clear barricade blocking after 2 seconds
						-- NOTE: Don't call ClearStuckDetection - preserve StuckNoObstacleTime for abandon timeout
						mem.Volatile.BarricadeBlocking = nil
						mem.Volatile.BarricadeBlockingTime = nil
						mem.Volatile.StuckCounter = nil -- Allow position movement detection to reset
						StuckPrint("Barricade blocking timeout, trying different approach")
					elseif mem.Volatile.PropBlocking and mem.Volatile.PropBlockingTime and CurTime() - mem.Volatile.PropBlockingTime < 2 then
						-- If a non-barricade prop is blocking (table, chair, etc.), move around it
						local phase = math.floor((CurTime() - mem.Volatile.PropBlockingTime) / 0.4) % 5
						if phase == 0 then
							forwardSpeed = -200
							sideSpeed = 400
							StuckPrint("Prop blocking - moving backwards + right")
						elseif phase == 1 then
							forwardSpeed = 0
							sideSpeed = -450
							StuckPrint("Prop blocking - strafing left")
						elseif phase == 2 then
							forwardSpeed = -200
							sideSpeed = -400
							StuckPrint("Prop blocking - moving backwards + left")
						elseif phase == 3 then
							forwardSpeed = 0
							sideSpeed = 450
							StuckPrint("Prop blocking - strafing right")
						else
							forwardSpeed = -300
							sideSpeed = 0
							StuckPrint("Prop blocking - moving backwards")
						end
					elseif mem.Volatile.PropBlocking then
						-- Clear prop blocking after 2 seconds
						-- NOTE: Don't call ClearStuckDetection - preserve StuckNoObstacleTime for abandon timeout
						mem.Volatile.PropBlocking = nil
						mem.Volatile.PropBlockingTime = nil
						mem.Volatile.StuckCounter = nil -- Allow position movement detection to reset
						StuckPrint("Prop blocking timeout, trying different approach")
					end
				end
			else
				-- Not stuck - don't attack, just move
				actions.Attack = false
				-- Clear any stuck attack target when moving freely
				mem.Volatile.StuckAttackEntity = nil
				mem.Volatile.StuckAttackPos = nil
				mem.Volatile.StuckAttackTime = nil
				-- Clear nest blocking when moving freely
				mem.Volatile.NestBlocking = nil
				mem.Volatile.NestBlockingTime = nil
				-- Clear barricade blocking when moving freely
				mem.Volatile.BarricadeBlocking = nil
				mem.Volatile.BarricadeBlockingTime = nil
				-- Clear D3bot stuck strafe time
				mem.Volatile.D3botStuckStrafeTime = nil
				-- Clear stuck jump cycle when moving freely
				mem.Volatile.StuckJumpTime = nil
				mem.Volatile.StuckJumpPhase = nil
			end
		end
	else
		-- Fallback behavior (should rarely reach here)
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.PounceAuto(bot, false)

		if not result then
			result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = D3bot.Basics.WalkAttackAuto(bot)
			if not result then return end
		end

		-- Handle barricade attacks only in fallback state
		if facesHindrance and CurTime() - (bot.D3bot_LastDamage or 0) > 2 then
			local entity, entityPos = bot:D3bot_FindBarricadeEntity(1)
			if entity and entityPos then
				-- Don't attack nests - they're spawn points, not obstacles
				if entity:GetClass() ~= "prop_creepernest" then
					mem.BarricadeAttackEntity, mem.BarricadeAttackPos = entity, entityPos
				end
			end
		end
	end

	-- ЛОГІКА МОБІЛЬНОСТІ: Універсальні стрибки з фіксацією фази
	if result and actions and not (minorStuck or majorStuck or facesHindrance) then
		local state = mem.Volatile.FleshcreeperState
		local targetPos = nil

		-- Визначаємо ціль для тактичних стрибків (додали STATE_REPAIRING_NEST)
		if state == STATE_MOVING_TO_BUILD then
			if mem.Volatile.BuildPosition then
				targetPos = mem.Volatile.BuildPosition
			elseif IsValid(mem.Volatile.NestToRepair) then
				targetPos = mem.Volatile.NestToRepair:GetPos()
			end
		elseif state == STATE_DESTROYING_NEST and IsValid(mem.Volatile.NestToDestroy) then
			targetPos = mem.Volatile.NestToDestroy:GetPos()
		end

		-- 1. БЕЗУМОВНА ПЕРЕВІРКА: чи є наказ стрибати? (від рутини або від поранення)
		if mem.Volatile.LeapEndTime and CurTime() < mem.Volatile.LeapEndTime then
			-- Поки триває таймер — затискаємо кнопки і дивимося вгору
			actions.Reload = true
			actions.Jump = true
			if aimAngle then
				aimAngle.pitch = -45
			end
		elseif targetPos then
			-- 2. Якщо наближаємось до цілі (ремонт, злам, будівництво)
			local distToTarget = bot:GetPos():Distance(targetPos)
			
			if distToTarget > 500 and bot:IsOnGround() then
				mem.Volatile.NextLeapTime = mem.Volatile.NextLeapTime or (CurTime() + math.random(2, 4))

				if CurTime() > mem.Volatile.NextLeapTime then
					-- ПОЧАТОК ФАЗИ СТРИБКА (тривалість 1 сек)
					mem.Volatile.LeapEndTime = CurTime() + 1
					-- Наступний стрибок через 2-4 секунд
					mem.Volatile.NextLeapTime = CurTime() + math.random(2, 4)
				end
			else
				-- Скидаємо готовність, якщо підійшли близько
				mem.Volatile.NextLeapTime = CurTime() + 2
			end
		end
	end

	-- Apply buttons and movement (same as undead_fallback)
	if result and actions then
		local buttons = bit.bor(
			actions.MoveForward and IN_FORWARD or 0,
			actions.MoveBackward and IN_BACK or 0,
			actions.MoveLeft and IN_MOVELEFT or 0,
			actions.MoveRight and IN_MOVERIGHT or 0,
			actions.Attack and IN_ATTACK or 0,
			actions.Attack2 and IN_ATTACK2 or 0,
			actions.Reload and IN_RELOAD or 0,
			actions.Duck and IN_DUCK or 0,
			actions.Jump and IN_JUMP or 0,
			actions.Use and IN_USE or 0
		)

		-- Don't kill bot for being stuck when building, following leader, or recently spawned (standing still is expected)
		local recentSpawn = mem.Volatile.RecentSpawnProtectionTime and mem.Volatile.RecentSpawnProtectionTime > CurTime()
		if majorStuck and GAMEMODE:GetWaveActive() and mem.Volatile.FleshcreeperState ~= STATE_BUILDING and not recentSpawn then bot:Kill() end
		
		if aimAngle then
			bot:SetEyeAngles(aimAngle)
			cmd:SetViewAngles(aimAngle)
		end
		if forwardSpeed then cmd:SetForwardMove(forwardSpeed) end
		if sideSpeed then cmd:SetSideMove(sideSpeed) end
		if upSpeed then cmd:SetUpMove(upSpeed) end
		cmd:SetButtons(buttons)
	end
end

-- CountAllBuiltNests and CountOwnBuiltNests now use D3bot.ZS shared functions (aliased above)
-- CountBotBuiltNests was identical to CountOwnBuiltNests, use that instead

--------------------------------------------------------------------------------
-- Coroutine-Based Behavior Implementation
-- When HANDLER.UseCoroutines = true, this provides a more readable sequential flow
-- compared to the state machine approach below.
--------------------------------------------------------------------------------

---Yields execution and returns on next think tick. Sets the current state for UpdateBotCmdFunction.
---@param mem table The bot's D3bot_Mem table
---@param state integer The state to set (STATE_FINDING_SIGIL, STATE_BUILDING, etc.)
local function YieldWithState(mem, state)
	mem.Volatile.FleshcreeperState = state
	coroutine.yield()
end

---Checks if an interrupt flag is set and should break out of current behavior.
---@param mem table The bot's D3bot_Mem table
---@return boolean True if interrupted
local function IsInterrupted(mem)
	return mem.Volatile.InterruptFlag ~= nil
end

local function CheckForInterrupts(bot, mem)
	local globalBuiltNests = D3bot.ZS.CountAllBuiltNests()
	local closestNest, _ = GetNestClosestToHumans()

	local corruptedSigil = D3bot.ZS.GetCorruptedSigil()
	if IsValid(corruptedSigil) and not IsValid(mem.Volatile.NestToDestroy) and mem.Volatile.FleshcreeperState ~= STATE_DESTROYING_NEST then
		local nestToDestroy = D3bot.ZS.GetNestNearCorruptedSigil(corruptedSigil, HANDLER.NestCorruptedSigilDistance)
		if IsValid(nestToDestroy) and nestToDestroy ~= closestNest then
			mem.Volatile.NestToDestroy = nestToDestroy
			mem.Volatile.CorruptedSigil = corruptedSigil
			return true, "sigil_corrupted"
		end
	end

	if globalBuiltNests >= HANDLER.NestsRequired then
		
		if not IsValid(mem.Volatile.NestToDestroy) and mem.Volatile.FleshcreeperState ~= STATE_REPAIRING_NEST and mem.Volatile.FleshcreeperState ~= STATE_BUILDING then
			local nestToRepair, healthPercent, pathDist = HANDLER.GetClosestNestNeedingRepair()
			if IsValid(nestToRepair) then
				mem.Volatile.NestToRepair = nestToRepair
				mem.Volatile.NestRepairHealthPercent = healthPercent
				return true, "nest_needs_repair"
			end
		end

		if not IsValid(mem.Volatile.NestToDestroy) and not IsValid(mem.Volatile.NestToRepair) and mem.Volatile.FleshcreeperState ~= STATE_BUILDING and mem.Volatile.FleshcreeperState ~= STATE_MOVING_TO_BUILD and mem.Volatile.FleshcreeperState ~= STATE_DESTROYING_NEST then
			local farNest, farNestDist = GetFurthestInvalidNest()
			if IsValid(farNest) then
				mem.Volatile.NestToDestroy = farNest
				mem.Volatile.NestTooFarDestroy = true
				return true, "nest_too_far"
			end
		end
		
	end

	return false, nil
end

---Creates the main behavior coroutine for a Flesh Creeper bot.
---This coroutine handles the sequential flow: find target -> move -> build -> repeat or attack.
---@param bot GPlayer The bot player
---@return thread The created coroutine
local function CreateBehaviorCoroutine(bot)
	return coroutine.create(function()
		local mem = bot.D3bot_Mem

		while true do
			if IsInterrupted(mem) then
				mem.Volatile.InterruptFlag = nil
				return
			end

			local globalBuiltNests = D3bot.ZS.CountAllBuiltNests()
			if globalBuiltNests >= HANDLER.NestsRequired then
				-- 1. Перевірка: чи є завдання на руйнування (печатки/дистанція)?
				if IsValid(mem.Volatile.NestToDestroy) then
					DebugPrint("Coroutine: Have nest to destroy, skipping suicide.")
				
				-- 2. Перевірка: чи є завдання на ремонт?
				elseif IsValid(mem.Volatile.NestToRepair) then
					DebugPrint("Coroutine: Have nest to repair, skipping suicide.")
				
				else
					-- ФІНАЛЬНИЙ АУДИТ ПЕРЕД СМЕРТЮ
					DebugPrint("Coroutine: Performing final audit before class switch...")
					
					-- 1. Спершу перевіряємо ЦІЛІСНІСТЬ (Здоров'я < 95%) - ЦЕ ВАЖЛИВІШЕ
					local damagedNest, _ = HANDLER.GetClosestNestNeedingRepair()
					if IsValid(damagedNest) then
						DebugPrint("Coroutine: Wait! Found damaged nest during audit. Going to repair.")
						mem.Volatile.NestToRepair = damagedNest
						-- Не вмираємо, цикл піде на PHASE 1.5
					else
						-- 2. Якщо всі цілі, перевіряємо АКТУАЛЬНІСТЬ (Дистанція 900)
						local furthestNest, dist = GetFurthestInvalidNest()
						if IsValid(furthestNest) then
							DebugPrint("Coroutine: Wait! Found invalid nest during audit (dist: " .. math.floor(dist) .. "). Relocating.")
							mem.Volatile.NestToDestroy = furthestNest
							mem.Volatile.NestTooFarDestroy = true
							-- Не вмираємо, цикл піде на PHASE 1
						else
							-- ЯКЩО МИ ТУТ — ВСЕ ІДЕАЛЬНО: 2 гнізда, всі близько, всі цілі.
							DebugPrint("Coroutine: Audit passed. Both nests are valid and healthy. Switching class.")
							
							local humansUnreachable = AreHumansUnreachable(bot)
							local attackClassIndex = GetRandomAttackClassIndex(humansUnreachable)
							bot.DeathClass = attackClassIndex
							
							bot.D3bot_RespawnDelayUntil = CurTime() + 3
							ClearStuckDetection(mem)
							bot:Kill()
							return -- Повна зупинка корутини
						end
					end
				end
			end

			-- PHASE 1: Handle destroying nests (if flagged by interrupt)
			if IsValid(mem.Volatile.NestToDestroy) then
				DebugPrint("Coroutine: Destroying nest")
				bot:D3bot_SetTgtOrNil(mem.Volatile.NestToDestroy, false, nil)
				bot:D3bot_UpdatePath(nil, nil)

				while IsValid(mem.Volatile.NestToDestroy) do
					YieldWithState(mem, STATE_DESTROYING_NEST)
					if IsInterrupted(mem) then return end
				end

				-- Nest destroyed - handle based on type
				if mem.Volatile.NestTooFarDestroy then
					DebugPrint("Coroutine: Nest too far destroyed, rebuilding closer")
					mem.Volatile.NestTooFarDestroy = nil
					mem.Volatile.RebuildNearHuman = true
				elseif IsValid(mem.Volatile.RelocateTarget) then
					DebugPrint("Coroutine: Relocation nest destroyed, building near target")
					local targetPos = mem.Volatile.RelocateTarget:GetPos()
					mem.Volatile.BuildPosition = FindOpenBuildPosition(bot, targetPos, 800)
					mem.Volatile.RelocateTarget = nil
					mem.Volatile.RelocateType = nil
				else
					-- Руйнування через зіпсовану печатку.
					-- ПРОСТО очищаємо пам'ять. Бот "провалиться" в будівництво, щоб зробити заміну.
					-- Друге гніздо він зламає лише тоді, коли добудує це (через CheckForInterrupts).
					mem.Volatile.CorruptedSigil = nil
				end
				mem.Volatile.NestToDestroy = nil
				ClearStuckDetection(mem)
			end

			-- PHASE 1.5: Handle repairing damaged nests (closest nest to humans)
			if IsValid(mem.Volatile.NestToRepair) then
				local nestToRepair = mem.Volatile.NestToRepair
				DebugPrint("Coroutine: Repairing closest nest, health:", math.floor((mem.Volatile.NestRepairHealthPercent or 0) * 100), "%")

				-- Move to the exact nest center (proximity 0)
				bot:D3bot_SetPosTgtOrNil(nestToRepair:GetPos(), 0)
				bot:D3bot_UpdatePath(nil, nil)

				local repairStartTime = CurTime()
				local repairTimeout = 30 -- 30 second timeout for repair

				while IsValid(nestToRepair) do
					-- Check if we're at the nest center
					local distToNest = bot:GetPos():Distance(nestToRepair:GetPos())

					if distToNest < 50 and bot:IsOnGround() then
						-- At nest center, start repairing
						YieldWithState(mem, STATE_REPAIRING_NEST)
					else
						-- Still moving to nest center
						YieldWithState(mem, STATE_MOVING_TO_BUILD)
						bot:D3bot_SetPosTgtOrNil(nestToRepair:GetPos(), 0)
						bot:D3bot_UpdatePath(nil, nil)
					end

					if IsInterrupted(mem) then return end

					-- Check if nest is fully repaired (use >= to avoid floating point issues)
					local health = nestToRepair:GetNestHealth() or 0
					local maxHealth = nestToRepair:GetNestMaxHealth() or 200
					if maxHealth > 0 and health >= maxHealth then
						DebugPrint("Coroutine: Nest fully repaired! Health:", health, "/", maxHealth)
						break
					end

					-- Timeout check
					if CurTime() - repairStartTime > repairTimeout then
						DebugPrint("Coroutine: Nest repair timeout")
						break
					end

					-- Check if nest was destroyed
					if not IsValid(nestToRepair) or not nestToRepair:GetNestBuilt() then
						DebugPrint("Coroutine: Nest was destroyed during repair")
						break
					end
				end

				mem.Volatile.NestToRepair = nil
				mem.Volatile.NestRepairHealthPercent = nil
				ClearStuckDetection(mem)

				-- After repair, check if 2 nests still exist - if so, loop back to PHASE 0 for attack mode
				local nestsAfterRepair = CountAllBuiltNests()
				if nestsAfterRepair >= HANDLER.NestsRequired then
					DebugPrint("Coroutine: Repair complete, 2 nests exist, looping back to PHASE 0")
					return -- Continue will loop back to PHASE 0 at the top of the while loop
				end
			end

			-- Find build position
			local buildPos = nil
			if mem.Volatile.RebuildNearHuman then
				-- Prioritize building near humans after nest destruction
				local humans = D3bot.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN))
				if #humans > 0 then
					local botPos = bot:GetPos()
					table.sort(humans, function(a, b) return botPos:DistToSqr(a:GetPos()) < botPos:DistToSqr(b:GetPos()) end)
					buildPos = FindOpenBuildPosition(bot, humans[1]:GetPos(), 800)
				end
				mem.Volatile.RebuildNearHuman = nil
			end

			if not buildPos then
				local targetSigil = FindTargetSigil(bot)
				mem.Volatile.TargetSigil = targetSigil
				buildPos = FindBuildPosition(bot, targetSigil)
			end

			if not buildPos then
				DebugPrint("Coroutine: No build position found, waiting...")
				YieldWithState(mem, STATE_FINDING_SIGIL)
				-- Loop back
			else
				mem.Volatile.BuildPosition = buildPos

				-- PHASE 4: Move to build position
				DebugPrint("Coroutine: Moving to build position")
				bot:D3bot_SetPosTgtOrNil(buildPos, 100)
				bot:D3bot_UpdatePath(nil, nil)
				local moveStartTime = CurTime()

				while bot:GetPos():Distance(buildPos) > 150 do
					YieldWithState(mem, STATE_MOVING_TO_BUILD)
					if IsInterrupted(mem) then return end

					-- Timeout check
					if CurTime() - moveStartTime > 15 then
						DebugPrint("Coroutine: Move timeout, finding new position")
						mem.Volatile.BuildPosition = nil
						ClearStuckDetection(mem)
						break
					end

					-- Opportunistic build check
					if bot:IsOnGround() then
						local closestHuman, distToHuman = GetClosestHuman(bot:GetPos())
						if closestHuman and distToHuman and distToHuman < HANDLER.OpportunisticBuildDistance and distToHuman > 420 then
							local tooCloseToNest, _ = IsTooCloseToNest(bot:GetPos(), HANDLER.MinNestDistance)
							local botPos = bot:GetPos()
							-- Must be hidden from humans, not near barricades or unnailed props, not blacklisted
							if not tooCloseToNest and not IsPositionBlacklisted(bot, botPos) and IsHiddenFromHumans(botPos, 1500) and not IsNearBarricade(botPos, HANDLER.BarricadeAvoidDistance) and not IsNearUnnailedProp(botPos, HANDLER.BarricadeAvoidDistance) then
								DebugPrint("Coroutine: Opportunistic build!")
								buildPos = botPos
								mem.Volatile.BuildPosition = buildPos
								break
							end
						end
					end

					-- Re-set target for path updates
					bot:D3bot_SetPosTgtOrNil(buildPos, 100)
					bot:D3bot_UpdatePath(mem.Volatile.PathCostFunction, nil)
				end

				-- PHASE 5: Build nest
				if bot:GetPos():Distance(buildPos) < 150 and bot:IsOnGround() then
					DebugPrint("Coroutine: Building nest")
					mem.Volatile.BuildStartTime = CurTime()

					-- Track the nest we're building (will be acquired during the loop)
					-- We need to track it because GetUnbuiltNest() won't return it once it's complete
					local buildingNest = nil
					local highestNestHealth = 0 -- Трекаємо пікове здоров'я

					-- Building loop
					while true do
						YieldWithState(mem, STATE_BUILDING)
						if IsInterrupted(mem) then return end

						-- HUMAN PROXIMITY CHECK: If human moves within 420 units before nest is created, abort
						-- This prevents wasting time trying to build in an invalid position
						if not IsValid(buildingNest) then
							local botPos = bot:GetPos()
							local humanTooClose = false
							for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
								if IsValidHumanTarget(pl) and pl:GetPos():Distance(botPos) < 420 then
									humanTooClose = true
									DebugPrint("Coroutine: Human moved within 420 units, aborting build!")
									break
								end
							end
							if humanTooClose then
								-- Abort build and find new position
								mem.Volatile.BuildPosition = nil
								mem.Volatile.BuildStartTime = nil
								ClearStuckDetection(mem)
								break
							end
						end

						-- Try to acquire the nest reference
						if not IsValid(buildingNest) then
							TagNearbyUnownedNests(bot)
							buildingNest = GetUnbuiltNest(bot)
							if IsValid(buildingNest) then
								DebugPrint("Coroutine: Acquired nest reference:", buildingNest)
								highestNestHealth = buildingNest:GetNestHealth() or 0
							end
						end

						-- ЗАЛІЗОБЕТОННИЙ NEST DAMAGE CHECK
						if IsValid(buildingNest) then
							local currentHealth = buildingNest:GetNestHealth() or 0
							
							-- Якщо здоров'я впало нижче історичного максимуму — нас б'ють!
							if currentHealth < highestNestHealth then
								DebugPrint("Coroutine: Nest taking damage! Dropped from", highestNestHealth, "to", currentHealth, "- abandoning position")
								BlacklistPosition(bot, buildPos, "nest_shot_by_human")
								
								mem.Volatile.BuildPosition = nil
								mem.Volatile.BuildStartTime = nil
								ClearStuckDetection(mem)
								break
							else
								-- Оновлюємо пік здоров'я (він росте поки бот будує)
								highestNestHealth = currentHealth
							end
						end

						-- Check if nest is complete
						-- We check the tracked nest entity directly, not via GetUnbuiltNest()
						local nestComplete = false
						if IsValid(buildingNest) then
							-- We have a tracked nest - check if it's built
							nestComplete = buildingNest:GetNestBuilt()
						end
						-- If buildingNest is nil, we haven't acquired it yet - keep waiting

						if nestComplete then
							DebugPrint("Coroutine: Nest complete!")
							mem.Volatile.BuildPosition = nil
							mem.Volatile.BuildStartTime = nil
							ClearStuckDetection(mem)
							break
						end

						-- Timeout check
						if CurTime() - mem.Volatile.BuildStartTime > 30 then
							DebugPrint("Coroutine: Build timeout")
							mem.Volatile.BuildPosition = nil
							mem.Volatile.BuildStartTime = nil
							ClearStuckDetection(mem)
							break
						end
					end
				end
			end -- End of else block for nest count check before building

			-- End of cycle, loop back to check nests and continue
			YieldWithState(mem, STATE_FINDING_SIGIL)
			if IsInterrupted(mem) then return end
		end
	end)
end

---Coroutine-based ThinkFunction implementation.
---@param bot GPlayer The bot player entity
local function ThinkFunction_Coroutine(bot)
	local mem = bot.D3bot_Mem
	mem.Volatile.FleshcreeperState = mem.Volatile.FleshcreeperState or STATE_FINDING_SIGIL

	-- Throttle thinking
	if mem.nextFleshcreeperThink and mem.nextFleshcreeperThink > CurTime() then return end
	mem.nextFleshcreeperThink = CurTime() + 0.5 + math.random() * 0.3

	-- Path cost function setup (same as state machine version)
	if not mem.Volatile.PathCostFunction then
		if D3bot.UsingSourceNav then
			mem.Volatile.PathCostFunction = function(cArea, nArea, link)
				if not mem.ConsidersPathLethality then return 0 end
				local linkMetaData = link:GetMetaData()
				return linkMetaData and linkMetaData.ZombieDeathCost or 0
			end
		else
			mem.Volatile.PathCostFunction = function(node, linkedNode, link)
				if not mem.ConsidersPathLethality then return 0 end
				local linkMetadata = D3bot.LinkMetadata[link]
				return linkMetadata and linkMetadata.ZombieDeathCost or 0
			end
		end
	end

	-- Enforce max Flesh Creeper limit
	local allCreepers = GetAllFleshCreeperBots()
	if #allCreepers > HANDLER.MaxFleshCreeperBots then
		local isExtra = true
		for i = 1, HANDLER.MaxFleshCreeperBots do
			if allCreepers[i] == bot then
				isExtra = false
				break
			end
		end
		if isExtra then
			DebugPrint("Coroutine: Too many Flesh Creepers, switching class")
			local attackClassIndex = GetRandomAttackClassIndex(false)
			if attackClassIndex then
				bot.DeathClass = attackClassIndex
				bot:Kill()
				return
			end
		end
	end

	-- EARLY CHECK: If post-build behavior was already applied but bot respawned as Flesh Creeper,
	-- force transition to attack mode to prevent building more nests
	-- EXCEPTION: Don't interrupt if currently repairing a nest
	local globalBuiltNests = CountAllBuiltNests()
	if globalBuiltNests >= HANDLER.NestsRequired and mem.PostBuildBehaviorApplied
	   and mem.Volatile.FleshcreeperState ~= STATE_ATTACKING
	   and mem.Volatile.FleshcreeperState ~= STATE_DESTROYING_NEST
	   and mem.Volatile.FleshcreeperState ~= STATE_REPAIRING_NEST then
		DebugPrint("Coroutine: Post-build already applied, forcing attack mode")
		mem.Volatile.FleshcreeperState = STATE_ATTACKING
		mem.Volatile.AttackMode = table.Random({ATTACK_MODE_HUMANS, ATTACK_MODE_BARRICADES, ATTACK_MODE_SIGILS})
		mem.Volatile.RecentSpawnProtectionTime = CurTime() + 5
		bot.DeathClass = GetRandomAttackClassIndex(false)
		-- Reset coroutine to use attack-only behavior
		mem.Volatile.BehaviorCoroutine = nil
	end

	-- Check for interrupts (sigil corrupted, nest too far, etc.)
	local shouldRestart, reason = CheckForInterrupts(bot, mem)
	if shouldRestart then
		DebugPrint("Coroutine: Interrupt detected -", reason)
		mem.Volatile.BehaviorCoroutine = nil -- Reset coroutine to handle interrupt
	end

	-- Create or resume coroutine
	if not mem.Volatile.BehaviorCoroutine or coroutine.status(mem.Volatile.BehaviorCoroutine) == "dead" then
		DebugPrint("Coroutine: Creating new behavior coroutine")
		mem.Volatile.BehaviorCoroutine = CreateBehaviorCoroutine(bot)
	end

	-- Resume the coroutine
	local ok, err = coroutine.resume(mem.Volatile.BehaviorCoroutine)
	if not ok then
		DebugPrint("Coroutine ERROR:", err)
		mem.Volatile.BehaviorCoroutine = nil
	end

	-- Update path based on current state
	if not mem.nextUpdatePath or mem.nextUpdatePath < CurTime() then
		local pathUpdateInterval = mem.Volatile.FleshcreeperState == STATE_MOVING_TO_BUILD and 0.3 or 0.9
		mem.nextUpdatePath = CurTime() + pathUpdateInterval + math.random() * 0.2
		bot:D3bot_UpdatePath(mem.Volatile.PathCostFunction, nil)
	end
end

---Called every tick for bot AI decision making using coroutine-based behavior.
---Handles state transitions, nest building logic, target selection, and leader/follower coordination.
---@param bot GPlayer The bot player entity
---@return nil
function HANDLER.ThinkFunction(bot)
	-- Skip dead bots (they're in 10-second intermission, spawn handled by handle.lua)
	if not bot:Alive() then return end

	ThinkFunction_Coroutine(bot)
end

---Called when the bot takes damage. Triggers backoff if attacked while building.
---@param bot GPlayer The bot player that took damage
---@param dmg GCTakeDamageInfo The damage info
---@return nil
function HANDLER.OnTakeDamageFunction(bot, dmg)
	local mem = bot.D3bot_Mem
	
	-- ЗАХИСНИЙ РИВОК: 50% шанс стрибнути при отриманні кожної кулі
	-- Перевіряємо, щоб випадково не зрізати таймер, якщо він уже в довгому стрибку
	if math.random() < 0.50 and (not mem.Volatile.LeapEndTime or mem.Volatile.LeapEndTime < CurTime() + 1) then
		mem.Volatile.LeapEndTime = CurTime() + 1 -- Короткий ривок вгору для ухилення
	end

	if mem.Volatile.FleshcreeperState == STATE_BUILDING or mem.Volatile.FleshcreeperState == STATE_MOVING_TO_BUILD then
		
		-- Блокуємо і цільову позицію, і фактичне місце, де бот отримав по голові
		if mem.Volatile.BuildPosition then
			BlacklistPosition(bot, mem.Volatile.BuildPosition, "took_damage")
		end
		BlacklistPosition(bot, bot:GetPos(), "took_damage_pos")

		-- Жорстко перериваємо процеси
		mem.Volatile.InterruptFlag = true
		mem.Volatile.BuildPosition = nil
		mem.Volatile.BuildStartTime = nil
		mem.Volatile.TargetSigil = nil
		
		-- МИТТЄВЕ СКИДАННЯ СТАНУ (це вимкне затискання ПКМ)
		mem.Volatile.FleshcreeperState = STATE_FINDING_SIGIL
	end
end

---Called when the bot damages something. Handles nest destruction tracking.
---@param bot GPlayer The bot player that dealt damage
---@param ent GEntity The entity that was damaged
---@param dmg GCTakeDamageInfo The damage info
---@return nil
function HANDLER.OnDoDamageFunction(bot, ent, dmg)
	local mem = bot.D3bot_Mem

	-- If attacking own nest for destruction
	if ent and ent:IsValid() and ent.IsCreeperNest and ent.OwnerUID == bot:UniqueID() then
		-- Good, continue attacking
	end
end

---Called when the bot dies. Handles leader succession and position blacklisting.
---@param bot GPlayer The bot player that died
---@return nil
function HANDLER.OnDeathFunction(bot)
	DebugPrint("OnDeathFunction called - bot died")

	local mem = bot.D3bot_Mem
	if mem then
		-- OPTION 3: Track deaths while moving to build - escalating avoidance
		-- If killed while trying to reach build position, increment death counter
		if mem.Volatile.FleshcreeperState == STATE_MOVING_TO_BUILD and mem.Volatile.BuildPosition then
			mem.BuildAttemptDeaths = (mem.BuildAttemptDeaths or 0) + 1
			local buildPos = mem.Volatile.BuildPosition

			DebugPrint("OnDeathFunction: Killed while moving to build! Deaths on this path:", mem.BuildAttemptDeaths)

			if mem.BuildAttemptDeaths >= 2 then
				-- Blacklist this build position after 2 deaths
				mem.BlacklistedBuildPositions = mem.BlacklistedBuildPositions or {}
				table.insert(mem.BlacklistedBuildPositions, {
					pos = buildPos,
					time = CurTime()
				})
				DebugPrint("OnDeathFunction: Blacklisted build position after", mem.BuildAttemptDeaths, "deaths:", buildPos)
				mem.BuildAttemptDeaths = 0 -- Reset counter for next attempt
			end
		elseif mem.Volatile.FleshcreeperState == STATE_FINDING_SIGIL then
			-- Also track deaths while finding sigil (early path)
			mem.BuildAttemptDeaths = (mem.BuildAttemptDeaths or 0) + 1
			DebugPrint("OnDeathFunction: Killed while finding sigil! Deaths:", mem.BuildAttemptDeaths)
		else
			-- Reset death counter if died in other states (building, attacking, etc.)
			mem.BuildAttemptDeaths = 0
		end
	end

	-- Check if this bot was the leader
	if CurrentFleshCreeperLeader == bot then
		-- Count built nests to determine if leader finished their mission
		local builtNestCount = 0
		for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
			if IsValid(nest) and nest.GetNestBuilt and nest:GetNestBuilt() then
				builtNestCount = builtNestCount + 1
			end
		end

		local mem = bot.D3bot_Mem
		local postBuildApplied = mem and mem.PostBuildBehaviorApplied

		-- Leader suicided after building 2 nests = followers should also suicide
		-- PostBuildBehaviorApplied means the leader triggered the kill-self behavior
		if builtNestCount >= 2 and postBuildApplied then
			DebugPrint("OnDeathFunction: Leader suicided after building 2 nests - followers should suicide too")
			LeaderDiedBySuicideWith2Nests = true
		else
			-- Leader was killed by human or nests incomplete - follower becomes new leader
			DebugPrint("OnDeathFunction: Leader was killed (not suicide with 2 nests) - follower becomes new leader")
			LeaderDiedBySuicideWith2Nests = false
		end

		DebugPrint("OnDeathFunction: Leader died, clearing leader for new selection. BuiltNests:", builtNestCount, "PostBuild:", postBuildApplied and "YES" or "NO", "Suicide2Nests:", LeaderDiedBySuicideWith2Nests and "YES" or "NO")
		CurrentFleshCreeperLeader = nil
		-- Clear leader state when leader is killed by human (not suicide) - new leader will set their own
		if not LeaderDiedBySuicideWith2Nests then
			LeaderAttackMode = nil
			LeaderDeathClass = nil
		end
	end

	-- NOTE: All mem.Volatile.* variables are automatically reset on spawn via D3bot_InitializeOrReset()
	-- No manual cleanup needed here anymore!
	--
	-- EXCEPTION: PostBuildBehaviorApplied should persist across death/respawn.
	-- If a bot has already triggered post-build behavior (switched class or started attacking),
	-- we don't want it to trigger again on respawn when 2 nests are still built.
	-- This is handled by NOT putting it in Volatile - it stays in mem directly.
end

---Returns whether a target is valid for this bot to pursue.
---Valid targets: humans, other Flesh Creepers (for following), uncorrupted sigils, barricades, nests near corrupted sigils.
---@param bot GPlayer The bot player
---@param target GPlayer|GEntity The potential target entity
---@return boolean True if the target is valid
function HANDLER.CanBeTgt(bot, target)
	if not target or not IsValid(target) then return false end

	-- Can target humans
	if target:IsPlayer() and target ~= bot and target:Team() ~= TEAM_UNDEAD and target:GetObserverMode() == OBS_MODE_NONE and not target:IsFlagSet(FL_NOTARGET) and target:Alive() then
		return true
	end

	-- Can target other Flesh Creeper bots (for following)
	if target:IsPlayer() and target ~= bot and target:Team() == TEAM_UNDEAD and target:Alive() then
		local targetClass = target:GetZombieClassTable()
		if targetClass and targetClass.Name == "Flesh Creeper" then
			return true
		end
	end

	-- Can target uncorrupted sigils
	if target:GetClass() == "prop_obj_sigil" then
		local corrupted, _ = IsSigilCorrupted(target)
		if not corrupted then
			return true
		end
	end

	-- Can target barricades/props (nailed props, player-placed entities)
	local entClass = target:GetClass()
	if entClass == "prop_physics" or entClass == "prop_physics_multiplayer" then
		if target.GetNumNails and target:GetNumNails() > 0 then
			return true
		end
		if target:GetOwner() and target:GetOwner():IsPlayer() then
			return true
		end
	elseif string.find(entClass, "prop_arsenal") or string.find(entClass, "prop_deployable") then
		return true
	end

	-- Can target nests near corrupted sigils (for destruction)
	if target.IsCreeperNest then
		-- Check if there's a corrupted sigil nearby this nest
		for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
			local corrupted, _ = IsSigilCorrupted(sigil)
			if IsValid(sigil) and corrupted then
				if target:GetPos():Distance(sigil:GetPos()) < HANDLER.NestCorruptedSigilDistance then
					return true
				end
			end
		end
	end

	return false
end

---Rerolls the bot's target to a random valid target (humans or uncorrupted sigils).
---@param bot GPlayer The bot player
---@return nil
function HANDLER.RerollTarget(bot)
	local players = D3bot.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN))
	if #players == 0 then
		players = D3bot.RemoveObsDeadTgts(player.GetAll())
		players = D3bot.From(players):Where(function(k, v) return v:Team() ~= TEAM_UNDEAD end).R
	end

	-- Add sigils as targets (if they exist)
	local sigils = ents.FindByClass("prop_obj_sigil")
	for _, sigil in ipairs(sigils) do
		local corrupted, _ = IsSigilCorrupted(sigil)
		if IsValid(sigil) and not corrupted then
			table.insert(players, sigil)
		end
	end

	bot:D3bot_SetTgtOrNil(table.Random(players), false, nil)
end

print("[D3bot] undead_fleshcreeper.lua loaded successfully!")

return HANDLER
