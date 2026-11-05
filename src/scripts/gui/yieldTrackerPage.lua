-- Author: AntCant
-- Date: 06-11-2025
-- Version: 1.0.0.0
-- yieldTrackerPage.lua

PRINT_PREFIX = "[ YieldTracker ] - "


YieldTrackerPage = {}
YieldTrackerPage._mt = Class(YieldTrackerPage, TabbedMenuFrameElement)
YieldTrackerPage.debug = false
YieldTrackerPage.dir = g_currentModDirectory
YieldTrackerPage.MAX_NAME_LENGTH = 18 -- Longer names don't fit the overview title

function YieldTrackerPage.new(i18n, messageCenter)
    local self = YieldTrackerPage:superClass().new(nil, YieldTrackerPage._mt)
    self.name = "YieldTrackerPage"
    self.hasCustomMenuButtons = true
    self.i18n = i18n
    self.messageCenter = messageCenter
    self.dataBindings = {}
    self.fieldEntries = {}    -- rows of the field list: { farmlandId = id } or { group = combined field }
    self.selectedEntry = nil
    self.yieldYears = {}
    self.cropInfo = {}      -- fill type descs with recorded yield (any map, any mod crop)
    self.selectedCrop = nil -- fill type index
    self.showingOwnedFields = true


    return self
end


local function formatWithCommas(n)
    n = math.floor(n + 0.5)  -- Round to nearest whole number
    local formatted = tostring(n)
    local k
    while true do
        formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end


function YieldTrackerPage:setupCustomButtons()
    
    self.backButtonInfo = {
		inputAction = InputAction.MENU_BACK
	}

    self.showAllFieldButton = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = self.i18n:getText("yt_showAllFieldsBtnTxt"),
        callback = function ()
            self.showingOwnedFields = not self.showingOwnedFields

            if self.showingOwnedFields then
                self.showAllFieldButton.text = self.i18n:getText("yt_showAllFieldsBtnTxt")
            else
                self.showAllFieldButton.text = self.i18n:getText("yt_showOwnedFieldsBtnTxt")
            end

            self:refreshFieldList()
        end
    }

    self.combineFieldsButton = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = self.i18n:getText("yt_combineFieldsBtnTxt"),
        callback = function ()
            self:onClickCombineFields()
        end
    }

    local info = {
		self.backButtonInfo,
        self.showAllFieldButton,
        self.combineFieldsButton,
	}

    self.menuButtons = info

    self:setMenuButtonInfo(self.menuButtons)
end


function YieldTrackerPage:setButtons()
	local info = {
		self.backButtonInfo,
        self.showAllFieldButton,
        self.combineFieldsButton,
	}

    self.menuButtons = info

	self:setMenuButtonInfoDirty()
end


function YieldTrackerPage:onGuiSetupFinished()
    YieldTrackerPage:superClass().onGuiSetupFinished(self)

    -- custom menu buttons
    self:setupCustomButtons()

    -- farm id list handling
    self.farmlandList = self:getDescendantById("farmlandList")
    self.farmlandList:setDataSource(self)
    self.farmlandList:setDelegate(self)

    -- crop list/fill type handling
    self.cropList = self:getDescendantById("cropList")
    self.cropList:setDataSource(self)
    self.cropList:setDelegate(self)

    if self.cropList then
        self:getCropInfo()
        self.cropList:reloadData()
    end

    -- users yield history list
    self.yieldPerYearList = self:getDescendantById("yieldPerYearList")
    self.yieldPerYearList:setDataSource(self)
    self.yieldPerYearList:setDelegate(self)

    -- debuggers
    self:debugMessage("YieldPerYearList found: " .. tostring(self.yieldPerYearList ~= nil))
    self:debugMessage("CropList found: " .. tostring(self.cropList ~= nil))
    self:debugMessage("FarmlandList found: " .. tostring(self.farmlandList ~= nil))

    -- Set initial search param based on self.selectedEntry and self.selectedCrop
    self:setSelectedPageData()
end



