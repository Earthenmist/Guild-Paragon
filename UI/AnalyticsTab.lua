-- Guild Paragon - Analytics tab
--
-- Read-only recruitment dashboard for persisted workflow counters and recent
-- scan/executor/outcome records.
local _, GP = ...
local Theme = GP.UI.Theme
local ScrollList = GP.UI.ScrollList

GP.UI.AnalyticsTab = GP.UI.AnalyticsTab or {}
local AnalyticsTab = GP.UI.AnalyticsTab

-- Own AceEvent identity so this tab's message handlers do not overwrite
-- handlers registered by other UI tables.
LibStub("AceEvent-3.0"):Embed(AnalyticsTab)

local frame, list
local refreshDirty = false
local dateFilter = "7d"
local typeFilter = "all"
local visibleRecords = {}

local ROW_HEIGHT = 28
local EXPORT_POPUP = "GUILDPARAGON_EXPORT_VISIBLE_ANALYTICS"

local COL = {
    leftPad = 8,
    gap = 8,
    time = 118,
    type = 78,
    status = 88,
}

local METRICS = {
    { key = "scansStarted", label = "Scans Started" },
    { key = "scansCompleted", label = "Scans Completed" },
    { key = "whoQueriesSent", label = "Who Queries" },
    { key = "whoQueriesRefined", label = "Who Refinements" },
    { key = "whoResults", label = "Who Results" },
    { key = "candidatesFound", label = "Candidates" },
    { key = "candidatesSkipped", label = "Skipped" },
    { key = "candidatesQueued", label = "Queued" },
    { key = "executorContactedCandidates", label = "Contacted" },
    { key = "whispersSent", label = "Whispers" },
    { key = "invitesSent", label = "Invites" },
    { key = "pendingCreated", label = "Pending Created" },
    { key = "pendingResolved", label = "Pending Resolved" },
    { key = "pendingAccepted", label = "Accepted" },
    { key = "pendingDeclined", label = "Declined" },
    { key = "pendingFailed", label = "Failed" },
    { key = "pendingTimedOut", label = "Timed Out" },
    { key = "welcomeGuildSent", label = "Welcome Guild" },
    { key = "welcomeWhisperSent", label = "Welcome Whispers" },
    { key = "welcomeFailed", label = "Welcome Fails" },
    { key = "executorSkippedCandidates", label = "Executor Skips" },
    { key = "executorFailedCandidates", label = "Executor Fails" },
}

local DATE_FILTERS = {
    { key = "today", label = "Today" },
    { key = "7d", label = "7 Days" },
    { key = "30d", label = "30 Days" },
    { key = "all", label = "All" },
}

local TYPE_FILTERS = {
    { key = "all", label = "All" },
    { key = "scan", label = "Scans" },
    { key = "executor", label = "Executor" },
    { key = "outcome", label = "Outcomes" },
    { key = "issues", label = "Issues" },
}

