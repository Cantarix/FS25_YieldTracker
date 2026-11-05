-- Author: AntCant
-- Date: 06-11-2025
-- Version: 1.1.0.0.0
-- yieldTracker.lua


PRINT_PREFIX = "[ YieldTracker ] - "

YieldTracker = {
    modDir = g_currentModDirectory,
    yieldData = {},       -- yieldData[year][farmlandId][fillTypeIndex] = { amount = liters }
    unresolvedData = {},  -- saved entries whose fill type is not loaded (e.g. map/mod removed), kept so they survive a save
    availableLiters = {}, -- availableLiters[farmlandId][fillTypeKey][year] = liters field work placed on the ground, not picked up yet
    windrowFillTypes = {},       -- set of crop windrow fill types (straw, grass, ...)
    pickupFillTypeCache = {},    -- fillTypeIndex -> true, or the time until which it counts as not pickable
    saveFileName = "yieldTrackerData.xml",
    saveVersion = 3,
    isActive = false,
}
YieldTracker.debug = false




-- HARVEST HOOKS
-- Yield is recorded where the game itself converts crop on the ground into liters, so every harvester,
-- baler and loader wagon is covered, including modded vehicles and custom fill types on any map.
--=======================================================================================================================================================================

-- Hooks stay installed for the whole game session, so they always forward to the tracker of the running mission.
local function getActiveTracker()
    if g_currentMission ~= nil and g_currentMission.yieldTracker ~= nil and g_currentMission.yieldTracker.isActive then
        return g_currentMission.yieldTracker
    end
    return nil
end


-- Remembers which header is currently delivering crop, so addCutterArea can attribute it to the header's position.
function YieldTracker.cutterOnEndWorkAreaProcessing(cutter, superFunc, dt, hasProcessed)
    YieldTracker.activeCutter = cutter
    local result = superFunc(cutter, dt, hasProcessed)
    YieldTracker.activeCutter = nil
    return result
end


-- Harvesters without a tank (forage harvesters) buffer the crop only for fillLevelBufferTime after their last discharge.
-- After that Combine:addCutterArea throws the crop away but still returns it as applied, e.g. when no trailer follows.
-- Same check as in Combine:addCutterArea, evaluated before it runs. AI workers wait for a trailer, so they never discard.
local function getIsCropDiscarded(combine)
    local spec = combine.spec_combine
    if spec == nil or spec.lastDischargeTime == nil or spec.fillLevelBufferTime == nil then
        return false
    end

    if combine:getFillUnitCapacity(spec.fillUnitIndex) ~= math.huge or combine:getFillUnitFillLevel(spec.fillUnitIndex) <= 0.001 then
        return false
    end

    local bufferTime = combine:getIsAIActive() and math.huge or spec.fillLevelBufferTime
    return spec.lastDischargeTime + bufferTime < g_currentMission.time
end


-- Every harvester (grain, root crop, forage, cotton, sugarcane, grape/olive) hands its crop to the combine through addCutterArea.
-- The return value is the amount actually accepted after rain/damage/additive modifiers and capacity limits.
function YieldTracker.combineAddCutterArea(combine, superFunc, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)
    local tracker = getActiveTracker()
    local isCropDiscarded = tracker ~= nil and getIsCropDiscarded(combine)

    local appliedDelta = superFunc(combine, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)

    if isCropDiscarded then
        if type(appliedDelta) == "number" and appliedDelta > 0 then
            tracker:debugMessage(string.format("Vehicle %d discarded %.2fL (nowhere to unload); not recorded", combine.id or -1, appliedDelta))
        end
    elseif tracker ~= nil and combine.isServer and type(appliedDelta) == "number" and appliedDelta > 0 then
        local cutter = YieldTracker.activeCutter
        local workArea = nil
        local pickupFillType, pickupLiters = nil, nil
        if cutter ~= nil and cutter.getWorkAreaByIndex ~= nil then
            workArea = cutter:getWorkAreaByIndex(1)

            -- Pickup headers collect windrows from the ground, which only count while field material is available
            local spec = cutter.spec_cutter
            if spec ~= nil and spec.useWindrow then
                pickupFillType = spec.currentInputFillType
                pickupLiters = spec.workAreaParameters.lastLiters
            end
        end
        tracker:recordHarvest(combine, workArea, outputFillType, appliedDelta, pickupFillType, pickupLiters)
    end

    return appliedDelta