function YieldTrackerPage:onFrameOpen()
    YieldTrackerPage:superClass().onFrameOpen(self)

    -- Also picks up crops harvested since the menu was last opened
    self:refreshFieldList()

    if self.farmlandList then
        FocusManager:setFocus(self.farmlandList)
    else
        self:debugMessage("Error: farmlandList not found in onFrameOpen")
    end

    if self.yieldPerYearList then
        self.yieldPerYearList:reloadData()
    end
end


-- Opens the queued dialog a couple of frames later, once the dialog that queued it has closed.
function YieldTrackerPage:update(dt)
    YieldTrackerPage:superClass().update(self, dt)

    if self.pendingDialog ~= nil then
        self.pendingDialogDelay = self.pendingDialogDelay - 1
        if self.pendingDialogDelay <= 0 then
            local pendingDialog = self.pendingDialog
            self.pendingDialog = nil
            pendingDialog()
        end
    end
end


function YieldTrackerPage:queueDialog(openDialog)
    self.pendingDialog = openDialog
    self.pendingDialogDelay = 2
end


-- Returns the farmlands that can be shown on the farmland screen, optionally only the owned ones.
function YieldTrackerPage:getFarmlandIDs(onlyOwned)
    local farmlandIDs = {}
    for id, farmland in pairs(g_farmlandManager.farmlands) do
        if farmland.showOnFarmlandsScreen then
            local isOwned = farmland.farmId == g_currentMission:getFarmId()
            if isOwned or not onlyOwned then
                table.insert(farmlandIDs, id)
            end
        end
    end
    table.sort(farmlandIDs)
    return farmlandIDs
end


-- Builds the rows of the field list: the farmlands, then the combined fields. A combined field counts as owned
-- when any of its farmlands is owned. Keeps the selected row when it is still listed, otherwise selects the first.
function YieldTrackerPage:getFieldEntries()
    local fieldEntries = {}
    for _, farmlandId in ipairs(self:getFarmlandIDs(self.showingOwnedFields)) do
        table.insert(fieldEntries, { farmlandId = farmlandId })
    end

    for _, group in ipairs(YieldTracker.fieldGroups) do
        local isListed = not self.showingOwnedFields
        for _, member in ipairs(group.members) do
            local farmland = g_farmlandManager:getFarmlandById(member.farmlandId)
            if farmland ~= nil and farmland.farmId == g_currentMission:getFarmId() then
                isListed = true
            end
        end

        if isListed then
            table.insert(fieldEntries, { group = group })
        end
    end

    self.fieldEntries = fieldEntries

    local selected = self.selectedEntry
    self.selectedEntry = fieldEntries[1]
    for _, entry in ipairs(fieldEntries) do
        if selected ~= nil and entry.farmlandId == selected.farmlandId and entry.group == selected.group then
            self.selectedEntry = entry
        end
    end

    return fieldEntries
end


-- Reloads the field list, keeps the highlighted row on the selected field and updates everything that depends on it.
function YieldTrackerPage:refreshFieldList()
    self:getFieldEntries()

    if self.farmlandList then
        self.farmlandList:reloadData()
        for i, entry in ipairs(self.fieldEntries) do
            if entry == self.selectedEntry then
                self.farmlandList:setSelectedItem(1, i, false, false)
                break
            end
        end
    end

    self:onFieldEntryChanged()
end


function YieldTrackerPage:onFieldEntryChanged()
    self:refreshCropList()
    self:setSelectedPageData()

    local isGroup = self.selectedEntry ~= nil and self.selectedEntry.group ~= nil
    self.combineFieldsButton.text = self.i18n:getText(isGroup and "yt_editCombinedFieldBtnTxt" or "yt_combineFieldsBtnTxt")
    self:setMenuButtonInfoDirty() -- Refresh the button text
end


