D3bot.Handlers = {}

-- Debug flag for spawn logging (set to true to enable [D3bot Spawn] console messages)
local DEBUG_SPAWN = false      

local DEBUG_BEHAVIOR = false   
-- Debug flag for Flesh Creeper death logging (set to true to enable natural death messages)
local DEBUG_FLESH_CREEPER = false    

-- TODO: Make search path relative
for i, filename in pairs(file.Find("d3bot/sv_zs_bot_handler/handlers/*.lua", "LUA")) do
	include("handlers/"..filename)
end

local handlerLookup = {}

function FindHandler(zombieClass, team)
	if handlerLookup[team] and handlerLookup[team][zombieClass] then -- TODO: Put cached handler into bot object
		return handlerLookup[team][zombieClass]
	end

	for _, fallback in ipairs({false, true}) do
		for _, handler in pairs(D3bot.Handlers) do
			if handler.Fallback == fallback and handler.SelectorFunction(GAMEMODE.ZombieClasses[zombieClass].Name, team) then
				handlerLookup[team] = {}
				handlerLookup[team][zombieClass] = handler
				return handler
			end
		end
	end
end
local FindHandler = FindHandler

hook.Add("StartCommand", D3bot.BotHooksId, function(pl, cmd)
	if D3bot.IsEnabledCached and pl.D3bot_Mem then

		local handler = FindHandler(pl:GetZombieClass(), pl:Team())
		if handler then
			handler.UpdateBotCmdFunction(pl, cmd)
		end

	end
end)

