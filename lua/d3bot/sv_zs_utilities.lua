-- D3bot ZS Utilities
-- Shared helper functions for Zombie Survival bot handlers
-- These functions are used by both undead_fleshcreeper.lua and undead_fallback.lua

D3bot.ZS = D3bot.ZS or {}

---Check if a human player is a valid target (alive, not spectating, not flagged)
---@param pl GPlayer The player to check
---@return boolean True if the player is a valid human target
function D3bot.ZS.IsValidHumanTarget(pl)
	if not IsValid(pl) then return false end
	if not pl:Alive() then return false end
	if pl:GetObserverMode() ~= OBS_MODE_NONE then return false end -- Skip spectators
	if pl:IsFlagSet(FL_NOTARGET) then return false end
	return true
end

---Safe wrapper for sigil corruption check (compatible with ZS versions without sigils)
---@param sigil GEntity The sigil entity to check
---@return boolean corrupted Whether the sigil is corrupted
---@return boolean exists Whether the sigil entity is valid
function D3bot.ZS.IsSigilCorrupted(sigil)
	if not IsValid(sigil) then return false, false end
	if sigil.GetSigilCorrupted then
		return sigil:GetSigilCorrupted(), true
	end
	-- Sigil entity exists but doesn't have corruption method (older ZS version)
	-- Assume not corrupted
	return false, true
end

---Check if sigils exist in this gamemode
---@return boolean True if at least one sigil exists
function D3bot.ZS.SigilsExist()
	local sigils = ents.FindByClass("prop_obj_sigil")
	return #sigils > 0
end

---Check if any sigil is corrupted (green)
---@return boolean True if any sigil is corrupted
function D3bot.ZS.AnySigilCorrupted()
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
		if corrupted then
			return true
		end
	end
	return false
end

---Get the closest human to a position
---@param pos GVector The position to check from
---@return GPlayer|nil closestHuman The closest human player or nil
---@return number closestDist The distance to the closest human (math.huge if none)
function D3bot.ZS.GetClosestHuman(pos)
	local closestHuman = nil
	local closestDist = math.huge
	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(pl) then
			local dist = pl:GetPos():Distance(pos)
			if dist < closestDist then
				closestDist = dist
				closestHuman = pl
			end
		end
	end
	return closestHuman, closestDist
end

---Find humans near a specific position, sorted by distance
---@param pos GVector The position to search from
---@param maxDist number|nil Maximum distance to search (default 2000)
---@return table[] Array of {ply = player, distSqr = distanceSquared} sorted by distance
function D3bot.ZS.FindHumansNearPosition(pos, maxDist)
	maxDist = maxDist or 2000
	local maxDistSqr = maxDist * maxDist
	local humans = {}
	for _, ply in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(ply) then
			local distSqr = pos:DistToSqr(ply:GetPos())
			if distSqr < maxDistSqr then
				table.insert(humans, {ply = ply, distSqr = distSqr})
			end
		end
	end
	table.sort(humans, function(a, b) return a.distSqr < b.distSqr end)
	return humans
end

---Get the Flesh Creeper class index
---@return number|nil The class index or nil if not found
function D3bot.ZS.GetFleshCreeperIndex()
	for idx, class in pairs(GAMEMODE.ZombieClasses) do
		if class.Name == "Flesh Creeper" then
			return class.Index
		end
	end
	return nil
end

---Get all unlocked zombie classes for the current wave (NO bosses - only regular zombies)
---@return table[] Array of zombie class tables
function D3bot.ZS.GetUnlockedZombieClasses()
	local currentWave = GAMEMODE:GetWave()
	local maxWave = GAMEMODE:GetNumberOfWaves() or 6
	local unlockedClasses = {}

	for className, zombieClass in pairs(GAMEMODE.ZombieClasses) do
		if zombieClass and not zombieClass.Locked then
			-- Check if class is unlocked (Wave property is a fraction of max waves)
			local waveUnlock = zombieClass.Wave or 0
			local isUnlocked = zombieClass.Unlocked or (waveUnlock * maxWave <= currentWave)

			-- Skip special classes that shouldn't be used by bots
			-- IMPORTANT: Skip ALL bosses - they should only come from game's forceboss system
			local skipClass = zombieClass.Hidden or zombieClass.Disabled or
			                  className == "Crow" or className == "Initial Dead" or
			                  zombieClass.Boss  -- NO BOSSES

			if isUnlocked and not skipClass then
				table.insert(unlockedClasses, zombieClass)
			end
		end
	end

	return unlockedClasses
end

---Get zombie spawn points
---@return GVector[] Array of spawn positions
function D3bot.ZS.GetZombieSpawnPoints()
	local spawns = {}
	local spawnClasses = {"info_player_undead", "info_player_zombie", "info_zombiespawn"}
	for _, className in ipairs(spawnClasses) do
		for _, spawn in ipairs(ents.FindByClass(className)) do
			if IsValid(spawn) then
				table.insert(spawns, spawn:GetPos())
			end
		end
	end
	return spawns
end

---Find all barricades within a certain distance from a position
---@param pos GVector The position to search from
---@param maxDistance number|nil Maximum distance to search (default 1000)
---@return table[] Array of {ent = entity, pos = position, dist = distance} sorted by distance
function D3bot.ZS.FindBarricadesNearPosition(pos, maxDistance)
	maxDistance = maxDistance or 1000
	local barricades = {}

	for _, ent in ipairs(ents.GetAll()) do
		if IsValid(ent) then
			local isBarricade = false
			if ent.D3bot_IsBarricade then
				isBarricade = ent:D3bot_IsBarricade()
			elseif ent:GetClass() == "prop_physics" and ent.GetNumNails and ent:GetNumNails() > 0 then
				isBarricade = true
			end

			if isBarricade then
				local dist = ent:GetPos():Distance(pos)
				if dist < maxDistance then
					table.insert(barricades, {ent = ent, pos = ent:GetPos(), dist = dist})
				end
			end
		end
	end

	table.sort(barricades, function(a, b) return a.dist < b.dist end)
	return barricades
end

---Find the nearest barricade to a position
---@param pos GVector The position to search from
---@param maxDistance number|nil Maximum distance to search (default 1000)
---@return GEntity|nil nearestBarricade The nearest barricade entity or nil
---@return number nearestDist The distance to nearest barricade (math.huge if none)
function D3bot.ZS.FindNearestBarricade(pos, maxDistance)
	local barricades = D3bot.ZS.FindBarricadesNearPosition(pos, maxDistance)
	if #barricades > 0 then
		return barricades[1].ent, barricades[1].dist
	end
	return nil, math.huge
end

