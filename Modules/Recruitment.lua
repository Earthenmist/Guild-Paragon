-- Guild Paragon — Recruitment foundation
--
-- Data, safety guardrails, review scanning, queueing, and manual execution for
-- recruitment workflows.
local _, GP = ...

local Recruitment = GP:NewModule("Recruitment", "AceEvent-3.0")

local MAX_MESSAGE_LENGTH = 255
local WHO_QUERY_TIMEOUT = 12
local NEXT_QUERY_DELAY = 5
local WHO_LEVEL_STEP = 5
local WHO_RESULT_CAP = 50
local MAX_SCANNER_QUERIES = 200
local DEFAULT_MAX_LEVEL = 90
local ANALYTICS_MAX_SESSIONS = 100
local EXECUTOR_MODE_INVITE = "invite"
local EXECUTOR_MODE_WHISPER = "whisper"
local EXECUTOR_MODE_WHISPER_INVITE = "whisper_invite"
local DEFAULT_EXECUTOR_MODE = EXECUTOR_MODE_WHISPER
local INVITE_OUTCOME_SYSTEM_PATTERNS

-- Forward-declared: SaveSettings (defined well before the snapshot helpers
-- in the file) needs to call them, and `local function` declarations aren't
local resolveMessages, pushMessageSnapshotIfNeeded, pushRecruitmentSnapshotsIfNeeded, cleanupExpiredPendingInvites

local function trim(value)
    value = GP:SafeOptionalString(value)
    if not value then return "" end
    local ok, trimmed = pcall(strtrim, value)
    return ok and trimmed or ""
end

local function now()
    return time()
end

-- Guild-master recruitment-settings sync ordering (`data.gmSettingsUpdated`)
-- needs a value that never repeats across consecutive saves from this
local lastSettingsSyncTs = 0
local function nextSettingsSyncTs()
    local ts = time()
    if ts <= lastSettingsSyncTs then
        ts = lastSettingsSyncTs + 0.001
    end
    lastSettingsSyncTs = ts
    return ts
end

local function currentGuild()
    local Roster = GP:GetModule("Roster", true)
    local guildKey = Roster and (Roster.currentGuildKey or Roster:GetGuildKey())
    return guildKey, guildKey and GP.db.global.guilds[guildKey]
end

local function normalizeName(name)
    local Roster = GP:GetModule("Roster", true)
    if Roster and Roster.NormalizePlayerName then
        return Roster:NormalizePlayerName(name)
    end
    return trim(name):lower()
end

local function fullName(name)
    name = trim(name)
    if name == "" then return nil end
    if not name:find("-", 1, true) then
        local realm = GetNormalizedRealmName and GetNormalizedRealmName()
        if (not realm or realm == "") and GetRealmName then
            realm = tostring(GetRealmName() or ""):gsub("%s+", "")
        end
        if realm and realm ~= "" then name = name .. "-" .. realm end
    end
    return name
end

local function recordID(name)
    local normalized = normalizeName(name)
    if normalized == "" then return nil end
    return "name:" .. normalized
end

local function messageID(name)
    local normalized = trim(name):lower():gsub("%s+", "-"):gsub("[^%w%-_]", "")
    if normalized == "" then return nil end
    return "message:" .. normalized
end

local function getGuildDisplayName()
    local guildName = IsInGuild and GetGuildInfo and GetGuildInfo("player")
    if guildName and guildName ~= "" then return guildName end

    local guildKey = currentGuild()
    if guildKey then
        local display = tostring(guildKey):match("^(.-)%-%d+$")
        if display and display ~= "" then return display end
        return tostring(guildKey)
    end

    return GP.L["Your Guild"]
end

local function getPlayerDisplayName()
    if UnitName then
        local name = GP:SafeString(UnitName("player"), "")
        if name ~= "" then return name end
    end
    return GP.L["Player"]
end

local function getPlayerWhisperTarget()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        name = GP:SafeString(name, "")
        realm = GP:SafeString(realm, "")
        if name ~= "" then
            if realm ~= "" then return name .. "-" .. realm end
            return name
        end
    end
    return getPlayerDisplayName()
end

local function getGuildRecruitmentLink()
    local guildName = getGuildDisplayName()
    local clubID = GP:SafeCall(C_Club and C_Club.GetGuildClubId, nil)
    local listing = clubID and GP:SafeCall(ClubFinderGetCurrentClubListingInfo, nil, clubID)
    if type(listing) == "table" and listing.clubFinderGUID then
        local linkName = GP:SafeString(listing.name, guildName)
        return "|cffffd200|HclubFinder:" .. tostring(listing.clubFinderGUID) .. "|h[" .. linkName .. "]|h|r"
    end
    return guildName
end

local function ensureRecruitment(guildData)
    guildData.recruitment = guildData.recruitment or {}
    local data = guildData.recruitment
    data.blacklist = data.blacklist or {}
    data.blacklistUpdated = data.blacklistUpdated or {}
    data.antiSpam = data.antiSpam or {}
    data.antiSpamUpdated = data.antiSpamUpdated or {}
    data.pendingInvites = data.pendingInvites or {}
    data.pendingInvitesUpdated = data.pendingInvitesUpdated or {}
    data.messages = data.messages or {}
    data.messagesUpdated = data.messagesUpdated or {}
    data.filters = data.filters or {}
    data.filtersUpdated = data.filtersUpdated or {}
    data.customZones = data.customZones or {}
    data.customZonesUpdated = data.customZonesUpdated or {}
    data.gmSettings = data.gmSettings or {}
    data.gmSettingsUpdated = data.gmSettingsUpdated or 0
    -- Recruits waiting for an officer-clicked welcome send. Local-only,
    -- matching pendingInvites, analytics, and scanner state.
    data.awaitingWelcome = data.awaitingWelcome or {}
    data.awaitingWelcomeSeq = data.awaitingWelcomeSeq or 0
    data.analytics = data.analytics or {}
    data.analytics.totals = data.analytics.totals or {}
    data.analytics.days = data.analytics.days or {}
    data.analytics.sessions = data.analytics.sessions or {}
    return data
end

local function analyticsDayKey(timestamp)
    return date("%Y-%m-%d", timestamp or now())
end

local function ensureAnalytics(data)
    data.analytics = data.analytics or {}
    data.analytics.totals = data.analytics.totals or {}
    data.analytics.days = data.analytics.days or {}
    data.analytics.sessions = data.analytics.sessions or {}
    return data.analytics
end

local function bumpAnalytics(guildKey, key, amount)
    amount = tonumber(amount) or 1
    if amount == 0 then return end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not key then return end
    local analytics = ensureAnalytics(ensureRecruitment(guildData))
    analytics.totals[key] = (tonumber(analytics.totals[key]) or 0) + amount
    local dayKey = analyticsDayKey()
    analytics.days[dayKey] = analytics.days[dayKey] or {}
    analytics.days[dayKey][key] = (tonumber(analytics.days[dayKey][key]) or 0) + amount
    analytics.updatedAt = now()
end

local function addAnalyticsSession(guildKey, record)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or type(record) ~= "table" then return end
    local analytics = ensureAnalytics(ensureRecruitment(guildData))
    record.endedAt = record.endedAt or now()
    record.day = record.day or analyticsDayKey(record.endedAt)
    table.insert(analytics.sessions, 1, record)
    while #analytics.sessions > ANALYTICS_MAX_SESSIONS do
        table.remove(analytics.sessions)
    end
    analytics.updatedAt = now()
end

local function recordPendingOutcomeAnalytics(guildKey, record, outcome, reason, resolvedAt)
    bumpAnalytics(guildKey, "pendingResolved", 1)
    if outcome == "accepted" then
        bumpAnalytics(guildKey, "pendingAccepted", 1)
    elseif outcome == "declined" then
        bumpAnalytics(guildKey, "pendingDeclined", 1)
    elseif outcome == "failed" then
        bumpAnalytics(guildKey, "pendingFailed", 1)
    elseif outcome == "timedout" then
        bumpAnalytics(guildKey, "pendingTimedOut", 1)
    end
    addAnalyticsSession(guildKey, {
        type = "outcome",
        outcome = outcome or "resolved",
        name = record and record.name or nil,
        mode = record and record.mode or nil,
        startedAt = record and record.contactedAt or nil,
        endedAt = resolvedAt or now(),
        reason = reason,
    })
end

local function normalizeZoneName(name)
    return trim(name):lower()
end

-- Common Retail PvP zones (battlegrounds + arenas), by display name rather
-- than map ID — the eventual consumer of this list (Recruitment:IsInvalidZone
local PVP_ZONE_NAMES = {
    "Warsong Gulch", "Arathi Basin", "Alterac Valley", "Eye of the Storm",
    "Strand of the Ancients", "Isle of Conquest", "Twin Peaks",
    "Battle for Gilneas", "Silvershard Mines", "Temple of Kotmogu",
    "Deepwind Gorge", "Seething Shore", "Wintergrasp", "Tol Barad",
    "Ashran", "Nagrand Arena", "Blade's Edge Arena", "Dalaran Sewers",
    "Ruins of Lordaeron", "The Tiger's Peak", "Mugambala", "Hook Point",
    "Maldraxxus Coliseum", "Enigma Crucible", "Nokhudon Proving Grounds",
}

-- Defensive cap so an unexpected Encounter Journal state can't loop forever
-- — normal current-season dungeon/raid counts are well under this.
local MAX_EJ_INSTANCES = 200

local function collectEncounterJournalZones(out, isRaid, reason)
    if not EJ_GetInstanceByIndex then return end
    local index = 0
    while index < MAX_EJ_INSTANCES do
        index = index + 1
        local instanceID, name = EJ_GetInstanceByIndex(index, isRaid)
        if not instanceID then break end
        if name and name ~= "" then
            out[normalizeZoneName(name)] = { name = name, reason = reason }
        end
    end
end

-- Builds the locked/default invalid zone list: common PvP zones, this
-- season's Mythic dungeons and raids (via the Encounter Journal, so it
-- tracks whatever season is currently live without a manual update), and
-- Delves.
local function buildLockedInvalidZones()
    local out = {}
    for _, zoneName in ipairs(PVP_ZONE_NAMES) do
        out[normalizeZoneName(zoneName)] = { name = zoneName, reason = GP.L["PvP Area"] }
    end

    if EncounterJournal_LoadUI then
        GP:SafeCall(EncounterJournal_LoadUI)
    end
    collectEncounterJournalZones(out, false, GP.L["Seasonal Dungeon"])
    collectEncounterJournalZones(out, true, GP.L["Seasonal Raid"])

    out[normalizeZoneName("Delves")] = { name = "Delves", reason = GP.L["Delves"] }
    return out
end

-- Built lazily (first read, not on addon load) and cached in memory only —
-- rebuilding just re-reads the Encounter Journal / static PvP list, so
-- there's nothing worth persisting to SavedVariables. `RefreshLockedInvalidZones`
-- below lets Settings force a rebuild if the Encounter Journal wasn't ready
-- the first time (e.g. the first call this login happened before its UI loaded).
local lockedInvalidZonesCache

local function getLockedInvalidZones()
    if not lockedInvalidZonesCache then
        lockedInvalidZonesCache = buildLockedInvalidZones()
    end
    return lockedInvalidZonesCache
end

-- ---------------------------------------------------------------------------
-- Recruitment filters — class/race/level candidate criteria
-- ---------------------------------------------------------------------------
-- Saved filters combine class + race + a level range into one record, which
-- keeps recruiter-facing criteria easy to scan and reason about.

-- Built lazily and cached in memory only, same reasoning as the locked
-- invalid-zone list above: cheap to rebuild, nothing worth persisting.
local classListCache, raceListCache

-- Ordered by GetClassInfo's own index (WoW's standard class list order),
-- not alphabetically — matches how class lists are conventionally
-- presented elsewhere in WoW's own UI.
local function buildClassList()
    local out = {}
    for i = 1, GetNumClasses() do
        local name, classFile = GetClassInfo(i)
        if name and classFile then
            table.insert(out, { id = classFile, name = name })
        end
    end
    return out
end

-- Race faction metadata for the filter editor. Blizzard's race-info API
-- gives us race names for every race ID, but not faction availability, and
local RACE_NAME_FACTIONS = {
    ["human"] = "Alliance",
    ["dwarf"] = "Alliance",
    ["night elf"] = "Alliance",
    ["gnome"] = "Alliance",
    ["draenei"] = "Alliance",
    ["worgen"] = "Alliance",
    ["void elf"] = "Alliance",
    ["lightforged draenei"] = "Alliance",
    ["dark iron dwarf"] = "Alliance",
    ["kul tiran"] = "Alliance",
    ["mechagnome"] = "Alliance",

    ["orc"] = "Horde",
    ["undead"] = "Horde",
    ["tauren"] = "Horde",
    ["troll"] = "Horde",
    ["blood elf"] = "Horde",
    ["goblin"] = "Horde",
    ["nightborne"] = "Horde",
    ["highmountain tauren"] = "Horde",
    ["mag'har orc"] = "Horde",
    ["zandalari troll"] = "Horde",
    ["vulpera"] = "Horde",

    ["pandaren"] = "Both",
    ["dracthyr"] = "Both",
    ["earthen"] = "Both",
    ["haranir"] = "Both",
}

-- Defensive cap, same reasoning as MAX_EJ_INSTANCES above — real race ID
-- values top out well under this even counting every allied race.
local MAX_RACE_ID = 130

local function buildRaceList()
    local byName = {}
    local order = {}
    local myFaction = GP:SafeOptionalString(GP:SafeCall(UnitFactionGroup, nil, "player"))
    for raceID = 1, MAX_RACE_ID do
        local raceInfo = GP:SafeCall(C_CreatureInfo.GetRaceInfo, nil, raceID)
        local raceName = raceInfo and raceInfo.raceName
        local normalized = raceName and trim(raceName):lower()
        local faction = normalized and RACE_NAME_FACTIONS[normalized]
        if raceName and faction then
            local item = byName[normalized]
            if not item then
                item = {
                    id = "race:" .. normalized:gsub("%s+", "-"),
                    name = raceName,
                    faction = faction,
                    ids = {},
                    oppositeFaction = myFaction and faction ~= "Both" and faction ~= myFaction or false,
                }
                byName[normalized] = item
                table.insert(order, item)
            end
            table.insert(item.ids, raceID)
        end
    end
    table.sort(order, function(a, b)
        if a.oppositeFaction ~= b.oppositeFaction then return not a.oppositeFaction end
        return a.name < b.name
    end)
    return order
end

local function getClassList()
    if not classListCache then classListCache = buildClassList() end
    return classListCache
end

local function getRaceList()
    if not raceListCache then raceListCache = buildRaceList() end
    return raceListCache
end

local function filterID(name)
    local normalized = trim(name):lower():gsub("%s+", "-"):gsub("[^%w%-_]", "")
    if normalized == "" then return nil end
    return "filter:" .. normalized
end

local function raceIDsByName()
    local out = {}
    for _, race in ipairs(getRaceList()) do
        local key = trim(race.name):lower()
        out[key] = out[key] or {}
        for _, id in ipairs(race.ids or { race.id }) do
            if type(id) == "number" then table.insert(out[key], id) end
        end
    end
    return out
end

local function displayNameFromFullName(name)
    name = trim(name)
    if name == "" then return "" end
    local currentRealm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    if currentRealm and currentRealm ~= "" then
        local short, realm = name:match("^(.-)%-(.+)$")
        if short and realm == currentRealm then return short end
    end
    return name
end