-- Builds the crop list from the fill types harvested on the selected field.
-- Keeps the crop the player last picked when this field has it, so the same crop can be compared across fields.
function YieldTrackerPage:getCropInfo()
    local entry = self.selectedEntry
    if entry == nil then
        self.cropInfo = {}
    elseif entry.group ~= nil then
        self.cropInfo = YieldTracker:getFieldGroupFillTypes(entry.group)
    else
        self.cropInfo = YieldTracker:getRecordedFillTypes(entry.farmlandId)
    end

    local preferredCrop = self.preferredCrop or self.selectedCrop
    for _, crop in ipairs(self.cropInfo) do
        if crop.index == preferredCrop then
            self.selectedCrop = crop.index
            return self.cropInfo
        end
    end

    self.selectedCrop = self.cropInfo[1] ~= nil and self.cropInfo[1].index or nil
    return self.cropInfo
end


-- Reloads the crop list and keeps the highlighted row on the selected crop.
function YieldTrackerPage:refreshCropList()
    self:getCropInfo()
    if self.cropList == nil then return end

    self.cropList:reloadData()
    for i, crop in ipairs(self.cropInfo) do
        if crop.index == self.selectedCrop then
            self.cropList:setSelectedItem(1, i, false, false)
            break
        end
    end
end


function YieldTrackerPage:onClickCropSelected(element)
    local selected = self.cropInfo[element.indexInSection]
    if selected == nil then return end
    self.selectedCrop = selected.index
    self.preferredCrop = selected.index
    self:setSelectedPageData()
end


function YieldTrackerPage:onClickFieldSelected(element)
    self.selectedEntry = self.fieldEntries[element.indexInSection]
    self:onFieldEntryChanged()
end


-- COMBINED FIELDS
function YieldTrackerPage:getFieldTitle(farmlandId)
    return string.format("%s %d", self.i18n:getText("yt_fieldIDLabel"), farmlandId)
end


-- Returns "3 + 4", listing each farmland once.
function YieldTrackerPage:getFieldGroupMemberList(group)
    local seen = {}
    local farmlandIds = {}
    for _, member in ipairs(group.members) do
        if not seen[member.farmlandId] then
            seen[member.farmlandId] = true
            table.insert(farmlandIds, tostring(member.farmlandId))
        end
    end
    return table.concat(farmlandIds, " + ")
end


function YieldTrackerPage:getFieldGroupTitle(group)
    return group.name or string.format("%s %s", self.i18n:getText("yt_fieldIDLabel"), self:getFieldGroupMemberList(group))
end


function YieldTrackerPage:getEntryRowText(entry)
    if entry.group == nil then
        return self:getFieldTitle(entry.farmlandId)
    elseif entry.group.name ~= nil then
        return string.format("%s (%s)", entry.group.name, self:getFieldGroupMemberList(entry.group))
    end
    return self:getFieldGroupTitle(entry.group)
end


function YieldTrackerPage:getEntryTitle(entry)
    if entry == nil then
        return ""
    elseif entry.group ~= nil then
        return self:getFieldGroupTitle(entry.group)
    end
    return self:getFieldTitle(entry.farmlandId)
end


-- The small line under the field title, explaining why the numbers start late or look small.
function YieldTrackerPage:getEntryNote(entry)
    if entry == nil then
        return ""
    end

    if entry.group ~= nil then
        local startYear = YieldTracker:getFieldGroupStartYear(entry.group)
        local endYear = YieldTracker:getFieldGroupEndYear(entry.group)
        if endYear ~= nil then
            return string.format(self.i18n:getText("yt_combinedRangeNote"), startYear, endYear)
        end
        return string.format(self.i18n:getText("yt_combinedSinceNote"), startYear)
    end

    local group, member = YieldTracker:getOpenFieldGroup(entry.farmlandId)
    if group ~= nil then
        return string.format(self.i18n:getText("yt_partOfNote"), self:getFieldGroupTitle(group), member.fromYear)
    end
    return ""
end


-- Offers a choice of years, newest first.
function YieldTrackerPage:showYearDialog(prompt, title, minYear, maxYear, callback)
    local years = {}
    local options = {}
    for year = maxYear, minYear, -1 do
        table.insert(years, year)
        table.insert(options, string.format("%s %d", self.i18n:getText("yt_yearLabel"), year))
    end

    OptionDialog.show(function(result)
        if result > 0 then
            callback(years[result])
        end
    end, prompt, title, options)
end