---Check if path between two positions is blocked by a barricade
---Uses line trace to detect barricades along the path
---@param startPos GVector Start position
---@param endPos GVector End position
---@return GEntity|nil blockingBarricade The barricade blocking the path, or nil
---@return GVector|nil hitPos The position where the barricade was hit
function D3bot.ZS.IsPathBlockedByBarricade(startPos, endPos)
	-- Trace from start to end
	local tr = util.TraceLine({
		start = startPos + Vector(0, 0, 40), -- Trace at ~waist height
		endpos = endPos + Vector(0, 0, 40),
		mask = MASK_SOLID
	})

	if tr.Hit and IsValid(tr.Entity) then
		local ent = tr.Entity
		local isBarricade = false
		if ent.D3bot_IsBarricade then
			isBarricade = ent:D3bot_IsBarricade()
		elseif ent:GetClass() == "prop_physics" and ent.GetNumNails and ent:GetNumNails() > 0 then
			isBarricade = true
		end

		if isBarricade then
			return ent, tr.HitPos
		end
	end

	-- Also check with hull trace for better coverage
	local hullTr = util.TraceHull({
		start = startPos + Vector(0, 0, 36),
		endpos = endPos + Vector(0, 0, 36),
		mins = Vector(-16, -16, -32),
		maxs = Vector(16, 16, 32),
		mask = MASK_SOLID
	})

	if hullTr.Hit and IsValid(hullTr.Entity) then
		local ent = hullTr.Entity
		local isBarricade = false
		if ent.D3bot_IsBarricade then
			isBarricade = ent:D3bot_IsBarricade()
		elseif ent:GetClass() == "prop_physics" and ent.GetNumNails and ent:GetNumNails() > 0 then
			isBarricade = true
		end

		if isBarricade then
			return ent, hullTr.HitPos
		end
	end

	return nil, nil
end

---Check if position is near a barricade with nails
---@param pos GVector The position to check
---@param distance number The maximum distance to consider
---@return boolean True if near a barricade
function D3bot.ZS.IsNearBarricade(pos, distance)
	for _, ent in ipairs(ents.GetAll()) do
		if IsValid(ent) then
			-- Check if entity has the barricade check method
			local isBarricade = false
			if ent.D3bot_IsBarricade then
				isBarricade = ent:D3bot_IsBarricade()
			elseif ent:GetClass() == "prop_physics" and ent.GetNumNails and ent:GetNumNails() > 0 then
				isBarricade = true
			end
			if isBarricade and ent:GetPos():Distance(pos) < distance then
				return true
			end
		end
	end
	return false
end

---Check if position is near an unnailed prop (prop_physics that could be used for barricading)
---This helps prevent building nests where humans might place barricades
---@param pos GVector The position to check
---@param distance number The maximum distance to consider
---@return boolean True if near an unnailed prop
function D3bot.ZS.IsNearUnnailedProp(pos, distance)
	for _, ent in ipairs(ents.FindByClass("prop_physics")) do
		if IsValid(ent) then
			-- Skip props that are already nailed (those are handled by IsNearBarricade)
			local isNailed = ent.GetNumNails and ent:GetNumNails() > 0
			if not isNailed then
				-- Check if this prop is within distance
				if ent:GetPos():Distance(pos) < distance then
					return true
				end
			end
		end
	end
	return false
end

---Check if position is near zombie spawn points
---@param pos GVector The position to check
---@param distance number|nil The maximum distance to consider (default 500)
---@return boolean True if near a zombie spawn
function D3bot.ZS.IsNearZombieSpawn(pos, distance)
	distance = distance or 500
	-- Check zombie spawn point entities
	local spawnClasses = {"info_player_undead", "info_player_zombie", "info_zombiespawn"}
	for _, className in ipairs(spawnClasses) do
		for _, spawn in ipairs(ents.FindByClass(className)) do
			if IsValid(spawn) and spawn:GetPos():Distance(pos) < distance then
				return true
			end
		end
	end
	return false
end

---Check if position is near gas/poison clouds
---@param pos GVector The position to check
---@param distance number|nil The maximum distance to consider (default 300)
---@return boolean True if near gas
function D3bot.ZS.IsNearGas(pos, distance)
	distance = distance or 300
	-- Check gas/poison entities (including main ZS gamemode class "zombiegasses")
	local gasClasses = {
		"zombiegasses",              -- Main ZS gamemode gas spawner
		"prop_poisongas",
		"env_poisongas",
		"point_poisongas",
		"prop_gascan",
		"env_zombiegas",
		"point_zombiegasser",
		"info_zombiegas",
		"prop_zombiegas",
		"prop_deployableemitter_gas",
		"status_poisonzombie"
	}
	for _, className in ipairs(gasClasses) do
		for _, gas in ipairs(ents.FindByClass(className)) do
			if IsValid(gas) and gas:GetPos():Distance(pos) < distance then
				return true
			end
		end
	end
	return false
end

---Check if position is hidden from nearby humans (behind walls)
---@param pos GVector The position to check
---@param checkDist number|nil The maximum distance to check for humans (default 1500)
---@return boolean True if position is NOT visible to any human within checkDist
function D3bot.ZS.IsHiddenFromHumans(pos, checkDist)
	checkDist = checkDist or 1500
	local checkDistSqr = checkDist * checkDist
	local traceHeight = Vector(0, 0, 40) -- Check at nest height

	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(pl) then
			local humanPos = pl:GetPos()
			if humanPos:DistToSqr(pos) < checkDistSqr then
				-- Trace from human eye position to nest position
				local tr = util.TraceLine({
					start = humanPos + Vector(0, 0, 64), -- Human eye height
					endpos = pos + traceHeight,
					mask = MASK_SOLID_BRUSHONLY -- Only check world geometry, not props
				})

				-- If trace didn't hit anything, human can see this position
				if not tr.Hit or tr.Fraction > 0.95 then
					return false -- Position is visible to this human
				end
			end
		end
	end

	return true -- Position is hidden from all nearby humans
end

---Count all built nests globally
---@return number The total number of built nests
function D3bot.ZS.CountAllBuiltNests()
	local count = 0
	for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(ent) and ent:GetNestBuilt() then
			count = count + 1
		end
	end
	return count
end

---Count bot's own built nests
---@param bot GPlayer The bot to check nests for
---@return number The number of built nests owned by this bot
function D3bot.ZS.CountOwnBuiltNests(bot)
	local uid = bot:UniqueID()
	local count = 0
	for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(ent) and ent.OwnerUID == uid and ent:GetNestBuilt() then
			count = count + 1
		end
	end
	return count
end

---Find the nearest built nest to a position
---@param pos GVector The position to search from
---@return GEntity|nil nearestNest The nearest built nest or nil
---@return number nearestDistSqr The squared distance to the nearest nest (math.huge if none)
function D3bot.ZS.FindNearestBuiltNest(pos)
	local nearestNest = nil
	local nearestDistSqr = math.huge
	for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(nest) and nest:GetNestBuilt() then
			local distSqr = pos:DistToSqr(nest:GetPos())
			if distSqr < nearestDistSqr then
				nearestDistSqr = distSqr
				nearestNest = nest
			end
		end
	end
	return nearestNest, nearestDistSqr
end

---Find uncorrupted (blue) sigils, optionally sorted by distance to a position
---@param pos GVector|nil The position to sort by distance from (optional)
---@return table[] Array of {sigil = entity, distSqr = distanceSquared} sorted by distance if pos provided
function D3bot.ZS.FindUncorruptedSigils(pos)
	local sigils = {}
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
		if IsValid(sigil) and not corrupted then
			local distSqr = pos and pos:DistToSqr(sigil:GetPos()) or 0
			table.insert(sigils, {sigil = sigil, distSqr = distSqr})
		end
	end
	if pos then
		table.sort(sigils, function(a, b) return a.distSqr < b.distSqr end)
	end
	return sigils
