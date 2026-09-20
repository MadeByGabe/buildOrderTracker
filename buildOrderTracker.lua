function widget:GetInfo()
	return {
		name = "BuildOrderTracker",
		desc = "Tracks build events and resource data per second to help analyze build order efficiency. Spectating, replays, and practice games against an inactive AI; /export_bo writes the files.",
		author = "Baldric",
		date = "2026-09-20",
		license = "GNU GPL, v2 or later",
		layer = 100,
		enabled = false,
	}
end


-- Export format version, written into each file's "#" metadata line. 6 records build priority (see priorityMark).
local FORMAT_VERSION = 6

-- Localized Spring API
local spGetSpectatingState = Spring.GetSpectatingState
local spIsReplay = Spring.IsReplay
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetPlayerList = Spring.GetPlayerList
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetMyPlayerID = Spring.GetMyPlayerID
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamList = Spring.GetTeamList
local spGetTeamInfo = Spring.GetTeamInfo
local spGetTeamLuaAI = Spring.GetTeamLuaAI
local spGetAIInfo = Spring.GetAIInfo
local spGetGameSeconds = Spring.GetGameSeconds
local spGetWind = Spring.GetWind
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamRulesParam = Spring.GetTeamRulesParam
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitCurrentBuildPower = Spring.GetUnitCurrentBuildPower
local spGetUnitMetalExtraction = Spring.GetUnitMetalExtraction
local spGetUnitWorkerTask = Spring.GetUnitWorkerTask
local spFindUnitCmdDesc = Spring.FindUnitCmdDesc
local spGetUnitCmdDescs = Spring.GetUnitCmdDescs
local spGetUnitTeam = Spring.GetUnitTeam
local spValidUnitID = Spring.ValidUnitID
local spValidFeatureID = Spring.ValidFeatureID
local spGetFeatureDefID = Spring.GetFeatureDefID
local spEcho = Spring.Echo

-- Localized Lua stdlib
local floor = math.floor
local max = math.max
local format = string.format
local concat = table.concat
local ioOpen = io.open
local pairs = pairs
local ipairs = ipairs

-- Localized CMD constants
local CMD_RECLAIM = CMD.RECLAIM
-- Build priority (the Builder Priority gadget): an ICON_MODE state on every builder that can be set passive, mode 0 = Low Prio, 1 = High Prio (the default)
local CMD_PRIORITY = GameCMD and GameCMD.PRIORITY

local GAME_SPEED = Game.gameSpeed or 30
local MAX_UNITS = Game.maxUnits or 32000

-- The engine's named causes of death: the ones that can mean a builder took the unit apart (it
-- reclaimed it, or a gadget removed it) against the rest, which rule a reclaim out. A death the
-- engine names no cause for leaves the question open.
local RECLAIM_CAUSE, OTHER_CAUSE = {}, {}
for name, id in pairs(Game.envDamageTypes or {}) do
	if name == "Reclaimed" or name == "KilledByLua" then
		RECLAIM_CAUSE[id] = true
	else
		OTHER_CAUSE[id] = true
	end
end

