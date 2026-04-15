function widget:GetInfo()
	return {
		name = "BuildOrderTracker",
		desc = "Tracks build events and resource data per second to help analyze build order efficiency",
		author = "Baldric",
		date = "2026-03-26",
		license = "GNU GPL, v2 or later",
		layer = 100,
		enabled = false,
	}
end


-- Localized Spring API
local spGetMyTeamID = Spring.GetMyTeamID
local spGetMyPlayerID = Spring.GetMyPlayerID
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetPlayerList = Spring.GetPlayerList
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetViewGeometry = Spring.GetViewGeometry
local spGetGameSeconds = Spring.GetGameSeconds
local spGetWind = Spring.GetWind
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitCommands = Spring.GetUnitCommands
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitMetalExtraction = Spring.GetUnitMetalExtraction
local spEcho = Spring.Echo

-- Localized Lua stdlib
local floor = math.floor
local format = string.format
local concat = table.concat
local ioOpen = io.open
local pairs = pairs
local ipairs = ipairs

-- Localized GL
local glColor = gl.Color
local glText = gl.Text

-- Localized CMD constants
local CMD_REPAIR = CMD.REPAIR
local CMD_RECLAIM = CMD.RECLAIM
local CMD_RESURRECT = CMD.RESURRECT

local myTeamID = spGetMyTeamID()
local gameStartTimestamp = os.date("%Y%m%d_%H%M%S")
local isSpectating = false
local playerData = {}
local buildStartTimes = {} -- unitID -> game seconds when construction began
local lastGameUpdate = -1
local exportDirCreated = false
local drawElement -- cached in Initialize from WG.FlowUI.Draw.Element

local buttonX1 = 0
local buttonY1 = 0
local buttonX2 = 0
local buttonY2 = 0

local mexNames = {
	armmex = true,
	cormex = true,
	legmex = true,
	armmoho = true,
	cormoho = true,
	legmoho = true,
	armuwmme = true,
	coruwmme = true,
	leguwmme = true,
}

local function isPointInBox(x, y, x1, y1, x2, y2)
	return x >= x1 and x <= x2 and y >= y1 and y <= y2
end


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


local function calculateTotalBuildPower(teamID)
	local totalBuildPower = 0
	local teamUnits = spGetTeamUnits(teamID)

	for _, unitID in ipairs(teamUnits) do
		if not spGetUnitIsBeingBuilt(unitID) then
			local unitDefID = spGetUnitDefID(unitID)
			if unitDefID then
				local unitDef = UnitDefs[unitDefID]
				if unitDef and unitDef.buildSpeed and unitDef.buildSpeed > 0 then
					local commands = spGetUnitCommands(unitID, 1)
					if commands and #commands > 0 then
						local cmd = commands[1]
						if cmd.id < 0 or cmd.id == CMD_REPAIR or cmd.id == CMD_RECLAIM or cmd.id == CMD_RESURRECT then
							totalBuildPower = totalBuildPower + unitDef.buildSpeed
						end
					end
				end
			end
		end
	end

	return totalBuildPower
end