function YieldTrackerPage:showNameDialog(defaultName, callback)
    self.nameDialogCallback = callback
    TextInputDialog.show(self.onNameDialogResult, self, defaultName, self.i18n:getText("yt_namePrompt"), nil,
        YieldTrackerPage.MAX_NAME_LENGTH, self.i18n:getText("yt_saveBtnTxt"), nil, nil, false)
end


function YieldTrackerPage:onNameDialogResult(text, success)
    local callback = self.nameDialogCallback
    self.nameDialogCallback = nil

    if success and callback ~= nil then
        local name = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        callback(name)
    end
end


function YieldTrackerPage:onClickCombineFields()
    local entry = self.selectedEntry
    if entry == nil then
        return
    elseif entry.group ~= nil then
        self:showEditDialog(entry.group)
    else
        self:showCombineDialog(entry.farmlandId)
    end
end


-- Owned farmlands that aren't combined at the moment, apart from the ones given.
function YieldTrackerPage:getCombineCandidates(excludedFarmlandId)
    local candidates = {}
    local options = {}
    for _, farmlandId in ipairs(self:getFarmlandIDs(true)) do
        if farmlandId ~= excludedFarmlandId and YieldTracker:getOpenFieldGroup(farmlandId) == nil then
            table.insert(candidates, farmlandId)
            table.insert(options, self:getFieldTitle(farmlandId))
        end
    end
    return candidates, options
end


function YieldTrackerPage:showCombineDialog(farmlandId)
    local group = YieldTracker:getOpenFieldGroup(farmlandId)
    if group ~= nil then
        InfoDialog.show(string.format(self.i18n:getText("yt_alreadyCombinedMsg"), self:getFieldTitle(farmlandId), self:getFieldGroupTitle(group)))
        return
    end

    local candidates, options = self:getCombineCandidates(farmlandId)
    if #candidates == 0 then
        InfoDialog.show(self.i18n:getText("yt_noFieldsToCombineMsg"))
        return
    end

    OptionDialog.show(function(result)
        if result > 0 then
            self:queueDialog(function() self:showCombineYearDialog(farmlandId, candidates[result]) end)
        end
    end, string.format(self.i18n:getText("yt_combineWithPrompt"), self:getFieldTitle(farmlandId)), self.i18n:getText("yt_combineFieldsBtnTxt"), options)
end


function YieldTrackerPage:showCombineYearDialog(farmlandId, otherFarmlandId)
    local minYear = math.max(YieldTracker:getEarliestFreeYear(farmlandId), YieldTracker:getEarliestFreeYear(otherFarmlandId))

    self:showYearDialog(self.i18n:getText("yt_combinedSincePrompt"), self.i18n:getText("yt_combineFieldsBtnTxt"), minYear, g_currentMission.environment.currentYear, function(year)
        self:queueDialog(function()
            local defaultName = string.format("%s %d + %d", self.i18n:getText("yt_fieldIDLabel"), farmlandId, otherFarmlandId)
            self:showNameDialog(defaultName, function(name)
                local groupName = name ~= "" and name ~= defaultName and name or nil
                local group = YieldTracker:createFieldGroup({ farmlandId, otherFarmlandId }, year, groupName)
                self.selectedEntry = { group = group }
                self:refreshFieldList()
            end)
        end)
    end)
end


function YieldTrackerPage:showEditDialog(group)
    local title = self.i18n:getText("yt_editCombinedFieldBtnTxt")
    local actions = {}
    local options = {}
    local function addAction(textKey, action)
        table.insert(options, self.i18n:getText(textKey))
        table.insert(actions, action)
    end

    local isRunning = YieldTracker:getFieldGroupEndYear(group) == nil
    if isRunning then
        addAction("yt_addFieldOption", function() self:showAddFieldDialog(group) end)
    end
    addAction("yt_changeStartYearOption", function() self:showStartYearDialog(group) end)
    addAction("yt_renameOption", function()
        self:showNameDialog(self:getFieldGroupTitle(group), function(name)
            local defaultName = string.format("%s %s", self.i18n:getText("yt_fieldIDLabel"), self:getFieldGroupMemberList(group))
            group.name = name ~= "" and name ~= defaultName and name or nil
            self:refreshFieldList()
        end)
    end)
    if isRunning then
        addAction("yt_splitOption", function() self:showSplitDialog(group) end)
    else
        addAction("yt_undoSplitOption", function()
            if YieldTracker:undoFieldGroupSplit(group) then
                self:refreshFieldList()
            else
                InfoDialog.show(self.i18n:getText("yt_cannotUndoSplitMsg"))
            end
        end)
    end
    addAction("yt_deleteOption", function() self:showDeleteDialog(group) end)

    OptionDialog.show(function(result)
        if result > 0 then
            self:queueDialog(actions[result])
        end
    end, self:getFieldGroupTitle(group), title, options)
