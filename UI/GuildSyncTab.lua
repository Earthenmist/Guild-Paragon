-- Guild Paragon — Guild Sync tab
-- Replaces the "sync" placeholder tab (Core/Core.lua) now that Modules/
local _, GP = ...
local Theme = GP.UI.Theme
local ScrollList = GP.UI.ScrollList

GP.UI.GuildSyncTab = GP.UI.GuildSyncTab or {}
local GuildSyncTab = GP.UI.GuildSyncTab
local REPLACE_EVENT_LOG_POPUP = "GUILDPARAGON_REPLACE_EVENT_LOG_SYNC"
local PEER_AGE_REFRESH_SECONDS = 30

-- Own AceEvent identity so this tab's message handlers do not overwrite
-- handlers registered by other UI tables.
LibStub("AceEvent-3.0"):Embed(GuildSyncTab)

local function formatWhen(ts)
    if not ts then return GP.L["never"] end
    return date("%H:%M:%S", ts)
end

local function formatDateTime(ts)
    if not ts then return GP.L["never"] end
    return date("%Y-%m-%d %H:%M", ts)
end

local function rowText(label, value)
    return string.format("%s: %s", label, value or GP.L["never"])
end

local function compactLine(label, value)
    return string.format("%s: %s", label, value or GP.L["never"])
end

local function compactName(name)
    if not name or name == "" then return GP.L["Unknown"] end
    return tostring(name):match("^([^-]+)") or tostring(name)
end

-- Per-peer transfer summary. Keep every category visible, split over short
-- lines so the row stays readable at the normal Guild Sync panel width.
local function countLines(counts)
    counts = counts or {}
    return {
        string.format("Identity: Alt/Main %d, Former %d, Nick %d",
            counts.altsMains or 0, counts.formerMembers or 0, counts.nicknames or 0),
        string.format("Notes/Dates: General %d, Officer %d, Birthday %d, Join %d",
            counts.notesGeneral or 0, counts.notesOfficer or 0, counts.birthdays or 0, counts.joinDates or 0),
        string.format("Tools: Rules %d, Ignores %d, Ban %d, Recruit %d, Log %d",
            counts.macroRules or 0, counts.macroIgnores or 0, counts.bans or 0,
            (counts.recruitmentBlacklist or 0) + (counts.recruitmentItems or 0), counts.log or 0),
    }
end

local DETAIL_LABELS = {
    alt = "Alt linked",
    altclear = "Alt cleared",
    main = "Main marked",
    mainclear = "Main cleared",
    nick = "Nickname",
    customnote = "Custom note",
    joindate = "Join date",
    birthday = "Birthday",
    formermember = "Former member",
    macrorule = "Macro rule",
    macroignore = "Macro ignore",
    ban = "Ban record",
    recruitmentsettings = "Recruitment settings",
    recruitmentblacklist = "Do-not-invite",
    ping = "Presence ping",
    pong = "Presence reply",
    presence = "Presence",
    ["presence reply"] = "Presence reply",
    ["startup"] = "Startup presence",
    ["startup retry"] = "Startup presence retry",
    full = "Full state",
    fulllogrequest = "Full log request",
    fulllogclaim = "Full log claim",
    fulllogchunk = "Full log chunk",
    ["Full log replace complete"] = "Full log replace complete",
}

local function detailText(details)
    if not details or details == "" then return "" end
    return DETAIL_LABELS[details] or details
end

local function setTextColor(fontString, color)
    fontString:SetTextColor(unpack(color))
end

