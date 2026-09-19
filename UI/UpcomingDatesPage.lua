-- Guild Paragon - Upcoming Dates Guild Health page
local _, GP = ...
local Theme = GP.UI.Theme
local ScrollList = GP.UI.ScrollList

GP.UI.UpcomingDatesPage = GP.UI.UpcomingDatesPage or {}
local UpcomingDatesPage = GP.UI.UpcomingDatesPage

local ROW_HEIGHT = 34
local GREETING_POPUP = "GUILDPARAGON_COPY_UPCOMING_GREETING"

StaticPopupDialogs[GREETING_POPUP] = StaticPopupDialogs[GREETING_POPUP] or {
    text = GP.L["Copy greeting:"],
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

local function addText(parent, font, text, point)
    local value = parent:CreateFontString(nil, "ARTWORK")
    value:SetFontObject(font)
    value:SetJustifyH("LEFT")
    value:SetText(text or "")
    if point then value:SetPoint(unpack(point)) end
    return value
end

local function createCheck(parent, label)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check.Text:SetFontObject(Theme.font.body)
    check.Text:SetText(label)
    return check
end

local function dateText(row)
    local occurrence = row and row.occurrence
    if not occurrence then return "" end
    return string.format("%02d-%02d-%04d", occurrence.day, occurrence.month, occurrence.year)
end

local function typeText(row)
    return row.type == "birthday" and GP.L["Birthday"] or GP.L["Anniversary"]
end

local function provenanceText(row)
    if row.type == "birthday" then return GP.L["Person date"] end
    if row.provenance == "verified" then return GP.L["Verified"] end
    if row.provenance == "imported" then return GP.L["Imported"] end
    return GP.L["Estimated"]
end

local function yearsText(row)
    if row.type ~= "anniversary" then return "—" end
    return tostring(row.years or 0)
end

local function classColor(classFile)
    local color = classFile and C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile)
    if color then return color.r, color.g, color.b end
    return unpack(Theme.color.textPrimary)
end

local calendarDialog

local function createInput(parent, width, height, multiline)
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetSize(width, height)
    input:SetFontObject(Theme.font.body)
    if multiline then
        input:SetMultiLine(true)
        input:SetTextInsets(6, 6, 6, 6)
        input:SetJustifyV("TOP")
    end
    return input
end

local function ensureCalendarDialog()
    if calendarDialog then return calendarDialog end
    local dialog = Theme:CreatePanel(UIParent, "panel", "accent")
    dialog:SetSize(570, 350)
    dialog:SetPoint("CENTER")
    dialog:SetFrameStrata("DIALOG")
    dialog:SetFrameLevel(200)
    dialog:EnableMouse(true)
    dialog:Hide()

    local heading = addText(dialog, Theme.font.heading, GP.L["Create guild announcement"], { "TOPLEFT", dialog, "TOPLEFT", 18, -16 })
    local close = Theme:CreateCloseButton(dialog)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() dialog:Hide() end)

    local titleLabel = addText(dialog, Theme.font.small, GP.L["Calendar title:"], { "TOPLEFT", heading, "BOTTOMLEFT", 0, -18 })
    dialog.title = createInput(dialog, 520, 28)
    dialog.title:SetPoint("TOPLEFT", titleLabel, "BOTTOMLEFT", 4, -4)
    dialog.title:SetMaxLetters(31)

    local dateLabel = addText(dialog, Theme.font.small, GP.L["Calendar date (day / month / year):"], { "TOPLEFT", dialog.title, "BOTTOMLEFT", -4, -14 })
    dialog.day = createInput(dialog, 54, 26)
    dialog.day:SetPoint("TOPLEFT", dateLabel, "BOTTOMLEFT", 4, -4)
    dialog.day:SetNumeric(true)
    dialog.day:SetMaxLetters(2)
    dialog.month = createInput(dialog, 54, 26)
    dialog.month:SetPoint("LEFT", dialog.day, "RIGHT", 12, 0)
    dialog.month:SetNumeric(true)
    dialog.month:SetMaxLetters(2)
    dialog.year = createInput(dialog, 76, 26)
    dialog.year:SetPoint("LEFT", dialog.month, "RIGHT", 12, 0)
    dialog.year:SetNumeric(true)
    dialog.year:SetMaxLetters(4)

    local descriptionLabel = addText(dialog, Theme.font.small, GP.L["Calendar description:"], { "TOPLEFT", dialog.day, "BOTTOMLEFT", -4, -14 })
    dialog.description = createInput(dialog, 520, 82, true)
    dialog.description:SetPoint("TOPLEFT", descriptionLabel, "BOTTOMLEFT", 4, -4)
    dialog.description:SetMaxLetters(255)

    dialog.status = addText(dialog, Theme.font.small, "", { "TOPLEFT", dialog.description, "BOTTOMLEFT", 0, -10 })
    dialog.status:SetWidth(520)
    dialog.status:SetTextColor(unpack(Theme.color.warning))

    dialog.create = Theme:CreateButton(dialog, GP.L["Create"])
    dialog.create:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 16)
    local cancel = Theme:CreateButton(dialog, CANCEL)
    cancel:SetPoint("RIGHT", dialog.create, "LEFT", -10, 0)
    cancel:SetScript("OnClick", function() dialog:Hide() end)

    dialog.create:SetScript("OnClick", function()
        if not dialog.preview then return end
        dialog.preview.title = dialog.title:GetText()
        dialog.preview.description = dialog.description:GetText()
        dialog.preview.day = dialog.day:GetNumber()
        dialog.preview.month = dialog.month:GetNumber()
        dialog.preview.year = dialog.year:GetNumber()
        local UpcomingDates = GP:GetModule("UpcomingDates")
        local ok, message, code = UpcomingDates:CreateCalendarEvent(dialog.preview, dialog.allowDuplicate)
        if ok then
            dialog:Hide()
        elseif code == "duplicate" then
            dialog.allowDuplicate = true
            dialog.status:SetText(GP.L["A matching announcement exists. Click Create again to create another."])
        else
            dialog.allowDuplicate = false
            dialog.status:SetText(message or GP.L["The calendar announcement could not be submitted."])
        end
    end)

    calendarDialog = dialog
    return dialog
