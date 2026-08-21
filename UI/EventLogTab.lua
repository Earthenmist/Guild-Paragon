-- Guild Paragon — Event Log tab
--
-- Browsable guild event history with display filters. Event rows render
-- structured Guild Paragon entries with class-colored character names, while
-- preserved import strings keep their original embedded colors.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.EventLogTab = GP.UI.EventLogTab or {}
local EventLogTab = GP.UI.EventLogTab

-- Own AceEvent identity, not GP — see UI/RecruitmentTab.lua's long comment
-- above its own Embed call for the full root-cause explanation: multiple
-- tabs registering the same message name against the shared GP table
-- silently overwrite each other. This tab shared GuildParagon_LogEntryAdded
-- with several other GP-registered tabs before this fix.
LibStub("AceEvent-3.0"):Embed(EventLogTab)

local COL = {
    leftPad   = 8,
    gap       = 8,
    lineWidth = 42,
    timeWidth = 130,
    removeWidth = 62,
}

local ROW_HEIGHT = 26
local FILTER_WIDTH = 230

local CATEGORY_COLORS = {
    join = Theme.color.success,
    joindate = Theme.color.success,
    leave = Theme.color.danger,
    promote = Theme.color.warning,
    demote = { 1.000, 0.533, 0.286, 1.00 },
    level = { 0.000, 0.440, 0.870, 1.00 },
    inactivereturn = { 0.000, 0.850, 0.850, 1.00 },
    note = { 0.537, 0.722, 1.000, 1.00 },
    officernote = { 1.000, 0.525, 0.780, 1.00 },
    customnote = Theme.color.accent,
    customofficernote = { 0.882, 0.455, 1.000, 1.00 },
    nickname = { 0.455, 0.843, 1.000, 1.00 },
    altlinked = { 0.714, 0.596, 1.000, 1.00 },
    altcleared = { 0.714, 0.596, 1.000, 1.00 },
    markedmain = { 0.714, 0.596, 1.000, 1.00 },
    unmarkedmain = { 0.714, 0.596, 1.000, 1.00 },
    birthday = { 1.000, 0.812, 0.424, 1.00 },
    banadded = Theme.color.danger,
    banedited = Theme.color.danger,
    banremoved = Theme.color.success,
    banwarning = Theme.color.danger,
    macromatch = Theme.color.accent,
    grmimport = Theme.color.textSecondary,
    labeladded = { 0.243, 0.851, 0.753, 1.00 },
    labelremoved = { 0.243, 0.851, 0.753, 1.00 },
}

local FILTERS = {
    { key = "join", label = "Joined", types = { join = true, joindate = true } },
    { key = "leave", label = "Left", types = { leave = true } },
    { key = "promote", label = "Promotions", types = { promote = true } },
    { key = "demote", label = "Demotions", types = { demote = true } },
    { key = "level", label = "Leveled", types = { level = true } },
    { key = "inactivereturn", label = "Inactive Return", types = { inactivereturn = true } },
    { key = "note", label = "Note", types = { note = true } },
    { key = "officernote", label = "Officer's Note", types = { officernote = true } },
    { key = "customnote", label = "Custom Note", types = { customnote = true } },
    { key = "customofficernote", label = "Custom Officer Note", types = { customofficernote = true } },
    { key = "nickname", label = "Name/Nickname", types = { nickname = true } },
    { key = "alts", label = "Alt/Main", types = { altlinked = true, altcleared = true, markedmain = true, unmarkedmain = true } },
    { key = "birthday", label = "Birthday", types = { birthday = true } },
    { key = "ban", label = "Ban List", types = { banadded = true, banedited = true, banremoved = true, banwarning = true } },
    { key = "label", label = "Labels", types = { labeladded = true, labelremoved = true } },
    -- Historical macro-match rows only; new entries are not created.
    { key = "macro", label = "Macro Rules (legacy)", types = { macromatch = true } },
    { key = "grmimport", label = "Imported GRM", types = { grmimport = true } },
}

local frame, list, searchBox, summaryText, filtersPanel
local refreshDirty = false
local filterChecks = {}
local getGuildKey