local NextSupervisorTick = CurTime()
local NextStorePos = CurTime()
hook.Add("Think", D3bot.BotHooksId.."_supervisor", function()
	if not D3bot.IsEnabledCached then return end

	-- General bot handler think function
	for _, bot in ipairs(D3bot.GetBots()) do

		if not D3bot.UseConsoleBots then
			-- Hackish method to get bots back into game. (player.CreateNextBot created bots do not trigger the StartCommand hook while they are dead)
			if not bot:OldAlive() then
				-- Check if bot is ready to spawn (in spectator mode, wave active, etc.)
				local inSpectatorMode = bot:GetObserverMode() ~= OBS_MODE_NONE
				local respawnDelayPassed = not bot.D3bot_RespawnDelayUntil or bot.D3bot_RespawnDelayUntil <= CurTime()
				local canSpawn = inSpectatorMode and GAMEMODE:GetWaveActive() and
				                 (not bot.StartSpectating or bot.StartSpectating <= CurTime()) and
				                 not (GAMEMODE.RoundEnded or bot.Revive or bot.NextSpawnTime) and
				                 respawnDelayPassed

				if canSpawn then
					-- Clear the respawn delay now that we're spawning
					bot.D3bot_RespawnDelayUntil = nil
					-- Bot is ready to spawn - handle spawn ourselves BEFORE PlayerDeathThink can
					local deathClass = bot.DeathClass
					local hasDeathClass = deathClass ~= nil

					-- If DeathClass is set, apply it first
					if hasDeathClass then
						bot:SetZombieClass(deathClass)
						bot.DeathClass = nil
						if DEBUG_SPAWN then print("[D3bot Spawn]", bot:Nick(), "-> Setting class to:", deathClass) end
					end

					-- Use Smart Spawn Selection
					-- REGULAR ZOMBIES: Always spawn at closest path distance to humans
					-- BOSS ZOMBIES: Random selection from dedicated boss spawn points (vanilla ZS behavior)
					local zombieClass = nil
					local isBoss = false
					local zombieClassTable = bot:GetZombieClassTable()
					if zombieClassTable then
						zombieClass = zombieClassTable.Name
						isBoss = zombieClassTable.Boss == true
					end

					-- Always spawn closest to humans
					local targetBehavior = "attack_humans"

					-- Pass target behavior to spawn selection so spawn is chosen close to humans
					local spawnEntity, spawnPos, spawnType, pathDist = D3bot.ZS.SelectSmartSpawn(zombieClass, isBoss, targetBehavior)

					-- DEBUG: Log spawn decision
					if DEBUG_SPAWN then
						local nestCount = #D3bot.ZS.GetActiveNests()
						local spawnPointCount = #D3bot.ZS.GetZombieSpawnEntities()
						local gasCount = #D3bot.ZS.GetZombieGasSpawners()
						local bossSpawnCount = #D3bot.ZS.GetBossSpawnPoints()
						print("[D3bot Spawn]", bot:Nick(),
							"-> Nests:", nestCount,
							"SpawnPts:", spawnPointCount,
							"Gas:", gasCount,
							"BossSpawns:", bossSpawnCount,
							"Selected:", spawnType or "NONE",
							"PathDist:", pathDist and math.floor(pathDist) or "N/A",
							"Class:", zombieClass or "default",
							"Boss:", isBoss and "YES" or "no")
					end

					if spawnEntity and spawnPos then
						-- Smart spawn found a valid location
						bot.ForceDynamicSpawn = spawnEntity
						bot.ForceSpawnAngles = Angle(0, math.random(0, 360), 0)

						-- Use the pre-decided target behavior (already set before spawn selection)
						if not isBoss then
							bot.NestSpawnBehavior = targetBehavior
							if DEBUG_SPAWN then
								print("[D3bot Spawn]", bot:Nick(), "-> Spawning at", string.upper(spawnType),
									"(closest to", targetBehavior == "attack_humans" and "humans" or "sigil", ")")
							end
						else
							-- Boss zombies don't use target-based spawning
							bot.NestSpawnBehavior = nil
							if DEBUG_SPAWN then print("[D3bot Spawn]", bot:Nick(), "-> Spawning at", string.upper(spawnType), "(boss mode)") end
						end

						bot:UnSpectateAndSpawn()
					else
						-- No valid spawn point found via smart spawn - use normal spawn
						if DEBUG_SPAWN then print("[D3bot Spawn]", bot:Nick(), "-> No smart spawn available, using default spawn") end
						bot.ForceDynamicSpawn = nil
						bot.ForceSpawnAngles = nil
						bot.NestSpawnBehavior = nil
						bot:RefreshDynamicSpawnPoint()
						bot:UnSpectateAndSpawn()
					end
				else
					-- Not ready to spawn yet - let PlayerDeathThink handle state transitions
					-- (putting bot from OBS_MODE_NONE into OBS_MODE_CHASE, etc.)
					gamemode.Call("PlayerDeathThink", bot)
				end
			end
		end

		::handler_logic::
		local handler = FindHandler(bot:GetZombieClass(), bot:Team())
		if handler then
			handler.ThinkFunction(bot)
		end
	end

	-- Supervisor think function
	if NextSupervisorTick < CurTime() then
		NextSupervisorTick = CurTime() + 0.05 + math.random() * 0.1
		D3bot.SupervisorThinkFunction()
	end

	-- Store history of all players (For behaviour classification, stuck checking)
	if NextStorePos < CurTime() then
		NextStorePos = CurTime() + 0.9 + math.random() * 0.2
		for _, ply in ipairs(player.GetAll()) do
			ply:D3bot_StorePos()
		end
	end
end)

hook.Add("EntityTakeDamage", D3bot.BotHooksId.."TakeDamage", function(ent, dmg)
	if D3bot.IsEnabledCached then
		if ent:IsPlayer() and ent.D3bot_Mem then
			-- Bot got damaged or damaged itself
			local handler = FindHandler(ent:GetZombieClass(), ent:Team())
			if handler then
				handler.OnTakeDamageFunction(ent, dmg)
			end
		end
		local attacker = dmg:GetAttacker()
		if attacker ~= ent and attacker:IsPlayer() and attacker.D3bot_Mem then
			-- A Bot did damage something
			local handler = FindHandler(attacker:GetZombieClass(), attacker:Team())
			if handler then
				handler.OnDoDamageFunction(attacker, ent, dmg)
			end
			attacker.D3bot_LastDamage = CurTime()
		end
	end
end)

