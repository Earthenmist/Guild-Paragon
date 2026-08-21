-- Guild roster scan and diff engine.
local _, GP = ...

local Roster = GP:NewModule("Roster", "AceEvent-3.0")

-- Guards against re-entrant scans triggered by rapid-fire GUILD_ROSTER_UPDATE
-- events (the client fires it multiple times in a row during login).
local scanInProgress = false
local scanQueued = false
-- Automatic scan requests that arrive mid-batch get one follow-up scan.
local rescanRequestedDuringScan = false
local scanStats = {
    requested = 0,
    queued = 0,
    coalesced = 0,
    skippedReentrant = 0,
    deferredProtected = 0,
    completed = 0,
    lastMs = 0,
    avgMs = 0,
    maxMs = 0,
    lastMembers = 0,
    -- Time-only scan counters; no memory sampling on the scan path.
    lastAt = 0,
    maxAt = 0,
}
local eventLogQueryPending = false
local eventLogQueryQueued = false
local eventLogLastQuery = 0
local INACTIVE_RETURN_HOURS = 14 * 24
-- Members processed per frame before Scan() yields.
local ROSTER_SCAN_BATCH_SIZE = 75
-- Roster scans keep timing counters only. Addon memory sampling stays off
-- this high-frequency path.

local function profileNow()
    return debugprofilestop and debugprofilestop() or 0
end

local function scanSettings()
    GP.db.profile.scan = GP.db.profile.scan or {}
    local s = GP.db.profile.scan
    if s.login == nil then s.login = true end
    if s.rosterUpdates == nil then s.rosterUpdates = true end
    return s
end

local function scanBlocked()
    if InCombatLockdown and InCombatLockdown() then
        return true, GP.L["Roster scan paused while combat or protected content is active."]
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        return true, GP.L["Roster scan paused while combat or protected content is active."]
    end
    return false
end

local function BeginFullRosterScan()
    if not (GetGuildRosterShowOffline and SetGuildRosterShowOffline) then return nil end
    local ok, alreadyOn = pcall(GetGuildRosterShowOffline)
    if not ok or alreadyOn then return nil end
    SetGuildRosterShowOffline(true)
    return false
end

local function EndFullRosterScan(restore)
    if restore ~= nil and SetGuildRosterShowOffline then
        pcall(SetGuildRosterShowOffline, restore)
    end
end

local function countTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function countStoredNotes(roster, field)
    local n = 0
    for _, player in pairs(roster or {}) do
        local value = player[field]
        if type(value) == "string" and value ~= "" then
            n = n + 1
        end
    end
    return n
end

local function canViewOfficerNotes()
    if C_GuildInfo and C_GuildInfo.CanViewOfficerNote then
        return GP:SafeBool(GP:SafeCall(C_GuildInfo.CanViewOfficerNote, false), false)
    end
    if CanViewOfficerNote then
        return GP:SafeBool(GP:SafeCall(CanViewOfficerNote, false), false)
    end
    if CanEditOfficerNote then
        return GP:SafeBool(GP:SafeCall(CanEditOfficerNote, false), false)
    end
    return false
end

local function chatMessagingLockdownActive()
    if not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) then return false end
    return GP:SafeBool(GP:SafeCall(C_ChatInfo.InChatMessagingLockdown, false), false)
end

local function totalOfflineHours(years, months, days, hours)
    years = GP:SafeNumber(years, 0)
    months = GP:SafeNumber(months, 0)
    days = GP:SafeNumber(days, 0)
    hours = GP:SafeNumber(hours, 0)
    return years * 8760 + months * 730 + days * 24 + hours
end

local function formatOfflineDuration(hours)
    hours = math.max(0, GP:SafeNumber(hours, 0))
    local days = math.floor(hours / 24)
    local remainder = hours % 24
    if days > 0 and remainder > 0 then
        return string.format("%d day%s, %d hr%s", days, days == 1 and "" or "s", remainder, remainder == 1 and "" or "s")
    elseif days > 0 then
        return string.format("%d day%s", days, days == 1 and "" or "s")
    end
    return string.format("%d hr%s", remainder, remainder == 1 and "" or "s")
end

local function currentLevelCap()
    if GetMaxPlayerLevel then
        local ok, value = pcall(GetMaxPlayerLevel)
        value = ok and GP:SafeNumber(value, nil) or nil
        if value and value > 0 then return value end
    end
    if GetMaxLevelForPlayerExpansion then
        local ok, value = pcall(GetMaxLevelForPlayerExpansion)
        value = ok and GP:SafeNumber(value, nil) or nil
        if value and value > 0 then return value end
    end
    return 0
end

local function getPlayer(guildData, guid)
    if not guildData or not guid then return nil end
    return (guildData.roster or {})[guid] or (guildData.formerMembers or {})[guid]
end

local function parseJoinDateText(text)
    text = strtrim(tostring(text or ""))
    local year, month, day = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if year then
        year, month, day = tonumber(year), tonumber(month), tonumber(day)
    else
        day, month, year = text:match("^(%d%d?)%-(%d%d?)%-(%d%d)$")
        if not year then return nil end
        day, month, year = tonumber(day), tonumber(month), 2000 + tonumber(year)
    end
    if not year or not month or not day or month < 1 or month > 12 or day < 1 or day > 31 then return nil end

    local ts = time({ year = year, month = month, day = day, hour = 12 })
    if date("%Y-%m-%d", ts) ~= string.format("%04d-%02d-%02d", year, month, day) then return nil end
    return ts
end

local function customJoinDateText(note)
    note = note or ""
    return note:match("[Rr]ejoined:%s*([%d%-]+)") or note:match("[Jj]oined:%s*([%d%-]+)")
end

local function dateText(ts)
    return type(ts) == "number" and date("%Y-%m-%d", ts) or nil
end

