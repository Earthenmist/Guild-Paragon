-- Guild Paragon - Guild Health tab
-- Officer-facing attention dashboard.
local _, GP = ...
local Theme = GP.UI.Theme
local ScrollList = GP.UI.ScrollList

GP.UI.GuildHealthTab = GP.UI.GuildHealthTab or {}
local GuildHealthTab = GP.UI.GuildHealthTab

LibStub("AceEvent-3.0"):Embed(GuildHealthTab)

local frame, attentionList, retentionList, recruitmentActivityList
local visibleRows = {}
local visibleRecruiters = {}
local visibleRecruitmentRecords = {}
local selectedRow
local selectedCohort = 30
local activeFilter = "all"
local activeView = "overview"
local recruitmentDateFilter = "7d"
local recruitmentTypeFilter = "all"
local lastRefreshAt = 0
local refreshScheduled = false
local refreshPending = false
local refreshToken = 0
local addText

local ROW_HEIGHT = 32
local RETENTION_ROW_HEIGHT = 26
local RECRUITMENT_ROW_HEIGHT = 28
local REFRESH_DEBOUNCE_SECONDS = 5
local MAX_CLASS_ROWS = 13
local MYTHIC_BUCKET_ROWS = 6
local MAX_LINKED_CONTEXT_ROWS = 12
local EXPORT_POPUP = "GUILDPARAGON_EXPORT_VISIBLE_ANALYTICS"

local COL = {
    pad = 8,
    status = 18,
    category = 66,
    title = 190,
    recruiter = 150,
    small = 72,
    pct = 100,
}

local ANALYTICS_DATE_FILTERS = {
    { key = "today", label = "Today" },
    { key = "7d", label = "7 Days" },
    { key = "30d", label = "30 Days" },
    { key = "all", label = "All" },
}

local ANALYTICS_TYPE_FILTERS = {
    { key = "all", label = "All" },
    { key = "pending", label = "Pending" },
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

local function formatDateTime(ts)
    return type(ts) == "number" and date("%Y-%m-%d %H:%M", ts) or GP.L["Never"]
end

local function severityColor(severity)
    if severity == "critical" then return Theme.color.danger end
    if severity == "warning" then return Theme.color.warning end
    return Theme.color.info
end

local function colorEscape(color)
    if not color then return "ffffffff" end
    local r = math.floor(((color.r or color[1] or 1) * 255) + 0.5)
    local g = math.floor(((color.g or color[2] or 1) * 255) + 0.5)
    local b = math.floor(((color.b or color[3] or 1) * 255) + 0.5)
    return string.format("ff%02x%02x%02x", r, g, b)
end

local function classColoredName(player)
    local name = player and player.name or GP.L["Unknown"]
    local classFile = player and (player.classFile or player.class)
    local color = classFile and C_ClassColor and C_ClassColor.GetClassColor(classFile)
    color = color or (classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
    return string.format("|c%s%s|r", colorEscape(color), name)
end

local function pctText(cohort)
    if not cohort or not cohort.retentionPct then
        if not cohort or (tonumber(cohort.judged) or 0) <= 0 then return GP.L["Not enough data"] end
        return string.format(GP.L["%d judged"], cohort.judged or 0)
    end
    return string.format(GP.L["%d%%"], cohort.retentionPct)
end

local function metricValue(source, key)
    return tonumber(source and source[key]) or 0
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

local function pct(part, whole)
    part, whole = tonumber(part) or 0, tonumber(whole) or 0
    if whole <= 0 then return "0%" end
    return string.format("%d%%", math.floor((part / whole) * 100 + 0.5))
end

local function formatShortTime(ts)
    return type(ts) == "number" and date("%m-%d %H:%M", ts) or GP.L["Never"]
end

local function currentGuildKey()
    local Roster = GP:GetModule("Roster", true)
    return Roster and (Roster.currentGuildKey or Roster:GetGuildKey()) or nil
end

local function guildDataForCurrent()
    local guildKey = currentGuildKey()
    return guildKey, guildKey and GP.db.global.guilds[guildKey] or nil
end

local function playerForRow(rowData)
    local _, guildData = guildDataForCurrent()
    if not guildData or not rowData then return nil end
    return (guildData.roster or {})[rowData.guid] or (guildData.formerMembers or {})[rowData.guid]
end

local function formatLastOnline(player)
    if not player then return GP.L["Unknown"] end
    if player.online then return GP.L["Online"] end
    local hours = tonumber(player.lastOnline)
    if not hours then return GP.L["Unknown"] end
    if hours <= 0 then return GP.L["< 1 hr"] end
    if hours < 24 then return string.format(GP.L["%d hour(s)"], hours) end
    return string.format(GP.L["%d day(s)"], math.floor(hours / 24))
end

local function outcomeLabel(outcome)
    if outcome == "accepted" then return GP.L["Accepted"] end
    if outcome == "declined" then return GP.L["Declined"] end
    if outcome == "failed" then return GP.L["Failed"] end
    if outcome == "timedout" then return GP.L["Timed Out"] end
    return GP.L["Resolved"]
end

local function recruitmentTypeLabel(record)
    if record.type == "pending" then return GP.L["Pending"] end
    if record.type == "scan" then return GP.L["Scan"] end
    if record.type == "executor" then return GP.L["Executor"] end
    if record.type == "outcome" then return GP.L["Outcome"] end
    return GP.L["Activity"]
end

local function recruitmentStatusLabel(record)
    if record.type == "pending" then return GP.L["Pending"] end
    if record.type == "outcome" then return outcomeLabel(record.outcome) end
    if record.status == "complete" then return GP.L["Complete"] end
    if record.status == "stopped" then return GP.L["Stopped"] end
    if record.status == "error" then return GP.L["Error"] end
    return GP.L["Unknown"]
end

local function recruitmentStatusColor(record)
    if record.type == "pending" then return Theme.color.warning end
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

local function recruitmentRecordHasIssue(record)
    if not record then return false end
    if record.error and record.error ~= "" then return true end
    if record.type == "outcome" then
        return record.outcome == "declined" or record.outcome == "failed" or record.outcome == "timedout"
    end
    return record.status == "stopped" or record.status == "error" or (tonumber(record.failed) or 0) > 0
end

local function recruitmentRecordDetail(record)
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
    if record.type == "pending" then
        local detail = record.name or GP.L["Unknown"]
        if record.mode and record.mode ~= "" then detail = detail .. " - " .. tostring(record.mode) end
        if record.contactedBy and record.contactedBy ~= "" then detail = detail .. " - " .. string.format(GP.L["Contacted by %s"], record.contactedBy) end
        return detail
    end
    return GP.L["Unknown"]
end

local function setButtonSelected(button, selected)
    if not button then return end
    button.selected = selected
    button:SetBackdropColor(unpack(selected and Theme.color.panelRaised or Theme.color.panel))
    button:SetBackdropBorderColor(unpack(selected and Theme.color.accent or Theme.color.accentDim))
    if button.text then button.text:SetTextColor(unpack(selected and Theme.color.accent or Theme.color.textPrimary)) end
end

local function viewPage(key)
    return frame and frame.viewPages and frame.viewPages[key] or nil
end

local function selectView(key)
    local previousView = activeView
    activeView = key or "overview"
    if not frame then return end
    for pageKey, page in pairs(frame.viewPages or {}) do
        page:SetShown(pageKey == activeView)
    end
    for _, button in ipairs(frame.viewButtons or {}) do
        setButtonSelected(button, button.key == activeView)
    end
    local selectedPage = frame.viewPages and frame.viewPages[activeView]
    if previousView ~= activeView and selectedPage and selectedPage.OnSelected then
        selectedPage:OnSelected()
    end
    GuildHealthTab:Refresh()
end

local function showActivityAttention()
    activeFilter = "activity"
    selectView("attention")
end

local function showAllAttention()
    activeFilter = "all"
    selectView("attention")
end

local function showNewMemberAttention()
    activeFilter = "newmember"
    selectView("attention")
end

local function showRecruitmentActivity(typeFilter)
    recruitmentDateFilter = "all"
    recruitmentTypeFilter = typeFilter or "all"
    selectView("recruitment")
end

local function showPendingRecruitment()
    showRecruitmentActivity("pending")
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
    local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
    card:SetBackdrop((Theme:Backdrop("panel", "border")))
    card:SetBackdropColor(unpack(Theme.color.panel))
    card:SetBackdropBorderColor(unpack(Theme.color.border))
    card:SetHeight(70)

    card.title = card:CreateFontString(nil, "ARTWORK")
    card.title:SetFontObject(Theme.font.small)
    card.title:SetPoint("TOPLEFT", Theme.layout.gutter, -8)
    card.title:SetText(title)
    card.title:SetTextColor(unpack(Theme.color.textSecondary))

    card.value = card:CreateFontString(nil, "ARTWORK")
    card.value:SetFontObject(Theme.font.title)
    card.value:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -7)
    card.value:SetTextColor(unpack(Theme.color.textPrimary))

    card.note = card:CreateFontString(nil, "ARTWORK")
    card.note:SetFontObject(Theme.font.small)
    card.note:SetPoint("TOPLEFT", card.value, "BOTTOMLEFT", 0, -5)
    card.note:SetTextColor(unpack(Theme.color.textSecondary))

    return card
end

local function setCard(card, value, note, color)
    if not card then return end
    card.value:SetText(tostring(value or 0))
    card.value:SetTextColor(unpack(color or Theme.color.textPrimary))
    card.note:SetText(note or "")
end

local function setCardTitle(card, title)
    if card and card.title then card.title:SetText(title or "") end
end

local function setCardAction(card, onClick)
    if not card then return end
    card.hasAction = onClick and true or false
    card:EnableMouse(onClick and true or false)
    card:SetScript("OnClick", onClick)
    card:SetScript("OnEnter", onClick and function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accent))
    end or nil)
    card:SetScript("OnLeave", onClick and function(self)
        self:SetBackdropColor(unpack(Theme.color.panel))
        self:SetBackdropBorderColor(unpack(Theme.color.border))
    end or nil)
    if not onClick then
        card:SetBackdropColor(unpack(Theme.color.panel))
        card:SetBackdropBorderColor(unpack(Theme.color.border))
    end
