-------------------------------------------------
--ZS Commands 1.1 - Swingflip - www.swingflip.net
-------------------------------------------------

local CATEGORY_NAME = "ZS ULX Commands"

--Restart Map--

function ulx.restartmap(calling_ply)
	ulx.fancyLogAdmin( calling_ply, "#A restarted the map.")
	game.ConsoleCommand("changelevel "..string.format(game.GetMap(),".bsp").."\n")
end
local restartmap = ulx.command(CATEGORY_NAME, "ulx restartmap", ulx.restartmap, "!restartmap")
restartmap:defaultAccess( ULib.ACCESS_SUPERADMIN )
restartmap:help( "Reloads the level." )

--Give Ammo--

function ulx.giveammo(calling_ply, amount, ammotype, target_plys)
	local affected_plys = {}
	for i=1, #target_plys do
		local v = target_plys[ i ]
		if v:IsValid() and v:Team() == TEAM_HUMAN and v:Alive() then
			v:GiveAmmo(amount, ammotype)
		end
	end
end

local giveammo = ulx.command( CATEGORY_NAME, "ulx giveammo", ulx.giveammo, "!giveammo" )
giveammo:addParam{ type=ULib.cmds.NumArg, hint="Ammo Amount"}
giveammo:addParam{ type=ULib.cmds.StringArg, hint="Ammo Type"}
giveammo:addParam{ type=ULib.cmds.PlayersArg }
giveammo:defaultAccess(ULib.ACCESS_ADMIN)
giveammo:help( "Gives the specified ammo to the target player(s)." )

--Give Points--

function ulx.givepoints( calling_ply, target_plys, amount )
	for i=1, #target_plys do
		target_plys[ i ]:AddPoints( amount )
	end
	ulx.fancyLogAdmin( calling_ply, "#A gave #i points to #T", amount, target_plys )
end
local takepoints = ulx.command( CATEGORY_NAME, "ulx givepoints", ulx.givepoints, "!givepoints" )
takepoints:addParam{ type=ULib.cmds.PlayersArg }
takepoints:addParam{ type=ULib.cmds.NumArg, hint="points", ULib.cmds.round }
takepoints:defaultAccess( ULib.ACCESS_ADMIN )
takepoints:help( "Gives points to target(s)." )

--Give Weapon--

function ulx.giveweapon( calling_ply, target_plys, weapon )
	
	
	local affected_plys = {}
	for i=1, #target_plys do
		local v = target_plys[ i ]
		
		if not v:Alive() then
		ULib.tsayError( calling_ply, v:Nick() .. " is dead", true )
		
		else
		v:Give(weapon)
		table.insert( affected_plys, v )
		end
	end
	ulx.fancyLogAdmin( calling_ply, "#A gave #T weapon #s", affected_plys, weapon )
end
	
	
local giveweapon = ulx.command( CATEGORY_NAME, "ulx giveweapon", ulx.giveweapon, "!giveweapon" )
giveweapon:addParam{ type=ULib.cmds.PlayersArg }
giveweapon:addParam{ type=ULib.cmds.StringArg, hint="weapon_zs_swingflip" }
giveweapon:defaultAccess( ULib.ACCESS_ADMIN )
giveweapon:help( "Give a player a weapon - !giveweapon" )

--Redeem Player--

function ulx.redeem( calling_ply, target_plys )
	local affected_plys = {}

	for i=1, #target_plys do
		local v = target_plys[ i ]

		if ulx.getExclusive( v, calling_ply ) then
			ULib.tsayError( calling_ply, ulx.getExclusive( v, calling_ply ), true )
		elseif v:Team() != TEAM_UNDEAD then
			ULib.tsayError( calling_ply, v:Nick() .. " is human!", true )
		else
			v:Redeem()
			table.insert( affected_plys, v )
		end
	end

	ulx.fancyLogAdmin( calling_ply, "#A redeemed #T", affected_plys )