end

---Find the nearest sigil to a position (corrupted or not)
---@param pos GVector The position to search from
---@return GEntity|nil nearestSigil The nearest sigil or nil
---@return number nearestDistSqr The squared distance to the nearest sigil (math.huge if none)
function D3bot.ZS.FindNearestSigil(pos)
	local nearestSigil = nil
	local nearestDistSqr = math.huge
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		if IsValid(sigil) then
			local distSqr = pos:DistToSqr(sigil:GetPos())
			if distSqr < nearestDistSqr then
				nearestDistSqr = distSqr
				nearestSigil = sigil
			end
		end
	end
	return nearestSigil, nearestDistSqr
end

---Check if a prop should be ignored (metal tables, etc.) - move around instead of attacking
---@param ent GEntity The entity to check
---@return boolean True if the prop should be ignored
function D3bot.ZS.IsIgnorableProp(ent)
	if not IsValid(ent) then return false end

	local entClass = ent:GetClass()

	-- Ignore prop_physics that are not barricades (tables, chairs, etc.)
	if entClass == "prop_physics" or entClass == "prop_physics_multiplayer" then
		-- Check if it's nailed (barricade) - don't ignore those
		if ent.GetNumNails and ent:GetNumNails() > 0 then
			return false
		end
		-- Check if it's a barricade object - don't ignore those
		if ent.IsBarricadeObject and ent:IsBarricadeObject() then
			return false
		end
		-- Check model for specific ignorable props (metal tables, vending machines, etc.)
		local model = ent:GetModel()
		if model then
			model = string.lower(model)
			-- Metal tables, kitchen counters, etc.
			if string.find(model, "table") or
			   string.find(model, "counter") or
			   string.find(model, "desk") or
			   string.find(model, "bench") or
			   string.find(model, "shelf") or
			   string.find(model, "cabinet") or
			   string.find(model, "locker") or
			   string.find(model, "vending") then
				return true
			end
		end
		-- Ignore non-nailed props in general
		return true
	end

	return false
end