local function sanitizeName(name)
    if not name or not name:find("%-") then return name end
    local parts = {}
    for part in name:gmatch("[^%-]+") do
        parts[#parts + 1] = part
    end
    if #parts < 3 then return name end
    local suffix = parts[#parts]
    for i = 2, #parts do
        if parts[i] ~= suffix then return name end
    end
    return parts[1] .. "-" .. suffix
end

local function shortName(name)
    return type(name) == "string" and name:match("^([^-]+)") or nil
end

local function normalizeName(name)
    name = sanitizeName(GP:SafeOptionalString(name))
    return name and name:lower() or ""
end

local function fetchLiveMythicScores()
    local scores = { byGUID = {}, byName = {}, available = false }
    if not (C_Club and C_Club.GetGuildClubId and C_Club.GetClubMembers and C_Club.GetMemberInfo) then
        return scores
    end

    local clubId = GP:SafeCall(C_Club.GetGuildClubId, nil)
    if not clubId then return scores end

    local ok = pcall(function()
        local members = C_Club.GetClubMembers(clubId)
        if type(members) ~= "table" then return end

        for _, memberId in ipairs(members) do
            local info = C_Club.GetMemberInfo(clubId, memberId)
            if type(info) == "table" then
                local score = GP:SafeNumber(info.overallDungeonScore, 0)
                local guid = GP:SafeOptionalString(info.guid)
                local name = sanitizeName(GP:SafeOptionalString(info.name))

                if guid and guid ~= "" then
                    scores.byGUID[guid] = score
                    scores.available = true
                end
                if name and name ~= "" then
                    scores.byName[normalizeName(name)] = score
                    scores.available = true
                end
            end
        end
    end)

    if not ok then
        scores.byGUID = {}
        scores.byName = {}
        scores.available = false
    end

    return scores
end

local function liveMythicScoreFor(scores, guid, name)
    if not scores or not scores.available then return nil end
    if guid and scores.byGUID[guid] ~= nil then return scores.byGUID[guid] end
    local key = normalizeName(name)
    return key ~= "" and scores.byName[key] or nil
end

function Roster:SanitizeName(name)
    return sanitizeName(name)
end

function Roster:ShortName(name)
    return shortName(name)
end

function Roster:NormalizePlayerName(name)
    return normalizeName(name)
end

function Roster:FindPlayerByName(guildData, name, includeFormer)
    if not guildData then return nil, nil, "missing" end
    name = sanitizeName(strtrim(tostring(name or "")))
    if name == "" then return nil, nil, "missing" end

    local needle = normalizeName(name)
    local hasRealm = name:find("%-") ~= nil
    local buckets = includeFormer and { guildData.roster or {}, guildData.formerMembers or {} } or { guildData.roster or {} }

    for _, bucket in ipairs(buckets) do
        for guid, player in pairs(bucket) do
            if normalizeName(player.name) == needle then
                return guid, player, "exact"
            end
        end
    end

    if hasRealm then return nil, nil, "missing" end

    local matchGUID, matchPlayer, matches = nil, nil, 0
    for _, bucket in ipairs(buckets) do
        for guid, player in pairs(bucket) do
            if normalizeName(shortName(player.name)) == needle then
                matchGUID, matchPlayer = guid, player
                matches = matches + 1
                if matches > 1 then return nil, nil, "ambiguous" end
            end
        end
    end

    if matches == 1 then return matchGUID, matchPlayer, "short" end
    return nil, nil, "missing"
end

local chatNameIndexCache = {}

local function chatNameIndex(guildKey, guildData)
    local cached = chatNameIndexCache[guildKey]
    if cached and cached.builtAt == guildData.lastScan then
        return cached.index
    end

    local index = {}
    for guid, player in pairs(guildData.roster or {}) do
        local key = normalizeName(player.name)
        if key ~= "" then
            if index[key] == nil then
                index[key] = guid
            elseif index[key] ~= false then
                -- Ambiguous names are safer to ignore than misattribute.
                index[key] = false
            end
        end
    end
    chatNameIndexCache[guildKey] = { builtAt = guildData.lastScan, index = index }
    return index
end

local function applyChatOnlineSignal(guildKey, guid, player)
    local previousLastOnline = GP:SafeNumber(player.lastOnline, 0)
    if previousLastOnline >= INACTIVE_RETURN_HOURS then
        GP:GetModule("EventLog"):Add(guildKey, "inactivereturn", guid, player.name, {
            hoursInactive = previousLastOnline,
            inactiveText = formatOfflineDuration(previousLastOnline),
        })
    end

    local now = time()
    player.online = true
    player.lastOnline = 0
    player.lastOnlineTime = { 0, 0, 0, 0 }
    player.lastSeen = now
    player.onlineSince = now
    player.timeEnteredZone = now
    player.chatOnlineProofAt = GetTime()
end

-- CHAT_MSG_GUILD / CHAT_MSG_OFFICER: a message proves its sender is online.
-- Check protected-content state before reading the sender argument.
function Roster:OnChatMsgGuildPresence(_, _, sender)
    if chatMessagingLockdownActive() then return end
    if not sender or sender == "" then return end

    local guildKey = self.currentGuildKey or self:GetGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return end

    local guid = chatNameIndex(guildKey, guildData)[normalizeName(sender)]
    local player = guid and guildData.roster[guid]
    if not player or player.online then return end

    applyChatOnlineSignal(guildKey, guid, player)
    GP:SendMessage("GuildParagon_RosterScanned", guildKey)
end

function Roster:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    self:RegisterEvent("GUILD_EVENT_LOG_UPDATE", "OnGuildEventLogUpdate")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "OnGuildRosterUpdate")
    -- Guild/officer chat as a free "already online" presence signal.
    self:RegisterEvent("CHAT_MSG_GUILD", "OnChatMsgGuildPresence")
    self:RegisterEvent("CHAT_MSG_OFFICER", "OnChatMsgGuildPresence")

    if IsInGuild() and scanSettings().login then
        local blocked = scanBlocked()
        if not blocked and C_GuildInfo and C_GuildInfo.GuildRoster then
            GP:SafeCall(C_GuildInfo.GuildRoster, nil)
        end
        self:RequestGuildEventLog(1.5)
        self:RequestScan(1)
    end
end

function Roster:OnGuildRosterUpdate()
    if not IsInGuild() then return end
    if not scanSettings().rosterUpdates then return end
    self:RequestScan(0.5)
end

function Roster:RequestScan(delay)
    if scanQueued then
        scanStats.coalesced = scanStats.coalesced + 1
        return
    end

    scanQueued = true
    scanStats.queued = scanStats.queued + 1
    C_Timer.After(delay or 0.5, function()
        scanQueued = false
        if IsInGuild() then
            self:Scan(true)
        end
    end)
end

local function timestampFromGuildEventAge(years, months, days, hours)
    years = GP:SafeNumber(years, 0)
    months = GP:SafeNumber(months, 0)
    days = GP:SafeNumber(days, 0)
    hours = GP:SafeNumber(hours, 0)
    return time() - ((years * 365 * 24 * 3600) + (months * 30 * 24 * 3600) + (days * 24 * 3600) + (hours * 3600))
end

-- Blizzard reports guild-event age in whole hours. Ignore timestamp shifts
-- inside this tolerance so rounding jitter near local midnight does not
-- rewrite join dates on every scan.
local JOIN_EVENT_JITTER_TOLERANCE = 2 * 3600

function Roster:RequestGuildEventLog(delay)
    if eventLogQueryQueued then return end
    if not IsInGuild() then return end
    if type(QueryGuildEventLog) ~= "function" then return end

    eventLogQueryQueued = true
    C_Timer.After(delay or 0, function()
        eventLogQueryQueued = false
        if not IsInGuild() then return end
        local blocked = scanBlocked()
        if blocked then return end

        local now = time()
        local wait = math.max(0, 10 - (now - eventLogLastQuery))
        if wait > 0 then
            self:RequestGuildEventLog(wait + 0.1)
            return
        end

        eventLogLastQuery = now
        eventLogQueryPending = true
        GP:SafeCall(QueryGuildEventLog, nil)
    end)
end

function Roster:OnGuildEventLogUpdate()
    if not IsInGuild() then return end
    if not eventLogQueryPending then return end

    eventLogQueryPending = false
    self:CorroborateJoinDatesFromGuildEventLog()
end

function Roster:GetPerformanceStats()
    return scanStats
end

function Roster:GetGuildKey()
    if not IsInGuild() then return nil end
    local guildName = GP:SafeOptionalString(GP:SafeCall(GetGuildInfo, nil, "player"))
    if not guildName or guildName == "" then return nil end
    local clubId = GP:SafeCall(C_Club and C_Club.GetGuildClubId, nil)
    if not clubId then return nil end -- guild club data hasn't loaded yet; retry next scan
    return guildName .. "-" .. clubId
end

local function mergeTimestamped(targetValues, targetUpdated, sourceValues, sourceUpdated)
    for guid, ts in pairs(sourceUpdated) do
        local existingTs = targetUpdated[guid]
        if existingTs == nil or ts > existingTs then
            targetUpdated[guid] = ts
            targetValues[guid] = sourceValues[guid]
        end
    end
    -- Defensive only: a source record with no *Updated entry at all shouldn't
    -- exist after the timestamp backfill (see Alts.lua/Nicknames.lua's own
    -- backfill), but if
    -- one somehow does, don't let it silently vanish — fold it in as the
    -- oldest possible ("unknown") timestamp, same convention as that backfill.
    for guid, value in pairs(sourceValues) do
        if targetUpdated[guid] == nil and targetValues[guid] == nil then
            targetValues[guid] = value
            targetUpdated[guid] = 0
        end
    end
end

local function mergeGuildData(target, source)
    target.roster = target.roster or {}
    target.formerMembers = target.formerMembers or {}
    for guid, player in pairs(source.roster or {}) do
        if not target.roster[guid] and not target.formerMembers[guid] then
            target.roster[guid] = player
        end
    end
    for guid, player in pairs(source.formerMembers or {}) do
        if not target.roster[guid] and not target.formerMembers[guid] then
            target.formerMembers[guid] = player
        end
    end

    target.alts, target.altsUpdated = target.alts or {}, target.altsUpdated or {}
    target.mains, target.mainsUpdated = target.mains or {}, target.mainsUpdated or {}
    target.nicknames, target.nicknamesUpdated = target.nicknames or {}, target.nicknamesUpdated or {}
    target.customNotes, target.customNotesUpdated = target.customNotes or {}, target.customNotesUpdated or {}
    target.customOfficerNotes, target.customOfficerNotesUpdated = target.customOfficerNotes or {}, target.customOfficerNotesUpdated or {}
    target.logRemoved = target.logRemoved or {}
    for id, ts in pairs(source.logRemoved or {}) do
        if not target.logRemoved[id] or ts > target.logRemoved[id] then
            target.logRemoved[id] = ts
        end
    end
    mergeTimestamped(target.alts, target.altsUpdated, source.alts or {}, source.altsUpdated or {})
    mergeTimestamped(target.mains, target.mainsUpdated, source.mains or {}, source.mainsUpdated or {})
    mergeTimestamped(target.nicknames, target.nicknamesUpdated, source.nicknames or {}, source.nicknamesUpdated or {})
    mergeTimestamped(target.customNotes, target.customNotesUpdated, source.customNotes or {}, source.customNotesUpdated or {})
    mergeTimestamped(target.customOfficerNotes, target.customOfficerNotesUpdated, source.customOfficerNotes or {}, source.customOfficerNotesUpdated or {})
end

function Roster:MigrateLegacyGuildKey(canonicalKey)
    local guildName = GP:SafeOptionalString(GP:SafeCall(GetGuildInfo, nil, "player"))
    if not guildName or guildName == "" then return end

    -- GetNormalizedRealmName() can read nil for a brief window after login
    -- before the realm resolves; bail rather than concatenate nil (this
    -- function is called every scan — see the file header note above — so a
    -- realm that hasn't resolved yet just gets picked up on the next scan).
    -- GP:LocalPlayerFullName() nil-guards GetNormalizedRealmName() during login.
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then return end

    local legacyKey = guildName .. "-" .. realm
    if legacyKey == canonicalKey then return end

    local legacyData = GP.db.global.guilds[legacyKey]
    if not legacyData then return end

    local canonicalData = GP.db.global.guilds[canonicalKey]
    if not canonicalData then
        -- Nobody's scanned into the canonical key from any realm yet — this
        -- character's data simply *is* the guild's data so far, just filed
        -- under the wrong key. Rename in place, nothing to merge.
        GP.db.global.guilds[canonicalKey] = legacyData
        GP.db.global.guilds[legacyKey] = nil
        GP:Print(string.format(GP.L["Guild Paragon merged data from an older realm-specific key (%s) into %s."], legacyKey, canonicalKey))
        return
    end

    mergeGuildData(canonicalData, legacyData)
    if legacyData.log and #legacyData.log > 0 then
        GP:GetModule("EventLog"):MergeEntries(canonicalKey, legacyData.log)
    end
    GP.db.global.guilds[legacyKey] = nil

    GP:Print(string.format(GP.L["Guild Paragon merged data from an older realm-specific key (%s) into %s."], legacyKey, canonicalKey))
end

function Roster:GetBirthday(player)
    local info = player and player.birthdayInfo
    if type(info) ~= "table" or type(info.date) ~= "table" then return nil, nil end
    local day = tonumber(info.date[1])
    local month = tonumber(info.date[2])
    if not day or not month or day <= 0 or month <= 0 then return nil, nil end
    return day, month
end

function Roster:GetBirthdayUpdatedAt(guildKey, guid)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    local info = player and player.birthdayInfo
    return type(info) == "table" and tonumber(info.timeUpdated) or nil
end

function Roster:GetBirthdayForSync(guildKey, guid)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    local info = player and player.birthdayInfo
    if type(info) ~= "table" then return nil end
    local day, month = self:GetBirthday(player)
    if not day or not month then return nil end
    return {
        date = { day, month },
        announced = info.announced and true or false,
        unknown = info.unknown and true or false,
    }
end

function Roster:GetBirthdaysForSync(guildKey)
    local guildData = GP.db.global.guilds[guildKey]
    local birthdays, updated = {}, {}
    if not guildData then return birthdays, updated end

    local function addBucket(bucket)
        for guid, player in pairs(bucket or {}) do
            local info = player.birthdayInfo
            if type(info) == "table" and type(info.timeUpdated) == "number" then
                updated[guid] = info.timeUpdated
                local birthday = self:GetBirthdayForSync(guildKey, guid)
                if birthday then birthdays[guid] = birthday end
            end
        end
    end

    addBucket(guildData.roster)
    addBucket(guildData.formerMembers)
    return birthdays, updated
end

local function formerMemberSyncTimestamp(player)
    if type(player) ~= "table" then return nil end
    local info = player.birthdayInfo
    return math.max(
        tonumber(player.leftDate) or 0,
        tonumber(player.lastSeen) or 0,
        tonumber(player.firstSeen) or 0,
        tonumber(player.joinDateUpdated) or 0,
        type(info) == "table" and (tonumber(info.timeUpdated) or 0) or 0
    )
end

function Roster:GetFormerMembersForSync(guildKey)
    local guildData = GP.db.global.guilds[guildKey]
    local former, updated = {}, {}
    if not guildData then return former, updated end

    for guid, player in pairs(guildData.formerMembers or {}) do
        local ts = formerMemberSyncTimestamp(player)
        if ts and ts > 0 and type(player.name) == "string" and player.name ~= "" then
            former[guid] = {
                guid = guid,
                name = player.name,
                class = player.class,
                level = player.level,
                rankName = player.rankName,
                rankIndex = player.rankIndex,
                firstSeen = player.firstSeen,
                joinDateSource = player.joinDateSource,
                joinDateUnknown = player.joinDateUnknown and true or false,
                joinDateUpdated = player.joinDateUpdated,
                leftDate = player.leftDate,
                lastSeen = player.lastSeen,
            }
            updated[guid] = ts
        end
    end

    return former, updated
end

function Roster:GetFormerMemberForSync(guildKey, guid)
    local former, updated = self:GetFormerMembersForSync(guildKey)
    return former[guid], updated[guid]
end

function Roster:GetFormerMemberUpdatedAt(guildKey, guid)
    local guildData = GP.db.global.guilds[guildKey]
    local player = guildData and guildData.formerMembers and guildData.formerMembers[guid]
    return formerMemberSyncTimestamp(player)
end

function Roster:SetFormerMemberFromSync(guildKey, guid, incoming, ts)
    if not guildKey or not guid or type(incoming) ~= "table" or type(ts) ~= "number" then return false end
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return false end
    guildData.roster = guildData.roster or {}
    guildData.formerMembers = guildData.formerMembers or {}

    if guildData.roster[guid] then
        return false
    end

    local current = guildData.formerMembers[guid]
    local currentTs = formerMemberSyncTimestamp(current)
    if currentTs and currentTs >= ts then return false end

    local player = current or { guid = guid, rankHistory = {}, noteHistory = {}, officerNoteHistory = {} }
    player.guid = guid
    player.name = sanitizeName(GP:SafeOptionalString(incoming.name)) or player.name
    player.class = GP:SafeOptionalString(incoming.class) or player.class
    player.level = GP:SafeNumber(incoming.level, player.level or 0)
    player.rankName = GP:SafeOptionalString(incoming.rankName) or player.rankName
    player.rankIndex = GP:SafeNumber(incoming.rankIndex, player.rankIndex)
    player.firstSeen = GP:SafeNumber(incoming.firstSeen, player.firstSeen)
    player.joinDateSource = GP:SafeOptionalString(incoming.joinDateSource) or player.joinDateSource
    if incoming.joinDateUnknown ~= nil then
        player.joinDateUnknown = incoming.joinDateUnknown and true or false
    end
    player.joinDateUpdated = GP:SafeNumber(incoming.joinDateUpdated, player.joinDateUpdated)
    player.leftDate = GP:SafeNumber(incoming.leftDate, player.leftDate)
    player.lastSeen = GP:SafeNumber(incoming.lastSeen, player.lastSeen)
    player.online = false
    player.status = GP:SafeNumber(player.status, 0)
    player.rankHistory = player.rankHistory or {}
    player.noteHistory = player.noteHistory or {}
    player.officerNoteHistory = player.officerNoteHistory or {}

    if not player.name or player.name == "" then return false end
    guildData.formerMembers[guid] = player
    return true
end

function Roster:GetJoinDateUpdatedAt(guildKey, guid)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    return player and tonumber(player.joinDateUpdated) or nil
end

function Roster:GetJoinDateForSync(guildKey, guid)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    if not player or type(player.firstSeen) ~= "number" then return nil end
    return {
        firstSeen = player.firstSeen,
        source = player.joinDateSource or "firstseen",
    }
end

function Roster:GetJoinDatesForSync(guildKey)
    local guildData = GP.db.global.guilds[guildKey]
    local joinDates, updated = {}, {}
    if not guildData then return joinDates, updated end

    local function addBucket(bucket)
        for guid, player in pairs(bucket or {}) do
            if type(player.joinDateUpdated) == "number" then
                updated[guid] = player.joinDateUpdated
                joinDates[guid] = {
                    firstSeen = player.firstSeen,
                    source = player.joinDateSource or "firstseen",
                }
            end
        end
    end

    addBucket(guildData.roster)
    addBucket(guildData.formerMembers)
    return joinDates, updated
end

function Roster:SetJoinDateFromSync(guildKey, guid, firstSeen, source, ts)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    firstSeen = tonumber(firstSeen)
    if not player or not firstSeen or firstSeen <= 0 or type(ts) ~= "number" then return false end

    player.firstSeen = firstSeen
    player.joinDateUnknown = false
    player.joinDateSource = source or "sync"
    player.joinDateUpdated = ts
    GP:SendMessage("GuildParagon_JoinDateChanged", guildKey, guid, firstSeen, player.joinDateSource, ts)
    return true
end

-- Note text is no longer consulted here: `firstSeen` is the sole source of
-- truth for join dates now, so corroboration only needs to defer to a
-- source that already outranks the guild event log (a manual edit, or a
-- one-time note-date migration) — never to note text directly.
local function canReplaceJoinDateFromGuildEvent(player, eventTs)
    if type(eventTs) ~= "number" or eventTs <= 0 then return false end
    if not dateText(eventTs) then return false end

    local source = player.joinDateSource
    if source and source ~= "firstseen" and source ~= "guildevent" then
        return false
    end

    if not source and type(player.grmJoinDateHist) == "table" and #player.grmJoinDateHist > 0 and not player.joinDateUnknown then
        return false
    end

    return true
end

function Roster:ApplyGuildEventJoinDate(guildKey, guid, eventTs)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    if not guildData or not player then return false end

    if not canReplaceJoinDateFromGuildEvent(player, eventTs) then return false end

    local oldDate = dateText(player.firstSeen)
    local newDate = dateText(eventTs)
    if not newDate then return false end

    -- If the first-seen date already matches Blizzard's guild log date, still
    -- upgrade the provenance once. This is the common "joined while Guild
    -- Paragon was watching" case: the date is right, but without this source
    -- upgrade the UI keeps saying "unconfirmed" forever.
    if oldDate == newDate then
        if player.joinDateSource ~= "guildevent" then
            local ts = time()
            player.joinDateUnknown = false
            player.joinDateSource = "guildevent"
            player.joinDateUpdated = ts
            GP:GetModule("EventLog"):Add(guildKey, "joindate", guid, player.name, {
                date = newDate,
                source = GP.L["guild event log"],
            })
            GP:SendMessage("GuildParagon_JoinDateChanged", guildKey, guid, player.firstSeen, player.joinDateSource, ts)
            return true
        end
        return false
    end

    -- See JOIN_EVENT_JITTER_TOLERANCE above: don't treat a reconstruction
    -- that only moved by plausible hour-granularity rounding error as a
    -- real corroborated change.
    if type(player.firstSeen) == "number" and math.abs(eventTs - player.firstSeen) < JOIN_EVENT_JITTER_TOLERANCE then
        return false
    end

    -- Bail before touching anything if the corroborated date already
    -- matches what's stored: this runs every roster scan (once per
    local ts = time()
    player.firstSeen = eventTs
    player.joinDateUnknown = false
    player.joinDateSource = "guildevent"
    player.joinDateUpdated = ts

    -- No longer touches the custom note. firstSeen is the only place this
    -- gets recorded, and only this one field needs to sync.
    GP:GetModule("EventLog"):Add(guildKey, "joindate", guid, player.name, {
        date = newDate,
        source = GP.L["guild event log"],
    })
    GP:SendMessage("GuildParagon_JoinDateChanged", guildKey, guid, eventTs, player.joinDateSource, ts)
    return true
end

function Roster:CorroborateJoinDatesFromGuildEventLog(guildKey)
    if not GP:IsOfficer() then return 0 end
    if type(GetNumGuildEvents) ~= "function" or type(GetGuildEventInfo) ~= "function" then return 0 end

    guildKey = guildKey or self.currentGuildKey or self:GetGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return 0 end

    local numEvents = GP:SafeNumber(GP:SafeCall(GetNumGuildEvents, 0), 0)
    if numEvents <= 0 then return 0 end

    local candidates = {}
    for i = 1, numEvents do
        local ok, eventType, playerName, _playerName2, _rank, years, months, days, hours = pcall(GetGuildEventInfo, i)
        if ok and GP:SafeOptionalString(eventType) == "join" then
            playerName = GP:SafeOptionalString(playerName)
            local guid = playerName and self:FindPlayerByName(guildData, sanitizeName(playerName), false)
            if guid then
                local eventTs = timestampFromGuildEventAge(years, months, days, hours)
                if not candidates[guid] or eventTs > candidates[guid] then
                    candidates[guid] = eventTs
                end
            end
        end
    end

    local updated = 0
    for guid, eventTs in pairs(candidates) do
        if self:ApplyGuildEventJoinDate(guildKey, guid, eventTs) then
            updated = updated + 1
        end
    end

    return updated
end

function Roster:SetJoinDate(guildKey, guid, dateTextInput, ts)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    if not player then return false, GP.L["Player not found."] end
    if not ts and not GP:IsOfficer() then return false, GP.L["Join-date audit changes require officer access."] end

    local parsed = parseJoinDateText(dateTextInput)
    if not parsed then return false, GP.L["Enter a date as YYYY-MM-DD."] end

    ts = ts or time()
    player.firstSeen = parsed
    player.joinDateUnknown = false
    player.joinDateSource = "manual"
    player.joinDateUpdated = ts

    GP:GetModule("EventLog"):Add(guildKey, "joindate", guid, player.name, {
        date = date("%Y-%m-%d", parsed),
        source = GP.L["manual edit"],
    })
    GP:SendMessage("GuildParagon_JoinDateChanged", guildKey, guid, parsed, player.joinDateSource, ts)
    return true
end

function Roster:MigrateNoteJoinDates(guildKey, confirmed)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return nil, GP.L["No roster data yet — try /gp scan."] end
    if not GP:IsGuildMaster() then return nil, GP.L["This command is restricted to the guild master."] end

    local CustomNotes = GP:GetModule("CustomNotes")
    local updated = 0
    local ts = time()

    local function scanBucket(bucket)
        for guid, player in pairs(bucket or {}) do
            local parsed = parseJoinDateText(customJoinDateText(CustomNotes:Get(guildKey, guid)))
            if parsed and (type(player.firstSeen) ~= "number" or date("%Y-%m-%d", parsed) ~= date("%Y-%m-%d", player.firstSeen)) then
                updated = updated + 1
                if confirmed then
                    player.firstSeen = parsed
                    player.joinDateUnknown = false
                    player.joinDateSource = "customnote"
                    player.joinDateUpdated = ts
                    GP:GetModule("EventLog"):Add(guildKey, "joindate", guid, player.name, {
                        date = date("%Y-%m-%d", parsed),
                        source = GP.L["custom note"],
                    })
                    GP:SendMessage("GuildParagon_JoinDateChanged", guildKey, guid, parsed, player.joinDateSource, ts)
                end
            end
        end
    end

    scanBucket(guildData.roster)
    scanBucket(guildData.formerMembers)
    return updated
end

function Roster:SetBirthday(guildKey, guid, day, month, ts)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    day = tonumber(day)
    month = tonumber(month)
    if not player then return false, GP.L["Player not found."] end
    if not ts and not GP:CanEditMemberProfile(guid) then
        return false, GP.L["You can only edit nicknames or birthdays for your own linked characters."]
    end
    if not day or day < 1 or day > 31 or not month or month < 1 or month > 12 then
        return false, GP.L["Use day 1-31 and month 1-12."]
    end

    ts = ts or time()
    local Alts = GP:GetModule("Alts")
    local groupMain = Alts:GetMain(guildKey, guid) or guid
    local group = { groupMain }
    for _, altGUID in ipairs(Alts:GetAlts(guildKey, groupMain) or {}) do
        table.insert(group, altGUID)
    end

    for _, memberGUID in ipairs(group) do
        local linkedPlayer = getPlayer(guildData, memberGUID)
        if linkedPlayer then
            linkedPlayer.birthdayInfo = linkedPlayer.birthdayInfo or {}
            linkedPlayer.birthdayInfo.date = { day, month }
            linkedPlayer.birthdayInfo.announced = linkedPlayer.birthdayInfo.announced and true or false
            linkedPlayer.birthdayInfo.timeUpdated = ts
            linkedPlayer.birthdayInfo.unknown = false
        end
    end

    GP:GetModule("EventLog"):Add(guildKey, "birthday", guid, player.name, { day = day, month = month })
    GP:SendMessage("GuildParagon_BirthdayChanged", guildKey, guid, day, month, ts)
    return true
end

function Roster:ClearBirthday(guildKey, guid, ts)
    local guildData = GP.db.global.guilds[guildKey]
    local player = getPlayer(guildData, guid)
    if not player then return false, GP.L["Player not found."] end
    if not ts and not GP:CanEditMemberProfile(guid) then
        return false, GP.L["You can only edit nicknames or birthdays for your own linked characters."]
    end

    ts = ts or time()
    local Alts = GP:GetModule("Alts")
    local groupMain = Alts:GetMain(guildKey, guid) or guid
    local group = { groupMain }
    for _, altGUID in ipairs(Alts:GetAlts(guildKey, groupMain) or {}) do
        table.insert(group, altGUID)
    end

    for _, memberGUID in ipairs(group) do
        local linkedPlayer = getPlayer(guildData, memberGUID)
        if linkedPlayer then
            linkedPlayer.birthdayInfo = {
                date = { 0, 0 },
                announced = false,
                timeUpdated = ts,
                unknown = false,
            }
        end
    end

    GP:GetModule("EventLog"):Add(guildKey, "birthday", guid, player.name, { cleared = true })
    GP:SendMessage("GuildParagon_BirthdayChanged", guildKey, guid, nil, nil, ts)
    return true
end

-- Batching:         The Blizzard-roster-read pass, the diff/apply pass, and
--                    the departure-detection pass below each run
function Roster:Scan(automatic, onComplete)
    scanStats.requested = scanStats.requested + 1
    if scanInProgress then
        scanStats.skippedReentrant = scanStats.skippedReentrant + 1
        if automatic then
            -- Queue one follow-up scan after the in-flight batch completes.
            rescanRequestedDuringScan = true
        end
        local reason = GP.L["Roster scan already in progress."]
        if onComplete then onComplete(false, reason) end
        return false, reason
    end

    local blocked, blockReason = scanBlocked()
    if blocked then
        scanStats.deferredProtected = scanStats.deferredProtected + 1
        local reason = automatic and nil or blockReason
        if onComplete then onComplete(false, reason) end
        return false, reason
    end

    local guildKey = self:GetGuildKey()
    if not guildKey then
        local reason = GP.L["No roster data yet — try /gp scan."]
        if onComplete then onComplete(false, reason) end
        return false, reason
    end

    scanInProgress = true
    local scanStart = profileNow()

    self:MigrateLegacyGuildKey(guildKey)

    GP.db.global.guilds[guildKey] = GP.db.global.guilds[guildKey] or {
        roster = {},
        formerMembers = {},
        log = {},
        logRemoved = {},
    }
    local guildData = GP.db.global.guilds[guildKey]
    guildData.logRemoved = guildData.logRemoved or {}
    local EventLog = GP:GetModule("EventLog")
    local CustomNotes = GP:GetModule("CustomNotes")
    CustomNotes:RepairStoredNotes(guildKey)

    local now = time()
    -- GetTime counterpart to `now`, used only for chatOnlineProofAt ordering.
    local scanStartedAt = GetTime()
    local seenGUIDs = {}

    -- Show-offline bracket: force the
    -- guild panel's "Show Offline Members" flag on for the duration of the
    local showOfflineRestore = BeginFullRosterScan()
    local showOfflineRestored = false
    local function endShowOfflineBracket()
        if showOfflineRestored then return end
        showOfflineRestored = true
        EndFullRosterScan(showOfflineRestore)
    end

    local numMembers = GP:SafeNumber(GP:SafeCall(GetNumGuildMembers, 0), 0)
    -- Snapshot before the loop touches anything — used below to sanity-check
    -- whether this scan looks complete before trusting it to mean "anyone
    -- missing has actually left".
    local previousActiveCount = countTable(guildData.roster)
    local previousFormerCount = countTable(guildData.formerMembers)
    local isInitialRosterPopulation = not guildData.lastScan and previousActiveCount == 0 and previousFormerCount == 0
    local previousPublicNoteCount = countStoredNotes(guildData.roster, "note")
    local previousOfficerNoteCount = countStoredNotes(guildData.roster, "officerNote")
    local currentPublicNoteCount, currentOfficerNoteCount = 0, 0
    local canReadOfficerNotes = canViewOfficerNotes()
    local scanRows = {}
    local liveMythicScores = fetchLiveMythicScores()
    local publicNotesReliable, officerNotesReliable

    if numMembers <= 0 and previousActiveCount > 0 then
        endShowOfflineBracket()
        scanInProgress = false
        local reason = automatic and nil or GP.L["Roster scan skipped because Blizzard roster data is not available yet."]
        if onComplete then onComplete(false, reason) end
        return false, reason
    end

    local abort, gatherBatch, beginApplyPhase, applyBatch, beginDeparturePhase, departBatch, finishScan

    abort = function(reason)
        endShowOfflineBracket()
        scanInProgress = false
        if onComplete then onComplete(false, reason) end
        if rescanRequestedDuringScan then
            rescanRequestedDuringScan = false
            self:RequestScan(0.5)
        end
    end

    -- Step 1: read every member out of Blizzard's roster cache and
    -- sanitize into scanRows, ROSTER_SCAN_BATCH_SIZE at a time.
    gatherBatch = function(startIndex)
        local blockedNow, blockedReason = scanBlocked()
        if blockedNow then
            abort(automatic and nil or blockedReason)
            return
        end

        local endIndex = math.min(numMembers, startIndex + ROSTER_SCAN_BATCH_SIZE - 1)
        for i = startIndex, endIndex do
            local ok, name, rankName, rankIndex, level, _, zone, note, officerNote, online, status, classFile, _, _, isMobile, _, _, guid = pcall(GetGuildRosterInfo, i)
            if not ok then
                name = nil
            end
            local yearsOffline, monthsOffline, daysOffline, hoursOffline = 0, 0, 0, 0
            if GetGuildRosterLastOnline then
                local lastOnlineOk
                lastOnlineOk, yearsOffline, monthsOffline, daysOffline, hoursOffline = pcall(GetGuildRosterLastOnline, i)
                if not lastOnlineOk then
                    yearsOffline, monthsOffline, daysOffline, hoursOffline = 0, 0, 0, 0
                end
            end

            name = sanitizeName(GP:SafeOptionalString(name))
            rankName = GP:SafeOptionalString(rankName)
            rankIndex = GP:SafeNumber(rankIndex, nil)
            level = GP:SafeNumber(level, nil)
            zone = GP:SafeOptionalString(zone)
            note = GP:SafeOptionalString(note)
            officerNote = GP:SafeOptionalString(officerNote)
            online = GP:SafeBool(online, false)
            status = GP:SafeNumber(status, nil)
            classFile = GP:SafeOptionalString(classFile)
            isMobile = GP:SafeBool(isMobile, false)
            guid = GP:SafeOptionalString(guid)
            yearsOffline = GP:SafeNumber(yearsOffline, 0)
            monthsOffline = GP:SafeNumber(monthsOffline, 0)
            daysOffline = GP:SafeNumber(daysOffline, 0)
            hoursOffline = GP:SafeNumber(hoursOffline, 0)

            if guid and name and name ~= "" then
                local mythicScore = liveMythicScoreFor(liveMythicScores, guid, name)
                if type(note) == "string" and note ~= "" then currentPublicNoteCount = currentPublicNoteCount + 1 end
                if type(officerNote) == "string" and officerNote ~= "" then currentOfficerNoteCount = currentOfficerNoteCount + 1 end
                table.insert(scanRows, {
                    name = name, rankName = rankName, rankIndex = rankIndex, level = level, zone = zone,
                    note = note, officerNote = officerNote, online = online, status = status,
                    classFile = classFile, isMobile = isMobile, guid = guid,
                    mythicScore = mythicScore,
                    yearsOffline = yearsOffline, monthsOffline = monthsOffline,
                    daysOffline = daysOffline, hoursOffline = hoursOffline,
                })
            end
        end

        if endIndex < numMembers then
            C_Timer.After(0, function() gatherBatch(endIndex + 1) end)
        else
            -- Gather phase complete — every remaining phase (apply, depart,
            -- finish) never touches GetGuildRosterInfo again, so the
            -- show-offline bracket ends here.
            endShowOfflineBracket()
            beginApplyPhase()
        end
    end

    beginApplyPhase = function()
        if numMembers > 0 and #scanRows == 0 then
            abort(automatic and nil or GP.L["Roster scan skipped because Blizzard roster data is not available yet."])
            return
        end

        publicNotesReliable = not (previousPublicNoteCount >= 10 and currentPublicNoteCount < previousPublicNoteCount * 0.5)
        officerNotesReliable = canReadOfficerNotes
            and not (previousOfficerNoteCount >= 10 and currentOfficerNoteCount < previousOfficerNoteCount * 0.5)

        applyBatch(1)
    end

    -- Step 2: diff each scanned row against stored state and apply
    -- changes, ROSTER_SCAN_BATCH_SIZE at a time.
    applyBatch = function(startIndex)
        local blockedNow, blockedReason = scanBlocked()
        if blockedNow then
            abort(automatic and nil or blockedReason)
            return
        end

        local endIndex = math.min(#scanRows, startIndex + ROSTER_SCAN_BATCH_SIZE - 1)
        for rowIndex = startIndex, endIndex do
            local row = scanRows[rowIndex]
            local name, rankName, rankIndex, level, zone = row.name, row.rankName, row.rankIndex, row.level, row.zone
            local note, officerNote = row.note, row.officerNote
            local online, status, classFile, isMobile, guid = row.online, row.status, row.classFile, row.isMobile, row.guid
            local mythicScore = row.mythicScore
            local yearsOffline, monthsOffline = row.yearsOffline, row.monthsOffline
            local daysOffline, hoursOffline = row.daysOffline, row.hoursOffline

            seenGUIDs[guid] = true

            local player = guildData.roster[guid]
            local joinedThisScan = false
            local rejoinedThisScan = false
            local joinAttribution
            if not isInitialRosterPopulation then
                local Recruitment = GP:GetModule("Recruitment", true)
                if Recruitment and Recruitment.GetJoinInviteAttribution then
                    joinAttribution = Recruitment:GetJoinInviteAttribution(guildKey, name)
                end
            end

            if not player and guildData.formerMembers[guid] then
                -- Rejoin: bring back their history instead of starting fresh.
                player = guildData.formerMembers[guid]
                guildData.formerMembers[guid] = nil
                guildData.roster[guid] = player
                player.pendingDepartureAt = nil
                player.leftDate = nil
                if not isInitialRosterPopulation then
                    local extra = joinAttribution or {}
                    extra.rejoin = true
                    EventLog:AddJoin(guildKey, guid, name, extra)
                    joinedThisScan = true
                    rejoinedThisScan = true
                end
                local Alts = GP:GetModule("Alts")
                if not isInitialRosterPopulation and not Alts:GetMain(guildKey, guid) and not Alts:IsMain(guildKey, guid) then
                    Alts:SetAsMain(guildKey, guid, now)
                end
            elseif not player then
                player = {
                    guid = guid,
                    name = name,
                    firstSeen = now,
                    rankHistory = {},
                    noteHistory = {},
                    officerNoteHistory = {},
                }
                guildData.roster[guid] = player
                if not isInitialRosterPopulation then
                    local extra = joinAttribution or {}
                    extra.rejoin = false
                    EventLog:AddJoin(guildKey, guid, name, extra)
                    -- Match the rejoin path: only auto-mark truly untagged
                    -- characters as standalone mains. A synced alt-tag may
                    -- exist before this client first sees the roster row.
                    local Alts = GP:GetModule("Alts")
                    if not Alts:GetMain(guildKey, guid) and not Alts:IsMain(guildKey, guid) then
                        Alts:SetAsMain(guildKey, guid, now)
                    end
                    joinedThisScan = true
                end
            end

            player.pendingDepartureAt = nil

            if rankIndex and player.rankIndex == nil then
                table.insert(player.rankHistory, { rankName = rankName, rankIndex = rankIndex, ts = now })
            elseif rankIndex and player.rankIndex ~= rankIndex then
                -- Lower rankIndex = more senior rank (0 is Guild Master).
                local eventType = rankIndex < player.rankIndex and "promote" or "demote"
                EventLog:Add(guildKey, eventType, guid, name, {
                    fromRank = player.rankName, toRank = rankName,
                    fromRankIndex = player.rankIndex, toRankIndex = rankIndex,
                })
                table.insert(player.rankHistory, { rankName = rankName, rankIndex = rankIndex, ts = now })
            end

            if publicNotesReliable and note and player.note == nil then
                table.insert(player.noteHistory, { note = note, ts = now })
            elseif publicNotesReliable and note and player.note ~= note then
                EventLog:Add(guildKey, "note", guid, name, { fromNote = player.note, toNote = note })
                table.insert(player.noteHistory, { note = note, ts = now })
            end

            if officerNotesReliable and officerNote and player.officerNote == nil then
                table.insert(player.officerNoteHistory, { note = officerNote, ts = now })
            elseif officerNotesReliable and officerNote and player.officerNote ~= officerNote then
                EventLog:Add(guildKey, "officernote", guid, name, { fromNote = player.officerNote, toNote = officerNote })
                table.insert(player.officerNoteHistory, { note = officerNote, ts = now })
            end

            -- Captured before player.online/zone are overwritten below. The
            -- tooltip's time-in-zone display resets on first-seen-online and on
            -- zone changes.
            local wasOnline = player.online
            local previousLastOnline = GP:SafeNumber(player.lastOnline, 0)
            local previousLevel = GP:SafeNumber(player.level, 0)
            local oldZone = player.zone

            if not isInitialRosterPopulation and not joinedThisScan and level and previousLevel > 0 and level > previousLevel then
                local gained = level - previousLevel
                local cap = currentLevelCap()
                EventLog:Add(guildKey, "level", guid, name, {
                    fromLevel = previousLevel,
                    toLevel = level,
                    gained = gained,
                    atLevelCap = cap > 0 and level >= cap or false,
                })
            end

            if not isInitialRosterPopulation and not joinedThisScan and online and not wasOnline and previousLastOnline >= INACTIVE_RETURN_HOURS then
                EventLog:Add(guildKey, "inactivereturn", guid, name, {
                    hoursInactive = previousLastOnline,
                    inactiveText = formatOfflineDuration(previousLastOnline),
                })
            end

            -- Preserve a newer chat-derived online proof over an older
            -- batched roster-cache row.
            if not online and player.chatOnlineProofAt and player.chatOnlineProofAt >= scanStartedAt then
                online = true
            end

            player.name = name
            if rankName then player.rankName = rankName end
            if rankIndex then player.rankIndex = rankIndex end
            player.level = level or player.level or 0
            if publicNotesReliable and note then player.note = note end
            if officerNotesReliable and officerNote then player.officerNote = officerNote end
            if classFile then player.class = classFile end
            if zone then player.zone = zone end
            if mythicScore ~= nil then player.mythicScore = mythicScore end
            player.online = online
            player.status = status
            player.isMobile = isMobile
            if player.online then
                player.lastOnline = 0
                player.lastOnlineTime = { 0, 0, 0, 0 }
            else
                player.lastOnline = totalOfflineHours(yearsOffline, monthsOffline, daysOffline, hoursOffline)
                player.lastOnlineTime = { yearsOffline, monthsOffline, daysOffline, hoursOffline }
            end
            player.lastSeen = now

            if player.online and not wasOnline then
                player.onlineSince = now
                player.timeEnteredZone = now
            elseif player.online and (not player.timeEnteredZone or (zone and oldZone ~= zone)) then
                player.timeEnteredZone = now
            elseif not player.online then
                player.onlineSince = nil
                player.timeEnteredZone = nil
            end

            if joinedThisScan then
                local BanList = GP:GetModule("BanList", true)
                if BanList and BanList.CheckJoinWarning then
                    BanList:CheckJoinWarning(guildKey, guid, player, rejoinedThisScan)
                end
                local Recruitment = GP:GetModule("Recruitment", true)
                if Recruitment and Recruitment.HandleRosterJoin then
                    Recruitment:HandleRosterJoin(guildKey, guid, player, rejoinedThisScan)
                end
            end
        end

        if endIndex < #scanRows then
            C_Timer.After(0, function() applyBatch(endIndex + 1) end)
        else
            beginDeparturePhase()
        end
    end

    -- Step 3: anyone previously in the roster but not seen this scan may have
    -- left — guarded: if this scan saw drastically fewer members than we
    beginDeparturePhase = function()
        local seenCount = countTable(seenGUIDs)
        if previousActiveCount == 0 or seenCount >= previousActiveCount * 0.5 then
            local departed = {}
            for guid in pairs(guildData.roster) do
                if not seenGUIDs[guid] then
                    departed[#departed + 1] = guid
                end
            end
            departBatch(departed, 1)
        else
            finishScan()
        end
    end

    departBatch = function(departed, startIndex)
        local blockedNow, blockedReason = scanBlocked()
        if blockedNow then
            abort(automatic and nil or blockedReason)
            return
        end

        local endIndex = math.min(#departed, startIndex + ROSTER_SCAN_BATCH_SIZE - 1)
        for i = startIndex, endIndex do
            local guid = departed[i]
            local player = guildData.roster[guid]
            if player then
                if not player.pendingDepartureAt then
                    player.pendingDepartureAt = now
                else
                    player.pendingDepartureAt = nil
                    player.leftDate = now
                    guildData.formerMembers[guid] = player
                    guildData.roster[guid] = nil
                    local PostKick = GP:GetModule("PostKick", true)
                    local handledRemoval = false
                    if PostKick and PostKick.OnRosterDeparture then
                        handledRemoval = PostKick:OnRosterDeparture(guildKey, guid, player) and true or false
                    end
                    if not handledRemoval then
                        EventLog:Add(guildKey, "leave", guid, player.name, {})
                    end
                    GP:SendMessage("GuildParagon_FormerMemberChanged", guildKey, guid, player, now)
                end
            end
        end

        if endIndex < #departed then
            C_Timer.After(0, function() departBatch(departed, endIndex + 1) end)
        else
            finishScan()
        end
    end

    finishScan = function()
        guildData.lastScan = now
        -- Macro Tool saved rules are analyzed on demand from the Macro Tool UI.
        self.currentGuildKey = guildKey
        scanInProgress = false

        local elapsedMs = profileNow() - scanStart
        if elapsedMs < 0 then elapsedMs = 0 end
        local completedAt = time()
        scanStats.completed = scanStats.completed + 1
        scanStats.lastMs = elapsedMs
        scanStats.lastAt = completedAt
        scanStats.lastMembers = numMembers
        if elapsedMs > scanStats.maxMs or scanStats.maxAt == 0 then
            scanStats.maxMs = elapsedMs
            scanStats.maxAt = completedAt
        end
        scanStats.avgMs = scanStats.avgMs + ((elapsedMs - scanStats.avgMs) / scanStats.completed)

        GP:SendMessage("GuildParagon_RosterScanned", guildKey)
        self:RequestGuildEventLog(0.5)
        if onComplete then onComplete(true) end
        if rescanRequestedDuringScan then
            rescanRequestedDuringScan = false
            self:RequestScan(0.5)
        end
    end

    gatherBatch(1)
    return true
end

-- (countTable itself now lives near the top of the file — Scan() needs it
-- too, to sanity-check scan completeness before trusting a "missing"
-- member as a real departure.)
function Roster:CountMembers(guildData)
    return countTable(guildData.roster), countTable(guildData.formerMembers)
end

function Roster:DumpRosterToChat()
    local guildKey = self.currentGuildKey or self:GetGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]

    if not guildData then
        GP:Print(GP.L["No roster data yet — try /gp scan."])
        return
    end

    local activeCount, formerCount = self:CountMembers(guildData)
    GP:Print(string.format(GP.L["Roster for %s: %d active, %d former."], guildKey, activeCount, formerCount))

    local names = {}
    for _, player in pairs(guildData.roster) do
        table.insert(names, player)
    end
    table.sort(names, function(a, b) return a.name < b.name end)

    for _, player in ipairs(names) do
        GP:Print(string.format("  [%d] %s — %s (%s)", player.level, player.name, player.rankName, player.class))
    end
end