end

local function colorByKey(key)
    return Theme.color[key or "textSecondary"] or Theme.color.textSecondary
end

local function createMetricBar(parent, label, colorKey)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(22)
    row.label = row:CreateFontString(nil, "ARTWORK")
    row.label:SetFontObject(Theme.font.body)
    row.label:SetPoint("LEFT")
    row.label:SetWidth(125)
    row.label:SetJustifyH("LEFT")
    row.label:SetText(label)

    row.track = row:CreateTexture(nil, "BACKGROUND")
    row.track:SetColorTexture(0.18, 0.19, 0.22, 0.85)
    row.track:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
    row.track:SetSize(270, 8)

    row.fill = row:CreateTexture(nil, "ARTWORK")
    row.fill:SetColorTexture(unpack(colorByKey(colorKey or "info")))
    row.fill:SetPoint("LEFT", row.track, "LEFT")
    row.fill:SetHeight(8)

    row.value = row:CreateFontString(nil, "ARTWORK")
    row.value:SetFontObject(Theme.font.small)
    row.value:SetPoint("LEFT", row.track, "RIGHT", 10, 0)
    row.value:SetWidth(58)
    row.value:SetJustifyH("RIGHT")
    return row
end

local function updateMetricBar(row, pct, text)
    pct = math.max(0, math.min(100, tonumber(pct) or 0))
    row.fill:SetWidth(math.max(1, 270 * pct / 100))
    row.value:SetText(text or string.format(GP.L["%d%%"], pct))
end