-- Pattern-building now goes through the shared
-- GP:BuildChatPattern()/GP:BuildChatNeedle() helpers (Core/ChatPattern.lua)
local function addSystemPattern(target, outcome, reason, value)
    local pattern = GP:BuildChatPattern(value)
    if pattern then
        table.insert(target, { outcome = outcome, reason = reason, pattern = pattern, needle = GP:BuildChatNeedle(value) })
    end
end

-- Hand-written fallback patterns paired with an explicit needle so they get
-- the same pre-filter benefit as the format-string-derived ones above.
local function addLiteralSystemPattern(target, outcome, reason, pattern, needle)
    table.insert(target, { outcome = outcome, reason = reason, pattern = pattern, needle = needle })
end

local function getInviteOutcomeSystemPatterns()
    if INVITE_OUTCOME_SYSTEM_PATTERNS then return INVITE_OUTCOME_SYSTEM_PATTERNS end
    local patterns = {}
    addSystemPattern(patterns, "declined", GP.L["Invite declined."], _G.ERR_GUILD_DECLINE_S)
    addSystemPattern(patterns, "failed", GP.L["Player is already in a guild."], _G.ERR_ALREADY_IN_GUILD_S or _G.ERR_ALREADY_IN_GUILD)
    addSystemPattern(patterns, "failed", GP.L["Player is already in your guild."], _G.ERR_ALREADY_IN_YOUR_GUILD_S)
    addSystemPattern(patterns, "failed", GP.L["Player already has a pending guild invite."], _G.ERR_ALREADY_INVITED_TO_GUILD_S)
    addSystemPattern(patterns, "failed", GP.L["Player not found."], _G.ERR_CHAT_PLAYER_NOT_FOUND_S or _G.ERR_PLAYER_NOT_FOUND_S)
    addSystemPattern(patterns, "failed", GP.L["Player is not currently playing WoW."], _G.ERR_NOT_PLAYING_WOW_S)
    addSystemPattern(patterns, "failed", GP.L["Player is ignoring you."], _G.ERR_IGNORING_YOU_S)
    addSystemPattern(patterns, "accepted", GP.L["Tracked recruit joined."], _G.GUILD_EVENT_PLAYER_JOINED or _G.ERR_GUILD_JOIN_S or _G.GUILD_JOIN_S)

    addLiteralSystemPattern(patterns, "declined", GP.L["Invite declined."], "^(.+) declines your guild invitation%.$", "declines your guild invitation")
    addLiteralSystemPattern(patterns, "declined", GP.L["Invite declined."], "^(.+) declined the guild invite%.$", "declined the guild invite")
    addLiteralSystemPattern(patterns, "failed", GP.L["Player is already in a guild."], "^(.+) is already in a guild%.$", "is already in a guild")
    addLiteralSystemPattern(patterns, "failed", GP.L["Player is already in your guild."], "^(.+) is already in your guild%.$", "is already in your guild")
    addLiteralSystemPattern(patterns, "failed", GP.L["Player already has a pending guild invite."], "^(.+) has already been invited to a guild%.$", "has already been invited to a guild")
    addLiteralSystemPattern(patterns, "failed", GP.L["Player already has a pending guild invite."], "^(.+) is already invited to a guild%.$", "is already invited to a guild")
    addLiteralSystemPattern(patterns, "failed", GP.L["Player is ignoring you."], "^(.+) is ignoring you%.$", "is ignoring you")
    INVITE_OUTCOME_SYSTEM_PATTERNS = patterns
    return INVITE_OUTCOME_SYSTEM_PATTERNS
end

local function compactQueryPart(prefix, label)
    label = trim(label)
    if label == "" then return "" end
    if label:find("%s") then
        return string.format('%s"%s"', prefix, label)
    end
    return prefix .. label
end

local function scannerQueryText(query)
    local parts = {}
    if query.raceName then table.insert(parts, compactQueryPart("r-", query.raceName)) end
    if query.className then table.insert(parts, compactQueryPart("c-", query.className)) end
    table.insert(parts, string.format("%d-%d", query.minLevel, query.maxLevel))
    return table.concat(parts, " ")
end

local function scannerQueryLabel(query)
    local parts = {}
    if query.raceName then table.insert(parts, query.raceName) end
    if query.className then table.insert(parts, query.className) end
    table.insert(parts, string.format(GP.L["Level %s-%s"], query.minLevel, query.maxLevel))
    return table.concat(parts, " ")
end

local function scannerQueryKey(query)
    if not query then return nil end
    local text = trim(query.text or scannerQueryText(query)):lower()
    if text == "" then return nil end
    return text
end

local function makeScannerQuery(minLevel, maxLevel, className, raceName, refined)
    local query = {
        minLevel = tonumber(minLevel) or 1,
        maxLevel = tonumber(maxLevel) or tonumber(minLevel) or 1,
        className = className,
        raceName = raceName,
        refined = refined and true or false,
    }
    query.text = scannerQueryText(query)
    query.label = scannerQueryLabel(query)
    return query
end

local function addScannerQuery(out, keys, query)
    local key = scannerQueryKey(query)
    if not key or keys[key] or #out >= MAX_SCANNER_QUERIES then return false end
    keys[key] = true
    table.insert(out, query)
    return true
end

local scannerState = {
    status = "idle",
    queries = {},
    queryKeys = {},
    queryIndex = 0,
    rawResults = 0,
    candidates = {},
    queue = {},
    queueOrder = {},
    selectedQueueID = nil,
    executorMode = DEFAULT_EXECUTOR_MODE,
    executorStatus = "idle",
    executorLastError = nil,
    executorToken = 0,
    executorProcessed = 0,
    executorSent = 0,
    executorSkipped = 0,
    executorFailed = 0,
    executorStartedAt = nil,
    executorFinishedAt = nil,
    skipped = {},
    lastQuery = "",
    lastError = nil,
    waiting = false,
    token = 0,
    friendsFrameHadWhoEvent = false,
    nextQueryAvailableAt = 0,
    startedAt = nil,
    finishedAt = nil,
    scannerAnalyticsRecorded = false,
    executorAnalyticsRecorded = false,
}

local function copyCandidate(record)
    if type(record) ~= "table" then return nil end
    return {
        id = record.id,
        fullName = record.fullName,
        name = record.name,
        level = record.level,
        classFile = record.classFile,
        className = record.className,
        raceID = record.raceID,
        raceName = record.raceName,
        zone = record.zone,
        guild = record.guild,
        reason = record.reason,
        query = record.query,
        addedAt = record.addedAt,
        queuedAt = record.queuedAt,
        queuedFromSkipped = record.queuedFromSkipped and true or false,
    }
end

