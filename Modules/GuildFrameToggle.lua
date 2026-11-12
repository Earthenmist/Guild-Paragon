-- Optional guild-window entry point replacement, applied at login/reload.
local _, GP = ...
local GuildFrameToggle = GP:NewModule("GuildFrameToggle")
local originalToggle, replacementToggle
local active = false

function GuildFrameToggle:OnEnable()
    if active or not GP.db.profile.replaceGuildFrame then return end
    if type(_G.ToggleGuildFrame) ~= "function" then return end
    originalToggle = _G.ToggleGuildFrame
    local previous = originalToggle
    replacementToggle = function(...)
        if not active then return previous(...) end
        if InCombatLockdown() then
            GP:Print(GP.L["Cannot open Guild Paragon through the guild shortcut while in combat."])
            return
        end
        GP.UI.MainWindow:Toggle()
    end
    active = true
    _G.ToggleGuildFrame = replacementToggle
end

function GuildFrameToggle:OnDisable()
    active = false
    -- Preserve a later replacement installed by another addon.
    if replacementToggle and _G.ToggleGuildFrame == replacementToggle then
        _G.ToggleGuildFrame = originalToggle
    end
end