end


-- Balers accumulate the windrow liters picked up this frame before adding them to the fill unit here.
function YieldTracker.balerOnEndWorkAreaProcessing(baler, superFunc, dt, hasProcessed)
    local tracker = getActiveTracker()
    local spec = baler.spec_baler

    if tracker ~= nil and baler.isServer and spec ~= nil then
        local pickedUpLiters = spec.workAreaParameters.lastPickedUpLiters or 0
        if pickedUpLiters > 0 then
            -- Same selection the baler uses for the fill type it adds to its fill unit
            local fillType = FillType.UNKNOWN
            local maxFillLevel = 0
            for fillTypeIndex, fillLevel in pairs(spec.pickupFillTypes) do
                if fillLevel > maxFillLevel then
                    fillType = fillTypeIndex
                    maxFillLevel = fillLevel
                end
            end

            tracker:recordHarvest(baler, baler:getWorkAreaByIndex(1), fillType, pickedUpLiters * (spec.fillScale or 1), fillType, pickedUpLiters)
        end
    end

    return superFunc(baler, dt, hasProcessed)
end


-- Loader wagons accumulate the windrow liters picked up this frame before filling the wagon here.
function YieldTracker.forageWagonOnEndWorkAreaProcessing(wagon, superFunc, dt, hasProcessed)
    local tracker = getActiveTracker()
    local spec = wagon.spec_forageWagon

    if tracker ~= nil and wagon.isServer and spec ~= nil then
        local pickupLiters = spec.workAreaParameters.lastPickupLiters or 0
        if pickupLiters > 0 then
            local fillType = spec.workAreaParameters.forcedFillType
            tracker:recordHarvest(wagon, wagon:getWorkAreaByIndex(1), fillType, pickupLiters, fillType, pickupLiters)
        end
    end

    return superFunc(wagon, dt, hasProcessed)
end


-- Marks tipping done by trailers, loader wagons, shovels etc. unloading onto the ground, as opposed to
-- mowers, combines and windrowers placing windrows from field work.
local function endDischargeToGround(...)
    YieldTracker.isDischargingToGround = false
    return ...
end

function YieldTracker.dischargeableDischargeToGround(vehicle, superFunc, dischargeNode, emptyLiters)
    YieldTracker.isDischargingToGround = true
    return endDischargeToGround(superFunc(vehicle, dischargeNode, emptyLiters))
end


-- Everything placed on or taken off the ground goes through here. Tracks how much material field work has made available:
-- combines and mowers add to it, tedders and rakes take material off and put it back, so they cancel out.
-- Unloading and vehicle-less placing (e.g. a bale cut open) are ignored, so picking that material up can't add yield.
-- Pickups by balers, loader wagons and pickup headers are deducted in recordHarvest; shovels are ignored.
local function onTippedToGround(vehicle, delta, fillTypeIndex, sx, sz, ex, ez, ...)
    local tippedLiters = ...
    local tracker = getActiveTracker()

    if tracker ~= nil and vehicle ~= nil and type(tippedLiters) == "number" and g_currentMission:getIsServer() then
        local isFieldWorkDrop = delta > 0 and tippedLiters > 0 and not YieldTracker.isDischargingToGround
        local isWindrowMove = delta < 0 and tippedLiters < 0
            and (vehicle.spec_tedder ~= nil or vehicle.spec_windrower ~= nil or vehicle.spec_mower ~= nil)

        if (isFieldWorkDrop or isWindrowMove) and tracker:getIsPickupFillType(tracker:getAvailableFillTypeKey(fillTypeIndex)) then
            tracker:changeAvailableLiters((sx + ex) / 2, (sz + ez) / 2, fillTypeIndex, tippedLiters)
        end
    end

    return ...