StaticPopupDialogs[EXPORT_POPUP] = StaticPopupDialogs[EXPORT_POPUP] or {
    text = GP.L["Copy visible Analytics export:"],
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 560,
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

local function metricValue(source, key)
    return tonumber(source and source[key]) or 0
end

local function formatDateTime(ts)
    return type(ts) == "number" and date("%Y-%m-%d %H:%M", ts) or GP.L["Never"]
end

local function formatShortTime(ts)
    return type(ts) == "number" and date("%m-%d %H:%M", ts) or GP.L["Never"]
end

local function pct(part, whole)
    part, whole = tonumber(part) or 0, tonumber(whole) or 0
    if whole <= 0 then return "0%" end
    return string.format("%d%%", math.floor((part / whole) * 100 + 0.5))
end

local function outcomeLabel(outcome)
    if outcome == "accepted" then return GP.L["Accepted"] end
    if outcome == "declined" then return GP.L["Declined"] end
    if outcome == "failed" then return GP.L["Failed"] end
    if outcome == "timedout" then return GP.L["Timed Out"] end
    return GP.L["Resolved"]
end

local function typeLabel(record)
    if record.type == "scan" then return GP.L["Scan"] end
    if record.type == "executor" then return GP.L["Executor"] end
    if record.type == "outcome" then return GP.L["Outcome"] end
    return GP.L["Activity"]
end

local function statusLabel(record)
    if record.type == "outcome" then return outcomeLabel(record.outcome) end
    if record.status == "complete" then return GP.L["Complete"] end
    if record.status == "stopped" then return GP.L["Stopped"] end
    if record.status == "error" then return GP.L["Error"] end
    return GP.L["Unknown"]
end

local function statusColor(record)
    if record.type == "outcome" then
        if record.outcome == "accepted" then return Theme.color.success end
        if record.outcome == "declined" or record.outcome == "failed" or record.outcome == "timedout" then return Theme.color.warning end
        return Theme.color.textSecondary
    end
    if record.status == "complete" then return Theme.color.success end
    if record.status == "error" then return Theme.color.danger end
    if record.status == "stopped" then return Theme.color.warning end
    return Theme.color.textSecondary
end

local function recordHasIssue(record)
    if not record then return false end
    if record.error and record.error ~= "" then return true end
    if record.type == "outcome" then
        return record.outcome == "declined" or record.outcome == "failed" or record.outcome == "timedout"
    end
    return record.status == "stopped" or record.status == "error" or (tonumber(record.failed) or 0) > 0
end

local function recordDetail(record)
    if record.type == "scan" then
        return string.format(GP.L["%d result(s), %d candidate(s), %d queued, %d skipped; %d/%d queries"],
            tonumber(record.results) or 0,
            tonumber(record.candidates) or 0,
            tonumber(record.queued) or 0,
            tonumber(record.skipped) or 0,
            tonumber(record.queries) or 0,
            tonumber(record.queryTotal) or 0)
    end
    if record.type == "executor" then
        return string.format(GP.L["%s mode; %d contacted, %d skipped, %d failed"],
            record.mode or GP.L["Unknown"],
            tonumber(record.sent) or 0,
            tonumber(record.skipped) or 0,
            tonumber(record.failed) or 0)
    end
    if record.type == "outcome" then
        local detail = record.name or GP.L["Unknown"]
        if record.reason and record.reason ~= "" then detail = detail .. " - " .. tostring(record.reason) end
        return detail
    end
    return GP.L["Unknown"]
end

local function cutoffForFilter()
    local t = time()
    if dateFilter == "today" then
        return time({ year = tonumber(date("%Y", t)), month = tonumber(date("%m", t)), day = tonumber(date("%d", t)), hour = 0 })
    end
    if dateFilter == "7d" then return t - (7 * 24 * 60 * 60) end
    if dateFilter == "30d" then return t - (30 * 24 * 60 * 60) end
    return nil
end

local function passesFilters(record)
    local cutoff = cutoffForFilter()
    if cutoff and (tonumber(record.endedAt) or 0) < cutoff then return false end
    if typeFilter == "issues" then return recordHasIssue(record) end
    if typeFilter ~= "all" and record.type ~= typeFilter then return false end
    return true
end

local function setButtonSelected(button, selected)
    if not button then return end
    button.selected = selected
    button:SetBackdropColor(unpack(selected and Theme.color.panelRaised or Theme.color.panel))
    button:SetBackdropBorderColor(unpack(selected and Theme.color.accent or Theme.color.accentDim))
    if button.text then button.text:SetTextColor(unpack(selected and Theme.color.accent or Theme.color.textPrimary)) end
end

local function createFilterButton(parent, label, onClick)
    local button = Theme:CreateButton(parent, label)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Theme.color.accent)) end)
    button:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(self.selected and Theme.color.accent or Theme.color.accentDim))
    end)
    return button
end