end


function YieldTrackerPage:showAddFieldDialog(group)
    local candidates, options = self:getCombineCandidates()
    if #candidates == 0 then
        InfoDialog.show(self.i18n:getText("yt_noFieldsToCombineMsg"))
        return
    end

    OptionDialog.show(function(result)
        if result > 0 then
            self:queueDialog(function()
                local farmlandId = candidates[result]
                local minYear = math.max(YieldTracker:getFieldGroupStartYear(group), YieldTracker:getEarliestFreeYear(farmlandId))
                self:showYearDialog(self.i18n:getText("yt_combinedSincePrompt"), self.i18n:getText("yt_addFieldOption"), minYear, g_currentMission.environment.currentYear, function(year)
                    YieldTracker:addFieldGroupMember(group, farmlandId, year)
                    self:refreshFieldList()
                end)
            end)
        end
    end, self.i18n:getText("yt_addFieldPrompt"), self.i18n:getText("yt_addFieldOption"), options)
end


function YieldTrackerPage:showStartYearDialog(group)
    local minYear, maxYear = YieldTracker:getFieldGroupStartYearRange(group)
    self:showYearDialog(self.i18n:getText("yt_combinedSincePrompt"), self.i18n:getText("yt_changeStartYearOption"), minYear, maxYear, function(year)
        YieldTracker:setFieldGroupStartYear(group, year)
        self:refreshFieldList()
    end)
end


function YieldTrackerPage:showSplitDialog(group)
    local minYear, maxYear = YieldTracker:getFieldGroupSplitYearRange(group)
    if minYear > maxYear then
        InfoDialog.show(self.i18n:getText("yt_cannotSplitMsg"))
        return
    end

    self:showYearDialog(self.i18n:getText("yt_splitPrompt"), self.i18n:getText("yt_splitOption"), minYear, maxYear, function(year)
        YieldTracker:splitFieldGroup(group, year)
        self:refreshFieldList()
    end)
end


function YieldTrackerPage:showDeleteDialog(group)
    YesNoDialog.show(function(_, yes)
        if yes then
            YieldTracker:deleteFieldGroup(group)
            self.selectedEntry = nil
            self:refreshFieldList()
        end
    end, self, string.format(self.i18n:getText("yt_deletePrompt"), self:getFieldGroupTitle(group)), self.i18n:getText("yt_deleteOption"))
end
-- COMBINED FIELDS - END


function YieldTrackerPage:setSelectedPageData()
    self:initiateFieldCropStatsSearch()
    self:setOverviewStatsText()

    self:setGraphData()
end