end

function YieldTracker.tipToGroundAroundLine(vehicle, superFunc, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, ...)
    return onTippedToGround(vehicle, delta, fillTypeIndex, sx, sz, ex, ez,
        superFunc(vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, ...))
end


-- Saves yield data on every game save.
function YieldTracker.onSaveCareerMission()
    local tracker = getActiveTracker()
    if tracker ~= nil then
        tracker:saveYieldData()
    end
end


-- Installs the hooks once per game session. The flag lives on a base game class so re-sourcing the mod never stacks hooks.
-- Must run when this file is sourced: TypeManager:finalizeTypes() copies functions such as addCutterArea into each
-- vehicle type before loadMap, so overwriting them later has no effect. (Event listeners are looked up at call time.)
function YieldTracker.installHooks()
    if Combine == nil or Combine.yieldTrackerHooksInstalled then
        return
    end

    Combine.addCutterArea = Utils.overwrittenFunction(Combine.addCutterArea, YieldTracker.combineAddCutterArea)
    Cutter.onEndWorkAreaProcessing = Utils.overwrittenFunction(Cutter.onEndWorkAreaProcessing, YieldTracker.cutterOnEndWorkAreaProcessing)
    Baler.onEndWorkAreaProcessing = Utils.overwrittenFunction(Baler.onEndWorkAreaProcessing, YieldTracker.balerOnEndWorkAreaProcessing)
    ForageWagon.onEndWorkAreaProcessing = Utils.overwrittenFunction(ForageWagon.onEndWorkAreaProcessing, YieldTracker.forageWagonOnEndWorkAreaProcessing)
    Dischargeable.dischargeToGround = Utils.overwrittenFunction(Dischargeable.dischargeToGround, YieldTracker.dischargeableDischargeToGround)
    DensityMapHeightUtil.tipToGroundAroundLine = Utils.overwrittenFunction(DensityMapHeightUtil.tipToGroundAroundLine, YieldTracker.tipToGroundAroundLine)
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, YieldTracker.onSaveCareerMission)

    Combine.yieldTrackerHooksInstalled = true
    print(PRINT_PREFIX .. "Harvest hooks installed")
end

YieldTracker.installHooks()

--=======================================================================================================================================================================





-- UTIL METHODS
--=======================================================================================================================================================================

-- Returns the farmland at a position, or nil when the spot is not on a real farmland.
-- The farmland map can hold ids without a farmland behind them (e.g. 255 for non-farmland areas on some maps).
function YieldTracker:getFarmlandIdAtPosition(x, z)
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    if farmlandId == nil or farmlandId == 0 or g_farmlandManager:getFarmlandById(farmlandId) == nil then
        return nil
    end
    return farmlandId
end


-- Uses the center of the work area (header, pickup) to find the farmland, falling back to the vehicle position.
function YieldTracker:getFarmlandIdAtWorkArea(vehicle, workArea)
    local x, _, z
    if workArea ~= nil and workArea.start ~= nil and workArea.width ~= nil and workArea.height ~= nil then
        local sx, _, sz = getWorldTranslation(workArea.start)
        local wx, _, wz = getWorldTranslation(workArea.width)
        local hx, _, hz = getWorldTranslation(workArea.height)
        x = (sx + wx + hx) / 3
        z = (sz + wz + hz) / 3
    else
        x, _, z = getWorldTranslation(vehicle.rootNode)
    end

    return self:getFarmlandIdAtPosition(x, z)
end


