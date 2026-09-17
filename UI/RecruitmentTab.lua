-- Guild Paragon — Recruitment tab
--
-- Recruitment workflow surface: review scanner, candidate queue, and manual executor.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.RecruitmentTab = GP.UI.RecruitmentTab or {}
local RecruitmentTab = GP.UI.RecruitmentTab

-- AceEvent-3.0's
-- RegisterMessage keys its registry as events[eventname][self] — see
LibStub("AceEvent-3.0"):Embed(RecruitmentTab)

local SCANNER_ROW_HEIGHT = 24

local frame
local refreshDirty = false
local candidateList, queueList, skippedList, candidateSearchBox, queueSearchBox, skippedSearchBox

local function truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then
        return text:sub(1, maxChars) .. "…"
    end
    return text
end

local function setPanelTitle(parent, text)
    local title = parent:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.heading)
    title:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    title:SetText(text)
    return title
end

local function classColor(classFile)
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color then return color.r, color.g, color.b, 1 end
    return unpack(Theme.color.textPrimary)
end

local function setButtonEnabled(button, enabled)
    if not button then return end
    button:SetEnabled(enabled and true or false)
    button:SetAlpha(enabled and 1 or 0.45)
    if button.text then
        button.text:SetTextColor(unpack(enabled and Theme.color.textPrimary or Theme.color.textDisabled))
    end
    button:SetBackdropBorderColor(unpack(enabled and Theme.color.accentDim or Theme.color.border))
end

local function setModeButtonSelected(button, selected)
    if not button then return end
    button.selected = selected and true or false
    button:SetBackdropColor(unpack(selected and Theme.color.panelRaised or Theme.color.panel))
    button:SetBackdropBorderColor(unpack(selected and Theme.color.accent or Theme.color.accentDim))
    if button.text then
        button.text:SetTextColor(unpack(selected and Theme.color.accent or Theme.color.textPrimary))
    end
end

local function buildStatusPanel(parent, topAnchor)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel:SetPoint("TOPRIGHT", -Theme.layout.gutter, -56)
    panel:SetSize(300, 118)

    setPanelTitle(panel, GP.L["Execution Status"])

    frame.statusText = panel:CreateFontString(nil, "ARTWORK")
    frame.statusText:SetFontObject(Theme.font.body)
    frame.statusText:SetPoint("TOPLEFT", Theme.layout.gutter, -38)
    frame.statusText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.statusText:SetHeight(70)
    frame.statusText:SetJustifyH("LEFT")
    frame.statusText:SetText(string.format(GP.L["Scanner: idle\nQueue: %d queued\n%s\nStart a scan to collect candidates."], 0, GP.L["Executor: ready"]))
    return panel
end

local function buildDoNotInviteSummaryPanel(parent, statusPanel)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel:SetPoint("TOPRIGHT", statusPanel, "TOPLEFT", -Theme.layout.gutter, 0)
    panel:SetSize(190, 118)

    local title = setPanelTitle(panel, GP.L["Do Not Invite"])

    frame.doNotInviteCountText = panel:CreateFontString(nil, "ARTWORK")
    frame.doNotInviteCountText:SetFontObject(Theme.font.body)
    frame.doNotInviteCountText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    frame.doNotInviteCountText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.doNotInviteCountText:SetJustifyH("LEFT")

    local reviewButton = Theme:CreateButton(panel, GP.L["Review List"])
    reviewButton:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    reviewButton:SetScript("OnClick", function()
        GP.UI.MainWindow:SelectTab("bans")
    end)
    return panel
end

-- Compact, read-only card — full template create/edit/delete/switch now
-- lives in Settings → Recruitment → Message Templates (see UI/Settings.lua)
local function buildActiveFilterPanel(parent, rightPanel)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel:SetPoint("TOPRIGHT", rightPanel, "TOPLEFT", -Theme.layout.gutter, 0)
    panel:SetSize(250, 118)

    local title = setPanelTitle(panel, GP.L["Active Filter"])

    frame.activeFilterTitle = panel:CreateFontString(nil, "ARTWORK")
    frame.activeFilterTitle:SetFontObject(Theme.font.body)
    frame.activeFilterTitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    frame.activeFilterTitle:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.activeFilterTitle:SetJustifyH("LEFT")
    frame.activeFilterTitle:SetWordWrap(false)

    frame.filterLockedText = panel:CreateFontString(nil, "ARTWORK")
    frame.filterLockedText:SetFontObject(Theme.font.small)
    frame.filterLockedText:SetPoint("TOPLEFT", frame.activeFilterTitle, "BOTTOMLEFT", 0, -6)
    frame.filterLockedText:SetText(GP.L["Locked by guild master"])
    frame.filterLockedText:Hide()

    local manageButton = Theme:CreateButton(panel, GP.L["Manage Filters"])
    manageButton:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    manageButton:SetScript("OnClick", function()
        GP.UI.MainWindow:SelectTab("settings")
        if GP.UI.Settings.OpenRecruitmentPage then
            GP.UI.Settings:OpenRecruitmentPage("filters")
        end
    end)
    return panel