StaticPopupDialogs[REPLACE_EVENT_LOG_POPUP] = StaticPopupDialogs[REPLACE_EVENT_LOG_POPUP] or {
    text = GP.L["Replace your local Event Log with a full copy from the best online guild source?\n\nLarge logs can take 30 minutes or longer to complete. Event Log entries do not sync automatically."],
    button1 = GP.L["Replace"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local ok, err = GP:GetModule("GuildSync"):RequestFullLogReplace()
        if ok then
            GP:Print(GP.L["Requesting a full Event Log replacement from the best online guild source..."])
        else
            GP:Print(err or GP.L["No suitable Event Log sync source is online."])
        end
        if data and data.frame then GuildSyncTab:RefreshStatus(data.frame) end
    end,
}

local function createPeerRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("TOPLEFT", 4, -6)
    row.name:SetWidth(140)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.status = row:CreateFontString(nil, "ARTWORK")
    row.status:SetFontObject(Theme.font.body)
    row.status:SetPoint("TOPLEFT", row.name, "TOPRIGHT", 8, 0)
    row.status:SetWidth(135)
    row.status:SetJustifyH("LEFT")
    row.status:SetWordWrap(false)

    row.details = row:CreateFontString(nil, "ARTWORK")
    row.details:SetFontObject(Theme.font.small)
    row.details:SetPoint("TOPLEFT", row.status, "TOPRIGHT", 8, -1)
    row.details:SetPoint("RIGHT", -80, 0)
    row.details:SetJustifyH("LEFT")
    row.details:SetWordWrap(false)

    row.time = row:CreateFontString(nil, "ARTWORK")
    row.time:SetFontObject(Theme.font.muted)
    row.time:SetPoint("TOPRIGHT", -8, -6)
    row.time:SetWidth(64)
    row.time:SetJustifyH("RIGHT")
    row.time:SetWordWrap(false)

    row.countLine1 = row:CreateFontString(nil, "ARTWORK")
    row.countLine1:SetFontObject(Theme.font.small)
    row.countLine1:SetPoint("TOPLEFT", 4, -23)
    row.countLine1:SetPoint("RIGHT", -8, 0)
    row.countLine1:SetJustifyH("LEFT")
    row.countLine1:SetWordWrap(false)

    row.countLine2 = row:CreateFontString(nil, "ARTWORK")
    row.countLine2:SetFontObject(Theme.font.small)
    row.countLine2:SetPoint("TOPLEFT", row.countLine1, "BOTTOMLEFT", 0, -2)
    row.countLine2:SetPoint("RIGHT", -8, 0)
    row.countLine2:SetJustifyH("LEFT")
    row.countLine2:SetWordWrap(false)

    row.countLine3 = row:CreateFontString(nil, "ARTWORK")
    row.countLine3:SetFontObject(Theme.font.small)
    row.countLine3:SetPoint("TOPLEFT", row.countLine2, "BOTTOMLEFT", 0, -2)
    row.countLine3:SetPoint("RIGHT", -8, 0)
    row.countLine3:SetJustifyH("LEFT")
    row.countLine3:SetWordWrap(false)

    row:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(Theme.color.panelRaised)) end)
    row:SetScript("OnLeave", function(self) self:SetBackdropColor(0, 0, 0, 0) end)
    return row
end

local function updatePeerRow(row, peer)
    row.name:SetText(peer.name or "?")
    row.status:SetText(peer.displayStatus or peer.status or GP.L["Unknown"])
    row.time:SetText(formatWhen(peer.lastSeen))
    local lines = countLines(peer.counts)
    row.countLine1:SetText(lines[1])
    row.countLine2:SetText(lines[2])
    row.countLine3:SetText(lines[3])
    row.details:SetText(detailText(peer.details))

    local status = peer.status or ""
    if peer.isProbablyOffline then
        setTextColor(row.status, Theme.color.textSecondary)
    elseif status:find("complete") or status:find("received") or status:find("update") or status:find("sent") or status == "Online" then
        setTextColor(row.status, Theme.color.success)
    elseif status:find("requested") or status:find("claimed") or status:find("Sending") or status:find("Receiving") or status == "Heard" then
        setTextColor(row.status, Theme.color.info)
    else
        setTextColor(row.status, Theme.color.textPrimary)
    end
end

