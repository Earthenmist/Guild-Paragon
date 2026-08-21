-- Guild Paragon - Public read-only API
local _, GP = ...

local APIModule = GP:NewModule("API", "AceEvent-3.0")

local API_VERSION = 1
local API = _G.GuildParagonAPI or {}
_G.GuildParagonAPI = API

local callbacks = LibStub("CallbackHandler-1.0"):New(API, "RegisterCallback", "UnregisterCallback", "UnregisterAllCallbacks")

local function copyArray(values)
    local out = {}
    for i, value in ipairs(values or {}) do
        out[i] = value
    end
    return out
end

local function splitName(name)
    name = tostring(name or "")
    local short, realm = name:match("^([^-]+)%-(.+)$")
    return short or name, realm
end

local function getRosterModule()
    return GP:GetModule("Roster", true)
end

local function currentGuildKey()
    local Roster = getRosterModule()
    return Roster and (Roster.currentGuildKey or (Roster.GetGuildKey and Roster:GetGuildKey()))
end

local function getGuildData(guildKey)
    guildKey = guildKey or currentGuildKey()
    local data = guildKey and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[guildKey]
    return data, guildKey
end

local function guildNameFromKey(guildKey)
    if not guildKey then return nil end
    return guildKey:match("^(.*)%-%d+$") or guildKey
end

local function findPlayer(guildData, nameOrGUID, includeFormer)
    if not guildData or not nameOrGUID then return nil, nil, nil end
    nameOrGUID = tostring(nameOrGUID)
    if (guildData.roster or {})[nameOrGUID] then
        return nameOrGUID, guildData.roster[nameOrGUID], false
    end
    if includeFormer and (guildData.formerMembers or {})[nameOrGUID] then
        return nameOrGUID, guildData.formerMembers[nameOrGUID], true
    end

    local Roster = getRosterModule()
    if not Roster or not Roster.FindPlayerByName then return nil, nil, nil end
    local guid, player = Roster:FindPlayerByName(guildData, nameOrGUID, includeFormer)
    if not guid then return nil, nil, nil end
    return guid, player, not (guildData.roster or {})[guid]
end

local function memberSummary(guildKey, guildData, guid, player, former)
    if not guid or not player then return nil end

    local Roster = getRosterModule()
    local Alts = GP:GetModule("Alts", true)
    local Nicknames = GP:GetModule("Nicknames", true)
    local CustomNotes = GP:GetModule("CustomNotes", true)

    local shortName, realm = splitName(player.name)
    local mainGUID = Alts and Alts:GetMain(guildKey, guid) or nil
    local altGUIDs = Alts and Alts:GetAlts(guildKey, guid) or {}
    local birthdayDay, birthdayMonth
    if Roster and Roster.GetBirthday then
        birthdayDay, birthdayMonth = Roster:GetBirthday(player)
    end

    local canAccessOfficer = CustomNotes and CustomNotes.CanAccessOfficerNotes and CustomNotes:CanAccessOfficerNotes()
    local out = {
        guid = guid,
        name = player.name,
        shortName = shortName,
        realm = realm,
        class = player.class,
        rankName = player.rankName,
        rankIndex = player.rankIndex,
        level = player.level,
        online = player.online and true or false,
        onlineSince = player.onlineSince,
        lastOnline = player.lastOnline,
        lastSeen = player.lastSeen,
        firstSeen = player.firstSeen,
        former = former and true or false,
        leftDate = player.leftDate,
        note = player.note or "",
        nickname = Nicknames and Nicknames:Get(guildKey, guid) or "",
        customNote = CustomNotes and CustomNotes:Get(guildKey, guid) or "",
        mainGUID = mainGUID,
        altGUIDs = copyArray(altGUIDs),
        isMain = Alts and Alts:IsMain(guildKey, guid) or false,
        isMarkedMain = Alts and Alts:IsMarkedMain(guildKey, guid) or false,
    }

    if birthdayDay and birthdayMonth then
        out.birthday = { day = birthdayDay, month = birthdayMonth }
    end
    if player.joinDate then
        out.joinDate = player.joinDate
        out.joinDateSource = player.joinDateSource
    end
    if canAccessOfficer then
        out.officerNote = player.officerNote or ""
        out.customOfficerNote = CustomNotes:GetOfficer(guildKey, guid)
    end

    return out
end

local function sortedMembers(guildData, includeFormer)
    local out = {}
    for guid, player in pairs(guildData and guildData.roster or {}) do
        out[#out + 1] = { guid = guid, player = player, former = false }
    end
    if includeFormer then
        for guid, player in pairs(guildData and guildData.formerMembers or {}) do
            out[#out + 1] = { guid = guid, player = player, former = true }
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.player.name or "") < tostring(b.player.name or "")
    end)
    return out
end

function API.GetAPIVersion()
    return API_VERSION
end

function API.GetAddonVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata("GuildParagon", "Version")
    end
    return GetAddOnMetadata and GetAddOnMetadata("GuildParagon", "Version") or "unknown"
end

function API.IsReady()
    local guildData = getGuildData()
    return guildData and guildData.roster and next(guildData.roster) ~= nil or false
end

function API.GetCurrentGuild()
    local guildData, guildKey = getGuildData()
    if not guildData then return nil end
    local Roster = getRosterModule()
    local active, former = 0, 0
    if Roster and Roster.CountMembers then
        active, former = Roster:CountMembers(guildData)
    end
    return {
        key = guildKey,
        name = guildNameFromKey(guildKey),
        active = active,
        former = former,
        lastScan = guildData.lastScan,
    }
end