end

local function buildActiveMessagePanel(parent, filterPanel)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -56)
    panel:SetPoint("RIGHT", filterPanel, "LEFT", -Theme.layout.gutter, 0)
    panel:SetHeight(118)

    local title = setPanelTitle(panel, GP.L["Active Message"])

    frame.activeMessageTitle = panel:CreateFontString(nil, "ARTWORK")
    frame.activeMessageTitle:SetFontObject(Theme.font.body)
    frame.activeMessageTitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    frame.activeMessageTitle:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.activeMessageTitle:SetJustifyH("LEFT")
    frame.activeMessageTitle:SetWordWrap(false)

    frame.messageLockedText = panel:CreateFontString(nil, "ARTWORK")
    frame.messageLockedText:SetFontObject(Theme.font.small)
    frame.messageLockedText:SetPoint("TOPLEFT", frame.activeMessageTitle, "BOTTOMLEFT", 0, -6)
    frame.messageLockedText:SetText(GP.L["Locked by guild master"])
    frame.messageLockedText:Hide()

    local manageButton = Theme:CreateButton(panel, GP.L["Manage Templates"])
    manageButton:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    manageButton:SetScript("OnClick", function()
        GP.UI.MainWindow:SelectTab("settings")
        if GP.UI.Settings.OpenRecruitmentPage then
            GP.UI.Settings:OpenRecruitmentPage("messages")
        end
    end)
    return panel
end

local function createCandidateRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(110)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.level = row:CreateFontString(nil, "ARTWORK")
    row.level:SetFontObject(Theme.font.muted)
    row.level:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.level:SetWidth(34)
    row.level:SetJustifyH("LEFT")

    row.class = row:CreateFontString(nil, "ARTWORK")
    row.class:SetFontObject(Theme.font.muted)
    row.class:SetPoint("LEFT", row.level, "RIGHT", 8, 0)
    row.class:SetWidth(76)
    row.class:SetJustifyH("LEFT")
    row.class:SetWordWrap(false)

    row.zone = row:CreateFontString(nil, "ARTWORK")
    row.zone:SetFontObject(Theme.font.muted)
    row.zone:SetPoint("LEFT", row.class, "RIGHT", 8, 0)
    row.zone:SetPoint("RIGHT", -8, 0)
    row.zone:SetJustifyH("LEFT")
    row.zone:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        if self.record then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.record.fullName or self.record.name or "?")
            GameTooltip:AddLine(GP.L["Click to add this candidate to the queue."], 0.45, 0.9, 0.85)
            GameTooltip:AddLine(string.format("%s %s", self.record.raceName or GP.L["Unknown"], self.record.className or ""), 1, 1, 1)
            GameTooltip:AddLine(string.format(GP.L["Zone: %s"], self.record.zone or GP.L["Unknown"]), 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(0, 0, 0, 0)
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        if not self.record then return end
        local ok, err = GP:GetModule("Recruitment"):AddCandidateToQueue(self.record)
        if not ok and err then GP:Print(err) end
        RecruitmentTab:Refresh()
    end)
    return row
end

local function updateCandidateRow(row, record)
    row.record = record
    row.name:SetText(truncate(record.name or record.fullName or "?", 22))
    row.name:SetTextColor(classColor(record.classFile))
    row.level:SetText(record.level and tostring(record.level) or "?")
    row.class:SetText(truncate(record.className or record.classFile or "?", 14))
    row.zone:SetText(truncate(record.zone or GP.L["Unknown"], 34))
end

local function createQueuedRow(parent)
    local row = createCandidateRow(parent)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.name:SetWidth(104)
    row.level:SetWidth(28)
    row.class:SetWidth(68)
    row.zone:SetPoint("RIGHT", -8, 0)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        if self.record then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.record.fullName or self.record.name or "?")
            GameTooltip:AddLine(GP.L["Left-click to preview this queued candidate. Right-click to remove from the queue."], 0.45, 0.9, 0.85)
            GameTooltip:AddLine(string.format("%s %s", self.record.raceName or GP.L["Unknown"], self.record.className or ""), 1, 1, 1)
            GameTooltip:AddLine(string.format(GP.L["Zone: %s"], self.record.zone or GP.L["Unknown"]), 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        if self.record and self.record.selected then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
            self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self, button)
        if not self.record then return end
        local Recruitment = GP:GetModule("Recruitment")
        local ok, err
        if button == "RightButton" then
            ok, err = Recruitment:RemoveQueuedCandidate(self.record.id)
        else
            ok, err = Recruitment:SelectQueuedCandidate(self.record.id)
        end
        if not ok and err then GP:Print(err) end
        RecruitmentTab:Refresh()
    end)
    return row