end
local redeem = ulx.command( CATEGORY_NAME, "ulx redeem", ulx.redeem, "!redeem" )
redeem:addParam{ type=ULib.cmds.PlayersArg }
redeem:defaultAccess( ULib.ACCESS_ADMIN )
redeem:help( "Redeems target(s)." )

--Fill Turrets--

function ulx.turretammo(calling_ply, amount)
	for _, ent in pairs(ents.FindByClass("prop_gunturret")) do
		ent:SetAmmo(ent:GetAmmo() + amount)
	end
end

local turretammo = ulx.command( CATEGORY_NAME, "ulx turretammo", ulx.turretammo, "!turretammo" )
turretammo:addParam{ type=ULib.cmds.NumArg, hint="Ammo Amount"}
turretammo:defaultAccess(ULib.ACCESS_ADMIN)
turretammo:help( "Gives the specified amount of ammo to all turrets in the game" )

--Wave Active--

function ulx.roundactive(calling_ply, state)
	GAMEMODE:SetWaveActive(state)
end

local roundactive = ulx.command( CATEGORY_NAME, "ulx roundactive", ulx.roundactive, "!roundactive" )
roundactive:addParam{ type=ULib.cmds.BoolArg, hint="Round State"}
roundactive:defaultAccess(ULib.ACCESS_ADMIN)
roundactive:help( "Sets the current wave to active or inactive" )

--Force Boss--

-- Boss dropdown for ULX XGUI (built from GAMEMODE.ZombieClasses)
ulx.zsBossZombieCompletes = ulx.zsBossZombieCompletes or {"Random"}
local FORCEBOSS_BOSSCHOICE_RANDOM = "Random"

local function ForceBossRebuildCompletes()
	if not GAMEMODE or not istable(GAMEMODE.ZombieClasses) then return false end

	local names = {}
	for _, classtable in ipairs(GAMEMODE.ZombieClasses) do
		if classtable and classtable.Boss and isstring(classtable.Name) then
			table.insert(names, classtable.Name)
		end
	end

	if #names == 0 then return false end
	table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)

	for k in pairs(ulx.zsBossZombieCompletes) do
		ulx.zsBossZombieCompletes[k] = nil
	end
	table.insert(ulx.zsBossZombieCompletes, FORCEBOSS_BOSSCHOICE_RANDOM)
	for _, name in ipairs(names) do
		table.insert(ulx.zsBossZombieCompletes, name)
	end

	return true
end

local FORCEBOSS_COMPLETES_TIMER = "ulx_forceboss_build_boss_completes"
local function ForceBossEnsureCompletes()
	if engine.ActiveGamemode and engine.ActiveGamemode() ~= "zombiesurvival" then
		timer.Remove(FORCEBOSS_COMPLETES_TIMER)
		return
	end

	if ForceBossRebuildCompletes() then
		timer.Remove(FORCEBOSS_COMPLETES_TIMER)
		return
	end

	if not timer.Exists(FORCEBOSS_COMPLETES_TIMER) then
		timer.Create(FORCEBOSS_COMPLETES_TIMER, 1, 0, ForceBossEnsureCompletes)
	end
end

hook.Add("InitPostEntity", "ulx_forceboss_build_boss_completes", ForceBossEnsureCompletes)
ForceBossEnsureCompletes()

