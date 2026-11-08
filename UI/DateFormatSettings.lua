local _, GP = ...
local Theme = GP.UI.Theme
function GP.UI.BuildDateFormatSettings(parent, settingsFrame)
    local label = parent:CreateFontString(nil, "ARTWORK")
    label:SetFontObject(Theme.font.body)
    label:SetPoint("BOTTOMLEFT", 14, 42)
    label:SetText(GP.L["Date display:"])
    local button = Theme:CreateButton(parent, "", 180, 26)
    button:SetWidth(180)
    button:SetPoint("LEFT", label, "RIGHT", 10, 0)
    local panel = Theme:CreatePanel(parent, "panelRaised", "accent")
    panel:SetSize(180, 86)
    panel:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, 2)
    panel:SetFrameLevel(parent:GetFrameLevel() + 30)
    panel:EnableMouse(true)
    panel:Hide()
    local function settings()
        GP.db.profile.ui = GP.db.profile.ui or {}
        return GP.db.profile.ui
    end
    local function refresh()
        local value = settings().dateFormat
        button.text:SetText((value == "DD-MM-YYYY" or value == "MM-DD-YYYY")
            and (value .. "  v") or (GP.L["Default (YYYY-MM-DD)"] .. "  v"))
    end
    for i, value in ipairs({"default", "DD-MM-YYYY", "MM-DD-YYYY"}) do
        local row = Theme:CreateButton(panel, value == "default" and GP.L["Default (YYYY-MM-DD)"] or value, 172, 24)
        row:SetWidth(172)
        row:SetPoint("TOPLEFT", 4, -4 - (i-1)*26)
        row:SetScript("OnClick", function()
            settings().dateFormat = value
            panel:Hide()
            refresh()
            GP.UI.Settings:RefreshStatus(settingsFrame)
            GP:SendMessage("GuildParagon_RosterDisplaySettingsChanged")
        end)
    end
    button:SetScript("OnClick", function() panel:SetShown(not panel:IsShown()) end)
    button:SetScript("OnShow", refresh)
    button:SetScript("OnHide", function() panel:Hide() end)
    local hint = parent:CreateFontString(nil, "ARTWORK")
    hint:SetFontObject(Theme.font.small)
    hint:SetPoint("BOTTOMLEFT", 14, 12)
    hint:SetPoint("RIGHT", -14, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(GP.L["Display only. Joined uses this format; other date inputs and exports are unchanged."])
    refresh()
end
