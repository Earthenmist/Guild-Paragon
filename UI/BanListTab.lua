-- Guild Paragon — Ban List tab
--
-- Officer-only ban registry. This is deliberately registry-only in v1:
-- it does not kick players, create macros, or broadcast private ban data.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.BanListTab = GP.UI.BanListTab or {}
local BanListTab = GP.UI.BanListTab

-- Own AceEvent identity so this tab's message handlers do not overwrite
-- handlers registered by other UI tables.
LibStub("AceEvent-3.0"):Embed(BanListTab)

local ROW_HEIGHT = 32
local REMOVE_POPUP = "GUILDPARAGON_REMOVE_BAN_RECORD"
local REMOVE_DNI_POPUP = "GUILDPARAGON_REMOVE_RECRUITMENT_BLOCK"

local frame, list, searchBox, dniList, dniSearchBox, selectedID, selectedDniID
local refreshDirty = false
local clearForm, clearDniForm

local function formatDate(ts)
    return type(ts) == "number" and date("%Y-%m-%d", ts) or ""
end

local function classColor(classFile)
    local c = classFile and C_ClassColor.GetClassColor(classFile)
    if c then return c.r, c.g, c.b end
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

local function selectedRecord()
    if not frame or not selectedID then return nil end
    return GP:GetModule("BanList"):GetRecord(frame.guildKey, selectedID)
end

local function selectedDniRecord()
    if not frame or not selectedDniID then return nil end
    return GP:GetModule("Recruitment"):GetBlacklistRecord(frame.guildKey, selectedDniID)
end

local function applyRowState(row, selected, hovered)
    if selected or hovered then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
        row:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

StaticPopupDialogs[REMOVE_POPUP] = StaticPopupDialogs[REMOVE_POPUP] or {
    text = GP.L["Remove ban record for %s?"],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local ok, err = GP:GetModule("BanList"):Remove(data.guildKey, data.id)
        GP:Print(ok and GP.L["Ban record removed."] or err)
        selectedID = nil
        if ok then clearForm() end
        BanListTab:Refresh()
    end,
}

StaticPopupDialogs[REMOVE_DNI_POPUP] = StaticPopupDialogs[REMOVE_DNI_POPUP] or {
    text = GP.L["Remove do-not-invite record for %s?"],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local ok, err = GP:GetModule("Recruitment"):RemoveBlacklist(data.guildKey, data.id)
        GP:Print(ok and GP.L["Do-not-invite record removed."] or err)
        selectedDniID = nil
        if ok then clearDniForm() end
        BanListTab:Refresh()
    end,
}

local function createRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(240)
    row.name:SetJustifyH("LEFT")

    row.date = row:CreateFontString(nil, "ARTWORK")
    row.date:SetFontObject(Theme.font.muted)
    row.date:SetPoint("LEFT", 260, 0)
    row.date:SetWidth(95)
    row.date:SetJustifyH("LEFT")

    row.reason = row:CreateFontString(nil, "ARTWORK")
    row.reason:SetFontObject(Theme.font.muted)
    row.reason:SetPoint("LEFT", 370, 0)
    row.reason:SetPoint("RIGHT", -8, 0)
    row.reason:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self)
        selectedID = self.record and self.record.id or nil
        BanListTab:Refresh()
    end)
    row:SetScript("OnEnter", function(self)
        applyRowState(self, selectedID == (self.record and self.record.id), true)
    end)
    row:SetScript("OnLeave", function(self)
        applyRowState(self, selectedID == (self.record and self.record.id), false)
    end)

    return row
end

local function updateRow(row, record)
    row.record = record
    row.name:SetText(record.name or "?")
    row.name:SetTextColor(classColor(record.class))
    row.date:SetText(formatDate(record.bannedAt))
    row.reason:SetText(record.reason ~= "" and record.reason or GP.L["No Ban Reason Given"])

    applyRowState(row, selectedID == record.id, false)
end

