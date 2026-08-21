-- Guild Paragon - Exports view
--
-- On-demand TSV exports for the data Guild Paragon already tracks/imports.
-- Nothing is precomputed or cached between clicks, keeping the feature quiet
-- for CPU/memory until the user actually asks for an export.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.ExportStatsTab = GP.UI.ExportStatsTab or {}
local ExportStatsTab = GP.UI.ExportStatsTab

-- Own AceEvent identity, not GP — see UI/RecruitmentTab.lua's long comment
-- above its own Embed call for the full root-cause explanation: multiple
LibStub("AceEvent-3.0"):Embed(ExportStatsTab)

local frame
local refreshDirty = false
local LOG_EXPORT_CHUNK_SIZE = 500

local EXPORT_FIELDS = {
    "status", "name", "rank", "rankIndex", "level", "class", "race", "sex",
    "faction", "realm", "online", "zone", "lastOnline", "dateJoined",
    "promoted", "birthday", "guildRep", "mythicScore", "nickname",
    "altOf", "alts", "isMain", "note", "officerNote", "customNote",
    "customOfficerNote", "guid",
}

local function getGuildKey()
    local Roster = GP:GetModule("Roster")
    return Roster.currentGuildKey or Roster:GetGuildKey()
end

local function countTable(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function cleanCell(value)
    if value == nil then return "" end
    value = tostring(value)
    value = value:gsub("[\r\n\t]", " ")
    return value
end

local function line(fields)
    local out = {}
    for i, value in ipairs(fields) do
        out[i] = cleanCell(value)
    end
    return table.concat(out, "\t")
end

local function formatDate(ts)
    return type(ts) == "number" and date("%Y-%m-%d", ts) or ""
end

local function formatBirthday(player)
    local info = player and player.birthdayInfo
    if type(info) == "table" and type(info.date) == "table" and info.date[1] and info.date[2] then
        return string.format("%02d-%02d", info.date[1], info.date[2])
    end
    return ""
end

local function formatLastOnline(player)
    if not player then return "" end
    if player.online then return GP.L["Online"] end

    local t = player.lastOnlineTime
    if type(t) ~= "table" then return "" end

    local years, months, days, hours = tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0, tonumber(t[4]) or 0
    local parts = {}
    if years > 0 then table.insert(parts, years .. "y") end
    if months > 0 then table.insert(parts, months .. "mo") end
    if days > 0 then table.insert(parts, days .. "d") end
    if years == 0 and months == 0 and hours > 0 then table.insert(parts, hours .. "h") end
    return table.concat(parts, " ")
end

local function playerByGUID(guildData, guid)
    return guildData and (guildData.roster[guid] or guildData.formerMembers[guid])
end

local function sortedPlayers(guildData, source)
    local out = {}
    for guid, player in pairs(source or {}) do
        table.insert(out, { guid = guid, player = player })
    end
    table.sort(out, function(a, b)
        return (a.player.name or ""):lower() < (b.player.name or ""):lower()
    end)
    return out
end

local function altNames(guildData, guildKey, guid)
    local Alts = GP:GetModule("Alts")
    local names = {}
    for _, altGUID in ipairs(Alts:GetAlts(guildKey, guid)) do
        local alt = playerByGUID(guildData, altGUID)
        table.insert(names, alt and alt.name or altGUID)
    end
    table.sort(names)
    return table.concat(names, ", ")
end

local function exportPlayer(guildData, guildKey, guid, player, status)
    local Alts = GP:GetModule("Alts")
    local Nicknames = GP:GetModule("Nicknames")
    local CustomNotes = GP:GetModule("CustomNotes")
    local canViewOfficer = CustomNotes:CanAccessOfficerNotes()
    local customNote = CustomNotes:Get(guildKey, guid)
    local customOfficerNote = canViewOfficer and CustomNotes:GetOfficer(guildKey, guid) or ""
    local mainGUID = Alts:GetMain(guildKey, guid)
    local main = mainGUID and playerByGUID(guildData, mainGUID)

    return line({
        status,
        player.name,
        player.rankName,
        player.rankIndex,
        player.level,
        player.class,
        player.race,
        player.sex,
        player.faction,
        player.realmName,
        player.online and GP.L["Online"] or GP.L["Offline"],
        player.zone,
        formatLastOnline(player),
        formatDate(player.firstSeen),
        formatDate((player.rankHistory and player.rankHistory[#player.rankHistory] or {}).ts),
        formatBirthday(player),
        player.guildRep,
        player.mythicScore,
        Nicknames:Get(guildKey, guid),
        main and main.name or "",
        altNames(guildData, guildKey, guid),
        Alts:IsMain(guildKey, guid) and "yes" or "",
        player.note,
        canViewOfficer and player.officerNote or "",
        customNote,
        customOfficerNote,
        guid,
    })
end

local function buildRosterExport(includeActive, includeFormer)
    local guildKey = getGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return GP.L["No roster data yet — try /gp scan."] end

    local lines = { line(EXPORT_FIELDS) }
    if includeActive then
        for _, row in ipairs(sortedPlayers(guildData, guildData.roster)) do
            table.insert(lines, exportPlayer(guildData, guildKey, row.guid, row.player, "active"))
        end
    end
    if includeFormer then
        for _, row in ipairs(sortedPlayers(guildData, guildData.formerMembers)) do
            table.insert(lines, exportPlayer(guildData, guildKey, row.guid, row.player, "former"))
        end
    end
    return table.concat(lines, "\n")
end

local function buildLogExportChunk(chunkIndex)
    local guildKey = getGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local log = guildKey and GP:GetModule("EventLog"):GetLog(guildKey)
    if not guildData or not log then return GP.L["No log data yet — try /gp scan."] end

    local EventLog = GP:GetModule("EventLog")
    local lines = { line({ "time", "type", "name", "guid", "event", "id" }) }
    local total = #log
    local totalChunks = math.max(1, math.ceil(total / LOG_EXPORT_CHUNK_SIZE))
    chunkIndex = math.min(math.max(tonumber(chunkIndex) or 1, 1), totalChunks)
    local startIndex = total > 0 and (((chunkIndex - 1) * LOG_EXPORT_CHUNK_SIZE) + 1) or 0
    local endIndex = math.min(total, chunkIndex * LOG_EXPORT_CHUNK_SIZE)

    if total > 0 then
        for i = startIndex, endIndex do
            local entry = log[i]
            table.insert(lines, line({
                entry.ts and date("%Y-%m-%d %H:%M:%S", entry.ts) or "",
                entry.type,
                entry.name,
                entry.guid,
                EventLog:Render(entry),
                entry.id,
            }))
        end
    end

    return table.concat(lines, "\n"), total, chunkIndex, totalChunks, startIndex, endIndex
end

local function buildStats(guildData, guildKey)
    local active, former = GP:GetModule("Roster"):CountMembers(guildData)
    local online, mains, altLinks = 0, 0, 0
    for _, player in pairs(guildData.roster or {}) do
        if player.online then online = online + 1 end
    end
    local alts, _, mainFlags = GP:GetModule("Alts"):GetAllForSync(guildKey)
    altLinks = countTable(alts)
    mains = countTable(mainFlags)

    local nicks = GP:GetModule("Nicknames"):GetAllForSync(guildKey)
    local customNotes, _, customOfficerNotes = GP:GetModule("CustomNotes"):GetAllForSync(guildKey)
    local log = GP:GetModule("EventLog"):GetLog(guildKey)

    return string.format(GP.L["Active: %d   Former: %d   Online: %d   Alts: %d   Mains: %d   Nicknames: %d   Custom Notes: %d   Officer Notes: %d   Log: %d"],
        active, former, online, altLinks, mains, countTable(nicks), countTable(customNotes), countTable(customOfficerNotes), log and #log or 0)
end

local function setChunkButtonsVisible(visible)
    if not frame then return end
    if frame.previousChunkButton then frame.previousChunkButton:SetShown(visible) end
    if frame.nextChunkButton then frame.nextChunkButton:SetShown(visible) end
end

local function frameVisible()
    return frame and frame.IsVisible and frame:IsVisible()
end

local function setOutput(text, statusText, keepLogState)
    if frame and not keepLogState then
        frame.logExportChunk = nil
        frame.logExportChunks = nil
        setChunkButtonsVisible(false)
    end

    frame.output:SetText(text or "")
    frame.output:HighlightText(0, 0)
    frame.countText:SetText(statusText or string.format(GP.L["%d character(s) ready to copy"], #(text or "")))
end

local function clearOutput()
    if not frame then return end
    frame.logExportChunk = nil
    frame.logExportChunks = nil
    setChunkButtonsVisible(false)
    frame.output:ClearFocus()
    frame.output:SetText("")
    frame.output:HighlightText(0, 0)
    frame.countText:SetText(GP.L["Choose an export."])
end

local function showLogExportChunk(chunkIndex)
    local text, total, current, chunks, first, last = buildLogExportChunk(chunkIndex)
    frame.logExportChunk = current or 1
    frame.logExportChunks = chunks or 1
    setChunkButtonsVisible((chunks or 1) > 1)
    local status = string.format(GP.L["Event Log export chunk %d of %d (%d-%d of %d entries, %d character(s) ready to copy)"],
        current or 1, chunks or 1, first or 0, last or 0, total or 0, #(text or ""))
    setOutput(text, status, true)
end

function ExportStatsTab:Refresh()
    if not frame then return end

    local guildKey = getGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if guildData then
        frame.statsText:SetText(buildStats(guildData, guildKey))
    else
        frame.statsText:SetText(GP.L["No roster data yet — try /gp scan."])
    end
end

function ExportStatsTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Exports"])

    local statsText = frame:CreateFontString(nil, "ARTWORK")
    statsText:SetFontObject(Theme.font.muted)
    statsText:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    statsText:SetJustifyH("LEFT")
    statsText:SetPoint("RIGHT")
    frame.statsText = statsText

    local activeButton = Theme:CreateButton(frame, L["Active Roster"])
    activeButton:SetPoint("TOPLEFT", statsText, "BOTTOMLEFT", 0, -16)
    activeButton:SetScript("OnClick", function() setOutput(buildRosterExport(true, false)) end)

    local formerButton = Theme:CreateButton(frame, L["Former Members"])
    formerButton:SetPoint("LEFT", activeButton, "RIGHT", 8, 0)
    formerButton:SetScript("OnClick", function() setOutput(buildRosterExport(false, true)) end)

    local allButton = Theme:CreateButton(frame, L["Active + Former"])
    allButton:SetPoint("LEFT", formerButton, "RIGHT", 8, 0)
    allButton:SetScript("OnClick", function() setOutput(buildRosterExport(true, true)) end)

    local logButton = Theme:CreateButton(frame, L["Event Log Export"])
    logButton:SetPoint("LEFT", allButton, "RIGHT", 8, 0)
    logButton:SetScript("OnClick", function() showLogExportChunk(1) end)

    local selectButton = Theme:CreateButton(frame, L["Select All"])
    selectButton:SetPoint("LEFT", logButton, "RIGHT", 8, 0)
    selectButton:SetScript("OnClick", function()
        frame.output:SetFocus()
        frame.output:HighlightText(0, #(frame.output:GetText() or ""))
    end)

    local previousChunkButton = Theme:CreateButton(frame, L["Previous Chunk"])
    previousChunkButton:SetPoint("LEFT", selectButton, "RIGHT", 8, 0)
    previousChunkButton:SetScript("OnClick", function()
        showLogExportChunk((frame.logExportChunk or 1) - 1)
    end)
    previousChunkButton:Hide()
    frame.previousChunkButton = previousChunkButton

    local nextChunkButton = Theme:CreateButton(frame, L["Next Chunk"])
    nextChunkButton:SetPoint("LEFT", previousChunkButton, "RIGHT", 8, 0)
    nextChunkButton:SetScript("OnClick", function()
        showLogExportChunk((frame.logExportChunk or 1) + 1)
    end)
    nextChunkButton:Hide()
    frame.nextChunkButton = nextChunkButton

    local countText = frame:CreateFontString(nil, "ARTWORK")
    countText:SetFontObject(Theme.font.small)
    countText:SetPoint("TOPLEFT", activeButton, "BOTTOMLEFT", 0, -8)
    countText:SetText(L["Choose an export."])
    frame.countText = countText

    local outputPanel = Theme:CreatePanel(frame, "panel", "border")
    outputPanel:SetPoint("TOPLEFT", countText, "BOTTOMLEFT", 0, -8)
    outputPanel:SetPoint("BOTTOMRIGHT")

    local scroll = CreateFrame("ScrollFrame", nil, outputPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)

    local output = CreateFrame("EditBox", nil, scroll)
    output:SetMultiLine(true)
    output:SetAutoFocus(false)
    output:SetFontObject(Theme.font.body)
    output:SetWidth(680)
    output:SetHeight(420)
    output:SetTextInsets(4, 4, 4, 4)
    output:SetScript("OnEscapePressed", output.ClearFocus)
    output:SetScript("OnTextChanged", function(self)
        local lines = self:GetNumLines() or 1
        self:SetHeight(math.min(9000, math.max(420, lines * 14 + 24)))
    end)
    scroll:SetScrollChild(output)
    frame.output = output

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua: both of these messages can fire many times in a row
    -- from one roster scan or Guild Sync full-state apply, and Refresh()
    -- recomputes stats over the whole roster/log each time. Collapse the
    -- burst to one refresh on the next frame instead.
    local function debouncedRefresh()
        if not frameVisible() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("ExportStatsTab:Refresh", function()
            if frameVisible() then
                refreshDirty = false
                ExportStatsTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    ExportStatsTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefresh)
    ExportStatsTab:RegisterMessage("GuildParagon_LogEntryAdded", debouncedRefresh)

    frame.OnSelected = function()
        refreshDirty = false
        clearOutput()
        ExportStatsTab:Refresh()
    end

    self:Refresh()
    return frame
end
