-- Guild Paragon - safe local hyperlinks
local _, GP = ...

local Hyperlinks = GP:NewModule("Hyperlinks", "AceEvent-3.0")

-- Blizzard's own "addon" link type: SetItemRef handles it and fires the
-- "SetItemRef" EventRegistry event, so the global never needs replacing.
-- Replacing SetItemRef taints every chat link click and blocks protected
-- link actions such as joining a community from an invite link.
local LINK_PREFIX = "addon:GuildParagon"
local MEMBER_LINK = LINK_PREFIX .. ":member:"

local clickHandlerRegistered

local function trim(value)
    return strtrim(tostring(value or ""))
end

local function blockedForProtectedContent()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    if IsInInstance then
        local ok, inInstance, instanceType = pcall(IsInInstance)
        if ok and inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario" or instanceType == "pvp" or instanceType == "arena") then
            return true
        end
    end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
        if ok and active then return true end
    end
    return false
end

local function colorHexForClass(classFile)
    local c = classFile and GP:GetClassColor(classFile)
    if not c then return nil end
    return string.format("%02x%02x%02x", math.floor((c.r or 1) * 255), math.floor((c.g or 1) * 255), math.floor((c.b or 1) * 255))
end

local function getGuildData(guildKey)
    if not guildKey then
        local Roster = GP:GetModule("Roster", true)
        guildKey = Roster and (Roster.currentGuildKey or (Roster.GetGuildKey and Roster:GetGuildKey()))
    end
    return guildKey and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[guildKey], guildKey
end

local function findMember(guildKey, guid, name)
    local guildData = getGuildData(guildKey)
    if not guildData then return nil end
    if guid and guid ~= "" then
        return (guildData.roster or {})[guid] or (guildData.formerMembers or {})[guid]
    end
    if name and name ~= "" then
        local Roster = GP:GetModule("Roster", true)
        if Roster and Roster.FindPlayerByName then
            local _, player = Roster:FindPlayerByName(guildData, name, true)
            return player
        end
    end
    return nil
end

function Hyperlinks:MemberLink(guildKey, guid, name, colored)
    name = trim(name)
    if name == "" then name = "?" end
    guid = trim(guid)
    if guid == "" then return name end

    local text = "|H" .. MEMBER_LINK .. guid .. "|h" .. name .. "|h"
    if colored then
        local player = findMember(guildKey, guid, name)
        local hex = player and colorHexForClass(player.class)
        if hex then text = "|cff" .. hex .. text .. "|r" end
    end
    return text
end

function Hyperlinks:OpenMember(guid, name)
    guid = trim(guid)
    name = trim(name)
    if guid == "" and name == "" then return false, GP.L["Guild Paragon member link could not be resolved."] end
    if blockedForProtectedContent() then
        return false, GP.L["Guild Paragon member links are paused while combat or protected content is active."]
    end

    local guildData = getGuildData()
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end

    local RosterTab = GP.UI and GP.UI.RosterTab
    if not RosterTab or not RosterTab.SelectPlayerByGUID then
        return false, GP.L["Guild Paragon roster view is not ready yet."]
    end

    if GP.UI.MainWindow and GP.UI.MainWindow.SelectTabByID then
        GP.UI.MainWindow:SelectTabByID("roster")
    end

    local ok = RosterTab:SelectPlayerByGUID(guid ~= "" and guid or nil, name ~= "" and name or nil)
    if not ok then return false, GP.L["Guild Paragon member link could not be resolved."] end
    return true
end

function Hyperlinks:HandleLink(link)
    if GP:IsSecretValue(link) or type(link) ~= "string" then return false end
    link = trim(link)
    local guid = link:match("^" .. MEMBER_LINK .. "(.+)$")
    if not guid then return false end

    local ok, err = self:OpenMember(guid)
    if not ok and err then GP:Print(err) end
    return true
end

function Hyperlinks:OnEnable()
    if clickHandlerRegistered then return end
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("SetItemRef", function(_, link)
            Hyperlinks:HandleLink(link)
        end, self)
        clickHandlerRegistered = true
    elseif type(SetItemRef) == "function" and hooksecurefunc then
        hooksecurefunc("SetItemRef", function(link)
            Hyperlinks:HandleLink(link)
        end)
        clickHandlerRegistered = true
    end
end
