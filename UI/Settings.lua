-- Guild Paragon — Settings tab
--
-- Modern, sectioned settings surface. Guild Paragon starts with the controls
-- that are already backed by working code and keeps heavier/officer-only
-- machinery in the feature tabs that own it.
local ADDON_NAME, GP = ...
local Theme = GP.UI.Theme

GP.UI.Settings = GP.UI.Settings or {}
local Settings = GP.UI.Settings

-- Own AceEvent identity so this tab's message handlers do not overwrite
-- handlers registered by other UI tables.
LibStub("AceEvent-3.0"):Embed(Settings)

local SECTION_WIDTH = 390
local RIGHT_SECTION_WIDTH = 520
local SECTION_GAP = 18
local SETTINGS_PAGE_WIDTH = 930
local SETTINGS_COLUMN_WIDTH = 450

local function ensureEventLogSettings()
    GP.db.profile.eventLog = GP.db.profile.eventLog or {}
    local s = GP.db.profile.eventLog
    if s.numberedLines == nil then s.numberedLines = true end
    if s.categoryColors == nil then s.categoryColors = true end
    return s
end

local function ensureRosterDisplaySettings()
    GP.db.profile.roster = GP.db.profile.roster or {}
    GP.db.profile.roster.display = GP.db.profile.roster.display or {}
    local s = GP.db.profile.roster.display
    if s.classColorNames == nil then s.classColorNames = true end
    if s.showLevel == nil then s.showLevel = true end
    return s
end

local function ensureScanSettings()
    GP.db.profile.scan = GP.db.profile.scan or {}
    local s = GP.db.profile.scan
    if s.login == nil then s.login = true end
    if s.rosterUpdates == nil then s.rosterUpdates = true end
    return s
end

local function ensureUISettings()
    GP.db.profile.ui = GP.db.profile.ui or {}
    local s = GP.db.profile.ui
    if s.autoHideInCombat == nil then s.autoHideInCombat = true end
    s.scale = tonumber(s.scale) or 1
    if s.scale < 0.50 then s.scale = 0.50 end
    if s.scale > 1.25 then s.scale = 1.25 end
    return s
end

local function ensureMinimapSettings()
    GP.db.profile.minimapIcon = GP.db.profile.minimapIcon or {}
    local s = GP.db.profile.minimapIcon
    if s.hide == nil then s.hide = false end
    s.angle = tonumber(s.angle) or 225
    return s
end

local function ensureRecruitmentSettings()
    local Recruitment = GP:GetModule("Recruitment", true)
    if Recruitment and Recruitment.GetSettings then
        return Recruitment:GetSettings()
    end
    GP.db.profile.recruitment = GP.db.profile.recruitment or {}
    local s = GP.db.profile.recruitment
    if s.requireOfficer == nil then s.requireOfficer = false end
    if s.executorMode == nil then s.executorMode = "whisper" end
    if s.pendingTimeoutDays == nil then s.pendingTimeoutDays = 7 end
    if s.welcomeGuild == nil then s.welcomeGuild = false end
    if s.welcomeGuildMessage == nil then s.welcomeGuildMessage = GP.L["Welcome PLAYERNAME to GUILDNAME!"] end
    if s.welcomeWhisper == nil then s.welcomeWhisper = false end
    if s.welcomeWhisperMessage == nil then s.welcomeWhisperMessage = GP.L["Welcome to GUILDNAME, PLAYERNAME!"] end
    if s.lockMessages == nil then s.lockMessages = false end
    if s.lockFilters == nil then s.lockFilters = false end
    return s
end

local function ensureGuildHealthSettings()
    local GuildHealth = GP:GetModule("GuildHealth", true)
    if GuildHealth and GuildHealth.GetSettings then
        return GuildHealth:GetSettings()
    end
    GP.db.profile.guildHealth = GP.db.profile.guildHealth or {}
    return GP.db.profile.guildHealth
end

local function createCheck(parent, label, onClick)
    local button = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    button:SetSize(22, 22)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(Theme.font.body)
    text:SetPoint("LEFT", button, "RIGHT", 4, 0)
    text:SetText(label)
    button.text = text

    button:SetScript("OnClick", function(self)
        if onClick then onClick(self:GetChecked() and true or false) end
    end)
    return button
end

local function fitCheckLabel(button, width)
    if not button or not button.text then return end
    button.text:SetWidth(width)
    button.text:SetJustifyH("LEFT")
    button.text:SetWordWrap(false)
end

local function addOptionDescription(parent, anchor, text, width)
    local fontString = parent:CreateFontString(nil, "ARTWORK")
    fontString:SetFontObject(Theme.font.small)
    fontString:SetTextColor(unpack(Theme.color.textSecondary))
    fontString:SetJustifyH("LEFT")
    fontString:SetWidth(width or 360)
    fontString:SetText(text)
    fontString:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 26, -1)
    return fontString
end

local function createSection(parent, title)
    local panel = Theme:CreatePanel(parent, "panel", "border")
    panel:SetWidth(SECTION_WIDTH)

    local heading = panel:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.heading)
    heading:SetFont(STANDARD_TEXT_FONT, 14, "")
    heading:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    heading:SetText(title)
    panel.heading = heading

    return panel
end

local function addBodyText(parent, anchor, text, width)
    local fontString = parent:CreateFontString(nil, "ARTWORK")
    fontString:SetFontObject(Theme.font.body)
    fontString:SetJustifyH("LEFT")
    fontString:SetWidth(width or (SECTION_WIDTH - Theme.layout.gutter * 2))
    fontString:SetText(text)
    if anchor then
        fontString:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
    else
        fontString:SetPoint("TOPLEFT", parent.heading, "BOTTOMLEFT", 0, -8)
    end
    return fontString
end

-- Status text used to just sit there permanently once set — with
-- Recruitment Safety now auto-saving on every click, "Recruitment settings
local function setSettingsStatus(frame, text, isError)
    if not frame or not frame.settingsStatus then return end
    frame.settingsStatus:SetText(text or "")
    frame.settingsStatus:SetTextColor(unpack(isError and Theme.color.danger or Theme.color.textSecondary))
    frame.settingsStatusGeneration = (frame.settingsStatusGeneration or 0) + 1
    if text and text ~= "" then
        local generation = frame.settingsStatusGeneration
        C_Timer.After(4, function()
            if frame.settingsStatusGeneration == generation and frame.settingsStatus then
                frame.settingsStatus:SetText("")
            end
        end)
    end
end

local function setControlEnabled(control, enabled)
    if not control then return end
    if enabled then
        if control.Enable then control:Enable() end
        control:SetAlpha(1)
        if control.text then control.text:SetTextColor(unpack(Theme.color.textPrimary)) end
    else
        if control.Disable then control:Disable() end
        control:SetAlpha(0.55)
        if control.text then control.text:SetTextColor(unpack(Theme.color.textSecondary)) end
    end
end

-- A `fitHeightToContent(panel, lastElement, margin)` helper used to live
-- here: it tried to size a panel from its own content's rendered

-- ---------------------------------------------------------------------------
-- Message Templates (Recruitment page → "Message Templates" sub-tab)
local MT = {}
MT.rowHeight = 26
MT.removePopup = "GUILDPARAGON_SETTINGS_REMOVE_RECRUITMENT_MESSAGE"

local function createLargeSettingsEditBox(parent, width, height, maxLetters)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    holder:SetSize(width, height)
    holder:SetBackdrop((Theme:Backdrop("panel", "border")))
    holder:SetBackdropColor(unpack(Theme.color.panel))
    holder:SetBackdropBorderColor(unpack(Theme.color.border))

    local box = CreateFrame("EditBox", nil, holder)
    box:SetPoint("TOPLEFT", 8, -6)
    box:SetPoint("BOTTOMRIGHT", -8, 6)
    box:SetFontObject(Theme.font.body)
    box:SetMultiLine(true)
    box:SetMaxLetters(maxLetters or 255)
    box:SetAutoFocus(false)
    box:SetJustifyV("TOP")
    box:SetTextInsets(0, 0, 0, 0)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnMouseDown", function() box:SetFocus() end)
    box.fixedHeight = height
    box.holder = holder
    return box
end

function MT.truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then
        return text:sub(1, maxChars) .. "…"
    end
    return text
end

function MT.selected()
    if not MT.selectedID then return nil end
    local Recruitment = GP:GetModule("Recruitment")
    return Recruitment:GetMessageRecord(Recruitment:GetCurrentGuildKey(), MT.selectedID)
end

function MT.updatePreview()
    if not MT.previewText then return end
    local Recruitment = GP:GetModule("Recruitment")
    local body = MT.bodyBox:GetText()
    local preview = Recruitment:RenderMessage(body, GP.L["Player"])
    local ok, err, length = Recruitment:ValidateMessage(body, GP.L["Player"])
    local limit = Recruitment:GetMessageLimit()

    MT.previewText:SetText(preview ~= "" and preview or GP.L["Type a recruitment message to preview it."])
    MT.countText:SetText(string.format(GP.L["Message length: %d / %d"], length or 0, limit))
    if ok or body == "" then
        MT.countText:SetTextColor(unpack(Theme.color.textSecondary))
    else
        MT.countText:SetTextColor(1, 0.35, 0.35)
        MT.previewText:SetText(err)
    end
end

function MT.clearForm()
    MT.selectedID = nil
    MT.titleBox:SetText("")
    MT.bodyBox:SetText("")
    MT.updatePreview()
end

function MT.loadForm(record)
    if not record then return end
    MT.titleBox:SetText(record.title or "")
    MT.bodyBox:SetText(record.body or "")
    MT.updatePreview()
end

function MT.refresh()
    if not MT.list then return end
    local Recruitment = GP:GetModule("Recruitment")
    local guildKey = Recruitment:GetCurrentGuildKey()
    MT.list:SetData(Recruitment:GetMessages(guildKey, MT.searchBox and MT.searchBox:GetText() or ""), false)

    local record = MT.selected()
    if record then
        MT.loadForm(record)
    else
        MT.updatePreview()
    end

    local locked = Recruitment:IsMessageEditingLocked()
    setControlEnabled(MT.titleBox, not locked)
    setControlEnabled(MT.bodyBox, not locked)
    setControlEnabled(MT.saveButton, not locked)
    setControlEnabled(MT.newButton, not locked)
    if locked then
        MT.useButton:Hide()
        MT.removeButton:Hide()
        if record then
            MT.testButton:Show()
        else
            MT.testButton:Hide()
        end
        MT.helpText:SetText(GP.L["Managed by the guild master — ask them to make changes."])
    else
        if record then
            MT.useButton:Show()
            MT.removeButton:Show()
            MT.testButton:Show()
        else
            MT.useButton:Hide()
            MT.removeButton:Hide()
            MT.testButton:Hide()
        end
        MT.helpText:SetText(GP.L["PLAYERNAME becomes the recruit's name, GUILDNAME becomes your guild name, and GUILDLINK becomes a guild link when testing or sending."])
    end
end

StaticPopupDialogs[MT.removePopup] = StaticPopupDialogs[MT.removePopup] or {
    text = GP.L["Delete recruitment message template \"%s\"?"],
    button1 = GP.L["Delete"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local ok, err = GP:GetModule("Recruitment"):RemoveMessage(data.guildKey, data.id)
        GP:Print(ok and GP.L["Recruitment message deleted."] or err)
        if ok then MT.clearForm() end
        MT.refresh()
    end,
}

function MT.createRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.title = row:CreateFontString(nil, "ARTWORK")
    row.title:SetFontObject(Theme.font.body)
    row.title:SetPoint("LEFT", 8, 0)
    row.title:SetWidth(130)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.status = row:CreateFontString(nil, "ARTWORK")
    row.status:SetFontObject(Theme.font.muted)
    row.status:SetPoint("LEFT", 144, 0)
    row.status:SetWidth(50)
    row.status:SetJustifyH("LEFT")

    -- Same word-wrap-off + truncate fix as the old Recruitment-tab list
    -- (and Roster/Alts tab rows before that) — bounded width with wrap left
    -- on lets a long saved message spill past the row into whatever's below.
    row.preview = row:CreateFontString(nil, "ARTWORK")
    row.preview:SetFontObject(Theme.font.muted)
    row.preview:SetPoint("LEFT", 198, 0)
    row.preview:SetPoint("RIGHT", -8, 0)
    row.preview:SetJustifyH("LEFT")
    row.preview:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        MT.selectedID = self.record and self.record.id or nil
        MT.refresh()
    end)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    end)
    row:SetScript("OnLeave", function(self)
        if self.record and MT.selectedID == self.record.id then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
            self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end)
    return row
end

function MT.updateRow(row, record)
    row.record = record
    row.title:SetText(MT.truncate(record.title or "?", 20))
    row.status:SetText(record.selected and GP.L["Active"] or "")
    row.preview:SetText(MT.truncate(record.body or "", 46))
    if MT.selectedID == record.id then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
        row:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

-- ---------------------------------------------------------------------------
-- Invalid Zones (Recruitment page → "Invalid Zones" sub-tab)
local IZ = {}
IZ.rowHeight = 24
IZ.removePopup = "GUILDPARAGON_SETTINGS_REMOVE_INVALID_ZONE"

function IZ.truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then
        return text:sub(1, maxChars) .. "…"
    end
    return text
end

function IZ.createLockedRow(parent)
    local row = CreateFrame("Frame", nil, parent)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(160)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.reason = row:CreateFontString(nil, "ARTWORK")
    row.reason:SetFontObject(Theme.font.muted)
    row.reason:SetPoint("LEFT", 176, 0)
    row.reason:SetPoint("RIGHT", -8, 0)
    row.reason:SetJustifyH("LEFT")
    row.reason:SetWordWrap(false)
    return row
end

function IZ.updateLockedRow(row, record)
    row.name:SetText(IZ.truncate(record.name or "?", 24))
    row.reason:SetText(record.reason or "")
end

function IZ.refreshLocked()
    if not IZ.lockedList then return end
    local Recruitment = GP:GetModule("Recruitment")
    IZ.lockedList:SetData(Recruitment:GetLockedInvalidZones(IZ.lockedSearchBox and IZ.lockedSearchBox:GetText() or ""), false)
end

function IZ.selectedCustom()
    if not IZ.selectedID then return nil end
    local Recruitment = GP:GetModule("Recruitment")
    return Recruitment:GetCustomInvalidZoneRecord(Recruitment:GetCurrentGuildKey(), IZ.selectedID)
end

function IZ.clearForm()
    IZ.selectedID = nil
    IZ.nameBox:SetText("")
    IZ.reasonBox:SetText("")
end

function IZ.loadForm(record)
    if not record then return end
    IZ.nameBox:SetText(record.name or "")
    IZ.reasonBox:SetText(record.reason or "")
end

function IZ.refreshCustom()
    if not IZ.customList then return end
    local Recruitment = GP:GetModule("Recruitment")
    local guildKey = Recruitment:GetCurrentGuildKey()
    IZ.customList:SetData(Recruitment:GetCustomInvalidZones(guildKey, IZ.customSearchBox and IZ.customSearchBox:GetText() or ""), false)

    local record = IZ.selectedCustom()
    if record then
        IZ.loadForm(record)
        IZ.detailText:SetText(string.format(GP.L["Added by: %s"], record.addedBy ~= "" and record.addedBy or GP.L["Unknown"]))
        IZ.removeButton:Show()
    else
        IZ.detailText:SetText(GP.L["Select a zone, or enter a name and reason to add your own invalid zone."])
        IZ.removeButton:Hide()
    end
end

StaticPopupDialogs[IZ.removePopup] = StaticPopupDialogs[IZ.removePopup] or {
    text = GP.L["Remove your invalid zone entry for %s?"],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local ok, err = GP:GetModule("Recruitment"):RemoveCustomInvalidZone(data.guildKey, data.id)
        GP:Print(ok and GP.L["Invalid zone record removed."] or err)
        if ok then IZ.clearForm() end
        IZ.refreshCustom()
    end,
}

function IZ.createCustomRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.reason = row:CreateFontString(nil, "ARTWORK")
    row.reason:SetFontObject(Theme.font.muted)
    row.reason:SetPoint("LEFT", 166, 0)
    row.reason:SetPoint("RIGHT", -8, 0)
    row.reason:SetJustifyH("LEFT")
    row.reason:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        IZ.selectedID = self.record and self.record.id or nil
        IZ.refreshCustom()
    end)
    row:SetScript("OnEnter", function(self)
        if IZ.selectedID ~= (self.record and self.record.id) then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
        end
    end)
    row:SetScript("OnLeave", function(self)
        if IZ.selectedID ~= (self.record and self.record.id) then
            self:SetBackdropColor(0, 0, 0, 0)
        end
    end)
    return row
end

function IZ.updateCustomRow(row, record)
    row.record = record
    row.name:SetText(IZ.truncate(record.name or "?", 20))
    row.reason:SetText(IZ.truncate(record.reason ~= "" and record.reason or GP.L["No reason given."], 38))
    if IZ.selectedID == record.id then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
    else
        row:SetBackdropColor(0, 0, 0, 0)
    end
end

-- ---------------------------------------------------------------------------
-- Recruitment filters (Recruitment page → "Filters" sub-tab)
-- ---------------------------------------------------------------------------
-- Saved class/race/level candidate criteria. State/helpers are grouped to
-- keep this large tab under Lua's upvalue limit.
local FT = {}
FT.rowHeight = 26
FT.removePopup = "GUILDPARAGON_SETTINGS_REMOVE_RECRUITMENT_FILTER"

function FT.truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then
        return text:sub(1, maxChars) .. "…"
    end
    return text
end

local function getCheckControls(checks)
    return checks and checks._controls or {}
end

local function countIDSet(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

function FT.summarize(record)
    local parts = {}
    local classCount, raceCount = countIDSet(record.classes), countIDSet(record.races)
    if classCount > 0 then table.insert(parts, string.format(GP.L["Classes: %d"], classCount)) end
    if raceCount > 0 then table.insert(parts, string.format(GP.L["Races: %d"], raceCount)) end
    if record.minLevel or record.maxLevel then
        table.insert(parts, string.format(GP.L["Level %s-%s"], record.minLevel or "1", record.maxLevel or "+"))
    end
    if #parts == 0 then return GP.L["Everyone"] end
    return table.concat(parts, "   ")
end

function FT.createRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(180)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.summary = row:CreateFontString(nil, "ARTWORK")
    row.summary:SetFontObject(Theme.font.muted)
    row.summary:SetPoint("LEFT", 196, 0)
    row.summary:SetPoint("RIGHT", -8, 0)
    row.summary:SetJustifyH("LEFT")
    row.summary:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        FT.selectedID = self.record and self.record.id or nil
        FT.refresh()
    end)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    end)
    row:SetScript("OnLeave", function(self)
        if self.record and FT.selectedID == self.record.id then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
            self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end)
    return row
