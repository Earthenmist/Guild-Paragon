-- Native addon/Macro Tool binding labels and Settings navigation.
local _, GP = ...
_G.BINDING_NAME_GUILDPARAGON_TOGGLE = GP.L["Toggle Guild Paragon"]
function _G.GuildParagon_ToggleUI()
    GP.UI.MainWindow:Toggle()
end
_G["BINDING_NAME_MACRO Paragon_Tool"] = GP.L["Execute Macro Tool batch"]

local returnTab
if EventRegistry then
    EventRegistry:RegisterCallback("SettingsPanel.OnHide", function()
        if not returnTab then return end
        local target=returnTab
        returnTab = nil
        C_Timer.After(0, function()
            if InCombatLockdown() or (SettingsPanel and SettingsPanel:IsShown()) then return end
            GP.UI.MainWindow:SelectTabByID(target)
        end)
    end)
end

local function openKeybindings(tab)
    if InCombatLockdown() then
        GP:Print(GP.L["Cannot open keybindings while in combat."])
        return
    end
    if C_AddOns and C_AddOns.LoadAddOn then C_AddOns.LoadAddOn("Blizzard_Settings") end
    if not Settings or not Settings.OpenToCategory or not Settings.KEYBINDINGS_CATEGORY_ID then
        GP:Print(GP.L["WoW keybinding APIs are not available right now."])
        return
    end
    Settings.OpenToCategory(Settings.KEYBINDINGS_CATEGORY_ID)
    returnTab = tab
    -- Closing the tool disarms its macro before visiting another screen.
    GP.UI.MainWindow:Hide()
end

function GP.UI.OpenMacroKeybindings()
    openKeybindings("macro")
end

function GP.UI.OpenUIKeybindings()
    openKeybindings("settings")
end

function GP.UI.BuildUIKeybindingSettings(parent)
    local Theme=GP.UI.Theme
    local row=CreateFrame("Frame",nil,parent)
    row:SetPoint("BOTTOMLEFT",14,14)
    row:SetPoint("BOTTOMRIGHT",-14,14)
    row:SetHeight(52)
    local label=row:CreateFontString(nil,"ARTWORK")
    label:SetFontObject(Theme.font.body)
    label:SetPoint("TOPLEFT")
    label:SetText(GP.L["Toggle Guild Paragon"])
    local button=Theme:CreateButton(row,GP.L["Keybindings"])
    button:SetSize(110,26)
    button:SetPoint("BOTTOMLEFT")
    button:SetScript("OnClick",GP.UI.OpenUIKeybindings)
    local shortcut=row:CreateFontString(nil,"ARTWORK")
    shortcut:SetFontObject(Theme.font.body)
    shortcut:SetPoint("LEFT",button,"RIGHT",10,0)
    shortcut:SetPoint("RIGHT",row,"RIGHT")
    shortcut:SetJustifyH("LEFT")
    local function refresh()
        local first,second
        if GetBindingKey then first,second=GetBindingKey("GUILDPARAGON_TOGGLE") end
        shortcut:SetText(first and (second and (first.." / "..second) or first) or GP.L["None"])
    end
    row:RegisterEvent("UPDATE_BINDINGS")
    row:SetScript("OnEvent",refresh)
    row:SetScript("OnShow",refresh)
    refresh()
    return row
end

local bindingEvents = CreateFrame("Frame")
bindingEvents:RegisterEvent("UPDATE_BINDINGS")
bindingEvents:SetScript("OnEvent", function()
    GP:SendMessage("GuildParagon_MacroExecutorChanged")
end)