---Check if a position is near the path humans walk (between spawn/cade and sigils, or between spawns and humans)
---@param pos GVector The position to check
---@param pathWidth number|nil How close to path counts as "on path" (default 200)
---@return boolean True if position is on a common human walking path
function D3bot.ZS.IsNearHumanPath(pos, pathWidth)
	pathWidth = pathWidth or 200 -- How close to path counts as "on path"

	-- Get human positions (current defenders - represents where they camp/walk)
	local humanPositions = {}
	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(pl) then
			table.insert(humanPositions, pl:GetPos())
		end
	end

	-- Also get human spawn points as path endpoints
	local spawnPoints = ents.FindByClass("info_player_human")
	for _, spawn in ipairs(spawnPoints) do
		if IsValid(spawn) then
			table.insert(humanPositions, spawn:GetPos())
		end
	end

	if #humanPositions < 2 then return false end -- Need at least 2 points to form a path

	-- Helper function to check if pos is near a line segment
	local function isNearLineSegment(startPos, endPos)
		local lineDir = endPos - startPos
		local lineLength = lineDir:Length()
		if lineLength < 100 then return false end -- Only check meaningful distances

		lineDir = lineDir / lineLength -- Normalize

		-- Project pos onto the line
		local toPos = pos - startPos
		local projection = toPos:Dot(lineDir)

		-- Check if projection is within the line segment
		if projection > 0 and projection < lineLength then
			-- Calculate perpendicular distance to the line
			local projectedPoint = startPos + lineDir * projection
			local perpDist = pos:Distance(projectedPoint)

			-- Also check height difference (don't count if significantly above/below)
			local heightDiff = math.abs(pos.z - projectedPoint.z)

			if perpDist < pathWidth and heightDiff < 100 then
				return true -- Position is on a path
			end
		end
		return false
	end

	-- Get all sigils
	local sigils = ents.FindByClass("prop_obj_sigil")

	if #sigils > 0 then
		-- Sigils exist: Check paths between human positions and sigils
		for _, sigilEnt in ipairs(sigils) do
			if IsValid(sigilEnt) then
				local sigilPos = sigilEnt:GetPos()
				for _, humanPos in ipairs(humanPositions) do
					if isNearLineSegment(humanPos, sigilPos) then
						return true
					end
				end
			end
		end
	else
		-- No sigils: Check paths between human spawn points and current human positions
		-- This helps avoid building on paths humans use to reach their teammates
		local spawnPositions = {}
		for _, spawn in ipairs(spawnPoints) do
			if IsValid(spawn) then
				table.insert(spawnPositions, spawn:GetPos())
			end
		end

		-- Check paths from spawns to humans
		for _, spawnPos in ipairs(spawnPositions) do
			for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
				if D3bot.ZS.IsValidHumanTarget(pl) then
					if isNearLineSegment(spawnPos, pl:GetPos()) then
						return true
					end
				end
			end
		end

		-- Also check paths between humans (they often move between each other)
		local humans = team.GetPlayers(TEAM_HUMAN)
		for i = 1, #humans - 1 do
			if D3bot.ZS.IsValidHumanTarget(humans[i]) then
				for j = i + 1, #humans do
					if D3bot.ZS.IsValidHumanTarget(humans[j]) then
						if isNearLineSegment(humans[i]:GetPos(), humans[j]:GetPos()) then
							return true
						end
					end
				end
			end
		end
	end

	return false
end

---Count current Flesh Creeper bots
---@return number The count of alive Flesh Creeper bots
function D3bot.ZS.CountFleshCreeperBots()
	local count = 0
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply:IsBot() and ply:Alive() and ply:Team() == TEAM_UNDEAD then
			local classTable = ply:GetZombieClassTable()
			if classTable and classTable.Name == "Flesh Creeper" then
				count = count + 1
			end
		end
	end
	return count
end

---Check if bot can become Flesh Creeper (max limit check)
---@param maxFleshCreepers number|nil Maximum allowed (default 2)
---@return boolean True if another bot can become Flesh Creeper
function D3bot.ZS.CanBecomeFleshCreeper(maxFleshCreepers)
	maxFleshCreepers = maxFleshCreepers or 2
	local fleshCreeperHandler = D3bot.Handlers.Undead_Fleshcreeper
	if fleshCreeperHandler and fleshCreeperHandler.MaxFleshCreeperBots then
		maxFleshCreepers = fleshCreeperHandler.MaxFleshCreeperBots
	end
	return D3bot.ZS.CountFleshCreeperBots() < maxFleshCreepers
end

---Check if bot has any nests (built or not)
---@param bot GPlayer The bot to check
---@return boolean True if the bot has any nests
function D3bot.ZS.HasAnyNests(bot)
	local uid = bot:UniqueID()
	for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(ent) and ent.OwnerUID == uid then
			return true
		end
	end
	return false
end

---Calculate the distance between two positions using NavMesh (A* Pathfinding)
---@param startPos GVector Starting position
---@param endPos GVector Ending position
---@param abilities table|nil Optional abilities table
---@return number|nil distance The distance in units, or nil if no path exists
function D3bot.ZS.GetPathDistance(startPos, endPos, abilities)
    if not startPos or not endPos then return nil end
    
    local mapNavMesh = D3bot.MapNavMesh
    if not mapNavMesh then 
        return startPos:Distance(endPos) 
    end

    local startNode = mapNavMesh:GetNearestNodeOrNil(startPos)
    local endNode = mapNavMesh:GetNearestNodeOrNil(endPos)

    -- Якщо вузли не знайдено або це один і той самий вузол
    if not startNode or not endNode or startNode == endNode then 
        return startPos:Distance(endPos) 
    end

    abilities = abilities or {Walk = true, Jump = 70, Height = 72, Crab = false}

    -- СПРАВЖНІЙ ПРОРАХУНОК ШЛЯХУ (A*)
    local path = D3bot.GetBestMeshPathOrNil(startNode, endNode, nil, nil, abilities)
    
    -- Якщо шляху немає (наприклад, люди повністю забарикадувались у кімнаті без дірок)
    if not path or #path < 2 then 
        return nil 
    end

    -- Рахуємо реальну дистанцію по вузлах (як зомбі буде бігти ногами)
    local totalDist = startPos:Distance(path[1].Pos)
    for i = 1, #path - 1 do
        totalDist = totalDist + path[i].Pos:Distance(path[i + 1].Pos)
    end
    totalDist = totalDist + path[#path].Pos:Distance(endPos)

    return totalDist
end

-- ---Find the spawn point (from a list) with the shortest path to any human
-- ---@param spawnPoints table Array of spawn point entities
-- ---@param humans table Array of human players
-- ---@return GEntity|nil bestSpawn The best spawn point entity
-- ---@return number bestDist The path distance to nearest human (math.huge if none)
-- function D3bot.ZS.FindBestSpawnByPathDistance(spawnPoints, humans)
-- 	local bestSpawn = nil
-- 	local bestDist = math.huge

-- 	for _, spawn in ipairs(spawnPoints) do
-- 		if IsValid(spawn) then
-- 			local spawnPos = spawn:GetPos()

-- 			-- Find shortest path to any human from this spawn
-- 			for _, human in ipairs(humans) do
-- 				if IsValid(human) and human:Alive() then
-- 					local pathDist = D3bot.ZS.GetPathDistance(spawnPos, human:GetPos())
-- 					if pathDist and pathDist < bestDist then
-- 						bestDist = pathDist
-- 						bestSpawn = spawn
-- 					end
-- 				end
-- 			end
-- 		end
-- 	end

-- 	return bestSpawn, bestDist
-- end

---Get a corrupted (green) sigil entity if any exists.
---@return GEntity|nil corruptedSigil The corrupted sigil entity, or nil if none
function D3bot.ZS.GetCorruptedSigil()
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
		if IsValid(sigil) and corrupted then
			return sigil
		end
	end
	return nil
end

---Check if any blue (uncorrupted) sigil exists.
---@return boolean True if at least one uncorrupted sigil exists
function D3bot.ZS.HasUncorruptedSigil()
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
		if IsValid(sigil) and not corrupted then
			return true
		end
	end
	return false
end

---Check if any humans are near a specific sigil.
---@param sigil GEntity The sigil to check
---@param distance number|nil Check distance (default 2000)
---@return boolean True if any valid human is within distance of the sigil
function D3bot.ZS.AreHumansNearSigil(sigil, distance)
	if not IsValid(sigil) then return false end
	distance = distance or 2000

	local sigilPos = sigil:GetPos()
	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(pl) then
			if pl:GetPos():Distance(sigilPos) < distance then
				return true
			end
		end
	end
	return false
end

---Check if any humans are near any blue (uncorrupted) sigil.
---@param distance number|nil Check distance (default 2000)
---@return boolean True if any human is near any uncorrupted sigil
function D3bot.ZS.AreHumansNearAnyBlueSigil(distance)
	distance = distance or 2000
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
		if IsValid(sigil) and not corrupted then
			if D3bot.ZS.AreHumansNearSigil(sigil, distance) then
				return true
			end
		end
	end
	return false
end

---Check if a position is too close to any nest.
---@param pos GVector Position to check
---@param minDist number|nil Minimum distance (default 192, matches GAMEMODE.CreeperNestDistBuildNest)
---@return boolean tooClose True if position is too close to a nest
---@return GEntity|nil blockingNest The blocking nest entity if too close
function D3bot.ZS.IsTooCloseToNest(pos, minDist)
	minDist = minDist or 192
	for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(nest) then
			-- Use 2D distance to match the game's SkewedDistance calculation
			local nestPos = nest:GetPos()
			local dist2D = math.sqrt((pos.x - nestPos.x)^2 + (pos.y - nestPos.y)^2)
			if dist2D < minDist then
				return true, nest
			end
		end
	end
	return false, nil
end

---Check if a position has a clear floor (not blocked by props).
---Useful for validating build positions.
---@param pos GVector Position to check
---@return boolean hasClear True if floor is clear
---@return GVector|nil groundPos The validated ground position if clear
function D3bot.ZS.HasClearFloor(pos)
	-- Trace down to find ground
	local trDown = util.TraceLine({
		start = pos + Vector(0, 0, 50),
		endpos = pos - Vector(0, 0, 50),
		mask = MASK_SOLID_BRUSHONLY
	})

	if not trDown.Hit or not trDown.HitWorld or trDown.HitSky then
		return false
	end

	local groundPos = trDown.HitPos + Vector(0, 0, 4)

	-- Check floor normal (must be relatively flat)
	if trDown.HitNormal.z < 0.75 then
		return false
	end

	-- Hull trace to check for blocking props
	local hullTrace = util.TraceHull({
		start = groundPos,
		endpos = groundPos,
		mins = Vector(-20, -20, 0),
		maxs = Vector(20, 20, 40),
		mask = MASK_PLAYERSOLID
	})

	-- If we hit something solid (world or prop), position is blocked
	if hullTrace.Hit and (hullTrace.HitWorld or (IsValid(hullTrace.Entity) and not hullTrace.Entity:IsPlayer())) then
		return false
	end

	return true, groundPos
end

---Get any BUILT nest near a corrupted sigil (within specified distance).
---@param corruptedSigil GEntity The corrupted sigil to search near
---@param maxDistance number|nil Maximum distance to search (default 1500)
---@return GEntity|nil nearestNest The closest built nest near the sigil, or nil
function D3bot.ZS.GetNestNearCorruptedSigil(corruptedSigil, maxDistance)
	if not IsValid(corruptedSigil) then return nil end
	maxDistance = maxDistance or 1500

	local sigilPos = corruptedSigil:GetPos()
	local closestNest = nil
	local closestDist = maxDistance

	for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
		-- Only consider fully built nests
		if IsValid(ent) and ent.GetNestBuilt and ent:GetNestBuilt() then
			local dist = ent:GetPos():Distance(sigilPos)
			if dist < closestDist then
				closestDist = dist
				closestNest = ent
			end
		end
	end
	return closestNest
end

---Get any built nest (useful for nest destruction/relocation).
---@return GEntity|nil builtNest A built nest entity, or nil if none exist
function D3bot.ZS.GetAnyBuiltNest()
	for _, ent in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(ent) and ent.GetNestBuilt and ent:GetNestBuilt() then
			return ent
		end
	end
	return nil
end

---Find humans near green sigil or isolated (not near any sigil).
---Useful for nest relocation targeting.
---@param sigilDistance number|nil Distance to consider "near" a sigil (default 2000)
---@return GPlayer|nil human The human player found
---@return string|nil posType Position type: "green_sigil" or "isolated"
function D3bot.ZS.FindHumansNearGreenOrIsolated(sigilDistance)
	sigilDistance = sigilDistance or 2000
	local sigils = ents.FindByClass("prop_obj_sigil")

	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(pl) then
			local plPos = pl:GetPos()
			local nearAnySigil = false
			local nearGreenSigil = false

			for _, sigil in ipairs(sigils) do
				if IsValid(sigil) then
					local dist = plPos:Distance(sigil:GetPos())
					if dist < sigilDistance then
						nearAnySigil = true
						local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
						if corrupted then
							nearGreenSigil = true
						end
					end
				end
			end

			-- Human is near a green sigil
			if nearGreenSigil then
				return pl, "green_sigil"
			end

			-- Human is isolated (not near any sigil)
			if not nearAnySigil then
				return pl, "isolated"
			end
		end
	end

	return nil, nil
end

---Find human that is NOT covered by any built nest (far from all nests).
---@param nestCoverageDistance number|nil Coverage distance (default 2000)
---@return GPlayer|nil human The uncovered human player
---@return string|nil posType Position type: "green_sigil", "isolated", or "blue_uncovered"
function D3bot.ZS.FindHumanNotCoveredByNest(nestCoverageDistance)
	nestCoverageDistance = nestCoverageDistance or 2000
	local nests = {}

	-- Get all built nests
	for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(nest) and nest.GetNestBuilt and nest:GetNestBuilt() then
			table.insert(nests, nest)
		end
	end

	if #nests == 0 then return nil, nil end

	-- Find humans not covered by any nest
	for _, pl in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if D3bot.ZS.IsValidHumanTarget(pl) then
			local plPos = pl:GetPos()
			local coveredByNest = false

			for _, nest in ipairs(nests) do
				if plPos:Distance(nest:GetPos()) < nestCoverageDistance then
					coveredByNest = true
					break
				end
			end

			if not coveredByNest then
				-- Determine the type of uncovered location
				local nearGreen = false
				local nearBlue = false
				for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
					if IsValid(sigil) then
						local dist = plPos:Distance(sigil:GetPos())
						if dist < 2000 then
							local corrupted, _ = D3bot.ZS.IsSigilCorrupted(sigil)
							if corrupted then
								nearGreen = true
							else
								nearBlue = true
							end
						end
					end
				end

				-- Prioritize: green_sigil > isolated > blue_uncovered
				if nearGreen then
					return pl, "green_sigil"
				elseif not nearBlue then
					return pl, "isolated"
				else
					return pl, "blue_uncovered"
				end
			end
		end
	end

	return nil, nil
end

--------------------------------------------------------------------------------
-- SMART ZOMBIE SPAWN SELECTION
-- Regular zombies: Spawn at point with closest path distance to humans
--                  (combines nests, spawn points, and gas spawners)
-- Boss zombies: Random selection from boss spawn points (or fallback to regular spawns)
--------------------------------------------------------------------------------

-- Configuration for smart spawn
D3bot.ZS.SmartSpawn = D3bot.ZS.SmartSpawn or {}
D3bot.ZS.SmartSpawn.Enabled = true          -- Enable/disable smart spawning
D3bot.ZS.SmartSpawn.Debug = false           -- Debug output

---Get all active zombie nests (built nests only)
---@return table[] Array of {entity, pos, type="nest"}
function D3bot.ZS.GetActiveNests()
	local nests = {}

	for _, nest in ipairs(ents.FindByClass("prop_creepernest")) do
		if IsValid(nest) and nest.GetNestBuilt and nest:GetNestBuilt() then
			table.insert(nests, {
				entity = nest,
				pos = nest:GetPos(),
				type = "nest"
			})
		end
	end

	return nests
end

---Get all zombie spawn points (spawn entities)
---@return table[] Array of {entity, pos, type="spawn_point"}
function D3bot.ZS.GetZombieSpawnEntities()
	local spawns = {}

	local spawnClasses = {"info_player_undead", "info_player_zombie", "info_zombiespawn"}
	for _, className in ipairs(spawnClasses) do
		for _, spawn in ipairs(ents.FindByClass(className)) do
			if IsValid(spawn) then
				-- Check if spawn point is disabled (matches GetBossSpawnPoints behavior)
				local isDisabled = spawn.Disabled == true
				if not isDisabled then
					table.insert(spawns, {
						entity = spawn,
						pos = spawn:GetPos(),
						type = "spawn_point"
					})
				end
			end
		end
	end

	return spawns
end

---Get all zombie gas spawners
---@return table[] Array of {entity, pos, type="gas", radius=number}
function D3bot.ZS.GetZombieGasSpawners()
	local gasSpawns = {}

	-- All gas spawner classes (including main ZS gamemode class)
	local gasClasses = {
		"zombiegasses",              -- Main ZS gamemode gas spawner (default radius 400)
		"env_zombiegas",
		"point_zombiegasser",
		"info_zombiegas",
		"prop_zombiegas",
		"prop_deployableemitter_gas",
		"status_poisonzombie"
	}

	for _, className in ipairs(gasClasses) do
		for _, gas in ipairs(ents.FindByClass(className)) do
			if IsValid(gas) then
				-- Check if gas is active (if method exists)
				local isActive = true
				if gas.IsActive then
					isActive = gas:IsActive()
				elseif gas.GetActive then
					isActive = gas:GetActive()
				elseif gas.Disabled then
					isActive = not gas.Disabled
				end

				if isActive then
					-- Get radius if available (zombiegasses uses GetRadius())
					local radius = 400 -- Default ZS gas radius
					if gas.GetRadius then
						radius = gas:GetRadius()
					end

					table.insert(gasSpawns, {
						entity = gas,
						pos = gas:GetPos(),
						type = "gas",
						radius = radius
					})
				end
			end
		end
	end

	return gasSpawns
end

---Get gas spawner positions for strategic nest placement scoring
---Returns positions and radii of all active gas spawners for coverage optimization
---@return table[] Array of {pos=Vector, radius=number}
function D3bot.ZS.GetGasSpawnerPositions()
	local gasPositions = {}
	local gasSpawners = D3bot.ZS.GetZombieGasSpawners()

	for _, gas in ipairs(gasSpawners) do
		table.insert(gasPositions, {
			pos = gas.pos,
			radius = gas.radius or 400
		})
	end

	return gasPositions
end

---Check if a position is within coverage of any gas spawner
---@param pos GVector The position to check
---@param gasPositions table[] Array of {pos, radius} from GetGasSpawnerPositions
---@return boolean covered True if position is within a gas cloud's coverage
---@return number|nil distance Distance to nearest gas center (if covered)
function D3bot.ZS.IsWithinGasCoverage(pos, gasPositions)
	for _, gas in ipairs(gasPositions) do
		local dist = pos:Distance(gas.pos)
		if dist <= gas.radius then
			return true, dist
		end
	end
	return false, nil
end

---Calculate strategic value of a nest position relative to gas spawners
---Nests should complement gas coverage, not overlap with it
---@param pos GVector The potential nest position
---@param gasPositions table[] Array of {pos, radius} from GetGasSpawnerPositions
---@param humans table[] Array of human data with positions
---@return number score Positive = good complementary position, negative = overlapping
function D3bot.ZS.CalculateGasCoverageScore(pos, gasPositions, humans)
	if not gasPositions or #gasPositions == 0 then
		return 0 -- No gas spawners, no score adjustment
	end

	local score = 0

	-- Check overlap with gas clouds (penalize)
	local isInGas, gasDistance = D3bot.ZS.IsWithinGasCoverage(pos, gasPositions)
	if isInGas then
		-- PENALTY: Nest inside gas cloud = wasted coverage
		score = score - 100
		return score
	end

	-- Find nearest gas spawner
	local nearestGasDist = math.huge
	local nearestGasPos = nil
	for _, gas in ipairs(gasPositions) do
		local dist = pos:Distance(gas.pos)
		if dist < nearestGasDist then
			nearestGasDist = dist
			nearestGasPos = gas.pos
		end
	end

	-- IDEAL: Nest should be 500-1200 units from nearest gas (complementary coverage)
	-- Too close (< 500) = overlapping effective areas
	-- Too far (> 1200) = gaps in coverage
	if nearestGasDist >= 500 and nearestGasDist <= 1200 then
		-- Perfect complementary distance
		score = score + 75
		-- Bonus for being closer to ideal (800 units)
		local idealDist = 800
		score = score + math.max(0, 50 - math.abs(nearestGasDist - idealDist) / 10)
	elseif nearestGasDist > 1200 and nearestGasDist <= 2000 then
		-- Acceptable but not ideal
		score = score + 25
	elseif nearestGasDist < 500 then
		-- Too close, penalize
		score = score - 50
	end

	-- Check if nest would cover humans not already covered by gas
	-- This rewards nests that expand zombie spawn coverage
	local humansNearGas = 0
	local humansNotNearGas = 0
	for _, humanData in ipairs(humans) do
		local humanInGas = D3bot.ZS.IsWithinGasCoverage(humanData.pos, gasPositions)
		if humanInGas then
			humansNearGas = humansNearGas + 1
		else
			humansNotNearGas = humansNotNearGas + 1
		end
	end

	-- If there are humans NOT covered by gas, and this nest would help reach them
	if humansNotNearGas > 0 then
		-- Check if any uncovered human is closer to this nest position than to gas
		for _, humanData in ipairs(humans) do
			local humanInGas = D3bot.ZS.IsWithinGasCoverage(humanData.pos, gasPositions)
			if not humanInGas then
				local distToNest = pos:Distance(humanData.pos)
				-- If this nest would be within effective spawn range (420-1500) of uncovered human
				if distToNest >= 420 and distToNest <= 1500 then
					score = score + 30 -- Bonus for expanding coverage
				end
			end
		end
	end

	return score
end

---Get all dedicated BOSS zombie spawn points (info_player_zombie_boss, info_player_undead_boss)
---These are special spawn points that ONLY bosses can use (matching vanilla ZS behavior)
---@return table[] Array of {entity, pos, type="boss_spawn"}
function D3bot.ZS.GetBossSpawnPoints()
	local bossSpawns = {}

	-- Dedicated boss spawn point classes (same as vanilla ZS)
	local bossSpawnClasses = {
		"info_player_zombie_boss",
		"info_player_undead_boss"
	}

	for _, className in ipairs(bossSpawnClasses) do
		for _, spawn in ipairs(ents.FindByClass(className)) do
			if IsValid(spawn) then
				-- Check if spawn point is disabled
				local isDisabled = spawn.Disabled == true
				if not isDisabled then
					table.insert(bossSpawns, {
						entity = spawn,
						pos = spawn:GetPos(),
						type = "boss_spawn"
					})
				end
			end
		end
	end

	return bossSpawns
end

---Calculate distance from spawn point to nearest human
---Uses heavily optimized direct distance (DistToSqr) instead of pathfinding
---Works with both players (humans) and entities (sigils)
---@param spawnData table {entity, pos, type}
---@param targets table Array of target entities (players or sigils)
---@return number dist Distance to nearest target (math.huge if no targets)
local function CalculateSpawnToTargetDistance(spawnData, targets)
    -- СТАРУ ЛОГІКУ ЗАКОМЕНТОВАНО 
    --[[
    local bestPathDist = math.huge
    local bestEuclideanDist = math.huge

    for _, target in ipairs(targets) do
        local isValidTarget = false
        if IsValid(target) then
            if target:IsPlayer() then
                isValidTarget = target:Alive()
            else
                isValidTarget = true
            end
        end

        if isValidTarget then
            local targetPos = target:GetPos()

            local pathDist = D3bot.ZS.GetPathDistance(spawnData.pos, targetPos)
            if pathDist and pathDist < bestPathDist then
                bestPathDist = pathDist
            end

            local euclideanDist = spawnData.pos:Distance(targetPos)
            if euclideanDist < bestEuclideanDist then
                bestEuclideanDist = euclideanDist
            end
        end
    end

    if bestPathDist < math.huge then
        return bestPathDist
    elseif bestEuclideanDist < math.huge then
        return bestEuclideanDist * 1.1
    else
        return math.huge
    end
    ]]

    -- НОВА ЛОГІКА: Ультрашвидкий пошук по квадрату дистанції (без math.sqrt)
    local bestDistSqr = math.huge

    for _, target in ipairs(targets) do
        local isValidTarget = false
        if IsValid(target) then
            if target:IsPlayer() then
                isValidTarget = target:Alive()
            else
                isValidTarget = true -- For sigils
            end
        end

        if isValidTarget then
            local distSqr = spawnData.pos:DistToSqr(target:GetPos())
            if distSqr < bestDistSqr then
                bestDistSqr = distSqr
            end
        end
    end

    -- Оскільки ми перевели логіку на DistToSqr, треба повернути звичайну дистанцію,
    -- щоб інші функції (наприклад команди дебагу) показували правильні цифри
    if bestDistSqr < math.huge then
        return math.sqrt(bestDistSqr)
    end
    
    return math.huge
end

---Find the best spawn from a list (closest path to targets)
---@param spawnList table[] Array of spawn data {entity, pos, type}
---@param targets table Array of target entities (players or sigils)
---@return table|nil bestSpawn Best spawn data or nil
---@return number bestDist Path distance to nearest target
local function FindBestSpawnFromList(spawnList, targets)
	local bestSpawn = nil
	local bestDist = math.huge

	for _, spawnData in ipairs(spawnList) do
		spawnData.pathDist = CalculateSpawnToTargetDistance(spawnData, targets)

		if spawnData.pathDist < bestDist then
			bestDist = spawnData.pathDist
			bestSpawn = spawnData
		end
	end

	return bestSpawn, bestDist
end

---Check if a zombie class is a boss
---@param zombieClassName string|nil The zombie class name
---@return boolean True if the class is a boss
function D3bot.ZS.IsBossClass(zombieClassName)
	if not zombieClassName then return false end

	-- Get the zombie class table from GAMEMODE
	if GAMEMODE and GAMEMODE.ZombieClasses then
		for _, classTable in pairs(GAMEMODE.ZombieClasses) do
			if classTable.Name == zombieClassName then
				return classTable.Boss == true
			end
		end
	end

	return false
end

---Select optimal spawn point for zombies
---REGULAR ZOMBIES: Spawn at point with closest path distance to humans (nests, spawn points, or gas spawners)
---BOSS ZOMBIES: Random selection from dedicated boss spawn points (info_player_zombie_boss), fallback to regular spawns
---@param zombieClass string|nil Optional zombie class name for class-specific logic
---@param isBoss boolean|nil Optional override to force boss behavior
---@param targetBehavior string|nil "attack_humans" (default) or "attack_sigil" - determines spawn proximity
---@return GEntity|nil spawnEntity The selected spawn entity
---@return GVector|nil spawnPos The spawn position
---@return string|nil spawnType "nest", "spawn_point", "gas", or "boss_spawn"
---@return number|nil pathDist Path distance to target
function D3bot.ZS.SelectSmartSpawn(zombieClass, isBoss, targetBehavior)
	if not D3bot.ZS.SmartSpawn.Enabled then
		return nil, nil, nil, nil
	end

	local debug = D3bot.ZS.SmartSpawn.Debug

	-- Default to attacking humans if not specified
	targetBehavior = targetBehavior or "attack_humans"

	-- Check if this is a boss zombie (either passed in or detected from class name)
	local bossMode = isBoss or D3bot.ZS.IsBossClass(zombieClass)

	if debug and bossMode then
		print("[SmartSpawn] BOSS DETECTED:", zombieClass, "- using dedicated boss spawn points only (vanilla ZS behavior)")
	end

	-- Get living humans
	local humans = {}
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply:Team() == TEAM_HUMAN and ply:Alive() then
			table.insert(humans, ply)
		end
	end

	-- Get active sigils (for sigil-targeting zombies)
	local sigils = {}
	for _, sigil in ipairs(ents.FindByClass("prop_obj_sigil")) do
		if IsValid(sigil) then
			-- Check if sigil is not corrupted (if the method exists)
			local isActive = true
			if sigil.GetSigilCorrupted then
				isActive = not sigil:GetSigilCorrupted()
			end
			if isActive then
				table.insert(sigils, sigil)
			end
		end
	end

	-- Determine targets based on behavior (with fallback)
	local targets = humans
	local targetType = "humans"
	if targetBehavior == "attack_sigil" and #sigils > 0 then
		targets = sigils
		targetType = "sigil"
		if debug then print("[SmartSpawn] Targeting SIGIL - will spawn closest to sigil") end
	elseif #humans > 0 then
		targets = humans
		targetType = "humans"
		if debug then print("[SmartSpawn] Targeting HUMANS - will spawn closest to humans") end
	elseif #sigils > 0 then
		-- Fallback: no humans, but sigils exist - spawn near sigil
		targets = sigils
		targetType = "sigil"
		if debug then print("[SmartSpawn] No humans, falling back to SIGIL as target") end
	else
		-- No valid targets at all
		if debug then print("[SmartSpawn] No humans or sigils available") end
		return nil, nil, nil, nil
	end

	-- Decision logic
	local selectedSpawn = nil

	--=========================================================================
	-- BOSS ZOMBIES: Random spawn selection (not path-based)
	-- Priority 1: info_player_zombie_boss (random selection if multiple)
	-- Priority 2: info_player_zombie + gas spawners (random selection if multiple)
	-- Bosses CANNOT spawn at: nests
	--=========================================================================
	if bossMode then
		local bossSpawnPoints = D3bot.ZS.GetBossSpawnPoints()
		local regularSpawnPoints = D3bot.ZS.GetZombieSpawnEntities()
		local gasSpawners = D3bot.ZS.GetZombieGasSpawners()

		if debug then
			print("[SmartSpawn] BOSS -> Found", #bossSpawnPoints, "boss spawns,", #regularSpawnPoints, "regular spawns,", #gasSpawners, "gas spawners")
		end

		if #bossSpawnPoints > 0 then
			-- Priority 1: Use dedicated boss spawn points (info_player_zombie_boss)
			-- Random selection from available boss spawn points
			local randomBossSpawn = bossSpawnPoints[math.random(#bossSpawnPoints)]
			selectedSpawn = randomBossSpawn
			if debug then
				print("[SmartSpawn] BOSS -> Using dedicated boss spawn point (random from", #bossSpawnPoints, "available)")
			end
		else
			-- Priority 2: Fallback to regular spawn points + gas spawners
			-- Combine regular spawns and gas spawners into one pool
			local fallbackSpawns = {}
			table.Add(fallbackSpawns, regularSpawnPoints)
			table.Add(fallbackSpawns, gasSpawners)

			if #fallbackSpawns > 0 then
				-- Random selection from combined pool
				local randomFallbackSpawn = fallbackSpawns[math.random(#fallbackSpawns)]
				selectedSpawn = randomFallbackSpawn
				if debug then
					print("[SmartSpawn] BOSS -> No boss spawns, using fallback (random from", #fallbackSpawns, "spawn+gas), type:", randomFallbackSpawn.type)
				end
			else
				-- No spawn points available at all
				if debug then
					print("[SmartSpawn] BOSS -> No spawn points found! Returning nil")
				end
				return nil, nil, nil, nil
			end
		end

	--=========================================================================
	-- REGULAR ZOMBIES: Spawn at the point closest by path distance to target
	-- Combines: nests, spawn points (info_player_zombie), and gas spawners
	-- Picks whichever has the shortest path to target (humans or sigil based on behavior)
	--=========================================================================
	else
		-- Gather ALL spawn options for regular zombies
		local nests = D3bot.ZS.GetActiveNests()
		local spawnPoints = D3bot.ZS.GetZombieSpawnEntities()
		local gasSpawners = D3bot.ZS.GetZombieGasSpawners()

		-- Combine ALL spawn options into one list
		local allSpawnOptions = {}
		table.Add(allSpawnOptions, nests)
		table.Add(allSpawnOptions, spawnPoints)
		table.Add(allSpawnOptions, gasSpawners)

		if debug then
			print("[SmartSpawn] Found:", #nests, "nests,", #spawnPoints, "spawn points,", #gasSpawners, "gas spawners (total:", #allSpawnOptions, ")")
		end

		if #allSpawnOptions == 0 then
			-- No spawn points found for regular zombie
			if debug then print("[SmartSpawn] No valid spawn points found") end
			return nil, nil, nil, nil
		end

		-- Find best spawn from ALL options (closest path to target - humans or sigil)
		local bestSpawn, bestSpawnDist = FindBestSpawnFromList(allSpawnOptions, targets)

		if bestSpawn then
			selectedSpawn = bestSpawn
			if debug then
				print("[SmartSpawn] Using", string.upper(bestSpawn.type), "(closest path to", targetType .. ", dist:", math.floor(bestSpawnDist), ")")
			end
		else
			if debug then print("[SmartSpawn] No valid spawn points found") end
			return nil, nil, nil, nil
		end

		-- Validate spawn position for regular zombies (with fallback)
		if selectedSpawn then
			local pos = selectedSpawn.pos
			local spawnEnt = selectedSpawn.entity

			-- Basic validation - check headroom (filter out spawn entity itself to avoid self-collision)
			-- This matches ZS gamemode's DynamicSpawnIsValid behavior
			local tr = util.TraceHull({
				start = pos + Vector(0, 0, 1),
				endpos = pos + Vector(0, 0, 72),
				mins = Vector(-16, -16, 0),
				maxs = Vector(16, 16, 0),
				filter = {spawnEnt},  -- Filter out the spawn entity (e.g., nest) to avoid detecting itself
				mask = MASK_SOLID_BRUSHONLY
			})

			if tr.Hit then
				if debug then print("[SmartSpawn] Selected spawn blocked, trying next best option") end

				-- Try to find next best unblocked spawn
				-- Remove the blocked spawn from list and find next best
				local fallbackOptions = {}
				for _, opt in ipairs(allSpawnOptions) do
					if opt ~= selectedSpawn then
						table.insert(fallbackOptions, opt)
					end
				end

				if #fallbackOptions > 0 then
					local fallbackSpawn, fallbackDist = FindBestSpawnFromList(fallbackOptions, targets)
					if fallbackSpawn then
						selectedSpawn = fallbackSpawn
						if debug then
							print("[SmartSpawn] Fallback to", string.upper(fallbackSpawn.type), "(path dist:", math.floor(fallbackDist), ")")
						end
					else
						if debug then print("[SmartSpawn] No valid fallback available") end
						return nil, nil, nil, nil
					end
				else
					if debug then print("[SmartSpawn] No fallback options available") end
					return nil, nil, nil, nil
				end
			end
		end
	end

	-- Return selected spawn
	if selectedSpawn then
		return selectedSpawn.entity, selectedSpawn.pos, selectedSpawn.type, selectedSpawn.pathDist
	end

	return nil, nil, nil, nil
end

-- ГЕНЕРАТОР ФУНКЦІЇ ВАРТОСТІ ШЛЯХУ ДЛЯ БОТА
function D3bot.ZS.GetSharedPathCostFunction(bot)
    local mem = bot.D3bot_Mem

    if D3bot.UsingSourceNav then
        return function(cArea, nArea, link)
            local linkMetaData = link:GetMetaData()
            local linkPenalty = linkMetaData and linkMetaData.ZombieDeathCost or 0
            return linkPenalty * (mem.ConsidersPathLethality and 1 or 0)
        end
    else
        return function(node, linkedNode, link)
            local linkMetadata = D3bot.LinkMetadata[link]
            local linkPenalty = linkMetadata and linkMetadata.ZombieDeathCost or 0
            return linkPenalty * (mem.ConsidersPathLethality and 1 or 0)
        end
    end
end

---ConCommand to test smart spawn selection
concommand.Add("d3bot_smartspawn_test", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end

	-- Temporarily enable debug
	local oldDebug = D3bot.ZS.SmartSpawn.Debug
	D3bot.ZS.SmartSpawn.Debug = true

	local entity, pos, spawnType, pathDist = D3bot.ZS.SelectSmartSpawn()

	if pos then
		print("[SmartSpawn TEST] Selected:", spawnType, "at", pos, "pathDist:", pathDist and math.floor(pathDist) or "N/A")

		-- Visual indicator for admins
		if IsValid(ply) then
			local ef = EffectData()
			ef:SetOrigin(pos)
			ef:SetScale(1)
			util.Effect("cball_explode", ef, true, true)
		end
	else
		print("[SmartSpawn TEST] No valid spawn found")
	end

	D3bot.ZS.SmartSpawn.Debug = oldDebug
end)

---ConCommand to list all spawn points with distances
concommand.Add("d3bot_smartspawn_list", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end

	local humans = {}
	for _, p in ipairs(player.GetAll()) do
		if IsValid(p) and p:Team() == TEAM_HUMAN and p:Alive() then
			table.insert(humans, p)
		end
	end

	print("=== ZOMBIE NESTS ===")
	local nests = D3bot.ZS.GetActiveNests()
	for i, nest in ipairs(nests) do
		nest.pathDist = CalculateSpawnToHumanDistance(nest, humans)
		print(string.format("  %d. %s - pathDist: %s", i, tostring(nest.pos),
			nest.pathDist ~= math.huge and math.floor(nest.pathDist) or "N/A"))
	end

	print("=== ZOMBIE SPAWN POINTS ===")
	local spawns = D3bot.ZS.GetZombieSpawnEntities()
	for i, spawn in ipairs(spawns) do
		spawn.pathDist = CalculateSpawnToHumanDistance(spawn, humans)
		print(string.format("  %d. %s - pathDist: %s", i, tostring(spawn.pos),
			spawn.pathDist ~= math.huge and math.floor(spawn.pathDist) or "N/A"))
	end

	print("=== ZOMBIE GAS SPAWNERS ===")
	local gas = D3bot.ZS.GetZombieGasSpawners()
	for i, g in ipairs(gas) do
		g.pathDist = CalculateSpawnToHumanDistance(g, humans)
		print(string.format("  %d. %s - pathDist: %s", i, tostring(g.pos),
			g.pathDist ~= math.huge and math.floor(g.pathDist) or "N/A"))
	end

	print("=== BOSS SPAWN POINTS (info_player_zombie_boss) ===")
	local bossSpawns = D3bot.ZS.GetBossSpawnPoints()
	for i, bs in ipairs(bossSpawns) do
		bs.pathDist = CalculateSpawnToHumanDistance(bs, humans)
		print(string.format("  %d. %s - pathDist: %s", i, tostring(bs.pos),
			bs.pathDist ~= math.huge and math.floor(bs.pathDist) or "N/A"))
	end

	print("=== SUMMARY ===")
	print("Nests:", #nests, "| Spawn Points:", #spawns, "| Gas:", #gas, "| Boss Spawns:", #bossSpawns)
	print("Regular zombies: " .. (D3bot.ZS.SmartSpawn.NestChance * 100) .. "% nest, " ..
		  (D3bot.ZS.SmartSpawn.SpawnPointChance * 100) .. "% spawn/gas")
	print("Boss zombies: 100% boss_spawn (vanilla ZS behavior)")
end)

---ConCommand to toggle smart spawn debug
concommand.Add("d3bot_smartspawn_debug", function(ply, cmd, args)
	if IsValid(ply) and not ply:IsAdmin() then return end

	if args[1] then
		D3bot.ZS.SmartSpawn.Debug = tobool(args[1])
	else
		D3bot.ZS.SmartSpawn.Debug = not D3bot.ZS.SmartSpawn.Debug
	end

	print("[SmartSpawn] Debug:", D3bot.ZS.SmartSpawn.Debug and "ENABLED" or "DISABLED")
end)

print("[D3bot] Loaded sv_zs_utilities.lua - Shared ZS helper functions")
