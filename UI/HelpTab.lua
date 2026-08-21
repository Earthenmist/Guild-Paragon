-- Guild Paragon — Help / maintenance tab
--
-- Lightweight diagnostics and command reference. Expensive-ish work such as
-- stored-data size estimation is cached and only recalculated on manual
-- refreshes or occasional throttled automatic refreshes.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.HelpTab = GP.UI.HelpTab or {}
local HelpTab = GP.UI.HelpTab

-- Own AceEvent identity, not GP — see UI/RecruitmentTab.lua's long comment
-- above its own Embed call for the full root-cause explanation: multiple
LibStub("AceEvent-3.0"):Embed(HelpTab)

local frame
local refreshDirty = false
local dbSizeEstimate
local dbSizeDirty = true
local lastDbSizeEstimateAt = 0
local messagesRegistered = false
local commandList
local commandRows = {}
local commandRowsKey
local canShowCommand

local DB_SIZE_AUTO_REFRESH_SECONDS = 30

local COMMANDS = {
    { "/gp", GP.L["Open or close the Guild Paragon window."] },
    { "/guildparagon", GP.L["Alias for /gp."] },
    { "/gp roster", GP.L["Print a compact roster summary to chat."] },
    { "/gp log [count]", GP.L["Print the newest Event Log entries to chat. Defaults to 15."] },
    { "/gp scan", GP.L["Request a roster scan now."] },
    { "/gp perf", GP.L["Print memory, roster scan, CPU, and Event Log pressure stats."] },
    { "/gp minimap", GP.L["Toggle the minimap button. The addon compartment entry stays available."] },
    { "/gp chatpreview Name", GP.L["Preview the guild chat nickname/main hint for a roster member."] },
    { "/gp fulllog", GP.L["Request a one-time full Event Log bootstrap from online Guild Paragon users."] },
    { "/gp cleanuplog", GP.L["Dry-run suspicious Event Log cleanup."], "officer" },
    { "/gp cleanuplog confirm", GP.L["Remove suspicious mass Event Log batches after review."], "officer" },
    { "/gp trimlog", GP.L["Dry-run Event Log retention cleanup for the current guild."], "officer" },
    { "/gp trimlog confirm", GP.L["Keep the newest 50,000 Event Log entries for the current guild."], "officer" },
    { "/gp fixgrmlogdates", GP.L["Dry-run imported GRM Event Log date cleanup."], "officer" },
    { "/gp fixgrmlogdates confirm", GP.L["Move imported GRM dates into Guild Paragon timestamps."], "officer" },
    { "/gp normalizejoindates", GP.L["Dry-run custom-note join date normalization."], "officer" },
    { "/gp normalizejoindates confirm", GP.L["Convert Joined/Rejoined DD-MM-YY custom-note tags to YYYY-MM-DD."], "officer" },
    { "/gp migratejoindates", GP.L["Dry-run one-time pull of legacy custom-note join dates into Guild Paragon's join-date field."], "guildmaster" },
    { "/gp migratejoindates confirm", GP.L["Move legacy custom-note join dates into Guild Paragon's join-date field."], "guildmaster" },
    { "/gp stripjoindatenotes", GP.L["Dry-run removal of Joined:/Rejoined: tags from custom notes."], "guildmaster" },
    { "/gp stripjoindatenotes confirm", GP.L["Remove Joined:/Rejoined: tags from custom notes, keeping the rest of the note."], "guildmaster" },
    { "/gp importgrm", GP.L["Dry-run current-guild import from GRM SavedVariables."], "guildmaster" },
    { "/gp importgrm confirm", GP.L["Wipe Guild Paragon data for this guild and import from GRM."], "guildmaster" },
}

local function formatBytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024 * 1024))
    end
    return string.format("%.1f KB", bytes / 1024)
end

local function estimateValueSize(value, seen)
    local valueType = type(value)
    if valueType == "string" then
        return #value + 4
    elseif valueType == "number" then
        return #tostring(value)
    elseif valueType == "boolean" then
        return value and 4 or 5
    elseif valueType ~= "table" then
        return 4
    end

    if seen[value] then return 0 end
    seen[value] = true

    local size = 2
    for k, v in pairs(value) do
        size = size + estimateValueSize(k, seen) + estimateValueSize(v, seen) + 4
    end
    return size
end

local function estimateDbSize()
    local seen = {}
    return estimateValueSize(GP.db and GP.db.global or {}, seen) + estimateValueSize(GP.db and GP.db.profile or {}, seen)
