function widget:GetInfo()
	return {
		name = "BuildOrderTracker",
		desc = "Tracks build events and resource data per second to help analyze build order efficiency. Spectators and replays only; /export_bo writes the files.",
		author = "Baldric",
		date = "2026-09-19",
		license = "GNU GPL, v2 or later",
		layer = 100,
		enabled = false,
	}
end


-- Export format version, written into each file's "#" metadata line
local FORMAT_VERSION = 2

-- Localized Spring API
local spGetSpectatingState = Spring.GetSpectatingState
local spIsReplay = Spring.IsReplay
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetPlayerList = Spring.GetPlayerList
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetGameSeconds = Spring.GetGameSeconds
local spGetWind = Spring.GetWind
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitCurrentBuildPower = Spring.GetUnitCurrentBuildPower
local spGetUnitMetalExtraction = Spring.GetUnitMetalExtraction
local spGetUnitWorkerTask = Spring.GetUnitWorkerTask
local spGetUnitTeam = Spring.GetUnitTeam
local spValidUnitID = Spring.ValidUnitID
local spEcho = Spring.Echo

-- Localized Lua stdlib
local floor = math.floor
local format = string.format
local concat = table.concat
local ioOpen = io.open
local pairs = pairs
local ipairs = ipairs

-- Localized CMD constants
local CMD_RECLAIM = CMD.RECLAIM

local GAME_SPEED = Game.gameSpeed or 30

local gameStartTimestamp = os.date("%Y%m%d_%H%M%S")
local playerData = {}
local buildStartTimes = {} -- unitID -> game seconds when construction began
local reclaimTracking = {} -- target unitID -> reclaim start time and reclaimer info
local RECLAIM_STALE_SECONDS = 1.5 -- reclaim considered abandoned if no builder seen working on it for this long
local exportDirCreated = false

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


-- First line of every export: "#" plus tab-separated key=value pairs, so the files carry their own context (the filename timestamp is when the export was made, not when the game was played)
local function metadataLine(data)
	local gameID = Game.gameID or Spring.GetGameRulesParam("GameID") or "?"
	local fields = {
		"# buildOrderTracker",
		"version=" .. FORMAT_VERSION,
		"player=" .. data.name,
		"map=" .. (Game.mapName or "?"),
		"game=" .. (Game.gameName or "?") .. " " .. (Game.gameVersion or ""),
		"gameID=" .. tostring(gameID),
		"exported=" .. os.date("%Y-%m-%d %H:%M:%S"),
	}
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


-- Widgets (LuaUI) don't receive reclaim callins like UnitReverseBuilt (synced only), so we poll each builder's current worker task. When a tracked builder is reclaiming a completed unit that belongs to a tracked team, we record when the reclaim was first seen (its start) and keep the "last seen" timestamp fresh while it continues. UnitDestroyed then turns a tracked-and-still-active reclaim into a logged event.
local function trackActiveReclaims(gameTime)
	for teamID in pairs(playerData) do
		for _, unitID in ipairs(spGetTeamUnits(teamID)) do
			local unitDefID = spGetUnitDefID(unitID)
			if builderSpeed[unitDefID] and not spGetUnitIsBeingBuilt(unitID) then
				local taskCmdID, targetID = spGetUnitWorkerTask(unitID)
				if taskCmdID == CMD_RECLAIM and targetID and spValidUnitID(targetID)
					and not spGetUnitIsBeingBuilt(targetID) then
					local targetTeam = spGetUnitTeam(targetID)
					if targetTeam and playerData[targetTeam] then
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