end

local function showCalendarDialog(preview)
    local dialog = ensureCalendarDialog()
    dialog.preview = preview
    dialog.allowDuplicate = false
    dialog.title:SetText(preview.title or "")
    dialog.description:SetText(preview.description or "")
    dialog.day:SetNumber(preview.day or 0)
    dialog.month:SetNumber(preview.month or 0)
    dialog.year:SetNumber(preview.year or 0)
    dialog.status:SetText(GP.L["Review the announcement, then click Create to add it to the guild calendar."])
    dialog:Show()
    dialog:Raise()
    dialog.title:SetFocus()
    dialog.title:HighlightText()
end

local function createRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel", "border")))
    row:SetBackdropColor(unpack(Theme.color.panel))
    row:SetBackdropBorderColor(unpack(Theme.color.border))

    row.typeText = addText(row, Theme.font.small, "", { "LEFT", row, "LEFT", 8, 0 })
    row.typeText:SetWidth(82)
    row.name = addText(row, Theme.font.body, "", { "LEFT", row.typeText, "RIGHT", 8, 0 })
    row.name:SetWidth(178)
    row.date = addText(row, Theme.font.body, "", { "LEFT", row.name, "RIGHT", 8, 0 })
    row.date:SetWidth(94)
    row.years = addText(row, Theme.font.body, "", { "LEFT", row.date, "RIGHT", 8, 0 })
    row.years:SetWidth(48)
    row.provenance = addText(row, Theme.font.small, "", { "LEFT", row.years, "RIGHT", 8, 0 })
    row.provenance:SetWidth(92)
    row.remaining = addText(row, Theme.font.body, "", { "LEFT", row.provenance, "RIGHT", 8, 0 })
    row.remaining:SetWidth(72)
    row.copy = Theme:CreateButton(row, GP.L["Copy greeting"])
    row.copy:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.calendar = Theme:CreateButton(row, GP.L["Create event"])
    row.calendar:SetPoint("RIGHT", row.copy, "LEFT", -8, 0)
    return row
end

local function updateRow(row, data)
    row.typeText:SetText(typeText(data))
    row.name:SetText(data.name or "")
    row.name:SetTextColor(classColor(data.class))
    row.date:SetText(dateText(data))
    row.years:SetText(yearsText(data))
    row.provenance:SetText(provenanceText(data))
    if data.daysRemaining == 0 then
        row.remaining:SetText(GP.L["Today"])
    elseif data.daysRemaining == 1 then
        row.remaining:SetText(GP.L["1 day"])
    else
        row.remaining:SetText(string.format(GP.L["%d days"], data.daysRemaining or 0))
    end
    row.copy:SetScript("OnClick", function()
        local greeting = GP:GetModule("UpcomingDates"):GetGreeting(data)
        StaticPopup_Show(GREETING_POPUP, nil, nil, greeting)
    end)
    local UpcomingDates = GP:GetModule("UpcomingDates")
    local preview = UpcomingDates:GetCalendarPreview(data)
    local allowed = preview and UpcomingDates:CanCreateCalendarEvent(preview)
    row.calendar:SetShown(allowed and true or false)
    row.calendar:SetScript("OnClick", function()
        local current = UpcomingDates:GetCalendarPreview(data)
        local canCreate, reason = UpcomingDates:CanCreateCalendarEvent(current)
        if not canCreate then
            if reason then GP:Print(reason) end
            return
        end
        showCalendarDialog(current)
    end)