end

local function markDbSizeDirty()
    dbSizeDirty = true
end

local function getDbSizeEstimate(force)
    local currentTime = time()
    if force or not dbSizeEstimate or (dbSizeDirty and (currentTime - lastDbSizeEstimateAt) >= DB_SIZE_AUTO_REFRESH_SECONDS) then
        dbSizeEstimate = estimateDbSize()
        dbSizeDirty = false
        lastDbSizeEstimateAt = currentTime
    end
    return dbSizeEstimate
end

local function dirtyDbSizeAndRefresh()
    markDbSizeDirty()
    if not frame or not frame:IsShown() then
        refreshDirty = true
        return
    end
    HelpTab:Refresh()
end

local function getCommandRows()
    local key = tostring(GP:IsOfficer() and 1 or 0) .. ":" .. tostring(GP:IsGuildMaster() and 1 or 0)
    if key == commandRowsKey then return commandRows end

    wipe(commandRows)
    for _, row in ipairs(COMMANDS) do
        if canShowCommand(row) then
            commandRows[#commandRows + 1] = {
                command = row[1],
                description = row[2],
            }
        end
    end
    commandRowsKey = key
    return commandRows
end

local function getGuildStats()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local EventLog = GP:GetModule("EventLog")
    if not guildData then return 0, 0, 0, EventLog:GetDisplayableTotalCount(), EventLog:GetRetentionLimit() end

    local active, former = Roster:CountMembers(guildData)
    return active, former, EventLog:CountDisplayable(guildKey), EventLog:GetDisplayableTotalCount(), EventLog:GetRetentionLimit()
end

local function memoryStats()
    if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
    local addonKb = GetAddOnMemoryUsage and GetAddOnMemoryUsage("GuildParagon") or 0
    local luaKb = collectgarbage and collectgarbage("count") or 0
    return addonKb, luaKb
end

function HelpTab:Refresh(forceDbSize)
    if not frame then return end

    local dbSize = getDbSizeEstimate(forceDbSize)
    local addonKb, luaKb = memoryStats()
    local active, former, currentLog, totalLog, retention = getGuildStats()

    frame.dbSize:SetText(string.format(GP.L["Stored data estimate: %s"], formatBytes(dbSize)))
    frame.memory:SetText(string.format(GP.L["Addon memory: %.1f MB   Lua memory: %.1f MB"], addonKb / 1024, luaKb / 1024))
    frame.roster:SetText(string.format(GP.L["Current guild: %d active, %d former, %d log entries."], active, former, currentLog))
    frame.logs:SetText(string.format(GP.L["Account-wide log entries: %d. Retention target: %d newest entries per guild."], totalLog, retention))

    if commandList then
        commandList:SetData(getCommandRows(), false)
    end
end

local function addStatLine(parent, previous)
    local fs = parent:CreateFontString(nil, "ARTWORK")
    fs:SetFontObject(Theme.font.body)
    fs:SetJustifyH("LEFT")
    fs:SetPoint("LEFT")
    fs:SetPoint("RIGHT")
    if previous then
        fs:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -8)
    end
    return fs
end