---Adds a harvested amount to the yieldData table. Also referenced during game save.
---Pickups (balers, loader wagons, pickup headers) pass what they collected from the ground. It only counts as yield
---while field work on this farmland has material available, so a dumped heap can't be counted a second time.
function YieldTracker:recordHarvest(vehicle, workArea, fillTypeIndex, amount, pickupFillTypeIndex, pickupLiters)
    if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN or amount <= 0 then return end
    if g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) == nil then return end

    local farmlandId = self:getFarmlandIdAtWorkArea(vehicle, workArea)
    if farmlandId == nil then return end

    if pickupFillTypeIndex ~= nil and pickupLiters ~= nil and pickupLiters > 0 then
        local collectedLiters = self:consumeAvailableLiters(farmlandId, pickupFillTypeIndex, pickupLiters)
        if collectedLiters < pickupLiters then
            self:debugMessage(string.format("Picked up %.2fL with no field material left on farmland %d; not counted", pickupLiters - collectedLiters, farmlandId))
        end
        amount = amount * collectedLiters / pickupLiters
        if amount <= 0 then return end
    end

    local year = g_currentMission.environment.currentYear
    self:addAmount(year, farmlandId, fillTypeIndex, amount)

    self:debugMessage(string.format(
        "Recorded %.2fL of %s on farmland %d (year %d) by vehicle %d",
        amount, g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex), farmlandId, year, vehicle.id or -1
    ))
end


function YieldTracker:addAmount(year, farmlandId, fillTypeIndex, amount)
    self.yieldData[year] = self.yieldData[year] or {}
    self.yieldData[year][farmlandId] = self.yieldData[year][farmlandId] or {}

    local entry = self.yieldData[year][farmlandId][fillTypeIndex]
    if entry == nil then
        entry = { amount = 0 }
        self.yieldData[year][farmlandId][fillTypeIndex] = entry
    end

    entry.amount = entry.amount + amount
end


-- Grass and hay share one available amount, since drying can turn one into the other without going through
-- tipToGroundAroundLine (e.g. FS25_MoistureSystem uses changeFillTypeAtArea).
function YieldTracker:getAvailableFillTypeKey(fillTypeIndex)
    if fillTypeIndex == FillType.DRYGRASS_WINDROW then
        return FillType.GRASS_WINDROW
    end
    return fillTypeIndex
end


-- Changes the material field work has made available at a position, in the current year's amount.
-- Rakes and tedders can briefly take this below 0 when they lift dumped material; it cancels out when they drop it again.
function YieldTracker:changeAvailableLiters(x, z, fillTypeIndex, liters)
    local farmlandId = self:getFarmlandIdAtPosition(x, z)
    if farmlandId == nil then return end -- pickups off farmland are never recorded

    local key = self:getAvailableFillTypeKey(fillTypeIndex)
    local year = g_currentMission.environment.currentYear

    self.availableLiters[farmlandId] = self.availableLiters[farmlandId] or {}
    self.availableLiters[farmlandId][key] = self.availableLiters[farmlandId][key] or {}
    self.availableLiters[farmlandId][key][year] = (self.availableLiters[farmlandId][key][year] or 0) + liters

    self:debugMessage(string.format("Available %s on farmland %d changed by %.2fL",
        tostring(g_fillTypeManager:getFillTypeNameByIndex(key)), farmlandId, liters))
end


-- Only fill types that can be picked up again matter for double counting: crop windrows plus whatever the balers
-- and loader wagons on the map accept. Other heaps (stone, lime, grain, ...) are ignored.
-- Positive results are cached for good; negative ones are re-checked every 10s in case such a vehicle is bought.
function YieldTracker:getIsPickupFillType(fillTypeIndex)
    local cached = self.pickupFillTypeCache[fillTypeIndex]
    if cached == true then return true end
    if cached ~= nil and g_currentMission.time < cached then return false end

    local isPickup = self.windrowFillTypes[fillTypeIndex] == true
    if not isPickup then
        for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
            local spec = vehicle.spec_baler or vehicle.spec_forageWagon
            if spec ~= nil and spec.fillUnitIndex ~= nil then
                local supportedFillTypes = vehicle:getFillUnitSupportedFillTypes(spec.fillUnitIndex)
                if supportedFillTypes ~= nil and supportedFillTypes[fillTypeIndex] then
                    isPickup = true
                    break
                end
            end
        end
    end

    self.pickupFillTypeCache[fillTypeIndex] = isPickup or (g_currentMission.time + 10000)
    return isPickup