local function createCard(parent, title)
    local card = Theme:CreatePanel(parent, "panel", "border")
    card:SetHeight(72)

    card.title = card:CreateFontString(nil, "ARTWORK")
    card.title:SetFontObject(Theme.font.small)
    card.title:SetPoint("TOPLEFT", Theme.layout.gutter, -8)
    card.title:SetText(title)
    card.title:SetTextColor(unpack(Theme.color.textSecondary))

    card.value = card:CreateFontString(nil, "ARTWORK")
    card.value:SetFontObject(Theme.font.title)
    card.value:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -8)
    card.value:SetTextColor(unpack(Theme.color.textPrimary))

    card.note = card:CreateFontString(nil, "ARTWORK")
    card.note:SetFontObject(Theme.font.small)
    card.note:SetPoint("TOPLEFT", card.value, "BOTTOMLEFT", 0, -5)
    card.note:SetTextColor(unpack(Theme.color.textSecondary))

    return card
end

local function setCard(card, value, note, color)
    if not card then return end
    card.value:SetText(value or "0")
    card.value:SetTextColor(unpack(color or Theme.color.textPrimary))
    card.note:SetText(note or "")
end

local function metricLine(source, key, label)
    return string.format("%s: %d", GP.L[label], metricValue(source, key))
end

local function buildMetricBlock(source)
    local lines = {}
    table.insert(lines, metricLine(source, "scansStarted", "Scans Started"))
    table.insert(lines, metricLine(source, "whoResults", "Who Results"))
    table.insert(lines, metricLine(source, "candidatesFound", "Candidates"))
    table.insert(lines, metricLine(source, "candidatesQueued", "Queued"))
    table.insert(lines, metricLine(source, "executorContactedCandidates", "Contacted"))
    table.insert(lines, metricLine(source, "pendingAccepted", "Accepted"))
    table.insert(lines, metricLine(source, "pendingDeclined", "Declined"))
    table.insert(lines, metricLine(source, "pendingTimedOut", "Timed Out"))
    table.insert(lines, metricLine(source, "welcomeGuildSent", "Welcome Guild"))
    table.insert(lines, metricLine(source, "welcomeWhisperSent", "Welcome Whispers"))
    return table.concat(lines, "\n")
end

local function escapeTSV(value)
    value = tostring(value or "")
    value = value:gsub("\t", " "):gsub("\r", " "):gsub("\n", " ")
    return value
end

local function tsvLine(values)
    local out = {}
    for i, value in ipairs(values) do out[i] = escapeTSV(value) end
    return table.concat(out, "\t")
end

local function buildVisibleExport()
    local lines = {
        tsvLine({ "time", "type", "status", "outcome", "name", "mode", "results", "candidates", "queued", "skipped", "contacted", "failed", "reason", "error" })
    }
    for _, record in ipairs(visibleRecords) do
        table.insert(lines, tsvLine({
            formatDateTime(record.endedAt),
            record.type,
            statusLabel(record),
            record.outcome,
            record.name,
            record.mode,
            record.results,
            record.candidates,
            record.queued,
            record.skipped,
            record.sent,
            record.failed,
            record.reason,
            record.error,
        }))
    end
    return table.concat(lines, "\n")
end