local REMOVE_ENTRY_POPUP = "GUILDPARAGON_REMOVE_EVENT_LOG_ENTRY"
local CLEAR_VISIBLE_POPUP = "GUILDPARAGON_CLEAR_VISIBLE_EVENT_LOG"
local CLEAR_RANGE_POPUP = "GUILDPARAGON_CLEAR_RANGE_EVENT_LOG"
local EXPORT_VISIBLE_POPUP = "GUILDPARAGON_EXPORT_VISIBLE_EVENT_LOG"
StaticPopupDialogs[REMOVE_ENTRY_POPUP] = StaticPopupDialogs[REMOVE_ENTRY_POPUP] or {
    text = GP.L["Remove this Event Log entry?\n\n%s"],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, entryID)
        local guildKey = getGuildKey()
        local ok, err = GP:GetModule("EventLog"):RemoveEntry(guildKey, entryID)
        if not ok then GP:Print(err) end
        EventLogTab:Refresh()
    end,
}
StaticPopupDialogs[CLEAR_VISIBLE_POPUP] = StaticPopupDialogs[CLEAR_VISIBLE_POPUP] or {
    text = GP.L["Remove %d visible Event Log entries?"],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, entryIDs)
        local guildKey = getGuildKey()
        local removed, err = GP:GetModule("EventLog"):RemoveEntries(guildKey, entryIDs)
        if removed then
            GP:Print(string.format(GP.L["Removed %d Event Log entries."], removed))
        else
            GP:Print(err)
        end
        EventLogTab:Refresh(true)
    end,
}
StaticPopupDialogs[CLEAR_RANGE_POPUP] = StaticPopupDialogs[CLEAR_RANGE_POPUP] or {
    text = GP.L["Remove visible Event Log lines %s?\n\nThis will remove %d entries from the current filtered view."],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, payload)
        local guildKey = getGuildKey()
        local removed, err = GP:GetModule("EventLog"):RemoveEntries(guildKey, payload and payload.entryIDs)
        if removed then
            GP:Print(string.format(GP.L["Removed %d Event Log entries."], removed))
            if payload and payload.fromBox then payload.fromBox:SetText("0") end
            if payload and payload.toBox then payload.toBox:SetText("0") end
        else
            GP:Print(err)
        end
        EventLogTab:Refresh(true)
    end,
}
StaticPopupDialogs[EXPORT_VISIBLE_POPUP] = StaticPopupDialogs[EXPORT_VISIBLE_POPUP] or {
    text = GP.L["Copy visible Event Log export:"],
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 520,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self, text)
        local editBox = self.editBox or self.EditBox
        if editBox then
            editBox:SetText(text or "")
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self)
        local editBox = self.editBox or self.EditBox
        if editBox then editBox:ClearFocus() end
    end,
}

getGuildKey = function()
    local Roster = GP:GetModule("Roster")
    return Roster.currentGuildKey or Roster:GetGuildKey()
end

local function getFilterState()
    GP.db.profile.eventLog = GP.db.profile.eventLog or {}
    GP.db.profile.eventLog.filters = GP.db.profile.eventLog.filters or {}
    return GP.db.profile.eventLog.filters
end

local function eventLogSettings()
    GP.db.profile.eventLog = GP.db.profile.eventLog or {}
    GP.db.profile.eventLog.toChat = GP.db.profile.eventLog.toChat or {}
    if GP.db.profile.eventLog.numberedLines == nil then
        GP.db.profile.eventLog.numberedLines = true
    end
    if GP.db.profile.eventLog.categoryColors == nil then
        GP.db.profile.eventLog.categoryColors = true
    end
    return GP.db.profile.eventLog
end

local function getChatState()
    local settings = eventLogSettings()
    settings.toChat = settings.toChat or {}
    return settings.toChat
end

local function cleanCell(value)
    if value == nil then return "" end
    value = tostring(value)
    value = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    value = value:gsub("[\r\n\t]", " ")
    return value
end

local function exportVisibleEntries(entries)
    local guildKey = getGuildKey()
    local EventLog = GP:GetModule("EventLog")
    local lines = { table.concat({ "line", "time", "type", "name", "guid", "event", "id" }, "\t") }
    for index, entry in ipairs(entries or {}) do
        table.insert(lines, table.concat({
            cleanCell(index),
            cleanCell(entry.ts and date("%Y-%m-%d %H:%M:%S", entry.ts) or ""),
            cleanCell(entry.type),
            cleanCell(entry.name),
            cleanCell(entry.guid),
            cleanCell(EventLog:Render(entry, guildKey, false)),
            cleanCell(entry.id),
        }, "\t"))
    end
    return table.concat(lines, "\n")