end

function UpcomingDatesPage:Build(parent)
    local L = GP.L
    local UpcomingDates = GP:GetModule("UpcomingDates")
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local heading = addText(page, Theme.font.heading, L["Upcoming Dates"], { "TOPLEFT" })
    local summary = addText(page, Theme.font.muted, L["Birthdays and character guild anniversaries within your selected reminder window."], { "TOPLEFT", heading, "BOTTOMLEFT", 0, -6 })

    local showBirthdays = createCheck(page, L["Show birthdays"])
    showBirthdays:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", -4, -12)
    local showAnniversaries = createCheck(page, L["Show membership anniversaries"])
    showAnniversaries:SetPoint("LEFT", showBirthdays, "RIGHT", 150, 0)
    local includeEstimated = createCheck(page, L["Include estimated anniversaries"])
    includeEstimated:SetPoint("LEFT", showAnniversaries, "RIGHT", 210, 0)

    local windowLabel = addText(page, Theme.font.body, L["Reminder window:"], { "TOPLEFT", showBirthdays, "BOTTOMLEFT", 4, -10 })
    local windowButtons = {}
    local previous
    for _, days in ipairs({ 7, 14, 30 }) do
        local button = Theme:CreateButton(page, string.format(L["%d Days"], days))
        button.days = days
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        else
            button:SetPoint("LEFT", windowLabel, "RIGHT", 10, 0)
        end
        windowButtons[#windowButtons + 1] = button
        previous = button
    end

    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", windowLabel, "BOTTOMLEFT", 0, -14)
    header:SetPoint("RIGHT")
    header:SetHeight(18)
    addText(header, Theme.font.small, L["Type"], { "LEFT", header, "LEFT", 8, 0 }):SetWidth(82)
    addText(header, Theme.font.small, L["Name"], { "LEFT", header, "LEFT", 98, 0 }):SetWidth(178)
    addText(header, Theme.font.small, L["Date"], { "LEFT", header, "LEFT", 284, 0 }):SetWidth(94)
    addText(header, Theme.font.small, L["Years"], { "LEFT", header, "LEFT", 386, 0 }):SetWidth(48)
    addText(header, Theme.font.small, L["Source"], { "LEFT", header, "LEFT", 442, 0 }):SetWidth(92)
    addText(header, Theme.font.small, L["Due"], { "LEFT", header, "LEFT", 542, 0 }):SetWidth(72)

    local listPanel = Theme:CreatePanel(page, "panel", "border")
    listPanel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    listPanel:SetPoint("BOTTOMRIGHT")
    local list = ScrollList:New(listPanel, ROW_HEIGHT, createRow)
    list:SetUpdateRow(updateRow)

    local empty = addText(listPanel, Theme.font.muted, L["No upcoming dates match these settings."], { "CENTER" })

    local function paintSettings()
        local settings = UpcomingDates:GetSettings()
        showBirthdays:SetChecked(settings.showBirthdays)
        showAnniversaries:SetChecked(settings.showAnniversaries)
        includeEstimated:SetChecked(settings.includeEstimatedAnniversaries)
        for _, button in ipairs(windowButtons) do
            local selected = button.days == settings.reminderWindowDays
            button:SetBackdropBorderColor(unpack(selected and Theme.color.accent or Theme.color.accentDim))
            button.text:SetTextColor(unpack(selected and Theme.color.accent or Theme.color.textPrimary))
        end
    end

    function page:Refresh()
        paintSettings()
        local rows = UpcomingDates:GetRows()
        list:SetData(rows, true)
        empty:SetShown(#rows == 0)
    end

    local function saveChecks()
        UpcomingDates:SaveSettings({
            showBirthdays = showBirthdays:GetChecked(),
            showAnniversaries = showAnniversaries:GetChecked(),
            includeEstimatedAnniversaries = includeEstimated:GetChecked(),
        })
        page:Refresh()
    end
    showBirthdays:SetScript("OnClick", saveChecks)
    showAnniversaries:SetScript("OnClick", saveChecks)
    includeEstimated:SetScript("OnClick", saveChecks)
    for _, button in ipairs(windowButtons) do
        button:SetScript("OnClick", function(self)
            UpcomingDates:SaveSettings({ reminderWindowDays = self.days })
            page:Refresh()
        end)
    end

    page.OnSelected = page.Refresh
    paintSettings()
    empty:Show()
    return page
end