local function isArmyUnit(unitDef)
	return unitDef.weapons and (#unitDef.weapons > 0) and not unitDef.customParams.iscommander and (unitDef.speed or 0) > 0
end

local function isDefenceUnit(unitDef)
	return unitDef.weapons and (#unitDef.weapons > 0) and not unitDef.customParams.iscommander and (unitDef.speed or 0) == 0
end


local function exportData()
	ensureExportDir()
	local filesCreated = 0

	for teamID, data in pairs(playerData) do
		-- Export build events. unit_name/built_by are the (translated) display names; unit_def is the internal name, which matches in any game language
		if #data.buildEvents > 0 then
			local filename = generateFilename("builddata_" .. data.name, "tsv")
			local file = ioOpen(filename, "w")
			if file then
				file:write(metadataLine(data))
				file:write("unit_name\tbuilt_by\ttime\tbuild_duration\tunit_def\n")
				for _, event in ipairs(data.buildEvents) do
					local prefix = event.reclaimed and "-" or ""
					local unitNameWithID = prefix .. event.unitName .. " (" .. (event.unitID or "?") .. ")"
					local builder = event.builderName or ""
					local duration = event.buildDuration and format("%.2f", event.buildDuration) or ""
					file:write(unitNameWithID .. "\t" .. builder .. "\t" .. format("%.2f", event.buildTime) .. "\t" .. duration .. "\t" .. (event.unitDefName or "") .. "\n")
				end
				file:close()
				filesCreated = filesCreated + 1
				spEcho("BuildOrderTracker: Exported " .. #data.buildEvents .. " build events for " .. data.name)
			end
		end

		-- Export resource data
		local rows = data.resourceRows
		if #rows > 0 then
			local filename = generateFilename("resourcedata_" .. data.name, "tsv")
			local file = ioOpen(filename, "w")
			if file then
				file:write(metadataLine(data))
				file:write(concat(RESOURCE_COLUMNS, "\t") .. "\n")
				local cells = {}
				for _, row in ipairs(rows) do
					cells[1] = format("%d", row[1])
					for i = 2, #RESOURCE_COLUMNS do
						cells[i] = format("%.2f", row[i] or 0)
					end
					file:write(concat(cells, "\t") .. "\n")
				end
				file:close()
				filesCreated = filesCreated + 1
				spEcho("BuildOrderTracker: Exported " .. #rows .. " data points for " .. data.name)
			end
		end
	end

	spEcho("BuildOrderTracker: Created " .. filesCreated .. " file(s)")
	return filesCreated > 0
end


local function exportBuildOrderCmd()
	exportData()
	return true
end


function widget:Initialize()
	-- Only useful when observing: spectating a live game or watching a replay
	if not (spIsReplay() or spGetSpectatingState()) then
		widgetHandler:RemoveWidget()
		return
	end

	local gaiaTeamID = spGetGaiaTeamID()
	local allPlayers = spGetPlayerList()
	for _, playerID in ipairs(allPlayers) do
		local pName, pActive, pSpectator, pTeamID = spGetPlayerInfo(playerID)
		if not pSpectator and pTeamID ~= gaiaTeamID then
			playerData[pTeamID] = {
				name = (pName or "player" .. playerID):gsub("[^%w_%-]", "_"),
				buildEvents = {},
				resourceRows = {},
				totalMetalProduced = 0,
				totalEnergyProduced = 0,
				armyValueBuilt = 0,
				defenceValueBuilt = 0,
			}
		end
	end

	widgetHandler:AddAction("export_bo", exportBuildOrderCmd, nil, "t")
end


function widget:Shutdown()
	widgetHandler:RemoveAction("export_bo")
end


-- One row per team per game second. Sampled from GameFrame rather than Update:
-- Update runs once per *drawn* frame, and a fast replay (or catching up after joining a live game) can run more than a second of sim between two draws, which silently dropped rows and their income from the running totals.
-- Sampled one frame *into* each second: GameFrame runs before the engine rolls the team's income/expense over on the second's first frame, so sampling on that frame read the previous second's flows next to the current storage.
local function sampleSecond(gs)
	local _, _, _, windStrength = spGetWind()

	for teamID, data in pairs(playerData) do
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
		buildStartTimes[unitID] = {
			startTime = spGetGameSeconds(),
			builderName = builderName,
			builderID = builderID,
		}
	end
end


function widget:GameFrame(frame)
	if frame % 6 == 0 then
		trackActiveReclaims(spGetGameSeconds())
	end
	if frame % GAME_SPEED == 1 then
		sampleSecond(floor(frame / GAME_SPEED))
	end
end


function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
	buildStartTimes[unitID] = nil

	local tracking = reclaimTracking[unitID]
	reclaimTracking[unitID] = nil

	-- Log a reclaim only if a tracked builder was actively reclaiming this unit right up until it disappeared (last seen within the stale window). We rely on the observed reclaim task rather than the death's weaponDefID, which isn't reliably the engine's Reclaimed damage type across game/engine versions.
	local gameTime = spGetGameSeconds()
	if not tracking or not playerData[unitTeam] then
		return
	end
	if (gameTime - tracking.lastSeen) > RECLAIM_STALE_SECONDS then
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
		buildTime = gameTime,
		buildDuration = gameTime - tracking.startTime,
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
	local buildDuration = startTime and (gameTime - startTime) or nil
	buildStartTimes[unitID] = nil

	local builderStr = nil
	if builderName and builderID then
		builderStr = builderName .. " (" .. builderID .. ")"
	elseif builderName then
		builderStr = builderName
	end

	if playerData[unitTeam] then
		local events = playerData[unitTeam].buildEvents
		events[#events + 1] = {
			unitName = unitName,
			unitDefName = unitDef.name,
			unitID = unitID,
			builderName = builderStr,
			buildTime = gameTime,
			buildDuration = buildDuration,
		}
	end
end