end

local function updateQueuedRow(row, record)
    updateCandidateRow(row, record)
    if record.selected then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
        row:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

local function createSkippedRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:RegisterForClicks("LeftButtonUp")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(100)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.reason = row:CreateFontString(nil, "ARTWORK")
    row.reason:SetFontObject(Theme.font.muted)
    row.reason:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.reason:SetWidth(110)
    row.reason:SetJustifyH("LEFT")
    row.reason:SetWordWrap(false)

    row.zone = row:CreateFontString(nil, "ARTWORK")
    row.zone:SetFontObject(Theme.font.muted)
    row.zone:SetPoint("LEFT", row.reason, "RIGHT", 8, 0)
    row.zone:SetPoint("RIGHT", -8, 0)
    row.zone:SetJustifyH("LEFT")
    row.zone:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        if self.record then
            local Recruitment = GP:GetModule("Recruitment")
            local canQueuePendingInvite = Recruitment:CanBypassAntiSpamForPendingInvite(
                Recruitment:GetCurrentGuildKey(),
                self.record.fullName or self.record.name,
                "invite")
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.record.fullName or self.record.name or "?")
            GameTooltip:AddLine(string.format(GP.L["Skipped: %s"], self.record.reason or GP.L["Unknown"]), 1, 0.85, 0.45)
            if canQueuePendingInvite then
                GameTooltip:AddLine(GP.L["Click to add this candidate to the queue."], 0.45, 0.9, 0.85)
            end
            GameTooltip:AddLine(string.format(GP.L["Zone: %s"], self.record.zone or GP.L["Unknown"]), 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(0, 0, 0, 0)
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        if not self.record then return end
        local Recruitment = GP:GetModule("Recruitment")
        if not Recruitment:CanBypassAntiSpamForPendingInvite(
            Recruitment:GetCurrentGuildKey(),
            self.record.fullName or self.record.name,
            "invite") then
            GP:Print(string.format(GP.L["Skipped: %s"], self.record.reason or GP.L["Unknown"]))
            return
        end

        local ok, err = Recruitment:AddCandidateToQueue(self.record)
        if not ok and err then GP:Print(err) end
        RecruitmentTab:Refresh()
    end)
    return row
end

local function updateSkippedRow(row, record)
    row.record = record
    row.name:SetText(truncate(record.name or record.fullName or "?", 20))
    row.name:SetTextColor(classColor(record.classFile))
    row.reason:SetText(truncate(record.reason or GP.L["Skipped."], 22))
    row.zone:SetText(truncate(record.zone or GP.L["Unknown"], 24))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
end