function YieldTrackerPage:initiateFieldCropStatsSearch()
    local entry = self.selectedEntry
    local selectedField = entry ~= nil and entry.farmlandId or nil
    local selectedFillTypeIndex = self.selectedCrop
    local yieldData = YieldTracker.yieldData
    local currentYear = g_currentMission.environment.currentYear
    local foundData = false
    self.yieldYears = {} -- Clear existing data

    local yearAmountMap = {}
    local minYear = nil
    local lastYear = currentYear

    -- Step 1: Collect data and find min year (no crop selected means nothing has been recorded yet)
    if entry ~= nil and entry.group ~= nil and selectedFillTypeIndex ~= nil then
        -- Combined field: its history starts in the year the fields were combined and stops if they were split
        yearAmountMap = YieldTracker:getFieldGroupYearAmounts(entry.group, selectedFillTypeIndex)
        for year in pairs(yearAmountMap) do
            minYear = (minYear == nil or year < minYear) and year or minYear
            foundData = true
        end
        lastYear = YieldTracker:getFieldGroupEndYear(entry.group) or currentYear
    elseif selectedField ~= nil and selectedFillTypeIndex ~= nil then
        local fillTypeName = tostring(g_fillTypeManager:getFillTypeNameByIndex(selectedFillTypeIndex))
        self:debugMessage(string.format("Search stats for %s on field %d", fillTypeName, selectedField))

        for year, yearData in pairs(yieldData) do
            local fieldData = yearData[selectedField]
            if fieldData then
                local cropData = fieldData[selectedFillTypeIndex]
                if cropData then
                    yearAmountMap[year] = cropData.amount
                    minYear = (minYear == nil or year < minYear) and year or minYear
                    foundData = true

                    self:debugMessage(string.format(
                        "Year %d - Field %d - Crop: %s - Amount: %d",
                        year, selectedField, fillTypeName, cropData.amount
                    ))
                else
                    self:debugMessage(string.format("Year %d - Field %d - No data for %s", year, selectedField, fillTypeName))
                end
            else
                self:debugMessage(string.format("Year %d - No data for field %d", year, selectedField))
            end
        end
    end


    -- Step 2: Fill in all years from startYear (e.g., 1) to maxYear
    local startYear = 1 -- You can change this to the actual first possible year
    if entry ~= nil and entry.group ~= nil then
        startYear = YieldTracker:getFieldGroupStartYear(entry.group)
    end
    if minYear ~= nil then
        local maxYear = lastYear
        -- Extend maxYear to the latest year found in data if it's greater
        for year in pairs(yearAmountMap) do
            if year > maxYear then
                maxYear = year
            end
        end

        for year = startYear, maxYear do
            local amount = yearAmountMap[year] or 0
            table.insert(self.yieldYears, {
                year = year,
                amount = amount
            })
        end
    end

    -- -- Sort by year ascending
    -- table.sort(self.yieldYears, function(a, b) return a.year < b.year end)
    -- Sort by year descending
    table.sort(self.yieldYears, function(a, b) return a.year > b.year end)

    if self.yieldPerYearList then
        self.yieldPerYearList:reloadData()
    end

    -- Show message only if no data found
    self.noYieldHistoryText:setVisible(not foundData)
    self.yieldStatsInformation:setVisible(foundData)
end


function YieldTrackerPage:setOverviewStatsText()
    local cropName = ""
    local cropIcon = nil

    -- Get crop name from fillTypeIndex
    for _, crop in ipairs(self.cropInfo) do
        if crop.index == self.selectedCrop then
            cropName = crop.title
            cropIcon = crop.hudOverlayFilename
            break
        end
    end

    local pageIcon = Utils.getFilename("images/page_header_icon.dds", YieldTrackerPage.dir)
    local pageHeaderIcon = self:getDescendantById("pageHeaderIcon")
    pageHeaderIcon:setImageFilename(pageIcon)

    local selectedOverviewData = self:fetchOverviewStats()
    local selectedFieldNumText = self:getDescendantById("selectedFieldNumText")
    local selectedCropTypeText = self:getDescendantById("selectedCropTypeText")
    local selectedCropTypeIcon = self:getDescendantById("selectedCropicon")
    local selectedCropTotalHarvests = self:getDescendantById("selectedCropTotalHarvests")
    local selectedCropAverageYield = self:getDescendantById("selectedCropAverageYield")
    local selectedCropBestYear = self:getDescendantById("selectedCropBestYear")

    if selectedFieldNumText and selectedCropTypeText and selectedCropTypeIcon and selectedCropTotalHarvests and selectedCropAverageYield and selectedCropBestYear then
        selectedFieldNumText:setText(self:getEntryTitle(self.selectedEntry))

        local selectedFieldNoteText = self:getDescendantById("selectedFieldNoteText")
        if selectedFieldNoteText then
            selectedFieldNoteText:setText(self:getEntryNote(self.selectedEntry))
        end

        -- Fill type titles are already localized by the game (including map/mod crops)
        selectedCropTypeText:setText(cropName)

        selectedCropTotalHarvests:setText(selectedOverviewData.totalYears)
        selectedCropAverageYield:setText(string.format("%s l", formatWithCommas(selectedOverviewData.averageYield)))

        selectedCropBestYear:setText(string.format("%s %d  -->  %s l", self.i18n:getText("yt_yearLabel"), selectedOverviewData.highestYear, formatWithCommas(selectedOverviewData.highestYieldAmount)))

        if cropIcon ~= nil then
            selectedCropTypeIcon:setImageFilename(cropIcon)
        end
        selectedCropTypeIcon:setVisible(cropIcon ~= nil)
    end