function GuildSyncTab:Build(parent)
    local L = GP.L
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Guild Sync"])

    local info = frame:CreateFontString(nil, "ARTWORK")
    info:SetFontObject(Theme.font.muted)
    info:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    info:SetJustifyH("LEFT")
    info:SetWidth(700)
    info:SetText(L["Guild data syncs with online Guild Paragon users. Officer-only data only syncs for eligible clients. Event Log entries are manual replacement only."])

    local summaryPanel = Theme:CreatePanel(frame, "panel", "border")
    summaryPanel:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -18)
    summaryPanel:SetSize(500, 292)

    local statusHeading = summaryPanel:CreateFontString(nil, "ARTWORK")
    statusHeading:SetFontObject(Theme.font.heading)
    statusHeading:SetPoint("TOPLEFT", 12, -12)
    statusHeading:SetText(L["Sync status"])

    local statusText = summaryPanel:CreateFontString(nil, "ARTWORK")
    statusText:SetFontObject(Theme.font.body)
    statusText:SetPoint("TOPLEFT", statusHeading, "BOTTOMLEFT", 0, -8)
    statusText:SetPoint("BOTTOMRIGHT", summaryPanel, "BOTTOMRIGHT", -12, 48)
    statusText:SetJustifyH("LEFT")
    statusText:SetWidth(470)
    frame.statusText = statusText

    local syncButton = Theme:CreateButton(summaryPanel, L["Sync Now"])
    syncButton:SetPoint("BOTTOMLEFT", 12, 12)
    syncButton:SetScript("OnClick", function()
        if GP:GetModule("GuildSync"):RequestSync() then
            GP:Print(L["Requesting the latest alt/main, nickname, custom note, and officer-only macro/ban data from any online guild members running Guild Paragon..."])
        else
            GP:Print(L["No roster data yet — try /gp scan."])
        end
        GuildSyncTab:RefreshStatus(frame)
    end)

    local fullLogButton = Theme:CreateButton(summaryPanel, L["Replace Event Log"])
    fullLogButton:SetPoint("LEFT", syncButton, "RIGHT", 8, 0)
    fullLogButton:SetScript("OnClick", function()
        StaticPopup_Show(REPLACE_EVENT_LOG_POPUP, nil, nil, { frame = frame })
    end)

    local categoriesPanel = Theme:CreatePanel(frame, "panel", "border")
    categoriesPanel:SetPoint("TOPLEFT", summaryPanel, "BOTTOMLEFT", 0, -10)
    categoriesPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT")
    categoriesPanel:SetWidth(500)

    local categoriesHeading = categoriesPanel:CreateFontString(nil, "ARTWORK")
    categoriesHeading:SetFontObject(Theme.font.heading)
    categoriesHeading:SetPoint("TOPLEFT", 12, -12)
    categoriesHeading:SetText(L["Sync categories"])

    local categoriesText = categoriesPanel:CreateFontString(nil, "ARTWORK")
    categoriesText:SetFontObject(Theme.font.body)
    categoriesText:SetPoint("TOPLEFT", categoriesHeading, "BOTTOMLEFT", 0, -8)
    categoriesText:SetPoint("BOTTOMRIGHT", categoriesPanel, "BOTTOMRIGHT", -12, 42)
    categoriesText:SetJustifyH("LEFT")
    categoriesText:SetWidth(470)
    frame.categoriesText = categoriesText

    local noteText = categoriesPanel:CreateFontString(nil, "ARTWORK")
    noteText:SetFontObject(Theme.font.small)
    noteText:SetPoint("BOTTOMLEFT", 12, 12)
    noteText:SetJustifyH("LEFT")
    noteText:SetWidth(470)
    noteText:SetText(L["Event Log replacement is manual and large logs can take 30 minutes or longer."])

    local peerPanel = Theme:CreatePanel(frame, "panel", "border")
    peerPanel:SetPoint("TOPLEFT", summaryPanel, "TOPRIGHT", 12, 0)
    peerPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT")

    local peerHeading = peerPanel:CreateFontString(nil, "ARTWORK")
    peerHeading:SetFontObject(Theme.font.heading)
    peerHeading:SetPoint("TOPLEFT", 12, -12)
    peerHeading:SetText(L["Peer progress"])

    local peerHeader = CreateFrame("Frame", nil, peerPanel)
    peerHeader:SetPoint("TOPLEFT", peerHeading, "BOTTOMLEFT", 0, -10)
    peerHeader:SetPoint("RIGHT", -10, 0)
    peerHeader:SetHeight(14)

    local peerNameHeader = peerHeader:CreateFontString(nil, "ARTWORK")
    peerNameHeader:SetFontObject(Theme.font.small)
    peerNameHeader:SetPoint("TOPLEFT", 4, 0)
    peerNameHeader:SetWidth(140)
    peerNameHeader:SetJustifyH("LEFT")
    peerNameHeader:SetTextColor(unpack(Theme.color.textSecondary))
    peerNameHeader:SetText(L["Peer"])

    local peerStatusHeader = peerHeader:CreateFontString(nil, "ARTWORK")
    peerStatusHeader:SetFontObject(Theme.font.small)
    peerStatusHeader:SetPoint("TOPLEFT", peerNameHeader, "TOPRIGHT", 8, 0)
    peerStatusHeader:SetWidth(135)
    peerStatusHeader:SetJustifyH("LEFT")
    peerStatusHeader:SetTextColor(unpack(Theme.color.textSecondary))
    peerStatusHeader:SetText(L["Status"])

    local peerProgressHeader = peerHeader:CreateFontString(nil, "ARTWORK")
    peerProgressHeader:SetFontObject(Theme.font.small)
    peerProgressHeader:SetPoint("TOPLEFT", peerStatusHeader, "TOPRIGHT", 8, 0)
    peerProgressHeader:SetPoint("RIGHT", -80, 0)
    peerProgressHeader:SetJustifyH("LEFT")
    peerProgressHeader:SetTextColor(unpack(Theme.color.textSecondary))
    peerProgressHeader:SetText(L["Latest activity"])

    local peerLastHeader = peerHeader:CreateFontString(nil, "ARTWORK")
    peerLastHeader:SetFontObject(Theme.font.small)
    peerLastHeader:SetPoint("TOPRIGHT", -8, 0)
    peerLastHeader:SetWidth(64)
    peerLastHeader:SetJustifyH("RIGHT")
    peerLastHeader:SetTextColor(unpack(Theme.color.textSecondary))
    peerLastHeader:SetText(L["Last"])

    local peerListFrame = CreateFrame("Frame", nil, peerPanel)
    peerListFrame:SetPoint("TOPLEFT", peerHeader, "BOTTOMLEFT", 0, -6)
    peerListFrame:SetPoint("BOTTOMRIGHT", -10, 12)
    local peerList = ScrollList:New(peerListFrame, 78, createPeerRow)
    peerList:SetUpdateRow(updatePeerRow)
    frame.peerList = peerList

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua. GuildParagon_SyncStatusChanged in particular fires on
    local statusDirty = false
    local function debouncedRefreshStatus()
        if not frame:IsShown() then
            statusDirty = true
            return
        end
        GP:DebounceCall("GuildSyncTab:RefreshStatus", function()
            if frame:IsShown() then
                statusDirty = false
                GuildSyncTab:RefreshStatus(frame)
            else
                statusDirty = true
            end
        end)
    end
    GuildSyncTab:RegisterMessage("GuildParagon_SyncStatusChanged", debouncedRefreshStatus)
    GuildSyncTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefreshStatus)
    GuildSyncTab:RegisterMessage("GuildParagon_MacroRuleChanged", debouncedRefreshStatus)
    GuildSyncTab:RegisterMessage("GuildParagon_MacroIgnoresChanged", debouncedRefreshStatus)
    GuildSyncTab:RegisterMessage("GuildParagon_BanListChanged", debouncedRefreshStatus)
    GuildSyncTab:RegisterMessage("GuildParagon_RecruitmentChanged", debouncedRefreshStatus)
    GuildSyncTab:RegisterMessage("GuildParagon_RecruitmentSettingsChanged", debouncedRefreshStatus)

    frame.peerAgeTicker = C_Timer.NewTicker(PEER_AGE_REFRESH_SECONDS, function()
        if frame:IsShown() then GuildSyncTab:RefreshStatus(frame) end
    end)
    frame:SetScript("OnHide", function()
        if frame.peerAgeTicker then
            frame.peerAgeTicker:Cancel()
            frame.peerAgeTicker = nil
        end
    end)
    frame:SetScript("OnShow", function()
        if not frame.peerAgeTicker then
            frame.peerAgeTicker = C_Timer.NewTicker(PEER_AGE_REFRESH_SECONDS, function()
                if frame:IsShown() then GuildSyncTab:RefreshStatus(frame) end
            end)
        end
        if statusDirty then statusDirty = false end
        GuildSyncTab:RefreshStatus(frame)
    end)

    self:RefreshStatus(frame)
    return frame