end


-- Deducts a pickup from the material available on that farmland and returns the part that counts as yield.
-- Uses last year's amount first. Anything older is dropped, so missed or plowed-under straw can't build up over the years.
function YieldTracker:consumeAvailableLiters(farmlandId, fillTypeIndex, liters)
    local key = self:getAvailableFillTypeKey(fillTypeIndex)
    local amounts = self.availableLiters[farmlandId] ~= nil and self.availableLiters[farmlandId][key] or nil
    if amounts == nil then
        return 0
    end

    local currentYear = g_currentMission.environment.currentYear
    for year in pairs(amounts) do
        if year < currentYear - 1 then
            amounts[year] = nil
        end
    end

    local collected = 0
    for year = currentYear - 1, currentYear do
        local available = amounts[year] or 0
        if available > 0 and collected < liters then
            local consumed = math.min(available, liters - collected)
            amounts[year] = available - consumed
            collected = collected + consumed
        end
    end

    return collected
end


-- Returns every fill type that has recorded yield, optionally only on one farmland, sorted by title.
-- Used to build the crop list in the GUI.
function YieldTracker:getRecordedFillTypes(farmlandId)
    local seen = {}
    local fillTypes = {}

    local function addFillTypes(crops)
        for fillTypeIndex in pairs(crops) do
            if not seen[fillTypeIndex] then
                seen[fillTypeIndex] = true
                local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                if fillTypeDesc ~= nil then
                    table.insert(fillTypes, fillTypeDesc)
                end
            end
        end
    end

    for _, fields in pairs(self.yieldData) do
        if farmlandId ~= nil then
            addFillTypes(fields[farmlandId] or {})
        else
            for _, crops in pairs(fields) do
                addFillTypes(crops)
            end
        end
    end

    table.sort(fillTypes, function(a, b) return a.title < b.title end)
    return fillTypes
end


-- Version 1 saves stored runtime fill type indices, which shift when maps/mods add fill types.
-- Trust the index only if its title still matches, otherwise look the title up.
function YieldTracker:resolveLegacyFillType(fillTypeIndex, title)
    local fillTypeDesc = fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    if fillTypeDesc ~= nil and (title == nil or fillTypeDesc.title == title) then
        return fillTypeDesc.index
    end

    if title ~= nil then
        for _, desc in ipairs(g_fillTypeManager:getFillTypes()) do
            if desc.title == title then
                return desc.index
            end
        end
    end

    return fillTypeDesc ~= nil and fillTypeDesc.index or nil
end


-- Prints a debug message if debugging is enabled.
function YieldTracker:debugMessage(message)
    if self.debug then
        print(PRINT_PREFIX .. message)
    end
end

--=======================================================================================================================================================================




-- SAVE/LOAD METHODS
--=======================================================================================================================================================================

-- Call required dependencies upon loadmap from main.lua
function YieldTracker:setup()
    self:loadYieldData()

    -- Fill type indices can differ between savegames (other maps/mods), so this is rebuilt per mission
    self.windrowFillTypes = {}
    self.pickupFillTypeCache = {}
    for _, fruitType in ipairs(g_fruitTypeManager:getFruitTypes()) do
        local windrowFillType = g_fruitTypeManager:getWindrowFillTypeIndexByFruitTypeIndex(fruitType.index)
        if windrowFillType ~= nil then
            self.windrowFillTypes[windrowFillType] = true
        end
    end

    g_currentMission.yieldTracker = self
    self.isActive = true

    if self.debug then
        addConsoleCommand("ytClearData", "Clears all YieldTracker data for the current savegame (debug only)", "consoleCommandClearData", self)
    end