end


function YieldTrackerPage:fetchOverviewStats()
    local totalYears = 0
    local totalAmount = 0
    local totalEntries = 0
    local highestYieldAmount = 0
    local highestYear = 0

    for _, entry in ipairs(self.yieldYears) do
        local yearYieldAmount = entry.amount or 0

        if yearYieldAmount > 0 then
            totalAmount = totalAmount + yearYieldAmount
            totalEntries = totalEntries + 1
            totalYears = totalYears + 1

            if yearYieldAmount > highestYieldAmount then
                highestYieldAmount = yearYieldAmount
                highestYear = entry.year
            end
        end
    end

    local averageYield = totalEntries > 0 and (totalAmount / totalEntries) or 0

    return {
        totalYears = totalYears,
        averageYield = averageYield,
        highestYear = highestYear,
        highestYieldAmount = highestYieldAmount
    }
end


-- SET GRAPH FUNCTIONALITY
function YieldTrackerPage:clearOldElements(container, template)
    for i = #container.elements, 1, -1 do
        local child = container.elements[i]
        if child ~= template then
            container:removeElement(child)
        end
    end
end


function YieldTrackerPage:extractYears(data)
    local years = {}
    for _, harvest in ipairs(data) do
        if harvest.year then
            table.insert(years, harvest.year)
        end
    end
    table.sort(years)
    return years
end


function YieldTrackerPage:calculateDisplayRange(minYear, maxYear)
    local rangeYears = maxYear - minYear + 1
    local displayMinYear, displayMaxYear
    if rangeYears >= 20 then
        displayMaxYear = maxYear
        displayMinYear = displayMaxYear - 19
    else
        displayMinYear = minYear
        displayMaxYear = displayMinYear + 19
    end
    return displayMinYear, displayMaxYear
end


function YieldTrackerPage:createHarvestLookup(data, minYear, maxYear)
    local lookup = {}
    for _, harvest in ipairs(data) do
        if harvest.year and harvest.year >= minYear and harvest.year <= maxYear then
            lookup[harvest.year] = harvest
        end
    end
    return lookup
end


function YieldTrackerPage:findMaxYield(harvestByYear, minYear, maxYear)
    local maxYield = 0
    for year = minYear, maxYear do
        local h = harvestByYear[year]
        if h and h.amount and h.amount > maxYield then
            maxYield = h.amount
        end
    end
    return maxYield
end

function YieldTrackerPage:findMinYield(harvestByYear, startYear, endYear)
    local min = math.huge
    for year = startYear, endYear do
        local data = harvestByYear[year]
        if data and data.amount and data.amount < min then
            min = data.amount
        end
    end
    return min
end