local function GetRandomBossZombieIndex()
	if not GAMEMODE or not istable(GAMEMODE.ZombieClasses) then return nil end

	local bossclasses = {}
	local bossclassset = {}
	for _, classtable in pairs(GAMEMODE.ZombieClasses) do
		if classtable and classtable.Boss and isnumber(classtable.Index) and not bossclassset[classtable.Index] then
			bossclassset[classtable.Index] = true
			table.insert(bossclasses, classtable.Index)
		end
	end

	if #bossclasses == 0 then return nil end
	return bossclasses[math.random(#bossclasses)]
end

function ulx.forceboss( calling_ply, target_plys, bossindex )
	local affected_plys = {}
	local bossNameSet = {}

	if isstring(bossindex) then
		local trimmed = string.Trim(bossindex)
		if trimmed == "" or string.lower(trimmed) == string.lower(FORCEBOSS_BOSSCHOICE_RANDOM) then
			bossindex = GetRandomBossZombieIndex()
		elseif trimmed:match("^%d+$") then
			bossindex = tonumber(trimmed)
		else
			local resolved
			if GAMEMODE and istable(GAMEMODE.ZombieClasses) then
				for _, classtable in ipairs(GAMEMODE.ZombieClasses) do
					if classtable and classtable.Boss and isnumber(classtable.Index) and isstring(classtable.Name) and string.lower(classtable.Name) == string.lower(trimmed) then
						resolved = classtable.Index
						break
					end
				end
			end

			if resolved then
				bossindex = resolved
			else
				ULib.tsayError(calling_ply, "Invalid boss zombie \"" .. trimmed .. "\".", true)
				return
			end
		end
	end

	for i=1, #target_plys do
		local v = target_plys[ i ]

		if v:IsFrozen() then
			ULib.tsayError( calling_ply, v:Nick() .. " is frozen!", true )
		elseif v:Team() == TEAM_HUMAN then
			ULib.tsayError( calling_ply, v:Nick() .. " is a human!", true )
		else
			local bossindexUsed = bossindex
			if not bossindexUsed and v.GetBossZombieIndex then
				bossindexUsed = v:GetBossZombieIndex()
			end

			if bossindexUsed == -1 then
				ULib.tsayError( calling_ply, "No boss classes are available.", true )
			else
				if bossindexUsed then
					GAMEMODE:SpawnBossZombie(v, false, bossindexUsed)
				else
					GAMEMODE:SpawnBossZombie(v)
				end

				local classtable = bossindexUsed and GAMEMODE and GAMEMODE.ZombieClasses and GAMEMODE.ZombieClasses[bossindexUsed] or nil
				if classtable and classtable.Name then
					bossNameSet[classtable.Name] = true
				end

				table.insert( affected_plys, v )
			end
		end
	end

	local bossNames = {}
	for name in pairs(bossNameSet) do
		table.insert(bossNames, name)
	end
	table.sort(bossNames)

	-- Only log if called by a real player (not automatic system)
	if IsValid(calling_ply) then
		if #bossNames > 0 then
			ulx.fancyLogAdmin( calling_ply, "#A forced #T to be boss #s.", affected_plys, table.concat(bossNames, ", ") )
		else
			ulx.fancyLogAdmin( calling_ply, "#A forced #T to be boss.", affected_plys )
		end
	end
end
local forceboss = ulx.command( CATEGORY_NAME, "ulx forceboss", ulx.forceboss, "!forceboss" )
forceboss:addParam{ type=ULib.cmds.PlayersArg }
forceboss:addParam{ type=ULib.cmds.StringArg, hint="boss", ULib.cmds.optional, ULib.cmds.takeRestOfLine, completes=ulx.zsBossZombieCompletes, default=FORCEBOSS_BOSSCHOICE_RANDOM }
forceboss:defaultAccess(ULib.ACCESS_ALL)
forceboss:help( "Sets target(s) as boss." )

-- Auto forceboss (Waves 1-6 -> Intermission 00:10)
-- Picks a single bot/player by exact nickname from D3bot's name list.
if SERVER then
	local FORCEBOSS_WAVE_MIN = 1
	local FORCEBOSS_WAVE_MAX = 6
	local FORCEBOSS_INTERMISSION_SECONDS = 1 -- Matches ZS countdown (util.ToMinutesSecondsCD uses ceil)
	local FORCEBOSS_RANDOM_BOSSCLASS = true
	-- Uses D3bot's name list (loaded from `addons/d3bot/lua/d3bot/names/*.lua`, e.g. `fng_usernames.lua`).
	-- Set this to a string (exact nickname) if you want to force a specific target instead.
	local FORCEBOSS_TARGET_NAME = (D3bot and D3bot.Names) or nil
	local FORCEBOSS_TIMER_ID = "ulx_forceboss_intermission10"

	local function IsZSMap()
		local map = string.lower(game.GetMap() or "")
		return string.StartWith(map, "zs")
	end

	local function ShouldForceBossThisWave(wave)
		if not isnumber(wave) then return false end
		return wave >= FORCEBOSS_WAVE_MIN and wave <= FORCEBOSS_WAVE_MAX
	end

	local function GetForceBossNameList()
		if isstring(FORCEBOSS_TARGET_NAME) and FORCEBOSS_TARGET_NAME ~= "" then return {FORCEBOSS_TARGET_NAME} end
		if D3bot and istable(D3bot.Names) then return D3bot.Names end
		if istable(FORCEBOSS_TARGET_NAME) then return FORCEBOSS_TARGET_NAME end
		return nil
	end

	local function FindForceBossTarget()
		local nameList = GetForceBossNameList()
		if not istable(nameList) or #nameList == 0 then return nil end

		local nameSet = {}
		for _, name in ipairs(nameList) do
			if isstring(name) and name ~= "" then
				nameSet[name] = true
			end
		end

		local botCandidates = {}
		for _, pl in ipairs(player.GetAll()) do
			-- Only allow bots here: if a real player uses a D3bot name, don't let them get auto-forced as boss.
			-- Exclude baby bots (temporary minions) from being selected as boss
			if IsValid(pl) and pl:IsBot() and not pl:IsFrozen() and pl:Team() == TEAM_UNDEAD and not pl:GetZombieClassTable().Boss and not pl.D3bot_BabyBot then
				local nick = pl:Nick()
				local baseNick = nick:match("^(.*)%(%d+%)$")
				if nameSet[nick] or (baseNick and nameSet[baseNick]) then
					table.insert(botCandidates, pl)
				end
			end
		end

		if #botCandidates > 0 then
			return botCandidates[math.random(#botCandidates)]
		end

		return nil
	end

	local function StopForceBossTimer()
		timer.Remove(FORCEBOSS_TIMER_ID)
	end

	local function HasRealZombiePlayer()
		for _, ply in ipairs(team.GetPlayers(TEAM_UNDEAD)) do
			if IsValid(ply) and not ply:IsBot() then
				print("REAL")
				return true 
			end
		end
		
		return false
	end

	local function StartForceBossTimer()
		StopForceBossTimer()

		if HasRealZombiePlayer() == true then return end
		
		timer.Create(FORCEBOSS_TIMER_ID, 0.1, 0, function()
			
			if engine.ActiveGamemode() ~= "zombiesurvival" or not GAMEMODE then
				return StopForceBossTimer()
			end
			if not IsZSMap() then
				return StopForceBossTimer()
			end
			if GAMEMODE.RoundEnded then
				return StopForceBossTimer()
			end
			if GAMEMODE:GetWaveActive() then
				return StopForceBossTimer()
			end
			if not ShouldForceBossThisWave(GAMEMODE:GetWave()) then
				return StopForceBossTimer()
			end

			if GetConVar("zs_bosszombies"):GetInt() <= 0 then
                return StopForceBossTimer()
            end

			local wavestart = GAMEMODE:GetWaveStart()
			if wavestart == -1 then
				return StopForceBossTimer()
			end

			local remaining = wavestart - CurTime()
			if remaining <= 0 then
				return StopForceBossTimer()
			end

			if math.ceil(remaining) ~= FORCEBOSS_INTERMISSION_SECONDS then
				return
			end

			StopForceBossTimer()

			local target = FindForceBossTarget()
			if not IsValid(target) then return end

			local bossindex = FORCEBOSS_RANDOM_BOSSCLASS and GetRandomBossZombieIndex() or nil
			ulx.forceboss(NULL, {target}, bossindex)
		end)
	end

	hook.Add("WaveStateChanged", "ulx_forceboss_waveended", function(active)
		if active then return end
		if engine.ActiveGamemode() ~= "zombiesurvival" or not GAMEMODE then return end
		if not IsZSMap() then return end
		if not ShouldForceBossThisWave(GAMEMODE:GetWave()) then return end

		StartForceBossTimer()
	end)

	hook.Add("PreRestartRound", "ulx_forceboss_reset", StopForceBossTimer)
end

--Force Zombie Class Spawn (sets DeathClass without killing)--

-- Helper function to get zombie class names for autocomplete
ulx.zsZombieClassCompletes = ulx.zsZombieClassCompletes or {}

local function ForceClassRebuildCompletes()
	if not GAMEMODE or not istable(GAMEMODE.ZombieClasses) then return false end

	local names = {}
	for name, classData in pairs(GAMEMODE.ZombieClasses) do
		if type(name) == "string" then
			table.insert(names, name)
		end
	end

	if #names == 0 then return false end
	table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)

	for k in pairs(ulx.zsZombieClassCompletes) do
		ulx.zsZombieClassCompletes[k] = nil
	end
	for _, name in ipairs(names) do
		table.insert(ulx.zsZombieClassCompletes, name)
	end

	return true
end

local FORCECLASS_COMPLETES_TIMER = "ulx_forceclass_build_completes"
local function ForceClassEnsureCompletes()
	if engine.ActiveGamemode and engine.ActiveGamemode() ~= "zombiesurvival" then
		timer.Remove(FORCECLASS_COMPLETES_TIMER)
		return
	end

	if ForceClassRebuildCompletes() then
		timer.Remove(FORCECLASS_COMPLETES_TIMER)
		return
	end

	if not timer.Exists(FORCECLASS_COMPLETES_TIMER) then
		timer.Create(FORCECLASS_COMPLETES_TIMER, 1, 0, ForceClassEnsureCompletes)
	end
end

hook.Add("InitPostEntity", "ulx_forceclass_build_completes", ForceClassEnsureCompletes)
ForceClassEnsureCompletes()

function ulx.forcezombieclassspawn(calling_ply, target_plys, class)
	local affected = {}
	local fclass = GAMEMODE.ZombieClasses[tostring(class)]

	if not fclass then
		ULib.tsayError(calling_ply, "Invalid zombie class: " .. tostring(class), true)
		return
	end

	for i=1, #target_plys do
		local ply = target_plys[i]
		if ply:IsFrozen() then
			ULib.tsayError(calling_ply, ply:Nick() .. " is frozen!", true)
		elseif ply:Team() == TEAM_HUMAN then
			ULib.tsayError(calling_ply, ply:Nick() .. " is a human!", true)
		else
			-- Store original death class to restore after spawn
			local oclass = ply.DeathClass or ply:GetZombieClass()

			-- Kill silently and set the new class
			ply:KillSilent()
			ply:SetZombieClassName(class)
			ply.DeathClass = nil

			-- Set up hulls for the new class
			ply:DoHulls(fclass.Index, TEAM_UNDEAD)

			-- Spawn the player (will use zombie spawn points)
			ply:UnSpectateAndSpawn()

			-- Restore original death class preference
			ply.DeathClass = oclass

			table.insert(affected, ply)
		end
	end

	ulx.fancyLogAdmin(calling_ply, "#A spawned #T as #s", affected, class)
end

local forcezombieclassspawn = ulx.command(CATEGORY_NAME, "ulx forcezombieclassspawn", ulx.forcezombieclassspawn, "!forcezombieclassspawn")
forcezombieclassspawn:addParam{ type=ULib.cmds.PlayersArg }
forcezombieclassspawn:addParam{ type=ULib.cmds.StringArg, hint="Classname", completes=ulx.zsZombieClassCompletes, ULib.cmds.takeRestOfLine }
forcezombieclassspawn:defaultAccess(ULib.ACCESS_SUPERADMIN)
forcezombieclassspawn:help("Sets the selected zombie players' next spawn class.")