local gameStartTimestamp = os.date("%Y%m%d_%H%M%S")
local playerData = {}
local buildStartTimes = {} -- unitID -> game seconds when construction began
local reclaimTracking = {} -- target unitID -> reclaim start time and reclaimer info
local RECLAIM_STALE_SECONDS = 1.5 -- reclaim considered abandoned if no builder seen working on it for this long
local assistTimes = {} -- unitID under construction -> { [assisting builder's unitID] = { seconds = seen working on it, polls = priority polls, low = those that saw Low Prio } }
local WORKER_POLL_FRAMES = 6 -- how often builders' worker tasks are polled
local WORKER_POLL_SECONDS = WORKER_POLL_FRAMES / GAME_SPEED
-- Whether a builder is set to Low Prio right now, read off the Builder Priority gadget's own command state. nil for a unit that has no such state, which is the same as High.
local function isLowPriority(unitID)
	if not CMD_PRIORITY then
		return nil
	end
	local index = spFindUnitCmdDesc(unitID, CMD_PRIORITY)
	if not index then
		return nil
	end
	local descs = spGetUnitCmdDescs(unitID, index, index)
	local mode = descs and descs[1] and descs[1].params and tonumber(descs[1].params[1])
	return mode ~= nil and mode == 0
end


-- One look at a builder's priority while it works on a build, onto the tally its mark is written from. The player can change priority mid-build, so what a row gets is what held for most of it.
local function pollPriority(tally, unitID)
	local low = isLowPriority(unitID)
	if low == nil then
		return
	end
	tally.polls = (tally.polls or 0) + 1
	if low then
		tally.low = (tally.low or 0) + 1
	end
end


-- What a tally writes after a builder in a built_by cell: "-" when it spent most of the build on Low Prio, nothing otherwise. High is the default and the usual case, so it goes unwritten and a reader takes an unmarked builder as high; "+" means high too, and is accepted but never written.
local function priorityMark(tally)
	local polls = tally and tally.polls or 0
	return (polls > 0 and (tally.low or 0) * 2 > polls) and "-" or ""
end


-- An assistant that helped for all but this much of a build is written without its seconds (a constant nano turret, a con guarding the factory): the larger of the two
local ASSIST_FULL_SLACK = 0.6
local ASSIST_FULL_FRACTION = 0.05
-- [teamID][reclaimerID] = { weight, wreckWeight, name, defName }: the builders seen reclaiming a feature since the last sample, each weighed by the build power it had in use. Cleared by writeReclaimRows, which splits the second's take over them.
local reclaimSeen = {}
local exportDirCreated = false
local gameIDHex -- from the GameID callin; missed if the widget is enabled after the game started, hence the fallbacks in getGameID

-- Per-unitDef lookups, built once
local builderSpeed = {} -- unitDefID -> buildSpeed, for anything that can build
local isMex = {} -- unitDefID -> true for metal extractors (incl. Exploiters, Twilight, naval/T1.5/T2 variants)
for unitDefID, unitDef in pairs(UnitDefs) do
	if (unitDef.buildSpeed or 0) > 0 then
		builderSpeed[unitDefID] = unitDef.buildSpeed
	end
	if (unitDef.extractsMetal or 0) > 0 then
		isMex[unitDefID] = true
	end
end

-- featureDefID -> true for a unit's corpse: the game stamps every featureDef it makes from a unit with the unit it came from. What the map itself put down - trees, rocks - carries no such stamp.
local isWreckDef = {}
for featureDefID, featureDef in pairs(FeatureDefs) do
	if featureDef.customParams and featureDef.customParams.fromunit then
		isWreckDef[featureDefID] = true
	end
end

-- Resource data columns, in export order. Each per-second sample is a row of numbers in this order. The army/defence columns are the metal value of what has been *built* so far: losses aren't subtracted, since the point is the build.
local RESOURCE_COLUMNS = {
	"time", "wind_speed",
	"metal_stored", "energy_stored",
	"metal_income", "energy_income",
	"metal_expense", "energy_expense",
	"metal_pull", "energy_pull", -- demanded; above expense means stalling
	"metal_excess", "energy_excess", -- lost to full storage
	"metal_received", "energy_received", -- from allies
	"metal_sent", "energy_sent", -- to allies
	"build_power", -- build power actually in use
	"total_metal_produced", "total_energy_produced",
	"metal_average", "energy_average",
	"army_value_built", "defence_value_built",
	-- What this team's builders took from features (wrecks, rocks, trees), as running totals. Part of metal_income/energy_income rather than on top of them, and zero throughout without the team stats gadget to count it (see writeReclaimRows).
	"total_metal_reclaimed", "total_energy_reclaimed",
	-- Energy converters: what the team could convert per second, and what it did convert
	"converter_capacity", "converter_use",
}

-- Build data columns, in export order. unit_name/built_by are the translated display names; unit_def is the internal one, which matches in any game language. built_by carries the unit's assistants after a ":" (see assistCell): "Bot Lab (2436):11501,27409=2.1"
local BUILD_COLUMNS = {
	"unit_name", "built_by", "start_time", "build_duration", "unit_def",
}

-- Reclaim data columns, in export order: one row per reclaiming unit per source, and only for a second in which something was reclaimed. See writeReclaimRows.
local RECLAIM_COLUMNS = {
	"time", "reclaimer_id", "reclaimer", "reclaimer_def", "source", "metal", "energy",
}

local function generateFilename(prefix, extension)
	local mapName = Game.mapName or "unknown_map"
	mapName = mapName:gsub("[^%w%s%-_]", ""):gsub("%s+", "_"):lower()
	if #mapName > 20 then
		mapName = mapName:sub(1, 20)
	end
	return "buildordertracker-builds/" .. prefix .. "_" .. mapName .. "_" .. gameStartTimestamp .. "." .. extension
end


local function ensureExportDir()
	if exportDirCreated then
		return
	end
	Spring.CreateDir("buildordertracker-builds")
	exportDirCreated = true
end


local function getGameID()
	return gameIDHex or Game.gameID or Spring.GetGameRulesParam("GameID")
end


-- When the game was played, as a unix timestamp. The engine fills the gameID's first 4 bytes with time() on the host at game start (little-endian), and replays carry the original ID. A lobby can override the gameID with a fixed one, so anything that isn't a plausible date is rejected.
local function gamePlayedTime(gameID)
	if type(gameID) ~= "string" or not gameID:match("^%x%x%x%x%x%x%x%x") then
		return nil
	end
	local t = 0
	for i = 4, 1, -1 do
		t = t * 256 + tonumber(gameID:sub(i * 2 - 1, i * 2), 16)
	end
	if t < 1262304000 or t > 4102444800 then -- 2010-01-01 .. 2100-01-01
		return nil
	end
	return t
end


-- First line of every export: "#" plus tab-separated key=value pairs, so the files carry their own context (the filename timestamp is when the widget loaded, not when the game was played)
local function metadataLine(data, buildName)
	local gameID = getGameID()
	local played = gamePlayedTime(gameID)
	local fields = {
		"# buildOrderTracker",
		"version=" .. FORMAT_VERSION,
		"player=" .. data.name,
		"map=" .. (Game.mapName or "?"),
		"game=" .. (Game.gameName or "?") .. " " .. (Game.gameVersion or ""),
		"gameID=" .. tostring(gameID or "?"),
		"played=" .. (played and os.date("%Y-%m-%d %H:%M:%S", played) or "?"),
		"exported=" .. os.date("%Y-%m-%d %H:%M:%S"),
		-- the map's wind range and tidal strength, so a simulation of this build can run under the same conditions
		"windMin=" .. (Game.windMin and format("%.2f", Game.windMin) or "?"),
		"windMax=" .. (Game.windMax and format("%.2f", Game.windMax) or "?"),
		"tidal=" .. (Game.tidal and format("%.2f", Game.tidal) or "?"),
	}
	if buildName ~= "" then
		fields[#fields + 1] = "name=" .. buildName
	end
	return concat(fields, "\t") .. "\n"
end


-- Build power actually in use: GetUnitCurrentBuildPower is the fraction (0..1) of a builder's build speed it applied this frame, so a commander walking to its next mex, or a factory with nothing it can afford, counts as idle
local function calculateBuildPowerInUse(teamID)
	local total = 0
	for _, unitID in ipairs(spGetTeamUnits(teamID)) do
		local speed = builderSpeed[spGetUnitDefID(unitID)]
		if speed then
			local fraction = spGetUnitCurrentBuildPower(unitID)
			if fraction and fraction > 0 then
				total = total + speed * fraction
			end
		end
	end
	return total
end


-- A worker task's target as a feature, or nil when it is a unit. Older engines offset a feature's ID by Game.maxUnits and newer ones don't (Engine.FeatureSupport.noOffsetForFeatureID), so it is resolved the way the game's own gadgets resolve it: above the unit range only a feature fits, below it a unit wins - which on a newer engine reads a low-numbered feature as the unit of that ID, an ambiguity the game itself lives with.
local function workerTaskFeature(targetID)
	if targetID >= MAX_UNITS then
		local featureID = targetID - MAX_UNITS
		return spValidFeatureID(featureID) and featureID or nil
	end
	if spValidUnitID(targetID) then
		return nil
	end
	return spValidFeatureID(targetID) and targetID or nil
end


-- Widgets (LuaUI) don't receive reclaim or assist callins, so we poll each builder's current worker task.
-- Reclaim: when a tracked builder is reclaiming a completed unit that belongs to a tracked team, we record when the reclaim was first seen (its start) and keep the "last seen" timestamp fresh while it continues. UnitDestroyed then turns a tracked-and-still-active reclaim into a logged event.
-- Feature reclaim: a builder taking a wreck, rock or tree apart is weighed by the build power it has in use, for the per-second split in writeReclaimRows.
-- Assist: a builder working on a unit under construction that some other unit started (a con guarding the factory, a nano turret, the commander helping a con's mex) is credited one poll interval of help on that unit. UnitFinished writes the tally into the unit's built_by cell.
local function trackWorkerTasks(gameTime)
	-- Build priority of whoever started each unit still under construction. Taken
	-- from the nanoframe rather than from the builder's worker task, since a
	-- factory reports no worker task for what it is producing.
	for _, buildInfo in pairs(buildStartTimes) do
		if buildInfo.builderID then
			pollPriority(buildInfo, buildInfo.builderID)
		end
	end
	for teamID in pairs(playerData) do
		for _, unitID in ipairs(spGetTeamUnits(teamID)) do
			local unitDefID = spGetUnitDefID(unitID)
			if builderSpeed[unitDefID] and not spGetUnitIsBeingBuilt(unitID) then
				local taskCmdID, targetID = spGetUnitWorkerTask(unitID)
				local targetBeingBuilt = targetID and spValidUnitID(targetID) and spGetUnitIsBeingBuilt(targetID)
				if taskCmdID and taskCmdID < 0 and targetBeingBuilt then -- build commands are the negative unitDefID; excludes capturing a nanoframe
					local buildInfo = buildStartTimes[targetID]
					if buildInfo and buildInfo.builderID ~= unitID then
						local times = assistTimes[targetID]
						if not times then
							times = {}
							assistTimes[targetID] = times
						end
						local tally = times[unitID]
						if not tally then
							tally = { seconds = 0 }
							times[unitID] = tally
						end
						tally.seconds = tally.seconds + WORKER_POLL_SECONDS
						-- an assistant queues for resources on its own priority, not the priority of the build it helps
						pollPriority(tally, unitID)
					end
				end
				if taskCmdID == CMD_RECLAIM and targetID then
					local featureID = workerTaskFeature(targetID)
					if featureID then
						-- A builder still walking to its target applies no build power and is credited nothing; two on the same feature share it as the engine does.
						local weight = builderSpeed[unitDefID] * (spGetUnitCurrentBuildPower(unitID) or 0)
						if weight > 0 then
							local seen = reclaimSeen[teamID]
							local entry = seen[unitID]
							if not entry then
								entry = {
									weight = 0,
									wreckWeight = 0,
									name = UnitDefs[unitDefID].translatedHumanName,
									defName = UnitDefs[unitDefID].name,
								}
								seen[unitID] = entry
							end
							entry.weight = entry.weight + weight
							if isWreckDef[spGetFeatureDefID(featureID)] then
								entry.wreckWeight = entry.wreckWeight + weight
							end
						end
					elseif spValidUnitID(targetID) and not targetBeingBuilt then
						local targetTeam = spGetUnitTeam(targetID)
						-- Only treat unit reclaim as a "build reclaim" for the team that owns both the reclaimer and the target. Enemy reclaim is a loss for the victim team.
						if targetTeam and targetTeam == teamID and playerData[targetTeam] then
							local tracking = reclaimTracking[targetID]
							if not tracking or (gameTime - tracking.lastSeen) > RECLAIM_STALE_SECONDS then
								reclaimTracking[targetID] = {
									startTime = gameTime,
									reclaimerName = UnitDefs[unitDefID].translatedHumanName,
									reclaimerID = unitID,
									lastSeen = gameTime,
								}
							else
								tracking.lastSeen = gameTime
							end
						end
					end
				end
			end
		end
	end
end


local function isArmyUnit(unitDef)
	return unitDef.weapons and (#unitDef.weapons > 0) and not unitDef.customParams.iscommander and (unitDef.speed or 0) > 0
end

local function isDefenceUnit(unitDef)
	return unitDef.weapons and (#unitDef.weapons > 0) and not unitDef.customParams.iscommander and (unitDef.speed or 0) == 0
end


-- The assistants of a finished unit, as the suffix of its built_by cell: "11501,27409-=2.1" — a builder's unitID, a "-" if it helped on Low Prio, and the seconds it helped unless it helped (nearly) the whole build. nil when nobody assisted.
local function assistCell(times, duration)
	if not times then
		return nil
	end
	local ids = {}
	for builderID in pairs(times) do
		ids[#ids + 1] = builderID
	end
	if #ids == 0 then
		return nil
	end
	table.sort(ids)
	local slack = duration and max(ASSIST_FULL_SLACK, ASSIST_FULL_FRACTION * duration)
	local cells = {}
	for i, builderID in ipairs(ids) do
		local tally = times[builderID]
		local seconds = tally.seconds
		local mark = priorityMark(tally)
		if slack and seconds >= duration - slack then
			cells[i] = builderID .. mark
		else
			cells[i] = builderID .. mark .. "=" .. format("%.1f", seconds)
		end
	end
	return concat(cells, ",")
end


-- Events are logged when they end (unit finished, reclaim completed); a build order reads in the order things were started. Ties keep their logged order.
local function eventsByStartTime(buildEvents)
	local sorted = {}
	for i, event in ipairs(buildEvents) do
		sorted[i] = { event = event, index = i }
	end
	table.sort(sorted, function(a, b)
		if a.event.startTime ~= b.event.startTime then
			return a.event.startTime < b.event.startTime
		end
		return a.index < b.index
	end)
	return sorted
end


-- The three kinds of data are three different shapes - one row per unit event, one per game second, one per second per reclaiming unit - so they are written as three blocks of one file rather than joined into a table none of them fits. A block opens with a blank line, a "## <name>" marker and its own header row, which is all a reader needs to split the file back into three tables; the metadata line at the top then covers all three at once.
local function beginSection(file, name, columns)
	file:write("\n## " .. name .. "\n" .. concat(columns, "\t") .. "\n")
end


-- Events are written in the order they were started (see eventsByStartTime), which is how a build order reads.
local function writeBuildSection(file, events)
	beginSection(file, "build", BUILD_COLUMNS)
	for _, entry in ipairs(eventsByStartTime(events)) do
		local event = entry.event
		local prefix = event.reclaimed and "-" or ""
		local unitNameWithID = prefix .. event.unitName .. " (" .. (event.unitID or "?") .. ")"
		local builder = event.builderName or ""
		local duration = event.duration and format("%.2f", event.duration) or ""
		file:write(unitNameWithID .. "\t" .. builder .. "\t" .. format("%.2f", event.startTime) .. "\t" .. duration .. "\t" .. (event.unitDefName or "") .. "\n")
	end
end


local function writeResourceSection(file, rows)
	beginSection(file, "resource", RESOURCE_COLUMNS)
	local cells = {}
	for _, row in ipairs(rows) do
		cells[1] = format("%d", row[1])
		for i = 2, #RESOURCE_COLUMNS do
			cells[i] = format("%.2f", row[i] or 0)
		end
		file:write(concat(cells, "\t") .. "\n")
	end
end


-- See writeReclaimRows. reclaimer_id joins to the builder's unitID in the build block, so a reclaimer can be followed back to when and by what it was built.
local function writeReclaimSection(file, rows)
	beginSection(file, "reclaim", RECLAIM_COLUMNS)
	for _, row in ipairs(rows) do
		file:write(format("%d\t%d\t%s\t%s\t%s\t%.2f\t%.2f\n",
			row[1], row[2], row[3], row[4], row[5], row[6], row[7]))
	end
end


-- One file per tracked player. All three blocks are written even when a block has no rows - a game where nothing was reclaimed still gets an empty reclaim block - so every file has the same shape and a reader never has to tell a missing block from an empty one.
local function exportData(buildName)
	ensureExportDir()
	local filesCreated = 0

	for _, data in pairs(playerData) do
		if #data.buildEvents > 0 or #data.resourceRows > 0 then
			local filename = generateFilename("buildorder_" .. data.name, "tsv")
			local file = ioOpen(filename, "w")
			if file then
				file:write(metadataLine(data, buildName))
				writeBuildSection(file, data.buildEvents)
				writeResourceSection(file, data.resourceRows)
				writeReclaimSection(file, data.reclaimRows)
				file:close()
				filesCreated = filesCreated + 1
				spEcho("BuildOrderTracker: Exported " .. data.name .. " - " .. #data.buildEvents .. " build events, "
					.. #data.resourceRows .. " data points, " .. #data.reclaimRows .. " reclaim rows")
			end
		end
	end

	spEcho("BuildOrderTracker: Created " .. filesCreated .. " file(s)")
	return filesCreated > 0
end


-- "/export_bo commander tempo build": the text after the command is saved as the build order's name in the metadata line. Control characters (tabs, newlines) would break the TSV, so they become spaces.
local function exportBuildOrderCmd(_, optLine)
	local buildName = (optLine or ""):gsub("%c", " "):match("^%s*(.-)%s*$")
	exportData(buildName)
	return true
end


function widget:GameID(gameID)
	gameIDHex = gameID
end


-- Skirmish AIs that never issue an order, by their shortName: practising a build order against one of these is the same as practising on an empty map. NullAI ships with the engine and describes itself as "This AI does absolutely nothing".
local INACTIVE_AI_SHORTNAMES = {
	NullAI = true,
}


-- Tracking a team means reading its resources, which a *playing* client may only do for its own team, so in a real match the widget would be both blind and suspect. A practice game is an exception.
---@return boolean practice
---@return string? reason what disqualified the game, when it isn't a practice game
local function isPracticeGame()
	local myPlayerID = spGetMyPlayerID()
	for _, playerID in ipairs(spGetPlayerList()) do
		if playerID ~= myPlayerID then
			local pName, _, pSpectator = spGetPlayerInfo(playerID, false)
			if not pSpectator then
				return false, (pName or "player " .. playerID) .. " is playing too"
			end
		end
	end

	local myTeamID = spGetMyTeamID()
	local gaiaTeamID = spGetGaiaTeamID()
	for _, teamID in ipairs(spGetTeamList()) do
		if teamID ~= myTeamID and teamID ~= gaiaTeamID then
			local luaAI = spGetTeamLuaAI(teamID)
			if luaAI and luaAI ~= "" then
				return false, "team " .. teamID .. " is run by " .. luaAI
			end
			local _, _, _, hasAI = spGetTeamInfo(teamID, false)
			if not hasAI then
				return false, "team " .. teamID .. " is not an AI"
			end
			-- Unsynced, so this is the real shortName; an AI hosted by someone else can read back as "UNKNOWN", which counts as active
			local _, _, _, shortName = spGetAIInfo(teamID)
			if not INACTIVE_AI_SHORTNAMES[shortName] then
				return false, "team " .. teamID .. " is run by " .. tostring(shortName) .. ", which plays"
			end
		end
	end

	return true
end


local function trackTeam(teamID, name)
	playerData[teamID] = {
		name = (name or "team" .. teamID):gsub("[^%w_%-]", "_"),
		buildEvents = {},
		resourceRows = {},
		reclaimRows = {},
		totalMetalProduced = 0,
		totalEnergyProduced = 0,
		-- Seeded from the team's own running totals: enabled mid-game, only what is reclaimed from here on is ours to split.
		totalMetalReclaimed = spGetTeamRulesParam(teamID, "teamStatsReclaimedMetal") or 0,
		totalEnergyReclaimed = spGetTeamRulesParam(teamID, "teamStatsReclaimedEnergy") or 0,
		armyValueBuilt = 0,
		defenceValueBuilt = 0,
	}
	reclaimSeen[teamID] = {}
end


function widget:Initialize()
	if spIsReplay() or spGetSpectatingState() then
		-- Observing: every player's data is readable, so track all of them
		local gaiaTeamID = spGetGaiaTeamID()
		for _, playerID in ipairs(spGetPlayerList()) do
			local pName, _, pSpectator, pTeamID = spGetPlayerInfo(playerID, false)
			if not pSpectator and pTeamID ~= gaiaTeamID then
				trackTeam(pTeamID, pName or "player" .. playerID)
			end
		end
	else
		local practice, reason = isPracticeGame()
		if not practice then
			spEcho("BuildOrderTracker: removed. While playing it only runs in a practice game against an inactive AI (" .. (reason or "?") .. "). Spectate or watch a replay to track every player.")
			widgetHandler:RemoveWidget()
			return
		end
		local myPlayerID = spGetMyPlayerID()
		local myTeamID = spGetMyTeamID()
		trackTeam(myTeamID, (spGetPlayerInfo(myPlayerID, false)) or "player" .. myPlayerID)
		spEcho("BuildOrderTracker: practice game, tracking your own team (" .. playerData[myTeamID].name .. ")")
	end

	widgetHandler:AddAction("export_bo", exportBuildOrderCmd, nil, "t")
end


function widget:Shutdown()
	widgetHandler:RemoveAction("export_bo")
end


local function addReclaimRow(rows, gs, reclaimerID, entry, source, metal, energy)
	if metal <= 0 and energy <= 0 then
		return
	end
	rows[#rows + 1] = { gs, reclaimerID, entry and entry.name or "", entry and entry.defName or "", source, metal, energy }
end


-- Splits what a team's builders took from features in the second just sampled over the builders seen taking part, and brings its running totals up to date.
-- The totals come from the game's team stats gadget, whose synced half counts every reclaim step into a team rules param; they say *how much*. The polling in trackWorkerTasks says *who*, since a widget sees neither the steps nor whose builder took them: the second's take is split by the build power each builder had in use, and per builder between wrecks and what the map put down in the same proportion.
-- What no builder was seen for - a tree taken whole between two polls, or a game with no such gadget - goes under no reclaimer rather than onto whoever was nearby. So a second's rows add up to its rise in the totals without anything being invented, and a large unattributed share is itself the sign that the rest is worth less.
local function writeReclaimRows(data, teamID, gs)
	-- A total reading lower than the one we hold means the param went unreadable (a team gone, a
	-- view lost), not that resources came back: hold what we had, or the next readable sample
	-- would book the whole game as one second.
	local metalTotal = max(spGetTeamRulesParam(teamID, "teamStatsReclaimedMetal") or 0, data.totalMetalReclaimed)
	local energyTotal = max(spGetTeamRulesParam(teamID, "teamStatsReclaimedEnergy") or 0, data.totalEnergyReclaimed)
	local metal = metalTotal - data.totalMetalReclaimed
	local energy = energyTotal - data.totalEnergyReclaimed
	data.totalMetalReclaimed = metalTotal
	data.totalEnergyReclaimed = energyTotal

	local seen = reclaimSeen[teamID]
	if metal > 0 or energy > 0 then
		local rows = data.reclaimRows
		local totalWeight = 0
		for _, entry in pairs(seen) do
			totalWeight = totalWeight + entry.weight
		end
		if totalWeight > 0 then
			for reclaimerID, entry in pairs(seen) do
				local share = entry.weight / totalWeight
				local wreckShare = entry.wreckWeight / entry.weight
				addReclaimRow(rows, gs, reclaimerID, entry, "wreck", metal * share * wreckShare, energy * share * wreckShare)
				local mapShare = share * (1 - wreckShare)
				addReclaimRow(rows, gs, reclaimerID, entry, "map", metal * mapShare, energy * mapShare)
			end
		else
			addReclaimRow(rows, gs, 0, nil, "unknown", metal, energy)
		end
	end
	reclaimSeen[teamID] = {}
end


-- One row per team per game second. Sampled from GameFrame rather than Update:
-- Update runs once per *drawn* frame, and a fast replay (or catching up after joining a live game) can run more than a second of sim between two draws, which silently dropped rows and their income from the running totals.
-- Sampled one frame *into* each second: GameFrame runs before the engine rolls the team's income/expense over on the second's first frame, so sampling on that frame read the previous second's flows next to the current storage.
local function sampleSecond(gs)
	local _, _, _, windStrength = spGetWind()

	for teamID, data in pairs(playerData) do
		writeReclaimRows(data, teamID, gs)
		local mCurrent, _, mPull, mIncome, mExpense, _, mSent, mReceived, mExcess = spGetTeamResources(teamID, "metal")
		local eCurrent, _, ePull, eIncome, eExpense, _, eSent, eReceived, eExcess = spGetTeamResources(teamID, "energy")
		mIncome = mIncome or 0
		eIncome = eIncome or 0

		data.totalMetalProduced = data.totalMetalProduced + mIncome
		data.totalEnergyProduced = data.totalEnergyProduced + eIncome

		-- same order as RESOURCE_COLUMNS
		local rows = data.resourceRows
		rows[#rows + 1] = {
			gs, windStrength or 0,
			mCurrent or 0, eCurrent or 0,
			mIncome, eIncome,
			mExpense or 0, eExpense or 0,
			mPull or 0, ePull or 0,
			mExcess or 0, eExcess or 0,
			mReceived or 0, eReceived or 0,
			mSent or 0, eSent or 0,
			calculateBuildPowerInUse(teamID),
			data.totalMetalProduced, data.totalEnergyProduced,
			gs > 0 and data.totalMetalProduced / gs or 0, gs > 0 and data.totalEnergyProduced / gs or 0,
			data.armyValueBuilt, data.defenceValueBuilt,
			data.totalMetalReclaimed, data.totalEnergyReclaimed,
			spGetTeamRulesParam(teamID, "mmCapacity") or 0, spGetTeamRulesParam(teamID, "mmUse") or 0,
		}
	end
end


function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
	if playerData[unitTeam] then
		local builderName = nil
		if builderID then
			local builderDefID = spGetUnitDefID(builderID)
			if builderDefID and UnitDefs[builderDefID] then
				builderName = UnitDefs[builderDefID].translatedHumanName
			end
		end
		local buildInfo = {
			startTime = spGetGameSeconds(),
			builderName = builderName,
			builderID = builderID,
		}
		-- a build that finishes inside one poll interval is never polled, so look once here
		if builderID then
			pollPriority(buildInfo, builderID)
		end
		buildStartTimes[unitID] = buildInfo
	end
end


function widget:GameFrame(frame)
	if frame % WORKER_POLL_FRAMES == 0 then
		trackWorkerTasks(spGetGameSeconds())
	end
	if frame % GAME_SPEED == 1 then
		sampleSecond(floor(frame / GAME_SPEED))
	end
end


function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
	buildStartTimes[unitID] = nil
	assistTimes[unitID] = nil

	local tracking = reclaimTracking[unitID]
	reclaimTracking[unitID] = nil

	-- Log a reclaim only if a tracked builder was seen reclaiming this unit right up until it disappeared (within the stale window), which is also what names the reclaimer - and only if the engine's own cause of death agrees: something an enemy shells first, or whose owner self-destructs it, was not reclaimed. A death the engine names no cause for falls back to the stale window alone.
	local gameTime = spGetGameSeconds()
	if not tracking or not playerData[unitTeam] then
		return
	end
	if (gameTime - tracking.lastSeen) > RECLAIM_STALE_SECONDS then
		return
	end
	if weaponDefID and (OTHER_CAUSE[weaponDefID] or (WeaponDefs[weaponDefID] and not RECLAIM_CAUSE[weaponDefID])) then
		return
	end

	local unitDef = unitDefID and UnitDefs[unitDefID]
	local unitName = unitDef and unitDef.translatedHumanName or "unknown"

	local reclaimerStr = nil
	if tracking.reclaimerName then
		reclaimerStr = tracking.reclaimerName .. " (" .. tracking.reclaimerID .. ")"
	elseif attackerID and attackerDefID and UnitDefs[attackerDefID] then
		reclaimerStr = UnitDefs[attackerDefID].translatedHumanName .. " (" .. attackerID .. ")"
	end

	local events = playerData[unitTeam].buildEvents
	events[#events + 1] = {
		unitName = unitName,
		unitDefName = unitDef and unitDef.name,
		unitID = unitID,
		builderName = reclaimerStr,
		startTime = tracking.startTime,
		duration = gameTime - tracking.startTime,
		reclaimed = true,
	}
end


function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then
		buildStartTimes[unitID] = nil
		return
	end

	-- Track the metal value of army and defence built (never reduced by losses)
	if playerData[unitTeam] then
		if isArmyUnit(unitDef) then
			playerData[unitTeam].armyValueBuilt = playerData[unitTeam].armyValueBuilt + unitDef.metalCost
		elseif isDefenceUnit(unitDef) then
			playerData[unitTeam].defenceValueBuilt = playerData[unitTeam].defenceValueBuilt + unitDef.metalCost
		end
	end

	-- Track build event
	local gameTime = spGetGameSeconds()
	local unitName = unitDef.translatedHumanName
	if isMex[unitDefID] then
		local metalExtract = spGetUnitMetalExtraction(unitID) or 0
		unitName = unitName .. ":" .. format("%.2f", metalExtract)
	end
	local buildInfo = buildStartTimes[unitID]
	local startTime = buildInfo and buildInfo.startTime or nil
	local builderName = buildInfo and buildInfo.builderName or nil
	local builderID = buildInfo and buildInfo.builderID or nil
	buildStartTimes[unitID] = nil

	local builderStr = nil
	if builderName and builderID then
		builderStr = builderName .. " (" .. builderID .. ")" .. priorityMark(buildInfo)
	elseif builderName then
		builderStr = builderName
	end
	local duration = startTime and (gameTime - startTime) or nil
	local assists = assistCell(assistTimes[unitID], duration)
	assistTimes[unitID] = nil
	if builderStr and assists then
		builderStr = builderStr .. ":" .. assists
	end

	if playerData[unitTeam] then
		local events = playerData[unitTeam].buildEvents
		events[#events + 1] = {
			unitName = unitName,
			unitDefName = unitDef.name,
			unitID = unitID,
			builderName = builderStr,
			-- If the start wasn't seen, fall back to the finish time with an unknown duration
			startTime = startTime or gameTime,
			duration = duration,
		}
	end
end