function API.GetRoster(includeFormer)
    local guildData, guildKey = getGuildData()
    if not guildData then return nil end
    local out = {}
    for _, record in ipairs(sortedMembers(guildData, includeFormer)) do
        out[#out + 1] = memberSummary(guildKey, guildData, record.guid, record.player, record.former)
    end
    return out
end

function API.GetMember(nameOrGUID, includeFormer)
    local guildData, guildKey = getGuildData()
    local guid, player, former = findPlayer(guildData, nameOrGUID, includeFormer)
    return memberSummary(guildKey, guildData, guid, player, former)
end

function API.IsGuildMember(nameOrGUID)
    local guildData = getGuildData()
    local guid = findPlayer(guildData, nameOrGUID, false)
    return guid ~= nil
end

function API.GetMain(nameOrGUID)
    local guildData, guildKey = getGuildData()
    local guid = findPlayer(guildData, nameOrGUID, true)
    if not guid then return nil end
    local Alts = GP:GetModule("Alts", true)
    local mainGUID = Alts and Alts:GetMain(guildKey, guid)
    if not mainGUID then return nil end
    local player = (guildData.roster or {})[mainGUID] or (guildData.formerMembers or {})[mainGUID]
    return memberSummary(guildKey, guildData, mainGUID, player, not (guildData.roster or {})[mainGUID])
end

function API.GetAlts(nameOrGUID)
    local guildData, guildKey = getGuildData()
    local guid = findPlayer(guildData, nameOrGUID, true)
    if not guid then return nil end
    local Alts = GP:GetModule("Alts", true)
    local out = {}
    for _, altGUID in ipairs(Alts and Alts:GetAlts(guildKey, guid) or {}) do
        local player = (guildData.roster or {})[altGUID] or (guildData.formerMembers or {})[altGUID]
        out[#out + 1] = memberSummary(guildKey, guildData, altGUID, player, not (guildData.roster or {})[altGUID])
    end
    return out
end

function API.GetNickname(nameOrGUID)
    local member = API.GetMember(nameOrGUID, true)
    return member and member.nickname or nil
end

function API.GetBirthday(nameOrGUID)
    local member = API.GetMember(nameOrGUID, true)
    return member and member.birthday or nil
end

function API.GetJoinDate(nameOrGUID)
    local member = API.GetMember(nameOrGUID, true)
    return member and member.joinDate or nil
end

function API.GetCustomNote(nameOrGUID)
    local member = API.GetMember(nameOrGUID, true)
    return member and member.customNote or nil
end

function API.CanAccessOfficerData()
    local CustomNotes = GP:GetModule("CustomNotes", true)
    return CustomNotes and CustomNotes.CanAccessOfficerNotes and CustomNotes:CanAccessOfficerNotes() or false
end

function API.GetOfficerNote(nameOrGUID)
    if not API.CanAccessOfficerData() then return nil end
    local member = API.GetMember(nameOrGUID, true)
    return member and member.officerNote or nil
end

function API.GetCustomOfficerNote(nameOrGUID)
    if not API.CanAccessOfficerData() then return nil end
    local member = API.GetMember(nameOrGUID, true)
    return member and member.customOfficerNote or nil
end

function API.GetRecentHistory(nameOrGUID, limit)
    local guildData, guildKey = getGuildData()
    local guid = findPlayer(guildData, nameOrGUID, true)
    if not guid then return nil end
    limit = math.max(1, math.min(tonumber(limit) or 10, 50))

    local EventLog = GP:GetModule("EventLog", true)
    local out = {}
    for i = #(guildData.log or {}), 1, -1 do
        local entry = guildData.log[i]
        if entry and entry.guid == guid and EventLog and EventLog:CanDisplayEntry(entry) and not EventLog:IsRemoved(guildKey, entry) then
            out[#out + 1] = {
                id = entry.id,
                ts = entry.ts,
                type = entry.type,
                guid = entry.guid,
                name = entry.name,
                text = EventLog:Render(entry, guildKey, false, false),
            }
            if #out >= limit then break end
        end
    end
    return out
end

function API.GetStats()
    local guildData, guildKey = getGuildData()
    if not guildData then return nil end
    local Roster = getRosterModule()
    local active, former = 0, 0
    if Roster and Roster.CountMembers then
        active, former = Roster:CountMembers(guildData)
    end
    local online = 0
    for _, player in pairs(guildData.roster or {}) do
        if player.online then online = online + 1 end
    end
    return {
        guildKey = guildKey,
        guildName = guildNameFromKey(guildKey),
        active = active,
        former = former,
        online = online,
        logEntries = #(guildData.log or {}),
        lastScan = guildData.lastScan,
    }
end

local EVENT_MAP = {
    GuildParagon_RosterScanned = "GuildParagonAPI_RosterUpdated",
    GuildParagon_AltsChanged = "GuildParagonAPI_MemberUpdated",
    GuildParagon_NicknamesChanged = "GuildParagonAPI_MemberUpdated",
    GuildParagon_CustomNotesChanged = "GuildParagonAPI_MemberUpdated",
    GuildParagon_JoinDateChanged = "GuildParagonAPI_MemberUpdated",
    GuildParagon_BirthdayChanged = "GuildParagonAPI_MemberUpdated",
    GuildParagon_LogEntryAdded = "GuildParagonAPI_LogUpdated",
}

function APIModule:Relay(event, ...)
    callbacks:Fire(EVENT_MAP[event] or event, ...)
end

function APIModule:OnEnable()
    for event in pairs(EVENT_MAP) do
        self:RegisterMessage(event, "Relay")
    end
    callbacks:Fire("GuildParagonAPI_Ready", API_VERSION)
end