end

local buildDisplayList

local function collectVisibleRangeIDs(fromLine, toLine)
    fromLine = math.floor(GP:SafeNumber(fromLine, 0))
    toLine = math.floor(GP:SafeNumber(toLine, 0))
    if fromLine <= 0 or toLine <= 0 then return nil, GP.L["Enter a valid line range."] end
    if toLine < fromLine then
        fromLine, toLine = toLine, fromLine
    end

    local visible = buildDisplayList()
    if #visible == 0 then return nil, GP.L["No log entries selected."] end
    if fromLine > #visible then return nil, GP.L["Line range is outside the visible Event Log."] end
    toLine = math.min(toLine, #visible)

    local ids = {}
    for index = fromLine, toLine do
        local entry = visible[index]
        if entry and entry.id then table.insert(ids, entry.id) end
    end
    if #ids == 0 then return nil, GP.L["No log entries selected."] end
    return ids, nil, fromLine, toLine
end

local function isFilterEnabled(def)
    local filters = getFilterState()
    if filters[def.key] == nil then
        filters[def.key] = true
    end
    return filters[def.key] ~= false
end

local function isEntryVisibleByType(entry)
    if not GP:GetModule("EventLog"):CanDisplayEntry(entry) then return false end
    for _, def in ipairs(FILTERS) do
        if def.types[entry.type] then
            return isFilterEnabled(def)
        end
    end
    return true
end

local function createCheck(parent, label, onClick)
    local button = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    button:SetSize(22, 22)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(Theme.font.body)
    text:SetPoint("LEFT", button, "RIGHT", 4, 0)
    text:SetText(label)
    text:SetWidth(150)
    text:SetWordWrap(false)
    text:SetJustifyH("LEFT")
    button.text = text

    button:SetScript("OnClick", function(self)
        if onClick then onClick(self:GetChecked() and true or false) end
    end)
    return button
end

-- Row widget

local function createLogRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    local lineText = row:CreateFontString(nil, "ARTWORK")
    lineText:SetFontObject(Theme.font.muted)
    lineText:SetJustifyH("LEFT")
    lineText:SetPoint("LEFT", COL.leftPad, 0)
    lineText:SetWidth(COL.lineWidth)
    row.lineText = lineText

    local timeText = row:CreateFontString(nil, "ARTWORK")
    timeText:SetFontObject(Theme.font.muted)
    timeText:SetJustifyH("LEFT")
    timeText:SetPoint("LEFT", lineText, "RIGHT", COL.gap, 0)
    timeText:SetWidth(COL.timeWidth)
    row.timeText = timeText

    local removeButton = Theme:CreateButton(row, GP.L["Remove"])
    removeButton:SetPoint("RIGHT", -8, 0)
    removeButton:SetWidth(COL.removeWidth)
    row.removeButton = removeButton

    local eventText = row:CreateFontString(nil, "ARTWORK")
    eventText:SetFontObject(Theme.font.body)
    eventText:SetJustifyH("LEFT")
    eventText:SetPoint("LEFT", timeText, "RIGHT", COL.gap, 0)
    eventText:SetPoint("RIGHT", removeButton, "LEFT", -8, 0)
    eventText:SetWordWrap(false)
    if eventText.SetHyperlinksEnabled and eventText.SetScript then
        eventText:SetHyperlinksEnabled(true)
        eventText:SetScript("OnHyperlinkClick", function(_, link)
            local Hyperlinks = GP:GetModule("Hyperlinks", true)
            if Hyperlinks and Hyperlinks.HandleLink then Hyperlinks:HandleLink(link) end
        end)
    end
    row.eventText = eventText
    row:EnableMouse(true)

    return row
end

local function updateLogRow(row, entry, index)
    local guildKey = getGuildKey()
    local EventLog = GP:GetModule("EventLog")
    row.lineText:SetText(eventLogSettings().numberedLines and string.format("%d)", index) or "")
    row.timeText:SetText(date("%Y-%m-%d %H:%M", entry.ts))
    row.eventText:SetText(EventLog:Render(entry, guildKey, true, true))
    local categoryColor = eventLogSettings().categoryColors and CATEGORY_COLORS[entry.type] or Theme.color.textSecondary
    row.lineText:SetTextColor(unpack(categoryColor or Theme.color.textSecondary))
    row.timeText:SetTextColor(unpack(categoryColor or Theme.color.textSecondary))

    local canRemove = GP:IsOfficer() and entry.id
    row.removeButton:SetShown(canRemove and true or false)
    row.removeButton:SetScript("OnClick", function()
        local preview = EventLog:Render(entry, guildKey, false)
        StaticPopup_Show(REMOVE_ENTRY_POPUP, preview, nil, entry.id)
    end)
    row:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" or not entry.guid then return end
        local Hyperlinks = GP:GetModule("Hyperlinks", true)
        if Hyperlinks and Hyperlinks.OpenMember then
            local ok, err = Hyperlinks:OpenMember(entry.guid, entry.name)
            if not ok and err then GP:Print(err) end
        end
    end)