local function buildScannerPanel(parent, activeMessagePanel)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel:SetPoint("TOPLEFT", activeMessagePanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    panel:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    panel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, Theme.layout.gutter)

    local title = setPanelTitle(panel, GP.L["Scanner"])

    frame.scannerStatus = panel:CreateFontString(nil, "ARTWORK")
    frame.scannerStatus:SetFontObject(Theme.font.muted)
    frame.scannerStatus:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    frame.scannerStatus:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.scannerStatus:SetHeight(36)
    frame.scannerStatus:SetJustifyH("LEFT")

    frame.startScanButton = Theme:CreateButton(panel, GP.L["Start Scan"])
    frame.startScanButton:SetPoint("TOPLEFT", frame.scannerStatus, "BOTTOMLEFT", 0, -8)
    frame.startScanButton:SetScript("OnClick", function()
        if frame.scanClickPending then return end
        frame.scanClickPending = true
        setButtonEnabled(frame.startScanButton, false)
        local Recruitment = GP:GetModule("Recruitment")
        local scannerState = Recruitment:GetScannerState()
        local ok, err
        if scannerState.running then
            ok, err = Recruitment:ContinueScanner()
        else
            ok, err = Recruitment:StartScanner()
        end
        if not ok then
            frame.scanClickPending = false
            GP:Print(err)
        end
        RecruitmentTab:Refresh()
    end)

    frame.stopScanButton = Theme:CreateButton(panel, GP.L["Stop"])
    frame.stopScanButton:SetPoint("LEFT", frame.startScanButton, "RIGHT", 8, 0)
    frame.stopScanButton:SetScript("OnClick", function()
        GP:GetModule("Recruitment"):StopScanner()
        RecruitmentTab:Refresh()
    end)

    frame.clearScanButton = Theme:CreateButton(panel, GP.L["Clear"])
    frame.clearScanButton:SetPoint("LEFT", frame.stopScanButton, "RIGHT", 8, 0)
    frame.clearScanButton:SetScript("OnClick", function()
        GP:GetModule("Recruitment"):ClearScanner()
        RecruitmentTab:Refresh()
    end)

    local candidatesTitle = panel:CreateFontString(nil, "ARTWORK")
    candidatesTitle:SetFontObject(Theme.font.heading)
    candidatesTitle:SetPoint("TOPLEFT", frame.startScanButton, "BOTTOMLEFT", 0, -14)
    candidatesTitle:SetText(GP.L["Candidates"])

    candidateSearchBox = Theme:CreateSearchBox(panel, 140, function() RecruitmentTab:Refresh() end)
    candidateSearchBox:SetPoint("TOPLEFT", candidatesTitle, "BOTTOMLEFT", 0, -8)

    frame.addVisibleButton = Theme:CreateButton(panel, GP.L["Add Visible"])
    frame.addVisibleButton:SetPoint("LEFT", candidateSearchBox, "RIGHT", 8, 0)
    frame.addVisibleButton:SetScript("OnClick", function()
        local Recruitment = GP:GetModule("Recruitment")
        local added = Recruitment:AddCandidatesToQueue(Recruitment:GetScannerCandidates(candidateSearchBox and candidateSearchBox:GetText() or ""))
        GP:Print(string.format(GP.L["Queued %d candidate(s)."], added))
        RecruitmentTab:Refresh()
    end)

    local candidatePanel = Theme:CreatePanel(panel, "panel", "border")
    candidatePanel:SetPoint("TOPLEFT", candidateSearchBox, "BOTTOMLEFT", 0, -26)
    candidatePanel:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    candidatePanel:SetWidth(300)

    local candidateNameHeader = candidatePanel:CreateFontString(nil, "ARTWORK")
    candidateNameHeader:SetFontObject(Theme.font.small)
    candidateNameHeader:SetPoint("BOTTOMLEFT", candidatePanel, "TOPLEFT", 8, 4)
    candidateNameHeader:SetText(GP.L["Name"])

    local candidateLevelHeader = candidatePanel:CreateFontString(nil, "ARTWORK")
    candidateLevelHeader:SetFontObject(Theme.font.small)
    candidateLevelHeader:SetPoint("LEFT", candidateNameHeader, "LEFT", 118, 0)
    candidateLevelHeader:SetText(GP.L["Lvl"])

    local candidateClassHeader = candidatePanel:CreateFontString(nil, "ARTWORK")
    candidateClassHeader:SetFontObject(Theme.font.small)
    candidateClassHeader:SetPoint("LEFT", candidateNameHeader, "LEFT", 160, 0)
    candidateClassHeader:SetText(GP.L["Class"])

    local candidateZoneHeader = candidatePanel:CreateFontString(nil, "ARTWORK")
    candidateZoneHeader:SetFontObject(Theme.font.small)
    candidateZoneHeader:SetPoint("LEFT", candidateNameHeader, "LEFT", 238, 0)
    candidateZoneHeader:SetText(GP.L["Zone"])

    candidateList = GP.UI.ScrollList:New(candidatePanel, SCANNER_ROW_HEIGHT, createCandidateRow)
    candidateList:SetUpdateRow(updateCandidateRow)

    local skippedTitle = panel:CreateFontString(nil, "ARTWORK")
    skippedTitle:SetFontObject(Theme.font.heading)
    skippedTitle:SetPoint("TOPLEFT", candidatesTitle, "TOPLEFT", 330, 0)
    skippedTitle:SetText(GP.L["Skipped"])

    skippedSearchBox = Theme:CreateSearchBox(panel, 140, function() RecruitmentTab:Refresh() end)
    skippedSearchBox:SetPoint("TOPLEFT", skippedTitle, "BOTTOMLEFT", 0, -8)

    local skippedPanel = Theme:CreatePanel(panel, "panel", "border")
    skippedPanel:SetPoint("TOPLEFT", skippedSearchBox, "BOTTOMLEFT", 0, -26)
    skippedPanel:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", Theme.layout.gutter + 330, Theme.layout.gutter)
    skippedPanel:SetWidth(300)

    local skippedNameHeader = skippedPanel:CreateFontString(nil, "ARTWORK")
    skippedNameHeader:SetFontObject(Theme.font.small)
    skippedNameHeader:SetPoint("BOTTOMLEFT", skippedPanel, "TOPLEFT", 8, 4)
    skippedNameHeader:SetText(GP.L["Name"])

    local skippedReasonHeader = skippedPanel:CreateFontString(nil, "ARTWORK")
    skippedReasonHeader:SetFontObject(Theme.font.small)
    skippedReasonHeader:SetPoint("LEFT", skippedNameHeader, "LEFT", 108, 0)
    skippedReasonHeader:SetText(GP.L["Reason"])

    local skippedZoneHeader = skippedPanel:CreateFontString(nil, "ARTWORK")
    skippedZoneHeader:SetFontObject(Theme.font.small)
    skippedZoneHeader:SetPoint("LEFT", skippedNameHeader, "LEFT", 226, 0)
    skippedZoneHeader:SetText(GP.L["Zone"])

    skippedList = GP.UI.ScrollList:New(skippedPanel, SCANNER_ROW_HEIGHT, createSkippedRow)
    skippedList:SetUpdateRow(updateSkippedRow)

    local queueTitle = panel:CreateFontString(nil, "ARTWORK")
    queueTitle:SetFontObject(Theme.font.heading)
    queueTitle:SetPoint("TOPLEFT", candidatesTitle, "TOPLEFT", 660, -90)
    queueTitle:SetText(GP.L["Queue"])

    local executorPanel = Theme:CreatePanel(panel, "panel", "border")
    executorPanel:SetPoint("TOPLEFT", panel, "TOPLEFT", Theme.layout.gutter + 660, -Theme.layout.gutter)
    executorPanel:SetPoint("RIGHT", panel, "RIGHT", -Theme.layout.gutter, 0)
    executorPanel:SetPoint("BOTTOM", queueTitle, "TOP", 0, 12)

    local executorTitle = executorPanel:CreateFontString(nil, "ARTWORK")
    executorTitle:SetFontObject(Theme.font.heading)
    executorTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    executorTitle:SetText(GP.L["Executor"])

    frame.executorModeButtons = {}
    local lastModeButton
    for _, mode in ipairs(GP:GetModule("Recruitment"):GetExecutorModes()) do
        local modeButton = Theme:CreateButton(executorPanel, mode.label)
        modeButton:SetHeight(24)
        modeButton:SetWidth(mode.id == "whisper_invite" and 126 or 78)
        if lastModeButton then
            modeButton:SetPoint("LEFT", lastModeButton, "RIGHT", 6, 0)
        else
            modeButton:SetPoint("TOPLEFT", executorTitle, "BOTTOMLEFT", 0, -8)
        end
        modeButton:SetScript("OnClick", function()
            local ok, err = GP:GetModule("Recruitment"):SetExecutorMode(mode.id)
            if not ok and err then GP:Print(err) end
            RecruitmentTab:Refresh()
        end)
        modeButton:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(unpack(Theme.color.accent))
        end)
        modeButton:SetScript("OnLeave", function(self)
            setModeButtonSelected(self, self.selected)
        end)
        frame.executorModeButtons[mode.id] = modeButton
        lastModeButton = modeButton
    end

    frame.executorButton = Theme:CreateButton(executorPanel, GP.L["Start Executor"])
    frame.executorButton:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    frame.executorButton:SetScript("OnClick", function()
        local ok, msg = GP:GetModule("Recruitment"):StartExecutor()
        if msg then GP:Print(msg) end
        RecruitmentTab:Refresh()
    end)

    frame.stopExecutorButton = Theme:CreateButton(executorPanel, GP.L["Stop Executor"])
    frame.stopExecutorButton:SetPoint("LEFT", frame.executorButton, "RIGHT", 8, 0)
    frame.stopExecutorButton:SetScript("OnClick", function()
        local ok, msg = GP:GetModule("Recruitment"):StopExecutor()
        if msg then GP:Print(msg) end
        RecruitmentTab:Refresh()
    end)

    frame.executorPreviewText = executorPanel:CreateFontString(nil, "ARTWORK")
    frame.executorPreviewText:SetFontObject(Theme.font.muted)
    frame.executorPreviewText:SetPoint("TOPLEFT", executorTitle, "BOTTOMLEFT", 0, -38)
    frame.executorPreviewText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.executorPreviewText:SetPoint("BOTTOM", frame.executorButton, "TOP", 0, 8)
    frame.executorPreviewText:SetJustifyH("LEFT")
    frame.executorPreviewText:SetWordWrap(true)

    queueSearchBox = Theme:CreateSearchBox(panel, 140, function() RecruitmentTab:Refresh() end)
    queueSearchBox:SetPoint("TOPLEFT", queueTitle, "BOTTOMLEFT", 0, -8)

    frame.clearQueueButton = Theme:CreateButton(panel, GP.L["Clear Queue"])
    frame.clearQueueButton:SetPoint("LEFT", queueSearchBox, "RIGHT", 8, 0)
    frame.clearQueueButton:SetScript("OnClick", function()
        GP:GetModule("Recruitment"):ClearCandidateQueue()
        RecruitmentTab:Refresh()
    end)

    local queuePanel = Theme:CreatePanel(panel, "panel", "border")
    queuePanel:SetPoint("TOPLEFT", queueSearchBox, "BOTTOMLEFT", 0, -26)
    queuePanel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)

    local queueNameHeader = queuePanel:CreateFontString(nil, "ARTWORK")
    queueNameHeader:SetFontObject(Theme.font.small)
    queueNameHeader:SetPoint("BOTTOMLEFT", queuePanel, "TOPLEFT", 8, 4)
    queueNameHeader:SetText(GP.L["Name"])

    local queueLevelHeader = queuePanel:CreateFontString(nil, "ARTWORK")
    queueLevelHeader:SetFontObject(Theme.font.small)
    queueLevelHeader:SetPoint("LEFT", queueNameHeader, "LEFT", 112, 0)
    queueLevelHeader:SetText(GP.L["Lvl"])

    local queueClassHeader = queuePanel:CreateFontString(nil, "ARTWORK")
    queueClassHeader:SetFontObject(Theme.font.small)
    queueClassHeader:SetPoint("LEFT", queueNameHeader, "LEFT", 150, 0)
    queueClassHeader:SetText(GP.L["Class"])

    local queueZoneHeader = queuePanel:CreateFontString(nil, "ARTWORK")
    queueZoneHeader:SetFontObject(Theme.font.small)
    queueZoneHeader:SetPoint("LEFT", queueNameHeader, "LEFT", 226, 0)
    queueZoneHeader:SetText(GP.L["Zone"])

    queueList = GP.UI.ScrollList:New(queuePanel, SCANNER_ROW_HEIGHT, createQueuedRow)
    queueList:SetUpdateRow(updateQueuedRow)

    return panel
