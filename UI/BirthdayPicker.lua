local _, GP = ...
local Theme = GP.UI.Theme
local Picker = {}
GP.UI.BirthdayPicker = Picker
local months = {"January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"}
local days = {31,29,31,30,31,30,31,31,30,31,30,31}
function Picker:DaysInMonth(month) return days[month] end
function Picker:Format(day, month)
    if not day or not month then return "" end
    return tostring(day) .. " " .. (months[month] and GP.L[months[month]]:sub(1,3) or tostring(month))
end
function Picker:New(parent)
    local button = Theme:CreateButton(parent, "")
    button:SetWidth(90)
    local panel = Theme:CreatePanel(parent, "panelRaised", "accent")
    panel:SetSize(238, 212)
    panel:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, 4)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:Hide()
    button.panel = panel
    local title = panel:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.body)
    title:SetPoint("TOP", 0, -12)
    title:SetText(GP.L["Choose birthday"])
    local monthText = panel:CreateFontString(nil, "ARTWORK")
    monthText:SetFontObject(Theme.font.body)
    monthText:SetPoint("TOP", 0, -45)
    local previous = Theme:CreateButton(panel, "<")
    previous:SetWidth(28);previous:SetPoint("TOPLEFT", 10, -36)
    local nextMonth = Theme:CreateButton(panel, ">")
    nextMonth:SetWidth(28);nextMonth:SetPoint("TOPRIGHT", -10, -36)
    local cells = {}
    local function paint()
        monthText:SetText(GP.L[months[button.viewMonth]])
        for day, cell in ipairs(cells) do
            cell:SetShown(day <= days[button.viewMonth])
            local selected = day == button.day and button.viewMonth == button.month
            cell:SetBackdropColor(unpack(selected and Theme.color.accentDim or Theme.color.panelRaised))
        end
    end
    function button:SetDate(day, month)
        self.day, self.month = day, month
        self.text:SetText(day and month and
            (Picker:Format(day, month) .. "  v") or (GP.L["Select"] .. "  v"))
        panel:Hide()
    end
    function button:GetDate() return self.day, self.month end
    function button:SetEditable(enabled)
        self:SetEnabled(enabled)
        self:SetAlpha(enabled and 1 or 0.6)
        if not enabled then panel:Hide() end
    end
    for day=1,31 do
        local cell = Theme:CreateButton(panel, tostring(day))
        cell:SetSize(28, 24)
        cell:SetPoint("TOPLEFT", 10 + ((day-1)%7)*31, -72 - math.floor((day-1)/7)*26)
        cell:SetScript("OnClick", function()
            if button:IsEnabled() then button:SetDate(day, button.viewMonth) end
        end)
        cells[day] = cell
    end
    previous:SetScript("OnClick", function() button.viewMonth = (button.viewMonth + 10)%12 + 1;paint() end)
    nextMonth:SetScript("OnClick", function() button.viewMonth = button.viewMonth%12 + 1;paint() end)
    button:SetScript("OnClick", function()
        if panel:IsShown() then panel:Hide();return end
        button.viewMonth = days[button.month] and button.month or 1
        paint();panel:Show()
    end)
    button:SetScript("OnHide", function() panel:Hide() end)
    button:SetDate(nil,nil)
    return button
end
