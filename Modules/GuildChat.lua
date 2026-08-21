-- Guild Paragon — guild chat name hints
--
-- Adds main/nickname context into chat by filtering the displayed message
-- body. Guild Paragon keeps this display-only: no note-writing side effects,
-- no sender-field rewriting, and no hooks that replace Blizzard's send path.
local _, GP = ...

local GuildChat = GP:NewModule("GuildChat")

local EVENTS = {
    CHAT_MSG_GUILD = "guild",
    CHAT_MSG_OFFICER = "officer",
    CHAT_MSG_PARTY = "party",
    CHAT_MSG_PARTY_LEADER = "party",
    CHAT_MSG_RAID = "raid",
    CHAT_MSG_RAID_LEADER = "raid",
    CHAT_MSG_GUILD_ACHIEVEMENT = "achievements",
    CHAT_MSG_ACHIEVEMENT = "achievements",
}

local function settings()
    GP.db.profile.guildChat = GP.db.profile.guildChat or {}
    local s = GP.db.profile.guildChat
    if s.guild == nil then s.guild = true end
    if s.officer == nil then s.officer = true end
    if s.party == nil then s.party = false end
    if s.raid == nil then s.raid = false end
    if s.achievements == nil then s.achievements = false end
    if s.nicknames == nil then s.nicknames = true end
    if s.preferNickname == nil then s.preferNickname = true end
    if s.appendOwnNickname == nil then s.appendOwnNickname = false end
    if s.showTags == nil then s.showTags = true end
    if s.showMainName == nil then s.showMainName = true end
    if s.fallbackToMainName == nil then s.fallbackToMainName = true end
    if s.classColor == nil then s.classColor = true end
    return s
end

local function getGuildData()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey and GP.db.global.guilds[guildKey], guildKey
end

local function shortName(name)
    return GP:GetModule("Roster"):ShortName(name) or name
end

local function accessibleString(value)
    if GP:IsSecretValue(value) and not GP:CanAccessValue(value) then
        return nil
    end
    return GP:SafeString(value, nil)
end

local function findPlayer(guildData, sender, senderGUID)
    senderGUID = accessibleString(senderGUID)
    if guildData and senderGUID and guildData.roster and guildData.roster[senderGUID] then
        return senderGUID, guildData.roster[senderGUID]
    end

    sender = accessibleString(sender) or ""
    if sender == "" or not guildData then return nil end

    return GP:GetModule("Roster"):FindPlayerByName(guildData, sender, false)
end

local function isOwnSender(sender, senderGUID)
    senderGUID = accessibleString(senderGUID)
    local ownGUID = UnitGUID and accessibleString(UnitGUID("player"))
    if senderGUID and ownGUID and senderGUID == ownGUID then
        return true
    end

    sender = accessibleString(sender)
    if not sender or sender == "" or not UnitFullName then return false end

    local name, realm = UnitFullName("player")
    if not name or name == "" then return false end

    local Roster = GP:GetModule("Roster")
    local normalizedSender = Roster:NormalizePlayerName(sender)
    local normalizedName = Roster:NormalizePlayerName(name)
    if normalizedSender == normalizedName then return true end

    if realm and realm ~= "" then
        return normalizedSender == Roster:NormalizePlayerName(name .. "-" .. realm)
    end
    return false
end

local function classColorPrefix(classFile, enabled)
    if not enabled then return "" end
    local color = classFile and C_ClassColor and C_ClassColor.GetClassColor(classFile)
    color = color or (classFile and CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[classFile])
    color = color or (classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
    if color and color.GenerateHexColor then
        local hex = color:GenerateHexColor()
        return "|c" .. (#hex == 6 and ("ff" .. hex) or hex)
    end
    if color then
        return string.format("|cff%02x%02x%02x", math.floor(color.r * 255), math.floor(color.g * 255), math.floor(color.b * 255))
    end
    return ""
end

local function formatHint(text, tag, classFile, useClassColor)
    local prefix = classColorPrefix(classFile, useClassColor)
    local hint = tag and ("(" .. tag .. ") " .. text) or ("(" .. text .. ")")
    if prefix ~= "" then
        return prefix .. hint .. "|r"
    end
    return hint
end

local function nicknameFor(guildKey, guid, mainGUID)
    local s = settings()
    local Nicknames = GP:GetModule("Nicknames")
    local nickname = ""
    if s.nicknames then
        nickname = Nicknames:Get(guildKey, mainGUID or guid)
        if nickname == "" and mainGUID then
            nickname = Nicknames:Get(guildKey, guid)
        end
    end
    return nickname
end

local function displayFor(guildData, guildKey, guid, player)
    local s = settings()
    local Alts = GP:GetModule("Alts")
    local mainGUID = Alts:GetMain(guildKey, guid)
    local mainPlayer = mainGUID and (guildData.roster[mainGUID] or guildData.formerMembers[mainGUID])
    local displaySourcePlayer = mainPlayer or player
    local nickname = nicknameFor(guildKey, guid, mainGUID)

    local display
    if s.preferNickname and nickname ~= "" then
        display = nickname
    elseif mainGUID and s.showMainName then
        display = displaySourcePlayer.name
    elseif nickname ~= "" then
        display = nickname
    end

    if not display and s.fallbackToMainName and s.showMainName and mainGUID then
        display = displaySourcePlayer.name
    end
    if not display or display == "" then return nil end

    display = shortName(display) or display
    local tag = s.showTags and (mainGUID and "A" or "M") or nil
    return formatHint(display, tag, displaySourcePlayer.class, s.classColor)
end

local function appendOwnNickname(msg, guildKey, guid, displayHint)
    local s = settings()
    if not s.appendOwnNickname then return msg end

    local Alts = GP:GetModule("Alts")
    local nickname = nicknameFor(guildKey, guid, Alts:GetMain(guildKey, guid))
    if not nickname or nickname == "" then return msg end
    if displayHint and displayHint:find(nickname, 1, true) then return msg end

    local suffix = " [" .. nickname .. "]"
    if msg:find(suffix, 1, true) then return msg end
    return msg .. suffix
end

function GuildChat:BuildHintForName(name)
    local guildData, guildKey = getGuildData()
    local guid, player = findPlayer(guildData, name)
    if not guid then return nil end
    return displayFor(guildData, guildKey, guid, player)
end

local function filter(_, event, msg, sender, ...)
    local settingsKey = EVENTS[event]
    if not settingsKey or not IsInGuild() then return false, msg, sender, ... end
    local s = settings()
    if not s[settingsKey] then return false, msg, sender, ... end
    msg = accessibleString(msg)
    sender = accessibleString(sender)
    if not msg or not sender then return false, msg, sender, ... end

    local guildData, guildKey = getGuildData()
    local senderGUID = select(10, ...)
    local guid, player = findPlayer(guildData, sender, senderGUID)
    if not guid then return false, msg, sender, ... end

    local display = displayFor(guildData, guildKey, guid, player)
    if isOwnSender(sender, senderGUID) then
        msg = appendOwnNickname(msg, guildKey, guid, display)
    end
    if not display or msg:find(display, 1, true) then return false, msg, sender, ... end

    return false, display .. ": " .. msg, sender, ...
end

function GuildChat:OnEnable()
    for event in pairs(EVENTS) do
        ChatFrame_AddMessageEventFilter(event, filter)
    end
end

function GuildChat:GetSettings()
    return settings()
end