end


-- Debug console command: resets all recorded data so tests can start from scratch without reloading.
-- The savegame file is only overwritten on the next game save.
function YieldTracker:consoleCommandClearData()
    self.yieldData = {}
    self.unresolvedData = {}
    self.availableLiters = {}
    return "YieldTracker data cleared. Save the game to also clear the savegame file."
end


-- Called upon deleteMap from main.lua so nothing carries over into another savegame.
function YieldTracker:shutdown()
    if self.isActive and self.debug then
        removeConsoleCommand("ytClearData")
    end

    self.isActive = false
    self.yieldData = {}
    self.unresolvedData = {}
    self.availableLiters = {}
    YieldTracker.activeCutter = nil
    YieldTracker.isDischargingToGround = false
end


-- Loads yield tracking data from an XML file in the current savegame directory.
-- Rebuilds the yieldData structure by year, farmland and fill type. Fill types are stored by name so they survive map/mod changes.
function YieldTracker:loadYieldData()
    self.yieldData = {}
    self.unresolvedData = {}
    self.availableLiters = {}

    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        self:debugMessage("Load skipped: no savegame directory")
        return
    end

    local filePath = g_currentMission.missionInfo.savegameDirectory .. "/" .. self.saveFileName
    if not fileExists(filePath) then
        self:debugMessage("No existing yield data XML found")
        return
    end

    local xmlFile = loadXMLFile("YieldDataXML", filePath)
    if not xmlFile then
        self:debugMessage("Failed to load yield data XML")
        return
    end

    local i = 0
    while true do
        local yearKey = string.format("yieldData.year(%d)", i)
        if not hasXMLProperty(xmlFile, yearKey) then break end

        local year = getXMLInt(xmlFile, yearKey .. "#value")

        local j = 0
        while true do
            local fieldKey = string.format("%s.field(%d)", yearKey, j)
            if not hasXMLProperty(xmlFile, fieldKey) then break end

            local farmlandId = getXMLInt(xmlFile, fieldKey .. "#id")

            local k = 0
            while true do
                local cropKey = string.format("%s.crop(%d)", fieldKey, k)
                if not hasXMLProperty(xmlFile, cropKey) then break end

                local amount = getXMLFloat(xmlFile, cropKey .. "#amount") or 0
                local fillTypeName = getXMLString(xmlFile, cropKey .. "#fillType")
                local fillTypeIndex

                if fillTypeName ~= nil then
                    fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
                else
                    fillTypeIndex = self:resolveLegacyFillType(getXMLInt(xmlFile, cropKey .. "#fillTypeIndex"), getXMLString(xmlFile, cropKey .. "#name"))
                end

                if year ~= nil and farmlandId ~= nil and fillTypeIndex ~= nil then
                    self:addAmount(year, farmlandId, fillTypeIndex, amount)
                elseif year ~= nil and farmlandId ~= nil and fillTypeName ~= nil then
                    table.insert(self.unresolvedData, { year = year, farmlandId = farmlandId, fillTypeName = fillTypeName, amount = amount })
                    self:debugMessage(string.format("Fill type '%s' is not loaded; keeping its data untouched", fillTypeName))
                end

                k = k + 1
            end

            j = j + 1
        end

        i = i + 1
    end

    -- Field material on the ground that has not been picked up yet
    local a = 0
    while true do
        local availableKey = string.format("yieldData.availableWindrows.entry(%d)", a)
        if not hasXMLProperty(xmlFile, availableKey) then break end

        local farmlandId = getXMLInt(xmlFile, availableKey .. "#farmland")
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(getXMLString(xmlFile, availableKey .. "#fillType"))
        local year = getXMLInt(xmlFile, availableKey .. "#year")
        local liters = getXMLFloat(xmlFile, availableKey .. "#liters")

        if farmlandId ~= nil and g_farmlandManager:getFarmlandById(farmlandId) ~= nil and fillTypeIndex ~= nil and year ~= nil and liters ~= nil and liters > 0 then
            self.availableLiters[farmlandId] = self.availableLiters[farmlandId] or {}
            self.availableLiters[farmlandId][fillTypeIndex] = self.availableLiters[farmlandId][fillTypeIndex] or {}
            self.availableLiters[farmlandId][fillTypeIndex][year] = liters
        end

        a = a + 1
    end

    delete(xmlFile)

    self:debugMessage("Yield data loaded from XML")