function YieldTrackerPage:setGraphData()
    if not self.yieldYears or #self.yieldYears == 0 then return end

    local tickContainer = self:getDescendantById("graphYearTickContainer")
    local barGraph = self:getDescendantById("barGraph")

    self:clearOldElements(tickContainer, self.graphYearTickTemplate)
    self:clearOldElements(barGraph, self.graphCandleTemplate)

    local years = self:extractYears(self.yieldYears)
    if #years == 0 then return end

    local actualMinYear = years[1]
    local actualMaxYear = years[#years]

    local displayMinYear, displayMaxYear = self:calculateDisplayRange(actualMinYear, actualMaxYear)

    local harvestByYear = self:createHarvestLookup(self.yieldYears, displayMinYear, displayMaxYear)

    local maxYield = self:findMaxYield(harvestByYear, displayMinYear, displayMaxYear)
    local minYield = self:findMinYield(harvestByYear, displayMinYear, displayMaxYear)
    local yieldRange = math.max(1, maxYield - minYield)

    local numTicks = displayMaxYear - displayMinYear + 1
    local totalGraphWidth = barGraph.size[1] * 0.9
    local spacing = totalGraphWidth / math.max(1, numTicks - 1)
    local candleWidth = spacing * 0.45
    local candleOffset = spacing * 0.84



    for year = displayMinYear, displayMaxYear do
        local tickX = (year - displayMinYear) * spacing

        -- Year tick label
        local tickClone = self.graphYearTickTemplate:clone(tickContainer)
        tickClone:setText(tostring(year))
        tickClone:setPosition(tickX, 0)
        tickClone:setVisible(true)

        -- Yield candle if data exists for this year
        local harvest = harvestByYear[year]
        if harvest then
            local yearYieldAmount = harvest.amount or 0

            if yearYieldAmount and yearYieldAmount > 0 then
                local candleClone = self.graphCandleTemplate:clone(barGraph)
                local minHeight = 0.08
                local heightRatio = (yearYieldAmount - minYield) / yieldRange
                -- heightRatio = math.sqrt(heightRatio) -- apply easing
                local candleHeight = minHeight + heightRatio * (0.27 - minHeight)

                candleClone:setSize(candleWidth, candleHeight)
                candleClone:setPosition(tickX + candleOffset, 0)
                candleClone:setVisible(true)
            end
        end
    end
end
-- SET GRAPH FUNCTIONALITY - END


function YieldTrackerPage:populateCellForItemInSection(list, sectionIndex, index, listItem)
    if list == self.farmlandList then
        local entry = self.fieldEntries[index]
        local fieldIDListText = listItem:getAttribute("fieldIDListText")
        if fieldIDListText and entry then
            fieldIDListText:setText(self:getEntryRowText(entry))
        end
    elseif list == self.cropList then
        local crop = self.cropInfo[index]
        if crop then
            local cropListText = listItem:getAttribute("cropListText")
            local icon = listItem:getAttribute("icon")

            if cropListText then
                cropListText:setText(crop.title)
            end

            if icon then
                if crop.hudOverlayFilename ~= nil then
                    icon:setImageFilename(crop.hudOverlayFilename)
                end
                icon:setVisible(crop.hudOverlayFilename ~= nil)
            end
        end
    elseif list == self.yieldPerYearList then
        local entry = self.yieldYears[index]
        if entry then
            local yearText = listItem:getDescendantByName("year")
            local amountText = listItem:getDescendantByName("yieldAmt")
            if yearText then
                yearText:setText(string.format("%s %s", self.i18n:getText("yt_yearLabel"), tostring(entry.year)))
            end
            if amountText then
                amountText:setText(formatWithCommas(entry.amount) .. " l")
            end   
        end
    end
end



function YieldTrackerPage:getCellTypeForItemInSection(_, sectionIndex, index)
    return "default"
end


function YieldTrackerPage:getNumberOfItemsInSection(list, sectionIndex)
    if list == self.farmlandList then
        return #self.fieldEntries
    elseif list == self.cropList then
        return #self.cropInfo
    elseif list == self.yieldPerYearList then
        return #self.yieldYears
    end
    return 0
end



function YieldTrackerPage:debugMessage(message)
    if self.debug then
        print(PRINT_PREFIX .. message)
    end
end


-- DEBUG
-- function dump(o, indent, depth)
--     indent = indent or ""
--     depth = depth or 1

--     if type(o) ~= "table" then
--         return tostring(o)
--     elseif depth <= 0 then
--         return "{...}"
--     end

--     local s = "{\n"
--     for k, v in pairs(o) do
--         s = s .. indent .. "  [" .. tostring(k) .. "] = "
--         if type(v) == "table" then
--             s = s .. dump(v, indent .. "  ", depth - 1)
--         else
--             s = s .. tostring(v)
--         end
--         s = s .. "\n"
--     end
--     return s .. indent .. "}"
-- end