end

function FT.updateRow(row, record)
    row.record = record
    row.name:SetText(FT.truncate(record.name or "?", 24))
    row.summary:SetText(FT.summarize(record))
    if FT.selectedID == record.id then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
        row:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

function FT.selected()
    if not FT.selectedID then return nil end
    local Recruitment = GP:GetModule("Recruitment")
    return Recruitment:GetFilterRecord(Recruitment:GetCurrentGuildKey(), FT.selectedID)
end

-- Applies a record's classes/races/level to the live editor controls —
-- shared by loadForm (loading a saved filter) and clearForm (loading an
-- empty one), so the checkbox-grid logic only lives once.
local function applyFilterToForm(record)
    for id, check in pairs(FT.classChecks or {}) do
        if id ~= "_controls" then
            check:SetChecked(record and record.classes and record.classes[id] or false)
        end
    end
    for _, check in ipairs(getCheckControls(FT.raceChecks)) do
        local checked = false
        for _, id in ipairs(check.filterIDs or {}) do
            if record and record.races and record.races[id] then
                checked = true
                break
            end
        end
        check:SetChecked(checked)
    end
    FT.minLevelBox:SetText(record and record.minLevel and tostring(record.minLevel) or "")
    FT.maxLevelBox:SetText(record and record.maxLevel and tostring(record.maxLevel) or "")
end

function FT.clearForm()
    FT.selectedID = nil
    FT.nameBox:SetText("")
    applyFilterToForm(nil)
end

function FT.loadForm(record)
    if not record then return end
    FT.nameBox:SetText(record.name or "")
    applyFilterToForm(record)
end

function FT.setEditorEnabled(enabled)
    setControlEnabled(FT.nameBox, enabled)
    setControlEnabled(FT.minLevelBox, enabled)
    setControlEnabled(FT.maxLevelBox, enabled)
    setControlEnabled(FT.saveButton, enabled)
    setControlEnabled(FT.newButton, enabled)
    setControlEnabled(FT.useButton, enabled)
    setControlEnabled(FT.removeButton, enabled)
    for _, check in ipairs(getCheckControls(FT.classChecks)) do
        setControlEnabled(check, enabled)
    end
    for _, check in ipairs(getCheckControls(FT.raceChecks)) do
        setControlEnabled(check, enabled)
        if enabled and check.oppositeFaction and check.text then
            check.text:SetTextColor(unpack(Theme.color.textSecondary))
        end
    end
end

function FT.refresh()
    if not FT.list then return end
    local Recruitment = GP:GetModule("Recruitment")
    local guildKey = Recruitment:GetCurrentGuildKey()
    local locked = Recruitment:IsFilterEditingLocked()
    FT.list:SetData(Recruitment:GetFilters(guildKey, FT.searchBox and FT.searchBox:GetText() or ""), false)
    FT.setEditorEnabled(not locked)

    local record = FT.selected()
    if record then
        FT.loadForm(record)
        if locked then
            FT.detailText:SetText(GP.L["The guild master has locked recruitment filters."])
            FT.useButton:Hide()
            FT.removeButton:Hide()
        else
            FT.detailText:SetText(string.format(GP.L["Added by: %s"], record.createdBy ~= "" and record.createdBy or GP.L["Unknown"]))
            FT.useButton:Show()
            FT.removeButton:Show()
        end
    else
        FT.detailText:SetText(locked and GP.L["The guild master has locked recruitment filters."] or GP.L["Select a filter, or choose classes/races/level and enter a name to add your own."])
        FT.useButton:Hide()
        FT.removeButton:Hide()
    end
end

StaticPopupDialogs[FT.removePopup] = StaticPopupDialogs[FT.removePopup] or {
    text = GP.L["Delete recruitment filter \"%s\"?"],
    button1 = GP.L["Delete"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        local ok, err = GP:GetModule("Recruitment"):RemoveFilter(data.guildKey, data.id)
        GP:Print(ok and GP.L["Recruitment filter deleted."] or err)
        if ok then FT.clearForm() end
        FT.refresh()
    end,
}

local function buildFilterCheckGrid(parent, items, columns, colWidth, rowHeight)
    local checks = { _controls = {} }
    local myFaction = GP:SafeOptionalString(GP:SafeCall(UnitFactionGroup, nil, "player"))
    for index, item in ipairs(items) do
        local col = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local label = item.name
        if item.faction and item.faction ~= "Both" and item.faction ~= myFaction then
            label = string.format("%s (%s)", item.name, item.faction)
        end
        local check = createCheck(parent, label)
        check:SetPoint("TOPLEFT", col * colWidth, -row * rowHeight)
        fitCheckLabel(check, colWidth - 30)
        check.filterIDs = item.ids or { item.id }
        check.oppositeFaction = item.oppositeFaction and true or false
        if check.oppositeFaction and check.text then
            check.text:SetTextColor(unpack(Theme.color.textSecondary))
        end
        checks[item.id] = check
        table.insert(checks._controls, check)
    end
    return checks
end

-- ---------------------------------------------------------------------------
-- Officer Labels (own top-level "Labels" tab)
local LB = {}
LB.rowHeight = 20
LB.assignedRowHeight = 24

-- Fixed palette; no ColorPickerFrame dependency.
LB.PALETTE = {
    Theme.color.accent,
    Theme.color.info,
    Theme.color.success,
    Theme.color.warning,
    Theme.color.danger,
    { 0.647, 0.475, 0.925 }, -- purple
    { 0.929, 0.514, 0.694 }, -- pink
    Theme.color.textSecondary,
}

function LB.truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then
        return text:sub(1, maxChars) .. "…"
    end
    return text
end

function LB.createRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.swatch = row:CreateTexture(nil, "ARTWORK")
    row.swatch:SetSize(14, 14)
    row.swatch:SetPoint("LEFT", 8, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", row.swatch, "RIGHT", 8, 0)
    row.name:SetWidth(220)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.usage = row:CreateFontString(nil, "ARTWORK")
    row.usage:SetFontObject(Theme.font.muted)
    row.usage:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.usage:SetPoint("RIGHT", -8, 0)
    row.usage:SetJustifyH("LEFT")
    row.usage:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        LB.selectedID = self.record and self.record.labelId or nil
        LB.refresh()
    end)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    end)
    row:SetScript("OnLeave", function(self)
        if self.record and LB.selectedID == self.record.labelId then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
            self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end)
    return row
end

function LB.updateRow(row, record)
    row.record = record
    row.swatch:SetColorTexture(unpack(record.color))

    local nameText = LB.truncate(record.name or "?", 30)
    if record.archived then
        nameText = nameText .. " " .. GP.L["(archived)"]
    end
    row.name:SetText(nameText)
    row.name:SetTextColor(unpack(record.archived and Theme.color.textSecondary or Theme.color.textPrimary))

    local guildKey = GP:GetModule("Labels"):GetCurrentGuildKey()
    local count = #GP:GetModule("Labels"):GetPlayersForLabel(guildKey, record.labelId)
    row.usage:SetText(string.format(GP.L["%d player(s)"], count))

    if LB.selectedID == record.labelId then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
        row:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

function LB.assignedRows(guildKey, labelId)
    local Labels = GP:GetModule("Labels")
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local rows = {}
    for _, guid in ipairs(Labels:GetPlayersForLabel(guildKey, labelId)) do
        local player = guildData and ((guildData.roster or {})[guid] or (guildData.formerMembers or {})[guid])
        if player then
            rows[#rows + 1] = {
                guid = guid,
                name = player.name or "?",
                rankName = player.rankName or "",
                classFile = player.classFile,
                active = guildData.roster and guildData.roster[guid] ~= nil,
            }
        end
    end
    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)
    return rows
end

function LB.openAssignedPlayer(guid, name)
    local MainWindow = GP.UI.MainWindow
    local RosterTab = GP.UI.RosterTab
    if not MainWindow or not RosterTab then return end

    MainWindow:SelectTab("roster")
    if not RosterTab:SelectPlayerByGUID(guid, name) then
        GP:Print(GP.L["Player not found."])
    end
end

function LB.createAssignedRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(220)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.rank = row:CreateFontString(nil, "ARTWORK")
    row.rank:SetFontObject(Theme.font.muted)
    row.rank:SetPoint("LEFT", row.name, "RIGHT", 12, 0)
    row.rank:SetWidth(180)
    row.rank:SetJustifyH("LEFT")
    row.rank:SetWordWrap(false)

    row.status = row:CreateFontString(nil, "ARTWORK")
    row.status:SetFontObject(Theme.font.muted)
    row.status:SetPoint("LEFT", row.rank, "RIGHT", 12, 0)
    row.status:SetPoint("RIGHT", -8, 0)
    row.status:SetJustifyH("LEFT")
    row.status:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        if self.record then LB.openAssignedPlayer(self.record.guid, self.record.name) end
    end)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(0, 0, 0, 0)
    end)
    return row
end

function LB.updateAssignedRow(row, record)
    row.record = record
    local color = record.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[record.classFile]
    if color then
        row.name:SetTextColor(color.r, color.g, color.b)
    else
        row.name:SetTextColor(unpack(Theme.color.textPrimary))
    end
    row.name:SetText(LB.truncate(record.name or "?", 28))
    row.rank:SetText(LB.truncate(record.rankName or "", 24))
    row.status:SetText(record.active and GP.L["Active"] or GP.L["Former"])
    row.status:SetTextColor(unpack(record.active and Theme.color.success or Theme.color.textSecondary))
end

-- One swatch button per LB.PALETTE entry, built once in Settings:Build and
-- reused for the whole login — a fixed 8-color grid, not a per-row
-- widget the ScrollList would need to recycle.
function LB.createPaletteSwatch(parent, color)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(22, 22)
    button:SetBackdrop((Theme:Backdrop("panel", "border")))
    button:SetBackdropColor(unpack(color))
    button.color = color
    button:SetScript("OnClick", function()
        LB.selectedColor = color
        LB.refreshPaletteHighlight()
    end)
    return button
end

function LB.refreshPaletteHighlight()
    for _, button in ipairs(LB.paletteButtons or {}) do
        if button.color == LB.selectedColor then
            button:SetBackdropBorderColor(unpack(Theme.color.accent))
        else
            button:SetBackdropBorderColor(unpack(Theme.color.border))
        end
    end
end

function LB.selected()
    if not LB.selectedID then return nil end
    local Labels = GP:GetModule("Labels")
    for _, record in ipairs(Labels:GetAllLabelDefinitions(Labels:GetCurrentGuildKey(), true)) do
        if record.labelId == LB.selectedID then return record end
    end
    return nil
end

function LB.clearForm()
    LB.selectedID = nil
    LB.nameBox:SetText("")
    LB.selectedColor = LB.PALETTE[1]
    LB.refreshPaletteHighlight()
    if LB.assignedList then LB.assignedList:SetData({}, true) end
end

function LB.loadForm(record)
    if not record then return end
    LB.nameBox:SetText(record.name or "")
    LB.selectedColor = record.color
    LB.refreshPaletteHighlight()
end

function LB.refresh()
    local Labels = GP:GetModule("Labels")
    local isOfficer = Labels:CanUse()
    if LB.tabButton then LB.tabButton:SetShown(isOfficer) end
    if not isOfficer or not LB.list then return end

    local guildKey = Labels:GetCurrentGuildKey()
    Labels:SeedDefaultsIfEmpty(guildKey)

    LB.list:SetData(Labels:GetAllLabelDefinitions(guildKey, LB.showArchivedCheck and LB.showArchivedCheck:GetChecked() or false,
        LB.searchBox and LB.searchBox:GetText() or nil), false)

    local record = LB.selected()
    if record then
        LB.loadForm(record)
        LB.archiveButton:SetText(record.archived and GP.L["Unarchive"] or GP.L["Archive"])
        LB.archiveButton:Show()
        local assignedRows = LB.assignedRows(guildKey, record.labelId)
        local count = #assignedRows
        LB.detailText:SetText(string.format(GP.L["%d player(s) currently carry this label."], count))
        if LB.assignedList then LB.assignedList:SetData(assignedRows, true) end
        if LB.assignedEmptyText then LB.assignedEmptyText:SetShown(count == 0) end
    else
        LB.archiveButton:Hide()
        LB.detailText:SetText(GP.L["Select a label, or enter a name and pick a color to create a new one."])
        if LB.assignedList then LB.assignedList:SetData({}, true) end
        if LB.assignedEmptyText then LB.assignedEmptyText:Show() end
    end
end

local GH = {}
GH.macroIgnoreRowHeight = 24
GH.macroActions = { "kick", "promote", "demote", "special" }

function GH.actionLabel(key)
    if key == "kick" then return GP.L["Kick"] end
    if key == "promote" then return GP.L["Promote"] end
    if key == "demote" then return GP.L["Demote"] end
    if key == "special" then return GP.L["Special"] end
    return tostring(key or "")
end

function GH.macroIgnoreRows()
    local Roster = GP:GetModule("Roster", true)
    local guildKey = Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil
    local guildData = guildKey and GP.db.global.guilds[guildKey] or nil
    local groups = {}
    local rows = {}

    for guid, ignore in pairs((guildData and guildData.macroIgnores) or {}) do
        if type(ignore) == "table" and next(ignore) then
            local mainGUID = (guildData.alts or {})[guid] or guid
            local group = groups[mainGUID]
            if not group then
                group = { guid = mainGUID, actionSet = {}, updatedAt = 0, fallbackGUID = guid }
                groups[mainGUID] = group
            end
            for action in pairs(ignore) do
                group.actionSet[action] = true
            end
            local updatedAt = tonumber(guildData.macroIgnoresUpdated and guildData.macroIgnoresUpdated[guid]) or 0
            if updatedAt > (group.updatedAt or 0) then group.updatedAt = updatedAt end
            if not ((guildData.roster or {})[mainGUID] or (guildData.formerMembers or {})[mainGUID]) then
                group.fallbackGUID = group.fallbackGUID or guid
            end
        end
    end

    for mainGUID, group in pairs(groups) do
        local displayGUID = ((guildData.roster or {})[mainGUID] or (guildData.formerMembers or {})[mainGUID]) and mainGUID or group.fallbackGUID
        local player = (guildData.roster or {})[displayGUID] or (guildData.formerMembers or {})[displayGUID]
        local actions = {}
        for _, action in ipairs(GH.macroActions) do
            if group.actionSet[action] then actions[#actions + 1] = GH.actionLabel(action) end
        end
        rows[#rows + 1] = {
            guid = displayGUID,
            name = player and player.name or displayGUID,
            classFile = player and player.classFile or nil,
            active = guildData.roster and guildData.roster[displayGUID] ~= nil,
            actions = table.concat(actions, ", "),
            updatedAt = group.updatedAt and group.updatedAt > 0 and group.updatedAt or nil,
        }
    end

    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)
    return rows
end

function GH.openMacroIgnorePlayer(guid, name)
    local MainWindow = GP.UI.MainWindow
    local RosterTab = GP.UI.RosterTab
    if not MainWindow or not RosterTab then return end

    MainWindow:SelectTab("roster")
    if not RosterTab:SelectPlayerByGUID(guid, name) then
        GP:Print(GP.L["Player not found."])
    end
end

function GH.createMacroIgnoreRow(parent)
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

    row.actions = row:CreateFontString(nil, "ARTWORK")
    row.actions:SetFontObject(Theme.font.muted)
    row.actions:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
    row.actions:SetWidth(180)
    row.actions:SetJustifyH("LEFT")
    row.actions:SetWordWrap(false)

    row.updated = row:CreateFontString(nil, "ARTWORK")
    row.updated:SetFontObject(Theme.font.muted)
    row.updated:SetPoint("LEFT", row.actions, "RIGHT", 10, 0)
    row.updated:SetPoint("RIGHT", -8, 0)
    row.updated:SetJustifyH("LEFT")
    row.updated:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        if self.record then GH.openMacroIgnorePlayer(self.record.guid, self.record.name) end
    end)
    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(0, 0, 0, 0)
    end)
    return row
end

function GH.updateMacroIgnoreRow(row, record)
    row.record = record
    local color = record.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[record.classFile]
    if color then
        row.name:SetTextColor(color.r, color.g, color.b)
    else
        row.name:SetTextColor(unpack(Theme.color.textPrimary))
    end
    row.name:SetText(LB.truncate(record.name or "?", 22))
    row.actions:SetText(record.actions or "")
    row.updated:SetText(record.updatedAt and date("%Y-%m-%d", record.updatedAt) or GP.L["Never"])
end