end



-- Saves yield tracking data to an XML file in the current savegame directory, grouped by year, farmland and fill type name.
function YieldTracker:saveYieldData()
    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        self:debugMessage("Save skipped: no savegame directory")
        return
    end

    -- Group recorded and unresolved entries together per year/farmland
    local entries = {}
    local function addEntry(year, farmlandId, fillTypeName, amount)
        entries[year] = entries[year] or {}
        entries[year][farmlandId] = entries[year][farmlandId] or {}
        table.insert(entries[year][farmlandId], { fillTypeName = fillTypeName, amount = amount })
    end

    for year, fields in pairs(self.yieldData) do
        for farmlandId, crops in pairs(fields) do
            for fillTypeIndex, cropData in pairs(crops) do
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
                if fillTypeName ~= nil then
                    addEntry(year, farmlandId, fillTypeName, cropData.amount)
                end
            end
        end
    end

    for _, entry in ipairs(self.unresolvedData) do
        addEntry(entry.year, entry.farmlandId, entry.fillTypeName, entry.amount)
    end

    local filePath = g_currentMission.missionInfo.savegameDirectory .. "/" .. self.saveFileName
    local xmlFile = createXMLFile("YieldDataXML", filePath, "yieldData")
    setXMLInt(xmlFile, "yieldData#version", self.saveVersion)

    local i = 0
    for year, fields in pairs(entries) do
        local yearKey = string.format("yieldData.year(%d)", i)
        setXMLInt(xmlFile, yearKey .. "#value", year)

        local j = 0
        for farmlandId, crops in pairs(fields) do
            local fieldKey = string.format("%s.field(%d)", yearKey, j)
            setXMLInt(xmlFile, fieldKey .. "#id", farmlandId)

            for k, cropData in ipairs(crops) do
                local cropKey = string.format("%s.crop(%d)", fieldKey, k - 1)
                setXMLString(xmlFile, cropKey .. "#fillType", cropData.fillTypeName)
                setXMLFloat(xmlFile, cropKey .. "#amount", cropData.amount)
            end
            j = j + 1
        end
        i = i + 1
    end

    -- Save field material on the ground that has not been picked up yet, skipping amounts too old to be used
    local currentYear = g_currentMission.environment.currentYear
    local a = 0
    for farmlandId, fillTypes in pairs(self.availableLiters) do
        for fillTypeIndex, amounts in pairs(fillTypes) do
            local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
            for year, liters in pairs(amounts) do
                if fillTypeName ~= nil and year >= currentYear - 1 and liters > 0.001 then
                    local availableKey = string.format("yieldData.availableWindrows.entry(%d)", a)
                    setXMLInt(xmlFile, availableKey .. "#farmland", farmlandId)
                    setXMLString(xmlFile, availableKey .. "#fillType", fillTypeName)
                    setXMLInt(xmlFile, availableKey .. "#year", year)
                    setXMLFloat(xmlFile, availableKey .. "#liters", liters)
                    a = a + 1
                end
            end
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)

    self:debugMessage("Yield data saved to XML")
end

--=======================================================================================================================================================================