end

function GuildSyncTab:RefreshStatus(frame)
    local L = GP.L
    local Roster = GP:GetModule("Roster")
    local GuildSync = GP:GetModule("GuildSync")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()

    if not guildKey then
        frame.statusText:SetText(L["No roster data yet — try /gp scan."])
        if frame.categoriesText then frame.categoriesText:SetText("") end
        if frame.peerList then frame.peerList:SetData({}, true) end
        return
    end

    -- Current local totals per staged category — always a fresh read of
    -- this client's own SavedVariables state, never accumulated, so it
    -- can't drift or balloon the way peer-reported totals used to (see
    -- GuildSync.lua's RecordPeer/ComputeCategoryProgress comments).
    local localCounts = GuildSync:GetLocalCounts(guildKey)
    local logCount = GP:GetModule("EventLog"):CountDisplayable(guildKey)
    local guildData = GP.db.global.guilds[guildKey]
    local bootstrapStatus
    if guildData and guildData.fullLogReplaceCompletedAt then
        bootstrapStatus = string.format(L["replaced %s from %s — imported %d of %d record(s)"],
            date("%Y-%m-%d %H:%M", guildData.fullLogReplaceCompletedAt),
            guildData.fullLogReplaceFrom or L["Unknown"],
            guildData.fullLogReplaceApplied or 0,
            guildData.fullLogReplaceConsidered or 0)
    elseif guildData and guildData.fullLogBootstrapCompleted then
        bootstrapStatus = string.format(L["complete %s from %s — merged %d of %d record(s)"],
            guildData.fullLogBootstrapCompletedAt and date("%Y-%m-%d %H:%M", guildData.fullLogBootstrapCompletedAt) or L["never"],
            guildData.fullLogBootstrapFrom or L["Unknown"],
            guildData.fullLogBootstrapApplied or 0,
            guildData.fullLogBootstrapConsidered or 0)
    elseif GuildSync.fullLogBootstrap and GuildSync.fullLogBootstrap.requestID then
        local state = GuildSync.fullLogBootstrap
        if state.timedOut then
            bootstrapStatus = string.format(L["timed out — %d/%d chunk(s), merged %d of %d record(s)"],
                state.received or 0, state.total or 0, state.applied or 0, state.considered or 0)
        else
            bootstrapStatus = string.format(L["in progress — %d/%d chunk(s), merged %d of %d record(s)"],
                state.received or 0, state.total or 0, state.applied or 0, state.considered or 0)
        end
    elseif GuildSync.lastIgnoredReason == L["No suitable Event Log sync source responded."] then
        bootstrapStatus = L["no suitable source responded"]
    else
        bootstrapStatus = L["manual only — use Replace Event Log"]
    end

    local syncMeta = (guildData and guildData.syncMeta) or {}
    local startupStatus
    if GuildSync.lastStartupFullSyncRequestedAt then
        startupStatus = string.format(L["requested %s"], formatWhen(GuildSync.lastStartupFullSyncRequestedAt))
    elseif GuildSync.lastStartupSyncSkippedAt then
        startupStatus = string.format(L["skipped %s"], formatWhen(GuildSync.lastStartupSyncSkippedAt))
    else
        startupStatus = L["pending"]
    end

    local lastReceived = GuildSync.lastHelloReceivedAt
        and string.format(L["%s from %s"], formatWhen(GuildSync.lastHelloReceivedAt), compactName(GuildSync.lastHelloReceivedFrom))
        or L["never"]
    local lastReplySent = GuildSync.lastReplySentAt
        and string.format("%s to %s", formatWhen(GuildSync.lastReplySentAt), compactName(GuildSync.lastReplySentTo))
        or L["never"]
    local lastFullReceived = GuildSync.lastFullSyncReceived
        and string.format("%s from %s", formatWhen(GuildSync.lastFullSyncReceived), compactName(GuildSync.lastFullSyncFrom))
        or L["never"]
    local lastFullSyncCounts = GuildSync.lastFullSyncCounts or {}
    local lastReplySentCounts = GuildSync.lastReplySentCounts or {}
    local lastFullDetails = GuildSync.lastFullSyncReceived
        and string.format("%d merged, %d newer, %d received",
            lastFullSyncCounts.applied or 0,
            lastFullSyncCounts.considered or 0,
            lastFullSyncCounts.receivedTotal or 0)
        or nil
    local lastSafetyRequested = GuildSync.lastSafetyRequestSentAt
        and string.format("%s (%s)", formatWhen(GuildSync.lastSafetyRequestSentAt), GuildSync.lastSafetyRequestReason or "?")
        or L["never"]
    local lastSafetyReceived = GuildSync.lastSafetySyncReceivedAt
        and string.format("%s from %s", formatWhen(GuildSync.lastSafetySyncReceivedAt), compactName(GuildSync.lastSafetySyncReceivedFrom))
        or L["never"]
    local lastSafetyCounts = GuildSync.lastSafetySyncCounts or {}
    local lastSafetyDetails = GuildSync.lastSafetySyncReceivedAt
        and string.format("%d merged, %d newer, %d received",
            lastSafetyCounts.applied or 0,
            lastSafetyCounts.considered or 0,
            lastSafetyCounts.receivedTotal or 0)
        or nil
    local lastSafetyReplySent = GuildSync.lastSafetyReplySentAt
        and string.format("%s to %s", formatWhen(GuildSync.lastSafetyReplySentAt), compactName(GuildSync.lastSafetyReplySentTo))
        or L["never"]
    local lastReplyDetails = GuildSync.lastReplySentAt
        and string.format("%d records offered",
            (lastReplySentCounts.alts or 0) + (lastReplySentCounts.mains or 0)
                + (lastReplySentCounts.formerMembers or 0) + (lastReplySentCounts.nicks or 0)
                + (lastReplySentCounts.customNotes or 0) + (lastReplySentCounts.customOfficerNotes or 0)
                + (lastReplySentCounts.macroRules or 0) + (lastReplySentCounts.macroIgnores or 0)
                + (lastReplySentCounts.bans or 0) + (lastReplySentCounts.birthdays or 0)
                + (lastReplySentCounts.joinDates or 0) + (lastReplySentCounts.recruitmentSettings or 0)
                + (lastReplySentCounts.logRemoved or 0) + (lastReplySentCounts.log or 0))
        or nil
    local compression = GuildSync.lastCompression or GuildSync.lastDecompression
    local compressionDetails = compression
        and string.format("%d -> %d bytes (%d saved)", compression.originalBytes or 0, compression.transferBytes or 0, compression.savedBytes or 0)
        or (GuildSync.lastCompressionSkippedReason or L["none this session"])

    local lines = {}
    table.insert(lines, L["Current guild"])
    table.insert(lines, compactLine(L["Guild"], guildKey))
    table.insert(lines, compactLine(L["Startup"], startupStatus))
    table.insert(lines, compactLine(L["Last full"], formatDateTime(syncMeta.lastFullStateExchangeAt)))
    table.insert(lines, "")
    table.insert(lines, L["Full state"])
    table.insert(lines, compactLine(L["Sent"], lastReplySent))
    if lastReplyDetails then table.insert(lines, "  " .. lastReplyDetails) end
    table.insert(lines, compactLine(L["Received"], lastFullReceived))
    if lastFullDetails then table.insert(lines, "  " .. lastFullDetails) end
    table.insert(lines, "")
    table.insert(lines, L["Safety catch-up"])
    table.insert(lines, compactLine(L["Requested"], lastSafetyRequested))
    table.insert(lines, compactLine(L["Received"], lastSafetyReceived))
    if lastSafetyDetails then table.insert(lines, "  " .. lastSafetyDetails) end
    table.insert(lines, compactLine(L["Reply sent"], lastSafetyReplySent))
    table.insert(lines, "")
    table.insert(lines, L["Event Log"])
    table.insert(lines, compactLine(L["Mode"], bootstrapStatus))
    table.insert(lines, compactLine(L["Reply sent"], GuildSync.lastFullLogReplySentAt
        and string.format("%s to %s (%d entries)", formatWhen(GuildSync.lastFullLogReplySentAt),
            compactName(GuildSync.lastFullLogReplySentTo), GuildSync.lastFullLogReplySentCount or 0)
        or L["never"]))

    frame.statusText:SetText(table.concat(lines, "\n"))

    -- Local data by category, in the exact order ApplyFullState applies a
    -- full sync — this answers "what should sync", so it
    local categoryLines = {
        L["Local data"],
        string.format("Identity: %d alt/main, %d former, %d nick", localCounts.altsMains, localCounts.formerMembers, localCounts.nicknames),
        string.format("Notes: %d general, %d officer", localCounts.notesGeneral, localCounts.notesOfficer),
        string.format("Dates: %d birthdays, %d join", localCounts.birthdays, localCounts.joinDates),
        string.format("Macro: %d rules, %d ignores", localCounts.macroRules, localCounts.macroIgnores),
        string.format("Recruitment/Ban: %d items, %d DNI, %d bans", localCounts.recruitmentItems, localCounts.recruitmentBlacklist, localCounts.bans),
        string.format(L["Event Log: %d (manual replace only)"], logCount),
        "",
        L["Diagnostics"],
        string.format("Last broadcast: %s",
            GuildSync.lastBroadcastAt
                and string.format("%s (%s)", formatWhen(GuildSync.lastBroadcastAt), tostring(GuildSync.lastBroadcastOp))
                or L["never"]),
        string.format("Raw: %d; Compression: %s", GuildSync.rawReceiveCount or 0, compressionDetails),
        (function()
            local pendingCount, oldestAge, oldestReceived, oldestTotal, oldestOp, oldestIdle = GuildSync:GetPendingRawTransferInfo()
            if pendingCount <= 0 then return "Pending transfers: 0" end
            return string.format("Pending transfers: %d (oldest %ds, idle %ds, %d/%d %s chunks)",
                pendingCount, math.floor(oldestAge or 0), math.floor(oldestIdle or 0), oldestReceived or 0, oldestTotal or 0, tostring(oldestOp or "?"))
        end)(),
        string.format("Stale/abandoned: %s",
            (GuildSync.staleRawTransferCount or 0) > 0
                and string.format("%d total, last %s (%s)", GuildSync.staleRawTransferCount, formatWhen(GuildSync.lastStaleRawTransferAt), tostring(GuildSync.lastStaleRawTransferDetail))
                or L["never"]),
        string.format("Raw retry: %s",
            GuildSync.lastRawMissingRequestAt
                and string.format("asked %s (%s)", formatWhen(GuildSync.lastRawMissingRequestAt), tostring(GuildSync.lastRawMissingRequestDetail))
                or (GuildSync.lastRawMissingReplyAt
                    and string.format("sent %s (%s)", formatWhen(GuildSync.lastRawMissingReplyAt), tostring(GuildSync.lastRawMissingReplyDetail))
                    or L["never"])),
        string.format("Last raw: %s",
            GuildSync.lastRawReceivedAt
                and string.format("%s from %s", formatWhen(GuildSync.lastRawReceivedAt), compactName(GuildSync.lastRawReceivedFrom))
                or L["never"]),
        string.format("Rejected: %s",
            GuildSync.lastRejectedAt
                and string.format("%s (%s)", formatWhen(GuildSync.lastRejectedAt), GuildSync.lastRejectedReason)
                or L["never"]),
        string.format("Chunk send failed: %s",
            GuildSync.lastRawChunkSendFailedAt
                and string.format("%s (%s)", formatWhen(GuildSync.lastRawChunkSendFailedAt), tostring(GuildSync.lastRawChunkSendFailedDetail))
                or L["never"]),
        string.format("Ignored: %s",
            GuildSync.lastIgnoredAt
                and string.format("%s from %s (%s)", formatWhen(GuildSync.lastIgnoredAt), compactName(GuildSync.lastIgnoredFrom), GuildSync.lastIgnoredReason)
                or L["never"]),
    }

    -- Diagnostic: the self-echo filter can wrongly catch a real peer's
    -- message or wrongly miss our own on the same client. Shows the actual
    -- GUID/method the check used for the most recent ignored message so
    -- that behavior is visible without reading code.
    local detail = GuildSync.lastIgnoredDetail
    if detail and detail.method == "guid" then
        table.insert(categoryLines, string.format(
            "Self-check: %s echo filtered", detail.method))
    elseif detail then
        table.insert(categoryLines, string.format(
            "Self-check: %s via %s", detail.method, compactName(detail.sender)))
    end
    frame.categoriesText:SetText(table.concat(categoryLines, "\n"))
    frame.peerList:SetData(GuildSync:GetPeerProgress(), false)
end