end

-- Data: filter, newest-first

buildDisplayList = function()
    local guildKey = getGuildKey()
    local EventLog = GP:GetModule("EventLog")
    local log = guildKey and EventLog:GetLog(guildKey)
    local out = {}
    if not log then return out end

    local filterText = strtrim(searchBox:GetText() or ""):lower()
    for i = #log, 1, -1 do
        local entry = log[i]
        if isEntryVisibleByType(entry) and not EventLog:IsRemoved(guildKey, entry) then
            local rendered = EventLog:Render(entry)
            local searchable = ((entry.name or "") .. " " .. (entry.type or "") .. " " .. (rendered or "")):lower()
            if filterText == "" or searchable:find(filterText, 1, true) then
                table.insert(out, entry)
            end
        end
    end
    return out
end

-- Top-level refresh

function EventLogTab:Refresh(resetScroll)
    if not frame then return end

    local guildKey = getGuildKey()
    local EventLog = GP:GetModule("EventLog")
    local displayList = buildDisplayList()
    list:SetData(displayList, resetScroll)

    if guildKey then
        local visibleTotal = EventLog:CountDisplayable(guildKey)
        summaryText:SetText(string.format(GP.L["Showing %d of %d log entries"], #displayList, visibleTotal))
    else
        summaryText:SetText(GP.L["No log data yet — try /gp scan."])
    end
end

-- Build

local function buildFilters(parent)
    filtersPanel = Theme:CreatePanel(parent, "panel", "border")
    filtersPanel:SetPoint("TOPRIGHT")
    filtersPanel:SetPoint("BOTTOMRIGHT")
    filtersPanel:SetWidth(FILTER_WIDTH)

    local title = filtersPanel:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.heading)
    title:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    title:SetText(GP.L["Display Changes"])

    local chatHeader = filtersPanel:CreateFontString(nil, "ARTWORK")
    chatHeader:SetFontObject(Theme.font.small)
    chatHeader:SetJustifyH("RIGHT")
    chatHeader:SetPoint("TOPRIGHT", filtersPanel, "TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter - 2)
    chatHeader:SetWidth(58)
    chatHeader:SetText(GP.L["To Chat"])

    local previous
    for _, def in ipairs(FILTERS) do
        local canShow = true
        for entryType in pairs(def.types) do
            if not GP:GetModule("EventLog"):CanDisplayEntry({ type = entryType }) then
                canShow = false
                break
            end
        end
        if canShow then
            local check = createCheck(filtersPanel, GP.L[def.label], function(value)
                getFilterState()[def.key] = value
                EventLogTab:Refresh(true)
            end)
            check:SetChecked(isFilterEnabled(def))
            if previous then
                check:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
            else
                check:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
            end
            filterChecks[def.key] = check

            -- No chat echo for imported or historical-only rows.
            if def.key ~= "grmimport" and def.key ~= "macro" then
                local chatCheck = createCheck(filtersPanel, "", function(value)
                    getChatState()[def.key] = value
                end)
                chatCheck:SetPoint("RIGHT", filtersPanel, "RIGHT", -Theme.layout.gutter, 0)
                chatCheck:SetPoint("TOP", check, "TOP", 0, 0)
                chatCheck:SetChecked(getChatState()[def.key] == true)
            end
            previous = check
        end
    end

    local allButton = Theme:CreateButton(filtersPanel, GP.L["Check All"])
    allButton:SetPoint("TOPLEFT", previous or title, "BOTTOMLEFT", 0, -8)
    allButton:SetWidth(92)
    allButton:SetScript("OnClick", function()
        local filters = getFilterState()
        for _, def in ipairs(FILTERS) do
            filters[def.key] = true
            if filterChecks[def.key] then filterChecks[def.key]:SetChecked(true) end
        end
        EventLogTab:Refresh(true)
    end)

    local noneButton = Theme:CreateButton(filtersPanel, GP.L["Clear All"])
    noneButton:SetPoint("LEFT", allButton, "RIGHT", 8, 0)
    noneButton:SetWidth(92)
    noneButton:SetScript("OnClick", function()
        local filters = getFilterState()
        for _, def in ipairs(FILTERS) do
            filters[def.key] = false
            if filterChecks[def.key] then filterChecks[def.key]:SetChecked(false) end
        end
        EventLogTab:Refresh(true)
    end)

    local optionsTitle = filtersPanel:CreateFontString(nil, "ARTWORK")
    optionsTitle:SetFontObject(Theme.font.heading)
    optionsTitle:SetPoint("TOPLEFT", allButton, "BOTTOMLEFT", 0, -12)
    optionsTitle:SetText(GP.L["Display Options"])

    local numberedCheck = createCheck(filtersPanel, GP.L["Numbered Lines"], function(value)
        eventLogSettings().numberedLines = value
        EventLogTab:Refresh()
    end)
    numberedCheck:SetPoint("TOPLEFT", optionsTitle, "BOTTOMLEFT", 0, -8)
    numberedCheck:SetChecked(eventLogSettings().numberedLines)

    local colorCheck = createCheck(filtersPanel, GP.L["Category Colors"], function(value)
        eventLogSettings().categoryColors = value
        EventLogTab:Refresh()
    end)
    colorCheck:SetPoint("TOPLEFT", numberedCheck, "BOTTOMLEFT", 0, -2)
    colorCheck:SetChecked(eventLogSettings().categoryColors)

    if GP:IsOfficer() then
        local actionsTitle = filtersPanel:CreateFontString(nil, "ARTWORK")
        actionsTitle:SetFontObject(Theme.font.heading)
        actionsTitle:SetPoint("TOPLEFT", colorCheck, "BOTTOMLEFT", 0, -12)
        actionsTitle:SetText(GP.L["Actions"])

        local exportButton = Theme:CreateButton(filtersPanel, GP.L["Export Visible"])
        exportButton:SetPoint("TOPLEFT", actionsTitle, "BOTTOMLEFT", 0, -8)
        exportButton:SetPoint("RIGHT", filtersPanel, "RIGHT", -Theme.layout.gutter, 0)
        exportButton:SetScript("OnClick", function()
            local exportText = exportVisibleEntries(buildDisplayList())
            StaticPopup_Show(EXPORT_VISIBLE_POPUP, exportText, nil, exportText)
        end)

        local clearButton = Theme:CreateButton(filtersPanel, GP.L["Clear Visible"])
        clearButton:SetPoint("TOPLEFT", exportButton, "BOTTOMLEFT", 0, -8)
        clearButton:SetPoint("RIGHT", filtersPanel, "RIGHT", -Theme.layout.gutter, 0)
        clearButton:SetScript("OnClick", function()
            local ids = {}
            for _, entry in ipairs(buildDisplayList()) do
                if entry.id then table.insert(ids, entry.id) end
            end
            if #ids == 0 then
                GP:Print(GP.L["No log entries selected."])
                return
            end
            StaticPopup_Show(CLEAR_VISIBLE_POPUP, #ids, nil, ids)
        end)

        local rangeTitle = filtersPanel:CreateFontString(nil, "ARTWORK")
        rangeTitle:SetFontObject(Theme.font.heading)
        -- Chain below the action buttons so the range controls move with
        -- the filter list.
        rangeTitle:SetPoint("TOPLEFT", clearButton, "BOTTOMLEFT", 0, -16)
        rangeTitle:SetText(GP.L["Clear Lines"])

        local fromBox = Theme:CreateEditBox(filtersPanel, 52)
        fromBox:SetPoint("LEFT", rangeTitle, "RIGHT", 8, 0)
        fromBox:SetJustifyH("CENTER")
        fromBox:SetText("0")
        if fromBox.SetNumeric then fromBox:SetNumeric(true) end

        local toLabel = filtersPanel:CreateFontString(nil, "ARTWORK")
        toLabel:SetFontObject(Theme.font.body)
        toLabel:SetPoint("LEFT", fromBox, "RIGHT", 10, 0)
        toLabel:SetText(GP.L["To"])

        local toBox = Theme:CreateEditBox(filtersPanel, 52)
        toBox:SetPoint("LEFT", toLabel, "RIGHT", 8, 0)
        toBox:SetJustifyH("CENTER")
        toBox:SetText("0")
        if toBox.SetNumeric then toBox:SetNumeric(true) end

        local confirmButton = Theme:CreateButton(filtersPanel, GP.L["Confirm Clear"])
        confirmButton:SetPoint("TOPLEFT", rangeTitle, "BOTTOMLEFT", 0, -8)
        confirmButton:SetPoint("RIGHT", filtersPanel, "RIGHT", -Theme.layout.gutter, 0)
        confirmButton:SetScript("OnClick", function()
            local ids, err, fromLine, toLine = collectVisibleRangeIDs(fromBox:GetText(), toBox:GetText())
            if not ids then
                GP:Print(err)
                return
            end
            StaticPopup_Show(CLEAR_RANGE_POPUP, string.format("%d-%d", fromLine, toLine), #ids, {
                entryIDs = ids,
                fromBox = fromBox,
                toBox = toBox,
            })
        end)
    end

end

function EventLogTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    buildFilters(frame)

    searchBox = Theme:CreateSearchBox(frame, 200, function() EventLogTab:Refresh(true) end)
    searchBox:SetPoint("TOPLEFT")

    summaryText = frame:CreateFontString(nil, "ARTWORK")
    summaryText:SetFontObject(Theme.font.muted)
    summaryText:SetJustifyH("RIGHT")
    summaryText:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    summaryText:SetPoint("RIGHT", filtersPanel, "LEFT", -12, 0)

    local headerRow = CreateFrame("Frame", nil, frame)
    headerRow:SetHeight(Theme.layout.rowHeight)
    headerRow:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    headerRow:SetPoint("RIGHT", filtersPanel, "LEFT", -Theme.layout.gutter, 0)

    local timeHeader = headerRow:CreateFontString(nil, "ARTWORK")
    timeHeader:SetFontObject(Theme.font.small)
    timeHeader:SetJustifyH("LEFT")
    timeHeader:SetPoint("LEFT", COL.leftPad + COL.lineWidth + COL.gap, 0)
    timeHeader:SetWidth(COL.timeWidth)
    timeHeader:SetText(L["Time"])

    local eventHeader = headerRow:CreateFontString(nil, "ARTWORK")
    eventHeader:SetFontObject(Theme.font.small)
    eventHeader:SetJustifyH("LEFT")
    eventHeader:SetPoint("LEFT", timeHeader, "RIGHT", COL.gap, 0)
    eventHeader:SetPoint("RIGHT", -8, 0)
    eventHeader:SetText(L["Event"])

    local listArea = CreateFrame("Frame", nil, frame)
    listArea:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -4)
    listArea:SetPoint("TOPRIGHT", headerRow, "BOTTOMRIGHT", 0, -4)
    listArea:SetPoint("BOTTOMLEFT")
    listArea:SetPoint("BOTTOMRIGHT", filtersPanel, "BOTTOMLEFT", -Theme.layout.gutter, 0)

    list = GP.UI.ScrollList:New(listArea, ROW_HEIGHT, createLogRow)
    list:SetUpdateRow(updateLogRow)

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua: Roster:Scan calls EventLog:Add once per changed
    local function debouncedRefresh()
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("EventLogTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                EventLogTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    EventLogTab:RegisterMessage("GuildParagon_LogEntryAdded", debouncedRefresh)

    frame.OnSelected = function()
        if refreshDirty then
            refreshDirty = false
            EventLogTab:Refresh()
        end
    end

    self:Refresh()
    return frame
end