local function copyScannerRows(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        table.insert(out, copyCandidate(row))
    end
    return out
end

local function rebuildQueueOrder()
    scannerState.queueOrder = {}
    for id in pairs(scannerState.queue or {}) do
        table.insert(scannerState.queueOrder, id)
    end
    table.sort(scannerState.queueOrder, function(a, b)
        local left = scannerState.queue[a]
        local right = scannerState.queue[b]
        return (left and (left.queuedAt or left.addedAt) or 0) < (right and (right.queuedAt or right.addedAt) or 0)
    end)
end

local function getFirstQueuedCandidate()
    if scannerState.selectedQueueID then
        local selected = scannerState.queue[scannerState.selectedQueueID]
        if selected then return selected end
        scannerState.selectedQueueID = nil
    end
    for _, id in ipairs(scannerState.queueOrder or {}) do
        local candidate = scannerState.queue[id]
        if candidate then return candidate end
    end
    return nil
end

local function getExecutorModeLabel(mode)
    if mode == EXECUTOR_MODE_INVITE then return GP.L["Invite"] end
    if mode == EXECUTOR_MODE_WHISPER then return GP.L["Whisper"] end
    return GP.L["Whisper + Invite"]
end

local function isValidExecutorMode(mode)
    return mode == EXECUTOR_MODE_INVITE or mode == EXECUTOR_MODE_WHISPER or mode == EXECUTOR_MODE_WHISPER_INVITE
end

local function modeUsesInvite(mode)
    return mode == EXECUTOR_MODE_INVITE or mode == EXECUTOR_MODE_WHISPER_INVITE
end

local function modeUsesWhisper(mode)
    return mode == EXECUTOR_MODE_WHISPER or mode == EXECUTOR_MODE_WHISPER_INVITE
end

local function resetExecutorState(status)
    scannerState.executorStatus = status or "idle"
    scannerState.executorLastError = nil
    scannerState.executorProcessed = 0
    scannerState.executorSent = 0
    scannerState.executorSkipped = 0
    scannerState.executorFailed = 0
    scannerState.executorStartedAt = nil
    scannerState.executorFinishedAt = nil
    scannerState.executorAnalyticsRecorded = false
end

local function removeScannerCandidateByID(id)
    for index, candidate in ipairs(scannerState.candidates) do
        if candidate.id == id then
            table.remove(scannerState.candidates, index)
            return candidate
        end
    end
    return nil
end

local function removeScannerSkippedByID(id)
    for index, candidate in ipairs(scannerState.skipped) do
        if candidate.id == id then
            table.remove(scannerState.skipped, index)
            return candidate
        end
    end
    return nil
end

local function hasScannerCandidate(id)
    for _, candidate in ipairs(scannerState.candidates) do
        if candidate.id == id then return true end
    end
    return false
end

local function hasScannerSkipped(id)
    for _, candidate in ipairs(scannerState.skipped) do
        if candidate.id == id then return true end
    end
    return false
end

local function consumeQueuedCandidate(id)
    if not id or not scannerState.queue[id] then return nil end
    local candidate = scannerState.queue[id]
    scannerState.queue[id] = nil
    if scannerState.selectedQueueID == id then scannerState.selectedQueueID = nil end
    rebuildQueueOrder()
    return candidate
end

local function recordScannerAnalytics(status)
    if scannerState.scannerAnalyticsRecorded then return end
    local guildKey = scannerState.guildKey
    if not guildKey then return end
    scannerState.scannerAnalyticsRecorded = true
    if status == "complete" then
        bumpAnalytics(guildKey, "scansCompleted", 1)
    elseif status == "stopped" then
        bumpAnalytics(guildKey, "scansStopped", 1)
    elseif status == "error" then
        bumpAnalytics(guildKey, "scanErrors", 1)
    end
    addAnalyticsSession(guildKey, {
        type = "scan",
        status = status,
        startedAt = scannerState.startedAt,
        endedAt = scannerState.finishedAt or now(),
        queries = scannerState.queryIndex or 0,
        queryTotal = #(scannerState.queries or {}),
        results = scannerState.rawResults or 0,
        candidates = #(scannerState.candidates or {}),
        queued = #(scannerState.queueOrder or {}),
        skipped = #(scannerState.skipped or {}),
        error = status ~= "complete" and scannerState.lastError or nil,
    })
end

local function recordExecutorAnalytics(status)
    if scannerState.executorAnalyticsRecorded then return end
    local guildKey = scannerState.guildKey
    if not guildKey then return end
    scannerState.executorAnalyticsRecorded = true
    if status == "complete" then
        bumpAnalytics(guildKey, "executorCompleted", 1)
    elseif status == "stopped" then
        bumpAnalytics(guildKey, "executorStopped", 1)
    elseif status == "error" then
        bumpAnalytics(guildKey, "executorErrors", 1)
    end
    addAnalyticsSession(guildKey, {
        type = "executor",
        status = status,
        mode = scannerState.executorMode,
        startedAt = scannerState.executorStartedAt,
        endedAt = scannerState.executorFinishedAt or now(),
        processed = scannerState.executorProcessed or 0,
        sent = scannerState.executorSent or 0,
        skipped = scannerState.executorSkipped or 0,
        failed = scannerState.executorFailed or 0,
        error = status ~= "complete" and scannerState.executorLastError or nil,
    })
end

local function addScannerRow(target, record)
    record.id = record.id or recordID(record.fullName or record.name) or tostring(#target + 1)
    record.addedAt = record.addedAt or now()
    table.insert(target, record)
end

local function copyFilterRecord(record)
    if type(record) ~= "table" then return nil end
    local classes, races = {}, {}
    for id in pairs(record.classes or {}) do classes[id] = true end
    for id in pairs(record.races or {}) do races[id] = true end
    return {
        id = record.id,
        active = record.active and true or false,
        name = record.name,
        classes = classes,
        races = races,
        minLevel = record.minLevel,
        maxLevel = record.maxLevel,
        selected = record.selected and true or false,
        createdAt = record.createdAt,
        createdBy = record.createdBy,
        updatedAt = record.updatedAt,
        updatedBy = record.updatedBy,
        removedAt = record.removedAt,
        removedBy = record.removedBy,
    }
end

-- Lean copy only (id/title/body) — this is a point-in-time snapshot of the
-- guild master's *approved* messages for locked/enforced guilds, not the
local function copyMessageSnapshot(messages)
    local out = {}
    if type(messages) == "table" then
        for _, m in ipairs(messages) do
            table.insert(out, { id = m.id, title = m.title, body = m.body })
        end
    end
    return out
end

local function copyFilterSnapshot(filters)
    local out = {}
    if type(filters) == "table" then
        for _, filter in ipairs(filters) do
            local classes, races = {}, {}
            for id in pairs(filter.classes or {}) do classes[id] = true end
            for id in pairs(filter.races or {}) do races[id] = true end
            table.insert(out, {
                id = filter.id,
                name = filter.name,
                classes = classes,
                races = races,
                minLevel = filter.minLevel,
                maxLevel = filter.maxLevel,
            })
        end
    end
    return out
end

-- Note: no welcomeGuild/welcomeGuildMessage/welcomeWhisper/
-- welcomeWhisperMessage fields here — Follow-up welcome messages are a
-- personal-per-client preference, not something the guild master can
-- enforce/lock for other officers. SaveFollowUpSettings owns these values;
-- ApplyGuildSettingsIfEnforced deliberately no longer touches them.
local function copyGuildSettings(settings)
    if type(settings) ~= "table" then return nil end
    return {
        enforced = settings.enforced and true or false,
        manualReview = true,
        requireOfficer = settings.requireOfficer and true or false,
        obeyBlockInvites = settings.obeyBlockInvites and true or false,
        antiSpam = settings.antiSpam and true or false,
        antiSpamDays = tonumber(settings.antiSpamDays) or 14,
        pendingTimeoutDays = tonumber(settings.pendingTimeoutDays) or 7,
        messageDelay = tonumber(settings.messageDelay) or 0.5,
        executorMode = isValidExecutorMode(settings.executorMode) and settings.executorMode or DEFAULT_EXECUTOR_MODE,
        lockMessages = settings.lockMessages and true or false,
        lockFilters = settings.lockFilters and true or false,
        messages = copyMessageSnapshot(settings.messages),
        selectedMessageID = settings.selectedMessageID,
        filters = copyFilterSnapshot(settings.filters),
        selectedFilterID = settings.selectedFilterID,
    }
end

local function normalizeSettings(settings)
    if settings.requireOfficer == nil then settings.requireOfficer = false end
    if settings.manualReview == nil then settings.manualReview = true end
    if settings.obeyBlockInvites == nil then settings.obeyBlockInvites = true end
    if settings.antiSpam == nil then settings.antiSpam = true end
    settings.antiSpamDays = tonumber(settings.antiSpamDays) or 14
    if settings.antiSpamDays < 1 then settings.antiSpamDays = 1 end
    if settings.antiSpamDays > 365 then settings.antiSpamDays = 365 end
    settings.pendingTimeoutDays = tonumber(settings.pendingTimeoutDays) or 7
    if settings.pendingTimeoutDays < 1 then settings.pendingTimeoutDays = 1 end
    if settings.pendingTimeoutDays > 365 then settings.pendingTimeoutDays = 365 end
    settings.messageDelay = tonumber(settings.messageDelay) or 0.5
    if settings.messageDelay < 0.2 then settings.messageDelay = 0.2 end
    if settings.messageDelay > 5 then settings.messageDelay = 5 end
    if settings.retailContextMenus == nil then settings.retailContextMenus = false end
    if settings.welcomeGuild == nil then settings.welcomeGuild = false end
    if settings.welcomeGuildMessage == nil then settings.welcomeGuildMessage = GP.L["Welcome PLAYERNAME to GUILDNAME!"] end
    if settings.welcomeWhisper == nil then settings.welcomeWhisper = false end
    if settings.welcomeWhisperMessage == nil then settings.welcomeWhisperMessage = GP.L["Welcome to GUILDNAME, PLAYERNAME!"] end
    if not isValidExecutorMode(settings.executorMode) then settings.executorMode = DEFAULT_EXECUTOR_MODE end
    if settings.lockMessages == nil then settings.lockMessages = false end
    if settings.lockFilters == nil then settings.lockFilters = false end
    settings.manualReview = true
    settings.scannerEnabled = false
    settings.inviteQueueEnabled = false
end

local function copyBlacklistRecord(record)
    if type(record) ~= "table" then return nil end
    return {
        id = record.id,
        active = record.active and true or false,
        name = record.name,
        reason = record.reason,
        addedAt = record.addedAt,
        addedBy = record.addedBy,
        source = record.source,
        expiresAt = record.expiresAt,
        removedAt = record.removedAt,
        removedBy = record.removedBy,
    }
end

local function copyPendingInviteRecord(record)
    if type(record) ~= "table" then return nil end
    return {
        id = record.id,
        active = record.active and true or false,
        status = record.status,
        name = record.name,
        normalizedName = record.normalizedName,
        contactedAt = record.contactedAt,
        updatedAt = record.updatedAt,
        resolvedAt = record.resolvedAt,
        contactedBy = record.contactedBy,
        source = record.source,
        mode = record.mode,
        whisperSent = record.whisperSent and true or false,
        inviteSent = record.inviteSent and true or false,
        messageID = record.messageID,
        messageTitle = record.messageTitle,
        level = record.level,
        classFile = record.classFile,
        className = record.className,
        raceID = record.raceID,
        raceName = record.raceName,
        zone = record.zone,
        guild = record.guild,
        query = record.query,
        attempts = record.attempts,
        outcome = record.outcome,
        outcomeReason = record.outcomeReason,
        lastError = record.lastError,
    }
end

local function copyBanRecordAsBlacklist(record)
    if type(record) ~= "table" then return nil end
    return {
        id = "ban:" .. tostring(record.id or record.guid or record.name or ""),
        active = record.active and true or false,
        name = record.name,
        reason = GP.L["On Ban List"],
        addedAt = record.bannedAt,
        addedBy = record.bannedBy,
        source = "banList",
        readOnly = true,
        banID = record.id,
    }
end

local function cleanupExpiredAntiSpamBlacklist(guildKey, data)
    if not guildKey or type(data) ~= "table" then return 0 end
    local currentTime = now()
    local settings = GP:GetModule("Recruitment"):GetSettings()
    local removed = 0
    local added = 0
    for id, record in pairs(data.antiSpam or {}) do
        local contactedAt = tonumber(record and record.contactedAt)
        local expiresAt = contactedAt and (contactedAt + ((tonumber(settings.antiSpamDays) or 14) * 86400)) or nil
        if contactedAt and expiresAt and expiresAt > currentTime then
            local blacklistRecord = data.blacklist and data.blacklist[id]
            if not blacklistRecord or not blacklistRecord.active or blacklistRecord.source ~= "antiSpam" then
                data.blacklist[id] = {
                    id = id,
                    active = true,
                    name = record.name,
                    reason = GP.L["Antispam"],
                    addedAt = contactedAt,
                    addedBy = record.addedBy or GP.L["Unknown"],
                    source = "antiSpam",
                    expiresAt = expiresAt,
                }
                data.blacklistUpdated[id] = currentTime
                added = added + 1
                GP:SendMessage("GuildParagon_RecruitmentBlacklistChanged", guildKey, id, copyBlacklistRecord(data.blacklist[id]), currentTime)
            end
        elseif contactedAt then
            data.antiSpam[id] = nil
            data.antiSpamUpdated[id] = currentTime
        end
    end
    for id, record in pairs(data.blacklist or {}) do
        if record and record.active and record.source == "antiSpam" and tonumber(record.expiresAt) and tonumber(record.expiresAt) <= currentTime then
            record.active = false
            record.removedAt = currentTime
            record.removedBy = GP.L["Anti-spam expired"]
            data.blacklistUpdated[id] = currentTime
            removed = removed + 1
            GP:SendMessage("GuildParagon_RecruitmentBlacklistChanged", guildKey, id, copyBlacklistRecord(record), currentTime)
        end
    end
    if removed > 0 or added > 0 then
        GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
    end
    return removed + added
end

local function copyMessageRecord(record)
    if type(record) ~= "table" then return nil end
    return {
        id = record.id,
        active = record.active and true or false,
        title = record.title,
        body = record.body,
        selected = record.selected and true or false,
        locked = record.locked and true or false,
        createdAt = record.createdAt,
        createdBy = record.createdBy,
        updatedAt = record.updatedAt,
        updatedBy = record.updatedBy,
        removedAt = record.removedAt,
        removedBy = record.removedBy,
    }
end

local function canGuildInvite()
    if C_GuildInfo and C_GuildInfo.CanGuildInvite then
        return GP:SafeBool(GP:SafeCall(C_GuildInfo.CanGuildInvite, false), false)
    end
    if CanGuildInvite then
        return GP:SafeBool(GP:SafeCall(CanGuildInvite, false), false)
    end
    return false
end

local function isChatTemporarilyRestricted()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and locked then return true end
    end
    if GetCVarBool then
        local ok, restricted = pcall(GetCVarBool, "addonChatRestrictionsForced")
        if ok and restricted then return true end
    end
    return false
end

local function sendRecruitmentWhisper(target, message)
    if not SendChatMessage then return false, GP.L["Whisper API is not available."] end
    if isChatTemporarilyRestricted() then
        return false, GP.L["Chat is temporarily restricted."]
    end
    local ok, err = pcall(SendChatMessage, message, "WHISPER", nil, target)
    if not ok then return false, tostring(err or GP.L["Unknown error."]) end
    return true
end

local function sendGuildInvite(target)
    if C_GuildInfo and C_GuildInfo.Invite then
        local ok, err = pcall(C_GuildInfo.Invite, target)
        if not ok then return false, tostring(err or GP.L["Unknown error."]) end
        return true
    end
    if GuildInvite then
        local ok, err = pcall(GuildInvite, target)
        if not ok then return false, tostring(err or GP.L["Unknown error."]) end
        return true
    end
    return false, GP.L["Guild invite API is not available."]
end

local function sendGuildWelcome(message)
    if not SendChatMessage then return false, GP.L["Chat message API is not available."] end
    if isChatTemporarilyRestricted() then
        return false, GP.L["Chat is temporarily restricted."]
    end
    local ok, err = pcall(SendChatMessage, message, "GUILD")
    if not ok then return false, tostring(err or GP.L["Unknown error."]) end
    return true
end

function Recruitment:CanUse()
    local settings = self:GetSettings()
    if settings.requireOfficer and not GP:IsOfficer() then return false end
    return IsInGuild and IsInGuild() and canGuildInvite()
end

function Recruitment:OnEnable()
    self:RegisterEvent("WHO_LIST_UPDATE", "OnWhoListUpdate")
    self:RegisterEvent("CHAT_MSG_SYSTEM", "OnChatMsgSystem")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStarted")
    self:RegisterEvent("PLAYER_LEAVING_WORLD", "OnLeavingWorld")
end

function Recruitment:GetCurrentGuildKey()
    return select(1, currentGuild())
end

function Recruitment:GetSettings()
    GP.db.profile.recruitment = GP.db.profile.recruitment or {}
    local settings = GP.db.profile.recruitment
    normalizeSettings(settings)
    self:ApplyGuildSettingsIfEnforced(settings)
    normalizeSettings(settings)
    return settings
end

function Recruitment:AreSettingsLocked()
    if GP:IsGuildMaster() then return false end
    local _, guildData = currentGuild()
    local data = guildData and ensureRecruitment(guildData)
    return data and data.gmSettings and data.gmSettings.enforced and true or false
end

function Recruitment:ApplyGuildSettingsIfEnforced(settings)
    if GP:IsGuildMaster() then return false end
    local _, guildData = currentGuild()
    local data = guildData and ensureRecruitment(guildData)
    local gmSettings = data and data.gmSettings
    if type(gmSettings) ~= "table" or not gmSettings.enforced then
        settings.gmEnforced = false
        return false
    end

    settings.gmEnforced = true
    settings.requireOfficer = gmSettings.requireOfficer and true or false
    settings.manualReview = true
    settings.obeyBlockInvites = gmSettings.obeyBlockInvites and true or false
    settings.antiSpam = gmSettings.antiSpam and true or false
    settings.antiSpamDays = tonumber(gmSettings.antiSpamDays) or settings.antiSpamDays
    settings.pendingTimeoutDays = tonumber(gmSettings.pendingTimeoutDays) or settings.pendingTimeoutDays
    settings.messageDelay = tonumber(gmSettings.messageDelay) or settings.messageDelay
    settings.executorMode = isValidExecutorMode(gmSettings.executorMode) and gmSettings.executorMode or DEFAULT_EXECUTOR_MODE
    -- welcomeGuild/welcomeGuildMessage/welcomeWhisper/welcomeWhisperMessage
    -- deliberately not overridden here — Follow-up welcome messages are a
    -- personal-per-client preference, not guild-master-enforceable. See
    -- Recruitment:SaveFollowUpSettings.
    settings.lockMessages = gmSettings.lockMessages and true or false
    settings.lockFilters = gmSettings.lockFilters and true or false
    return true
end

function Recruitment:SaveSettings(values)
    if self:AreSettingsLocked() then
        return false, GP.L["Guild-master recruitment defaults are active."]
    end

    local settings = self:GetSettings()
    settings.requireOfficer = values.requireOfficer and true or false
    settings.manualReview = true
    settings.obeyBlockInvites = values.obeyBlockInvites and true or false
    settings.antiSpam = values.antiSpam and true or false
    settings.antiSpamDays = tonumber(values.antiSpamDays) or settings.antiSpamDays
    settings.pendingTimeoutDays = tonumber(values.pendingTimeoutDays) or settings.pendingTimeoutDays
    settings.messageDelay = tonumber(values.messageDelay) or settings.messageDelay
    settings.executorMode = isValidExecutorMode(values.executorMode) and values.executorMode or settings.executorMode
    if values.retailContextMenus ~= nil then settings.retailContextMenus = values.retailContextMenus and true or false end
    settings.welcomeGuild = values.welcomeGuild and true or false
    settings.welcomeGuildMessage = trim(values.welcomeGuildMessage or settings.welcomeGuildMessage)
    settings.welcomeWhisper = values.welcomeWhisper and true or false
    settings.welcomeWhisperMessage = trim(values.welcomeWhisperMessage or settings.welcomeWhisperMessage)
    settings.lockMessages = values.lockMessages and true or false
    settings.lockFilters = values.lockFilters and true or false
    self:GetSettings()
    scannerState.executorMode = settings.executorMode

    local guildKey, guildData = currentGuild()
    if values.gmEnforced ~= nil and GP:IsGuildMaster() then
        settings.gmEnforced = values.gmEnforced and true or false
        if guildKey and guildData then
            local data = ensureRecruitment(guildData)
            data.gmSettings = {
                enforced = settings.gmEnforced,
                manualReview = true,
                requireOfficer = settings.requireOfficer,
                obeyBlockInvites = settings.obeyBlockInvites,
                antiSpam = settings.antiSpam,
                antiSpamDays = settings.antiSpamDays,
                pendingTimeoutDays = settings.pendingTimeoutDays,
                messageDelay = settings.messageDelay,
                executorMode = settings.executorMode,
                -- No welcomeGuild/welcomeGuildMessage/welcomeWhisper/
                -- welcomeWhisperMessage here — see copyGuildSettings' note.
                lockMessages = settings.lockMessages,
                lockFilters = settings.lockFilters,
            }
            data.gmSettingsUpdated = nextSettingsSyncTs()
            if settings.gmEnforced and (settings.lockMessages or settings.lockFilters) then
                -- Rebuilds any locked GM-owned snapshots from the current
                -- local records, then sends one settings payload containing
                pushRecruitmentSnapshotsIfNeeded(guildKey, guildData)
            else
                GP:SendMessage("GuildParagon_RecruitmentSettingsChanged", guildKey, copyGuildSettings(data.gmSettings), data.gmSettingsUpdated)
            end
        end
    end

    GP:SendMessage("GuildParagon_RecruitmentChanged")
    return true
end

function Recruitment:SaveRetailContextMenuSetting(value)
    local settings = self:GetSettings()
    local previous = settings.retailContextMenus and true or false
    settings.retailContextMenus = value and true or false
    GP:SendMessage("GuildParagon_RecruitmentChanged")

    local RecruitmentContext = GP:GetModule("RecruitmentContext", true)
    if RecruitmentContext and RecruitmentContext.RefreshRetailIntegration then
        RecruitmentContext:RefreshRetailIntegration()
    end

    if previous and not settings.retailContextMenus then
        return true, GP.L["Retail right-click shortcuts disabled. Reload UI to fully detach the Blizzard menu hook."]
    end
    return true
end

function Recruitment:SaveFollowUpSettings(values)
    local settings = self:GetSettings()
    settings.welcomeGuild = values.welcomeGuild and true or false
    settings.welcomeGuildMessage = trim(values.welcomeGuildMessage or settings.welcomeGuildMessage)
    settings.welcomeWhisper = values.welcomeWhisper and true or false
    settings.welcomeWhisperMessage = trim(values.welcomeWhisperMessage or settings.welcomeWhisperMessage)
    GP:SendMessage("GuildParagon_RecruitmentChanged")
    return true
end

function Recruitment:SaveRequireOfficer(value)
    local settings = self:GetSettings()
    return self:SaveSettings({
        requireOfficer = value,
        obeyBlockInvites = settings.obeyBlockInvites,
        antiSpam = settings.antiSpam,
        antiSpamDays = settings.antiSpamDays,
        pendingTimeoutDays = settings.pendingTimeoutDays,
        messageDelay = settings.messageDelay,
        executorMode = settings.executorMode,
        welcomeGuild = settings.welcomeGuild,
        welcomeGuildMessage = settings.welcomeGuildMessage,
        welcomeWhisper = settings.welcomeWhisper,
        welcomeWhisperMessage = settings.welcomeWhisperMessage,
        lockMessages = settings.lockMessages,
        lockFilters = settings.lockFilters,
        gmEnforced = GP:IsGuildMaster() and settings.gmEnforced or nil,
    })
end

function Recruitment:GetGuildSettingsForSync(guildKey)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil, nil end
    local data = ensureRecruitment(guildData)
    if not data.gmSettingsUpdated or data.gmSettingsUpdated <= 0 then return nil, nil end
    return copyGuildSettings(data.gmSettings), data.gmSettingsUpdated
end

function Recruitment:GetGuildSettingsUpdatedAt(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local data = guildData and ensureRecruitment(guildData)
    return data and data.gmSettingsUpdated
end

function Recruitment:SetGuildSettingsFromSync(guildKey, incoming, ts)
    if type(ts) ~= "number" or type(incoming) ~= "table" then return false end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end
    local data = ensureRecruitment(guildData)
    if data.gmSettingsUpdated and ts <= data.gmSettingsUpdated then return false end

    data.gmSettings = copyGuildSettings(incoming) or {}
    data.gmSettingsUpdated = ts
    local settings = self:GetSettings()
    self:ApplyGuildSettingsIfEnforced(settings)
    normalizeSettings(settings)
    scannerState.executorMode = settings.executorMode
    GP:SendMessage("GuildParagon_RecruitmentSettingsChanged", guildKey, copyGuildSettings(data.gmSettings), data.gmSettingsUpdated)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
    return true
end

resolveMessages = function(guildData)
    local data = ensureRecruitment(guildData)
    if Recruitment:IsMessageEditingLocked() then
        local locked = (data.gmSettings and data.gmSettings.messages) or {}
        local selectedID = data.gmSettings and data.gmSettings.selectedMessageID
        local out = {}
        for _, m in ipairs(locked) do
            out[m.id] = {
                id = m.id, active = true, title = m.title, body = m.body,
                selected = (m.id == selectedID), locked = true,
            }
        end
        return out
    end
    return data.messages
end

local function resolveFilters(guildData)
    local data = ensureRecruitment(guildData)
    if Recruitment:IsFilterEditingLocked() then
        local locked = (data.gmSettings and data.gmSettings.filters) or {}
        local selectedID = data.gmSettings and data.gmSettings.selectedFilterID
        local out = {}
        for _, filter in ipairs(locked) do
            local classes, races = {}, {}
            for id in pairs(filter.classes or {}) do classes[id] = true end
            for id in pairs(filter.races or {}) do races[id] = true end
            out[filter.id] = {
                id = filter.id, active = true, name = filter.name,
                classes = classes, races = races,
                minLevel = filter.minLevel, maxLevel = filter.maxLevel,
                selected = (filter.id == selectedID), locked = true,
            }
        end
        return out
    end
    return data.filters
end

pushRecruitmentSnapshotsIfNeeded = function(guildKey, guildData)
    if not guildKey or not GP:IsGuildMaster() then return end
    local data = ensureRecruitment(guildData)
    if not data.gmSettings or not data.gmSettings.enforced then return end

    -- Snapshot-building runs inside pcall so a bad message/filter record can
-- never silently swallow the broadcast below it. This remains useful
-- defensive hardening even though send transport is handled separately in
-- GuildSync.lua's SendRawMessage — a bad record here could still cause a
-- real, separate failure of its own.
    local ok, err = pcall(function()
        if data.gmSettings.lockMessages then
            local snapshot, selectedID = {}, nil
            for id, record in pairs(data.messages) do
                if record.active then
                    table.insert(snapshot, { id = id, title = record.title, body = record.body })
                    if record.selected then selectedID = id end
                end
            end
            data.gmSettings.messages = snapshot
            data.gmSettings.selectedMessageID = selectedID
        else
            data.gmSettings.messages = nil
            data.gmSettings.selectedMessageID = nil
        end

        if data.gmSettings.lockFilters then
            local snapshot, selectedID = {}, nil
            for id, record in pairs(data.filters) do
                if record.active then
                    table.insert(snapshot, copyFilterRecord(record))
                    if record.selected then selectedID = id end
                end
            end
            data.gmSettings.filters = snapshot
            data.gmSettings.selectedFilterID = selectedID
        else
            data.gmSettings.filters = nil
            data.gmSettings.selectedFilterID = nil
        end
    end)
    if not ok then
        GP:Print(string.format(GP.L["Guild Sync error: %s"], tostring(err)))
    end

    data.gmSettingsUpdated = nextSettingsSyncTs()
    GP:SendMessage("GuildParagon_RecruitmentSettingsChanged", guildKey, copyGuildSettings(data.gmSettings), data.gmSettingsUpdated)
end

pushMessageSnapshotIfNeeded = pushRecruitmentSnapshotsIfNeeded

function Recruitment:GetBlacklist(guildKey, search)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    local data = ensureRecruitment(guildData)
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    cleanupExpiredPendingInvites(guildKey, data)
    local query = normalizeName(search or "")
    local out = {}
    local seenNames = {}

    local function matches(name, reason)
        name = name or ""
        reason = reason or ""
        return query == "" or normalizeName(name):find(query, 1, true) or reason:lower():find(query, 1, true)
    end

    local BanList = GP:GetModule("BanList", true)
    if BanList and BanList.GetRecords then
        for _, record in ipairs(BanList:GetRecords(guildKey) or {}) do
            if record.active and matches(record.name, GP.L["On Ban List"]) then
                local row = copyBanRecordAsBlacklist(record)
                table.insert(out, row)
                seenNames[normalizeName(record.name)] = true
            end
        end
    end

    for _, record in pairs(data.blacklist) do
        if record.active then
            local name = record.name or ""
            local reason = record.reason or ""
            if not seenNames[normalizeName(name)] and matches(name, reason) then
                table.insert(out, copyBlacklistRecord(record))
            end
        end
    end

    table.sort(out, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return out
end

function Recruitment:GetBlacklistRecord(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return nil end
    local banID = tostring(id):match("^ban:(.+)$")
    if banID then
        local BanList = GP:GetModule("BanList", true)
        local record = BanList and BanList.GetRecord and BanList:GetRecord(guildKey, banID)
        return copyBanRecordAsBlacklist(record)
    end

    local data = ensureRecruitment(guildData)
    return copyBlacklistRecord(data.blacklist[id])
end

function Recruitment:RenderMessage(body, playerName, useGuildLink)
    body = trim(body)
    local guildName = getGuildDisplayName()
    local guildLink = useGuildLink and getGuildRecruitmentLink() or guildName
    local displayName = trim(playerName)
    displayName = displayName:gsub("%-.+$", "")
    if displayName == "" then displayName = GP.L["Player"] end

    local rendered = body
    rendered = rendered:gsub("PLAYERNAME", displayName)
    rendered = rendered:gsub("GUILDNAME", guildName)
    rendered = rendered:gsub("GUILDLINK", guildLink)
    rendered = rendered:gsub("{player}", displayName)
    rendered = rendered:gsub("{name}", displayName)
    rendered = rendered:gsub("{guild}", guildName)
    rendered = rendered:gsub("{guildlink}", guildLink)
    return rendered
end

function Recruitment:GetMessageLength(body, playerName)
    local rendered = self:RenderMessage(body, playerName)
    return string.len(rendered)
end

function Recruitment:ValidateMessage(body, playerName)
    body = trim(body)
    if body == "" then return false, GP.L["Type a recruitment message first."], 0 end
    local length = self:GetMessageLength(body, playerName)
    if length > MAX_MESSAGE_LENGTH then
        return false, string.format(GP.L["Recruitment message is too long (%d / %d)."], length, MAX_MESSAGE_LENGTH), length
    end
    return true, nil, length
end

function Recruitment:GetMessageLimit()
    return MAX_MESSAGE_LENGTH
end

function Recruitment:GetMessages(guildKey, search)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    local messages = resolveMessages(guildData)
    local query = trim(search or ""):lower()
    local out = {}

    for _, record in pairs(messages) do
        if record.active then
            local title = record.title or ""
            local body = record.body or ""
            if query == "" or title:lower():find(query, 1, true) or body:lower():find(query, 1, true) then
                table.insert(out, copyMessageRecord(record))
            end
        end
    end

    table.sort(out, function(a, b)
        if a.selected ~= b.selected then return a.selected end
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    return out
end

function Recruitment:GetMessageRecord(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return nil end
    return copyMessageRecord(resolveMessages(guildData)[id])
end

function Recruitment:GetSelectedMessage(guildKey)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil end
    for _, record in pairs(resolveMessages(guildData)) do
        if record.active and record.selected then
            return copyMessageRecord(record)
        end
    end
    return nil
end

function Recruitment:SendTestMessage(guildKey, id)
    if not (IsInGuild and IsInGuild()) then return false, GP.L["You must be in a guild to test recruitment messages."] end
    guildKey = guildKey or self:GetCurrentGuildKey()
    local record = id and self:GetMessageRecord(guildKey, id) or self:GetSelectedMessage(guildKey)
    if not record then return false, GP.L["Select a recruitment message first."] end

    local rendered = self:RenderMessage(record.body, getPlayerDisplayName(), true)
    if rendered == "" then return false, GP.L["Type a recruitment message first."] end
    if type(SendChatMessage) ~= "function" then return false, GP.L["Chat message API is not available."] end

    local ok, err = pcall(SendChatMessage, rendered, "WHISPER", nil, getPlayerWhisperTarget())
    if not ok then return false, err end
    return true
end

function Recruitment:IsMessageEditingLocked()
    return self:AreSettingsLocked() and self:GetSettings().lockMessages and true or false
end

function Recruitment:IsFilterEditingLocked()
    return self:AreSettingsLocked() and self:GetSettings().lockFilters and true or false
end

function Recruitment:AddOrUpdateMessage(guildKey, title, body, existingID)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if self:IsMessageEditingLocked() then return false, GP.L["The guild master has locked recruitment message templates."] end
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end

    title = trim(title)
    body = trim(body)
    if title == "" then return false, GP.L["Type a template name first."] end

    local ok, err = self:ValidateMessage(body, GP.L["Player"])
    if not ok then return false, err end

    local id = messageID(title) or existingID
    if not id then return false, GP.L["Type a template name first."] end

    local data = ensureRecruitment(guildData)
    local currentTime = now()
    local actor = UnitName and UnitName("player") or ""
    if existingID and existingID ~= id then
        data.messages[existingID] = nil
        data.messagesUpdated[existingID] = currentTime
    end

    local previous = data.messages[id]
    data.messages[id] = {
        id = id,
        active = true,
        title = title,
        body = body,
        selected = previous and previous.selected or false,
        createdAt = previous and previous.createdAt or currentTime,
        createdBy = previous and previous.createdBy or actor,
        updatedAt = currentTime,
        updatedBy = actor,
    }
    data.messagesUpdated[id] = currentTime

    pushMessageSnapshotIfNeeded(guildKey, guildData)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true, nil, id
end

function Recruitment:SetSelectedMessage(guildKey, id)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if self:IsMessageEditingLocked() then return false, GP.L["The guild master has locked recruitment message templates."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return false, GP.L["Recruitment message not found."] end
    local data = ensureRecruitment(guildData)
    if not data.messages[id] or not data.messages[id].active then return false, GP.L["Recruitment message not found."] end

    local currentTime = now()
    for messageIDKey, record in pairs(data.messages) do
        if record.selected ~= (messageIDKey == id) then
            record.selected = messageIDKey == id
            data.messagesUpdated[messageIDKey] = currentTime
        end
    end

    pushMessageSnapshotIfNeeded(guildKey, guildData)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true
end

function Recruitment:RemoveMessage(guildKey, id)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if self:IsMessageEditingLocked() then return false, GP.L["The guild master has locked recruitment message templates."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return false, GP.L["Recruitment message not found."] end
    local data = ensureRecruitment(guildData)
    local record = data.messages[id]
    if not record or not record.active then return false, GP.L["Recruitment message not found."] end

    record.active = false
    record.selected = false
    record.removedAt = now()
    record.removedBy = UnitName and UnitName("player") or ""
    data.messagesUpdated[id] = record.removedAt

    pushMessageSnapshotIfNeeded(guildKey, guildData)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true
end

function Recruitment:AddOrUpdateBlacklist(guildKey, name, reason, existingID)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end

    name = fullName(name)
    if not name then return false, GP.L["Type a character name first."] end

    local data = ensureRecruitment(guildData)
    local id = recordID(name) or existingID
    if not id then return false, GP.L["Type a character name first."] end

    local currentTime = now()
    local actor = UnitName and UnitName("player") or ""
    if existingID and existingID ~= id then
        local existing = data.blacklist[existingID]
        if existing and existing.active and existing.source == "antiSpam" then
            return false, GP.L["Anti-spam entries are managed automatically and expire after the configured cooldown."]
        end
        data.blacklist[existingID] = nil
        data.blacklistUpdated[existingID] = currentTime
    end

    local previous = data.blacklist[id]
    if previous and previous.active and previous.source == "antiSpam" then
        return false, GP.L["Anti-spam entries are managed automatically and expire after the configured cooldown."]
    end
    data.blacklist[id] = {
        id = id,
        active = true,
        name = name,
        reason = trim(reason),
        addedAt = previous and previous.addedAt or currentTime,
        addedBy = previous and previous.addedBy or actor,
    }
    data.blacklistUpdated[id] = currentTime

    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    GP:SendMessage("GuildParagon_RecruitmentBlacklistChanged", guildKey, id, copyBlacklistRecord(data.blacklist[id]), currentTime)
    return true, nil, id
end

function Recruitment:AddContextBlacklist(name)
    local ok, err = self:AddOrUpdateBlacklist(self:GetCurrentGuildKey(), name, GP.L["Manual context-menu addition."])
    if ok then
        GP:Print(string.format(GP.L["Added %s to recruitment Do Not Invite."], fullName(name) or name))
    end
    return ok, err
end

function Recruitment:RemoveBlacklist(guildKey, id)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return false, GP.L["Recruitment record not found."] end

    local data = ensureRecruitment(guildData)
    local record = data.blacklist[id]
    if not record or not record.active then return false, GP.L["Recruitment record not found."] end
    if record.source == "antiSpam" then
        return false, GP.L["Anti-spam entries are managed automatically and expire after the configured cooldown."]
    end

    record.active = false
    record.removedAt = now()
    record.removedBy = UnitName and UnitName("player") or ""
    data.blacklistUpdated[id] = record.removedAt

    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    GP:SendMessage("GuildParagon_RecruitmentBlacklistChanged", guildKey, id, copyBlacklistRecord(record), record.removedAt)
    return true
end

function Recruitment:GetBlacklistUpdatedAt(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return nil end
    local data = ensureRecruitment(guildData)
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    return data.blacklistUpdated[id]
end

function Recruitment:GetBlacklistForSync(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {}, {} end
    local data = ensureRecruitment(guildData)
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    local out = {}
    for id, record in pairs(data.blacklist or {}) do
        out[id] = copyBlacklistRecord(record)
    end
    return out, data.blacklistUpdated
end

function Recruitment:SetBlacklistFromSync(guildKey, id, record, ts)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id or type(ts) ~= "number" then return false end
    local data = ensureRecruitment(guildData)
    if type(record) == "table" then
        local copy = copyBlacklistRecord(record)
        copy.id = copy.id or id
        data.blacklist[id] = copy
    else
        data.blacklist[id] = nil
    end
    data.blacklistUpdated[id] = ts
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true
end

function Recruitment:IsDoNotInvite(guildKey, name)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end
    local data = ensureRecruitment(guildData)
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    local canonicalName = fullName(name) or name
    local id = recordID(canonicalName)
    local record = id and data.blacklist[id]
    if record and record.active then
        return true, copyBlacklistRecord(record)
    end

    local normalized = normalizeName(canonicalName)
    local BanList = GP:GetModule("BanList", true)
    if BanList and BanList.GetRecords and normalized ~= "" then
        for _, ban in ipairs(BanList:GetRecords(guildKey) or {}) do
            if ban.active and normalizeName(ban.name) == normalized then
                return true, copyBanRecordAsBlacklist(ban)
            end
        end
    end
    return false
end

function Recruitment:AddAntiSpam(guildKey, name)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end
    name = fullName(name)
    local id = recordID(name)
    if not id then return false end

    local data = ensureRecruitment(guildData)
    local settings = self:GetSettings()
    if not settings.antiSpam then return false end
    local currentTime = now()
    local expiresAt = currentTime + ((tonumber(settings.antiSpamDays) or 14) * 86400)
    data.antiSpam[id] = { id = id, name = name, contactedAt = currentTime }
    data.antiSpamUpdated[id] = currentTime
    data.blacklist[id] = {
        id = id,
        active = true,
        name = name,
        reason = GP.L["Antispam"],
        addedAt = currentTime,
        addedBy = UnitName and UnitName("player") or "",
        source = "antiSpam",
        expiresAt = expiresAt,
    }
    data.blacklistUpdated[id] = currentTime
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    GP:SendMessage("GuildParagon_RecruitmentBlacklistChanged", guildKey, id, copyBlacklistRecord(data.blacklist[id]), currentTime)
    return true
end

function Recruitment:IsAntiSpamBlocked(guildKey, name)
    local settings = self:GetSettings()
    if not settings.antiSpam then return false end

    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end
    local id = recordID(fullName(name) or name)
    if not id then return false end

    local data = ensureRecruitment(guildData)
    local record = data.antiSpam[id]
    if not record or not record.contactedAt then return false end
    local expires = record.contactedAt + (settings.antiSpamDays * 86400)
    if now() < expires then return true, record end

    data.antiSpam[id] = nil
    data.antiSpamUpdated[id] = now()
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    return false
end

cleanupExpiredPendingInvites = function(guildKey, data)
    if not guildKey or type(data) ~= "table" then return 0 end
    local settings = GP:GetModule("Recruitment"):GetSettings()
    local timeoutDays = tonumber(settings.pendingTimeoutDays) or 7
    local cutoff = now() - (timeoutDays * 86400)
    local expired = 0
    local currentTime = now()

    for id, record in pairs(data.pendingInvites or {}) do
        local contactedAt = tonumber(record and record.contactedAt)
        if record and record.active and contactedAt and contactedAt <= cutoff then
            record.active = false
            record.status = "timedout"
            record.outcome = "timedout"
            record.outcomeReason = string.format(GP.L["No response after %d day(s)."], timeoutDays)
            record.resolvedAt = currentTime
            record.updatedAt = currentTime
            data.pendingInvitesUpdated[id] = currentTime
            expired = expired + 1
            recordPendingOutcomeAnalytics(guildKey, record, "timedout", record.outcomeReason, currentTime)
        end
    end

    if expired > 0 then
        GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
    end
    return expired
end

function Recruitment:AddPendingInvite(guildKey, candidate, details)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end

    local target
    if type(candidate) == "table" then
        target = candidate.fullName or candidate.name
    else
        target = candidate
        candidate = nil
    end
    target = fullName(target)
    local id = recordID(target)
    if not id then return false end

    details = type(details) == "table" and details or {}
    local data = ensureRecruitment(guildData)
    cleanupExpiredPendingInvites(guildKey, data)
    local currentTime = now()
    local previous = data.pendingInvites[id]
    local continuing = previous and previous.active
    local record = {
        id = id,
        active = true,
        status = "pending",
        name = target,
        normalizedName = normalizeName(target),
        contactedAt = continuing and previous.contactedAt or currentTime,
        updatedAt = currentTime,
        contactedBy = UnitName and UnitName("player") or "",
        source = details.source or (candidate and candidate.source) or "executor",
        mode = details.mode,
        whisperSent = details.whisperSent and true or false,
        inviteSent = details.inviteSent and true or false,
        messageID = details.messageID,
        messageTitle = details.messageTitle,
        level = candidate and candidate.level or nil,
        classFile = candidate and candidate.classFile or nil,
        className = candidate and candidate.className or nil,
        raceID = candidate and candidate.raceID or nil,
        raceName = candidate and candidate.raceName or nil,
        zone = candidate and candidate.zone or nil,
        guild = candidate and candidate.guild or nil,
        query = candidate and candidate.query or nil,
        attempts = (previous and tonumber(previous.attempts) or 0) + 1,
        lastError = details.lastError,
    }
    data.pendingInvites[id] = record
    data.pendingInvitesUpdated[id] = currentTime

    if not continuing then
        bumpAnalytics(guildKey, "pendingCreated", 1)
    end
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true, nil, id
end

function Recruitment:ResolvePendingInvite(guildKey, name, outcome, reason)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local id = recordID(fullName(name) or name)
    if not guildData or not id then return false, GP.L["Recruitment record not found."] end

    local data = ensureRecruitment(guildData)
    local record = data.pendingInvites[id]
    if not record or not record.active then return false, GP.L["Recruitment record not found."] end

    local currentTime = now()
    record.active = false
    record.status = outcome or "resolved"
    record.outcome = outcome or "resolved"
    record.outcomeReason = reason
    record.resolvedAt = currentTime
    record.updatedAt = currentTime
    data.pendingInvitesUpdated[id] = currentTime

    recordPendingOutcomeAnalytics(guildKey, record, record.outcome, reason, currentTime)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true, nil, copyPendingInviteRecord(record)
end

local function normalizeSystemPlayerName(name)
    name = trim(name)
    if name == "" then return "" end
    name = name:gsub("|Hplayer:([^:|]+):.-|h%[[^%]]+%]|h", "%1")
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if Ambiguate then
        name = GP:SafeString(GP:SafeCall(Ambiguate, name, name, "none"), name)
    end
    return trim(name)
end

function Recruitment:FindPendingInviteFromSystemMessage(guildKey, msg, capturedName)
    msg = trim(msg)
    if msg == "" then return nil end
    local pending = self:GetPendingInvites(guildKey)
    if #pending == 0 then return nil end

    local captured = normalizeSystemPlayerName(capturedName)
    if captured ~= "" then
        local capturedID = recordID(fullName(captured) or captured)
        for _, record in ipairs(pending) do
            if capturedID and record.id == capturedID then return record end
            if normalizeName(record.name) == normalizeName(captured) then return record end
            if normalizeName(displayNameFromFullName(record.name)) == normalizeName(captured) then return record end
        end
    end

    local lowerMsg = msg:lower()
    for _, record in ipairs(pending) do
        local display = displayNameFromFullName(record.name)
        if record.name and record.name ~= "" and lowerMsg:find(record.name:lower(), 1, true) then
            return record
        end
        if display ~= "" and lowerMsg:find(display:lower(), 1, true) then
            return record
        end
    end
    return nil
end

function Recruitment:OnChatMsgSystem(_, msg)
    local guildKey = self:GetCurrentGuildKey()
    if not guildKey then return end
    msg = trim(msg)
    if msg == "" then return end

    -- Strip link/color markup once so a
    -- pattern built from the plain Blizzard format string still matches a
    local stripped = GP:StripChatLinkMarkup(msg)

    for _, spec in ipairs(getInviteOutcomeSystemPatterns()) do
        if not spec.needle or stripped:find(spec.needle, 1, true) then
            local captured = stripped:match(spec.pattern)
            if captured then
                local record = self:FindPendingInviteFromSystemMessage(guildKey, stripped, captured)
                if record then
                    if spec.outcome == "accepted" then
                        self:ResolveAcceptedPendingInvite(guildKey, nil, record.name, false)
                    else
                        self:ResolvePendingInvite(guildKey, record.name, spec.outcome, spec.reason)
                    end
                    GP:SendMessage("GuildParagon_RecruitmentOutcome", guildKey, record.name, spec.outcome, spec.reason)
                    return
                end
            end
        end
    end
end

function Recruitment:GetPendingInvite(guildKey, name)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local id = recordID(fullName(name) or name)
    if not guildData or not id then return nil end
    local data = ensureRecruitment(guildData)
    cleanupExpiredPendingInvites(guildKey, data)
    local record = data.pendingInvites[id]
    if not record or not record.active then return nil end
    return copyPendingInviteRecord(record)
end

function Recruitment:GetPendingInvites(guildKey, includeResolved)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    cleanupExpiredPendingInvites(guildKey, ensureRecruitment(guildData))
    local out = {}
    for _, record in pairs(ensureRecruitment(guildData).pendingInvites or {}) do
        if includeResolved or record.active then
            table.insert(out, copyPendingInviteRecord(record))
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.updatedAt) or 0) > (tonumber(b.updatedAt) or 0)
    end)
    return out
end

function Recruitment:GetPendingInviteCount(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return 0 end
    cleanupExpiredPendingInvites(guildKey, ensureRecruitment(guildData))
    local count = 0
    for _, record in pairs(ensureRecruitment(guildData).pendingInvites or {}) do
        if record.active then count = count + 1 end
    end
    return count
end

function Recruitment:CanBypassAntiSpamForPendingInvite(guildKey, name, mode)
    if not modeUsesInvite(mode) then return false end
    local pending = self:GetPendingInvite(guildKey, name)
    if not pending or not pending.active then return false end
    return pending.whisperSent and true or false
end

function Recruitment:GetJoinInviteAttribution(guildKey, name)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local id = recordID(fullName(name) or name)
    if not guildData or not id then return nil end

    local data = ensureRecruitment(guildData)
    cleanupExpiredPendingInvites(guildKey, data)
    local record = data.pendingInvites and data.pendingInvites[id]
    if not record or not record.inviteSent then return nil end
    if not record.active and record.outcome ~= "accepted" then return nil end

    local actor = trim(record.contactedBy or "")
    if actor == "" then actor = GP.L["Unknown"] end
    return {
        invitedBy = actor,
        invitedByMode = record.mode,
        recruitmentContact = true,
        recruitmentContactedAt = record.contactedAt,
        recruitmentResolvedAt = record.resolvedAt,
    }
end

function Recruitment:ResolveAcceptedPendingInvite(guildKey, guid, name, rejoined)
    if not guildKey or not name then return false end
    local pending = self:GetPendingInvite(guildKey, name)
    if not pending then return false end

    local settings = self:GetSettings()
    local wantsGuild = settings.welcomeGuild and self:RenderMessage(settings.welcomeGuildMessage, name, true) ~= ""
    local wantsWhisper = settings.welcomeWhisper and self:RenderMessage(settings.welcomeWhisperMessage, name, true) ~= ""

    if wantsGuild or wantsWhisper then
        local guildData = GP.db.global.guilds[guildKey]
        local data = guildData and ensureRecruitment(guildData)
        if data then
            data.awaitingWelcomeSeq = data.awaitingWelcomeSeq + 1
            table.insert(data.awaitingWelcome, {
                id = data.awaitingWelcomeSeq,
                guid = guid,
                name = name,
                ts = now(),
                wantsGuild = wantsGuild and true or false,
                wantsWhisper = wantsWhisper and true or false,
                rejoined = rejoined and true or false,
            })
        end
    end

    local reason = rejoined and GP.L["Tracked recruit rejoined."] or GP.L["Tracked recruit joined."]
    self:ResolvePendingInvite(guildKey, name, "accepted", reason)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
    return true
end

function Recruitment:HandleRosterJoin(guildKey, guid, player, rejoined)
    if not guildKey or type(player) ~= "table" then return false end
    return self:ResolveAcceptedPendingInvite(guildKey, guid, player.name, rejoined)
end

function Recruitment:GetAwaitingWelcomes(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    local data = ensureRecruitment(guildData)
    local out = {}
    for _, entry in ipairs(data.awaitingWelcome) do
        table.insert(out, {
            id = entry.id,
            guid = entry.guid,
            name = entry.name,
            ts = entry.ts,
            wantsGuild = entry.wantsGuild,
            wantsWhisper = entry.wantsWhisper,
            rejoined = entry.rejoined,
        })
    end
    return out
end

function Recruitment:GetAwaitingWelcomeCount(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return 0 end
    return #ensureRecruitment(guildData).awaitingWelcome
end

function Recruitment:SendAwaitingWelcome(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["Recruitment record not found."] end
    local data = ensureRecruitment(guildData)

    local index, entry
    for i, candidate in ipairs(data.awaitingWelcome) do
        if candidate.id == id then
            index, entry = i, candidate
            break
        end
    end
    if not entry then return false, GP.L["Recruitment record not found."] end

    local settings = self:GetSettings()
    local failures = {}
    local remainingGuild, remainingWhisper = false, false

    if entry.wantsGuild then
        local message = self:RenderMessage(settings.welcomeGuildMessage, entry.name, true)
        if message == "" then
            -- Template was cleared since queueing; nothing left to send.
        elseif string.len(message) > MAX_MESSAGE_LENGTH then
            table.insert(failures, string.format(GP.L["Recruitment message is too long (%d / %d)."], string.len(message), MAX_MESSAGE_LENGTH))
            bumpAnalytics(guildKey, "welcomeFailed", 1)
            remainingGuild = true
        else
            local ok, err = sendGuildWelcome(message)
            if ok then
                bumpAnalytics(guildKey, "welcomeGuildSent", 1)
            else
                table.insert(failures, err or GP.L["Unknown error."])
                bumpAnalytics(guildKey, "welcomeFailed", 1)
                remainingGuild = true
            end
        end
    end

    if entry.wantsWhisper then
        local message = self:RenderMessage(settings.welcomeWhisperMessage, entry.name, true)
        if message == "" then
            -- Template was cleared since queueing; nothing left to send.
        elseif string.len(message) > MAX_MESSAGE_LENGTH then
            table.insert(failures, string.format(GP.L["Recruitment message is too long (%d / %d)."], string.len(message), MAX_MESSAGE_LENGTH))
            bumpAnalytics(guildKey, "welcomeFailed", 1)
            remainingWhisper = true
        else
            local ok, err = sendRecruitmentWhisper(entry.name, message)
            if ok then
                bumpAnalytics(guildKey, "welcomeWhisperSent", 1)
            else
                table.insert(failures, err or GP.L["Unknown error."])
                bumpAnalytics(guildKey, "welcomeFailed", 1)
                remainingWhisper = true
            end
        end
    end

    if remainingGuild or remainingWhisper then
        entry.wantsGuild = remainingGuild
        entry.wantsWhisper = remainingWhisper
        GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
        return false, #failures > 0 and table.concat(failures, " ") or nil
    end

    table.remove(data.awaitingWelcome, index)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
    return true
end

function Recruitment:DismissAwaitingWelcome(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end
    local data = ensureRecruitment(guildData)
    for i, candidate in ipairs(data.awaitingWelcome) do
        if candidate.id == id then
            table.remove(data.awaitingWelcome, i)
            GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey)
            return true
        end
    end
    return false
end

local function zoneRecordID(name)
    local normalized = normalizeZoneName(name)
    if normalized == "" then return nil end
    return "zone:" .. normalized
end

function Recruitment:GetLockedInvalidZones(search)
    local zones = getLockedInvalidZones()
    local query = trim(search or ""):lower()
    local out = {}
    for id, record in pairs(zones) do
        if query == "" or record.name:lower():find(query, 1, true) then
            table.insert(out, { id = id, name = record.name, reason = record.reason })
        end
    end
    table.sort(out, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return out
end

-- Forces a rebuild of the locked/default invalid zone list — useful from
-- Settings if the Encounter Journal wasn't loaded yet the first time this
-- login read the list, or after a season/tier change.
function Recruitment:RefreshLockedInvalidZones()
    lockedInvalidZonesCache = buildLockedInvalidZones()
    GP:SendMessage("GuildParagon_RecruitmentChanged")
    return lockedInvalidZonesCache
end

function Recruitment:GetCustomInvalidZones(guildKey, search)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    local data = ensureRecruitment(guildData)
    local query = normalizeZoneName(search or "")
    local out = {}

    for _, record in pairs(data.customZones) do
        if record.active then
            local name = record.name or ""
            local reason = record.reason or ""
            if query == "" or name:lower():find(query, 1, true) or reason:lower():find(query, 1, true) then
                table.insert(out, copyBlacklistRecord(record))
            end
        end
    end

    table.sort(out, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return out
end

function Recruitment:GetCustomInvalidZoneRecord(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return nil end
    local data = ensureRecruitment(guildData)
    return copyBlacklistRecord(data.customZones[id])
end

function Recruitment:AddCustomInvalidZone(guildKey, name, reason, existingID)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end

    name = trim(name)
    if name == "" then return false, GP.L["Type a zone name first."] end

    local data = ensureRecruitment(guildData)
    local id = zoneRecordID(name) or existingID
    if not id then return false, GP.L["Type a zone name first."] end

    local currentTime = now()
    local actor = UnitName and UnitName("player") or ""
    if existingID and existingID ~= id then
        data.customZones[existingID] = nil
        data.customZonesUpdated[existingID] = currentTime
    end

    local previous = data.customZones[id]
    data.customZones[id] = {
        id = id,
        active = true,
        name = name,
        reason = trim(reason),
        addedAt = previous and previous.addedAt or currentTime,
        addedBy = previous and previous.addedBy or actor,
    }
    data.customZonesUpdated[id] = currentTime

    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true, nil, id
end

function Recruitment:RemoveCustomInvalidZone(guildKey, id)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return false, GP.L["Recruitment record not found."] end

    local data = ensureRecruitment(guildData)
    local record = data.customZones[id]
    if not record or not record.active then return false, GP.L["Recruitment record not found."] end

    record.active = false
    record.removedAt = now()
    record.removedBy = UnitName and UnitName("player") or ""
    data.customZonesUpdated[id] = record.removedAt

    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true
end

function Recruitment:IsInvalidZone(zoneName, guildKey)
    zoneName = trim(zoneName)
    if zoneName == "" then return false end
    local normalized = normalizeZoneName(zoneName)

    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if guildData then
        local data = ensureRecruitment(guildData)
        for _, record in pairs(data.customZones) do
            if record.active and normalizeZoneName(record.name or "") == normalized then
                return true, (record.reason and record.reason ~= "") and record.reason or GP.L["Custom invalid zone"]
            end
        end
    end

    if normalized == "delves" then return true, GP.L["Delves"] end

    local locked = getLockedInvalidZones()[normalized]
    if locked then return true, locked.reason end

    return false
end

function Recruitment:GetClassList()
    return getClassList()
end

function Recruitment:GetRaceList()
    return getRaceList()
end

function Recruitment:GetFilters(guildKey, search)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    local query = trim(search or ""):lower()
    local out = {}

    for _, record in pairs(resolveFilters(guildData)) do
        if record.active then
            local name = record.name or ""
            if query == "" or name:lower():find(query, 1, true) then
                table.insert(out, copyFilterRecord(record))
            end
        end
    end

    table.sort(out, function(a, b)
        if a.selected ~= b.selected then return a.selected end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return out
end

function Recruitment:GetFilterRecord(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return nil end
    return copyFilterRecord(resolveFilters(guildData)[id])
end

function Recruitment:GetSelectedFilter(guildKey)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil end
    for _, record in pairs(resolveFilters(guildData)) do
        if record.active and record.selected then
            return copyFilterRecord(record)
        end
    end
    return nil
end

function Recruitment:AddOrUpdateFilter(guildKey, name, classes, races, minLevel, maxLevel, existingID)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if self:IsFilterEditingLocked() then return false, GP.L["The guild master has locked recruitment filters."] end
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end

    name = trim(name)
    if name == "" then return false, GP.L["Type a filter name first."] end

    minLevel = tonumber(minLevel)
    maxLevel = tonumber(maxLevel)
    if minLevel and maxLevel and minLevel > maxLevel then
        return false, GP.L["Minimum level can't be higher than maximum level."]
    end

    local data = ensureRecruitment(guildData)
    local id = filterID(name) or existingID
    if not id then return false, GP.L["Type a filter name first."] end

    local currentTime = now()
    local actor = UnitName and UnitName("player") or ""
    if existingID and existingID ~= id then
        data.filters[existingID] = nil
        data.filtersUpdated[existingID] = currentTime
    end

    local classSet, raceSet = {}, {}
    for id2, checked in pairs(classes or {}) do if checked then classSet[id2] = true end end
    for id2, checked in pairs(races or {}) do if checked then raceSet[id2] = true end end

    local previous = data.filters[id]
    data.filters[id] = {
        id = id,
        active = true,
        name = name,
        classes = classSet,
        races = raceSet,
        minLevel = minLevel,
        maxLevel = maxLevel,
        selected = previous and previous.selected or false,
        createdAt = previous and previous.createdAt or currentTime,
        createdBy = previous and previous.createdBy or actor,
        updatedAt = currentTime,
        updatedBy = actor,
    }
    data.filtersUpdated[id] = currentTime

    pushRecruitmentSnapshotsIfNeeded(guildKey, guildData)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true, nil, id
end

function Recruitment:SetSelectedFilter(guildKey, id)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if self:IsFilterEditingLocked() then return false, GP.L["The guild master has locked recruitment filters."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return false, GP.L["Recruitment filter not found."] end
    local data = ensureRecruitment(guildData)
    if not data.filters[id] or not data.filters[id].active then return false, GP.L["Recruitment filter not found."] end

    local currentTime = now()
    for filterIDKey, record in pairs(data.filters) do
        if record.selected ~= (filterIDKey == id) then
            record.selected = filterIDKey == id
            data.filtersUpdated[filterIDKey] = currentTime
        end
    end

    pushRecruitmentSnapshotsIfNeeded(guildKey, guildData)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true
end

function Recruitment:RemoveFilter(guildKey, id)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if self:IsFilterEditingLocked() then return false, GP.L["The guild master has locked recruitment filters."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return false, GP.L["Recruitment filter not found."] end
    local data = ensureRecruitment(guildData)
    local record = data.filters[id]
    if not record or not record.active then return false, GP.L["Recruitment filter not found."] end

    record.active = false
    record.selected = false
    record.removedAt = now()
    record.removedBy = UnitName and UnitName("player") or ""
    data.filtersUpdated[id] = record.removedAt

    pushRecruitmentSnapshotsIfNeeded(guildKey, guildData)
    GP:SendMessage("GuildParagon_RecruitmentChanged", guildKey, id)
    return true
end

function Recruitment:MatchesFilter(candidate, guildKey)
    if type(candidate) ~= "table" then return true end
    local filter = self:GetSelectedFilter(guildKey)
    if not filter then return true end

    if next(filter.classes) and not (candidate.classFile and filter.classes[candidate.classFile]) then
        return false
    end
    if next(filter.races) and not (candidate.raceID and filter.races[candidate.raceID]) then
        return false
    end
    if filter.minLevel and (not candidate.level or candidate.level < filter.minLevel) then
        return false
    end
    if filter.maxLevel and (not candidate.level or candidate.level > filter.maxLevel) then
        return false
    end
    return true
end

local function buildLevelRanges(minLevel, maxLevel)
    minLevel = tonumber(minLevel) or 1
    maxLevel = tonumber(maxLevel) or DEFAULT_MAX_LEVEL
    minLevel = math.max(1, math.floor(minLevel))
    maxLevel = math.max(minLevel, math.floor(maxLevel))

    local ranges = {}
    local startLevel = minLevel
    while startLevel <= maxLevel do
        local endLevel = math.min(maxLevel, startLevel + WHO_LEVEL_STEP - 1)
        table.insert(ranges, { min = startLevel, max = endLevel })
        startLevel = endLevel + 1
    end
    return ranges
end

local function selectedClassNames(filter)
    if not filter or not next(filter.classes or {}) then return nil end
    local out = {}
    for _, class in ipairs(getClassList()) do
        if filter.classes[class.id] then table.insert(out, class.name) end
    end
    return out
end

local function selectedRaceNames(filter)
    if not filter or not next(filter.races or {}) then return nil end
    local out, seen = {}, {}
    for _, race in ipairs(getRaceList()) do
        for _, raceID in ipairs(race.ids or {}) do
            if filter.races[raceID] and not seen[race.name] then
                table.insert(out, race.name)
                seen[race.name] = true
                break
            end
        end
    end
    return out
end

local function appendQueriesForCriteria(out, keys, labels, kind, ranges)
    for _, label in ipairs(labels or {}) do
        for _, range in ipairs(ranges) do
            if kind == "class" then
                addScannerQuery(out, keys, makeScannerQuery(range.min, range.max, label, nil, false))
            elseif kind == "race" then
                addScannerQuery(out, keys, makeScannerQuery(range.min, range.max, nil, label, false))
            end
        end
    end
end

local function allRaceNames()
    local out = {}
    for _, race in ipairs(getRaceList()) do
        table.insert(out, race.name)
    end
    return out
end

local function allClassNames()
    local out = {}
    for _, class in ipairs(getClassList()) do
        table.insert(out, class.name)
    end
    return out
end

function Recruitment:BuildScannerQueries(guildKey)
    local filter = self:GetSelectedFilter(guildKey)
    local minLevel = filter and filter.minLevel or 1
    local maxLevel = filter and filter.maxLevel or DEFAULT_MAX_LEVEL
    local ranges = buildLevelRanges(minLevel, maxLevel)
    local queries = {}
    local keys = {}

    local classes = selectedClassNames(filter)
    if classes and #classes > 0 then
        appendQueriesForCriteria(queries, keys, classes, "class", ranges)
        return queries, keys
    end

    local races = selectedRaceNames(filter)
    if races and #races > 0 then
        appendQueriesForCriteria(queries, keys, races, "race", ranges)
        return queries, keys
    end

    for _, range in ipairs(ranges) do
        addScannerQuery(queries, keys, makeScannerQuery(range.min, range.max, nil, nil, false))
    end
    return queries, keys
end

function Recruitment:BuildCappedResultRefinements(guildKey, query)
    if type(query) ~= "table" then return {} end
    local out = {}
    local keys = {}
    local filter = self:GetSelectedFilter(guildKey)

    local minLevel = tonumber(query.minLevel) or 1
    local maxLevel = tonumber(query.maxLevel) or minLevel
    if maxLevel > minLevel then
        local mid = math.floor((minLevel + maxLevel) / 2)
        addScannerQuery(out, keys, makeScannerQuery(minLevel, mid, query.className, query.raceName, true))
        addScannerQuery(out, keys, makeScannerQuery(mid + 1, maxLevel, query.className, query.raceName, true))
        return out
    end

    if not query.raceName then
        local races = selectedRaceNames(filter) or allRaceNames()
        for _, raceName in ipairs(races) do
            addScannerQuery(out, keys, makeScannerQuery(minLevel, maxLevel, query.className, raceName, true))
        end
        return out
    end

    if not query.className then
        local classes = selectedClassNames(filter) or allClassNames()
        for _, className in ipairs(classes) do
            addScannerQuery(out, keys, makeScannerQuery(minLevel, maxLevel, className, query.raceName, true))
        end
        return out
    end

    return out
end

function Recruitment:InsertCappedResultRefinements(guildKey, query)
    if not query then return 0 end
    local refinements = self:BuildCappedResultRefinements(guildKey, query)
    local inserted = 0
    for _, refinedQuery in ipairs(refinements) do
        if #scannerState.queries >= MAX_SCANNER_QUERIES then break end
        local key = scannerQueryKey(refinedQuery)
        if key and not scannerState.queryKeys[key] then
            scannerState.queryKeys[key] = true
            inserted = inserted + 1
            table.insert(scannerState.queries, scannerState.queryIndex + inserted, refinedQuery)
        end
    end
    if inserted > 0 then
        scannerState.lastError = string.format(GP.L["Who result cap reached; added %d narrower query(s)."], inserted)
        bumpAnalytics(guildKey, "whoQueriesRefined", inserted)
    end
    return inserted
end

local function readWhoInfo(index)
    if not C_FriendList or not C_FriendList.GetWhoInfo then return nil end
    local info = GP:SafeCall(C_FriendList.GetWhoInfo, nil, index)
    if type(info) ~= "table" then return nil end
    local reportedName = GP:SafeOptionalString(info.fullName) or GP:SafeOptionalString(info.name)
    local canonicalFullName = fullName(reportedName)
    if not canonicalFullName then return nil end

    local raceName = GP:SafeOptionalString(info.raceStr)
    local raceID
    local byName = raceIDsByName()
    local raceIDs = raceName and byName[trim(raceName):lower()]
    if raceIDs then raceID = raceIDs[1] end

    return {
        fullName = canonicalFullName,
        name = displayNameFromFullName(canonicalFullName),
        level = GP:SafeNumber(info.level, nil),
        classFile = GP:SafeOptionalString(info.filename),
        className = GP:SafeOptionalString(info.classStr),
        raceID = raceID,
        raceName = raceName,
        zone = GP:SafeOptionalString(info.area),
        guild = GP:SafeOptionalString(info.fullGuildName) or GP:SafeOptionalString(info.guild),
    }
end

function Recruitment:ClassifyCandidate(candidate, guildKey)
    if type(candidate) ~= "table" then return false, GP.L["Invalid who result."] end
    if candidate.guild and candidate.guild ~= "" then
        return false, GP.L["Already in a guild."]
    end

    local Roster = GP:GetModule("Roster", true)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if Roster and Roster.FindPlayerByName and guildData then
        local guid = Roster:FindPlayerByName(guildData, candidate.fullName or candidate.name, false)
        if guid then return false, GP.L["Already in your guild."] end
    end

    local blocked, record = self:IsDoNotInvite(guildKey, candidate.fullName or candidate.name)
    if blocked then
        return false, (record and record.reason and record.reason ~= "") and record.reason or GP.L["Do Not Invite"]
    end

    blocked = self:IsAntiSpamBlocked(guildKey, candidate.fullName or candidate.name)
    if blocked then
        return false, GP.L["Anti-spam cooldown."]
    end

    blocked, record = self:IsInvalidZone(candidate.zone, guildKey)
    if blocked then
        return false, record or GP.L["Invalid zone."]
    end

    if not self:MatchesFilter(candidate, guildKey) then
        return false, GP.L["Outside active filter."]
    end

    return true
end

local function sendWhoQuery(query)
    if InCombatLockdown and InCombatLockdown() then
        return false, GP.L["Recruitment scanner paused while combat is active."]
    end
    if FriendsFrame and FriendsFrame.UnregisterEvent then
        scannerState.friendsFrameHadWhoEvent = FriendsFrame.IsEventRegistered and FriendsFrame:IsEventRegistered("WHO_LIST_UPDATE") or true
        FriendsFrame:UnregisterEvent("WHO_LIST_UPDATE")
    end
    if C_FriendList and C_FriendList.SetWhoToUi then
        C_FriendList.SetWhoToUi(true)
    end
    if C_FriendList and C_FriendList.SendWho then
        C_FriendList.SendWho(query)
        return true
    end
    if SendWho then
        SendWho(query)
        return true
    end
    return false
end

local function restoreWhoRouting()
    if scannerState.friendsFrameHadWhoEvent and FriendsFrame and FriendsFrame.RegisterEvent then
        FriendsFrame:RegisterEvent("WHO_LIST_UPDATE")
    end
    scannerState.friendsFrameHadWhoEvent = false
end

function Recruitment:RunNextScannerQuery()
    if scannerState.status ~= "running" then return end
    if scannerState.waiting then return end
    if InCombatLockdown and InCombatLockdown() then
        scannerState.status = "stopped"
        scannerState.waiting = false
        scannerState.finishedAt = now()
        scannerState.lastError = GP.L["Recruitment scanner paused while combat is active."]
        restoreWhoRouting()
        recordScannerAnalytics("stopped")
        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        return
    end
    scannerState.queryIndex = scannerState.queryIndex + 1
    local query = scannerState.queries[scannerState.queryIndex]
    if not query then
        scannerState.queryIndex = #scannerState.queries
        scannerState.status = "complete"
        scannerState.waiting = false
        scannerState.finishedAt = now()
        recordScannerAnalytics("complete")
        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        return
    end

    scannerState.lastQuery = query.label or query.text
    scannerState.waiting = true
    scannerState.lastError = nil
    scannerState.nextQueryAvailableAt = 0
    scannerState.token = (scannerState.token or 0) + 1
    local token = scannerState.token
    local sent, errorText = sendWhoQuery(query.text)
    if not sent then
        scannerState.status = "error"
        scannerState.waiting = false
        scannerState.lastError = errorText or GP.L["Who query API is not available."]
        scannerState.finishedAt = now()
        restoreWhoRouting()
        recordScannerAnalytics("error")
    else
        bumpAnalytics(scannerState.guildKey, "whoQueriesSent", 1)
    end
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    if scannerState.status == "running" and scannerState.waiting then
        C_Timer.After(WHO_QUERY_TIMEOUT, function()
            if scannerState.status ~= "running" or not scannerState.waiting or scannerState.token ~= token then return end
            scannerState.waiting = false
            scannerState.lastError = GP.L["Who query timed out. Click Next Query to continue."]
            restoreWhoRouting()
            bumpAnalytics(scannerState.guildKey, "whoQueryTimeouts", 1)
            GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        end)
    end
end

function Recruitment:StartScanner()
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if InCombatLockdown and InCombatLockdown() then return false, GP.L["Recruitment scanner paused while combat is active."] end
    if not (C_FriendList and C_FriendList.GetNumWhoResults and C_FriendList.GetWhoInfo) then
        return false, GP.L["Who query API is not available."]
    end

    local guildKey = self:GetCurrentGuildKey()
    if not guildKey then return false, GP.L["No roster data yet — try /gp scan."] end

    scannerState.status = "running"
    scannerState.guildKey = guildKey
    scannerState.queries, scannerState.queryKeys = self:BuildScannerQueries(guildKey)
    scannerState.queryKeys = scannerState.queryKeys or {}
    scannerState.queryIndex = 0
    scannerState.rawResults = 0
    scannerState.candidates = {}
    scannerState.queue = {}
    scannerState.queueOrder = {}
    scannerState.selectedQueueID = nil
    scannerState.executorMode = self:GetDefaultExecutorMode()
    scannerState.skipped = {}
    scannerState.seen = {}
    scannerState.lastQuery = ""
    scannerState.lastError = nil
    scannerState.waiting = false
    scannerState.nextQueryAvailableAt = 0
    scannerState.token = 0
    scannerState.startedAt = now()
    scannerState.finishedAt = nil
    scannerState.scannerAnalyticsRecorded = false
    bumpAnalytics(guildKey, "scansStarted", 1)

    if #scannerState.queries == 0 then
        scannerState.status = "complete"
        scannerState.finishedAt = now()
        recordScannerAnalytics("complete")
        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        return true
    end

    self:RunNextScannerQuery()
    return true
end

function Recruitment:ContinueScanner()
    if scannerState.status ~= "running" then return false, GP.L["Scanner is not running."] end
    if scannerState.waiting then return false, GP.L["Waiting for Who results."] end
    local remaining = (scannerState.nextQueryAvailableAt or 0) - now()
    if remaining > 0 then
        return false, string.format(GP.L["Wait %d second(s) before the next query."], math.ceil(remaining))
    end
    self:RunNextScannerQuery()
    return true
end

function Recruitment:StopScanner()
    if scannerState.status == "running" then
        scannerState.token = (scannerState.token or 0) + 1
        scannerState.status = "stopped"
        scannerState.waiting = false
        scannerState.finishedAt = now()
        restoreWhoRouting()
        recordScannerAnalytics("stopped")
        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        return true
    end
    return false
end

function Recruitment:OnCombatStarted()
    local changed = false
    if scannerState.status == "running" then
        scannerState.token = (scannerState.token or 0) + 1
        scannerState.status = "stopped"
        scannerState.waiting = false
        scannerState.nextQueryAvailableAt = 0
        scannerState.finishedAt = now()
        scannerState.lastError = GP.L["Recruitment scanner paused while combat is active."]
        restoreWhoRouting()
        recordScannerAnalytics("stopped")
        changed = true
    end
    if scannerState.executorStatus == "running" then
        scannerState.executorToken = (scannerState.executorToken or 0) + 1
        scannerState.executorStatus = "stopped"
        scannerState.executorFinishedAt = now()
        scannerState.executorLastError = GP.L["Executor stopped while combat is active."]
        recordExecutorAnalytics("stopped")
        changed = true
    end
    if not changed then return end
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
end

function Recruitment:OnLeavingWorld()
    local changed = false
    if scannerState.status == "running" then
        scannerState.token = (scannerState.token or 0) + 1
        scannerState.status = "stopped"
        scannerState.waiting = false
        scannerState.nextQueryAvailableAt = 0
        scannerState.finishedAt = now()
        scannerState.lastError = GP.L["Recruitment scanner paused while leaving the world."]
        restoreWhoRouting()
        recordScannerAnalytics("stopped")
        changed = true
    end
    if scannerState.executorStatus == "running" then
        scannerState.executorToken = (scannerState.executorToken or 0) + 1
        scannerState.executorStatus = "stopped"
        scannerState.executorFinishedAt = now()
        scannerState.executorLastError = GP.L["Executor stopped while leaving the world."]
        recordExecutorAnalytics("stopped")
        changed = true
    end
    if not changed then return end
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
end

function Recruitment:ClearScanner()
    restoreWhoRouting()
    scannerState.status = "idle"
    scannerState.queries = {}
    scannerState.queryKeys = {}
    scannerState.queryIndex = 0
    scannerState.rawResults = 0
    scannerState.candidates = {}
    scannerState.queue = {}
    scannerState.queueOrder = {}
    scannerState.selectedQueueID = nil
    scannerState.executorMode = self:GetDefaultExecutorMode()
    resetExecutorState("idle")
    scannerState.skipped = {}
    scannerState.seen = {}
    scannerState.lastQuery = ""
    scannerState.lastError = nil
    scannerState.waiting = false
    scannerState.nextQueryAvailableAt = 0
    scannerState.token = (scannerState.token or 0) + 1
    scannerState.startedAt = nil
    scannerState.finishedAt = nil
    scannerState.scannerAnalyticsRecorded = false
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
end

function Recruitment:OnWhoListUpdate()
    if scannerState.status ~= "running" or not scannerState.waiting then return end
    scannerState.waiting = false
    scannerState.token = (scannerState.token or 0) + 1

    local count = GP:SafeNumber(GP:SafeCall(C_FriendList.GetNumWhoResults, 0), 0)
    restoreWhoRouting()
    scannerState.rawResults = scannerState.rawResults + count
    local guildKey = scannerState.guildKey or self:GetCurrentGuildKey()
    local activeQuery = scannerState.queries[scannerState.queryIndex]
    local candidatesAdded = 0
    local skippedAdded = 0

    for i = 1, count do
        local candidate = readWhoInfo(i)
        if candidate then
            local id = recordID(candidate.fullName)
            if id and not scannerState.seen[id] then
                scannerState.seen[id] = true
                candidate.query = activeQuery and activeQuery.label or scannerState.lastQuery
                local ok, reason = self:ClassifyCandidate(candidate, guildKey)
                if ok then
                    addScannerRow(scannerState.candidates, candidate)
                    candidatesAdded = candidatesAdded + 1
                else
                    candidate.reason = reason or GP.L["Skipped."]
                    addScannerRow(scannerState.skipped, candidate)
                    skippedAdded = skippedAdded + 1
                end
            end
        end
    end
    bumpAnalytics(guildKey, "whoResults", count)
    bumpAnalytics(guildKey, "candidatesFound", candidatesAdded)
    bumpAnalytics(guildKey, "candidatesSkipped", skippedAdded)
    if count >= WHO_RESULT_CAP then
        self:InsertCappedResultRefinements(guildKey, activeQuery)
    end

    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    if scannerState.status == "running" then
        if scannerState.queryIndex >= #scannerState.queries then
            scannerState.status = "complete"
            scannerState.finishedAt = now()
            scannerState.nextQueryAvailableAt = 0
            recordScannerAnalytics("complete")
            GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        else
            scannerState.nextQueryAvailableAt = now() + NEXT_QUERY_DELAY
            for delay = 1, NEXT_QUERY_DELAY do
                C_Timer.After(delay, function()
                    if scannerState.status == "running" and not scannerState.waiting and scannerState.queryIndex < #scannerState.queries then
                        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
                    end
                end)
            end
        end
    end
end

function Recruitment:GetScannerState()
    local canContinue = scannerState.status == "running" and not scannerState.waiting and scannerState.queryIndex < #scannerState.queries
    if canContinue and (scannerState.nextQueryAvailableAt or 0) > now() then
        canContinue = false
    end
    return {
        status = scannerState.status,
        running = scannerState.status == "running",
        waiting = scannerState.waiting,
        canContinue = canContinue,
        nextQueryAvailableAt = scannerState.nextQueryAvailableAt or 0,
        queryIndex = scannerState.queryIndex,
        queryTotal = #scannerState.queries,
        rawResults = scannerState.rawResults,
        candidates = #scannerState.candidates,
        queued = #scannerState.queueOrder,
        selectedQueueID = scannerState.selectedQueueID,
        executorMode = self:GetExecutorMode(),
        skipped = #scannerState.skipped,
        lastQuery = scannerState.lastQuery,
        lastError = scannerState.lastError,
        startedAt = scannerState.startedAt,
        finishedAt = scannerState.finishedAt,
    }
end

function Recruitment:GetExecutorModes()
    return {
        { id = EXECUTOR_MODE_INVITE, label = GP.L["Invite"] },
        { id = EXECUTOR_MODE_WHISPER, label = GP.L["Whisper"] },
        { id = EXECUTOR_MODE_WHISPER_INVITE, label = GP.L["Whisper + Invite"] },
    }
end

function Recruitment:GetDefaultExecutorMode()
    local settings = self:GetSettings()
    return isValidExecutorMode(settings.executorMode) and settings.executorMode or DEFAULT_EXECUTOR_MODE
end

function Recruitment:GetExecutorMode()
    return isValidExecutorMode(scannerState.executorMode) and scannerState.executorMode or self:GetDefaultExecutorMode()
end

function Recruitment:SetExecutorMode(mode)
    if not isValidExecutorMode(mode) then
        return false, GP.L["Unknown executor mode."]
    end
    scannerState.executorMode = mode
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    return true
end

function Recruitment:SelectQueuedCandidate(id)
    if not id or not scannerState.queue[id] then
        scannerState.selectedQueueID = nil
        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        return false, GP.L["Queued candidate not found."]
    end
    scannerState.selectedQueueID = id
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    return true
end

function Recruitment:GetExecutorPreview()
    local mode = self:GetExecutorMode()
    local candidate = getFirstQueuedCandidate()
    local preview = {
        mode = mode,
        modeLabel = getExecutorModeLabel(mode),
        usesInvite = modeUsesInvite(mode),
        usesWhisper = modeUsesWhisper(mode),
        queueCount = #scannerState.queueOrder,
        ready = false,
        target = nil,
        message = nil,
        warning = nil,
    }

    if not candidate then
        preview.summary = GP.L["Queue a candidate to prepare the executor."]
        return preview
    end

    preview.target = candidate.fullName or candidate.name
    local parts = {}
    if preview.usesWhisper then table.insert(parts, GP.L["Whisper"]) end
    if preview.usesInvite then table.insert(parts, GP.L["Invite"]) end
    preview.summary = string.format(GP.L["Next: %s - %s"], preview.target or "?", table.concat(parts, " + "))

    if preview.usesWhisper then
        local message = self:GetSelectedMessage(scannerState.guildKey or self:GetCurrentGuildKey())
        if not message then
            preview.warning = GP.L["Select an active recruitment message first."]
            return preview
        end
        preview.message = self:RenderMessage(message.body, candidate.name or candidate.fullName, true)
        if preview.message == "" then
            preview.warning = GP.L["Type a recruitment message first."]
            return preview
        end
        if string.len(preview.message) > MAX_MESSAGE_LENGTH then
            preview.warning = string.format(GP.L["Recruitment message is too long (%d / %d)."], string.len(preview.message), MAX_MESSAGE_LENGTH)
            return preview
        end
    end

    preview.ready = true
    return preview
end

function Recruitment:RunExecutorPreview()
    local preview = self:GetExecutorPreview()
    if not preview.ready then return false, preview.warning or preview.summary or GP.L["Nothing to preview."] end
    if preview.usesWhisper and preview.usesInvite then
        return true, string.format(GP.L["Preview only: would whisper %s, then prepare a guild invite."], preview.target or "?")
    end
    if preview.usesWhisper then
        return true, string.format(GP.L["Preview only: would whisper %s."], preview.target or "?")
    end
    return true, string.format(GP.L["Preview only: would prepare a guild invite for %s."], preview.target or "?")
end

function Recruitment:GetExecutorState()
    return {
        status = scannerState.executorStatus or "idle",
        running = scannerState.executorStatus == "running",
        lastError = scannerState.executorLastError,
        processed = scannerState.executorProcessed or 0,
        sent = scannerState.executorSent or 0,
        skipped = scannerState.executorSkipped or 0,
        failed = scannerState.executorFailed or 0,
        queueCount = #scannerState.queueOrder,
        mode = self:GetExecutorMode(),
    }
end

function Recruitment:GetExecutorStatusText()
    local state = self:GetExecutorState()
    if state.status == "running" then
        return string.format(GP.L["Executor: running (%d sent, %d skipped, %d failed)"], state.sent, state.skipped, state.failed)
    end
    if state.status == "complete" then
        return string.format(GP.L["Executor: complete (%d sent, %d skipped, %d failed)"], state.sent, state.skipped, state.failed)
    end
    if state.status == "stopped" then
        return string.format(GP.L["Executor: stopped (%d sent, %d skipped, %d failed)"], state.sent, state.skipped, state.failed)
    end
    if state.status == "error" then
        return string.format(GP.L["Executor: stopped - %s"], state.lastError or GP.L["Unknown error."])
    end
    return GP.L["Executor: ready"]
end

local function finishExecutor(status, message)
    scannerState.executorStatus = status or "complete"
    scannerState.executorFinishedAt = now()
    scannerState.executorLastError = message
    recordExecutorAnalytics(scannerState.executorStatus)
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    if message and message ~= "" then GP:Print(message) end
end

function Recruitment:StopExecutor()
    if scannerState.executorStatus ~= "running" then return false, GP.L["Executor is not running."] end
    scannerState.executorToken = (scannerState.executorToken or 0) + 1
    finishExecutor("stopped", GP.L["Executor stopped."])
    return true
end

function Recruitment:RunNextExecutorStep(token)
    if scannerState.executorStatus ~= "running" or token ~= scannerState.executorToken then return end
    if InCombatLockdown and InCombatLockdown() then
        scannerState.executorToken = (scannerState.executorToken or 0) + 1
        finishExecutor("stopped", GP.L["Executor stopped while combat is active."])
        return
    end

    local candidate = getFirstQueuedCandidate()
    if not candidate then
        finishExecutor("complete", string.format(GP.L["Executor complete: %d sent, %d skipped, %d failed."],
            scannerState.executorSent or 0, scannerState.executorSkipped or 0, scannerState.executorFailed or 0))
        return
    end

    local guildKey = scannerState.guildKey or self:GetCurrentGuildKey()
    local target = candidate.fullName or candidate.name
    local id = candidate.id or recordID(target)
    local mode = self:GetExecutorMode()
    local skippedReason
    local pendingAntiSpamInviteBypass = self:CanBypassAntiSpamForPendingInvite(guildKey, target, mode)
    local blocked, blockRecord = self:IsDoNotInvite(guildKey, target)
    if blocked and not (pendingAntiSpamInviteBypass and blockRecord and blockRecord.source == "antiSpam") then
        skippedReason = GP.L["On Do Not Invite list."]
    elseif self:IsAntiSpamBlocked(guildKey, target) and not pendingAntiSpamInviteBypass then
        skippedReason = GP.L["Anti-spam cooldown."]
    end

    if skippedReason then
        consumeQueuedCandidate(id)
        scannerState.executorProcessed = (scannerState.executorProcessed or 0) + 1
        scannerState.executorSkipped = (scannerState.executorSkipped or 0) + 1
        bumpAnalytics(guildKey, "executorSkippedCandidates", 1)
        GP:Print(string.format(GP.L["Executor skipped %s: %s"], target or "?", skippedReason))
    else
        local message
        local selectedMessage
        if modeUsesWhisper(mode) then
            selectedMessage = self:GetSelectedMessage(guildKey)
            if not selectedMessage then
                finishExecutor("error", GP.L["Select an active recruitment message first."])
                return
            end
            message = self:RenderMessage(selectedMessage.body, target, true)
            if message == "" then
                finishExecutor("error", GP.L["Type a recruitment message first."])
                return
            end
            if string.len(message) > MAX_MESSAGE_LENGTH then
                finishExecutor("error", string.format(GP.L["Recruitment message is too long (%d / %d)."], string.len(message), MAX_MESSAGE_LENGTH))
                return
            end
        end

        local ok, err = true, nil
        local contacted = false
        local whisperSent = false
        local inviteSent = false
        if modeUsesWhisper(mode) then
            ok, err = sendRecruitmentWhisper(target, message)
            if ok then
                contacted = true
                whisperSent = true
            end
        end
        if ok and modeUsesInvite(mode) then
            if not canGuildInvite() then
                ok, err = false, GP.L["Guild invite permission is required."]
            else
                ok, err = sendGuildInvite(target)
                if ok then
                    contacted = true
                    inviteSent = true
                end
            end
        end

        if not ok then
            scannerState.executorFailed = (scannerState.executorFailed or 0) + 1
            bumpAnalytics(guildKey, "executorFailedCandidates", 1)
            if contacted then
                consumeQueuedCandidate(id)
                scannerState.executorProcessed = (scannerState.executorProcessed or 0) + 1
                self:AddAntiSpam(guildKey, target)
                self:AddPendingInvite(guildKey, candidate, {
                    mode = mode,
                    whisperSent = whisperSent,
                    inviteSent = inviteSent,
                    messageID = selectedMessage and selectedMessage.id or nil,
                    messageTitle = selectedMessage and selectedMessage.title or nil,
                    lastError = err,
                })
                bumpAnalytics(guildKey, "executorContactedCandidates", 1)
            end
            finishExecutor("error", string.format(GP.L["Executor failed for %s: %s"], target or "?", err or GP.L["Unknown error."]))
            return
        end

        consumeQueuedCandidate(id)
        scannerState.executorProcessed = (scannerState.executorProcessed or 0) + 1
        scannerState.executorSent = (scannerState.executorSent or 0) + 1
        self:AddAntiSpam(guildKey, target)
        self:AddPendingInvite(guildKey, candidate, {
            mode = mode,
            whisperSent = whisperSent,
            inviteSent = inviteSent,
            messageID = selectedMessage and selectedMessage.id or nil,
            messageTitle = selectedMessage and selectedMessage.title or nil,
        })
        bumpAnalytics(guildKey, "executorContactedCandidates", 1)
        if modeUsesWhisper(mode) then bumpAnalytics(guildKey, "whispersSent", 1) end
        if modeUsesInvite(mode) then bumpAnalytics(guildKey, "invitesSent", 1) end
    end

    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    local delay = self:GetSettings().messageDelay or 0.5
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, function() self:RunNextExecutorStep(token) end)
    else
        self:RunNextExecutorStep(token)
    end
end

function Recruitment:StartExecutor()
    if scannerState.executorStatus == "running" then return false, GP.L["Executor is already running."] end
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    if InCombatLockdown and InCombatLockdown() then return false, GP.L["Executor stopped while combat is active."] end
    if #scannerState.queueOrder == 0 then return false, GP.L["Queue a candidate before starting executor."] end

    local preview = self:GetExecutorPreview()
    if not preview.ready then return false, preview.warning or preview.summary or GP.L["Nothing to execute."] end

    scannerState.executorToken = (scannerState.executorToken or 0) + 1
    scannerState.executorStatus = "running"
    scannerState.executorLastError = nil
    scannerState.executorProcessed = 0
    scannerState.executorSent = 0
    scannerState.executorSkipped = 0
    scannerState.executorFailed = 0
    scannerState.executorStartedAt = now()
    scannerState.executorFinishedAt = nil
    scannerState.executorAnalyticsRecorded = false
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    GP:Print(GP.L["Executor started."])
    self:RunNextExecutorStep(scannerState.executorToken)
    return true
end

function Recruitment:AddCandidateToQueue(candidateOrID)
    local id
    if type(candidateOrID) == "table" then
        id = candidateOrID.id or recordID(candidateOrID.fullName or candidateOrID.name)
    else
        id = candidateOrID
    end
    if not id then return false, GP.L["Select a candidate first."] end

    local source
    if type(candidateOrID) == "table" then
        source = candidateOrID
    else
        for _, candidate in ipairs(scannerState.candidates) do
            if candidate.id == id then
                source = candidate
                break
            end
        end
    end
    if not source then return false, GP.L["Candidate not found."] end
    if scannerState.queue[id] then return false, GP.L["Candidate is already queued."] end

    local queued = copyCandidate(source)
    queued.id = id
    queued.queuedAt = now()
    scannerState.queue[id] = queued
    table.insert(scannerState.queueOrder, id)
    removeScannerCandidateByID(id)
    if removeScannerSkippedByID(id) then
        queued.queuedFromSkipped = true
    end
    bumpAnalytics(scannerState.guildKey or self:GetCurrentGuildKey(), "candidatesQueued", 1)
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    return true
end

function Recruitment:AddContextCandidateToQueue(name, openRecruitment)
    if not self:CanUse() then return false, GP.L["Guild invite permission is required."] end
    local target = fullName(name)
    if not target then return false, GP.L["Player not found."] end

    local guildKey = self:GetCurrentGuildKey()
    local id = recordID(target)
    if not id then return false, GP.L["Player not found."] end
    if scannerState.queue[id] then
        scannerState.selectedQueueID = id
        if openRecruitment and GP.UI and GP.UI.MainWindow then
            GP.UI.MainWindow:SelectTabByID("recruitment")
        end
        GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
        return false, GP.L["Candidate is already queued."]
    end

    local candidate = {
        id = id,
        fullName = target,
        name = target,
        className = GP.L["Unknown"],
        raceName = GP.L["Unknown"],
        zone = GP.L["Unknown"],
        query = GP.L["Context menu"],
        addedAt = now(),
    }

    local ok, err = self:AddCandidateToQueue(candidate)
    if ok then
        scannerState.guildKey = scannerState.guildKey or guildKey
        scannerState.selectedQueueID = id
        if openRecruitment and GP.UI and GP.UI.MainWindow then
            GP.UI.MainWindow:SelectTabByID("recruitment")
        end
        GP:Print(string.format(GP.L["Queued %s for recruitment."], target))
    end
    return ok, err
end

function Recruitment:AddCandidatesToQueue(candidates)
    local added = 0
    for _, candidate in ipairs(candidates or {}) do
        local ok = self:AddCandidateToQueue(candidate)
        if ok then added = added + 1 end
    end
    return added
end

function Recruitment:RemoveQueuedCandidate(id)
    if not id or not scannerState.queue[id] then return false, GP.L["Queued candidate not found."] end
    local candidate = scannerState.queue[id]
    scannerState.queue[id] = nil
    if scannerState.selectedQueueID == id then scannerState.selectedQueueID = nil end
    rebuildQueueOrder()
    if candidate.queuedFromSkipped then
        if not hasScannerSkipped(id) then
            table.insert(scannerState.skipped, copyCandidate(candidate))
        end
    elseif not hasScannerCandidate(id) then
        table.insert(scannerState.candidates, copyCandidate(candidate))
    end
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
    return true
end

function Recruitment:ClearCandidateQueue()
    for _, id in ipairs(scannerState.queueOrder or {}) do
        local candidate = scannerState.queue[id]
        if candidate and candidate.queuedFromSkipped and not hasScannerSkipped(id) then
            table.insert(scannerState.skipped, copyCandidate(candidate))
        elseif candidate and not hasScannerCandidate(id) then
            table.insert(scannerState.candidates, copyCandidate(candidate))
        end
    end
    scannerState.queue = {}
    scannerState.queueOrder = {}
    scannerState.selectedQueueID = nil
    GP:SendMessage("GuildParagon_RecruitmentScannerChanged")
end

function Recruitment:GetQueuedCandidates(search)
    local query = normalizeName(search or "")
    local out = {}
    for _, id in ipairs(scannerState.queueOrder) do
        local row = scannerState.queue[id]
        if row and (query == "" or normalizeName(row.fullName):find(query, 1, true) or normalizeZoneName(row.zone or ""):find(query, 1, true)) then
            local copy = copyCandidate(row)
            copy.selected = id == scannerState.selectedQueueID
            table.insert(out, copy)
        end
    end
    return out
end

function Recruitment:GetScannerCandidates(search)
    local query = normalizeName(search or "")
    if query == "" then return copyScannerRows(scannerState.candidates) end
    local out = {}
    for _, row in ipairs(scannerState.candidates) do
        if normalizeName(row.fullName):find(query, 1, true) or normalizeZoneName(row.zone or ""):find(query, 1, true) then
            table.insert(out, copyCandidate(row))
        end
    end
    return out
end

function Recruitment:GetScannerSkipped(search)
    local query = normalizeName(search or "")
    if query == "" then return copyScannerRows(scannerState.skipped) end
    local out = {}
    for _, row in ipairs(scannerState.skipped) do
        if normalizeName(row.fullName):find(query, 1, true)
            or normalizeZoneName(row.zone or ""):find(query, 1, true)
            or normalizeZoneName(row.reason or ""):find(query, 1, true) then
            table.insert(out, copyCandidate(row))
        end
    end
    return out
end

function Recruitment:GetScannerStatusText()
    local s = self:GetScannerState()
    local executorText = self:GetExecutorStatusText()
    if s.status == "error" then
        return string.format(GP.L["Scanner: error\n%s\nQueue: %d queued\n%s"], s.lastError or GP.L["Unknown error."], s.queued, executorText)
    end
    if s.status == "running" then
        if s.lastError and s.canContinue then
            return string.format(GP.L["Scanner: ready %d/%d\n%s\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
                s.queryIndex, s.queryTotal, s.lastError, s.rawResults, s.candidates, s.queued, s.skipped, executorText)
        end
        if s.canContinue then
            return string.format(GP.L["Scanner: ready %d/%d\nPress Next Query to continue.\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
                s.queryIndex, s.queryTotal, s.rawResults, s.candidates, s.queued, s.skipped, executorText)
        end
        local waitSeconds = math.ceil((s.nextQueryAvailableAt or 0) - now())
        if waitSeconds > 0 and s.queryIndex < s.queryTotal then
            return string.format(GP.L["Scanner: ready %d/%d\nNext query available in %d second(s).\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
                s.queryIndex, s.queryTotal, waitSeconds, s.rawResults, s.candidates, s.queued, s.skipped, executorText)
        end
        if s.lastError then
            return string.format(GP.L["Scanner: waiting %d/%d\n%s\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
                s.queryIndex, s.queryTotal, s.lastError, s.rawResults, s.candidates, s.queued, s.skipped, executorText)
        end
        return string.format(GP.L["Scanner: running %d/%d\nLast query: %s\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
            s.queryIndex, s.queryTotal, s.lastQuery ~= "" and s.lastQuery or GP.L["Starting..."], s.rawResults, s.candidates, s.queued, s.skipped, executorText)
    end
    if s.status == "complete" then
        return string.format(GP.L["Scanner: complete %d/%d\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
            s.queryIndex, s.queryTotal, s.rawResults, s.candidates, s.queued, s.skipped, executorText)
    end
    if s.status == "stopped" then
        return string.format(GP.L["Scanner: stopped %d/%d\nResults: %d  Candidates: %d  Queued: %d  Skipped: %d\n%s"],
            s.queryIndex, s.queryTotal, s.rawResults, s.candidates, s.queued, s.skipped, executorText)
    end
    return string.format(GP.L["Scanner: idle\nQueue: %d queued\n%s\nStart a scan to collect candidates."], s.queued, executorText)
end

function Recruitment:GetSummary(guildKey)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return 0, 0, 0, 0, 0, 0 end
    local data = ensureRecruitment(guildData)
    cleanupExpiredAntiSpamBlacklist(guildKey, data)
    local blacklist, antiSpam, messages, filters, zones, pending = 0, 0, 0, 0, 0, 0
    blacklist = #self:GetBlacklist(guildKey)
    for _ in pairs(data.antiSpam) do antiSpam = antiSpam + 1 end
    for _, record in pairs(data.pendingInvites) do if record.active then pending = pending + 1 end end
    for _, record in pairs(data.messages) do if record.active then messages = messages + 1 end end
    for _, record in pairs(data.filters) do if record.active then filters = filters + 1 end end
    for _, record in pairs(data.customZones) do if record.active then zones = zones + 1 end end
    return blacklist, antiSpam, messages, filters, zones, pending
end

function Recruitment:GetAnalyticsSummary(guildKey, maxSessions)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then
        return { totals = {}, today = {}, sessions = {}, updatedAt = nil }
    end

    local data = ensureRecruitment(guildData)
    cleanupExpiredPendingInvites(guildKey, data)
    local analytics = ensureAnalytics(data)
    local todayKey = analyticsDayKey()
    local sessions = {}
    local limit = tonumber(maxSessions) or 10
    for index, record in ipairs(analytics.sessions or {}) do
        if limit > 0 and index > limit then break end
        local copy = {}
        for key, value in pairs(record) do copy[key] = value end
        table.insert(sessions, copy)
    end
    local pendingInvites = self:GetPendingInvites(guildKey)
    table.sort(pendingInvites, function(a, b)
        return (tonumber(a.contactedAt) or 0) > (tonumber(b.contactedAt) or 0)
    end)

    return {
        totals = analytics.totals or {},
        today = analytics.days and analytics.days[todayKey] or {},
        sessions = sessions,
        pendingInvites = pendingInvites,
        updatedAt = analytics.updatedAt,
    }
end