local function openChatWithCommand(command)
    local editBox = ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend()
    if not editBox then return end

    ChatEdit_ActivateChat(editBox)
    editBox:SetText(command)
    editBox:SetCursorPosition(#command)
end

canShowCommand = function(row)
    local permission = row[3]
    if permission == "officer" then
        return GP:IsOfficer()
    elseif permission == "guildmaster" then
        return GP:IsGuildMaster()
    end
    return true
end

function HelpTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Help"])

    local statsPanel = Theme:CreatePanel(frame, "panel", "border")
    statsPanel:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -14)
    statsPanel:SetPoint("TOPRIGHT")
    statsPanel:SetHeight(150)

    local statsTitle = statsPanel:CreateFontString(nil, "ARTWORK")
    statsTitle:SetFontObject(Theme.font.heading)
    statsTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    statsTitle:SetText(L["Diagnostics"])

    frame.dbSize = addStatLine(statsPanel)
    frame.dbSize:SetPoint("TOPLEFT", statsTitle, "BOTTOMLEFT", 0, -12)

    frame.memory = addStatLine(statsPanel, frame.dbSize)
    frame.roster = addStatLine(statsPanel, frame.memory)
    frame.logs = addStatLine(statsPanel, frame.roster)

    local refreshButton = Theme:CreateButton(statsPanel, L["Refresh"])
    refreshButton:SetPoint("TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter)
    refreshButton:SetScript("OnClick", function() HelpTab:Refresh(true) end)

    local note = statsPanel:CreateFontString(nil, "ARTWORK")
    note:SetFontObject(Theme.font.small)
    note:SetJustifyH("LEFT")
    note:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    note:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    note:SetText(L["Stored data size is an estimate; WoW does not expose the exact SavedVariables file size while running."])

    local commandsPanel = Theme:CreatePanel(frame, "panel", "border")
    commandsPanel:SetPoint("TOPLEFT", statsPanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    commandsPanel:SetPoint("BOTTOMRIGHT")

    local cmdTitle = commandsPanel:CreateFontString(nil, "ARTWORK")
    cmdTitle:SetFontObject(Theme.font.heading)
    cmdTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    cmdTitle:SetText(L["Slash Commands"])

    local cmdHint = commandsPanel:CreateFontString(nil, "ARTWORK")
    cmdHint:SetFontObject(Theme.font.small)
    cmdHint:SetPoint("TOPLEFT", cmdTitle, "BOTTOMLEFT", 0, -4)
    cmdHint:SetText(L["Click a command to load it into chat. Press Enter there to run it."])

    local listArea = CreateFrame("Frame", nil, commandsPanel)
    listArea:SetPoint("TOPLEFT", cmdHint, "BOTTOMLEFT", 0, -12)
    listArea:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)

    commandList = GP.UI.ScrollList:New(listArea, 26, function(rowParent)
        local row = CreateFrame("Button", nil, rowParent)
        row:EnableMouse(true)

        local cmd = row:CreateFontString(nil, "ARTWORK")
        cmd:SetFontObject(Theme.font.body)
        cmd:SetJustifyH("LEFT")
        cmd:SetPoint("LEFT")
        cmd:SetWidth(210)
        cmd:SetTextColor(unpack(Theme.color.accent))
        row.cmd = cmd

        local desc = row:CreateFontString(nil, "ARTWORK")
        desc:SetFontObject(Theme.font.muted)
        desc:SetJustifyH("LEFT")
        desc:SetPoint("LEFT", cmd, "RIGHT", 18, 0)
        desc:SetPoint("RIGHT")
        desc:SetWordWrap(false)
        row.desc = desc

        row:SetScript("OnClick", function(self)
            if self.command then openChatWithCommand(self.command) end
        end)
        row:SetScript("OnEnter", function(self)
            self.cmd:SetTextColor(unpack(Theme.color.textPrimary))
        end)
        row:SetScript("OnLeave", function(self)
            self.cmd:SetTextColor(unpack(Theme.color.accent))
        end)

        return row
    end)
    commandList:SetUpdateRow(function(row, item)
        row.command = item.command
        row.cmd:SetText(item.command)
        row.desc:SetText(item.description)
    end)

    if not messagesRegistered then
        -- Debounced (GP:DebounceCall) — see the matching comment in
        -- RosterTab.lua: a Guild Sync full-state apply can fire hundreds
        -- of these in one burst, and dirtyDbSizeAndRefresh redraws this
        -- tab that often in a row tripped WoW's "script ran too long"
        -- watchdog in live testing.
        local function debouncedDirtyRefresh() GP:DebounceCall("HelpTab:dirtyDbSizeAndRefresh", dirtyDbSizeAndRefresh) end
        HelpTab:RegisterMessage("GuildParagon_RosterScanned", debouncedDirtyRefresh)
        HelpTab:RegisterMessage("GuildParagon_LogEntryAdded", debouncedDirtyRefresh)
        HelpTab:RegisterMessage("GuildParagon_AltsChanged", debouncedDirtyRefresh)
        HelpTab:RegisterMessage("GuildParagon_NicknamesChanged", debouncedDirtyRefresh)
        HelpTab:RegisterMessage("GuildParagon_CustomNotesChanged", debouncedDirtyRefresh)
        HelpTab:RegisterMessage("GuildParagon_MacroRuleChanged", debouncedDirtyRefresh)
        HelpTab:RegisterMessage("GuildParagon_MacroIgnoresChanged", debouncedDirtyRefresh)
        messagesRegistered = true
    end

    frame.OnSelected = function()
        if refreshDirty then
            refreshDirty = false
            HelpTab:Refresh()
        end
    end

    self:Refresh(true)
    return frame
end
