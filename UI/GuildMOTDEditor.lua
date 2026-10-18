-- Guild text editing begins from Blizzard's own controls to preserve protected writes.
local _, GP = ...
local Editor = {}
GP.UI.GuildMOTDEditor = Editor
local function read(fn, kind, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and not GP:IsSecretValue(value) and type(value) == kind then return value end
end
function Editor:CanEdit(kind)
    kind = kind or "motd"
    if kind ~= "motd" and kind ~= "info" then return false end
    local permission = CanEditMOTD
    if kind == "info" then permission = CanEditGuildInfo end
    return GP.UI.GuildInfoPage:IsSafe() and GP.UI.GuildRecruitment:IsOfficer()
        and read(permission, "boolean") == true
end
function Editor:Open(kind)
    kind = kind or "motd"
    if not self:CanEdit(kind) then return false end
    local ok = pcall(function()
        if not CommunitiesFrame then
            if not C_AddOns or not C_AddOns.LoadAddOn then error("Communities unavailable") end
            C_AddOns.LoadAddOn("Blizzard_Communities")
        end
        if not CommunitiesFrame then error("Communities unavailable") end
        -- Native edit mode and text must originate from Blizzard's own click.
        -- Do not initialize the text dialog, select a club, or change display mode.
        if not CommunitiesFrame:IsShown() then ShowUIPanel(CommunitiesFrame) end
        if not CommunitiesFrame:IsShown() then error("Communities did not open") end
    end)
    if not ok then
        GP:Print(GP.L["Could not open Guild & Communities. Open it using WoW's Guild & Communities keybinding."])
        return false
    end
    GP.UI.MainWindow:Hide()
    GP:Print(GP.L[kind == "info"
        and "In Guild & Communities, select your guild, open Info, then click Guild Information to edit it. Save with Blizzard's Accept button."
        or "In Guild & Communities, select your guild, open Info, then click Message of the Day to edit it. Save with Blizzard's Accept button."])
    return true
end
