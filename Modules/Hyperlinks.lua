-- Guild Paragon - safe local hyperlinks
local _, GP = ...

local Hyperlinks = GP:NewModule("Hyperlinks", "AceEvent-3.0")

local LINK_PREFIX = "gparagon"
local MEMBER_LINK = LINK_PREFIX .. ":member:"

local originalSetItemRef

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
    local c = classFile and C_ClassColor.GetClassColor(classFile)
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
    link = trim(link)
    local guid = link:match("^" .. MEMBER_LINK .. "(.+)$")
    if not guid then return false end

    local ok, err = self:OpenMember(guid)
    if not ok and err then GP:Print(err) end
    return true
end

function Hyperlinks:OnEnable()
    if type(SetItemRef) ~= "function" or originalSetItemRef then return end
    originalSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, chatFrame)
        local module = GP:GetModule("Hyperlinks", true)
        if module and module.HandleLink and module:HandleLink(link) then return end
        return originalSetItemRef(link, text, button, chatFrame)
    end
end
