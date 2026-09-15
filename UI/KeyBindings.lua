-- Native Macro Tool binding label and Settings navigation.
local _, GP = ...
_G["BINDING_NAME_MACRO Paragon_Tool"] = GP.L["Execute Macro Tool batch"]

local returnToMacroTool = false
if EventRegistry then
    EventRegistry:RegisterCallback("SettingsPanel.OnHide", function()
        if not returnToMacroTool then return end
        returnToMacroTool = false
        C_Timer.After(0, function()
            if InCombatLockdown() or (SettingsPanel and SettingsPanel:IsShown()) then return end
            GP.UI.MainWindow:SelectTabByID("macro")
        end)
    end)
end

function GP.UI.OpenMacroKeybindings()
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
    returnToMacroTool = true
    -- Closing the tool disarms its macro before visiting another screen.
    GP.UI.MainWindow:Hide()
end

local bindingEvents = CreateFrame("Frame")
bindingEvents:RegisterEvent("UPDATE_BINDINGS")
bindingEvents:SetScript("OnEvent", function()
    GP:SendMessage("GuildParagon_MacroExecutorChanged")
end)