local function isArmedUnit(unitDef)
	return unitDef.weapons and (#unitDef.weapons > 0) and not unitDef.customParams.iscommander
end


local function exportData()
	ensureExportDir()
	local filesCreated = 0

	for teamID, data in pairs(playerData) do
		-- Export build events
		if #data.buildEvents > 0 then
			local filename = generateFilename("builddata_" .. data.name, "tsv")
			local file = ioOpen(filename, "w")
			if file then
				file:write("unit_name\tbuilt_by\ttime\tbuild_duration\n")
				for _, event in ipairs(data.buildEvents) do
					local unitNameWithID = event.unitName .. " (" .. (event.unitID or "?") .. ")"
					local builder = event.builderName or ""
					local duration = event.buildDuration and format("%.2f", event.buildDuration) or ""
					file:write(unitNameWithID .. "\t" .. builder .. "\t" .. format("%.2f", event.buildTime) .. "\t" .. duration .. "\n")
				end
				file:close()
				filesCreated = filesCreated + 1
				spEcho("BuildOrderTracker: Exported " .. #data.buildEvents .. " build events for " .. data.name)
			end
		end

		-- Export resource data
		if #data.resourceData.seconds > 0 then
			local filename = generateFilename("resourcedata_" .. data.name, "tsv")
			local file = ioOpen(filename, "w")
			if file then
				file:write("time\twind_speed\tmetal_stored\tenergy_stored\tmetal_income\tenergy_income\tmetal_expense\tenergy_expense\tbuild_power\ttotal_metal_produced\ttotal_energy_produced\tmetal_average\tenergy_average\ttotal_military_value\ttime_weighted_military_avg\n")
				local rd = data.resourceData
				for i = 1, #rd.seconds do
					local row = {
						rd.seconds[i] or 0, format("%.2f", rd.windSpeed[i] or 0), format("%.2f", rd.metalStored[i] or 0), format("%.2f", rd.energyStored[i] or 0), format("%.2f", rd.metalIncome[i] or 0), format("%.2f", rd.energyIncome[i] or 0), format("%.2f", rd.metalExpense[i] or 0), format("%.2f", rd.energyExpense[i] or 0), format("%.2f", rd.buildPower[i] or 0), format("%.2f", rd.totalMetalProduced[i] or 0), format("%.2f", rd.totalEnergyProduced[i] or 0),
							format("%.2f", rd.metalAverage[i] or 0), format("%.2f", rd.energyAverage[i] or 0), format("%.2f", rd.totalMilitaryValue[i] or 0), format("%.3f", rd.militaryValueIntegrated[i] or 0)}
					file:write(concat(row, "\t") .. "\n")
				end
				file:close()
				filesCreated = filesCreated + 1
				spEcho("BuildOrderTracker: Exported " .. #rd.seconds .. " data points for " .. data.name)
			end
		end
	end

	spEcho("BuildOrderTracker: Created " .. filesCreated .. " file(s)")
	return filesCreated > 0
end


function widget:Initialize()
	local myPlayerID = spGetMyPlayerID()
	if myPlayerID then
		local name, active, spectator = spGetPlayerInfo(myPlayerID)
		isSpectating = spectator
	end

	local gaiaTeamID = spGetGaiaTeamID()
	local allPlayers = spGetPlayerList()
	for _, playerID in ipairs(allPlayers) do
		local pName, pActive, pSpectator, pTeamID = spGetPlayerInfo(playerID)
		if not pSpectator and pTeamID ~= gaiaTeamID then
			if not isSpectating and pTeamID ~= myTeamID then
				-- Skip other teams in single player
			else
				playerData[pTeamID] = {
					name = (pName or "player" .. playerID):gsub("[^%w_%-]", "_"),
					buildEvents = {},
					resourceData = {
						seconds = {},
						windSpeed = {},
						metalStored = {},
						energyStored = {},
						metalIncome = {},
						energyIncome = {},
						metalExpense = {},
						energyExpense = {},
						buildPower = {},
						totalMetalProduced = {},
						totalEnergyProduced = {},
						metalAverage = {},
						energyAverage = {},
						totalMilitaryValue = {},
						militaryValueIntegrated = {},
					},
					totalMilitaryValue = 0,
					militaryValueIntegrated = 0,
				}
			end
		end
	end

	local vsx, vsy = spGetViewGeometry()
	buttonX1 = vsx - 140
	buttonX2 = vsx - 20
	buttonY1 = 260
	buttonY2 = 300

	if WG.FlowUI and WG.FlowUI.Draw then
		drawElement = WG.FlowUI.Draw.Element
	end
end


function widget:ViewResize()
	local vsx, vsy = spGetViewGeometry()
	buttonX1 = vsx - 140
	buttonX2 = vsx - 20
	buttonY1 = 260
	buttonY2 = 300
end


function widget:Update()
	local gs = floor(spGetGameSeconds())
	if gs == lastGameUpdate then
		return
	end
	lastGameUpdate = gs

	local _, _, _, windStrength = spGetWind()

	for teamID, data in pairs(playerData) do
		local rd = data.resourceData
		local n = #rd.seconds + 1

		rd.seconds[n] = gs
		rd.windSpeed[n] = windStrength

		local metalCurrent, metalStorage, metalPull, metalIncome, metalExpense = spGetTeamResources(teamID, "metal")
		local energyCurrent, energyStorage, energyPull, energyIncome, energyExpense = spGetTeamResources(teamID, "energy")

		rd.metalStored[n] = metalCurrent or 0
		rd.energyStored[n] = energyCurrent or 0
		rd.metalIncome[n] = metalIncome or 0
		rd.energyIncome[n] = energyIncome or 0
		rd.metalExpense[n] = metalExpense or 0
		rd.energyExpense[n] = energyExpense or 0

		local totalMetal = 0
		local totalEnergy = 0
		if n > 1 then
			totalMetal = rd.totalMetalProduced[n - 1]
			totalEnergy = rd.totalEnergyProduced[n - 1]
		end
		totalMetal = totalMetal + (metalIncome or 0)
		totalEnergy = totalEnergy + (energyIncome or 0)
		rd.totalMetalProduced[n] = totalMetal
		rd.totalEnergyProduced[n] = totalEnergy

		local metalAvg = gs > 0 and totalMetal / gs or 0
		local energyAvg = gs > 0 and totalEnergy / gs or 0
		rd.metalAverage[n] = metalAvg
		rd.energyAverage[n] = energyAvg

		rd.buildPower[n] = calculateTotalBuildPower(teamID)

		-- Calculate time-average of the cumulative military value curve (shows military production rate weighted by time)
		rd.totalMilitaryValue[n] = data.totalMilitaryValue
		data.militaryValueIntegrated = data.militaryValueIntegrated + data.totalMilitaryValue
		rd.militaryValueIntegrated[n] = gs > 0 and data.militaryValueIntegrated / gs or 0
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


function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	buildStartTimes[unitID] = nil
end


function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local unitDef = UnitDefs[unitDefID]
	if not unitDef then
		buildStartTimes[unitID] = nil
		return
	end

	-- Track military value for resource data
	if playerData[unitTeam] then
		if isArmedUnit(unitDef) then
			playerData[unitTeam].totalMilitaryValue = playerData[unitTeam].totalMilitaryValue + unitDef.metalCost
		end
	end

	-- Track build event
	local gameTime = spGetGameSeconds()
	local unitName = unitDef.translatedHumanName
	if mexNames[unitDef.name] then
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
			unitID = unitID,
			builderName = builderStr,
			buildTime = gameTime,
			buildDuration = buildDuration,
		}
	end
end


function widget:DrawScreen()
	if drawElement then
		drawElement(buttonX1, buttonY1, buttonX2, buttonY2, 0.8, 0.8, 0.8, 0.8, 1, 1, 1, 1)
	end

	local centerX = (buttonX1 + buttonX2) / 2
	local centerY = (buttonY1 + buttonY2) / 2
	glColor(1, 1, 1, 1)
	glText("Export", centerX - 20, centerY - 6, 12, "o")
end


function widget:MousePress(x, y, button)
	if button == 1 and isPointInBox(x, y, buttonX1, buttonY1, buttonX2, buttonY2) then
		exportData()
		return true
	end
	return false
end