function GH.refreshMacroIgnores()
    if not GH.macroIgnoreList then return end
    local rows = GH.macroIgnoreRows()
    GH.macroIgnoreList:SetData(rows, true)
    if GH.macroIgnoreCountText then
        GH.macroIgnoreCountText:SetText(string.format(GP.L["%d macro ignore player(s)"], #rows))
    end
    if GH.macroIgnoreEmptyText then
        GH.macroIgnoreEmptyText:SetShown(#rows == 0)
    end
end

local function refreshPerformanceText(frame)
    if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
    local memoryKb = GetAddOnMemoryUsage and GetAddOnMemoryUsage(ADDON_NAME) or 0
    local luaKb = collectgarbage and collectgarbage("count") or 0
    frame.performanceText:SetText(string.format(GP.L["Addon memory: %.1f MB   Lua memory: %.1f MB"], (memoryKb or 0) / 1024, (luaKb or 0) / 1024))
end

local function displayGuildName(guildKey)
    local guildName = GP:SafeOptionalString(GP:SafeCall(GetGuildInfo, nil, "player"))
    if guildName and guildName ~= "" then return guildName end
    return tostring(guildKey or ""):match("^(.-)%-%d+$") or guildKey or "?"
end

local function createSettingsTabButton(parent, label)
    local button = Theme:CreateButton(parent, label)
    button:SetHeight(28)
    function button:SetSelected(selected)
        self.selected = selected
        if selected then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
            self:SetBackdropBorderColor(unpack(Theme.color.accent))
            self.text:SetFontObject(Theme.font.heading)
        else
            self:SetBackdropColor(unpack(Theme.color.panel))
            self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
            self.text:SetFontObject(Theme.font.body)
        end
    end
    button:SetScript("OnEnter", function(self)
        self:SetBackdropColor(unpack(Theme.color.panelRaised))
        self:SetBackdropBorderColor(unpack(Theme.color.accent))
    end)
    button:SetScript("OnLeave", function(self)
        self:SetSelected(self.selected)
    end)
    button:SetSelected(false)
    return button
end

local function buildHealthSettingsPage(frame, healthPage)
    local L = GP.L
    local HEALTH_LEFT_WIDTH = 500
    local HEALTH_RIGHT_WIDTH = 520
    local health = createSection(healthPage, L["Guild Health"])
    health:SetPoint("TOPLEFT", 0, 0)
    health:SetSize(HEALTH_LEFT_WIDTH, 335)

    local healthSettings = ensureGuildHealthSettings()
    local birthdayHealthCheck = createCheck(health, L["Show missing birthdays as Guild Health issue"])
    birthdayHealthCheck:SetPoint("TOPLEFT", health.heading, "BOTTOMLEFT", 0, -8)
    birthdayHealthCheck:SetChecked(healthSettings.showBirthdayIssues)
    local birthdayHealthDesc = addOptionDescription(health, birthdayHealthCheck, L["When disabled, missing birthdays do not appear in Guild Health attention rows or counts."], 380)

    local ignoreAltActivityCheck = createCheck(health, L["Ignore inactive linked characters when group is active"])
    ignoreAltActivityCheck:SetPoint("TOPLEFT", birthdayHealthDesc, "BOTTOMLEFT", -26, -8)
    ignoreAltActivityCheck:SetChecked(healthSettings.ignoreAltsWhenMainActive)
    local ignoreAltActivityDesc = addOptionDescription(health, ignoreAltActivityCheck, L["Prevents linked characters from appearing as inactivity risks while any character in their main/alt group is active within the configured active window."], 380)

    local activeDaysLabel = health:CreateFontString(nil, "ARTWORK")
    activeDaysLabel:SetFontObject(Theme.font.body)
    activeDaysLabel:SetPoint("TOPLEFT", ignoreAltActivityDesc, "BOTTOMLEFT", 0, -12)
    activeDaysLabel:SetText(L["Active window days:"])

    local activeDaysBox = Theme:CreateEditBox(health, 46)
    activeDaysBox:SetPoint("LEFT", activeDaysLabel, "RIGHT", 8, 0)
    activeDaysBox:SetNumeric(true)
    activeDaysBox:SetText(tostring(healthSettings.activeDays))

    local fadingDaysLabel = health:CreateFontString(nil, "ARTWORK")
    fadingDaysLabel:SetFontObject(Theme.font.body)
    fadingDaysLabel:SetPoint("TOPLEFT", activeDaysLabel, "BOTTOMLEFT", 0, -12)
    fadingDaysLabel:SetText(L["Fading days:"])

    local fadingDaysBox = Theme:CreateEditBox(health, 46)
    fadingDaysBox:SetPoint("LEFT", fadingDaysLabel, "RIGHT", 8, 0)
    fadingDaysBox:SetNumeric(true)
    fadingDaysBox:SetText(tostring(healthSettings.fadingDays))

    local atRiskDaysLabel = health:CreateFontString(nil, "ARTWORK")
    atRiskDaysLabel:SetFontObject(Theme.font.body)
    atRiskDaysLabel:SetPoint("LEFT", fadingDaysBox, "RIGHT", 18, 0)
    atRiskDaysLabel:SetText(L["At-risk days:"])

    local atRiskDaysBox = Theme:CreateEditBox(health, 46)
    atRiskDaysBox:SetPoint("LEFT", atRiskDaysLabel, "RIGHT", 8, 0)
    atRiskDaysBox:SetNumeric(true)
    atRiskDaysBox:SetText(tostring(healthSettings.atRiskDays))

    local goneDaysLabel = health:CreateFontString(nil, "ARTWORK")
    goneDaysLabel:SetFontObject(Theme.font.body)
    goneDaysLabel:SetPoint("TOPLEFT", fadingDaysLabel, "BOTTOMLEFT", 0, -12)
    goneDaysLabel:SetText(L["Gone days:"])

    local goneDaysBox = Theme:CreateEditBox(health, 46)
    goneDaysBox:SetPoint("LEFT", goneDaysLabel, "RIGHT", 8, 0)
    goneDaysBox:SetNumeric(true)
    goneDaysBox:SetText(tostring(healthSettings.goneDays))

    local mythicSeasonLabel = health:CreateFontString(nil, "ARTWORK")
    mythicSeasonLabel:SetFontObject(Theme.font.body)
    mythicSeasonLabel:SetPoint("TOPLEFT", goneDaysLabel, "BOTTOMLEFT", 0, -14)
    mythicSeasonLabel:SetText(L["Mythic+ season start:"])

    local mythicSeasonDesc = addOptionDescription(health, mythicSeasonLabel, L["Insert the current Mythic+ season start as YYYY-MM-DD HH:MM. Guild Health treats imported M+ scores as unrated until a character has logged in since this time."], HEALTH_LEFT_WIDTH - Theme.layout.gutter * 4)
    mythicSeasonDesc:ClearAllPoints()
    mythicSeasonDesc:SetPoint("TOPLEFT", mythicSeasonLabel, "BOTTOMLEFT", 0, -1)

    local mythicSeasonBox = Theme:CreateEditBox(health, 132)
    mythicSeasonBox:SetPoint("TOPLEFT", mythicSeasonDesc, "BOTTOMLEFT", 0, -10)
    mythicSeasonBox:SetText(tostring(healthSettings.mythicSeasonStartDate or ""))

    local macroIgnores = createSection(healthPage, L["Macro Rule Ignores"])
    macroIgnores:SetPoint("TOPLEFT", health, "BOTTOMLEFT", 0, -SECTION_GAP)
    macroIgnores:SetSize(HEALTH_LEFT_WIDTH, 220)

    local macroIgnoresDesc = addBodyText(macroIgnores, macroIgnores.heading, L["Players excluded from Macro Tool actions."], HEALTH_LEFT_WIDTH - Theme.layout.gutter * 2)
    macroIgnoresDesc:SetFontObject(Theme.font.small)
    macroIgnoresDesc:SetTextColor(unpack(Theme.color.textSecondary))

    GH.macroIgnoreCountText = macroIgnores:CreateFontString(nil, "ARTWORK")
    GH.macroIgnoreCountText:SetFontObject(Theme.font.small)
    GH.macroIgnoreCountText:SetPoint("TOPRIGHT", macroIgnores, "TOPRIGHT", -Theme.layout.gutter, -Theme.layout.gutter - 2)
    GH.macroIgnoreCountText:SetJustifyH("RIGHT")

    local macroIgnoreHeader = CreateFrame("Frame", nil, macroIgnores)
    macroIgnoreHeader:SetPoint("TOPLEFT", macroIgnoresDesc, "BOTTOMLEFT", 0, -12)
    macroIgnoreHeader:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    macroIgnoreHeader:SetHeight(18)

    local macroIgnoreNameHeader = macroIgnoreHeader:CreateFontString(nil, "ARTWORK")
    macroIgnoreNameHeader:SetFontObject(Theme.font.small)
    macroIgnoreNameHeader:SetPoint("LEFT", 8, 0)
    macroIgnoreNameHeader:SetText(L["Player"])

    local macroIgnoreActionsHeader = macroIgnoreHeader:CreateFontString(nil, "ARTWORK")
    macroIgnoreActionsHeader:SetFontObject(Theme.font.small)
    macroIgnoreActionsHeader:SetPoint("LEFT", macroIgnoreNameHeader, "LEFT", 170, 0)
    macroIgnoreActionsHeader:SetText(L["Actions"])

    local macroIgnoreUpdatedHeader = macroIgnoreHeader:CreateFontString(nil, "ARTWORK")
    macroIgnoreUpdatedHeader:SetFontObject(Theme.font.small)
    macroIgnoreUpdatedHeader:SetPoint("LEFT", macroIgnoreActionsHeader, "LEFT", 190, 0)
    macroIgnoreUpdatedHeader:SetText(L["Updated"])

    local macroIgnoreListPanel = Theme:CreatePanel(macroIgnores, "panel", "border")
    macroIgnoreListPanel:SetPoint("TOPLEFT", macroIgnoreHeader, "BOTTOMLEFT", 0, -4)
    macroIgnoreListPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    GH.macroIgnoreList = GP.UI.ScrollList:New(macroIgnoreListPanel, GH.macroIgnoreRowHeight, GH.createMacroIgnoreRow)
    GH.macroIgnoreList:SetUpdateRow(GH.updateMacroIgnoreRow)
    GH.macroIgnoreEmptyText = macroIgnoreListPanel:CreateFontString(nil, "ARTWORK")
    GH.macroIgnoreEmptyText:SetFontObject(Theme.font.body)
    GH.macroIgnoreEmptyText:SetTextColor(unpack(Theme.color.textSecondary))
    GH.macroIgnoreEmptyText:SetJustifyH("LEFT")
    GH.macroIgnoreEmptyText:SetText(L["No players currently have macro ignore settings."])
    GH.macroIgnoreEmptyText:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    GH.macroIgnoreEmptyText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    GH.refreshMacroIgnores()

    local newMember = createSection(healthPage, L["New Member Follow-up"])
    newMember:SetPoint("TOPLEFT", health, "TOPRIGHT", SECTION_GAP, 0)
    newMember:SetSize(HEALTH_RIGHT_WIDTH, 280)

    local newMemberDesc = addBodyText(newMember, newMember.heading, L["Configure which recent members appear in Guild Health's New Members attention view."], HEALTH_RIGHT_WIDTH - Theme.layout.gutter * 2)
    newMemberDesc:SetFontObject(Theme.font.small)
    newMemberDesc:SetTextColor(unpack(Theme.color.textSecondary))

    local newMemberWindowLabel = newMember:CreateFontString(nil, "ARTWORK")
    newMemberWindowLabel:SetFontObject(Theme.font.body)
    newMemberWindowLabel:SetPoint("TOPLEFT", newMemberDesc, "BOTTOMLEFT", 0, -12)
    newMemberWindowLabel:SetText(L["Recent member window days:"])

    local newMemberWindowBox = Theme:CreateEditBox(newMember, 46)
    newMemberWindowBox:SetPoint("LEFT", newMemberWindowLabel, "RIGHT", 8, 0)
    newMemberWindowBox:SetNumeric(true)
    newMemberWindowBox:SetText(tostring(healthSettings.newMemberWindowDays))

    local newMemberRankLabel = newMember:CreateFontString(nil, "ARTWORK")
    newMemberRankLabel:SetFontObject(Theme.font.body)
    newMemberRankLabel:SetPoint("TOPLEFT", newMemberWindowLabel, "BOTTOMLEFT", 0, -12)
    newMemberRankLabel:SetText(L["New-member rank:"])

    local selectedNewMemberRank = tostring(healthSettings.newMemberRankName or "")
    local selectedPromotionRankIndex = tonumber(healthSettings.newMemberPromotionRankIndex)
    local rankPickerButtons = {}
    local promotionRankPickerButtons = {}

    local function rankDisplayName(rankIndex)
        if rankIndex == nil then return L["Any rank"] end
        if GuildControlGetRankName then
            local ok, name = pcall(GuildControlGetRankName, rankIndex + 1)
            name = ok and GP:SafeOptionalString(name) or nil
            if name and name ~= "" then return name end
        end
        return string.format(L["Rank %d"], rankIndex)
    end

    local function collectGuildRanks()
        local ranks = {}
        if GuildControlGetNumRanks then
            local ok, count = pcall(GuildControlGetNumRanks)
            count = ok and tonumber(count) or nil
            if count and count > 0 then
                for rankIndex = 0, count - 1 do
                    table.insert(ranks, rankIndex)
                end
                return ranks
            end
        end

        local Roster = GP:GetModule("Roster", true)
        local guildKey = Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil
        local guildData = guildKey and GP.db.global.guilds[guildKey] or nil
        local seen = {}
        for _, player in pairs((guildData and guildData.roster) or {}) do
            local rankIndex = tonumber(player.rankIndex)
            if rankIndex and not seen[rankIndex] then
                seen[rankIndex] = true
                table.insert(ranks, rankIndex)
            end
        end
        table.sort(ranks)
        return ranks
    end

    local rankButton = Theme:CreateButton(newMember, "")
    rankButton:SetPoint("LEFT", newMemberRankLabel, "RIGHT", 8, 0)
    rankButton:SetSize(160, 24)

    local rankPicker = Theme:CreatePanel(newMember, "panelRaised", "border")
    rankPicker:SetPoint("TOPLEFT", rankButton, "BOTTOMLEFT", 0, -4)
    rankPicker:SetWidth(176)
    rankPicker:SetFrameLevel(rankButton:GetFrameLevel() + 8)
    rankPicker:Hide()

    local function refreshRankButton()
        rankButton.text:SetText(selectedNewMemberRank ~= "" and selectedNewMemberRank or L["Any rank"])
    end

    local function hideRankPicker()
        rankPicker:Hide()
    end

    local function refreshRankPicker()
        for _, button in ipairs(rankPickerButtons) do
            button:Hide()
        end

        local ranks = collectGuildRanks()
        local previous
        local optionIndex = 0
        local function addRankOption(label, value)
            optionIndex = optionIndex + 1
            local button = rankPickerButtons[optionIndex]
            if not button then
                button = Theme:CreateButton(rankPicker, "")
                button:SetSize(160, 23)
                rankPickerButtons[optionIndex] = button
            end
            button.text:SetText(label)
            button.value = value
            button:ClearAllPoints()
            if previous then
                button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
            else
                button:SetPoint("TOPLEFT", 8, -8)
            end
            button:SetScript("OnClick", function(self)
                selectedNewMemberRank = tostring(self.value or "")
                refreshRankButton()
                hideRankPicker()
            end)
            button:Show()
            previous = button
        end

        addRankOption(L["Any rank"], "")
        for _, rankIndex in ipairs(ranks) do
            addRankOption(rankDisplayName(rankIndex), rankDisplayName(rankIndex))
        end
        rankPicker:SetHeight(16 + (#ranks + 1) * 25)
    end

    rankButton:SetScript("OnClick", function()
        if rankPicker:IsShown() then
            hideRankPicker()
        else
            refreshRankPicker()
            rankPicker:Show()
        end
    end)
    refreshRankButton()

    local promotionDaysLabel = newMember:CreateFontString(nil, "ARTWORK")
    promotionDaysLabel:SetFontObject(Theme.font.body)
    promotionDaysLabel:SetPoint("TOPLEFT", newMemberRankLabel, "BOTTOMLEFT", 0, -12)
    promotionDaysLabel:SetText(L["Promotion review days:"])

    local promotionDaysBox = Theme:CreateEditBox(newMember, 46)
    promotionDaysBox:SetPoint("LEFT", promotionDaysLabel, "RIGHT", 8, 0)
    promotionDaysBox:SetNumeric(true)
    promotionDaysBox:SetText(tostring(healthSettings.newMemberPromotionDays))

    local promotionRankLabel = newMember:CreateFontString(nil, "ARTWORK")
    promotionRankLabel:SetFontObject(Theme.font.body)
    promotionRankLabel:SetPoint("LEFT", promotionDaysBox, "RIGHT", 18, 0)
    promotionRankLabel:SetText(L["Rank after promotion:"])

    local promotionRankButton = Theme:CreateButton(newMember, "")
    promotionRankButton:SetPoint("LEFT", promotionRankLabel, "RIGHT", 8, 0)
    promotionRankButton:SetSize(150, 24)

    local promotionRankPicker = Theme:CreatePanel(newMember, "panelRaised", "border")
    promotionRankPicker:SetPoint("TOPLEFT", promotionRankButton, "BOTTOMLEFT", 0, -4)
    promotionRankPicker:SetWidth(166)
    promotionRankPicker:SetFrameLevel(promotionRankButton:GetFrameLevel() + 8)
    promotionRankPicker:Hide()

    local function refreshPromotionRankButton()
        promotionRankButton.text:SetText(selectedPromotionRankIndex ~= nil and rankDisplayName(selectedPromotionRankIndex) or L["Select rank"])
    end

    local function hidePromotionRankPicker()
        promotionRankPicker:Hide()
    end

    local function refreshPromotionRankPicker()
        for _, button in ipairs(promotionRankPickerButtons) do
            button:Hide()
        end

        local ranks = collectGuildRanks()
        local previous
        local optionIndex = 0
        for _, rankIndex in ipairs(ranks) do
            optionIndex = optionIndex + 1
            local button = promotionRankPickerButtons[optionIndex]
            if not button then
                button = Theme:CreateButton(promotionRankPicker, "")
                button:SetSize(150, 23)
                promotionRankPickerButtons[optionIndex] = button
            end
            button.text:SetText(rankDisplayName(rankIndex))
            button.value = rankIndex
            button:ClearAllPoints()
            if previous then
                button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
            else
                button:SetPoint("TOPLEFT", 8, -8)
            end
            button:SetScript("OnClick", function(self)
                selectedPromotionRankIndex = tonumber(self.value)
                refreshPromotionRankButton()
                hidePromotionRankPicker()
            end)
            button:Show()
            previous = button
        end
        promotionRankPicker:SetHeight(16 + math.max(1, #ranks) * 25)
    end

    promotionRankButton:SetScript("OnClick", function()
        if promotionRankPicker:IsShown() then
            hidePromotionRankPicker()
        else
            refreshPromotionRankPicker()
            promotionRankPicker:Show()
        end
    end)
    refreshPromotionRankButton()

    local noteCheck = createCheck(newMember, L["Flag missing notes"])
    noteCheck:SetPoint("TOPLEFT", promotionDaysLabel, "BOTTOMLEFT", -2, -12)
    noteCheck:SetChecked(healthSettings.newMemberCheckNote)

    local labelCheck = createCheck(newMember, L["Flag missing labels"])
    labelCheck:SetPoint("LEFT", noteCheck, "RIGHT", 180, 0)
    labelCheck:SetChecked(healthSettings.newMemberCheckLabel)

    local birthdayCheck = createCheck(newMember, L["Flag missing birthdays"])
    birthdayCheck:SetPoint("TOPLEFT", noteCheck, "BOTTOMLEFT", 0, -8)
    birthdayCheck:SetChecked(healthSettings.newMemberCheckBirthday)

    local altMainCheck = createCheck(newMember, L["Flag missing alt/main tags"])
    altMainCheck:SetPoint("LEFT", birthdayCheck, "RIGHT", 180, 0)
    altMainCheck:SetChecked(healthSettings.newMemberCheckAltMain)

    local function saveHealthSettings()
        local GuildHealth = GP:GetModule("GuildHealth")
        local saved = GuildHealth:SaveSettings({
            showBirthdayIssues = birthdayHealthCheck:GetChecked(),
            ignoreAltsWhenMainActive = ignoreAltActivityCheck:GetChecked(),
            activeDays = activeDaysBox:GetText(),
            fadingDays = fadingDaysBox:GetText(),
            atRiskDays = atRiskDaysBox:GetText(),
            goneDays = goneDaysBox:GetText(),
            mythicSeasonStartDate = mythicSeasonBox:GetText(),
            newMemberWindowDays = newMemberWindowBox:GetText(),
            newMemberRankName = selectedNewMemberRank,
            newMemberPromotionRankIndex = selectedPromotionRankIndex,
            newMemberPromotionDays = promotionDaysBox:GetText(),
            newMemberCheckNote = noteCheck:GetChecked(),
            newMemberCheckLabel = labelCheck:GetChecked(),
            newMemberCheckBirthday = birthdayCheck:GetChecked(),
            newMemberCheckAltMain = altMainCheck:GetChecked(),
        })
        activeDaysBox:SetText(tostring(saved.activeDays))
        fadingDaysBox:SetText(tostring(saved.fadingDays))
        atRiskDaysBox:SetText(tostring(saved.atRiskDays))
        goneDaysBox:SetText(tostring(saved.goneDays))
        mythicSeasonBox:SetText(tostring(saved.mythicSeasonStartDate or ""))
        newMemberWindowBox:SetText(tostring(saved.newMemberWindowDays))
        selectedNewMemberRank = tostring(saved.newMemberRankName or "")
        selectedPromotionRankIndex = tonumber(saved.newMemberPromotionRankIndex)
        refreshRankButton()
        hideRankPicker()
        refreshPromotionRankButton()
        hidePromotionRankPicker()
        promotionDaysBox:SetText(tostring(saved.newMemberPromotionDays))
        setSettingsStatus(frame, L["Guild Health settings saved."])
    end

    local saveHealthButton = Theme:CreateButton(health, L["Save Settings"])
    saveHealthButton:SetPoint("TOPLEFT", mythicSeasonBox, "BOTTOMLEFT", 0, -14)
    saveHealthButton:SetScript("OnClick", saveHealthSettings)

    local saveNewMemberButton = Theme:CreateButton(newMember, L["Save Settings"])
    saveNewMemberButton:SetPoint("TOPLEFT", birthdayCheck, "BOTTOMLEFT", 2, -14)
    saveNewMemberButton:SetScript("OnClick", saveHealthSettings)
end

function Settings:Build(parent)
    local L = GP.L
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    frame.settingPages = {}
    frame.settingTabs = {}

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Settings"])

    local version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "?"

    local versionText = frame:CreateFontString(nil, "ARTWORK")
    versionText:SetFontObject(Theme.font.muted)
    versionText:SetPoint("LEFT", heading, "RIGHT", 12, 0)
    versionText:SetText(string.format(L["Version: %s"], version))

    local settingsStatus = frame:CreateFontString(nil, "ARTWORK")
    settingsStatus:SetFontObject(Theme.font.small)
    settingsStatus:SetJustifyH("RIGHT")
    settingsStatus:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    settingsStatus:SetPoint("LEFT", versionText, "RIGHT", 16, 0)
    settingsStatus:SetText("")
    frame.settingsStatus = settingsStatus

    local tabBar = CreateFrame("Frame", nil, frame)
    tabBar:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -16)
    tabBar:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    tabBar:SetHeight(30)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -14)
    content:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    frame.content = content

    local function createPage(key)
        local page = CreateFrame("Frame", nil, content)
        page:SetAllPoints()
        page:Hide()
        frame.settingPages[key] = page
        return page
    end

    local previousTab
    local function addSettingsTab(key, label)
        local button = createSettingsTabButton(tabBar, label)
        if previousTab then
            button:SetPoint("LEFT", previousTab, "RIGHT", 8, 0)
        else
            button:SetPoint("LEFT", 0, 0)
        end
        button:SetScript("OnClick", function() Settings:SelectSettingsPage(frame, key) end)
        frame.settingTabs[key] = button
        previousTab = button
        return button
    end

    addSettingsTab("general", L["General"])
    addSettingsTab("chat", L["Chat"])
    addSettingsTab("logs", L["Logs & Sync"])
    addSettingsTab("recruitment", L["Recruitment"])
    addSettingsTab("health", L["Health"])
    -- LB.tabButton set here so LB.refresh() (a plain top-level function, no
    -- `frame` upvalue of its own) can show/hide it independently — see
    -- LB.refresh's own body. Fully hidden for a non-officer, not shown-
    -- disabled, matching every other officer-only surface in this addon.
    LB.tabButton = addSettingsTab("labels", L["Labels"])
    frame.backupTabButton = addSettingsTab("backup", L["Backup & Restore"])
    frame.backupTabButton:SetWidth(128)

    local generalPage = createPage("general")
    local chatPage = createPage("chat")
    local logsPage = createPage("logs")
    local recruitmentPage = createPage("recruitment")
    local healthPage = createPage("health")
    local backupPage = createPage("backup")
    local labelsPage = createPage("labels")

    GP.UI.BackupRestoreTab:Build(backupPage)

    -- Single section, full page to itself — same fixed-generous-literal-
    -- size discipline as Message Templates above (SECTION 204), not
    local labelsSection = createSection(labelsPage, L["Officer Labels"])
    labelsSection:SetPoint("TOPLEFT", 0, 0)
    labelsSection:SetSize(1020, 610)

    local labelsDesc = addBodyText(labelsSection, labelsSection.heading,
        L["Build a shared catalog of labels (e.g. \"Trial\", \"Casual Raider\") officers can attach to players from the Roster tab for recruiting and evaluation tracking."],
        1020 - Theme.layout.gutter * 2)
    labelsDesc:SetFontObject(Theme.font.small)
    labelsDesc:SetTextColor(unpack(Theme.color.textSecondary))

    LB.showArchivedCheck = createCheck(labelsSection, L["Show archived"], function() LB.refresh() end)
    LB.showArchivedCheck:SetPoint("TOPLEFT", labelsDesc, "BOTTOMLEFT", -2, -12)

    LB.searchBox = Theme:CreateSearchBox(labelsSection, 200, function() LB.refresh() end)
    LB.searchBox:SetPoint("LEFT", LB.showArchivedCheck.text, "RIGHT", 20, 0)

    local labelListPanel = Theme:CreatePanel(labelsSection, "panel", "border")
    labelListPanel:SetPoint("TOPLEFT", LB.showArchivedCheck, "BOTTOMLEFT", 0, -26)
    labelListPanel:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    labelListPanel:SetHeight(140)

    local labelNameHeader = labelListPanel:CreateFontString(nil, "ARTWORK")
    labelNameHeader:SetFontObject(Theme.font.small)
    labelNameHeader:SetPoint("BOTTOMLEFT", labelListPanel, "TOPLEFT", 30, 4)
    labelNameHeader:SetText(L["Label"])

    local labelUsageHeader = labelListPanel:CreateFontString(nil, "ARTWORK")
    labelUsageHeader:SetFontObject(Theme.font.small)
    labelUsageHeader:SetPoint("LEFT", labelNameHeader, "LEFT", 228, 0)
    labelUsageHeader:SetText(L["Players"])

    LB.list = GP.UI.ScrollList:New(labelListPanel, LB.rowHeight, LB.createRow)
    LB.list:SetUpdateRow(LB.updateRow)

    -- Everything below chains off the previous element's own actual
    -- rendered bottom (same discipline as Message Templates/Invalid Zones
    local labelNameLabel = labelsSection:CreateFontString(nil, "ARTWORK")
    labelNameLabel:SetFontObject(Theme.font.small)
    labelNameLabel:SetPoint("TOPLEFT", labelListPanel, "BOTTOMLEFT", 0, -12)
    labelNameLabel:SetText(L["Label Name"])

    LB.nameBox = Theme:CreateEditBox(labelsSection, 220)
    LB.nameBox:SetPoint("TOPLEFT", labelNameLabel, "BOTTOMLEFT", 0, -4)
    LB.nameBox:SetMaxLetters(40) -- matches Modules/Labels.lua's LABEL_NAME_MAX_CHARS

    local labelColorLabel = labelsSection:CreateFontString(nil, "ARTWORK")
    labelColorLabel:SetFontObject(Theme.font.small)
    labelColorLabel:SetPoint("TOPLEFT", LB.nameBox, "BOTTOMLEFT", 0, -10)
    labelColorLabel:SetText(L["Color"])

    local PALETTE_SWATCH_SIZE = 22
    local PALETTE_ROW_GAP = 4
    LB.paletteButtons = {}
    local previousSwatch
    for _, color in ipairs(LB.PALETTE) do
        local swatch = LB.createPaletteSwatch(labelsSection, color)
        if previousSwatch then
            swatch:SetPoint("LEFT", previousSwatch, "RIGHT", 6, 0)
        else
            swatch:SetPoint("TOPLEFT", labelColorLabel, "BOTTOMLEFT", 0, -PALETTE_ROW_GAP)
        end
        table.insert(LB.paletteButtons, swatch)
        previousSwatch = swatch
    end
    local PALETTE_ROW_OFFSET = PALETTE_ROW_GAP + PALETTE_SWATCH_SIZE + 12

    LB.saveButton = Theme:CreateButton(labelsSection, L["Save"])
    LB.saveButton:SetPoint("TOPLEFT", labelColorLabel, "BOTTOMLEFT", 0, -PALETTE_ROW_OFFSET)
    LB.saveButton:SetScript("OnClick", function()
        local Labels = GP:GetModule("Labels")
        local guildKey = Labels:GetCurrentGuildKey()
        local name = LB.nameBox:GetText()
        local ok, errOrID

        if LB.selectedID then
            -- One atomic write: calling
            -- RenameLabel then SetLabelColor separately here previously
            -- risked the second write silently never reaching a peer, since
            -- both would often share the same time()-resolution timestamp
            -- and Guild Sync's receive-side compare is strict `ts > current`.
            ok, errOrID = Labels:UpdateLabelDefinition(guildKey, LB.selectedID, name, LB.selectedColor)
        else
            ok, errOrID = Labels:CreateLabel(guildKey, name, LB.selectedColor)
            if ok then LB.selectedID = errOrID end
        end

        GP:Print(ok and L["Label saved."] or errOrID)
        LB.refresh()
    end)

    LB.newButton = Theme:CreateButton(labelsSection, L["New"])
    LB.newButton:SetPoint("LEFT", LB.saveButton, "RIGHT", 8, 0)
    LB.newButton:SetScript("OnClick", function()
        LB.clearForm()
        LB.refresh()
    end)

    -- No confirmation popup, unlike Invalid Zones' Remove — archiving isn't
    -- destructive (Modules/Labels.lua never hard-deletes a definition;
    -- ArchiveLabel/UnarchiveLabel both fully reversible from this same
    -- button, which just relabels itself based on the selected record's
    -- current state — see LB.refresh).
    LB.archiveButton = Theme:CreateButton(labelsSection, L["Archive"])
    LB.archiveButton:SetPoint("LEFT", LB.newButton, "RIGHT", 8, 0)
    LB.archiveButton:SetScript("OnClick", function()
        local record = LB.selected()
        if not record then return end
        local Labels = GP:GetModule("Labels")
        local guildKey = Labels:GetCurrentGuildKey()
        local ok, err
        if record.archived then
            ok, err = Labels:UnarchiveLabel(guildKey, record.labelId)
        else
            ok, err = Labels:ArchiveLabel(guildKey, record.labelId)
        end
        GP:Print(ok and (record.archived and L["Label unarchived."] or L["Label archived."]) or err)
        LB.refresh()
    end)

    LB.detailText = labelsSection:CreateFontString(nil, "ARTWORK")
    LB.detailText:SetFontObject(Theme.font.muted)
    LB.detailText:SetPoint("TOPLEFT", LB.saveButton, "BOTTOMLEFT", 0, -12)
    LB.detailText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    LB.detailText:SetJustifyH("LEFT")
    LB.detailText:SetHeight(34)

    local assignedHeader = labelsSection:CreateFontString(nil, "ARTWORK")
    assignedHeader:SetFontObject(Theme.font.small)
    assignedHeader:SetPoint("TOPLEFT", LB.detailText, "BOTTOMLEFT", 0, -8)
    assignedHeader:SetText(L["Assigned Players"])

    local assignedListPanel = Theme:CreatePanel(labelsSection, "panel", "border")
    assignedListPanel:SetPoint("TOPLEFT", assignedHeader, "BOTTOMLEFT", 0, -6)
    assignedListPanel:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    assignedListPanel:SetHeight(150)

    LB.assignedEmptyText = assignedListPanel:CreateFontString(nil, "ARTWORK")
    LB.assignedEmptyText:SetFontObject(Theme.font.muted)
    LB.assignedEmptyText:SetPoint("TOPLEFT", 8, -8)
    LB.assignedEmptyText:SetPoint("RIGHT", -8, 0)
    LB.assignedEmptyText:SetJustifyH("LEFT")
    LB.assignedEmptyText:SetText(L["No players currently carry this label."])

    LB.assignedList = GP.UI.ScrollList:New(assignedListPanel, LB.assignedRowHeight, LB.createAssignedRow)
    LB.assignedList:SetUpdateRow(LB.updateAssignedRow)

    LB.clearForm()
    -- Also handles the tab button's initial officer-only visibility and
    -- (harmlessly, since the catalog usually won't be empty) the one-time
    -- seed check — see LB.refresh's own body.
    LB.refresh()
    -- GuildParagon_LabelsChanged can fire repeatedly during a Guild Sync
    -- full-state catch-up the same way recruitment settings can
    -- during a GM snapshot sync — same debounce reasoning as
    -- debouncedRefreshRecruitmentControls below.
    local function debouncedRefreshLabels()
        if not frame or not frame:IsShown() then
            if frame then frame.refreshLabelsDirty = true end
            return
        end
        GP:DebounceCall("Settings:refreshLabels", function()
            if frame and frame:IsShown() then
                frame.refreshLabelsDirty = false
                LB.refresh()
            elseif frame then
                frame.refreshLabelsDirty = true
            end
        end)
    end
    Settings:RegisterMessage("GuildParagon_LabelsChanged", debouncedRefreshLabels)

    local function debouncedRefreshHealthMacroIgnores()
        local healthSettingsPage = frame and frame.settingPages and frame.settingPages.health
        if not frame or not frame:IsShown() or not (healthSettingsPage and healthSettingsPage:IsShown()) then
            if frame then frame.refreshHealthMacroIgnoresDirty = true end
            return
        end
        GP:DebounceCall("Settings:refreshHealthMacroIgnores", function()
            local visibleHealthPage = frame and frame.settingPages and frame.settingPages.health
            if frame and frame:IsShown() and visibleHealthPage and visibleHealthPage:IsShown() then
                frame.refreshHealthMacroIgnoresDirty = false
                GH.refreshMacroIgnores()
            elseif frame then
                frame.refreshHealthMacroIgnoresDirty = true
            end
        end)
    end
    Settings:RegisterMessage("GuildParagon_MacroIgnoresChanged", debouncedRefreshHealthMacroIgnores)
    Settings:RegisterMessage("GuildParagon_RosterScanned", debouncedRefreshHealthMacroIgnores)

    -- Recruitment page has its own internal sub-tab bar (Safety Settings /
    -- Message Templates / Invalid Zones) instead of trying to fit multiple
    local recruitmentSubTabBar = CreateFrame("Frame", nil, recruitmentPage)
    recruitmentSubTabBar:SetPoint("TOPLEFT", 0, 0)
    recruitmentSubTabBar:SetPoint("RIGHT", 0, 0)
    recruitmentSubTabBar:SetHeight(30)

    local recruitmentSubContent = CreateFrame("Frame", nil, recruitmentPage)
    recruitmentSubContent:SetPoint("TOPLEFT", recruitmentSubTabBar, "BOTTOMLEFT", 0, -10)
    recruitmentSubContent:SetPoint("BOTTOMRIGHT", 0, 0)

    local recruitmentSubPages = {}
    local recruitmentSubTabs = {}
    local function selectRecruitmentSubPage(key)
        for pageKey, page in pairs(recruitmentSubPages) do
            page:SetShown(pageKey == key)
        end
        for tabKey, tab in pairs(recruitmentSubTabs) do
            tab:SetSelected(tabKey == key)
        end
        if frame.refreshRecruitmentControls then
            frame.refreshRecruitmentControls()
        elseif key == "filters" and FT.refresh then
            FT.refresh()
        end
    end
    -- Let other tabs deep-link to a recruitment settings sub-tab.
    frame.selectRecruitmentSubPage = selectRecruitmentSubPage

    local previousRecruitmentSubTab
    local function addRecruitmentSubTab(key, label)
        local button = createSettingsTabButton(recruitmentSubTabBar, label)
        if previousRecruitmentSubTab then
            button:SetPoint("LEFT", previousRecruitmentSubTab, "RIGHT", 8, 0)
        else
            button:SetPoint("LEFT", 0, 0)
        end
        button:SetScript("OnClick", function() selectRecruitmentSubPage(key) end)
        recruitmentSubTabs[key] = button
        previousRecruitmentSubTab = button
        return button
    end
    local function createRecruitmentSubPage(key)
        local page = CreateFrame("Frame", nil, recruitmentSubContent)
        page:SetAllPoints()
        page:Hide()
        recruitmentSubPages[key] = page
        return page
    end

    addRecruitmentSubTab("safety", L["Recruitment Safety"])
    addRecruitmentSubTab("followup", L["Follow-up"])
    addRecruitmentSubTab("messages", L["Message Templates"])
    addRecruitmentSubTab("zones", L["Invalid Zones"])
    addRecruitmentSubTab("filters", L["Filters"])

    local safetyPage = createRecruitmentSubPage("safety")
    local followUpPage = createRecruitmentSubPage("followup")
    local messagesPage = createRecruitmentSubPage("messages")
    local zonesPage = createRecruitmentSubPage("zones")
    local filtersPage = createRecruitmentSubPage("filters")

    local leftTop = createSection(generalPage, L["Guild Data"])
    leftTop:SetPoint("TOPLEFT", 0, 0)
    leftTop:SetSize(SETTINGS_COLUMN_WIDTH, 300)

    local statusText = addBodyText(leftTop, nil, "")
    statusText:SetSpacing(2)
    frame.statusText = statusText

    local rescanButton = Theme:CreateButton(leftTop, L["Rescan Now"])
    rescanButton:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -14)
    rescanButton:SetScript("OnClick", function()
        -- Scan() is batched; update status only from its completion callback.
        local started, startErr
        started, startErr = GP:GetModule("Roster"):Scan(false, function(ok, err)
            if not started then return end
            setSettingsStatus(frame, ok and L["Roster scan complete."] or (err or L["Roster scan skipped."]), not ok)
            if ok then Settings:RefreshStatus(frame) end
        end)
        if not started then
            setSettingsStatus(frame, startErr or L["Roster scan skipped."], true)
        else
            setSettingsStatus(frame, L["Scanning..."], false)
        end
    end)

    local reloadButton = Theme:CreateButton(leftTop, L["Reload UI"])
    reloadButton:SetPoint("LEFT", rescanButton, "RIGHT", 8, 0)
    reloadButton:SetScript("OnClick", function()
        ReloadUI()
    end)

    local minimapSettings = ensureMinimapSettings()
    local minimapCheck = createCheck(leftTop, L["Show minimap button"], function(value)
        minimapSettings.hide = not value
        local Launcher = GP:GetModule("Launcher", true)
        if Launcher and Launcher.SetMinimapShown then
            Launcher:SetMinimapShown(value)
        end
    end)
    minimapCheck:SetPoint("TOPLEFT", rescanButton, "BOTTOMLEFT", 0, -8)
    minimapCheck:SetChecked(not minimapSettings.hide)
    local minimapDesc = addOptionDescription(leftTop, minimapCheck, L["Shows or hides the draggable minimap launcher. The addon compartment entry always remains available."], 380)

    local safety = createSection(generalPage, L["Safety & Performance"])
    safety:SetPoint("TOPLEFT", leftTop, "BOTTOMLEFT", 0, -SECTION_GAP)
    safety:SetSize(SETTINGS_COLUMN_WIDTH, 170)

    local safetyText = addBodyText(safety, nil, L["Restricted Blizzard values are ignored until accessible."], SETTINGS_COLUMN_WIDTH - Theme.layout.gutter * 2)
    safetyText:SetFontObject(Theme.font.muted)
    frame.performanceText = addBodyText(safety, safetyText, "", SETTINGS_COLUMN_WIDTH - Theme.layout.gutter * 2)

    local refreshPerfButton = Theme:CreateButton(safety, L["Refresh"])
    refreshPerfButton:SetPoint("TOPLEFT", frame.performanceText, "BOTTOMLEFT", 0, -14)
    refreshPerfButton:SetScript("OnClick", function() refreshPerformanceText(frame) end)

    local performanceDesc = addOptionDescription(safety, refreshPerfButton, L["Refresh updates the displayed memory figures."], 380)
    performanceDesc:ClearAllPoints()
    performanceDesc:SetPoint("TOPLEFT", refreshPerfButton, "BOTTOMLEFT", 0, -6)

    local rosterDisplay = createSection(generalPage, L["Roster Display"])
    rosterDisplay:SetPoint("TOPLEFT", leftTop, "TOPRIGHT", SECTION_GAP, 0)
    rosterDisplay:SetSize(SETTINGS_COLUMN_WIDTH, 300)

    local rosterSettings = ensureRosterDisplaySettings()
    local classColorCheck = createCheck(rosterDisplay, L["Class color roster names"], function(value)
        rosterSettings.classColorNames = value
        GP.UI.RosterTab:Refresh()
    end)
    classColorCheck:SetPoint("TOPLEFT", rosterDisplay.heading, "BOTTOMLEFT", 0, -8)
    classColorCheck:SetChecked(rosterSettings.classColorNames)
    local classColorDesc = addOptionDescription(rosterDisplay, classColorCheck, L["Uses each character's class color in roster lists and detail views."], 380)

    local levelCheck = createCheck(rosterDisplay, L["Show roster levels"], function(value)
        rosterSettings.showLevel = value
        GP.UI.RosterTab:Refresh()
    end)
    levelCheck:SetPoint("TOPLEFT", classColorDesc, "BOTTOMLEFT", -26, -8)
    levelCheck:SetChecked(rosterSettings.showLevel)
    local levelDesc = addOptionDescription(rosterDisplay, levelCheck, L["Shows the level column in the Guild Paragon roster."], 380)

    local scanSettings = ensureScanSettings()
    local uiSettings = ensureUISettings()
    local scanLoginCheck = createCheck(rosterDisplay, L["Scan after login"], function(value)
        scanSettings.login = value
    end)
    scanLoginCheck:SetPoint("TOPLEFT", levelDesc, "BOTTOMLEFT", -26, -10)
    scanLoginCheck:SetChecked(scanSettings.login)
    local scanLoginDesc = addOptionDescription(rosterDisplay, scanLoginCheck, L["Requests a safe roster scan shortly after login when guild data is available."], 380)

    local rosterUpdateCheck = createCheck(rosterDisplay, L["Scan roster updates"], function(value)
        scanSettings.rosterUpdates = value
    end)
    rosterUpdateCheck:SetPoint("TOPLEFT", scanLoginDesc, "BOTTOMLEFT", -26, -8)
    rosterUpdateCheck:SetChecked(scanSettings.rosterUpdates)
    local rosterUpdateDesc = addOptionDescription(rosterDisplay, rosterUpdateCheck, L["Allows roster-update events to queue a coalesced scan instead of waiting for a manual refresh."], 380)

    local combatCheck = createCheck(rosterDisplay, L["Hide Guild Paragon in combat"], function(value)
        uiSettings.autoHideInCombat = value
    end)
    combatCheck:SetPoint("TOPLEFT", rosterUpdateDesc, "BOTTOMLEFT", -26, -8)
    combatCheck:SetChecked(uiSettings.autoHideInCombat)
    local combatDesc = addOptionDescription(rosterDisplay, combatCheck, L["Automatically hides Guild Paragon's main window during combat lockdown."], 380)

    local scaleLabel = rosterDisplay:CreateFontString(nil, "ARTWORK")
    scaleLabel:SetFontObject(Theme.font.body)
    scaleLabel:SetPoint("TOPLEFT", combatDesc, "BOTTOMLEFT", 0, -12)
    scaleLabel:SetText(L["Window Scale:"])

    local scaleBox = Theme:CreateEditBox(rosterDisplay, 52)
    scaleBox:SetPoint("LEFT", scaleLabel, "RIGHT", 8, 0)
    scaleBox:SetText(tostring(math.floor((uiSettings.scale * 100) + 0.5)))

    local scaleApply = Theme:CreateButton(rosterDisplay, L["Apply"])
    scaleApply:SetPoint("LEFT", scaleBox, "RIGHT", 8, 0)
    local function applyScale()
        local percent = tonumber(scaleBox:GetText()) or 100
        if percent < 50 then percent = 50 end
        if percent > 125 then percent = 125 end
        percent = math.floor(percent + 0.5)
        uiSettings.scale = percent / 100
        scaleBox:SetText(tostring(percent))
        scaleBox:ClearFocus()
        if GP.UI.MainWindow and GP.UI.MainWindow.ApplySettings then
            GP.UI.MainWindow:ApplySettings()
        end
        setSettingsStatus(frame, string.format(L["Window scale set to %d%%."], percent))
    end
    scaleApply:SetScript("OnClick", applyScale)
    scaleBox:SetScript("OnEnterPressed", applyScale)

    buildHealthSettingsPage(frame, healthPage)

    local maintenance = createSection(logsPage, L["Sync & Maintenance"])
    maintenance:SetPoint("TOPLEFT", 0, 0)
    maintenance:SetSize(SETTINGS_COLUMN_WIDTH, 500)

    local MAINTENANCE_BUTTON_WIDTH = 220
    local MAINTENANCE_DESC_WIDTH = SETTINGS_COLUMN_WIDTH - Theme.layout.gutter * 2
    local maintenanceAnchor = maintenance.heading
    local function addMaintenanceAction(label, description, onClick)
        local button = Theme:CreateButton(maintenance, label)
        button:SetWidth(MAINTENANCE_BUTTON_WIDTH)
        button:SetPoint("TOPLEFT", maintenanceAnchor, "BOTTOMLEFT", 0, -14)
        button:SetScript("OnClick", onClick)

        local desc = addOptionDescription(maintenance, button, description, MAINTENANCE_DESC_WIDTH)
        desc:ClearAllPoints()
        desc:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -4)
        maintenanceAnchor = desc
        return button, desc
    end

    addMaintenanceAction(L["Sync Now"], L["Requests a guild data sync from online Guild Paragon users."], function()
        if GP:GetModule("GuildSync"):RequestSync() then
            setSettingsStatus(frame, L["Sync request sent."])
        else
            setSettingsStatus(frame, L["No roster data yet — try /gp scan."], true)
        end
    end)

    if GP:IsOfficer() then
        addMaintenanceAction(L["Normalize Join Dates"], L["Dry-runs conversion of custom-note join dates to YYYY-MM-DD. Run /gp normalizejoindates confirm to apply."], function()
            GP:NormalizeJoinDates(false)
            setSettingsStatus(frame, L["Dry-run printed to chat."])
        end)

        addMaintenanceAction(L["Fix GRM Log Dates"], L["Dry-runs cleanup of duplicate dates on imported Event Log rows. Run /gp fixgrmlogdates confirm to apply."], function()
            GP:FixGRMLogDates(false)
            setSettingsStatus(frame, L["Dry-run printed to chat."])
        end)

        addMaintenanceAction(L["Trim Event Log"], L["Dry-runs removal of oldest Event Log rows above the retention target. Run /gp trimlog confirm to apply."], function()
            GP:TrimLog(false)
            setSettingsStatus(frame, L["Dry-run printed to chat."])
        end)
    end

    if GP:IsGuildMaster() then
        addMaintenanceAction(L["Import GRM"], L["Dry-runs importing the current guild from GRM SavedVariables. Run /gp importgrm confirm to apply."], function()
            GP:ImportGRM(false)
            setSettingsStatus(frame, L["Dry-run printed to chat."])
        end)

        addMaintenanceAction(L["Migrate Note Join Dates"], L["Dry-runs moving Joined/Rejoined note tags into Guild Paragon join dates. Run /gp migratejoindates confirm to apply."], function()
            GP:MigrateJoinDates(false)
            setSettingsStatus(frame, L["Dry-run printed to chat."])
        end)

        addMaintenanceAction(L["Strip Note Join Date Tags"], L["Dry-runs removing Joined/Rejoined tags from custom notes after migration. Run /gp stripjoindatenotes confirm to apply."], function()
            GP:StripJoinDateNotes(false)
            setSettingsStatus(frame, L["Dry-run printed to chat."])
        end)
    end

    local eventLog = createSection(logsPage, L["Event Log"])
    eventLog:SetPoint("TOPLEFT", maintenance, "TOPRIGHT", SECTION_GAP, 0)
    eventLog:SetSize(SETTINGS_COLUMN_WIDTH, 180)

    local eventLogSettings = ensureEventLogSettings()
    local numberedCheck = createCheck(eventLog, L["Numbered Lines"], function(value)
        eventLogSettings.numberedLines = value
        GP.UI.EventLogTab:Refresh()
    end)
    numberedCheck:SetPoint("TOPLEFT", eventLog.heading, "BOTTOMLEFT", 0, -8)
    numberedCheck:SetChecked(eventLogSettings.numberedLines)
    local numberedDesc = addOptionDescription(eventLog, numberedCheck, L["Shows row numbers in the Event Log for easier review and line removal."], 380)

    local colorCheck = createCheck(eventLog, L["Category Colors"], function(value)
        eventLogSettings.categoryColors = value
        GP.UI.EventLogTab:Refresh()
    end)
    colorCheck:SetPoint("TOPLEFT", numberedDesc, "BOTTOMLEFT", -26, -8)
    colorCheck:SetChecked(eventLogSettings.categoryColors)
    addOptionDescription(eventLog, colorCheck, L["Colors log lines by category so promotions, notes, joins, and imports are easier to scan."], 380)

    local recruitment = createSection(safetyPage, L["Recruitment Safety"])
    recruitment:SetPoint("TOPLEFT", 0, 0)
    -- Full page width (was SETTINGS_COLUMN_WIDTH/450) — at 450 with nothing
    -- beside it, this looked like a small card floating in a mostly-empty
    recruitment:SetSize(GP:IsGuildMaster() and SETTINGS_PAGE_WIDTH or SETTINGS_COLUMN_WIDTH, 430)

    local recruitmentSettings = ensureRecruitmentSettings()
    local Recruitment = GP:GetModule("Recruitment", true)
    local recruitmentLocked = Recruitment and Recruitment.AreSettingsLocked and Recruitment:AreSettingsLocked()

    local manualReviewCheck = createCheck(recruitment, L["Require manual review before invites or messages"])
    manualReviewCheck:SetPoint("TOPLEFT", recruitment.heading, "BOTTOMLEFT", 0, -8)
    manualReviewCheck:SetChecked(true)
    manualReviewCheck:Disable()
    manualReviewCheck:SetAlpha(0.55)
    manualReviewCheck.text:SetTextColor(unpack(Theme.color.textSecondary))
    local manualReviewDesc = addOptionDescription(recruitment, manualReviewCheck, L["Guild Paragon will require review before any recruitment invite or message workflow can act."], 380)

    -- Referenced by handlers declared outside the guild-master-only block.
    local requireOfficerCheck

    local obeyBlockInvitesCheck = createCheck(recruitment, L["Respect Blizzard blocked-invite checks"])
    obeyBlockInvitesCheck:SetPoint("TOPLEFT", manualReviewDesc, "BOTTOMLEFT", -26, -8)
    obeyBlockInvitesCheck:SetChecked(recruitmentSettings.obeyBlockInvites)
    local obeyBlockInvitesDesc = addOptionDescription(recruitment, obeyBlockInvitesCheck, L["Skips players when Blizzard reports that guild invites are blocked or unavailable."], 380)

    local antiSpamCheck = createCheck(recruitment, L["Use anti-spam cooldowns"])
    antiSpamCheck:SetPoint("TOPLEFT", obeyBlockInvitesDesc, "BOTTOMLEFT", -26, -8)
    antiSpamCheck:SetChecked(recruitmentSettings.antiSpam)
    local antiSpamDesc = addOptionDescription(recruitment, antiSpamCheck, L["Prevents repeated recruitment attempts to the same character during the cooldown window."], 380)

    local antiSpamLabel = recruitment:CreateFontString(nil, "ARTWORK")
    antiSpamLabel:SetFontObject(Theme.font.small)
    antiSpamLabel:SetPoint("TOPLEFT", antiSpamDesc, "BOTTOMLEFT", -26, -18)
    antiSpamLabel:SetText(L["Cooldown days"])

    local antiSpamDaysBox = Theme:CreateEditBox(recruitment, 58)
    antiSpamDaysBox:SetPoint("LEFT", antiSpamLabel, "RIGHT", 10, 0)
    antiSpamDaysBox:SetText(tostring(recruitmentSettings.antiSpamDays))

    local delayLabel = recruitment:CreateFontString(nil, "ARTWORK")
    delayLabel:SetFontObject(Theme.font.small)
    delayLabel:SetPoint("LEFT", antiSpamDaysBox, "RIGHT", 20, 0)
    delayLabel:SetText(L["Message delay seconds"])

    local messageDelayBox = Theme:CreateEditBox(recruitment, 58)
    messageDelayBox:SetPoint("LEFT", delayLabel, "RIGHT", 10, 0)
    messageDelayBox:SetText(tostring(recruitmentSettings.messageDelay))

    local pendingTimeoutLabel = recruitment:CreateFontString(nil, "ARTWORK")
    pendingTimeoutLabel:SetFontObject(Theme.font.small)
    pendingTimeoutLabel:SetPoint("TOPLEFT", antiSpamLabel, "BOTTOMLEFT", 0, -12)
    pendingTimeoutLabel:SetText(L["Pending timeout days"])

    local pendingTimeoutDaysBox = Theme:CreateEditBox(recruitment, 58)
    pendingTimeoutDaysBox:SetPoint("LEFT", pendingTimeoutLabel, "RIGHT", 10, 0)
    pendingTimeoutDaysBox:SetText(tostring(recruitmentSettings.pendingTimeoutDays or 7))

    local executorModeLabel = recruitment:CreateFontString(nil, "ARTWORK")
    executorModeLabel:SetFontObject(Theme.font.small)
    executorModeLabel:SetPoint("TOPLEFT", pendingTimeoutLabel, "BOTTOMLEFT", 0, -12)
    executorModeLabel:SetText(L["Default executor mode"])

    local selectedExecutorMode = recruitmentSettings.executorMode or "whisper"
    local executorModeButtons = {}
    local saveRecruitmentSettings
    local scheduleRecruitmentSettingsSave
    local function refreshExecutorModeButtons()
        for id, button in pairs(executorModeButtons) do
            button:SetSelected(id == selectedExecutorMode)
        end
    end

    local executorModes = Recruitment and Recruitment.GetExecutorModes and Recruitment:GetExecutorModes() or {
        { id = "invite", label = L["Invite"] },
        { id = "whisper", label = L["Whisper"] },
        { id = "whisper_invite", label = L["Whisper + Invite"] },
    }
    local lastExecutorModeButton
    for _, mode in ipairs(executorModes) do
        local modeButton = createSettingsTabButton(recruitment, mode.label)
        modeButton:SetWidth(mode.id == "whisper_invite" and 126 or 82)
        if lastExecutorModeButton then
            modeButton:SetPoint("LEFT", lastExecutorModeButton, "RIGHT", 8, 0)
        else
            modeButton:SetPoint("TOPLEFT", executorModeLabel, "BOTTOMLEFT", 0, -8)
        end
        modeButton:SetScript("OnClick", function()
            if recruitmentLocked then return end
            selectedExecutorMode = mode.id
            refreshExecutorModeButtons()
            if scheduleRecruitmentSettingsSave then scheduleRecruitmentSettingsSave() end
        end)
        executorModeButtons[mode.id] = modeButton
        lastExecutorModeButton = modeButton
    end
    refreshExecutorModeButtons()

    local executorModeDesc = addOptionDescription(recruitment, lastExecutorModeButton or executorModeLabel, L["New scans use this executor mode by default. The Recruitment screen can still preview another mode for the current session."], 380)
    executorModeDesc:ClearAllPoints()
    executorModeDesc:SetPoint("TOPLEFT", executorModeLabel, "BOTTOMLEFT", 26, -40)

    local retailContextMenuCheck = createCheck(recruitment, L["Enable Retail right-click recruitment shortcuts"])
    retailContextMenuCheck:SetPoint("TOPLEFT", executorModeDesc, "BOTTOMLEFT", -26, -8)
    retailContextMenuCheck:SetChecked(recruitmentSettings.retailContextMenus)
    local retailContextMenuDesc = addOptionDescription(recruitment, retailContextMenuCheck, L["Adds Guild Paragon actions to Blizzard player right-click menus. Useful, but can taint protected menu actions like Copy Character Name on some clients."], 380)

    -- Guild-master controls share the panel with regular recruitment
    -- settings but keep a fixed right-column anchor.
    local RECRUITMENT_RIGHT_COLUMN_X = 460
    local gmEnforcedCheck
    local gmEnforcedDesc
    local lockMessagesCheck
    local lockMessagesDesc
    local lockFiltersCheck
    local lockFiltersDesc
    if GP:IsGuildMaster() then
        gmEnforcedCheck = createCheck(recruitment, L["Use these as guild-master defaults"])
        gmEnforcedCheck:SetPoint("TOPLEFT", recruitment.heading, "BOTTOMLEFT", RECRUITMENT_RIGHT_COLUMN_X, -8)
        gmEnforcedCheck:SetChecked(recruitmentSettings.gmEnforced)
        gmEnforcedDesc = addOptionDescription(recruitment, gmEnforcedCheck, L["When saved by the guild master, these recruitment settings sync to the guild and lock for non-GM users."], 380)

        lockMessagesCheck = createCheck(recruitment, L["Lock message templates to guild master"])
        lockMessagesCheck:SetPoint("TOPLEFT", gmEnforcedDesc, "BOTTOMLEFT", -26, -8)
        lockMessagesCheck:SetChecked(recruitmentSettings.lockMessages)
        lockMessagesDesc = addOptionDescription(recruitment, lockMessagesCheck, L["When locked, only the guild master can create, edit, or delete recruitment message templates. Everyone else can view and select from them, but not change or add alternatives."], 380)

        lockFiltersCheck = createCheck(recruitment, L["Lock filters to guild master"])
        lockFiltersCheck:SetPoint("TOPLEFT", lockMessagesDesc, "BOTTOMLEFT", -26, -8)
        lockFiltersCheck:SetChecked(recruitmentSettings.lockFilters)
        lockFiltersDesc = addOptionDescription(recruitment, lockFiltersCheck, L["When locked, only the guild master can create, edit, delete, or select active recruitment filters. Everyone else uses the guild master's active filter."], 380)

        requireOfficerCheck = createCheck(recruitment, L["Restrict Recruitment tab to officers"])
        requireOfficerCheck:SetPoint("TOPLEFT", lockFiltersDesc, "BOTTOMLEFT", -26, -8)
        requireOfficerCheck:SetChecked(recruitmentSettings.requireOfficer)
        addOptionDescription(recruitment, requireOfficerCheck, L["When enabled, only officers can open the Recruitment tab; otherwise anyone with guild invite permission can use it."], 380)
    end

    local saveRecruitmentButton = Theme:CreateButton(recruitment, L["Save Settings"])
    saveRecruitmentButton:SetPoint("TOPLEFT", retailContextMenuDesc, "BOTTOMLEFT", -26, -14)
    saveRecruitmentSettings = function()
        if recruitmentLocked then return end
        local ok, err
        if Recruitment and Recruitment.SaveSettings then
            ok, err = Recruitment:SaveSettings({
                requireOfficer = (requireOfficerCheck and requireOfficerCheck:GetChecked()) or (not requireOfficerCheck and recruitmentSettings.requireOfficer),
                obeyBlockInvites = obeyBlockInvitesCheck:GetChecked(),
                antiSpam = antiSpamCheck:GetChecked(),
                antiSpamDays = antiSpamDaysBox:GetText(),
                pendingTimeoutDays = pendingTimeoutDaysBox:GetText(),
                messageDelay = messageDelayBox:GetText(),
                executorMode = selectedExecutorMode,
                retailContextMenus = recruitmentSettings.retailContextMenus,
                welcomeGuild = recruitmentSettings.welcomeGuild,
                welcomeGuildMessage = recruitmentSettings.welcomeGuildMessage,
                welcomeWhisper = recruitmentSettings.welcomeWhisper,
                welcomeWhisperMessage = recruitmentSettings.welcomeWhisperMessage,
                -- GetChecked() returns nil (not false) when unchecked, same
                -- gotcha every other checkbox in this file coerces around.
                gmEnforced = gmEnforcedCheck and (gmEnforcedCheck:GetChecked() and true or false),
                lockMessages = (lockMessagesCheck and lockMessagesCheck:GetChecked()) or (not lockMessagesCheck and recruitmentSettings.lockMessages),
                lockFilters = (lockFiltersCheck and lockFiltersCheck:GetChecked()) or (not lockFiltersCheck and recruitmentSettings.lockFilters),
            })
        else
            recruitmentSettings.requireOfficer = (requireOfficerCheck and requireOfficerCheck:GetChecked()) or (not requireOfficerCheck and recruitmentSettings.requireOfficer)
            recruitmentSettings.obeyBlockInvites = obeyBlockInvitesCheck:GetChecked()
            recruitmentSettings.antiSpam = antiSpamCheck:GetChecked()
            recruitmentSettings.antiSpamDays = tonumber(antiSpamDaysBox:GetText()) or recruitmentSettings.antiSpamDays
            recruitmentSettings.pendingTimeoutDays = tonumber(pendingTimeoutDaysBox:GetText()) or recruitmentSettings.pendingTimeoutDays
            recruitmentSettings.messageDelay = tonumber(messageDelayBox:GetText()) or recruitmentSettings.messageDelay
            recruitmentSettings.executorMode = selectedExecutorMode
            recruitmentSettings.retailContextMenus = recruitmentSettings.retailContextMenus and true or false
            recruitmentSettings.welcomeGuild = recruitmentSettings.welcomeGuild and true or false
            recruitmentSettings.welcomeGuildMessage = recruitmentSettings.welcomeGuildMessage or L["Welcome PLAYERNAME to GUILDNAME!"]
            recruitmentSettings.welcomeWhisper = recruitmentSettings.welcomeWhisper and true or false
            recruitmentSettings.welcomeWhisperMessage = recruitmentSettings.welcomeWhisperMessage or L["Welcome to GUILDNAME, PLAYERNAME!"]
            recruitmentSettings.lockMessages = (lockMessagesCheck and lockMessagesCheck:GetChecked()) or (not lockMessagesCheck and recruitmentSettings.lockMessages)
            recruitmentSettings.lockFilters = (lockFiltersCheck and lockFiltersCheck:GetChecked()) or (not lockFiltersCheck and recruitmentSettings.lockFilters)
            ok = true
        end

        if not ok then
            setSettingsStatus(frame, err or L["Guild-master recruitment defaults are active."], true)
            return
        end
        recruitmentSettings = ensureRecruitmentSettings()
        antiSpamDaysBox:SetText(tostring(recruitmentSettings.antiSpamDays))
        pendingTimeoutDaysBox:SetText(tostring(recruitmentSettings.pendingTimeoutDays))
        messageDelayBox:SetText(tostring(recruitmentSettings.messageDelay))
        selectedExecutorMode = recruitmentSettings.executorMode or "whisper"
        refreshExecutorModeButtons()
        if GP.UI.MainWindow and GP.UI.MainWindow.BuildSidebar then
            GP.UI.MainWindow:BuildSidebar()
        end
        MT.refresh()
        FT.refresh()
        setSettingsStatus(frame, L["Recruitment settings saved."])
    end
    saveRecruitmentButton:SetScript("OnClick", saveRecruitmentSettings)

    -- Recruitment Safety auto-saves on every click/blur, which
    -- means clicking two checkboxes back to back — or tabbing out of a
    local recruitmentAutoSaveGeneration = 0
    scheduleRecruitmentSettingsSave = function()
        if recruitmentLocked then return end
        recruitmentAutoSaveGeneration = recruitmentAutoSaveGeneration + 1
        local generation = recruitmentAutoSaveGeneration
        C_Timer.After(0.6, function()
            if generation == recruitmentAutoSaveGeneration then
                saveRecruitmentSettings()
            end
        end)
    end

    local function autoSaveRecruitmentCheck(check)
        if not check then return end
        check:SetScript("OnClick", function()
            if recruitmentLocked then
                frame.refreshRecruitmentControls()
                return
            end
            scheduleRecruitmentSettingsSave()
        end)
    end
    autoSaveRecruitmentCheck(requireOfficerCheck)
    autoSaveRecruitmentCheck(obeyBlockInvitesCheck)
    autoSaveRecruitmentCheck(antiSpamCheck)
    autoSaveRecruitmentCheck(gmEnforcedCheck)
    autoSaveRecruitmentCheck(lockMessagesCheck)
    autoSaveRecruitmentCheck(lockFiltersCheck)

    retailContextMenuCheck:SetScript("OnClick", function(self)
        local ok, msg
        if Recruitment and Recruitment.SaveRetailContextMenuSetting then
            ok, msg = Recruitment:SaveRetailContextMenuSetting(self:GetChecked())
        else
            recruitmentSettings.retailContextMenus = self:GetChecked() and true or false
            ok = true
        end
        recruitmentSettings = ensureRecruitmentSettings()
        self:SetChecked(recruitmentSettings.retailContextMenus)
        if msg then
            setSettingsStatus(frame, msg)
        elseif ok then
            setSettingsStatus(frame, L["Recruitment settings saved."])
        end
    end)

    local function autoSaveRecruitmentBox(box)
        if not box then return end
        box:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
        end)
        box:SetScript("OnEditFocusLost", function()
            scheduleRecruitmentSettingsSave()
        end)
    end
    autoSaveRecruitmentBox(antiSpamDaysBox)
    autoSaveRecruitmentBox(pendingTimeoutDaysBox)
    autoSaveRecruitmentBox(messageDelayBox)

    if recruitmentLocked then
        setControlEnabled(obeyBlockInvitesCheck, false)
        setControlEnabled(antiSpamCheck, false)
        setControlEnabled(antiSpamDaysBox, false)
        setControlEnabled(pendingTimeoutDaysBox, false)
        setControlEnabled(messageDelayBox, false)
        for _, button in pairs(executorModeButtons) do
            setControlEnabled(button, false)
        end
        setControlEnabled(saveRecruitmentButton, false)
    end

    local followUp = createSection(followUpPage, L["Recruitment Follow-up"])
    followUp:SetPoint("TOPLEFT", 0, 0)
    followUp:SetSize(SETTINGS_PAGE_WIDTH, 430)

    local followUpSettings = recruitmentSettings
    local welcomeGuildCheck = createCheck(followUp, L["Send guild welcome when tracked recruit joins"])
    welcomeGuildCheck:SetPoint("TOPLEFT", followUp.heading, "BOTTOMLEFT", 0, -8)
    welcomeGuildCheck:SetChecked(followUpSettings.welcomeGuild)
    local welcomeGuildDesc = addOptionDescription(followUp, welcomeGuildCheck, L["Sends a guild chat welcome only when the joining member has a pending Guild Paragon recruitment contact."], 820)

    local guildWelcomeLabel = followUp:CreateFontString(nil, "ARTWORK")
    guildWelcomeLabel:SetFontObject(Theme.font.small)
    guildWelcomeLabel:SetPoint("TOPLEFT", welcomeGuildDesc, "BOTTOMLEFT", -26, -12)
    guildWelcomeLabel:SetText(L["Guild Welcome Message"])

    local guildWelcomeBox = createLargeSettingsEditBox(followUp, 520, 70, 255)
    guildWelcomeBox.holder:SetPoint("TOPLEFT", guildWelcomeLabel, "BOTTOMLEFT", 0, -6)
    guildWelcomeBox:SetText(followUpSettings.welcomeGuildMessage or L["Welcome PLAYERNAME to GUILDNAME!"])

    local welcomeWhisperCheck = createCheck(followUp, L["Send welcome whisper when tracked recruit joins"])
    welcomeWhisperCheck:SetPoint("TOPLEFT", guildWelcomeBox.holder, "BOTTOMLEFT", 0, -16)
    welcomeWhisperCheck:SetChecked(followUpSettings.welcomeWhisper)
    local welcomeWhisperDesc = addOptionDescription(followUp, welcomeWhisperCheck, L["Sends a private welcome whisper only when the joining member has a pending Guild Paragon recruitment contact."], 820)

    local whisperWelcomeLabel = followUp:CreateFontString(nil, "ARTWORK")
    whisperWelcomeLabel:SetFontObject(Theme.font.small)
    whisperWelcomeLabel:SetPoint("TOPLEFT", welcomeWhisperDesc, "BOTTOMLEFT", -26, -12)
    whisperWelcomeLabel:SetText(L["Welcome Whisper Message"])

    local whisperWelcomeBox = createLargeSettingsEditBox(followUp, 520, 70, 255)
    whisperWelcomeBox.holder:SetPoint("TOPLEFT", whisperWelcomeLabel, "BOTTOMLEFT", 0, -6)
    whisperWelcomeBox:SetText(followUpSettings.welcomeWhisperMessage or L["Welcome to GUILDNAME, PLAYERNAME!"])

    local followUpHelp = addBodyText(followUp, whisperWelcomeBox.holder, L["Use PLAYERNAME, GUILDNAME, and GUILDLINK in follow-up messages."], 820)
    followUpHelp:SetFontObject(Theme.font.small)
    followUpHelp:SetTextColor(unpack(Theme.color.textSecondary))

    -- Follow-up welcome messages are a personal-per-client preference, not
    -- something the guild master can lock for other officers — deliberately
    -- saved through Recruitment:SaveFollowUpSettings (no AreSettingsLocked()
    -- gate) instead of the shared SaveSettings used by the Recruitment
    -- Safety page, and never disabled based on recruitmentLocked.
    local function saveFollowUpSettings()
        local ok = true
        if Recruitment and Recruitment.SaveFollowUpSettings then
            ok = Recruitment:SaveFollowUpSettings({
                welcomeGuild = welcomeGuildCheck:GetChecked(),
                welcomeGuildMessage = guildWelcomeBox:GetText(),
                welcomeWhisper = welcomeWhisperCheck:GetChecked(),
                welcomeWhisperMessage = whisperWelcomeBox:GetText(),
            })
        else
            followUpSettings.welcomeGuild = welcomeGuildCheck:GetChecked()
            followUpSettings.welcomeGuildMessage = guildWelcomeBox:GetText()
            followUpSettings.welcomeWhisper = welcomeWhisperCheck:GetChecked()
            followUpSettings.welcomeWhisperMessage = whisperWelcomeBox:GetText()
        end

        if not ok then return end
        followUpSettings = ensureRecruitmentSettings()
        welcomeGuildCheck:SetChecked(followUpSettings.welcomeGuild)
        if not guildWelcomeBox:HasFocus() then guildWelcomeBox:SetText(followUpSettings.welcomeGuildMessage or "") end
        welcomeWhisperCheck:SetChecked(followUpSettings.welcomeWhisper)
        if not whisperWelcomeBox:HasFocus() then whisperWelcomeBox:SetText(followUpSettings.welcomeWhisperMessage or "") end
        setSettingsStatus(frame, L["Recruitment follow-up settings saved."])
    end

    local followUpAutoSaveGeneration = 0
    local function scheduleFollowUpSettingsSave()
        followUpAutoSaveGeneration = followUpAutoSaveGeneration + 1
        local generation = followUpAutoSaveGeneration
        if C_Timer and C_Timer.After then
            C_Timer.After(0.6, function()
                if generation == followUpAutoSaveGeneration then
                    saveFollowUpSettings()
                end
            end)
        else
            saveFollowUpSettings()
        end
    end

    local function autoSaveFollowUpCheck(check)
        if not check then return end
        check:SetScript("OnClick", scheduleFollowUpSettingsSave)
    end

    local function autoSaveFollowUpBox(box)
        if not box then return end
        box:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
        end)
        box:SetScript("OnEditFocusLost", scheduleFollowUpSettingsSave)
    end

    autoSaveFollowUpCheck(welcomeGuildCheck)
    autoSaveFollowUpCheck(welcomeWhisperCheck)
    autoSaveFollowUpBox(guildWelcomeBox)
    autoSaveFollowUpBox(whisperWelcomeBox)

    local saveFollowUpButton = Theme:CreateButton(followUp, L["Save Follow-up"])
    saveFollowUpButton:SetPoint("TOPLEFT", followUpHelp, "BOTTOMLEFT", 0, -14)
    saveFollowUpButton:SetScript("OnClick", function()
        followUpAutoSaveGeneration = followUpAutoSaveGeneration + 1
        saveFollowUpSettings()
    end)

    -- Message Templates: now its own Recruitment sub-tab (see the sub-tab
    -- scaffold above) rather than a column squeezed beside Recruitment
    -- Full-width message-template editor.
    local messageTemplates = createSection(messagesPage, L["Message Templates"])
    messageTemplates:SetPoint("TOPLEFT", 0, 0)
    -- Fixed height keeps the editor stable as template text changes.
    messageTemplates:SetSize(1020, 570)

    MT.searchBox = Theme:CreateSearchBox(messageTemplates, 200, function() MT.refresh() end)
    MT.searchBox:SetPoint("TOPLEFT", messageTemplates.heading, "BOTTOMLEFT", 0, -10)

    local templateListPanel = Theme:CreatePanel(messageTemplates, "panel", "border")
    templateListPanel:SetPoint("TOPLEFT", MT.searchBox, "BOTTOMLEFT", 0, -26)
    templateListPanel:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    templateListPanel:SetHeight(140)

    local templateHeader = templateListPanel:CreateFontString(nil, "ARTWORK")
    templateHeader:SetFontObject(Theme.font.small)
    templateHeader:SetPoint("BOTTOMLEFT", templateListPanel, "TOPLEFT", 8, 4)
    templateHeader:SetText(L["Template"])

    local templateStateHeader = templateListPanel:CreateFontString(nil, "ARTWORK")
    templateStateHeader:SetFontObject(Theme.font.small)
    templateStateHeader:SetPoint("LEFT", templateHeader, "LEFT", 136, 0)
    templateStateHeader:SetText(L["State"])

    local templatePreviewHeader = templateListPanel:CreateFontString(nil, "ARTWORK")
    templatePreviewHeader:SetFontObject(Theme.font.small)
    templatePreviewHeader:SetPoint("LEFT", templateHeader, "LEFT", 190, 0)
    templatePreviewHeader:SetText(L["Preview"])

    MT.list = GP.UI.ScrollList:New(templateListPanel, MT.rowHeight, MT.createRow)
    MT.list:SetUpdateRow(MT.updateRow)

    -- Chain fields vertically so dynamic text cannot overlap later controls.
    local templateNameLabel = messageTemplates:CreateFontString(nil, "ARTWORK")
    templateNameLabel:SetFontObject(Theme.font.small)
    templateNameLabel:SetPoint("TOPLEFT", templateListPanel, "BOTTOMLEFT", 0, -12)
    templateNameLabel:SetText(L["Template Name"])

    MT.titleBox = Theme:CreateEditBox(messageTemplates, 220)
    MT.titleBox:SetPoint("TOPLEFT", templateNameLabel, "BOTTOMLEFT", 0, -4)
    MT.titleBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    local templateBodyLabel = messageTemplates:CreateFontString(nil, "ARTWORK")
    templateBodyLabel:SetFontObject(Theme.font.small)
    templateBodyLabel:SetPoint("TOPLEFT", MT.titleBox, "BOTTOMLEFT", 0, -10)
    templateBodyLabel:SetText(L["Message"])

    MT.bodyBox = createLargeSettingsEditBox(messageTemplates, 380, 90, 255)
    MT.bodyBox.holder:SetPoint("TOPLEFT", templateBodyLabel, "BOTTOMLEFT", 0, -4)
    MT.bodyBox.holder:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    MT.bodyBox.holder:SetHeight(MT.bodyBox.fixedHeight)
    MT.bodyBox:SetScript("OnTextChanged", MT.updatePreview)

    MT.countText = messageTemplates:CreateFontString(nil, "ARTWORK")
    MT.countText:SetFontObject(Theme.font.small)
    MT.countText:SetPoint("TOPLEFT", MT.bodyBox.holder, "BOTTOMLEFT", 0, -8)

    MT.previewText = messageTemplates:CreateFontString(nil, "ARTWORK")
    MT.previewText:SetFontObject(Theme.font.muted)
    MT.previewText:SetPoint("TOPLEFT", MT.countText, "BOTTOMLEFT", 0, -6)
    MT.previewText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    MT.previewText:SetJustifyH("LEFT")
    MT.previewText:SetHeight(34)

    MT.helpText = messageTemplates:CreateFontString(nil, "ARTWORK")
    MT.helpText:SetFontObject(Theme.font.small)
    MT.helpText:SetPoint("TOPLEFT", MT.previewText, "BOTTOMLEFT", 0, -10)
    MT.helpText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    MT.helpText:SetJustifyH("LEFT")
    MT.helpText:SetHeight(30)

    MT.saveButton = Theme:CreateButton(messageTemplates, L["Save"])
    MT.saveButton:SetPoint("TOPLEFT", MT.helpText, "BOTTOMLEFT", 0, -12)
    MT.saveButton:SetScript("OnClick", function()
        local RecruitmentModule = GP:GetModule("Recruitment")
        local ok, err, id = RecruitmentModule:AddOrUpdateMessage(RecruitmentModule:GetCurrentGuildKey(), MT.titleBox:GetText(), MT.bodyBox:GetText(), MT.selectedID)
        if ok then
            MT.selectedID = id
            GP:Print(L["Recruitment message saved."])
        else
            GP:Print(err)
        end
        MT.refresh()
    end)

    MT.newButton = Theme:CreateButton(messageTemplates, L["New"])
    MT.newButton:SetPoint("LEFT", MT.saveButton, "RIGHT", 8, 0)
    MT.newButton:SetScript("OnClick", function()
        if GP:GetModule("Recruitment"):IsMessageEditingLocked() then return end
        MT.clearForm()
        MT.refresh()
    end)

    MT.useButton = Theme:CreateButton(messageTemplates, L["Use"])
    MT.useButton:SetPoint("LEFT", MT.newButton, "RIGHT", 8, 0)
    MT.useButton:SetScript("OnClick", function()
        if GP:GetModule("Recruitment"):IsMessageEditingLocked() then return end
        local record = MT.selected()
        if not record then return end
        local RecruitmentModule = GP:GetModule("Recruitment")
        local ok, err = RecruitmentModule:SetSelectedMessage(RecruitmentModule:GetCurrentGuildKey(), record.id)
        GP:Print(ok and L["Recruitment message selected."] or err)
        MT.refresh()
    end)

    MT.removeButton = Theme:CreateButton(messageTemplates, L["Delete"])
    MT.removeButton:SetPoint("LEFT", MT.useButton, "RIGHT", 8, 0)
    MT.removeButton:SetScript("OnClick", function()
        if GP:GetModule("Recruitment"):IsMessageEditingLocked() then return end
        local record = MT.selected()
        if record then
            StaticPopup_Show(MT.removePopup, record.title or record.id, nil, { guildKey = GP:GetModule("Recruitment"):GetCurrentGuildKey(), id = record.id })
        end
    end)

    MT.testButton = Theme:CreateButton(messageTemplates, L["Test Whisper"])
    MT.testButton:SetPoint("LEFT", MT.removeButton, "RIGHT", 8, 0)
    MT.testButton:SetScript("OnClick", function()
        local record = MT.selected()
        local RecruitmentModule = GP:GetModule("Recruitment")
        local ok, err = RecruitmentModule:SendTestMessage(RecruitmentModule:GetCurrentGuildKey(), record and record.id)
        GP:Print(ok and L["Recruitment test whisper sent to your character."] or err)
    end)

    MT.clearForm()
    MT.refresh()
    -- RecruitmentChanged is handled by frame.refreshRecruitmentControls below.

    -- Invalid Zones fill the available sub-page height so both lists can
    -- show as many rows as possible.
    -- GetTop()/GetBottom() the way the removed fitHeightToContent helper
    -- did, so none of that helper's failure modes apply to this section.
    local INVALID_ZONE_COLUMN_WIDTH = 500

    local lockedZones = createSection(zonesPage, L["Default Invalid Zone List"])
    lockedZones:SetPoint("TOPLEFT", 0, 0)
    -- BOTTOMLEFT reuses the same x-offset (0) as TOPLEFT above, both
    -- relative to zonesPage — consistent, not conflicting, and gives this
    -- column zonesPage's full height automatically, however tall that
    -- turns out to be.
    lockedZones:SetPoint("BOTTOMLEFT", zonesPage, "BOTTOMLEFT", 0, 0)
    lockedZones:SetWidth(INVALID_ZONE_COLUMN_WIDTH)

    local lockedZonesDesc = addBodyText(lockedZones, lockedZones.heading,
        L["Built automatically from this season's Mythic dungeons/raids, common PvP battlegrounds and arenas, and Delves. The recruitment scanner uses this list when reviewing candidates."],
        INVALID_ZONE_COLUMN_WIDTH - Theme.layout.gutter * 2)
    lockedZonesDesc:SetFontObject(Theme.font.small)
    lockedZonesDesc:SetTextColor(unpack(Theme.color.textSecondary))

    IZ.lockedSearchBox = Theme:CreateSearchBox(lockedZones, 200, function() IZ.refreshLocked() end)
    IZ.lockedSearchBox:SetPoint("TOPLEFT", lockedZonesDesc, "BOTTOMLEFT", 0, -12)

    -- List panel stretches to fill whatever room lockedZones' own height
    -- (now page-filling, see above) leaves above the Rebuild List button —
    local lockedZoneListPanel = Theme:CreatePanel(lockedZones, "panel", "border")
    lockedZoneListPanel:SetPoint("TOPLEFT", IZ.lockedSearchBox, "BOTTOMLEFT", 0, -26)
    lockedZoneListPanel:SetPoint("BOTTOMRIGHT", lockedZones, "BOTTOMRIGHT", -Theme.layout.gutter, 56)

    local lockedZoneNameHeader = lockedZoneListPanel:CreateFontString(nil, "ARTWORK")
    lockedZoneNameHeader:SetFontObject(Theme.font.small)
    lockedZoneNameHeader:SetPoint("BOTTOMLEFT", lockedZoneListPanel, "TOPLEFT", 8, 4)
    lockedZoneNameHeader:SetText(L["Zone Name"])

    local lockedZoneReasonHeader = lockedZoneListPanel:CreateFontString(nil, "ARTWORK")
    lockedZoneReasonHeader:SetFontObject(Theme.font.small)
    lockedZoneReasonHeader:SetPoint("LEFT", lockedZoneNameHeader, "LEFT", 176, 0)
    lockedZoneReasonHeader:SetText(L["Reason"])

    IZ.lockedList = GP.UI.ScrollList:New(lockedZoneListPanel, IZ.rowHeight, IZ.createLockedRow)
    IZ.lockedList:SetUpdateRow(IZ.updateLockedRow)

    local rebuildZonesButton = Theme:CreateButton(lockedZones, L["Rebuild List"])
    rebuildZonesButton:SetPoint("TOPLEFT", lockedZoneListPanel, "BOTTOMLEFT", 0, -12)
    rebuildZonesButton:SetScript("OnClick", function()
        local zones = GP:GetModule("Recruitment"):RefreshLockedInvalidZones()
        local count = 0
        for _ in pairs(zones) do count = count + 1 end
        IZ.refreshLocked()
        setSettingsStatus(frame, string.format(L["Invalid zone list rebuilt (%d zones)."], count))
    end)

    local customZones = createSection(zonesPage, L["Your Invalid Zone List"])
    customZones:SetPoint("TOPLEFT", lockedZones, "TOPRIGHT", SECTION_GAP, 0)
    -- Match the locked-zones column height while keeping x anchors
    -- consistent.
    customZones:SetPoint("BOTTOMLEFT", lockedZones, "BOTTOMRIGHT", SECTION_GAP, 0)
    customZones:SetWidth(INVALID_ZONE_COLUMN_WIDTH)

    local customZonesDesc = addBodyText(customZones, customZones.heading,
        L["Add zones you don't want to recruit candidates in, such as world events or contested leveling areas. Shared with the rest of the guild."],
        INVALID_ZONE_COLUMN_WIDTH - Theme.layout.gutter * 2)
    customZonesDesc:SetFontObject(Theme.font.small)
    customZonesDesc:SetTextColor(unpack(Theme.color.textSecondary))

    IZ.customSearchBox = Theme:CreateSearchBox(customZones, 200, function() IZ.refreshCustom() end)
    IZ.customSearchBox:SetPoint("TOPLEFT", customZonesDesc, "BOTTOMLEFT", 0, -12)

    -- Stretches like lockedZoneListPanel above, reserving 220px below for
    -- the name/reason fields, buttons, and detail text that follow — hand-
    local customZoneListPanel = Theme:CreatePanel(customZones, "panel", "border")
    customZoneListPanel:SetPoint("TOPLEFT", IZ.customSearchBox, "BOTTOMLEFT", 0, -26)
    customZoneListPanel:SetPoint("BOTTOMRIGHT", customZones, "BOTTOMRIGHT", -Theme.layout.gutter, 220)

    local customZoneNameHeader = customZoneListPanel:CreateFontString(nil, "ARTWORK")
    customZoneNameHeader:SetFontObject(Theme.font.small)
    customZoneNameHeader:SetPoint("BOTTOMLEFT", customZoneListPanel, "TOPLEFT", 8, 4)
    customZoneNameHeader:SetText(L["Zone Name"])

    local customZoneReasonHeader = customZoneListPanel:CreateFontString(nil, "ARTWORK")
    customZoneReasonHeader:SetFontObject(Theme.font.small)
    customZoneReasonHeader:SetPoint("LEFT", customZoneNameHeader, "LEFT", 166, 0)
    customZoneReasonHeader:SetText(L["Reason"])

    IZ.customList = GP.UI.ScrollList:New(customZoneListPanel, IZ.rowHeight, IZ.createCustomRow)
    IZ.customList:SetUpdateRow(IZ.updateCustomRow)

    -- Everything below chains off the previous element's own actual
    -- rendered bottom, same discipline used for Message Templates above —
    -- no shared offsets, no fixed-far-anchor reservations.
    local zoneNameLabel = customZones:CreateFontString(nil, "ARTWORK")
    zoneNameLabel:SetFontObject(Theme.font.small)
    zoneNameLabel:SetPoint("TOPLEFT", customZoneListPanel, "BOTTOMLEFT", 0, -12)
    zoneNameLabel:SetText(L["Zone Name"])

    IZ.nameBox = Theme:CreateEditBox(customZones, 220)
    IZ.nameBox:SetPoint("TOPLEFT", zoneNameLabel, "BOTTOMLEFT", 0, -4)
    IZ.nameBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    local zoneReasonLabel = customZones:CreateFontString(nil, "ARTWORK")
    zoneReasonLabel:SetFontObject(Theme.font.small)
    zoneReasonLabel:SetPoint("TOPLEFT", IZ.nameBox, "BOTTOMLEFT", 0, -10)
    zoneReasonLabel:SetText(L["Reason"])

    IZ.reasonBox = Theme:CreateEditBox(customZones, 220)
    IZ.reasonBox:SetPoint("TOPLEFT", zoneReasonLabel, "BOTTOMLEFT", 0, -4)
    IZ.reasonBox:SetPoint("RIGHT", -Theme.layout.gutter, 0)

    local saveZoneButton = Theme:CreateButton(customZones, L["Save"])
    saveZoneButton:SetPoint("TOPLEFT", IZ.reasonBox, "BOTTOMLEFT", 0, -12)
    saveZoneButton:SetScript("OnClick", function()
        local RecruitmentModule = GP:GetModule("Recruitment")
        local ok, err, id = RecruitmentModule:AddCustomInvalidZone(RecruitmentModule:GetCurrentGuildKey(), IZ.nameBox:GetText(), IZ.reasonBox:GetText(), IZ.selectedID)
        if ok then
            IZ.selectedID = id
            GP:Print(L["Invalid zone record saved."])
        else
            GP:Print(err)
        end
        IZ.refreshCustom()
    end)

    local newZoneButton = Theme:CreateButton(customZones, L["New"])
    newZoneButton:SetPoint("LEFT", saveZoneButton, "RIGHT", 8, 0)
    newZoneButton:SetScript("OnClick", function()
        IZ.clearForm()
        IZ.refreshCustom()
    end)

    IZ.removeButton = Theme:CreateButton(customZones, L["Remove"])
    IZ.removeButton:SetPoint("LEFT", newZoneButton, "RIGHT", 8, 0)
    IZ.removeButton:SetScript("OnClick", function()
        local record = IZ.selectedCustom()
        if record then
            StaticPopup_Show(IZ.removePopup, record.name or record.id, nil, { guildKey = GP:GetModule("Recruitment"):GetCurrentGuildKey(), id = record.id })
        end
    end)

    IZ.detailText = customZones:CreateFontString(nil, "ARTWORK")
    IZ.detailText:SetFontObject(Theme.font.muted)
    IZ.detailText:SetPoint("TOPLEFT", saveZoneButton, "BOTTOMLEFT", 0, -10)
    IZ.detailText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    IZ.detailText:SetHeight(34)
    IZ.detailText:SetJustifyH("LEFT")
    -- No fitHeightToContent call here — customZones' height already comes
    -- from filling the page (its BOTTOMLEFT anchor above), not from this
    -- element.

    IZ.clearForm()
    IZ.refreshLocked()
    IZ.refreshCustom()
    -- No standalone GuildParagon_RecruitmentChanged registration here —
    -- same reasoning as MT.refresh() above; frame.refreshRecruitmentControls
    -- already calls IZ.refreshLocked()/IZ.refreshCustom() itself.

    -- Filters — a single full-page section. This uses the same safe
    -- fill-parent corner anchoring as the Invalid Zones columns: no
    -- content-driven GetTop/GetBottom reads, and no guessed literal height
    -- that can run past the bottom of the Settings page.
    local filtersSection = createSection(filtersPage, L["Saved Filters"])
    filtersSection:SetPoint("TOPLEFT", 0, 0)
    filtersSection:SetPoint("BOTTOMRIGHT", filtersPage, "BOTTOMRIGHT", 0, 0)

    local filtersDesc = addBodyText(filtersSection, filtersSection.heading,
        L["Save filters so the recruitment scanner can skip candidates outside them. Leave classes, races, and level blank to match everyone."],
        1020)
    filtersDesc:SetFontObject(Theme.font.small)
    filtersDesc:SetTextColor(unpack(Theme.color.textSecondary))

    FT.searchBox = Theme:CreateSearchBox(filtersSection, 200, function() FT.refresh() end)
    FT.searchBox:SetPoint("TOPLEFT", filtersDesc, "BOTTOMLEFT", 0, -12)

    local filterListPanel = Theme:CreatePanel(filtersSection, "panel", "border")
    filterListPanel:SetPoint("TOPLEFT", FT.searchBox, "BOTTOMLEFT", 0, -26)
    filterListPanel:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    filterListPanel:SetHeight(86)

    local filterNameHeader = filterListPanel:CreateFontString(nil, "ARTWORK")
    filterNameHeader:SetFontObject(Theme.font.small)
    filterNameHeader:SetPoint("BOTTOMLEFT", filterListPanel, "TOPLEFT", 8, 4)
    filterNameHeader:SetText(L["Filter Name"])

    local filterSummaryHeader = filterListPanel:CreateFontString(nil, "ARTWORK")
    filterSummaryHeader:SetFontObject(Theme.font.small)
    filterSummaryHeader:SetPoint("LEFT", filterNameHeader, "LEFT", 196, 0)
    filterSummaryHeader:SetText(L["Criteria"])

    FT.list = GP.UI.ScrollList:New(filterListPanel, FT.rowHeight, FT.createRow)
    FT.list:SetUpdateRow(FT.updateRow)

    -- Everything below chains off the previous element's own actual
    -- rendered bottom, same discipline used elsewhere in this file.
    local filterNameLabel = filtersSection:CreateFontString(nil, "ARTWORK")
    filterNameLabel:SetFontObject(Theme.font.small)
    filterNameLabel:SetPoint("TOPLEFT", filterListPanel, "BOTTOMLEFT", 0, -12)
    filterNameLabel:SetText(L["Filter Name"])

    FT.nameBox = Theme:CreateEditBox(filtersSection, 300)
    FT.nameBox:SetPoint("TOPLEFT", filterNameLabel, "BOTTOMLEFT", 0, -4)

    -- Classes (left half) and Races (right half) grids, side by side —
    -- built once here via buildFilterCheckGrid and reused across refreshes
    -- (FT.refresh only reads/writes GetChecked()/SetChecked(), never
    -- rebuilds the grid).
    local classesLabel = filtersSection:CreateFontString(nil, "ARTWORK")
    classesLabel:SetFontObject(Theme.font.small)
    classesLabel:SetPoint("TOPLEFT", FT.nameBox, "BOTTOMLEFT", 0, -14)
    classesLabel:SetText(L["Classes"])

    local classesGrid = CreateFrame("Frame", nil, filtersSection)
    classesGrid:SetPoint("TOPLEFT", classesLabel, "BOTTOMLEFT", 0, -6)
    classesGrid:SetSize(420, 110)
    FT.classChecks = buildFilterCheckGrid(classesGrid, GP:GetModule("Recruitment"):GetClassList(), 3, 140, 22)

    local racesLabel = filtersSection:CreateFontString(nil, "ARTWORK")
    racesLabel:SetFontObject(Theme.font.small)
    racesLabel:SetPoint("TOPLEFT", classesLabel, "TOPLEFT", 455, 0)
    racesLabel:SetText(L["Races"])

    local racesGrid = CreateFrame("Frame", nil, filtersSection)
    racesGrid:SetPoint("TOPLEFT", racesLabel, "BOTTOMLEFT", 0, -6)
    racesGrid:SetSize(560, 198)
    FT.raceChecks = buildFilterCheckGrid(racesGrid, GP:GetModule("Recruitment"):GetRaceList(), 3, 185, 22)

    -- Fixed reserve below classesLabel's own top (not "below the
    -- grid", since the grid's real height varies with the player's own
    -- faction's race count) — generous against the full cross-faction
    -- races grid while
    -- keeping the controls clear of the Settings page bottom.
    local levelLabel = filtersSection:CreateFontString(nil, "ARTWORK")
    levelLabel:SetFontObject(Theme.font.small)
    levelLabel:SetPoint("TOPLEFT", classesLabel, "BOTTOMLEFT", 0, -222)
    levelLabel:SetText(L["Min Level"])

    FT.minLevelBox = Theme:CreateEditBox(filtersSection, 58)
    FT.minLevelBox:SetPoint("LEFT", levelLabel, "RIGHT", 8, 0)

    local maxLevelLabel = filtersSection:CreateFontString(nil, "ARTWORK")
    maxLevelLabel:SetFontObject(Theme.font.small)
    maxLevelLabel:SetPoint("LEFT", FT.minLevelBox, "RIGHT", 20, 0)
    maxLevelLabel:SetText(L["Max Level"])

    FT.maxLevelBox = Theme:CreateEditBox(filtersSection, 58)
    FT.maxLevelBox:SetPoint("LEFT", maxLevelLabel, "RIGHT", 8, 0)

    local saveFilterButton = Theme:CreateButton(filtersSection, L["Save"])
    saveFilterButton:SetPoint("TOPLEFT", levelLabel, "BOTTOMLEFT", 0, -14)
    saveFilterButton:SetScript("OnClick", function()
        if GP:GetModule("Recruitment"):IsFilterEditingLocked() then
            GP:Print(L["The guild master has locked recruitment filters."])
            return
        end
        local classes, races = {}, {}
        for id, check in pairs(FT.classChecks) do if id ~= "_controls" and check:GetChecked() then classes[id] = true end end
        for _, check in ipairs(getCheckControls(FT.raceChecks)) do
            if check:GetChecked() then
                for _, id in ipairs(check.filterIDs or {}) do
                    races[id] = true
                end
            end
        end
        local RecruitmentModule = GP:GetModule("Recruitment")
        local ok, err, id = RecruitmentModule:AddOrUpdateFilter(RecruitmentModule:GetCurrentGuildKey(), FT.nameBox:GetText(), classes, races, FT.minLevelBox:GetText(), FT.maxLevelBox:GetText(), FT.selectedID)
        if ok then
            FT.selectedID = id
            GP:Print(L["Recruitment filter saved."])
        else
            GP:Print(err)
        end
        FT.refresh()
    end)
    FT.saveButton = saveFilterButton

    local newFilterButton = Theme:CreateButton(filtersSection, L["New"])
    newFilterButton:SetPoint("LEFT", saveFilterButton, "RIGHT", 8, 0)
    newFilterButton:SetScript("OnClick", function()
        FT.clearForm()
        FT.refresh()
    end)
    FT.newButton = newFilterButton

    FT.useButton = Theme:CreateButton(filtersSection, L["Use"])
    FT.useButton:SetPoint("LEFT", newFilterButton, "RIGHT", 8, 0)
    FT.useButton:SetScript("OnClick", function()
        local record = FT.selected()
        if not record then return end
        local RecruitmentModule = GP:GetModule("Recruitment")
        local ok, err = RecruitmentModule:SetSelectedFilter(RecruitmentModule:GetCurrentGuildKey(), record.id)
        GP:Print(ok and L["Recruitment filter selected."] or err)
        FT.refresh()
    end)

    FT.removeButton = Theme:CreateButton(filtersSection, L["Remove"])
    FT.removeButton:SetPoint("LEFT", FT.useButton, "RIGHT", 8, 0)
    FT.removeButton:SetScript("OnClick", function()
        local record = FT.selected()
        if record then
            StaticPopup_Show(FT.removePopup, record.name or record.id, nil, { guildKey = GP:GetModule("Recruitment"):GetCurrentGuildKey(), id = record.id })
        end
    end)

    FT.detailText = filtersSection:CreateFontString(nil, "ARTWORK")
    FT.detailText:SetFontObject(Theme.font.muted)
    FT.detailText:SetPoint("TOPLEFT", saveFilterButton, "BOTTOMLEFT", 0, -10)
    FT.detailText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    FT.detailText:SetHeight(34)
    FT.detailText:SetJustifyH("LEFT")

    FT.clearForm()
    FT.refresh()
    -- No standalone GuildParagon_RecruitmentChanged registration here —
    -- same reasoning as MT.refresh() above; frame.refreshRecruitmentControls
    -- already calls FT.refresh() itself.

    frame.refreshRecruitmentControls = function()
        recruitmentSettings = ensureRecruitmentSettings()
        recruitmentLocked = Recruitment and Recruitment.AreSettingsLocked and Recruitment:AreSettingsLocked()

        obeyBlockInvitesCheck:SetChecked(recruitmentSettings.obeyBlockInvites)
        antiSpamCheck:SetChecked(recruitmentSettings.antiSpam)
        retailContextMenuCheck:SetChecked(recruitmentSettings.retailContextMenus)
        if not antiSpamDaysBox:HasFocus() then antiSpamDaysBox:SetText(tostring(recruitmentSettings.antiSpamDays)) end
        if not pendingTimeoutDaysBox:HasFocus() then pendingTimeoutDaysBox:SetText(tostring(recruitmentSettings.pendingTimeoutDays or 7)) end
        if not messageDelayBox:HasFocus() then messageDelayBox:SetText(tostring(recruitmentSettings.messageDelay)) end
        selectedExecutorMode = recruitmentSettings.executorMode or "whisper"
        refreshExecutorModeButtons()

        local editable = not recruitmentLocked
        setControlEnabled(obeyBlockInvitesCheck, editable)
        setControlEnabled(antiSpamCheck, editable)
        setControlEnabled(antiSpamDaysBox, editable)
        setControlEnabled(pendingTimeoutDaysBox, editable)
        setControlEnabled(messageDelayBox, editable)
        setControlEnabled(retailContextMenuCheck, true)
        for _, button in pairs(executorModeButtons) do
            setControlEnabled(button, editable)
        end
        setControlEnabled(saveRecruitmentButton, editable)

        -- Guild-master-only controls: never touched by `editable` above —
        -- same reasoning as gmEnforcedCheck/lockMessagesCheck/lockFiltersCheck
        if gmEnforcedCheck then gmEnforcedCheck:SetChecked(recruitmentSettings.gmEnforced) end
        if lockMessagesCheck then lockMessagesCheck:SetChecked(recruitmentSettings.lockMessages) end
        if lockFiltersCheck then lockFiltersCheck:SetChecked(recruitmentSettings.lockFilters) end
        if requireOfficerCheck then requireOfficerCheck:SetChecked(recruitmentSettings.requireOfficer) end

        -- Follow-up welcome messages never gate on `editable` — see the
        -- comment above saveFollowUpButton's OnClick handler.
        followUpSettings = recruitmentSettings
        welcomeGuildCheck:SetChecked(followUpSettings.welcomeGuild)
        if not guildWelcomeBox:HasFocus() then guildWelcomeBox:SetText(followUpSettings.welcomeGuildMessage or "") end
        welcomeWhisperCheck:SetChecked(followUpSettings.welcomeWhisper)
        if not whisperWelcomeBox:HasFocus() then whisperWelcomeBox:SetText(followUpSettings.welcomeWhisperMessage or "") end

        MT.refresh()
        IZ.refreshLocked()
        IZ.refreshCustom()
        FT.refresh()
    end
    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua. GuildParagon_RecruitmentSettingsChanged in particular
    -- can fire repeatedly during a guild-master settings/snapshot sync.
    -- Collapse the burst to one refresh on the next frame instead.
    local function debouncedRefreshRecruitmentControls()
        if not frame or not frame:IsShown() then
            if frame then frame.refreshRecruitmentControlsDirty = true end
            return
        end
        GP:DebounceCall("Settings:refreshRecruitmentControls", function()
            if frame and frame:IsShown() then
                frame.refreshRecruitmentControlsDirty = false
                if frame.refreshRecruitmentControls then frame.refreshRecruitmentControls() end
            elseif frame then
                frame.refreshRecruitmentControlsDirty = true
            end
        end)
    end
    Settings:RegisterMessage("GuildParagon_RecruitmentChanged", debouncedRefreshRecruitmentControls)
    Settings:RegisterMessage("GuildParagon_RecruitmentSettingsChanged", debouncedRefreshRecruitmentControls)

    -- Default page unless a caller requests a specific recruitment sub-tab.
    selectRecruitmentSubPage("safety")

    local chat = createSection(chatPage, L["Chat Name Hints"])
    chat:SetPoint("TOPLEFT", 0, 0)
    chat:SetSize(SETTINGS_PAGE_WIDTH, 420)

    local chatSettings = GP:GetModule("GuildChat"):GetSettings()
    local checks = {}
    local function setChatSetting(key, value)
        chatSettings[key] = value
    end

    checks.guild = createCheck(chat, L["Guild chat"], function(value) setChatSetting("guild", value) end)
    checks.guild:SetPoint("TOPLEFT", chat.heading, "BOTTOMLEFT", 0, -8)
    checks.guild:SetChecked(chatSettings.guild)
    local guildChatDesc = addOptionDescription(chat, checks.guild, L["Shows local name hints on guild chat lines."], 280)

    checks.officer = createCheck(chat, L["Officer chat"], function(value) setChatSetting("officer", value) end)
    checks.officer:SetPoint("TOPLEFT", guildChatDesc, "BOTTOMLEFT", -26, -8)
    checks.officer:SetChecked(chatSettings.officer)
    local officerChatDesc = addOptionDescription(chat, checks.officer, L["Shows local name hints on officer chat lines when you can see them."], 280)

    checks.party = createCheck(chat, L["Party chat"], function(value) setChatSetting("party", value) end)
    checks.party:SetPoint("TOPLEFT", officerChatDesc, "BOTTOMLEFT", -26, -8)
    checks.party:SetChecked(chatSettings.party)
    local partyChatDesc = addOptionDescription(chat, checks.party, L["Shows local name hints in party chat for guild members Guild Paragon can identify."], 280)

    checks.raid = createCheck(chat, L["Raid chat"], function(value) setChatSetting("raid", value) end)
    checks.raid:SetPoint("TOPLEFT", partyChatDesc, "BOTTOMLEFT", -26, -8)
    checks.raid:SetChecked(chatSettings.raid)
    local raidChatDesc = addOptionDescription(chat, checks.raid, L["Shows local name hints in raid chat for guild members Guild Paragon can identify."], 280)

    checks.achievements = createCheck(chat, L["Achievement chat"], function(value) setChatSetting("achievements", value) end)
    checks.achievements:SetPoint("TOPLEFT", raidChatDesc, "BOTTOMLEFT", -26, -8)
    checks.achievements:SetChecked(chatSettings.achievements)
    addOptionDescription(chat, checks.achievements, L["Shows local name hints on guild achievement messages."], 280)

    checks.nicknames = createCheck(chat, L["Show nicknames"], function(value) setChatSetting("nicknames", value) end)
    checks.nicknames:SetPoint("TOPLEFT", chat.heading, "BOTTOMLEFT", 340, -8)
    fitCheckLabel(checks.nicknames, 360)
    checks.nicknames:SetChecked(chatSettings.nicknames)
    local nicknamesDesc = addOptionDescription(chat, checks.nicknames, L["Uses saved nicknames when building local chat hints."], 360)

    checks.preferNickname = createCheck(chat, L["Prefer nickname over main name"], function(value) setChatSetting("preferNickname", value) end)
    checks.preferNickname:SetPoint("TOPLEFT", nicknamesDesc, "BOTTOMLEFT", -26, -8)
    fitCheckLabel(checks.preferNickname, 300)
    checks.preferNickname:SetChecked(chatSettings.preferNickname)
    local preferNicknameDesc = addOptionDescription(chat, checks.preferNickname, L["When both are known, shows the nickname before the main name."], 360)

    checks.appendOwnNickname = createCheck(chat, L["Show my nickname on my messages"], function(value) setChatSetting("appendOwnNickname", value) end)
    checks.appendOwnNickname:SetPoint("TOPLEFT", preferNicknameDesc, "BOTTOMLEFT", -26, -8)
    fitCheckLabel(checks.appendOwnNickname, 300)
    checks.appendOwnNickname:SetChecked(chatSettings.appendOwnNickname)
    local appendOwnNicknameDesc = addOptionDescription(chat, checks.appendOwnNickname, L["Adds your own saved nickname to your local chat display only; it does not change the message other players receive."], 360)

    checks.showTags = createCheck(chat, L["Show main/alt tags"], function(value) setChatSetting("showTags", value) end)
    checks.showTags:SetPoint("TOPLEFT", appendOwnNicknameDesc, "BOTTOMLEFT", -26, -8)
    fitCheckLabel(checks.showTags, 360)
    checks.showTags:SetChecked(chatSettings.showTags)
    local showTagsDesc = addOptionDescription(chat, checks.showTags, L["Adds compact main or alt tags to make linked characters easier to spot."], 360)

    checks.showMainName = createCheck(chat, L["Show main name for alts"], function(value) setChatSetting("showMainName", value) end)
    checks.showMainName:SetPoint("TOPLEFT", showTagsDesc, "BOTTOMLEFT", -26, -8)
    fitCheckLabel(checks.showMainName, 300)
    checks.showMainName:SetChecked(chatSettings.showMainName)
    local showMainNameDesc = addOptionDescription(chat, checks.showMainName, L["Displays the linked main character when an alt speaks."], 360)

    checks.fallbackToMainName = createCheck(chat, L["Fallback to main name"], function(value) setChatSetting("fallbackToMainName", value) end)
    checks.fallbackToMainName:SetPoint("TOPLEFT", showMainNameDesc, "BOTTOMLEFT", -26, -8)
    fitCheckLabel(checks.fallbackToMainName, 300)
    checks.fallbackToMainName:SetChecked(chatSettings.fallbackToMainName)
    local fallbackToMainNameDesc = addOptionDescription(chat, checks.fallbackToMainName, L["Uses the linked main name when no nickname is available."], 360)

    checks.classColor = createCheck(chat, L["Color hints by class"], function(value) setChatSetting("classColor", value) end)
    checks.classColor:SetPoint("TOPLEFT", fallbackToMainNameDesc, "BOTTOMLEFT", -26, -8)
    fitCheckLabel(checks.classColor, 300)
    checks.classColor:SetChecked(chatSettings.classColor)
    addOptionDescription(chat, checks.classColor, L["Colors hinted names using the character or linked main class color."], 360)

    self:RefreshStatus(frame)
    refreshPerformanceText(frame)
    frame.backupTabButton:SetShown(GP:IsOfficer())
    self:SelectSettingsPage(frame, "general")
    frame.OnSelected = function()
        frame.backupTabButton:SetShown(GP:IsOfficer())
        if frame.refreshLabelsDirty then
            frame.refreshLabelsDirty = false
            LB.refresh()
        end
        if frame.refreshHealthMacroIgnoresDirty then
            frame.refreshHealthMacroIgnoresDirty = false
            GH.refreshMacroIgnores()
        end
        if frame.refreshRecruitmentControlsDirty then
            frame.refreshRecruitmentControlsDirty = false
            if frame.refreshRecruitmentControls then frame.refreshRecruitmentControls() end
        else
            if frame.refreshRecruitmentControls then frame.refreshRecruitmentControls() end
        end
    end
    self.frame = frame
    return frame
end

function Settings:OpenRecruitmentPage(subTab)
    if not self.frame then return end
    self:SelectSettingsPage(self.frame, "recruitment")
    if subTab and self.frame.selectRecruitmentSubPage then
        self.frame.selectRecruitmentSubPage(subTab)
    end
end

function Settings:SelectSettingsPage(frame, key)
    if not frame or not frame.settingPages then return end
    if key == "backup" and not GP:IsOfficer() then key = "general" end
    for pageKey, page in pairs(frame.settingPages) do
        page:SetShown(pageKey == key)
    end
    for tabKey, tab in pairs(frame.settingTabs or {}) do
        tab:SetSelected(tabKey == key)
    end
    if key == "recruitment" and frame.refreshRecruitmentControls then
        frame.refreshRecruitmentControls()
    end
    if key == "labels" then
        LB.refresh()
    end
    if key == "health" and frame.refreshHealthMacroIgnoresDirty then
        frame.refreshHealthMacroIgnoresDirty = false
        GH.refreshMacroIgnores()
    end
    if key == "backup" and GP.UI.BackupRestoreTab.OnSelected then
        GP.UI.BackupRestoreTab:OnSelected()
    end
end

function Settings:RefreshStatus(frame)
    local L = GP.L
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]

    if not guildData then
        frame.statusText:SetText(L["No roster data yet — try Rescan Now, or /gp scan."])
        return
    end

    local activeCount, formerCount = Roster:CountMembers(guildData)
    local lastScan = guildData.lastScan and date("%Y-%m-%d %H:%M", guildData.lastScan) or L["never"]

    frame.statusText:SetText(string.format(
        L["Guild: %s\nActive: %d, Former: %d\nLast scan: %s"],
        displayGuildName(guildKey), activeCount, formerCount, lastScan
    ))
end