local function createDniRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(160)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.added = row:CreateFontString(nil, "ARTWORK")
    row.added:SetFontObject(Theme.font.muted)
    row.added:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.added:SetWidth(84)
    row.added:SetJustifyH("LEFT")

    row.reason = row:CreateFontString(nil, "ARTWORK")
    row.reason:SetFontObject(Theme.font.muted)
    row.reason:SetPoint("LEFT", row.added, "RIGHT", 8, 0)
    row.reason:SetPoint("RIGHT", -8, 0)
    row.reason:SetJustifyH("LEFT")
    row.reason:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        selectedDniID = self.record and self.record.id or nil
        BanListTab:Refresh()
    end)
    row:SetScript("OnEnter", function(self)
        applyRowState(self, selectedDniID == (self.record and self.record.id), true)
    end)
    row:SetScript("OnLeave", function(self)
        applyRowState(self, selectedDniID == (self.record and self.record.id), false)
    end)

    return row
end

local function updateDniRow(row, record)
    row.record = record
    row.name:SetText(record.name or "?")
    row.added:SetText(formatDate(record.addedAt))
    row.reason:SetText(record.reason ~= "" and record.reason or GP.L["No reason given."])

    applyRowState(row, selectedDniID == record.id, false)
end

clearForm = function()
    selectedID = nil
    frame.nameBox:SetText("")
    frame.reasonBox:SetText("")
    frame.dateBox:SetText(date("%Y-%m-%d"))
end

clearDniForm = function()
    selectedDniID = nil
    frame.dniNameBox:SetText("")
    frame.dniReasonBox:SetText("")
end

local function loadForm(record)
    if not record then return end
    frame.nameBox:SetText(record.name or "")
    frame.reasonBox:SetText(record.reason or "")
    frame.dateBox:SetText(formatDate(record.bannedAt))
end

local function loadDniForm(record)
    if not record then return end
    frame.dniNameBox:SetText(record.name or "")
    frame.dniReasonBox:SetText(record.reason or "")
end