local function createOverviewPanel(parent, title)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel.title = addText(panel, Theme.font.heading, title, { "TOPLEFT", panel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    return panel
end

local function createRiskRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(24)
    row.bar = createMetricBar(row, "", "success")
    row.bar:SetAllPoints()
    row:SetScript("OnClick", function(self)
        if self.riskKey == "atRisk" or self.riskKey == "gone" then showActivityAttention() end
    end)
    return row
end

local function updateRiskRow(row, data, total)
    row.riskKey = data.key
    row.bar.label:SetText(data.label or "")
    row.bar.fill:SetColorTexture(unpack(colorByKey(data.color)))
    updateMetricBar(row.bar, total > 0 and ((data.count or 0) / total) * 100 or 0, tostring(data.count or 0))
end

local function createCompositionRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(22)
    row.bar = createMetricBar(row, "", "info")
    row.bar:SetAllPoints()
    return row
end

local function updateCompositionRow(row, data, maxTotal)
    row.bar.label:SetText(data.label or GP.L["Unknown"])
    row.bar.label:SetTextColor(unpack(data.color or Theme.color.textSecondary))
    row.bar.fill:SetColorTexture(unpack(data.color or Theme.color.info))
    updateMetricBar(row.bar, maxTotal > 0 and ((data.total or 0) / maxTotal) * 100 or 0, string.format(GP.L["%d/%d"], data.active or 0, data.total or 0))
end

local function buildAttentionRows(summary)
    if activeFilter == "all" then
        return summary.rows or {}, summary.rowTotal or 0
    end
    local rowsByCategory = summary.rowsByCategory or {}
    local totalsByCategory = summary.totalsByCategory or {}
    return rowsByCategory[activeFilter] or {}, totalsByCategory[activeFilter] or 0
end

local function categoryLabel(category)
    if category == "cleanup" then return GP.L["Cleanup"] end
    if category == "activity" then return GP.L["Activity"] end
    if category == "newmember" then return GP.L["New Members"] end
    return GP.L["Guild Health"]
end

local selectRow

local function openSelectedInRoster()
    if not selectedRow then return end
    local MainWindow = GP.UI.MainWindow
    local RosterTab = GP.UI.RosterTab
    if not MainWindow or not RosterTab then return end

    MainWindow:SelectTab("roster")
    if not RosterTab:SelectPlayerByGUID(selectedRow.guid, selectedRow.name) then
        GP:Print(GP.L["Player not found."])
    end
end

local function showSelectedMacroRules(button)
    local guildKey = currentGuildKey()
    local player = playerForRow(selectedRow)
    if not guildKey or not player or not GP.UI.MemberTooltip then return end
    local ok = GP.UI.MemberTooltip:ShowMacroRulesForPlayer(button, player, guildKey)
    if not ok then GP:Print(GP.L["Macro Tool is officer-only."]) end
end

local function toggleSelectedMacroIgnore(action)
    local guildKey = currentGuildKey()
    local MacroTool = GP:GetModule("MacroTool", true)
    if not guildKey or not selectedRow or not selectedRow.guid or not MacroTool then return end

    local value = not MacroTool:IsPlayerIgnored(guildKey, selectedRow.guid, action)
    local ok, err = MacroTool:SetPlayerIgnore(guildKey, selectedRow.guid, action, value)
    GP:Print(ok and GP.L["Macro Rules updated."] or err)
    if ok then
        GuildHealthTab:Refresh()
        selectRow(selectedRow)
    end
end

local function rankDisplayName(rankIndex)
    rankIndex = tonumber(rankIndex)
    if not rankIndex then return nil end
    if GuildControlGetRankName then
        local ok, name = pcall(GuildControlGetRankName, rankIndex + 1)
        name = ok and GP:SafeOptionalString(name) or nil
        if name and name ~= "" then return name end
    end
    return string.format(GP.L["Rank %d"], rankIndex)
end

local function promoteSelectedNewMember()
    local guildKey = currentGuildKey()
    local player = playerForRow(selectedRow)
    local GuildHealth = GP:GetModule("GuildHealth", true)
    local MacroTool = GP:GetModule("MacroTool", true)
    local settings = GuildHealth and GuildHealth:GetSettings() or {}
    local targetRankIndex = tonumber(settings.newMemberPromotionRankIndex)

    if not guildKey or not player or not selectedRow then
        GP:Print(GP.L["Player not found."])
        return
    end
    if not MacroTool or not MacroTool:CanUse() then
        GP:Print(GP.L["Macro Tool requires officer access."])
        return
    end
    if not targetRankIndex then
        GP:Print(GP.L["Choose a rank after promotion in Settings > Health first."])
        return
    end

    local currentRank = tonumber(player.rankIndex)
    if currentRank == nil then
        GP:Print(GP.L["Current rank is unknown."])
        return
    end
    if targetRankIndex >= currentRank then
        GP:Print(GP.L["Rank after promotion must be above the current rank."])
        return
    end

    local ok, msg = MacroTool:BuildExecutionBatch({
        {
            include = true,
            action = "promote",
            actualAction = "promote",
            player = player,
            guid = player.guid,
            targetRankIndex = targetRankIndex,
            targetRankName = rankDisplayName(targetRankIndex),
        },
    })
    GP:Print(ok and (msg or GP.L["Promotion macro armed."]) or msg)
    if ok and GP.UI.MainWindow then
        GP.UI.MainWindow:SelectTab("macro")
    end
end

local function setActionButton(button, shown, label, onClick)
    if not button then return end
    button:SetShown(shown and true or false)
    if label and button.text then
        button.text:SetText(label)
        button:SetWidth(button.text:GetStringWidth() + 32)
    end
    button:SetScript("OnClick", onClick)
end

local function activityContextText(rowData)
    local lines = {}
    if rowData and rowData.members then
        local members = {}
        for _, entry in ipairs(rowData.members) do
            table.insert(members, entry)
        end
        table.sort(members, function(a, b)
            local ap, bp = a and a.player, b and b.player
            local ar, br = tonumber(ap and ap.rankIndex) or 999, tonumber(bp and bp.rankIndex) or 999
            if ar ~= br then return ar < br end
            return tostring(ap and ap.name or "") < tostring(bp and bp.name or "")
        end)

        local shown = math.min(#members, MAX_LINKED_CONTEXT_ROWS)
        for i = 1, shown do
            local entry = members[i]
            local player = entry.player
            local rank = player and player.rankName or GP.L["Unknown"]
            table.insert(lines, string.format("%s  |  %s  |  %s", classColoredName(player), rank, formatLastOnline(player)))
        end
        if #members > shown then
            table.insert(lines, string.format(GP.L["%d more linked character(s) not shown."], #members - shown))
        end
    end
    return #lines > 0 and table.concat(lines, "\n") or GP.L["No linked character details available."]
end

local function refreshDetailActions(rowData)
    if not frame or not frame.detailActions then return end
    local guildKey = currentGuildKey()
    local MacroTool = GP:GetModule("MacroTool", true)
    local hasPlayer = rowData and rowData.guid and playerForRow(rowData)
    local canUseMacro = hasPlayer and guildKey and MacroTool and MacroTool:CanUse()

    setActionButton(frame.detailActions.roster, hasPlayer, GP.L["Open in Roster"], openSelectedInRoster)
    setActionButton(frame.detailActions.macro, canUseMacro, GP.L["Macro Rules"], function(self) showSelectedMacroRules(self) end)

    if rowData and rowData.category == "activity" and canUseMacro then
        local ignored = MacroTool:IsPlayerIgnored(guildKey, rowData.guid, "kick")
        setActionButton(frame.detailActions.ignoreKick, true, ignored and GP.L["Allow Kick Rules"] or GP.L["Do Not Kick"], function()
            toggleSelectedMacroIgnore("kick")
        end)
    else
        setActionButton(frame.detailActions.ignoreKick, false)
    end

    if rowData and rowData.category == "newmember" and canUseMacro then
        local ignored = MacroTool:IsPlayerIgnored(guildKey, rowData.guid, "promote")
        setActionButton(frame.detailActions.ignorePromote, true, ignored and GP.L["Allow Promote Rules"] or GP.L["Do Not Promote"], function()
            toggleSelectedMacroIgnore("promote")
        end)
    else
        setActionButton(frame.detailActions.ignorePromote, false)
    end

    setActionButton(frame.detailActions.promote, rowData and rowData.promotionReview and canUseMacro, GP.L["Promote"], promoteSelectedNewMember)
end

selectRow = function(rowData)
    selectedRow = rowData
    if attentionList then attentionList:Refresh() end
    if not frame then return end

    if not rowData then
        frame.detailTitle:SetText(GP.L["Select an attention item"])
        frame.detailBody:SetText(GP.L["Select a row to view the source data and caveat."])
        if frame.detailContextTitle then frame.detailContextTitle:SetText("") end
        if frame.detailContextBody then frame.detailContextBody:SetText("") end
        refreshDetailActions(nil)
        return
    end

    frame.detailTitle:SetText(rowData.title or GP.L["Attention item"])
    frame.detailBody:SetText(string.format(GP.L["Reason: %s\nSource: %s\n\n%s"],
        categoryLabel(rowData.category),
        rowData.source or GP.L["Unknown"],
        rowData.detail or ""))
    if frame.detailContextTitle then
        frame.detailContextTitle:SetText(rowData.category == "activity" and GP.L["Linked Characters"] or GP.L["Action Context"])
    end
    if frame.detailContextBody then
        frame.detailContextBody:SetText(rowData.category == "activity" and activityContextText(rowData) or GP.L["Use the actions above to open the player in context or manage Macro Rule ignores."])
    end
    refreshDetailActions(rowData)
end

local function createAttentionRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("LEFT", COL.pad, 0)

    row.category = row:CreateFontString(nil, "ARTWORK")
    row.category:SetFontObject(Theme.font.small)
    row.category:SetPoint("LEFT", row.dot, "RIGHT", COL.status, 0)
    row.category:SetWidth(COL.category)
    row.category:SetJustifyH("LEFT")

    row.title = row:CreateFontString(nil, "ARTWORK")
    row.title:SetFontObject(Theme.font.body)
    row.title:SetPoint("LEFT", row.category, "RIGHT", COL.pad, 0)
    row.title:SetWidth(COL.title)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.detail = row:CreateFontString(nil, "ARTWORK")
    row.detail:SetFontObject(Theme.font.muted)
    row.detail:SetPoint("LEFT", row.title, "RIGHT", COL.pad, 0)
    row.detail:SetPoint("RIGHT", -COL.pad, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if not self.selected then self:SetBackdropColor(unpack(Theme.color.panelRaised)) end
    end)
    row:SetScript("OnLeave", function(self)
        if not self.selected then self:SetBackdropColor(0, 0, 0, 0) end
    end)
    row:SetScript("OnClick", function(self)
        if self.rowData then selectRow(self.rowData) end
    end)
    return row
end

local function updateAttentionRow(row, rowData)
    row.rowData = rowData
    row.selected = selectedRow and rowData and selectedRow.id == rowData.id
    row:SetBackdropColor(unpack(row.selected and Theme.color.panelRaised or { 0, 0, 0, 0 }))
    row.dot:SetColorTexture(unpack(severityColor(rowData.severity)))
    row.category:SetText(categoryLabel(rowData.category))
    row.category:SetTextColor(unpack(Theme.color.textSecondary))
    row.title:SetText(rowData.title or "")
    row.title:SetTextColor(unpack(rowData.severity == "critical" and Theme.color.danger
        or rowData.severity == "warning" and Theme.color.warning
        or Theme.color.textPrimary))
    row.detail:SetText(rowData.detail or "")
end

local function createRetentionRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.recruiter = row:CreateFontString(nil, "ARTWORK")
    row.recruiter:SetFontObject(Theme.font.body)
    row.recruiter:SetPoint("LEFT", COL.pad, 0)
    row.recruiter:SetWidth(COL.recruiter)
    row.recruiter:SetJustifyH("LEFT")
    row.recruiter:SetWordWrap(false)

    local previous = row.recruiter
    row.cells = {}
    for i = 1, 6 do
        local cell = row:CreateFontString(nil, "ARTWORK")
        cell:SetFontObject(Theme.font.muted)
        cell:SetPoint("LEFT", previous, "RIGHT", COL.pad, 0)
        cell:SetWidth(i == 6 and COL.pct or COL.small)
        cell:SetJustifyH("LEFT")
        row.cells[i] = cell
        previous = cell
    end

    return row
end

local function recruitmentCutoffForFilter()
    local t = time()
    if recruitmentDateFilter == "today" then
        return time({ year = tonumber(date("%Y", t)), month = tonumber(date("%m", t)), day = tonumber(date("%d", t)), hour = 0 })
    end
    if recruitmentDateFilter == "7d" then return t - (7 * 24 * 60 * 60) end
    if recruitmentDateFilter == "30d" then return t - (30 * 24 * 60 * 60) end
    return nil
end

local function recruitmentRecordPassesFilters(record)
    local cutoff = recruitmentCutoffForFilter()
    if cutoff and (tonumber(record.endedAt) or 0) < cutoff then return false end
    if recruitmentTypeFilter == "issues" then return recruitmentRecordHasIssue(record) end
    if recruitmentTypeFilter ~= "all" and record.type ~= recruitmentTypeFilter then return false end
    return true
end

local function buildVisibleRecruitmentRecords(summary)
    local out = {}
    for _, pending in ipairs(summary.pendingInvites or {}) do
        local record = {}
        for key, value in pairs(pending) do record[key] = value end
        record.type = "pending"
        record.endedAt = record.contactedAt or record.updatedAt
        if recruitmentRecordPassesFilters(record) then table.insert(out, record) end
    end
    for _, record in ipairs(summary.sessions or {}) do
        if recruitmentRecordPassesFilters(record) then table.insert(out, record) end
    end
    return out
end

local function recruitmentRecordTotal(summary)
    return #(summary.sessions or {}) + #(summary.pendingInvites or {})
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

local function buildVisibleRecruitmentExport()
    local lines = {
        tsvLine({ "time", "type", "status", "outcome", "name", "mode", "results", "candidates", "queued", "skipped", "contacted", "failed", "reason", "error" })
    }
    for _, record in ipairs(visibleRecruitmentRecords) do
        table.insert(lines, tsvLine({
            formatDateTime(record.endedAt),
            record.type,
            recruitmentStatusLabel(record),
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

local function createRecruitmentActivityRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.time = row:CreateFontString(nil, "ARTWORK")
    row.time:SetFontObject(Theme.font.body)
    row.time:SetPoint("LEFT", COL.pad, 0)
    row.time:SetWidth(118)
    row.time:SetJustifyH("LEFT")

    row.kind = row:CreateFontString(nil, "ARTWORK")
    row.kind:SetFontObject(Theme.font.body)
    row.kind:SetPoint("LEFT", row.time, "RIGHT", COL.pad, 0)
    row.kind:SetWidth(78)
    row.kind:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "ARTWORK")
    row.status:SetFontObject(Theme.font.body)
    row.status:SetPoint("LEFT", row.kind, "RIGHT", COL.pad, 0)
    row.status:SetWidth(88)
    row.status:SetJustifyH("LEFT")

    row.detail = row:CreateFontString(nil, "ARTWORK")
    row.detail:SetFontObject(Theme.font.muted)
    row.detail:SetPoint("LEFT", row.status, "RIGHT", COL.pad, 0)
    row.detail:SetPoint("RIGHT", -COL.pad, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)
    return row
end

local function updateRecruitmentActivityRow(row, record)
    row.time:SetText(formatShortTime(record.endedAt))
    row.kind:SetText(recruitmentTypeLabel(record))
    row.status:SetText(recruitmentStatusLabel(record))
    row.status:SetTextColor(unpack(recruitmentStatusColor(record)))
    row.detail:SetText(recruitmentRecordDetail(record))
end

local function updateRetentionRow(row, record)
    local cohort = record.cohorts and record.cohorts[selectedCohort] or {}
    row.recruiter:SetText(record.recruiter or GP.L["Unknown"])
    row.cells[1]:SetText(tostring(cohort.tracked or 0))
    row.cells[2]:SetText(tostring(cohort.retained or 0))
    row.cells[3]:SetText(tostring(cohort.left or 0))
    row.cells[4]:SetText(tostring(cohort.rejoined or 0))
    row.cells[5]:SetText(tostring(cohort.tooNew or 0))
    row.cells[6]:SetText(pctText(cohort))
    row.cells[6]:SetTextColor(unpack(cohort.retentionPct and Theme.color.success or Theme.color.textSecondary))
end

local function updateOverview(summary)
    if not frame or not frame.overview then return end
    local overview = summary.overview or {}
    local vitality = overview.vitality or {}
    updateMetricBar(frame.overview.vitalityBars.active, vitality.activePct, string.format(GP.L["%d%%"], vitality.activePct or 0))
    updateMetricBar(frame.overview.vitalityBars.retention, vitality.retentionPct, string.format(GP.L["%d%%"], vitality.retentionPct or 0))
    updateMetricBar(frame.overview.vitalityBars.growth, vitality.growthPct, string.format(GP.L["%d%%"], vitality.growthPct or 0))
    updateMetricBar(frame.overview.vitalityBars.engagement, vitality.engagementPct, string.format(GP.L["%d%%"], vitality.engagementPct or 0))
    frame.overview.score:SetText(string.format(GP.L["%d / 100"], vitality.score or 0))
    frame.overview.vitalityNote:SetText(string.format(GP.L["%d of %d main groups active in the configured active window."], vitality.active or 0, vitality.total or 0))

    local total = vitality.total or 0
    local inactivityReview = 0
    for _, band in ipairs(overview.retentionRisk or {}) do
        if band.key == "atRisk" or band.key == "gone" then
            inactivityReview = inactivityReview + (tonumber(band.count) or 0)
        end
    end
    frame.overview.riskSummary:SetText(string.format(GP.L["%d main group(s) need inactivity review."], inactivityReview))
    for i, row in ipairs(frame.overview.riskRows or {}) do
        updateRiskRow(row, (overview.retentionRisk or {})[i] or {}, total)
    end

    local composition = overview.rosterComposition or {}
    local maxTotal = 0
    for _, record in ipairs(composition) do
        if (record.total or 0) > maxTotal then maxTotal = record.total or 0 end
    end
    for i, row in ipairs(frame.overview.classRows or {}) do
        local record = composition[i]
        row:SetShown(record ~= nil)
        if record then updateCompositionRow(row, record, maxTotal) end
    end

    local mythic = overview.mythicRatings or {}
    frame.overview.mythicSummary:SetText(string.format(GP.L["Average Rating: %d    Rated Players: %d"], mythic.average or 0, mythic.rated or 0))
    local maxBucket = 0
    for _, bucket in ipairs(mythic.buckets or {}) do
        if (bucket.count or 0) > maxBucket then maxBucket = bucket.count or 0 end
    end
    for i, row in ipairs(frame.overview.mythicRows or {}) do
        local bucket = (mythic.buckets or {})[i]
        row:SetShown(bucket ~= nil)
        if bucket then
            row.bar.label:SetText(bucket.label or "")
            updateMetricBar(row.bar, maxBucket > 0 and ((bucket.count or 0) / maxBucket) * 100 or 0, tostring(bucket.count or 0))
        end
    end
end

local function updateButtons()
    for _, button in ipairs(frame.viewButtons or {}) do
        setButtonSelected(button, button.key == activeView)
    end
    for _, button in ipairs(frame.filterButtons or {}) do
        setButtonSelected(button, button.key == activeFilter)
    end
    for _, button in ipairs(frame.cohortButtons or {}) do
        setButtonSelected(button, button.days == selectedCohort)
    end
    for _, button in ipairs(frame.recruitmentDateButtons or {}) do
        setButtonSelected(button, button.key == recruitmentDateFilter)
    end
    for _, button in ipairs(frame.recruitmentTypeButtons or {}) do
        setButtonSelected(button, button.key == recruitmentTypeFilter)
    end
end

local function countRiskBuckets(summary)
    local risk = 0
    local bands = summary and summary.overview and summary.overview.retentionRisk or {}
    for _, band in ipairs(bands) do
        if band.key == "atRisk" or band.key == "gone" then
            risk = risk + (tonumber(band.count) or 0)
        end
    end
    return risk
end

local function applyRefreshResults(summary, analyticsSummary)
    if not frame then return end
    analyticsSummary = analyticsSummary or {}
    local totals, today = analyticsSummary.totals or {}, analyticsSummary.today or {}
    frame.recruitmentTodayText:SetText(buildMetricBlock(today))
    frame.recruitmentLifetimeText:SetText(buildMetricBlock(totals))
    if activeView == "recruitment" then
        local todayCandidates = metricValue(today, "candidatesFound")
        local lifetimeCandidates = metricValue(totals, "candidatesFound")
        local todayContacted = metricValue(today, "executorContactedCandidates")
        local lifetimeContacted = metricValue(totals, "executorContactedCandidates")
        local todayAccepted = metricValue(today, "pendingAccepted")
        local lifetimeAccepted = metricValue(totals, "pendingAccepted")
        local openPending = math.max(0, metricValue(totals, "pendingCreated") - metricValue(totals, "pendingResolved"))
        setCardTitle(frame.cards.attention, GP.L["Candidates"])
        setCard(frame.cards.attention, tostring(todayCandidates),
            string.format(GP.L["%d lifetime; %s contacted"], lifetimeCandidates, pct(lifetimeContacted, lifetimeCandidates)))
        setCardTitle(frame.cards.hygiene, GP.L["Contacted"])
        setCard(frame.cards.hygiene, tostring(todayContacted),
            string.format(GP.L["%d lifetime; %d invite(s)"], lifetimeContacted, metricValue(totals, "invitesSent")))
        setCardTitle(frame.cards.retention, GP.L["Accepted"])
        setCard(frame.cards.retention, tostring(todayAccepted),
            string.format(GP.L["%d lifetime; %s conversion"], lifetimeAccepted, pct(lifetimeAccepted, lifetimeContacted)),
            lifetimeAccepted > 0 and Theme.color.success or Theme.color.textPrimary)
        setCardTitle(frame.cards.extra, GP.L["Open Pending"])
        setCard(frame.cards.extra, tostring(openPending),
            string.format(GP.L["%d created; %d resolved"], metricValue(totals, "pendingCreated"), metricValue(totals, "pendingResolved")),
            openPending > 0 and Theme.color.warning or Theme.color.textPrimary)
        setCardAction(frame.cards.attention, lifetimeCandidates > 0 and function() showRecruitmentActivity("all") end or nil)
        setCardAction(frame.cards.hygiene, lifetimeContacted > 0 and function() showRecruitmentActivity("executor") end or nil)
        setCardAction(frame.cards.retention, lifetimeAccepted > 0 and function() showRecruitmentActivity("outcome") end or nil)
        setCardAction(frame.cards.extra, openPending > 0 and showPendingRecruitment or nil)
    else
        setCardTitle(frame.cards.attention, GP.L["Attention Items"])
        setCard(frame.cards.attention, summary.cards.attention,
            string.format(GP.L["%d shown"], #(summary.rows or {})),
            (summary.cards.attention or 0) > 0 and Theme.color.warning or Theme.color.success)
        local riskCount = countRiskBuckets(summary)
        local mythic = summary.overview and summary.overview.mythicRatings or {}
        setCardTitle(frame.cards.hygiene, GP.L["New Member"])
        setCard(frame.cards.hygiene, tostring(summary.cards.newMember or 0), GP.L["Required promotion review"])
        setCardTitle(frame.cards.retention, GP.L["At Risk Members"])
        setCard(frame.cards.retention, tostring(riskCount), GP.L["At risk + gone offline"],
            riskCount > 0 and Theme.color.warning or Theme.color.success)
        setCardTitle(frame.cards.extra, GP.L["Rated M+"])
        setCard(frame.cards.extra, tostring(mythic.rated or 0),
            string.format(GP.L["%d rated / %d total"], mythic.rated or 0, mythic.total or 0),
            (mythic.rated or 0) > 0 and Theme.color.info or Theme.color.textPrimary)
        setCardAction(frame.cards.attention, (summary.cards.attention or 0) > 0 and showAllAttention or nil)
        setCardAction(frame.cards.hygiene, (summary.cards.newMember or 0) > 0 and showNewMemberAttention or nil)
        setCardAction(frame.cards.retention, riskCount > 0 and showActivityAttention or nil)
        setCardAction(frame.cards.extra, nil)
    end
    updateOverview(summary)

    frame.updatedText:SetText(string.format(GP.L["Last updated: %s"], formatDateTime(time())))
    updateButtons()
    local visibleTotal
    visibleRows, visibleTotal = buildAttentionRows(summary)
    frame.attentionSummary:SetText(string.format(GP.L["Showing %d of %d attention item(s)"], #visibleRows, visibleTotal or 0))
    attentionList:SetData(visibleRows, false)
    if selectedRow then
        local stillVisible
        for _, rowData in ipairs(visibleRows) do
            if rowData.id == selectedRow.id then
                stillVisible = rowData
                break
            end
        end
        selectRow(stillVisible)
    elseif #visibleRows > 0 then
        selectRow(visibleRows[1])
    else
        selectRow(nil)
    end

    local retention = summary.retention or {}
    visibleRecruiters = retention.recruiters or {}
    retentionList:SetData(visibleRecruiters, true)
    frame.retentionSummary:SetText(GP.L["Based on local Event Log history. Very recent recruits are shown but excluded from retention percentage until 14 days old."])
    visibleRecruitmentRecords = buildVisibleRecruitmentRecords(analyticsSummary)
    recruitmentActivityList:SetData(visibleRecruitmentRecords, false)
    frame.recruitmentSessionSummary:SetText(string.format(GP.L["Showing %d of %d recruitment record(s)"], #visibleRecruitmentRecords, recruitmentRecordTotal(analyticsSummary)))
end

function GuildHealthTab:Refresh()
    if not frame then return end
    lastRefreshAt = GetTime and GetTime() or 0
    refreshPending = false
    refreshToken = refreshToken + 1
    local token = refreshToken

    local GuildHealth = GP:GetModule("GuildHealth")
    local Recruitment = GP:GetModule("Recruitment")
    local summary
    local analyticsSummary

    GP:RunFrameSteps("GuildHealthTab:Refresh", {
        function()
            if token ~= refreshToken or not frame or not frame:IsShown() then return false end
            summary = GuildHealth:GetSummary(nil, { cohortDays = selectedCohort })
        end,
        function()
            if token ~= refreshToken or not frame or not frame:IsShown() then return false end
            analyticsSummary = Recruitment:GetAnalyticsSummary(nil, 100)
        end,
        function()
            if token ~= refreshToken or not frame or not frame:IsShown() then return false end
            applyRefreshResults(summary, analyticsSummary)
        end,
    })
end

local function requestRefresh()
    if not frame or not frame:IsShown() then return end
    local now = GetTime and GetTime() or 0
    local elapsed = now - lastRefreshAt
    if elapsed >= REFRESH_DEBOUNCE_SECONDS then
        GuildHealthTab:Refresh()
        return
    end

    refreshPending = true
    if refreshScheduled then return end
    refreshScheduled = true
    C_Timer.After(REFRESH_DEBOUNCE_SECONDS - elapsed, function()
        refreshScheduled = false
        if refreshPending and frame and frame:IsShown() then
            GuildHealthTab:Refresh()
        end
    end)
end

function addText(parent, font, text, point)
    local fs = parent:CreateFontString(nil, "ARTWORK")
    fs:SetFontObject(font)
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    if point then fs:SetPoint(unpack(point)) end
    return fs
end

local function buildRetentionHeader(parent, anchor)
    local header = CreateFrame("Frame", nil, parent)
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
    header:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    header:SetHeight(18)

    local labels = { GP.L["Recruiter"], GP.L["Tracked"], GP.L["Still In"], GP.L["Left"], GP.L["Rejoined"], GP.L["Too New"], GP.L["Retention"] }
    local widths = { COL.recruiter, COL.small, COL.small, COL.small, COL.small, COL.small, COL.pct }
    local previous
    for i, label in ipairs(labels) do
        local text = header:CreateFontString(nil, "ARTWORK")
        text:SetFontObject(Theme.font.small)
        text:SetJustifyH("LEFT")
        text:SetText(label)
        text:SetWidth(widths[i])
        if previous then
            text:SetPoint("LEFT", previous, "RIGHT", COL.pad, 0)
        else
            text:SetPoint("LEFT", COL.pad, 0)
        end
        previous = text
    end
    return header
end

function GuildHealthTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    frame.cards = {}

    local heading = addText(frame, Theme.font.title, L["Guild Health"], { "TOPLEFT" })
    local info = addText(frame, Theme.font.muted, L["Officer attention signals from existing Guild Paragon data."], { "TOPLEFT", heading, "BOTTOMLEFT", 0, -8 })
    info:SetWidth(720)

    frame.updatedText = addText(frame, Theme.font.small, "", { "TOPRIGHT", frame, "TOPRIGHT", 0, -4 })
    frame.updatedText:SetJustifyH("RIGHT")

    local refreshButton = Theme:CreateButton(frame, L["Refresh"])
    refreshButton:SetPoint("TOPRIGHT", frame.updatedText, "BOTTOMRIGHT", 0, -8)
    refreshButton:SetScript("OnClick", function() GuildHealthTab:Refresh() end)

    local cardsRow = CreateFrame("Frame", nil, frame)
    cardsRow:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -16)
    cardsRow:SetPoint("RIGHT", 0, 0)
    cardsRow:SetHeight(70)

    frame.cards.attention = createCard(cardsRow, L["Attention Items"])
    frame.cards.attention:SetPoint("TOPLEFT")
    frame.cards.attention:SetWidth(250)

    frame.cards.hygiene = createCard(cardsRow, L["New Member"])
    frame.cards.hygiene:SetPoint("LEFT", frame.cards.attention, "RIGHT", Theme.layout.gutter, 0)
    frame.cards.hygiene:SetWidth(250)

    frame.cards.retention = createCard(cardsRow, L["At Risk Members"])
    frame.cards.retention:SetPoint("LEFT", frame.cards.hygiene, "RIGHT", Theme.layout.gutter, 0)
    frame.cards.retention:SetWidth(250)

    frame.cards.extra = createCard(cardsRow, L["Rated M+"])
    frame.cards.extra:SetPoint("LEFT", frame.cards.retention, "RIGHT", Theme.layout.gutter, 0)
    frame.cards.extra:SetPoint("RIGHT")

    local viewBar = CreateFrame("Frame", nil, frame)
    viewBar:SetPoint("TOPLEFT", cardsRow, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    viewBar:SetPoint("RIGHT", 0, 0)
    viewBar:SetHeight(28)

    local viewContent = CreateFrame("Frame", nil, frame)
    viewContent:SetPoint("TOPLEFT", viewBar, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    viewContent:SetPoint("BOTTOMRIGHT")
    frame.viewPages = {}
    frame.viewButtons = {}

    local function addViewButton(key, label)
        local button = createFilterButton(viewBar, label, function() selectView(key) end)
        button.key = key
        button:SetWidth(110)
        if #frame.viewButtons == 0 then
            button:SetPoint("LEFT")
        else
            button:SetPoint("LEFT", frame.viewButtons[#frame.viewButtons], "RIGHT", 8, 0)
        end
        table.insert(frame.viewButtons, button)
        return button
    end

    addViewButton("overview", L["Overview"])
    addViewButton("attention", L["Attention"])
    addViewButton("recruitment", L["Recruitment"])
    addViewButton("exports", L["Exports"])

    local overviewPage = CreateFrame("Frame", nil, viewContent)
    overviewPage:SetAllPoints()
    frame.viewPages.overview = overviewPage
    local attentionPage = CreateFrame("Frame", nil, viewContent)
    attentionPage:SetAllPoints()
    frame.viewPages.attention = attentionPage
    local recruitmentPage = CreateFrame("Frame", nil, viewContent)
    recruitmentPage:SetAllPoints()
    frame.viewPages.recruitment = recruitmentPage
    local exportsPage = CreateFrame("Frame", nil, viewContent)
    exportsPage:SetAllPoints()
    frame.viewPages.exports = exportsPage
    if GP.UI.ExportStatsTab and GP.UI.ExportStatsTab.Build then
        local exportsContent = GP.UI.ExportStatsTab:Build(exportsPage)
        exportsPage.OnSelected = function()
            if exportsContent and exportsContent.OnSelected then
                exportsContent:OnSelected()
            end
        end
    end

    frame.overview = { vitalityBars = {}, riskRows = {}, classRows = {}, mythicRows = {} }
    local mythicPanel = createOverviewPanel(overviewPage, L["M+ Ratings"])
    mythicPanel:SetPoint("TOPLEFT")
    mythicPanel:SetSize(560, 260)
    frame.overview.mythicSummary = addText(mythicPanel, Theme.font.body, "", { "TOPLEFT", mythicPanel.title, "BOTTOMLEFT", 0, -12 })
    local mythicAnchor = frame.overview.mythicSummary
    for i = 1, MYTHIC_BUCKET_ROWS do
        local row = createCompositionRow(mythicPanel)
        row:SetPoint("TOPLEFT", mythicAnchor, "BOTTOMLEFT", 0, i == 1 and -16 or -7)
        row:SetPoint("RIGHT", -Theme.layout.gutter, 0)
        frame.overview.mythicRows[i] = row
        mythicAnchor = row
    end

    local riskPanel = createOverviewPanel(overviewPage, L["Retention Risk"])
    riskPanel:SetPoint("TOPLEFT", mythicPanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    riskPanel:SetPoint("BOTTOMLEFT")
    riskPanel:SetWidth(560)
    frame.overview.riskSummary = addText(riskPanel, Theme.font.small, "", { "TOPLEFT", riskPanel.title, "BOTTOMLEFT", 0, -8 })
    local riskAnchor = frame.overview.riskSummary
    for i = 1, 6 do
        local row = createRiskRow(riskPanel)
        row:SetPoint("TOPLEFT", riskAnchor, "BOTTOMLEFT", 0, i == 1 and -10 or -6)
        row:SetPoint("RIGHT", -Theme.layout.gutter, 0)
        frame.overview.riskRows[i] = row
        riskAnchor = row
    end

    local compositionPanel = createOverviewPanel(overviewPage, L["Roster Composition (Active / Total)"])
    compositionPanel:SetPoint("TOPLEFT", mythicPanel, "TOPRIGHT", Theme.layout.gutter, 0)
    compositionPanel:SetPoint("TOPRIGHT")
    compositionPanel:SetHeight(370)
    local classAnchor = compositionPanel.title
    for i = 1, MAX_CLASS_ROWS do
        local row = createCompositionRow(compositionPanel)
        row:SetPoint("TOPLEFT", classAnchor, "BOTTOMLEFT", 0, i == 1 and -12 or -4)
        row:SetPoint("RIGHT", -Theme.layout.gutter, 0)
        frame.overview.classRows[i] = row
        classAnchor = row
    end

    local vitalityPanel = createOverviewPanel(overviewPage, L["Guild Vitality"])
    vitalityPanel:SetPoint("TOPLEFT", compositionPanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    vitalityPanel:SetPoint("BOTTOMRIGHT")
    frame.overview.vitalityBars.active = createMetricBar(vitalityPanel, L["Active"], "info")
    frame.overview.vitalityBars.active:SetPoint("TOPLEFT", vitalityPanel.title, "BOTTOMLEFT", 0, -14)
    frame.overview.vitalityBars.retention = createMetricBar(vitalityPanel, L["Retention"], "info")
    frame.overview.vitalityBars.retention:SetPoint("TOPLEFT", frame.overview.vitalityBars.active, "BOTTOMLEFT", 0, -8)
    frame.overview.vitalityBars.growth = createMetricBar(vitalityPanel, L["Growth Trend"], "info")
    frame.overview.vitalityBars.growth:SetPoint("TOPLEFT", frame.overview.vitalityBars.retention, "BOTTOMLEFT", 0, -8)
    frame.overview.vitalityBars.engagement = createMetricBar(vitalityPanel, L["Engagement"], "info")
    frame.overview.vitalityBars.engagement:SetPoint("TOPLEFT", frame.overview.vitalityBars.growth, "BOTTOMLEFT", 0, -8)
    for _, bar in pairs(frame.overview.vitalityBars) do
        bar:Hide()
    end
    frame.overview.score = addText(vitalityPanel, Theme.font.title, "", { "CENTER", vitalityPanel, "CENTER", 0, 10 })
    frame.overview.score:SetFont(STANDARD_TEXT_FONT, 28, "")
    frame.overview.score:SetJustifyH("CENTER")
    frame.overview.vitalityNote = addText(vitalityPanel, Theme.font.small, "", { "BOTTOM", vitalityPanel, "BOTTOM", 0, 14 })
    frame.overview.vitalityNote:SetJustifyH("CENTER")

    local attentionPanel = Theme:CreatePanel(attentionPage, "panel", "border")
    attentionPanel:SetPoint("TOPLEFT")
    attentionPanel:SetPoint("BOTTOMLEFT", 0, 0)
    attentionPanel:SetWidth(560)

    local attentionTitle = addText(attentionPanel, Theme.font.heading, L["Attention List"], { "TOPLEFT", attentionPanel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    frame.attentionSummary = addText(attentionPanel, Theme.font.small, "", { "TOPRIGHT", attentionPanel, "TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter - 2 })
    frame.attentionSummary:SetJustifyH("RIGHT")

    frame.filterButtons = {}
    local allButton = createFilterButton(attentionPanel, L["All"], function()
        activeFilter = "all"
        GuildHealthTab:Refresh()
    end)
    allButton.key = "all"
    allButton:SetWidth(72)
    allButton:SetPoint("TOPLEFT", attentionTitle, "BOTTOMLEFT", 0, -10)
    table.insert(frame.filterButtons, allButton)

    local cleanupButton = createFilterButton(attentionPanel, L["Cleanup"], function()
        activeFilter = "cleanup"
        GuildHealthTab:Refresh()
    end)
    cleanupButton.key = "cleanup"
    cleanupButton:SetWidth(88)
    cleanupButton:SetPoint("LEFT", allButton, "RIGHT", 8, 0)
    table.insert(frame.filterButtons, cleanupButton)

    local activityButton = createFilterButton(attentionPanel, L["Activity"], function()
        activeFilter = "activity"
        GuildHealthTab:Refresh()
    end)
    activityButton.key = "activity"
    activityButton:SetWidth(88)
    activityButton:SetPoint("LEFT", cleanupButton, "RIGHT", 8, 0)
    table.insert(frame.filterButtons, activityButton)

    local newMembersButton = createFilterButton(attentionPanel, L["New Members"], function()
        activeFilter = "newmember"
        GuildHealthTab:Refresh()
    end)
    newMembersButton.key = "newmember"
    newMembersButton:SetWidth(118)
    newMembersButton:SetPoint("LEFT", activityButton, "RIGHT", 8, 0)
    table.insert(frame.filterButtons, newMembersButton)

    local header = CreateFrame("Frame", nil, attentionPanel)
    header:SetPoint("TOPLEFT", allButton, "BOTTOMLEFT", 0, -12)
    header:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    header:SetHeight(18)

    addText(header, Theme.font.small, L["Type"], { "LEFT", header, "LEFT", COL.pad + COL.status, 0 }):SetWidth(COL.category)
    local signalHeader = addText(header, Theme.font.small, L["Signal"], { "LEFT", header, "LEFT", COL.pad + COL.status + COL.category + COL.pad, 0 })
    signalHeader:SetWidth(COL.title)
    addText(header, Theme.font.small, L["Reason"], { "LEFT", signalHeader, "RIGHT", COL.pad, 0 })

    local listPanel = Theme:CreatePanel(attentionPanel, "panel", "border")
    listPanel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    listPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    attentionList = ScrollList:New(listPanel, ROW_HEIGHT, createAttentionRow)
    attentionList:SetUpdateRow(updateAttentionRow)

    local rightPanel = CreateFrame("Frame", nil, attentionPage)
    rightPanel:SetPoint("TOPLEFT", attentionPanel, "TOPRIGHT", Theme.layout.gutter, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)

    local detailPanel = Theme:CreatePanel(rightPanel, "panel", "border")
    detailPanel:SetPoint("TOPLEFT")
    detailPanel:SetPoint("TOPRIGHT")
    detailPanel:SetHeight(190)

    frame.detailTitle = addText(detailPanel, Theme.font.heading, "", { "TOPLEFT", detailPanel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    frame.detailBody = addText(detailPanel, Theme.font.body, "", { "TOPLEFT", frame.detailTitle, "BOTTOMLEFT", 0, -10 })
    frame.detailBody:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.detailBody:SetJustifyV("TOP")
    frame.detailBody:SetHeight(92)

    frame.detailActions = {}
    frame.detailActions.roster = Theme:CreateButton(detailPanel, L["Open in Roster"])
    frame.detailActions.roster:SetPoint("BOTTOMLEFT", detailPanel, "BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    frame.detailActions.macro = Theme:CreateButton(detailPanel, L["Macro Rules"])
    frame.detailActions.macro:SetPoint("LEFT", frame.detailActions.roster, "RIGHT", 8, 0)
    frame.detailActions.promote = Theme:CreateButton(detailPanel, L["Promote"])
    frame.detailActions.promote:SetPoint("LEFT", frame.detailActions.macro, "RIGHT", 8, 0)
    frame.detailActions.ignoreKick = Theme:CreateButton(detailPanel, L["Do Not Kick"])
    frame.detailActions.ignoreKick:SetPoint("LEFT", frame.detailActions.macro, "RIGHT", 8, 0)
    frame.detailActions.ignorePromote = Theme:CreateButton(detailPanel, L["Do Not Promote"])
    frame.detailActions.ignorePromote:SetPoint("LEFT", frame.detailActions.promote, "RIGHT", 8, 0)

    local contextPanel = Theme:CreatePanel(rightPanel, "panel", "border")
    contextPanel:SetPoint("TOPLEFT", detailPanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    contextPanel:SetPoint("BOTTOMRIGHT")

    frame.detailContextTitle = addText(contextPanel, Theme.font.heading, "", { "TOPLEFT", contextPanel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    frame.detailContextBody = addText(contextPanel, Theme.font.body, "", { "TOPLEFT", frame.detailContextTitle, "BOTTOMLEFT", 0, -10 })
    frame.detailContextBody:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.detailContextBody:SetJustifyV("TOP")
    frame.detailContextBody:SetHeight(420)

    local metricsPanel = Theme:CreatePanel(recruitmentPage, "panel", "border")
    metricsPanel:SetPoint("TOPLEFT")
    metricsPanel:SetSize(250, 355)

    local todayHeading = addText(metricsPanel, Theme.font.heading, L["Today"], { "TOPLEFT", metricsPanel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    frame.recruitmentTodayText = addText(metricsPanel, Theme.font.body, "", { "TOPLEFT", todayHeading, "BOTTOMLEFT", 0, -6 })
    frame.recruitmentTodayText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.recruitmentTodayText:SetJustifyV("TOP")

    local lifetimeHeading = addText(metricsPanel, Theme.font.heading, L["Lifetime"], { "TOPLEFT", metricsPanel, "TOPLEFT", Theme.layout.gutter, -176 })
    frame.recruitmentLifetimeText = addText(metricsPanel, Theme.font.body, "", { "TOPLEFT", lifetimeHeading, "BOTTOMLEFT", 0, -6 })
    frame.recruitmentLifetimeText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.recruitmentLifetimeText:SetJustifyV("TOP")

    local sessionsPanel = Theme:CreatePanel(recruitmentPage, "panel", "border")
    sessionsPanel:SetPoint("TOPLEFT", metricsPanel, "TOPRIGHT", Theme.layout.gutter, 0)
    sessionsPanel:SetPoint("RIGHT")
    sessionsPanel:SetHeight(355)

    local sessionTitle = addText(sessionsPanel, Theme.font.heading, L["Recruitment Activity"], { "TOPLEFT", sessionsPanel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    frame.recruitmentSessionSummary = addText(sessionsPanel, Theme.font.small, "", { "TOPRIGHT", sessionsPanel, "TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter - 2 })
    frame.recruitmentSessionSummary:SetJustifyH("RIGHT")

    frame.recruitmentDateButtons = {}
    local previous
    for _, def in ipairs(ANALYTICS_DATE_FILTERS) do
        local button = createFilterButton(sessionsPanel, L[def.label], function()
            recruitmentDateFilter = def.key
            GuildHealthTab:Refresh()
        end)
        button.key = def.key
        button:SetWidth(def.key == "today" and 72 or 78)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("TOPLEFT", sessionTitle, "BOTTOMLEFT", 0, -10)
        end
        table.insert(frame.recruitmentDateButtons, button)
        previous = button
    end

    frame.recruitmentTypeButtons = {}
    previous = nil
    for _, def in ipairs(ANALYTICS_TYPE_FILTERS) do
        local button = createFilterButton(sessionsPanel, L[def.label], function()
            recruitmentTypeFilter = def.key
            GuildHealthTab:Refresh()
        end)
        button.key = def.key
        button:SetWidth(def.key == "executor" and 86 or 78)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("TOPLEFT", frame.recruitmentDateButtons[1], "BOTTOMLEFT", 0, -8)
        end
        table.insert(frame.recruitmentTypeButtons, button)
        previous = button
    end

    local exportButton = Theme:CreateButton(sessionsPanel, L["Export Visible"])
    exportButton:SetPoint("RIGHT", sessionsPanel, "RIGHT", -Theme.layout.gutter, 0)
    exportButton:SetPoint("TOP", frame.recruitmentTypeButtons[1], "TOP", 0, 0)
    exportButton:SetScript("OnClick", function()
        local exportText = buildVisibleRecruitmentExport()
        StaticPopup_Show(EXPORT_POPUP, exportText, nil, exportText)
    end)

    local recruitmentHeader = CreateFrame("Frame", nil, sessionsPanel)
    recruitmentHeader:SetPoint("TOPLEFT", frame.recruitmentTypeButtons[1], "BOTTOMLEFT", 0, -14)
    recruitmentHeader:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    recruitmentHeader:SetHeight(18)
    addText(recruitmentHeader, Theme.font.small, L["Time"], { "LEFT", recruitmentHeader, "LEFT", COL.pad, 0 }):SetWidth(118)
    local typeHeader = addText(recruitmentHeader, Theme.font.small, L["Type"], { "LEFT", recruitmentHeader, "LEFT", COL.pad + 126, 0 })
    typeHeader:SetWidth(78)
    local statusHeader = addText(recruitmentHeader, Theme.font.small, L["Status"], { "LEFT", typeHeader, "RIGHT", COL.pad, 0 })
    statusHeader:SetWidth(88)
    addText(recruitmentHeader, Theme.font.small, L["Details"], { "LEFT", statusHeader, "RIGHT", COL.pad, 0 })

    local recruitmentListPanel = Theme:CreatePanel(sessionsPanel, "panel", "border")
    recruitmentListPanel:SetPoint("TOPLEFT", recruitmentHeader, "BOTTOMLEFT", 0, -4)
    recruitmentListPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    recruitmentActivityList = ScrollList:New(recruitmentListPanel, RECRUITMENT_ROW_HEIGHT, createRecruitmentActivityRow)
    recruitmentActivityList:SetUpdateRow(updateRecruitmentActivityRow)

    local retentionPanel = Theme:CreatePanel(recruitmentPage, "panel", "border")
    retentionPanel:SetPoint("TOPLEFT", metricsPanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    retentionPanel:SetPoint("BOTTOMRIGHT")

    local retentionTitle = addText(retentionPanel, Theme.font.heading, L["Recruiter Retention"], { "TOPLEFT", retentionPanel, "TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter })
    frame.retentionSummary = addText(retentionPanel, Theme.font.small, "", { "TOPLEFT", retentionTitle, "BOTTOMLEFT", 0, -8 })
    frame.retentionSummary:SetPoint("RIGHT", retentionPanel, "RIGHT", -Theme.layout.gutter, 0)

    frame.cohortButtons = {}
    local previous
    for _, days in ipairs({ 30, 60, 90 }) do
        local button = createFilterButton(retentionPanel, string.format(L["%d Days"], days), function()
            selectedCohort = days
            GuildHealthTab:Refresh()
        end)
        button.days = days
        button:SetWidth(76)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("TOPLEFT", frame.retentionSummary, "BOTTOMLEFT", 0, -10)
        end
        table.insert(frame.cohortButtons, button)
        previous = button
    end

    local retentionHeader = buildRetentionHeader(retentionPanel, frame.cohortButtons[1])
    local retentionListPanel = Theme:CreatePanel(retentionPanel, "panel", "border")
    retentionListPanel:SetPoint("TOPLEFT", retentionHeader, "BOTTOMLEFT", 0, -4)
    retentionListPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    retentionList = ScrollList:New(retentionListPanel, RETENTION_ROW_HEIGHT, createRetentionRow)
    retentionList:SetUpdateRow(updateRetentionRow)

    local function debouncedRefresh() requestRefresh() end
    GuildHealthTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_LogEntryAdded", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_AltsChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_NicknamesChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_CustomNotesChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_JoinDateChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_BirthdayChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_LabelsChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_MacroIgnoresChanged", debouncedRefresh)
    GuildHealthTab:RegisterMessage("GuildParagon_GuildHealthSettingsChanged", debouncedRefresh)

    frame.OnSelected = function()
        GuildHealthTab:Refresh()
    end
    frame.OnDeselected = function()
        refreshPending = false
    end

    selectRow(nil)
    selectView(activeView)
    self:Refresh()
    return frame
end