local function createRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.time = row:CreateFontString(nil, "ARTWORK")
    row.time:SetFontObject(Theme.font.body)
    row.time:SetPoint("LEFT", COL.leftPad, 0)
    row.time:SetWidth(COL.time)
    row.time:SetJustifyH("LEFT")

    row.kind = row:CreateFontString(nil, "ARTWORK")
    row.kind:SetFontObject(Theme.font.body)
    row.kind:SetPoint("LEFT", row.time, "RIGHT", COL.gap, 0)
    row.kind:SetWidth(COL.type)
    row.kind:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "ARTWORK")
    row.status:SetFontObject(Theme.font.body)
    row.status:SetPoint("LEFT", row.kind, "RIGHT", COL.gap, 0)
    row.status:SetWidth(COL.status)
    row.status:SetJustifyH("LEFT")

    row.detail = row:CreateFontString(nil, "ARTWORK")
    row.detail:SetFontObject(Theme.font.muted)
    row.detail:SetPoint("LEFT", row.status, "RIGHT", COL.gap, 0)
    row.detail:SetPoint("RIGHT", -COL.leftPad, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    return row
end

local function updateRow(row, record)
    row.time:SetText(formatShortTime(record.endedAt))
    row.kind:SetText(typeLabel(record))
    row.status:SetText(statusLabel(record))
    row.status:SetTextColor(unpack(statusColor(record)))
    row.detail:SetText(recordDetail(record))
end

local function updateButtons()
    for _, button in ipairs(frame.dateButtons or {}) do
        setButtonSelected(button, button.key == dateFilter)
    end
    for _, button in ipairs(frame.typeButtons or {}) do
        setButtonSelected(button, button.key == typeFilter)
    end
end

local function buildVisibleRecords(summary)
    local out = {}
    for _, record in ipairs(summary.sessions or {}) do
        if passesFilters(record) then table.insert(out, record) end
    end
    return out
end

function AnalyticsTab:Refresh()
    if not frame then return end
    local Recruitment = GP:GetModule("Recruitment")
    local summary = Recruitment:GetAnalyticsSummary(nil, 100)
    local totals, today = summary.totals or {}, summary.today or {}

    local todayCandidates = metricValue(today, "candidatesFound")
    local lifetimeCandidates = metricValue(totals, "candidatesFound")
    local todayContacted = metricValue(today, "executorContactedCandidates")
    local lifetimeContacted = metricValue(totals, "executorContactedCandidates")
    local todayAccepted = metricValue(today, "pendingAccepted")
    local lifetimeAccepted = metricValue(totals, "pendingAccepted")
    local openPending = math.max(0, metricValue(totals, "pendingCreated") - metricValue(totals, "pendingResolved"))

    setCard(frame.cards.candidates, tostring(todayCandidates),
        string.format(GP.L["%d lifetime; %s contacted"], lifetimeCandidates, pct(lifetimeContacted, lifetimeCandidates)))
    setCard(frame.cards.contacted, tostring(todayContacted),
        string.format(GP.L["%d lifetime; %d invite(s)"], lifetimeContacted, metricValue(totals, "invitesSent")))
    setCard(frame.cards.accepted, tostring(todayAccepted),
        string.format(GP.L["%d lifetime; %s conversion"], lifetimeAccepted, pct(lifetimeAccepted, lifetimeContacted)),
        lifetimeAccepted > 0 and Theme.color.success or Theme.color.textPrimary)
    setCard(frame.cards.pending, tostring(openPending),
        string.format(GP.L["%d created; %d resolved"], metricValue(totals, "pendingCreated"), metricValue(totals, "pendingResolved")),
        openPending > 0 and Theme.color.warning or Theme.color.textPrimary)

    frame.todayText:SetText(buildMetricBlock(today))
    frame.lifetimeText:SetText(buildMetricBlock(totals))
    frame.updatedText:SetText(string.format(GP.L["Last updated: %s"], formatDateTime(summary.updatedAt)))

    updateButtons()
    visibleRecords = buildVisibleRecords(summary)
    list:SetData(visibleRecords, false)
    frame.sessionSummary:SetText(string.format(GP.L["Showing %d of %d stored analytics record(s)"], #visibleRecords, #(summary.sessions or {})))
end

function AnalyticsTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    frame.cards = {}

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Analytics"])

    local info = frame:CreateFontString(nil, "ARTWORK")
    info:SetFontObject(Theme.font.muted)
    info:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    info:SetWidth(760)
    info:SetJustifyH("LEFT")
    info:SetText(L["Recruitment analytics are stored per guild and update as scans, queues, and executor actions run."])

    frame.updatedText = frame:CreateFontString(nil, "ARTWORK")
    frame.updatedText:SetFontObject(Theme.font.small)
    frame.updatedText:SetPoint("TOPRIGHT", 0, -4)
    frame.updatedText:SetJustifyH("RIGHT")

    local cardsRow = CreateFrame("Frame", nil, frame)
    cardsRow:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -16)
    cardsRow:SetPoint("RIGHT", 0, 0)
    cardsRow:SetHeight(72)

    frame.cards.candidates = createCard(cardsRow, L["Candidates"])
    frame.cards.candidates:SetPoint("TOPLEFT")
    frame.cards.candidates:SetWidth(230)

    frame.cards.contacted = createCard(cardsRow, L["Contacted"])
    frame.cards.contacted:SetPoint("LEFT", frame.cards.candidates, "RIGHT", Theme.layout.gutter, 0)
    frame.cards.contacted:SetWidth(230)

    frame.cards.accepted = createCard(cardsRow, L["Accepted"])
    frame.cards.accepted:SetPoint("LEFT", frame.cards.contacted, "RIGHT", Theme.layout.gutter, 0)
    frame.cards.accepted:SetWidth(230)

    frame.cards.pending = createCard(cardsRow, L["Open Pending"])
    frame.cards.pending:SetPoint("LEFT", frame.cards.accepted, "RIGHT", Theme.layout.gutter, 0)
    frame.cards.pending:SetPoint("RIGHT")

    local metricsPanel = Theme:CreatePanel(frame, "panel", "border")
    metricsPanel:SetPoint("TOPLEFT", cardsRow, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    metricsPanel:SetPoint("BOTTOMLEFT", 0, 0)
    metricsPanel:SetWidth(250)

    local todayHeading = metricsPanel:CreateFontString(nil, "ARTWORK")
    todayHeading:SetFontObject(Theme.font.heading)
    todayHeading:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    todayHeading:SetText(L["Today"])

    frame.todayText = metricsPanel:CreateFontString(nil, "ARTWORK")
    frame.todayText:SetFontObject(Theme.font.body)
    frame.todayText:SetPoint("TOPLEFT", todayHeading, "BOTTOMLEFT", 0, -6)
    frame.todayText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.todayText:SetJustifyH("LEFT")
    frame.todayText:SetJustifyV("TOP")

    local lifetimeHeading = metricsPanel:CreateFontString(nil, "ARTWORK")
    lifetimeHeading:SetFontObject(Theme.font.heading)
    lifetimeHeading:SetPoint("TOPLEFT", metricsPanel, "TOPLEFT", Theme.layout.gutter, -176)
    lifetimeHeading:SetText(L["Lifetime"])

    frame.lifetimeText = metricsPanel:CreateFontString(nil, "ARTWORK")
    frame.lifetimeText:SetFontObject(Theme.font.body)
    frame.lifetimeText:SetPoint("TOPLEFT", lifetimeHeading, "BOTTOMLEFT", 0, -6)
    frame.lifetimeText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.lifetimeText:SetJustifyH("LEFT")
    frame.lifetimeText:SetJustifyV("TOP")

    local sessionsPanel = Theme:CreatePanel(frame, "panel", "border")
    sessionsPanel:SetPoint("TOPLEFT", metricsPanel, "TOPRIGHT", Theme.layout.gutter, 0)
    sessionsPanel:SetPoint("BOTTOMRIGHT", 0, 0)

    local sessionTitle = sessionsPanel:CreateFontString(nil, "ARTWORK")
    sessionTitle:SetFontObject(Theme.font.heading)
    sessionTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    sessionTitle:SetText(L["Recruitment Activity"])

    frame.sessionSummary = sessionsPanel:CreateFontString(nil, "ARTWORK")
    frame.sessionSummary:SetFontObject(Theme.font.small)
    frame.sessionSummary:SetPoint("TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter - 2)
    frame.sessionSummary:SetJustifyH("RIGHT")

    frame.dateButtons = {}
    local previous
    for _, def in ipairs(DATE_FILTERS) do
        local button = createFilterButton(sessionsPanel, L[def.label], function()
            dateFilter = def.key
            AnalyticsTab:Refresh()
        end)
        button.key = def.key
        button:SetWidth(def.key == "today" and 72 or 78)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("TOPLEFT", sessionTitle, "BOTTOMLEFT", 0, -10)
        end
        table.insert(frame.dateButtons, button)
        previous = button
    end

    frame.typeButtons = {}
    previous = nil
    for _, def in ipairs(TYPE_FILTERS) do
        local button = createFilterButton(sessionsPanel, L[def.label], function()
            typeFilter = def.key
            AnalyticsTab:Refresh()
        end)
        button.key = def.key
        button:SetWidth(def.key == "executor" and 86 or 78)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("TOPLEFT", frame.dateButtons[1], "BOTTOMLEFT", 0, -8)
        end
        table.insert(frame.typeButtons, button)
        previous = button
    end

    local exportButton = Theme:CreateButton(sessionsPanel, L["Export Visible"])
    exportButton:SetPoint("RIGHT", sessionsPanel, "RIGHT", -Theme.layout.gutter, 0)
    exportButton:SetPoint("TOP", frame.typeButtons[1], "TOP", 0, 0)
    exportButton:SetScript("OnClick", function()
        local exportText = buildVisibleExport()
        StaticPopup_Show(EXPORT_POPUP, exportText, nil, exportText)
    end)

    local header = CreateFrame("Frame", nil, sessionsPanel)
    header:SetPoint("TOPLEFT", frame.typeButtons[1], "BOTTOMLEFT", 0, -14)
    header:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    header:SetHeight(18)

    local timeHeader = header:CreateFontString(nil, "ARTWORK")
    timeHeader:SetFontObject(Theme.font.small)
    timeHeader:SetPoint("LEFT", COL.leftPad, 0)
    timeHeader:SetWidth(COL.time)
    timeHeader:SetJustifyH("LEFT")
    timeHeader:SetText(L["Time"])

    local typeHeader = header:CreateFontString(nil, "ARTWORK")
    typeHeader:SetFontObject(Theme.font.small)
    typeHeader:SetPoint("LEFT", timeHeader, "RIGHT", COL.gap, 0)
    typeHeader:SetWidth(COL.type)
    typeHeader:SetJustifyH("LEFT")
    typeHeader:SetText(L["Type"])

    local statusHeader = header:CreateFontString(nil, "ARTWORK")
    statusHeader:SetFontObject(Theme.font.small)
    statusHeader:SetPoint("LEFT", typeHeader, "RIGHT", COL.gap, 0)
    statusHeader:SetWidth(COL.status)
    statusHeader:SetJustifyH("LEFT")
    statusHeader:SetText(L["Status"])

    local detailHeader = header:CreateFontString(nil, "ARTWORK")
    detailHeader:SetFontObject(Theme.font.small)
    detailHeader:SetPoint("LEFT", statusHeader, "RIGHT", COL.gap, 0)
    detailHeader:SetPoint("RIGHT", -COL.leftPad, 0)
    detailHeader:SetJustifyH("LEFT")
    detailHeader:SetText(L["Details"])

    local listPanel = Theme:CreatePanel(sessionsPanel, "panel", "border")
    listPanel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    listPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)

    list = ScrollList:New(listPanel, ROW_HEIGHT, createRow)
    list:SetUpdateRow(updateRow)

    -- Collapse bursty scanner events to one refresh.
    local function debouncedRefresh()
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("AnalyticsTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                AnalyticsTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    AnalyticsTab:RegisterMessage("GuildParagon_RecruitmentScannerChanged", debouncedRefresh)
    AnalyticsTab:RegisterMessage("GuildParagon_RecruitmentChanged", debouncedRefresh)

    frame.OnSelected = function()
        refreshDirty = false
        AnalyticsTab:Refresh()
    end

    self:Refresh()
    return frame
end