hook.Add("PlayerDeath", D3bot.BotHooksId.."PlayerDeath", function(pl, inflictor, attacker)
	if D3bot.IsEnabledCached and pl.D3bot_Mem then
		local handler = FindHandler(pl:GetZombieClass(), pl:Team())
		if handler then
			handler.OnDeathFunction(pl)
		end

		-- Add death cost to the current link (Навчання навігації)
		local mem = pl.D3bot_Mem
		local nodeOrNil = mem.NodeOrNil
		local nextNodeOrNil = mem.NextNodeOrNil
		if nodeOrNil and nextNodeOrNil then
			local link
			if D3bot.UsingSourceNav then
				link = nodeOrNil:SharesLink( nextNodeOrNil )
			else
				link = nodeOrNil.LinkByLinkedNode[nextNodeOrNil]
			end
			if link then D3bot.LinkMetadata_ZombieDeath(link, D3bot.LinkDeathCostRaise) end
		end
	end

	-- Handle baby bot death (Shadow Child / Giga Child)
	if pl.D3bot_BabyOwner and IsValid(pl.D3bot_BabyOwner) then
		local owner = pl.D3bot_BabyOwner
		owner.D3bot_BabyCount = math.max(0, (owner.D3bot_BabyCount or 1) - 1)
		pl.D3bot_BabyOwner = nil 

		if pl:IsBot() then
			print("[D3bot] Baby bot", pl:Nick(), "died - disconnecting")
			timer.Simple(0.1, function()
				if IsValid(pl) then
					pl:Kick("Baby zombie died")
				end
			end)
		end
	end

	-- Насмішки (Танці)
	if IsValid(attacker) and attacker:IsPlayer() and attacker.D3bot_Mem and attacker:Team() == TEAM_UNDEAD then
		if IsValid(pl) and pl:IsPlayer() and pl:Team() ~= TEAM_UNDEAD and attacker ~= pl then
			if math.random() <= 0.5 then
				local taunts = {"taunt_dance", "taunt_muscle", "taunt_laugh"}
				local selectedTaunt = table.Random(taunts)
				local seqID = attacker:LookupSequence(selectedTaunt)
				
				if seqID and seqID > 0 then
					attacker:AddVCDSequenceToGestureSlot(GESTURE_SLOT_CUSTOM, seqID, 0, true)
					
					local code = string.format([[
						local bot = Entity(%d)
						if IsValid(bot) then
							bot:AddVCDSequenceToGestureSlot(5, %d, 0, true)
						end
					]], attacker:EntIndex(), seqID)
					
					D3bot.PauseSupervisorUntil = CurTime() + 5.0
					BroadcastLua(code)
					
					if DEBUG_BEHAVIOR then
						print("[D3bot Taunt] Зомбі " .. attacker:Nick() .. " флексить над " .. pl:Nick() .. " (" .. selectedTaunt .. ", ID: " .. seqID .. ")!")
					end
				end
			end
		end
	end
end)

local hadBonusByPl = {}
hook.Add("PlayerSpawn", D3bot.BotHooksId.."PlayerSpawn", function(pl)
	if not D3bot.IsEnabledCached then return end
	if pl.D3bot_Mem then
		pl:D3bot_InitializeOrReset()
	end
	if D3bot.IsEnabledCached and D3bot.StartBonus and D3bot.StartBonus > 0 and pl:Team() == TEAM_SURVIVOR then
		local hadBonus = hadBonusByPl[pl]
		hadBonusByPl[pl] = true
		pl:SetPoints(hadBonus and 0 or D3bot.StartBonus)
	end
end)
hook.Add("PreRestartRound", D3bot.BotHooksId.."PreRestartRound", function() hadBonusByPl = {} end)