function BanListTab:Refresh()
    if not frame then return end

    local BanList = GP:GetModule("BanList")
    frame.guildKey = BanList:GetCurrentGuildKey()
    local records = BanList:GetRecords(frame.guildKey, searchBox and searchBox:GetText() or "")
    local Recruitment = GP:GetModule("Recruitment")
    local dniRecords = Recruitment:GetBlacklist(frame.guildKey, dniSearchBox and dniSearchBox:GetText() or "")

    local selected = selectedRecord()
    if selectedID and not selected then selectedID = nil end

    frame.summaryText:SetText(string.format(GP.L["Showing %d banned player(s)."], #records))
    list:SetData(records, false)
    frame.dniSummaryText:SetText(string.format(GP.L["Entries: %d"], #dniRecords))
    dniList:SetData(dniRecords, false)

    selected = selectedRecord()
    if selected then
        loadForm(selected)
        frame.detailText:SetText(table.concat({
            string.format(GP.L["Banned by: %s"], selected.bannedBy ~= "" and selected.bannedBy or GP.L["Unknown"]),
            string.format(GP.L["Date of Ban: %s"], formatDate(selected.bannedAt)),
            string.format(GP.L["Rank: %s"], selected.rankName or GP.L["Unknown"]),
            selected.source == "grm" and GP.L["Imported from GRM."] or GP.L["Manual Guild Paragon record."],
        }, "\n"))
        frame.removeButton:Show()
    else
        frame.detailText:SetText(GP.L["Select a ban record, or enter a name and reason to add one."])
        frame.removeButton:Hide()
    end

    local dni = selectedDniRecord()
    if selectedDniID and not dni then selectedDniID = nil end

    if dni then
        loadDniForm(dni)
        if dni.readOnly or dni.source == "antiSpam" then
            local detailText = dni.source == "antiSpam" and GP.L["Anti-spam entries are managed automatically and expire after the configured cooldown."] or GP.L["Ban List entries are managed from the Ban List tab."]
            frame.dniDetailText:SetText(table.concat({
                detailText,
                string.format(GP.L["Added: %s"], formatDate(dni.addedAt)),
            }, "\n"))
            frame.dniRemoveButton:Show()
            setButtonEnabled(frame.dniRemoveButton, false)
            setButtonEnabled(frame.dniSaveButton, false)
        else
            frame.dniDetailText:SetText(table.concat({
                string.format(GP.L["Added by: %s"], dni.addedBy ~= "" and dni.addedBy or GP.L["Unknown"]),
                string.format(GP.L["Added: %s"], formatDate(dni.addedAt)),
            }, "\n"))
            frame.dniRemoveButton:Show()
            setButtonEnabled(frame.dniRemoveButton, true)
            setButtonEnabled(frame.dniSaveButton, true)
        end
    else
        frame.dniDetailText:SetText(GP.L["Select a record, or enter a name and reason to add a do-not-invite entry."])
        frame.dniRemoveButton:Hide()
        setButtonEnabled(frame.dniRemoveButton, false)
        setButtonEnabled(frame.dniSaveButton, true)
    end
end

function BanListTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    frame.OnSelected = function()
        BanListTab:OnSelected()
    end

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Ban List"])

    local info = frame:CreateFontString(nil, "ARTWORK")
    info:SetFontObject(Theme.font.muted)
    info:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    info:SetWidth(620)
    info:SetJustifyH("LEFT")
    info:SetText(L["Officer-only registry of players who should not be reinvited. This tab records ban details only; it does not kick players or build macros."])

    searchBox = Theme:CreateSearchBox(frame, 260, function() BanListTab:Refresh() end)
    searchBox:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -16)

    frame.summaryText = frame:CreateFontString(nil, "ARTWORK")
    frame.summaryText:SetFontObject(Theme.font.muted)
    frame.summaryText:SetPoint("TOPRIGHT", -Theme.layout.gutter, -4)
    frame.summaryText:SetJustifyH("RIGHT")

    local listPanel = Theme:CreatePanel(frame, "panel", "border")
    listPanel:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -18)
    listPanel:SetPoint("TOPRIGHT", frame, "TOPLEFT", 620, 0)
    listPanel:SetHeight(300)

    local nameHeader = listPanel:CreateFontString(nil, "ARTWORK")
    nameHeader:SetFontObject(Theme.font.small)
    nameHeader:SetPoint("BOTTOMLEFT", listPanel, "TOPLEFT", 8, 4)
    nameHeader:SetText(L["Name"])

    local dateHeader = listPanel:CreateFontString(nil, "ARTWORK")
    dateHeader:SetFontObject(Theme.font.small)
    dateHeader:SetPoint("LEFT", nameHeader, "LEFT", 252, 0)
    dateHeader:SetText(L["Ban Date"])

    local reasonHeader = listPanel:CreateFontString(nil, "ARTWORK")
    reasonHeader:SetFontObject(Theme.font.small)
    reasonHeader:SetPoint("LEFT", nameHeader, "LEFT", 362, 0)
    reasonHeader:SetText(L["Reason"])

    list = GP.UI.ScrollList:New(listPanel, ROW_HEIGHT, createRow)
    list:SetUpdateRow(updateRow)

    local detailPanel = Theme:CreatePanel(frame, "panel", "border")
    detailPanel:SetPoint("TOPLEFT", listPanel, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    detailPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 620, Theme.layout.gutter)

    local formTitle = detailPanel:CreateFontString(nil, "ARTWORK")
    formTitle:SetFontObject(Theme.font.heading)
    formTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    formTitle:SetText(L["Ban Details"])

    local nameLabel = detailPanel:CreateFontString(nil, "ARTWORK")
    nameLabel:SetFontObject(Theme.font.small)
    nameLabel:SetPoint("TOPLEFT", formTitle, "BOTTOMLEFT", 0, -16)
    nameLabel:SetText(L["Name"])

    frame.nameBox = Theme:CreateEditBox(detailPanel, 160)
    frame.nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)
    frame.nameBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    local dateLabel = detailPanel:CreateFontString(nil, "ARTWORK")
    dateLabel:SetFontObject(Theme.font.small)
    dateLabel:SetPoint("TOPLEFT", frame.nameBox, "BOTTOMLEFT", 0, -12)
    dateLabel:SetText(L["Ban Date"])

    frame.dateBox = Theme:CreateEditBox(detailPanel, 120)
    frame.dateBox:SetPoint("TOPLEFT", dateLabel, "BOTTOMLEFT", 0, -4)

    local reasonLabel = detailPanel:CreateFontString(nil, "ARTWORK")
    reasonLabel:SetFontObject(Theme.font.small)
    reasonLabel:SetPoint("TOPLEFT", frame.dateBox, "BOTTOMLEFT", 0, -12)
    reasonLabel:SetText(L["Reason Banned:"])

    frame.reasonBox = Theme:CreateEditBox(detailPanel, 160)
    frame.reasonBox:SetHeight(88)
    frame.reasonBox:SetMultiLine(true)
    frame.reasonBox:SetMaxLetters(500)
    frame.reasonBox:SetJustifyV("TOP")
    frame.reasonBox:SetTextInsets(8, 8, 6, 6)
    frame.reasonBox:SetPoint("TOPLEFT", reasonLabel, "BOTTOMLEFT", 0, -4)
    frame.reasonBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    local saveButton = Theme:CreateButton(detailPanel, L["Save"])
    saveButton:SetPoint("TOPLEFT", frame.reasonBox, "BOTTOMLEFT", 0, -12)
    saveButton:SetScript("OnClick", function()
        local ok, err, id = GP:GetModule("BanList"):AddOrUpdate(frame.guildKey, frame.nameBox:GetText(), frame.reasonBox:GetText(), frame.dateBox:GetText(), selectedID)
        if ok then
            selectedID = id
            GP:Print(L["Ban record saved."])
        else
            GP:Print(err)
        end
        BanListTab:Refresh()
    end)

    local newButton = Theme:CreateButton(detailPanel, L["New"])
    newButton:SetPoint("LEFT", saveButton, "RIGHT", 8, 0)
    newButton:SetScript("OnClick", function()
        clearForm()
        BanListTab:Refresh()
    end)

    frame.removeButton = Theme:CreateButton(detailPanel, L["Remove Ban"])
    frame.removeButton:SetPoint("TOPLEFT", saveButton, "BOTTOMLEFT", 0, -8)
    frame.removeButton:SetScript("OnClick", function()
        local record = selectedRecord()
        if record then
            StaticPopup_Show(REMOVE_POPUP, record.name or record.id, nil, { guildKey = frame.guildKey, id = record.id })
        end
    end)

    frame.detailText = detailPanel:CreateFontString(nil, "ARTWORK")
    frame.detailText:SetFontObject(Theme.font.muted)
    frame.detailText:SetPoint("TOPLEFT", newButton, "TOPRIGHT", 22, 2)
    frame.detailText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.detailText:SetHeight(78)
    frame.detailText:SetJustifyH("LEFT")
    frame.detailText:SetJustifyV("TOP")

    local dniPanel = Theme:CreatePanel(frame, "panel", "border")
    dniPanel:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", Theme.layout.gutter, 0)
    dniPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)

    local dniTitle = dniPanel:CreateFontString(nil, "ARTWORK")
    dniTitle:SetFontObject(Theme.font.heading)
    dniTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    dniTitle:SetText(L["Do Not Invite (Recruitment)"])

    frame.dniSummaryText = dniPanel:CreateFontString(nil, "ARTWORK")
    frame.dniSummaryText:SetFontObject(Theme.font.muted)
    frame.dniSummaryText:SetPoint("TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter)
    frame.dniSummaryText:SetJustifyH("RIGHT")

    dniSearchBox = Theme:CreateSearchBox(dniPanel, 160, function() BanListTab:Refresh() end)
    dniSearchBox:SetPoint("TOPLEFT", dniTitle, "BOTTOMLEFT", 0, -12)

    local dniListPanel = Theme:CreatePanel(dniPanel, "panel", "border")
    dniListPanel:SetPoint("TOPLEFT", dniSearchBox, "BOTTOMLEFT", 0, -26)
    dniListPanel:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    dniListPanel:SetHeight(300)

    local dniNameHeader = dniListPanel:CreateFontString(nil, "ARTWORK")
    dniNameHeader:SetFontObject(Theme.font.small)
    dniNameHeader:SetPoint("BOTTOMLEFT", dniListPanel, "TOPLEFT", 8, 4)
    dniNameHeader:SetText(L["Name"])

    local dniDateHeader = dniListPanel:CreateFontString(nil, "ARTWORK")
    dniDateHeader:SetFontObject(Theme.font.small)
    dniDateHeader:SetPoint("LEFT", dniNameHeader, "LEFT", 168, 0)
    dniDateHeader:SetText(L["Added"])

    local dniReasonHeader = dniListPanel:CreateFontString(nil, "ARTWORK")
    dniReasonHeader:SetFontObject(Theme.font.small)
    dniReasonHeader:SetPoint("LEFT", dniNameHeader, "LEFT", 270, 0)
    dniReasonHeader:SetText(L["Reason"])

    dniList = GP.UI.ScrollList:New(dniListPanel, 24, createDniRow)
    dniList:SetUpdateRow(updateDniRow)

    local dniNameLabel = dniPanel:CreateFontString(nil, "ARTWORK")
    dniNameLabel:SetFontObject(Theme.font.small)
    dniNameLabel:SetPoint("TOPLEFT", dniListPanel, "BOTTOMLEFT", 0, -12)
    dniNameLabel:SetText(L["Name"])

    frame.dniNameBox = Theme:CreateEditBox(dniPanel, 160)
    frame.dniNameBox:SetPoint("TOPLEFT", dniNameLabel, "BOTTOMLEFT", 0, -4)
    frame.dniNameBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    local dniReasonLabel = dniPanel:CreateFontString(nil, "ARTWORK")
    dniReasonLabel:SetFontObject(Theme.font.small)
    dniReasonLabel:SetPoint("TOPLEFT", frame.dniNameBox, "BOTTOMLEFT", 0, -10)
    dniReasonLabel:SetText(L["Reason"])

    frame.dniReasonBox = Theme:CreateEditBox(dniPanel, 160)
    frame.dniReasonBox:SetHeight(42)
    frame.dniReasonBox:SetMultiLine(true)
    frame.dniReasonBox:SetMaxLetters(300)
    frame.dniReasonBox:SetJustifyV("TOP")
    frame.dniReasonBox:SetTextInsets(8, 8, 6, 6)
    frame.dniReasonBox:SetPoint("TOPLEFT", dniReasonLabel, "BOTTOMLEFT", 0, -4)
    frame.dniReasonBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    frame.dniSaveButton = Theme:CreateButton(dniPanel, L["Save"])
    frame.dniSaveButton:SetPoint("TOPLEFT", frame.dniReasonBox, "BOTTOMLEFT", 0, -10)
    frame.dniSaveButton:SetScript("OnClick", function()
        local dni = selectedDniRecord()
        if dni and (dni.readOnly or dni.source == "antiSpam") then
            GP:Print(dni.source == "antiSpam" and L["Anti-spam entries are managed automatically and expire after the configured cooldown."] or L["Ban List entries are managed from the Ban List tab."])
            return
        end
        local ok, err, id = GP:GetModule("Recruitment"):AddOrUpdateBlacklist(frame.guildKey, frame.dniNameBox:GetText(), frame.dniReasonBox:GetText(), selectedDniID)
        if ok then
            selectedDniID = id
            GP:Print(L["Do-not-invite record saved."])
        else
            GP:Print(err)
        end
        BanListTab:Refresh()
    end)

    local dniNewButton = Theme:CreateButton(dniPanel, L["New"])
    dniNewButton:SetPoint("LEFT", frame.dniSaveButton, "RIGHT", 8, 0)
    dniNewButton:SetScript("OnClick", function()
        clearDniForm()
        BanListTab:Refresh()
    end)

    frame.dniRemoveButton = Theme:CreateButton(dniPanel, L["Remove"])
    frame.dniRemoveButton:SetPoint("LEFT", dniNewButton, "RIGHT", 8, 0)
    frame.dniRemoveButton:SetScript("OnClick", function()
        local dni = selectedDniRecord()
        if dni and dni.source == "antiSpam" then
            GP:Print(L["Anti-spam entries are managed automatically and expire after the configured cooldown."])
            return
        end
        if dni and not dni.readOnly then
            StaticPopup_Show(REMOVE_DNI_POPUP, dni.name or dni.id, nil, { guildKey = frame.guildKey, id = dni.id })
        end
    end)

    frame.dniDetailText = dniPanel:CreateFontString(nil, "ARTWORK")
    frame.dniDetailText:SetFontObject(Theme.font.muted)
    frame.dniDetailText:SetPoint("TOPLEFT", frame.dniSaveButton, "BOTTOMLEFT", 0, -10)
    frame.dniDetailText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.dniDetailText:SetJustifyH("LEFT")
    frame.dniDetailText:SetJustifyV("TOP")

    clearForm()
    clearDniForm()
    -- Collapse bursty sync/roster events to one refresh.
    local function debouncedRefresh()
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("BanListTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                BanListTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    BanListTab:RegisterMessage("GuildParagon_BanListChanged", debouncedRefresh)
    BanListTab:RegisterMessage("GuildParagon_RecruitmentChanged", debouncedRefresh)
    BanListTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefresh)
    self:Refresh()
    return frame
end

function BanListTab:OnSelected()
    if not frame then return end
    refreshDirty = false
    clearForm()
    clearDniForm()
    self:Refresh()
end