end

local WELCOME_ROW_HEIGHT = 28
local WELCOME_FLYOUT_WIDTH = 320
local WELCOME_MAX_VISIBLE_ROWS = 6

local function welcomeRowLabel(entry)
    if entry.wantsGuild and entry.wantsWhisper then
        return GP.L["Guild + Whisper"]
    elseif entry.wantsWhisper then
        return GP.L["Whisper"]
    end
    return GP.L["Guild"]
end

local function createWelcomeRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(WELCOME_ROW_HEIGHT)
    row:SetPoint("LEFT", 4, 0)
    row:SetPoint("RIGHT", -4, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.kind = row:CreateFontString(nil, "ARTWORK")
    row.kind:SetFontObject(Theme.font.muted)
    row.kind:SetPoint("BOTTOMLEFT", row.name, "TOPLEFT", 0, 0)
    row.kind:SetJustifyH("LEFT")

    row.dismissButton = Theme:CreateButton(row, "×")
    row.dismissButton:SetSize(22, 22)
    row.dismissButton:SetPoint("RIGHT", 0, 0)

    row.sendButton = Theme:CreateButton(row, GP.L["Send"])
    row.sendButton:SetWidth(64)
    row.sendButton:SetPoint("RIGHT", row.dismissButton, "LEFT", -6, 0)

    row.name:SetPoint("RIGHT", row.sendButton, "LEFT", -8, 8)

    return row
end

local function updateWelcomeRow(row, entry)
    row.entry = entry
    row.name:SetText(truncate(entry.name or "?", 20))
    row.kind:SetText(welcomeRowLabel(entry))
end

local function buildAwaitingWelcomePanel(parent, statusPanel)
    frame.awaitingWelcomeButton = Theme:CreateButton(parent, GP.L["Pending Welcomes"])
    frame.awaitingWelcomeButton:SetPoint("BOTTOMRIGHT", statusPanel, "TOPRIGHT", 0, Theme.layout.gutter)
    frame.awaitingWelcomeButton:SetWidth(180)

    local flyout = Theme:CreatePanel(parent, "panelRaised", "accent")
    flyout:SetFrameStrata("DIALOG")
    flyout:SetWidth(WELCOME_FLYOUT_WIDTH)
    flyout:SetHeight(28 + 8 + WELCOME_MAX_VISIBLE_ROWS * WELCOME_ROW_HEIGHT)
    flyout:SetPoint("TOPRIGHT", frame.awaitingWelcomeButton, "BOTTOMRIGHT", 0, -6)
    flyout:Hide()
    frame.awaitingWelcomeFlyout = flyout

    local title = flyout:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.heading)
    title:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    title:SetText(GP.L["Pending Welcomes"])

    local emptyText = flyout:CreateFontString(nil, "ARTWORK")
    emptyText:SetFontObject(Theme.font.muted)
    emptyText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    emptyText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetText(GP.L["No welcomes waiting to be sent."])
    frame.awaitingWelcomeEmptyText = emptyText

    local rows = {}
    frame.awaitingWelcomeRows = rows
    local previousRow
    for i = 1, WELCOME_MAX_VISIBLE_ROWS do
        local row = createWelcomeRow(flyout)
        if previousRow then
            row:SetPoint("TOPLEFT", previousRow, "BOTTOMLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        end
        row.sendButton:SetScript("OnClick", function()
            if not row.entry then return end
            local Recruitment = GP:GetModule("Recruitment")
            local ok, err = Recruitment:SendAwaitingWelcome(frame.guildKey, row.entry.id)
            if not ok and err then GP:Print(err) end
        end)
        row.dismissButton:SetScript("OnClick", function()
            if not row.entry then return end
            GP:GetModule("Recruitment"):DismissAwaitingWelcome(frame.guildKey, row.entry.id)
        end)
        row:Hide()
        table.insert(rows, row)
        previousRow = row
    end

    frame.awaitingWelcomeButton:SetScript("OnClick", function()
        flyout:SetShown(not flyout:IsShown())
    end)

    -- Passive mouse-position watcher; no competing click-catcher frame.
    local outsideMouseWasDown = false
    local watcher = CreateFrame("Frame")
    watcher:Hide()
    watcher:SetScript("OnUpdate", function()
        local isDown = IsMouseButtonDown("LeftButton")
        if isDown and not outsideMouseWasDown then
            if flyout:IsShown() and not flyout:IsMouseOver() and not frame.awaitingWelcomeButton:IsMouseOver() then
                flyout:Hide()
            end
        end
        outsideMouseWasDown = isDown
    end)
    flyout:SetScript("OnShow", function()
        outsideMouseWasDown = IsMouseButtonDown("LeftButton")
        watcher:Show()
    end)
    flyout:SetScript("OnHide", function()
        watcher:Hide()
    end)
end

function RecruitmentTab:RefreshAwaitingWelcomes()
    if not frame or not frame.awaitingWelcomeRows then return end
    local Recruitment = GP:GetModule("Recruitment")
    local entries = Recruitment:GetAwaitingWelcomes(frame.guildKey)

    frame.awaitingWelcomeButton:SetText(string.format(GP.L["Pending Welcomes (%d)"], #entries))

    frame.awaitingWelcomeEmptyText:SetShown(#entries == 0)
    for i, row in ipairs(frame.awaitingWelcomeRows) do
        local entry = entries[i]
        if entry then
            updateWelcomeRow(row, entry)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end

    if frame.awaitingWelcomeFlyout and #entries == 0 then
        frame.awaitingWelcomeFlyout:Hide()
    end
end

function RecruitmentTab:Refresh()
    if not frame then return end

    local Recruitment = GP:GetModule("Recruitment")
    frame.guildKey = Recruitment:GetCurrentGuildKey()
    local blacklist, antiSpam, messages, filters, zones, pending = Recruitment:GetSummary(frame.guildKey)

    frame.summaryText:SetText(string.format(GP.L["Do-not-invite: %d   Anti-spam: %d   Pending: %d   Messages: %d   Filters: %d   Your Invalid Zones: %d"],
        blacklist, antiSpam, pending, messages, filters, zones))
    frame.doNotInviteCountText:SetText(string.format(GP.L["Entries: %d"], blacklist))
    self:RefreshAwaitingWelcomes()

    -- Active-message card: read-only here on purpose — creating/editing/
    -- switching/deleting templates now happens in Settings → Recruitment →
    -- Message Templates (UI/Settings.lua). "Locked by guild master" is
    -- purely informational since there's nothing to disable on this card.
    local activeMessage = Recruitment:GetSelectedMessage(frame.guildKey)
    if activeMessage then
        frame.activeMessageTitle:SetText(activeMessage.title or "?")
    else
        frame.activeMessageTitle:SetText(GP.L["No active message selected."])
    end
    frame.messageLockedText:SetShown(Recruitment:IsMessageEditingLocked())

    local activeFilter = Recruitment:GetSelectedFilter(frame.guildKey)
    if activeFilter then
        frame.activeFilterTitle:SetText(truncate(activeFilter.name or "?", 30))
    else
        frame.activeFilterTitle:SetText(GP.L["No active filter selected."])
    end
    frame.filterLockedText:SetShown(Recruitment:IsFilterEditingLocked())

    local scannerState = Recruitment:GetScannerState()
    if frame.scanClickPending and (scannerState.waiting or not scannerState.running or not scannerState.canContinue) then
        frame.scanClickPending = false
    end
    frame.statusText:SetText(Recruitment:GetScannerStatusText())
    if frame.scannerStatus then
        frame.scannerStatus:SetText(string.format(GP.L["Queries: %d / %d   Results: %d   Candidates: %d   Queued: %d   Skipped: %d"],
            scannerState.queryIndex, scannerState.queryTotal, scannerState.rawResults, scannerState.candidates, scannerState.queued, scannerState.skipped))
    end
    if frame.startScanButton then
        if frame.startScanButton.text then
            local nextWait = scannerState.running and math.max(0, math.ceil((scannerState.nextQueryAvailableAt or 0) - time())) or 0
            if scannerState.running and nextWait > 0 then
                frame.startScanButton.text:SetText(string.format(GP.L["Next Query (%ds)"], nextWait))
            else
                frame.startScanButton.text:SetText(scannerState.running and GP.L["Next Query"] or GP.L["Start Scan"])
            end
        end
        setButtonEnabled(frame.startScanButton, (not frame.scanClickPending) and (not scannerState.running or scannerState.canContinue))
        setButtonEnabled(frame.stopScanButton, scannerState.running)
        setButtonEnabled(frame.clearScanButton, not scannerState.running and (scannerState.candidates > 0 or scannerState.skipped > 0 or scannerState.rawResults > 0))
    end
    if candidateList then
        candidateList:SetData(Recruitment:GetScannerCandidates(candidateSearchBox and candidateSearchBox:GetText() or ""), false)
    end
    if queueList then
        queueList:SetData(Recruitment:GetQueuedCandidates(queueSearchBox and queueSearchBox:GetText() or ""), false)
    end
    if skippedList then
        skippedList:SetData(Recruitment:GetScannerSkipped(skippedSearchBox and skippedSearchBox:GetText() or ""), false)
    end
    if frame.addVisibleButton then
        setButtonEnabled(frame.addVisibleButton, scannerState.candidates > 0)
    end
    if frame.clearQueueButton then
        setButtonEnabled(frame.clearQueueButton, scannerState.queued > 0)
    end
    local executorPreview = Recruitment:GetExecutorPreview()
    if frame.executorPreviewText then
        if executorPreview.warning then
            frame.executorPreviewText:SetText(executorPreview.warning)
        elseif executorPreview.message and executorPreview.message ~= "" then
            frame.executorPreviewText:SetText(executorPreview.summary .. ": " .. executorPreview.message)
        else
            frame.executorPreviewText:SetText(executorPreview.summary or "")
        end
    end
    local executorState = Recruitment:GetExecutorState()
    if frame.executorModeButtons then
        for id, button in pairs(frame.executorModeButtons) do
            setButtonEnabled(button, not executorState.running)
            setModeButtonSelected(button, id == executorPreview.mode)
        end
    end
    if frame.executorButton then
        setButtonEnabled(frame.executorButton, executorPreview.ready and not executorState.running)
    end
    if frame.stopExecutorButton then
        setButtonEnabled(frame.stopExecutorButton, executorState.running)
    end
end

function RecruitmentTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Recruitment"])

    local info = frame:CreateFontString(nil, "ARTWORK")
    info:SetFontObject(Theme.font.muted)
    info:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    info:SetWidth(1000)
    info:SetJustifyH("LEFT")
    info:SetText(L["Recruitment scanner collects candidates for review. The executor only acts on queued candidates when started manually."])

    frame.summaryText = frame:CreateFontString(nil, "ARTWORK")
    frame.summaryText:SetFontObject(Theme.font.muted)
    frame.summaryText:SetPoint("TOPRIGHT", -Theme.layout.gutter, -4)
    frame.summaryText:SetJustifyH("RIGHT")

    local statusPanel = buildStatusPanel(frame, info)
    local doNotInvitePanel = buildDoNotInviteSummaryPanel(frame, statusPanel)
    local filterPanel = buildActiveFilterPanel(frame, doNotInvitePanel)
    local activeMessagePanel = buildActiveMessagePanel(frame, filterPanel)
    buildScannerPanel(frame, activeMessagePanel)
    buildAwaitingWelcomePanel(frame, statusPanel)

    -- Closes the welcome flyout on tab switch, matching UI/RosterTab.lua's
    -- Hide flyouts when the tab is deselected.
    frame.OnDeselected = function()
        if frame.awaitingWelcomeFlyout then frame.awaitingWelcomeFlyout:Hide() end
    end

    -- Debounce scanner bursts so the tab refreshes once per classified batch.
    local function debouncedRefresh()
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("RecruitmentTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                RecruitmentTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    RecruitmentTab:RegisterMessage("GuildParagon_RecruitmentChanged", debouncedRefresh)
    -- The guild-master lock/settings push path
    -- (pushRecruitmentSnapshotsIfNeeded, see Modules/Recruitment.lua) only
    RecruitmentTab:RegisterMessage("GuildParagon_RecruitmentSettingsChanged", debouncedRefresh)
    RecruitmentTab:RegisterMessage("GuildParagon_BanListChanged", debouncedRefresh)
    RecruitmentTab:RegisterMessage("GuildParagon_RecruitmentScannerChanged", debouncedRefresh)
    self:Refresh()
    return frame
end

function RecruitmentTab:OnSelected()
    refreshDirty = false
    self:Refresh()
end
