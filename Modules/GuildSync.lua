-- Guild Sync: timestamped shared guild-state convergence over addon messages.
-- Large full-state payloads are compressed and chunked; Event Log sync stays manual.
local _, GP = ...

local GuildSync = GP:NewModule("GuildSync", "AceEvent-3.0", "AceSerializer-3.0")

-- Bump on wire-incompatible protocol changes; WoW caps prefixes at 16 chars.
local COMM_PREFIX = "GuildParagon2"
-- Protocol 3 sends full/safety state one category at a time.
local PROTOCOL_VERSION = 3

-- Routine Event Log sync is disabled; full replacement stays button-only.
local SYNC_EVENT_LOG = false

-- Explicit gates for large non-log categories.
local SYNC_GENERAL_NOTES = true
local SYNC_BIRTHDAYS = true

-- Explicit gate for join-date sync.
local SYNC_JOIN_DATES = true

-- Minimum gap between automatic mismatch-triggered resyncs.
local AUTO_RESYNC_COOLDOWN_SECONDS = 30

-- Cap zero-apply auto-resync retries per sender.
local MAX_AUTO_RESYNC_STREAK = 3
local AUTO_RESYNC_ENABLED = false
local STARTUP_FULL_SYNC_INTERVAL_SECONDS = 24 * 60 * 60
local STARTUP_FULL_SYNC_SAFETY_FALLBACK_SECONDS = 3 * 60
local PEER_PROBABLY_OFFLINE_SECONDS = 5 * 60
local PEER_HIDE_AFTER_SECONDS = 15 * 60

local LOG_SYNC_DAYS = 7
local LOG_SYNC_MAX_ENTRIES = 200
local FULL_LOG_CHUNK_SIZE = 100
local FULL_LOG_CHUNK_DELAY = 0.05
local FULL_LOG_BOOTSTRAP_TIMEOUT = 900
local FULL_LOG_BOOTSTRAP_LOCAL_LIMIT = LOG_SYNC_MAX_ENTRIES + 25
local RAW_SYNC_CHUNK_BYTES = 45
local RAW_SYNC_CHUNK_DELAY = 0.20
local RAW_SYNC_DIRECT_BYTES = 245
local RAW_SYNC_COMPRESSION_MIN_BYTES = 512
local RAW_SYNC_COMPRESSION_MIN_SAVINGS = 32
local FULL_APPLY_BATCH_SIZE = 75
local HOUSING_INSTANCE_TYPES = {
    neighborhood = true,
    interior = true,
}

-- Idle raw transfers retry missing chunks before being abandoned.
local RAW_TRANSFER_STALE_SECONDS = 90
local RAW_RESEND_CACHE_SECONDS = 15 * 60
local RAW_MISSING_RETRY_LIMIT = 3
local RAW_MISSING_CHUNKS_PER_REQUEST = 64

-- Full-state replies are sent one category at a time under one exchangeID.
-- Labels also require requester eligibility; most categories gate only on sender access.
local FULL_STATE_CATEGORIES = {
    "bans", "recruitmentBlacklist", "nicknames", "altsMains", "macroIgnores",
    "macroRules", "recruitmentItems", "formerMembers", "birthdays",
    "notesOfficer", "notesGeneral", "joinDates", "log", "labels",
}

-- Incomplete exchanges are swept only after raw-transfer retry windows have passed.
local FULL_EXCHANGE_TIMEOUT_SECONDS = 180

-- Keyed by guildKey + sender + exchangeID.
local pendingFullExchanges = {}

-- Heavy raw-transfer apply is deferred during low-FPS or recent-zone moments.
local HEAVY_SYNC_FPS_THRESHOLD = 25
local HEAVY_SYNC_POST_ZONE_COOLDOWN_SECONDS = 30
local HEAVY_SYNC_RECHECK_SECONDS = 2
-- Longer than zone cooldown so one transition gets the full defer window.
local HEAVY_SYNC_MAX_DEFER_SECONDS = 45
local lastZoneEnteredAt = 0

-- Uses measurable client conditions only; no combat/instance/group reads.
local function heavySyncUnsafe()
    if GetFramerate and GetFramerate() < HEAVY_SYNC_FPS_THRESHOLD then
        return true, "low framerate"
    end
    if lastZoneEnteredAt > 0 and (time() - lastZoneEnteredAt) < HEAVY_SYNC_POST_ZONE_COOLDOWN_SECONDS then
        return true, "recent zone transition"
    end
    return false
end

-- Runs once conditions improve, with a bounded starvation fallback.
local function runWhenSyncSafe(deferStartedAt, fn)
    local unsafe = heavySyncUnsafe()
    if not unsafe or (time() - deferStartedAt) >= HEAVY_SYNC_MAX_DEFER_SECONDS then
        fn()
        return
    end
    C_Timer.After(HEAVY_SYNC_RECHECK_SECONDS, function() runWhenSyncSafe(deferStartedAt, fn) end)
end

local helloSent = false
local safetyCatchupSent = false
local startupFullSyncRequestID
local startupFullSyncResponseStarted = false
local fullLogRequestsSent = {}
local fullLogClaims = {}
local rawReceives = {}
local outboundRawTransfers = {}
local outboundSequence = 0
local presencePingSent = false
local unreachableSyncTargets = {}
local activeWhisperTargets = {}

-- Normalized peer name -> outstanding WHISPER sends.
local suppressionRefCounts = {}
-- Grace window after ChatThrottleLib reports a send attempt as complete
-- before assuming no offline-target system message is coming for it.
local SUPPRESSION_GRACE_SECONDS = 2
local guildSyncSystemFilterInstalled = false
local guildSyncSuppressWatcher

-- requestID -> time() marked satisfied. Fan-out suppression: lets
-- HandleHello recognize "someone already fully answered this hello" before
-- sending a redundant reply. Swept on the same cadence as the rest of
-- Guild Sync's runtime caches.
local satisfiedHelloRequests = {}
local SATISFIED_HELLO_TTL_SECONDS = 5 * 60

-- Same fan-out suppression as satisfiedHelloRequests above, for the safety
-- catch-up's own request/reply cycle. Kept as a separate table rather than
-- sharing one with hello, since a hello requestID and a safety requestID
-- are never meant to satisfy each other.
local satisfiedSafetyRequests = {}
local safetyRepliesSent = {}

local RUNTIME_CACHE_SWEEP_SECONDS = 60

local function getLibDeflate()
    if not LibStub then return nil end
    return LibStub:GetLibrary("LibDeflate", true)
end

local function countTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Category counters follow ApplyFullState's fixed application order.
local function newCounts()
    return {
        bans = 0,
        recruitmentBlacklist = 0,
        nicknames = 0,
        altsMains = 0,
        macroIgnores = 0,
        macroRules = 0,
        recruitmentItems = 0,
        formerMembers = 0,
        birthdays = 0,
        notesOfficer = 0,
        notesGeneral = 0,
        joinDates = 0,
        log = 0,
        labels = 0,
    }
end

local function addCount(target, key, amount)
    target[key] = (target[key] or 0) + (tonumber(amount) or 0)
end

-- Builds a counts table from a `*Ts`-shaped table (a real full-state
-- payload, or a locally-assembled equivalent — see GetLocalCounts).
local function countsFromFullPayload(payload)
    local counts = newCounts()
    addCount(counts, "bans", countTable(payload.bansTs or {}))
    addCount(counts, "recruitmentBlacklist", countTable(payload.recruitmentBlacklistTs or {}))
    addCount(counts, "nicknames", countTable(payload.nicksTs or {}))
    addCount(counts, "altsMains", countTable(payload.altsTs or {}) + countTable(payload.mainsTs or {}))
    addCount(counts, "macroIgnores", countTable(payload.macroIgnoresTs or {}))
    addCount(counts, "macroRules", countTable(payload.macroRulesTs or {}))
    addCount(counts, "recruitmentItems", payload.recruitmentSettingsTs and 1 or 0)
    addCount(counts, "formerMembers", countTable(payload.formerMembersTs or {}))
    addCount(counts, "birthdays", countTable(payload.birthdaysTs or {}))
    addCount(counts, "notesOfficer", countTable(payload.customOfficerNotesTs or {}))
    addCount(counts, "notesGeneral", countTable(payload.customNotesTs or {}))
    addCount(counts, "joinDates", countTable(payload.joinDatesTs or {}))
    addCount(counts, "log", #(payload.log or {}) + countTable(payload.logRemoved or {}))
    addCount(counts, "labels", countTable(payload.labelDefinitionsTs or {}) + countTable(payload.labelAssignmentsTs or {}))
    return counts
end

-- Per-category count contribution, keyed by the FULL_STATE_CATEGORIES name
-- (which deliberately matches newCounts()'s field names) instead of reading
-- every field off one combined payload the way countsFromFullPayload does —
-- used by GuildSync:ReceiveFullStateCategory to accumulate ex.receivedCounts
-- one category message at a time.
local function categoryReceivedCount(category, payload)
    if category == "bans" then return countTable(payload.bansTs or {})
    elseif category == "recruitmentBlacklist" then return countTable(payload.recruitmentBlacklistTs or {})
    elseif category == "nicknames" then return countTable(payload.nicksTs or {})
    elseif category == "altsMains" then return countTable(payload.altsTs or {}) + countTable(payload.mainsTs or {})
    elseif category == "macroIgnores" then return countTable(payload.macroIgnoresTs or {})
    elseif category == "macroRules" then return countTable(payload.macroRulesTs or {})
    elseif category == "recruitmentItems" then return payload.recruitmentSettingsTs and 1 or 0
    elseif category == "formerMembers" then return countTable(payload.formerMembersTs or {})
    elseif category == "birthdays" then return countTable(payload.birthdaysTs or {})
    elseif category == "notesOfficer" then return countTable(payload.customOfficerNotesTs or {})
    elseif category == "notesGeneral" then return countTable(payload.customNotesTs or {})
    elseif category == "joinDates" then return countTable(payload.joinDatesTs or {})
    elseif category == "log" then return #(payload.log or {}) + countTable(payload.logRemoved or {})
    elseif category == "labels" then return countTable(payload.labelDefinitionsTs or {}) + countTable(payload.labelAssignmentsTs or {})
    end
    return 0
end

-- Detailed received counters for diagnostics.
local function addReceivedDetail(detailed, category, payload)
    if category == "bans" then
        detailed.bans = detailed.bans + countTable(payload.bansTs or {})
    elseif category == "recruitmentBlacklist" then
        detailed.recruitmentSettings = detailed.recruitmentSettings + countTable(payload.recruitmentBlacklistTs or {})
    elseif category == "recruitmentItems" then
        detailed.recruitmentSettings = detailed.recruitmentSettings + (payload.recruitmentSettingsTs and 1 or 0)
    elseif category == "nicknames" then
        detailed.nicks = detailed.nicks + countTable(payload.nicksTs or {})
    elseif category == "altsMains" then
        detailed.alts = detailed.alts + countTable(payload.altsTs or {})
        detailed.mains = detailed.mains + countTable(payload.mainsTs or {})
    elseif category == "macroIgnores" then
        detailed.macroIgnores = detailed.macroIgnores + countTable(payload.macroIgnoresTs or {})
    elseif category == "macroRules" then
        detailed.macroRules = detailed.macroRules + countTable(payload.macroRulesTs or {})
    elseif category == "formerMembers" then
        detailed.formerMembers = detailed.formerMembers + countTable(payload.formerMembersTs or {})
    elseif category == "birthdays" then
        detailed.birthdays = detailed.birthdays + countTable(payload.birthdaysTs or {})
    elseif category == "joinDates" then
        detailed.joinDates = detailed.joinDates + countTable(payload.joinDatesTs or {})
    elseif category == "notesOfficer" then
        detailed.customOfficerNotes = detailed.customOfficerNotes + countTable(payload.customOfficerNotesTs or {})
    elseif category == "notesGeneral" then
        detailed.customNotes = detailed.customNotes + countTable(payload.customNotesTs or {})
    elseif category == "log" then
        detailed.log = detailed.log + #(payload.log or {})
        detailed.logRemoved = detailed.logRemoved + countTable(payload.logRemoved or {})
    end
end

local function newReceivedDetail()
    return {
        alts = 0, mains = 0, nicks = 0, customNotes = 0, customOfficerNotes = 0,
        formerMembers = 0, joinDates = 0, birthdays = 0, macroRules = 0,
        macroIgnores = 0, bans = 0, recruitmentSettings = 0, logRemoved = 0, log = 0,
    }
end

local function countsForOp(payload)
    local counts = newCounts()
    local op = payload and payload.op
    if op == "ban" then
        counts.bans = 1
    elseif op == "recruitmentblacklist" then
        counts.recruitmentBlacklist = 1
    elseif op == "nick" then
        counts.nicknames = 1
    elseif op == "alt" or op == "altclear" or op == "main" or op == "mainclear" then
        counts.altsMains = 1
    elseif op == "macroignore" then
        counts.macroIgnores = 1
    elseif op == "macrorule" then
        counts.macroRules = 1
    elseif op == "recruitmentsettings" then
        counts.recruitmentItems = 1
    elseif op == "formermember" then
        counts.formerMembers = 1
    elseif op == "birthday" then
        counts.birthdays = 1
    elseif op == "customnote" then
        if payload.scope == "officer" then
            counts.notesOfficer = 1
        else
            counts.notesGeneral = 1
        end
    elseif op == "joindate" then
        counts.joinDates = 1
    elseif op == "fulllogchunk" then
        counts.log = #(payload.entries or {}) + countTable(payload.removed or {})
    elseif op == "logentry" then
        counts.log = 1
    elseif op == "label" then
        counts.labels = 1
    end
    return counts
end

local function mergeCounts(target, counts)
    target = target or newCounts()
    for key, amount in pairs(counts or {}) do
        addCount(target, key, amount)
    end
    return target
end

local function totalCounts(counts)
    local total = 0
    for _, amount in pairs(counts or {}) do
        total = total + (tonumber(amount) or 0)
    end
    return total
end

-- Reentrancy guard: true only while GuildSync itself is applying a remote
-- change through Alts/Nicknames/CustomNotes' normal setters. Those setters fire the
local applyingRemote = false
local senderIsGuildMaster

local function applyRemote(fn)
    applyingRemote = true
    local ok, err = pcall(fn)
    applyingRemote = false
    if not ok then
        GP:Print(string.format(GP.L["Guild Sync error: %s"], tostring(err)))
    end
end

local function applyTimestampMapBatched(source, perItem, onDone)
    local keys = {}
    for key in pairs(source or {}) do
        keys[#keys + 1] = key
    end
    local index = 1
    local function step()
        local limit = math.min(#keys, index + FULL_APPLY_BATCH_SIZE - 1)
        if index <= limit then
            applyRemote(function()
                for i = index, limit do
                    local key = keys[i]
                    perItem(key, source[key])
                end
            end)
        end
        index = limit + 1
        if index <= #keys then
            C_Timer.After(0, step)
        elseif onDone then
            onDone()
        end
    end
    step()
end

-- Officer Labels:
-- Modules/Labels.lua stores per-player assignment as a nested
local LABEL_ASSIGNMENT_KEY_SEP = "\30"

local function flattenLabelAssignments(assignments, assignmentsUpdated)
    local flatValues, flatUpdated = {}, {}
    -- Drive off the `*Updated` table, not the value table, so cleared
    -- records without values still sync.
    for guid, tsMap in pairs(assignmentsUpdated or {}) do
        local labelMap = assignments and assignments[guid]
        for labelId, ts in pairs(tsMap) do
            local key = guid .. LABEL_ASSIGNMENT_KEY_SEP .. labelId
            flatUpdated[key] = ts
            flatValues[key] = labelMap and labelMap[labelId]
        end
    end
    return flatValues, flatUpdated
end

local function splitLabelAssignmentKey(key)
    return key:match("^(.-)" .. LABEL_ASSIGNMENT_KEY_SEP .. "(.+)$")
end

-- Flag index into C_GuildInfo.GuildControlGetRankFlags(rankIndex + 1)'s
-- returned table used to mean "this rank can view officer notes" — matches
local OFFICER_NOTE_RANK_FLAG_INDEX = 12

--                    Scoped to "labels" only. Ban List, Macro Tool
--                    rules/ignores, and officer notes use the existing
local function canRequesterViewOfficerData(guildKey, requesterName)
    if not requesterName or requesterName == "" then return false end
    if not (C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags) then return false end

    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end

    local Roster = GP:GetModule("Roster")
    local _, player = Roster:FindPlayerByName(guildData, requesterName, false)
    local rankIndex = player and tonumber(player.rankIndex)
    if not rankIndex or rankIndex < 0 then return false end

    local flags = GP:SafeCall(C_GuildInfo.GuildControlGetRankFlags, nil, rankIndex + 1)
    if type(flags) ~= "table" then return false end
    return flags[OFFICER_NOTE_RANK_FLAG_INDEX] == true
end

local function localFullPlayerName()
    local name = UnitName and UnitName("player")
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not name or name == "" then return nil end
    if not realm or realm == "" then return name end
    return name .. "-" .. realm
end

local function normalizePeerName(name)
    if not name or name == "" then return nil end
    return tostring(name):lower():match("^([^-]+)")
end

local function syncQueueName(target)
    local key = normalizePeerName(target)
    if not key then return COMM_PREFIX end
    return string.format("%s:WHISPER:%s", COMM_PREFIX, key)
end

-- Built lazily, on first successful attempt, from Blizzard's own localized
-- format string rather than a hardcoded English literal — the same
local playerNotFoundPattern, playerNotFoundNeedle = nil, nil

local function extractPlayerNotFoundName(rawMessage)
    if not playerNotFoundPattern then
        local formatString = _G.ERR_CHAT_PLAYER_NOT_FOUND_S or _G.ERR_PLAYER_NOT_FOUND_S
        if formatString then
            playerNotFoundPattern = GP:BuildChatPattern(formatString)
            playerNotFoundNeedle = GP:BuildChatNeedle(formatString)
        end
    end
    if not playerNotFoundPattern then return nil end
    local message = GP:SafeOptionalString(rawMessage)
    if not message or message == "" then return nil end
    local stripped = GP:StripChatLinkMarkup(message)
    if playerNotFoundNeedle and not stripped:find(playerNotFoundNeedle, 1, true) then return nil end
    local name = stripped:match(playerNotFoundPattern)
    if not name or name == "" then return nil end
    return name
end

local function guildSyncSystemMessageFilter(_, event, message, ...)
    if event ~= "CHAT_MSG_SYSTEM" then return false, message, ... end
    local matchedName = extractPlayerNotFoundName(message)
    if not matchedName or matchedName == "" then return false, message, ... end
    if not GuildSync:IsSyncSuppressionActive(matchedName) then return false, message, ... end
    return true
end

function GuildSync:OnEnable()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, COMM_PREFIX)
    end
    self:RegisterEvent("CHAT_MSG_ADDON", "OnChatMsgAddon")
    self:RegisterEvent("CHAT_MSG_SYSTEM", "OnChatMsgSystem")
    self:RegisterEvent("PLAYER_LOGOUT", "OnPlayerLogout")
    -- Feeds the heavy-sync scheduler's post-zone-transition cooldown —
    -- not a combat/instance read, just "did a loading screen just happen".
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterMessage("GuildParagon_RosterScanned", "OnRosterScanned")
    self:RegisterMessage("GuildParagon_AltsChanged", "OnLocalAltsChanged")
    self:RegisterMessage("GuildParagon_NicknamesChanged", "OnLocalNicknamesChanged")
    self:RegisterMessage("GuildParagon_CustomNotesChanged", "OnLocalCustomNotesChanged")
    self:RegisterMessage("GuildParagon_FormerMemberChanged", "OnLocalFormerMemberChanged")
    self:RegisterMessage("GuildParagon_JoinDateChanged", "OnLocalJoinDateChanged")
    self:RegisterMessage("GuildParagon_BirthdayChanged", "OnLocalBirthdayChanged")
    self:RegisterMessage("GuildParagon_MacroRuleChanged", "OnLocalMacroRuleChanged")
    self:RegisterMessage("GuildParagon_MacroIgnoresChanged", "OnLocalMacroIgnoresChanged")
    self:RegisterMessage("GuildParagon_BanListChanged", "OnLocalBanListChanged")
    self:RegisterMessage("GuildParagon_RecruitmentSettingsChanged", "OnLocalRecruitmentSettingsChanged")
    self:RegisterMessage("GuildParagon_RecruitmentBlacklistChanged", "OnLocalRecruitmentBlacklistChanged")
    self:RegisterMessage("GuildParagon_LogEntryAdded", "OnLocalLogEntryAdded")
    self:RegisterMessage("GuildParagon_LabelsChanged", "OnLocalLabelsChanged")

    if C_Timer and C_Timer.NewTicker and not self.runtimeCacheTicker then
        self.runtimeCacheTicker = C_Timer.NewTicker(RUNTIME_CACHE_SWEEP_SECONDS, function()
            self:CleanupRuntimeCaches()
        end)
    end

    -- The offline-peer suppression filter's install/remove tracks
    -- combat/instance state via the same four events Macro Tool's own
    if not guildSyncSuppressWatcher then
        guildSyncSuppressWatcher = CreateFrame("Frame")
        guildSyncSuppressWatcher:SetScript("OnEvent", function()
            GuildSync:RefreshSystemMessageSuppression()
        end)
    end
    guildSyncSuppressWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
    guildSyncSuppressWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    guildSyncSuppressWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    guildSyncSuppressWatcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RefreshSystemMessageSuppression()
end

function GuildSync:OnDisable()
    if self.runtimeCacheTicker and self.runtimeCacheTicker.Cancel then
        self.runtimeCacheTicker:Cancel()
    end
    self.runtimeCacheTicker = nil
    -- Unregistering the watcher's events (rather than relying on
    -- self:IsEnabled() alone) closes the filter-reinstall leak
    if guildSyncSuppressWatcher then
        guildSyncSuppressWatcher:UnregisterAllEvents()
    end
    if guildSyncSystemFilterInstalled and ChatFrame_RemoveMessageEventFilter then
        pcall(ChatFrame_RemoveMessageEventFilter, "CHAT_MSG_SYSTEM", guildSyncSystemMessageFilter)
        guildSyncSystemFilterInstalled = false
    end
    -- A count left over from a send whose ChatThrottleLib completion
    -- callback hasn't fired yet (module disabled mid-transfer) would
    -- otherwise still be sitting here on a later re-enable, granting stale
    -- suppression eligibility for a peer with no send actually in flight
    -- anymore.
    if table.wipe then
        table.wipe(suppressionRefCounts)
    else
        for key in pairs(suppressionRefCounts) do
            suppressionRefCounts[key] = nil
        end
    end
end

local function ringContains(ring, pipe)
    local first = ring and ring.pos
    if not first or not pipe then return false end
    local current = first
    repeat
        if current == pipe then return true end
        current = current.next
    until not current or current == first
    return false
end

function GuildSync:PurgeSyncWhisperQueue(target)
    if not ChatThrottleLib or not ChatThrottleLib.Prio then return 0 end
    local key = normalizePeerName(target)
    if not key then return 0 end
    local purged = 0
    for _, prio in pairs(ChatThrottleLib.Prio) do
        for queueName, pipe in pairs(prio.ByName or {}) do
            if queueName == syncQueueName(target) or tostring(queueName):lower():find(key, 1, true) then
                if ringContains(prio.Ring, pipe) then
                    pcall(function() prio.Ring:Remove(pipe) end)
                elseif prio.Blocked and ringContains(prio.Blocked, pipe) then
                    pcall(function() prio.Blocked:Remove(pipe) end)
                end
                purged = purged + #(pipe or {})
                if table.wipe then
                    table.wipe(pipe)
                end
                prio.ByName[queueName] = nil
            end
        end
    end
    return purged
end

function GuildSync:MarkSyncWhisperTarget(target)
    local key = normalizePeerName(target)
    if not key then return end
    activeWhisperTargets[key] = time() + RAW_RESEND_CACHE_SECONDS
end

function GuildSync:IsSyncWhisperTarget(target)
    local key = normalizePeerName(target)
    if not key then return false end
    local expires = activeWhisperTargets[key]
    if not expires then return false end
    if expires < time() then
        activeWhisperTargets[key] = nil
        return false
    end
    return true
end

function GuildSync:BeginSyncSuppression(target)
    local key = normalizePeerName(target)
    if not key then return end
    suppressionRefCounts[key] = (suppressionRefCounts[key] or 0) + 1
end

function GuildSync:EndSyncSuppression(target)
    local key = normalizePeerName(target)
    if not key then return end
    local count = suppressionRefCounts[key]
    if not count then return end
    if count <= 1 then
        suppressionRefCounts[key] = nil
    else
        suppressionRefCounts[key] = count - 1
    end
end

function GuildSync:IsSyncSuppressionActive(target)
    local key = normalizePeerName(target)
    if not key then return false end
    return (suppressionRefCounts[key] or 0) > 0
end

function GuildSync:MarkPeerUnreachable(target, reason)
    local key = normalizePeerName(target)
    if not key then return end
    -- Do not clear suppressionRefCounts here. Several sends can already be
    -- queued for this peer; each one keeps and releases its own suppression
    -- window through SendRawMessage's callback.
    unreachableSyncTargets[key] = time() + PEER_PROBABLY_OFFLINE_SECONDS
    self.lastUnreachablePeer = target
    self.lastUnreachableReason = reason or "player not found"
    self.lastUnreachableAt = time()

    for transferID, transfer in pairs(outboundRawTransfers) do
        if transfer and transfer.target and normalizePeerName(transfer.target) == key then
            outboundRawTransfers[transferID] = nil
        end
    end
    for transferID, state in pairs(rawReceives) do
        local sourceKey = normalizePeerName(state and (state.sourceName or state.sender))
        if sourceKey == key then
            rawReceives[transferID] = nil
            self.staleRawTransferCount = (self.staleRawTransferCount or 0) + 1
            self.lastStaleRawTransferAt = time()
            self.lastStaleRawTransferDetail = string.format("%s: abandoned %d/%d chunks from %s; peer unavailable",
                tostring(state.originalOp or "?"), state.received or 0, state.total or 0, tostring(target))
        end
    end
    local purged = self:PurgeSyncWhisperQueue(target)
    if purged > 0 then
        self.lastPurgedSyncWhisperQueueCount = purged
        self.lastPurgedSyncWhisperQueueAt = time()
    end
    self:RecordPeer(target, "Probably offline", nil, reason or "sync whisper target unavailable")
    local Roster = GP:GetModule("Roster", true)
    GP:SendMessage("GuildParagon_SyncStatusChanged", Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil)
end

function GuildSync:IsPeerUnreachable(target)
    local key = normalizePeerName(target)
    if not key then return false end
    local expires = unreachableSyncTargets[key]
    if not expires then return false end
    if expires < time() then
        unreachableSyncTargets[key] = nil
        return false
    end
    return true
end

function GuildSync:FilterSyncSystemMessage(message)
    local matchedName = extractPlayerNotFoundName(message)
    if not matchedName or matchedName == "" then return false end
    local key = normalizePeerName(matchedName)
    if not key or not self:IsSyncWhisperTarget(matchedName) then return false end
    if self:IsPeerUnreachable(matchedName) then
        self:PurgeSyncWhisperQueue(matchedName)
        return true
    end
    self:MarkPeerUnreachable(matchedName, "Blizzard reported sync whisper target offline")
    return true
end

function GuildSync:OnChatMsgSystem(_event, message)
    self:FilterSyncSystemMessage(message)
end

function GuildSync:IsMe(sender)
    if not sender then return false end
    local name = UnitName("player")
    if not name then return false end
    -- Realm resolution can lag during login; the short-name check above
    -- covers that pre-resolve window.
    local full = GP:LocalPlayerFullName()
    return sender == name or (full ~= nil and sender == full)
end

function GuildSync:IsOwnPayload(sender, payload)
    if type(payload) ~= "table" then return false end
    local playerGUID = UnitGUID and UnitGUID("player")
    local isSelf
    local method
    if playerGUID and payload.sourceGUID then
        method = "guid"
        isSelf = payload.sourceGUID == playerGUID
    else
        method = "name-fallback"
        isSelf = self:IsMe(sender)
    end
    self.lastSelfCheck = {
        sender = sender,
        payloadGUID = payload.sourceGUID,
        localGUID = playerGUID,
        method = method,
        result = isSelf,
    }
    return isSelf
end

local function nextDeliveryID()
    outboundSequence = outboundSequence + 1
    return string.format("%s-%s-%d", UnitGUID and UnitGUID("player") or "player", time(), outboundSequence)
end

function GuildSync:PreparePayload(payload)
    payload = payload or {}
    local noSourceStamp = payload.noSourceStamp
    payload.noSourceStamp = nil
    if not noSourceStamp then
        payload.sourceGUID = UnitGUID and UnitGUID("player") or payload.sourceGUID
        payload.sourceName = (UnitName and UnitName("player") or "?") .. "-" .. (GetNormalizedRealmName and GetNormalizedRealmName() or "?")
    end
    return self:Serialize(payload)
end

function GuildSync:CompressRawMessage(message)
    if type(message) ~= "string" or #message < RAW_SYNC_COMPRESSION_MIN_BYTES then
        return message, nil
    end

    local LibDeflate = getLibDeflate()
    if not LibDeflate then
        self.lastCompressionSkippedReason = "LibDeflate unavailable"
        return message, nil
    end

    local ok, compressed = pcall(function()
        return LibDeflate:CompressDeflate(message, { level = 6 })
    end)
    if not ok or type(compressed) ~= "string" or #compressed <= 0 then
        self.lastCompressionSkippedReason = "compression failed"
        return message, nil
    end

    local encodedOk, encoded = pcall(function()
        return LibDeflate:EncodeForWoWAddonChannel(compressed)
    end)
    if not encodedOk or type(encoded) ~= "string" or #encoded <= 0 then
        self.lastCompressionSkippedReason = "compression encoding failed"
        return message, nil
    end

    if (#message - #encoded) < RAW_SYNC_COMPRESSION_MIN_SAVINGS then
        self.lastCompressionSkippedReason = "compression savings too small"
        return message, nil
    end

    local meta = {
        encoding = "deflate-addon",
        originalBytes = #message,
        transferBytes = #encoded,
        savedBytes = #message - #encoded,
    }
    self.lastCompression = {
        originalBytes = meta.originalBytes,
        transferBytes = meta.transferBytes,
        savedBytes = meta.savedBytes,
        ratio = meta.transferBytes / math.max(1, meta.originalBytes),
        at = time(),
    }
    self.lastCompressionSkippedReason = nil
    return encoded, meta
end

function GuildSync:DecompressRawMessage(message, encoding, originalBytes, transferBytes)
    if encoding ~= "deflate-addon" then
        return true, message
    end

    local LibDeflate = getLibDeflate()
    if not LibDeflate then
        return false, "LibDeflate unavailable"
    end

    local decodedOk, decoded = pcall(function()
        return LibDeflate:DecodeForWoWAddonChannel(message)
    end)
    if not decodedOk or type(decoded) ~= "string" then
        return false, "compressed raw decode failed"
    end

    local inflatedOk, inflated = pcall(function()
        return LibDeflate:DecompressDeflate(decoded)
    end)
    if not inflatedOk or type(inflated) ~= "string" then
        return false, "compressed raw inflate failed"
    end

    if tonumber(originalBytes) and #inflated ~= tonumber(originalBytes) then
        return false, "compressed raw size mismatch"
    end

    self.lastDecompression = {
        originalBytes = #inflated,
        transferBytes = tonumber(transferBytes) or #message,
        savedBytes = math.max(0, #inflated - (tonumber(transferBytes) or #message)),
        ratio = (tonumber(transferBytes) or #message) / math.max(1, #inflated),
        at = time(),
    }
    return true, inflated
end

-- Record attempted broadcasts before the send call.
function GuildSync:Broadcast(payload)
    self.lastBroadcastAt = time()
    self.lastBroadcastOp = payload and payload.op
    self:SendRawPayload(payload, "GUILD")
end

function GuildSync:SendToPeer(payload, target)
    payload = payload or {}
    payload.deliveryID = payload.deliveryID or nextDeliveryID()
    if target and target ~= "" then
        return self:SendRawPayload(payload, "WHISPER", target)
    else
        return self:SendRawPayload(payload, "GUILD")
    end
end

function GuildSync:SendToKnownPeers(payload)
    payload = payload or {}
    payload.deliveryID = payload.deliveryID or nextDeliveryID()
    local sentDirect = false
    for target in pairs(self.peerProgress or {}) do
        if target and target ~= "" and not self:IsMe(target) then
            self:SendRawPayload(payload, "WHISPER", target)
            sentDirect = true
        end
    end
    if not sentDirect then
        self:SendRawPayload(payload, "GUILD")
    end
end

function GuildSync:SendToPeerSequential(payload, target, onDone)
    payload = payload or {}
    payload.deliveryID = payload.deliveryID or nextDeliveryID()
    if target and target ~= "" then
        return self:SendRawPayload(payload, "WHISPER", target, onDone)
    else
        return self:SendRawPayload(payload, "GUILD", nil, onDone)
    end
end

-- Routed through ChatThrottleLib instead of calling C_ChatInfo.SendAddonMessage
-- directly. Blizzard silently drops addon messages sent faster than its own
function GuildSync:SendRawMessage(message, distribution, target)
    if not ChatThrottleLib then
        self.lastRejectedReason = "ChatThrottleLib unavailable"
        self.lastRejectedAt = time()
        return false
    end
    local isSyncWhisper = distribution == "WHISPER" and target and target ~= ""
    if isSyncWhisper then
        if self:IsPeerUnreachable(target) then
            self.lastRejectedReason = string.format("sync whisper target unavailable: %s", tostring(target))
            self.lastRejectedAt = time()
            return false
        end
        self:MarkSyncWhisperTarget(target)
        -- Every WHISPER-distribution sync send — chunked, resent, or a
        -- short direct message — flows through here, so this one counter
        -- increment covers all three without the caller needing to know
        -- which kind of send it's making.
        self:BeginSyncSuppression(target)
    end

    local ok, result = pcall(function()
        local queueName = distribution == "WHISPER" and target and syncQueueName(target) or COMM_PREFIX
        return ChatThrottleLib:SendAddonMessage("NORMAL", COMM_PREFIX, message, distribution, target, queueName, function(_, didSend)
            if isSyncWhisper then
                if didSend == false then
                    -- Each send releases its own suppression contribution;
                    -- MarkPeerUnreachable handles peer cleanup only.
                    self:MarkPeerUnreachable(target, "addon whisper send failed")
                    self:EndSyncSuppression(target)
                else
                    C_Timer.After(SUPPRESSION_GRACE_SECONDS, function()
                        self:EndSyncSuppression(target)
                    end)
                end
            end
        end)
    end)
    if not ok then
        -- The CTL call itself errored before queuing, so its callback above
        -- will never fire — release the increment now or it leaks forever.
        if isSyncWhisper then
            self:EndSyncSuppression(target)
        end
        self.lastRejectedReason = string.format("throttled addon send failed: %s", tostring(result))
        self.lastRejectedAt = time()
        return false
    end
    return true
end

function GuildSync:SendRawPayload(payload, distribution, target, onDone)
    payload = payload or {}
    local isRawWrapper = payload.op == "rawstart" or payload.op == "rawchunk"
    if not isRawWrapper then
        payload.deliveryID = payload.deliveryID or nextDeliveryID()
    end
    local message = self:PreparePayload(payload)
    if #message <= RAW_SYNC_DIRECT_BYTES then
        local sent = self:SendRawMessage(message, distribution, target)
        if sent and onDone then C_Timer.After(RAW_SYNC_CHUNK_DELAY, onDone) end
        return sent
    end
    if isRawWrapper then
        self.lastRejectedReason = string.format("raw wrapper too large: %d", #message)
        self.lastRejectedAt = time()
        return false
    end

    local transferID = payload.deliveryID
    local compressionMeta
    message, compressionMeta = self:CompressRawMessage(message)
    local total = math.max(1, math.ceil(#message / RAW_SYNC_CHUNK_BYTES))
    self:CleanupRawTransferCaches()
    outboundRawTransfers[transferID] = {
        chunks = {},
        createdAt = time(),
        expiresAt = time() + RAW_RESEND_CACHE_SECONDS,
        originalOp = payload.op,
        total = total,
        totalBytes = #message,
        encoding = compressionMeta and compressionMeta.encoding or nil,
        originalBytes = compressionMeta and compressionMeta.originalBytes or #message,
        distribution = distribution,
        target = target,
        counts = payload.op == "full" and countsFromFullPayload(payload) or nil,
    }
    -- noSourceStamp keeps rawstart below the direct-message size limit.
    -- Raw-transfer readers already fall back to the wire-level
    -- CHAT_MSG_ADDON sender when source fields are absent, matching
    -- rawchunk behavior.
    local startSent = self:SendRawPayload({
        v = PROTOCOL_VERSION,
        op = "rawstart",
        noSourceStamp = true,
        transferID = transferID,
        originalOp = payload.op,
        total = total,
        totalBytes = #message,
        encoding = compressionMeta and compressionMeta.encoding or nil,
        originalBytes = compressionMeta and compressionMeta.originalBytes or nil,
        helloRequestID = payload.helloRequestID,
    }, distribution, target)
    if not startSent then
        self.lastRawChunkSendFailedDetail = string.format("rawstart for %s to %s", tostring(transferID), tostring(target))
        self.lastRawChunkSendFailedAt = time()
    end

    local function sendChunk(index)
        if index > total then
            if onDone then onDone() end
            return
        end
        if distribution == "WHISPER" and target and target ~= "" and self:IsPeerUnreachable(target) then
            if payload.op == "full" then
                self:RecordPeer(target, "Probably offline", countsFromFullPayload(payload),
                    string.format("stopped at %d/%d raw chunk(s)", math.max(0, index - 1), total), "snapshot")
                local Roster = GP:GetModule("Roster", true)
                GP:SendMessage("GuildParagon_SyncStatusChanged", Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil)
            end
            outboundRawTransfers[transferID] = nil
            if onDone then onDone() end
            return
        end

        local startIndex = ((index - 1) * RAW_SYNC_CHUNK_BYTES) + 1
        local part = string.sub(message, startIndex, startIndex + RAW_SYNC_CHUNK_BYTES - 1)
        local cached = outboundRawTransfers[transferID]
        if cached then
            cached.chunks[index] = part
            cached.expiresAt = time() + RAW_RESEND_CACHE_SECONDS
        end
        -- Record synchronous send failures so the Guild Sync tab can show
        -- which chunk failed; SendRawPayload/SendRawMessage keep the
        -- underlying rejection reason.
        local sent = self:SendRawPayload({
            v = PROTOCOL_VERSION,
            op = "rawchunk",
            noSourceStamp = true,
            transferID = transferID,
            index = index,
            total = total,
            data = part,
        }, distribution, target)
        if not sent then
            self.lastRawChunkSendFailedDetail = string.format("chunk %d/%d to %s", index, total, tostring(target))
            self.lastRawChunkSendFailedAt = time()
        end

        if payload.op == "full" and target and (index == 1 or index % 50 == 0 or index == total) then
            self:RecordPeer(target, "Sending raw full state", countsFromFullPayload(payload),
                string.format("%d/%d raw chunk(s)%s", index, total,
                    compressionMeta and string.format("; compressed %d -> %d bytes", compressionMeta.originalBytes, compressionMeta.transferBytes) or ""),
                "snapshot")
            GP:SendMessage("GuildParagon_SyncStatusChanged", GP:GetModule("Roster"):GetGuildKey())
        end

        C_Timer.After(RAW_SYNC_CHUNK_DELAY, function() sendChunk(index + 1) end)
    end

    C_Timer.After(RAW_SYNC_CHUNK_DELAY, function() sendChunk(1) end)
    return true
end

local function rawTransferKey(payload)
    return tostring(payload and payload.transferID or "?")
end

local function peerNamesMatch(a, b)
    if not a or not b then return false end
    if a == b then return true end
    if tostring(a):find("-", 1, true) or tostring(b):find("-", 1, true) then return false end
    local aShort = tostring(a):match("^([^-]+)")
    local bShort = tostring(b):match("^([^-]+)")
    return aShort and bShort and aShort == bShort
end

function GuildSync:CleanupRawTransferCaches()
    local now = time()
    for transferID, state in pairs(outboundRawTransfers) do
        if not state.expiresAt or state.expiresAt <= now then
            outboundRawTransfers[transferID] = nil
        end
    end
end

local function rawRecoveryPaused()
    if InCombatLockdown and InCombatLockdown() then return true end
    if IsInInstance then
        local ok, inInstance, instanceType = pcall(IsInInstance)
        if ok and inInstance and instanceType and instanceType ~= "none" and not HOUSING_INSTANCE_TYPES[instanceType] then return true end
    end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
        if ok and active then return true end
    end
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        if ok and mapID then return true end
    end
    return false
end

function GuildSync:RefreshSystemMessageSuppression()
    if not ChatFrame_AddMessageEventFilter or not ChatFrame_RemoveMessageEventFilter then
        guildSyncSystemFilterInstalled = false
        return
    end
    local shouldInstall = self:IsEnabled() and not rawRecoveryPaused()
    if shouldInstall and not guildSyncSystemFilterInstalled then
        local ok = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", guildSyncSystemMessageFilter)
        guildSyncSystemFilterInstalled = ok and true or false
    elseif not shouldInstall and guildSyncSystemFilterInstalled then
        pcall(ChatFrame_RemoveMessageEventFilter, "CHAT_MSG_SYSTEM", guildSyncSystemMessageFilter)
        guildSyncSystemFilterInstalled = false
    end
end

function GuildSync:CleanupRuntimeCaches()
    local now = time()
    self:CleanupRawTransferCaches()

    for key, expires in pairs(activeWhisperTargets) do
        if not expires or expires <= now then
            activeWhisperTargets[key] = nil
        end
    end
    for key, expires in pairs(unreachableSyncTargets) do
        if not expires or expires <= now then
            unreachableSyncTargets[key] = nil
        end
    end
    for requestID, markedAt in pairs(satisfiedHelloRequests) do
        if not markedAt or (now - markedAt) > SATISFIED_HELLO_TTL_SECONDS then
            satisfiedHelloRequests[requestID] = nil
        end
    end
    for requestID, markedAt in pairs(satisfiedSafetyRequests) do
        if not markedAt or (now - markedAt) > SATISFIED_HELLO_TTL_SECONDS then
            satisfiedSafetyRequests[requestID] = nil
        end
    end
    for requestID, markedAt in pairs(safetyRepliesSent) do
        if not markedAt or (now - markedAt) > SATISFIED_HELLO_TTL_SECONDS then
            safetyRepliesSent[requestID] = nil
        end
    end

    -- ExpireStaleRawReceives can send missing-chunk retry whispers. Keep that
    -- recovery path paused during combat/instance/Mythic+ lockdown checks, but
    -- still release expired outbound caches and old peer markers above.
    if not rawRecoveryPaused() then
        self:ExpireStaleRawReceives()
    end

    -- Sweep abandoned exchanges; outbound retries remain protected below.
    self:SweepStaleFullExchanges()
end

function GuildSync:GetMissingRawChunks(state, maxChunks)
    local missing, totalMissing = {}, 0
    local total = tonumber(state and state.total) or 0
    if total <= 0 then return missing, totalMissing end
    for index = 1, total do
        if not state.chunks or not state.chunks[index] then
            totalMissing = totalMissing + 1
            if #missing < maxChunks then
                missing[#missing + 1] = index
            end
        end
    end
    return missing, totalMissing
end

function GuildSync:RequestMissingRawChunks(guildKey, state, reason)
    if not state or not state.transferID then return false end
    -- rawmissing is classified as heavy-control traffic: it's small on its own, but it triggers more
    -- chunk traffic and, eventually, another decompress/apply pass once
    if heavySyncUnsafe() then return false, "unsafe" end
    local missing, totalMissing = self:GetMissingRawChunks(state, RAW_MISSING_CHUNKS_PER_REQUEST)
    if #missing == 0 then return false end
    local target = state.sourceName or state.sender
    if not target or target == "" then return false end
    if self:IsPeerUnreachable(target) then
        self.lastRawMissingRequestAt = time()
        self.lastRawMissingRequestDetail = string.format("%s: abandoned retry; %s is unavailable",
            tostring(state.originalOp or "?"), tostring(target))
        self:RecordPeer(target, "Probably offline", nil, self.lastRawMissingRequestDetail)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        return false
    end

    state.retryAttempts = (state.retryAttempts or 0) + 1

    local sent = self:SendToPeer({
        v = PROTOCOL_VERSION,
        op = "rawmissing",
        transferID = state.transferID,
        originalOp = state.originalOp,
        chunks = missing,
        totalMissing = totalMissing,
        received = state.received or 0,
        total = state.total or 0,
        reason = reason or "idle",
    }, target)
    if not sent then
        self.lastRawMissingRequestAt = time()
        self.lastRawMissingRequestDetail = string.format("%s: abandoned retry; could not reach %s",
            tostring(state.originalOp or "?"), tostring(target))
        self:RecordPeer(target, "Probably offline", nil, self.lastRawMissingRequestDetail)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        return false
    end

    state.lastMissingRequestAt = time()
    state.lastActivityAt = time()

    self.lastRawMissingRequestAt = time()
    self.lastRawMissingRequestDetail = string.format("%s: requested %d/%d missing chunk(s) from %s; attempt %d/%d",
        tostring(state.originalOp or "?"), #missing, totalMissing, tostring(target),
        state.retryAttempts or 0, RAW_MISSING_RETRY_LIMIT)
    self:RecordPeer(target, "Requested raw retry", nil, self.lastRawMissingRequestDetail)
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    return true
end

function GuildSync:ExpireStaleRawReceives()
    local now = time()
    for key, state in pairs(rawReceives) do
        local lastActivityAt = state.lastActivityAt or state.startedAt
        if lastActivityAt and (now - lastActivityAt) > RAW_TRANSFER_STALE_SECONDS then
            local target = state.sourceName or state.sender

            local function abandon(detail)
                rawReceives[key] = nil
                self.staleRawTransferCount = (self.staleRawTransferCount or 0) + 1
                self.lastStaleRawTransferAt = now
                self.lastStaleRawTransferDetail = detail
            end

            if target and target ~= "" and self:IsPeerUnreachable(target) then
                abandon(string.format("%s: abandoned %d/%d chunks from %s; peer unavailable",
                    tostring(state.originalOp or "?"), state.received or 0, state.total or 0, tostring(target)))
            elseif (state.retryAttempts or 0) < RAW_MISSING_RETRY_LIMIT then
                local sent, requestReason = self:RequestMissingRawChunks(GP:GetModule("Roster"):GetGuildKey(), state, "idle")
                if sent then
                    self.lastStaleRawTransferAt = now
                    self.lastStaleRawTransferDetail = self.lastRawMissingRequestDetail
                elseif requestReason == "unsafe" then
                    -- heavySyncUnsafe() deferring
                    -- the retry is not a real retry failure — the old code
                    self.lastStaleRawTransferAt = now
                    self.lastStaleRawTransferDetail = string.format(
                        "%s: %d/%d chunks from %s; retry deferred (heavy-sync scheduler)",
                        tostring(state.originalOp or "?"), state.received or 0, state.total or 0,
                        tostring(state.sourceName or state.sender or "?"))
                else
                    abandon(string.format("%s: %d/%d chunks from %s; idle %ds; retries %d/%d",
                        tostring(state.originalOp or "?"), state.received or 0, state.total or 0,
                        tostring(state.sourceName or state.sender or "?"), now - lastActivityAt,
                        state.retryAttempts or 0, RAW_MISSING_RETRY_LIMIT))
                end
            else
                abandon(string.format("%s: %d/%d chunks from %s; idle %ds; retries %d/%d",
                    tostring(state.originalOp or "?"), state.received or 0, state.total or 0,
                    tostring(state.sourceName or state.sender or "?"), now - lastActivityAt,
                    state.retryAttempts or 0, RAW_MISSING_RETRY_LIMIT))
            end
        end
    end
end

function GuildSync:GetPendingRawTransferInfo()
    local count, oldestAge, oldestIdle, oldestReceived, oldestTotal, oldestOp = 0, nil, nil, nil, nil, nil
    local now = time()
    for _, state in pairs(rawReceives) do
        count = count + 1
        local age = now - (state.startedAt or now)
        local idle = now - (state.lastActivityAt or state.startedAt or now)
        if not oldestAge or age > oldestAge then
            oldestAge, oldestIdle, oldestReceived, oldestTotal, oldestOp = age, idle, state.received, state.total, state.originalOp
        end
    end
    return count, oldestAge, oldestReceived, oldestTotal, oldestOp, oldestIdle
end

function GuildSync:HandleRawStart(guildKey, payload, sender)
    self:ExpireStaleRawReceives()
    if not payload or not payload.transferID then return end
    local key = rawTransferKey(payload)
    local state = rawReceives[key] or { chunks = {}, received = 0, startedAt = time() }
    state.lastActivityAt = time()
    state.sourceGUID = payload.sourceGUID
    state.sourceName = payload.sourceName
    state.sender = sender
    state.transferID = payload.transferID
    state.originalOp = payload.originalOp
    state.total = tonumber(payload.total) or state.total or 0
    state.totalBytes = tonumber(payload.totalBytes) or state.totalBytes or 0
    state.encoding = payload.encoding
    state.originalBytes = tonumber(payload.originalBytes) or state.originalBytes or state.totalBytes
    rawReceives[key] = state
    if payload.originalOp == "full" then
        if payload.helloRequestID == startupFullSyncRequestID or (startupFullSyncRequestID and not payload.helloRequestID) then
            self:MarkStartupFullSyncResponseStarted("raw full state started", payload.sourceName or sender)
        end
        self:RecordPeer(payload.sourceName or sender, "Raw full state claimed", nil,
            string.format("%d/%d raw chunk(s)%s", state.received or 0, state.total or 0,
                state.encoding == "deflate-addon" and string.format("; compressed %d -> %d bytes", state.originalBytes or 0, state.totalBytes or 0) or ""))
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end
end

function GuildSync:HandleRawChunk(guildKey, payload, sender)
    self:ExpireStaleRawReceives()
    if not payload or not payload.transferID or not payload.index or type(payload.data) ~= "string" then return end
    local key = rawTransferKey(payload)
    local state = rawReceives[key]
    if not state then
        state = {
            sender = sender,
            transferID = payload.transferID,
            total = tonumber(payload.total) or 0,
            chunks = {},
            received = 0,
            startedAt = time(),
            lastActivityAt = time(),
            encoding = payload.encoding,
            originalBytes = tonumber(payload.originalBytes),
            totalBytes = tonumber(payload.totalBytes),
        }
        rawReceives[key] = state
    end

    local index = tonumber(payload.index) or 0
    if index <= 0 then return end
    state.total = math.max(state.total or 0, tonumber(payload.total) or 0)
    if not state.chunks[index] then
        state.chunks[index] = payload.data
        state.received = (state.received or 0) + 1
        state.lastActivityAt = time()
    end

    local peerName = state.sourceName or payload.sourceName or sender
    if state.originalOp == "full" and (state.received == 1 or state.received % 50 == 0 or (state.total > 0 and state.received >= state.total)) then
        self:RecordPeer(peerName, "Receiving raw full state", nil,
            string.format("%d/%d raw chunk(s)%s", state.received or 0, state.total or 0,
                state.encoding == "deflate-addon" and string.format("; compressed %d -> %d bytes", state.originalBytes or 0, state.totalBytes or 0) or ""))
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end

    if state.total <= 0 or state.received < state.total then return end

    local pieces = {}
    for i = 1, state.total do
        if not state.chunks[i] then return end
        pieces[i] = state.chunks[i]
    end
    rawReceives[key] = nil

    -- Defer concat/decompress/deserialize/apply during measured bad moments.
    local deferStartedAt = time()
    runWhenSyncSafe(deferStartedAt, function()
        -- Timed so /gp perf can report the raw apply pipeline.
        local perfMark = GP:PerfMark()
        local transferDetail = string.format("%s, %d chunks, from %s",
            tostring(state.originalOp or "?"), state.total or 0, tostring(peerName or "?"))
        local assembled, decodedOrReason, innerPayload
        local concatMs, decompressMs, deserializeMs = 0, 0, 0

        local function processPayload()
            self.lastHeavySyncTiming = {
                op = innerPayload.op, category = innerPayload.category,
                concatMs = concatMs, decompressMs = decompressMs, deserializeMs = deserializeMs,
                deferredMs = (time() - deferStartedAt) * 1000, at = time(),
            }
            self:ProcessPayload(guildKey, innerPayload, innerPayload.sourceName or peerName)
            GP:PerfRecord("GuildSync raw decode/apply", perfMark)
        end

        local function deserializePayload()
            local deserializeStart = debugprofilestop and debugprofilestop() or 0
            local ok
            ok, innerPayload = self:Deserialize(decodedOrReason)
            deserializeMs = (debugprofilestop and debugprofilestop() or 0) - deserializeStart
            if not ok or type(innerPayload) ~= "table" or innerPayload.v ~= PROTOCOL_VERSION then
                self.lastRejectedReason = string.format("raw sync reassembly failed (%s)", transferDetail)
                self.lastRejectedAt = time()
                GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
                return
            end
            C_Timer.After(0, processPayload)
        end

        local function decompressPayload()
            local decompressStart = debugprofilestop and debugprofilestop() or 0
            local decodedOk
            decodedOk, decodedOrReason = self:DecompressRawMessage(assembled, state.encoding, state.originalBytes, state.totalBytes)
            decompressMs = (debugprofilestop and debugprofilestop() or 0) - decompressStart
            assembled = nil
            if not decodedOk then
                self.lastRejectedReason = string.format("%s (%s)", decodedOrReason or "compressed raw sync failed", transferDetail)
                self.lastRejectedAt = time()
                GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
                return
            end
            C_Timer.After(0, deserializePayload)
        end

        local concatStart = debugprofilestop and debugprofilestop() or 0
        assembled = table.concat(pieces, "")
        concatMs = (debugprofilestop and debugprofilestop() or 0) - concatStart
        C_Timer.After(0, decompressPayload)
    end)
end

function GuildSync:HandleRawMissing(guildKey, payload, sender)
    self:CleanupRawTransferCaches()
    if not payload or not payload.transferID or type(payload.chunks) ~= "table" then return end
    local transfer = outboundRawTransfers[tostring(payload.transferID)]
    local requester = payload.sourceName or sender
    if not transfer then
        self:RecordIgnored("raw retry requested for expired transfer", requester)
        return
    end
    if transfer.target and transfer.target ~= "" and not peerNamesMatch(requester, transfer.target) and not peerNamesMatch(sender, transfer.target) then
        self:RecordIgnored("raw retry requested by non-target peer", requester)
        return
    end

    local requested = {}
    for _, index in ipairs(payload.chunks) do
        index = tonumber(index) or 0
        if index > 0 and index <= (transfer.total or 0) and transfer.chunks[index] then
            requested[#requested + 1] = index
            if #requested >= RAW_MISSING_CHUNKS_PER_REQUEST then break end
        end
    end
    if #requested == 0 then
        self:RecordIgnored("raw retry requested no cached chunks", requester)
        return
    end

    local distribution, target = "GUILD", nil
    if requester and requester ~= "" then
        distribution, target = "WHISPER", requester
    elseif transfer.distribution == "WHISPER" and transfer.target then
        distribution, target = "WHISPER", transfer.target
    end

    -- noSourceStamp: see the matching comment on SendRawPayload's own
    -- rawstart send — same size-budget reasoning, same safe fallback to
    -- the wire-level sender for every reader of this state.
    local restartSent = self:SendRawPayload({
        v = PROTOCOL_VERSION,
        op = "rawstart",
        noSourceStamp = true,
        transferID = payload.transferID,
        originalOp = transfer.originalOp,
        total = transfer.total,
        totalBytes = transfer.totalBytes,
        encoding = transfer.encoding,
        originalBytes = transfer.originalBytes,
    }, distribution, target)
    if not restartSent then
        self.lastRawChunkSendFailedDetail = string.format("resend rawstart for %s to %s", tostring(payload.transferID), tostring(target))
        self.lastRawChunkSendFailedAt = time()
    end

    local function resendChunk(position)
        local index = requested[position]
        if not index then return end
        if distribution == "WHISPER" and target and target ~= "" and self:IsPeerUnreachable(target) then
            self:RecordPeer(target, "Probably offline", transfer.counts,
                string.format("stopped missing-chunk resend after %d/%d chunk(s)", math.max(0, position - 1), #requested), "snapshot")
            GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
            return
        end
        -- Match sendChunk diagnostics: record synchronous resend failures
        -- with the missing chunk position that failed.
        local sent = self:SendRawPayload({
            v = PROTOCOL_VERSION,
            op = "rawchunk",
            noSourceStamp = true,
            transferID = payload.transferID,
            index = index,
            total = transfer.total,
            data = transfer.chunks[index],
        }, distribution, target)
        if not sent then
            self.lastRawChunkSendFailedDetail = string.format("resend chunk %d for %s to %s",
                index, tostring(payload.transferID), tostring(target))
            self.lastRawChunkSendFailedAt = time()
        end
        C_Timer.After(RAW_SYNC_CHUNK_DELAY, function()
            resendChunk(position + 1)
        end)
    end
    C_Timer.After(RAW_SYNC_CHUNK_DELAY, function()
        resendChunk(1)
    end)

    transfer.expiresAt = time() + RAW_RESEND_CACHE_SECONDS
    self.lastRawMissingReplyAt = time()
    -- "Resending", not "resent": the actual sends above are deferred via
    -- C_Timer.After and haven't happened yet at this point, let alone been
    -- confirmed delivered — this only records that a resend was queued.
    self.lastRawMissingReplyDetail = string.format("%s: resending %d chunk(s) to %s for %s",
        tostring(transfer.originalOp or "?"), #requested, tostring(requester or "?"), tostring(payload.transferID))
    self:RecordPeer(requester, "Resending raw chunks", transfer.counts,
        string.format("%d requested chunk(s)", #requested), "snapshot")
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
end

-- Snapshot mode:    A full-state exchange reports the sender's *entire*
--                    current total for every category, not a new delta.
function GuildSync:RecordPeer(sender, status, counts, details, mode)
    if not sender then return end
    self.peerProgress = self.peerProgress or {}

    local peerKey = sender
    local senderNameKey = normalizePeerName(sender)
    if senderNameKey and not self.peerProgress[peerKey] then
        for existingKey in pairs(self.peerProgress) do
            if normalizePeerName(existingKey) == senderNameKey then
                peerKey = existingKey
                break
            end
        end
    end

    local peer = self.peerProgress[peerKey]
    if not peer then
        peer = { name = sender, counts = newCounts(), firstSeen = time() }
        self.peerProgress[peerKey] = peer
    end

    peer.lastSeen = time()
    peer.name = peer.name or sender
    peer.status = status or peer.status
    peer.details = details or peer.details
    if mode == "snapshot" then
        peer.counts = counts or newCounts()
    else
        peer.counts = mergeCounts(peer.counts, counts)
    end
    self.categoryProgress = self:ComputeCategoryProgress()
end

function GuildSync:ComputeCategoryProgress()
    local totals = newCounts()
    for _, peer in pairs(self.peerProgress or {}) do
        mergeCounts(totals, peer.counts)
    end
    return totals
end

function GuildSync:GetPeerProgress()
    local rows = {}
    local now = time()
    for _, peer in pairs(self.peerProgress or {}) do
        local age = peer.lastSeen and (now - peer.lastSeen) or 0
        if age < PEER_HIDE_AFTER_SECONDS then
            local row = peer
            if age >= PEER_PROBABLY_OFFLINE_SECONDS then
                row = {}
                for key, value in pairs(peer) do row[key] = value end
                row.displayStatus = GP.L["Probably offline"]
                row.isProbablyOffline = true
            end
            table.insert(rows, row)
        end
    end
    table.sort(rows, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
    return rows
end

function GuildSync:GetCategoryProgress()
    return self.categoryProgress or newCounts()
end

function GuildSync:RecordIgnored(reason, sender)
    self.lastIgnoredReason = reason or "ignored"
    self.lastIgnoredFrom = sender
    self.lastIgnoredAt = time()
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if guildKey then GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey) end
end

function GuildSync:GetSyncMeta(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil end
    guildData.syncMeta = guildData.syncMeta or {}
    return guildData.syncMeta
end

function GuildSync:MarkFullSyncExchange(guildKey, ts)
    local meta = self:GetSyncMeta(guildKey)
    if not meta then return end
    meta.lastFullStateExchangeAt = ts or time()
end

function GuildSync:MarkStartupFullSyncResponseStarted(reason, sender)
    if not startupFullSyncRequestID or startupFullSyncResponseStarted then return end
    startupFullSyncResponseStarted = true
    self.lastStartupFullSyncResponseStartedAt = time()
    self.lastStartupFullSyncResponseStartedReason = reason
    self.lastStartupFullSyncResponseStartedFrom = sender
end

function GuildSync:ShouldRequestStartupFullSync(guildKey)
    local meta = self:GetSyncMeta(guildKey)
    local now = time()
    local last = meta and tonumber(meta.lastFullStateExchangeAt)
    if not last or last <= 0 then
        return true, GP.L["first sync for this guild"]
    end
    if (now - last) >= STARTUP_FULL_SYNC_INTERVAL_SECONDS then
        return true, GP.L["last full sync is older than 24 hours"]
    end
    return false, string.format(GP.L["last full sync was %s"], date("%Y-%m-%d %H:%M", last))
end

function GuildSync:OnRosterScanned(_event, guildKey)
    if helloSent or not guildKey then return end
    helloSent = true
    self:SchedulePresencePings(guildKey)
    local shouldRequest, reason = self:ShouldRequestStartupFullSync(guildKey)
    if shouldRequest then
        local requestID = self:BroadcastHello()
        startupFullSyncRequestID = requestID
        startupFullSyncResponseStarted = false
        self.lastStartupFullSyncRequestedAt = self.lastHelloSent
        self.lastStartupFullSyncReason = reason
        self.lastSafetyRequestReason = "deferred; startup full sync has priority"
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        C_Timer.After(STARTUP_FULL_SYNC_SAFETY_FALLBACK_SECONDS, function()
            if startupFullSyncRequestID == requestID and not startupFullSyncResponseStarted and not safetyCatchupSent then
                if self:RequestSafetyCatchup("startup safety fallback") then
                    safetyCatchupSent = true
                end
            end
        end)
        C_Timer.After(8, function()
            self:MaybeRequestFullLogBootstrap(guildKey)
        end)
    else
        self:ScheduleSafetyCatchups(guildKey)
        self.lastStartupSyncSkippedAt = time()
        self.lastStartupSyncSkippedReason = reason
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end
end

function GuildSync:BuildSafetyPayload(guildKey)
    local BanList = GP:GetModule("BanList")
    local Recruitment = GP:GetModule("Recruitment")
    local recruitmentSettings, recruitmentSettingsUpdated = Recruitment:GetGuildSettingsForSync(guildKey)
    local recruitmentBlacklist, recruitmentBlacklistUpdated = Recruitment:GetBlacklistForSync(guildKey)
    local bans, bansUpdated = {}, {}
    if BanList:CanUse() then
        bans, bansUpdated = BanList:GetAllForSync(guildKey)
    end

    return {
        v = PROTOCOL_VERSION,
        op = "safetyfull",
        recruitmentSettings = recruitmentSettings,
        recruitmentSettingsTs = recruitmentSettingsUpdated,
        recruitmentBlacklist = recruitmentBlacklist,
        recruitmentBlacklistTs = recruitmentBlacklistUpdated,
        bans = bans,
        bansTs = bansUpdated,
    }
end

function GuildSync:RequestSafetyCatchup(reason)
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildKey then return false end
    if self.pendingSafetyRequestID and satisfiedSafetyRequests[self.pendingSafetyRequestID] then
        self:RecordIgnored("safety catch-up already satisfied", nil)
        return false
    end
    local requestID = self.pendingSafetyRequestID or nextDeliveryID()
    self.pendingSafetyRequestID = requestID
    self:Broadcast({ v = PROTOCOL_VERSION, op = "safetyhello", reason = reason or "startup safety", requestID = requestID })
    self.lastSafetyRequestSentAt = time()
    self.lastSafetyRequestReason = reason or "startup safety"
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    return true
end

function GuildSync:ScheduleSafetyCatchups(guildKey)
    if safetyCatchupSent or not guildKey then return end
    safetyCatchupSent = true
    self:RequestSafetyCatchup("startup safety")
    C_Timer.After(10, function() self:RequestSafetyCatchup("startup safety retry") end)
    C_Timer.After(30, function() self:RequestSafetyCatchup("startup safety retry") end)
end

function GuildSync:SendSafetyState(guildKey, requestedBy, safetyRequestID)
    if not guildKey then return end
    local payload = self:BuildSafetyPayload(guildKey)
    payload.safetyRequestID = safetyRequestID
    -- Broadcast rather than whisper: these records are timestamp-merged and
    -- cross-faction/cross-realm whisper delivery is not reliable in guilds.
    self:Broadcast(payload)
    self.lastSafetyReplySentTo = requestedBy
    self.lastSafetyReplySentAt = time()
    self.lastSafetyReplySentCounts = countsFromFullPayload(payload)
    self:RecordPeer(requestedBy, "Safety state sent", self.lastSafetyReplySentCounts, "recruitment/ban")
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
end

function GuildSync:RequestSync()
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildKey then return false end
    helloSent = true
    self:BroadcastHello()
    return true
end

function GuildSync:BroadcastHello()
    local requestID = nextDeliveryID()
    self.pendingHelloRequestID = requestID
    self:Broadcast({ v = PROTOCOL_VERSION, op = "hello", requestID = requestID })
    self.lastHelloSent = time()
    return requestID
end

function GuildSync:SendPresencePing(reason)
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildKey then return false end
    self:Broadcast({ v = PROTOCOL_VERSION, op = "ping", reason = reason or "presence" })
    self.lastPresenceSentAt = time()
    self.lastPresenceReason = reason or "presence"
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    return true
end

function GuildSync:OnPlayerLogout()
    self:SendLogoutNotice()
end

function GuildSync:OnPlayerEnteringWorld()
    lastZoneEnteredAt = time()
end

function GuildSync:SendLogoutNotice()
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildKey then return end

    local message = self:PreparePayload({ v = PROTOCOL_VERSION, op = "bye", reason = "logout" })
    pcall(C_ChatInfo.SendAddonMessage, COMM_PREFIX, message, "GUILD")
end

function GuildSync:SchedulePresencePings(guildKey)
    if presencePingSent or not guildKey then return end
    presencePingSent = true
    self:SendPresencePing("startup")
    C_Timer.After(10, function() self:SendPresencePing("startup retry") end)
    C_Timer.After(30, function() self:SendPresencePing("startup retry") end)
end

function GuildSync:MaybeRequestFullLogBootstrap(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or guildData.fullLogBootstrapCompleted or fullLogRequestsSent[guildKey] then return false end

    local count = GP:GetModule("EventLog"):CountDisplayable(guildKey)
    if count > FULL_LOG_BOOTSTRAP_LOCAL_LIMIT then return false end
    return self:RequestFullLogBootstrap(guildKey, false)
end

function GuildSync:RequestFullLogBootstrap(guildKey, manual)
    if not SYNC_EVENT_LOG then return false end
    guildKey = guildKey or GP:GetModule("Roster"):GetGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false end
    if guildData.fullLogBootstrapCompleted and not manual then return false end

    -- GP:LocalPlayerFullName() nil-guards GetNormalizedRealmName() for the pre-resolve window.
    local requestID = (GP:LocalPlayerFullName() or "?") .. "-" .. time() .. "-" .. math.random(1000, 9999)
    fullLogRequestsSent[guildKey] = true
    guildData.fullLogBootstrapRequestedAt = time()
    self.fullLogBootstrap = {
        requestID = requestID,
        requestedAt = guildData.fullLogBootstrapRequestedAt,
        requestedManual = manual and true or false,
        received = 0,
        total = 0,
        applied = 0,
        considered = 0,
    }

    self:SendToKnownPeers({
        v = PROTOCOL_VERSION,
        op = "fulllogrequest",
        requestID = requestID,
        count = GP:GetModule("EventLog"):CountDisplayable(guildKey),
    })
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    C_Timer.After(FULL_LOG_BOOTSTRAP_TIMEOUT, function()
        local state = self.fullLogBootstrap
        if not state or state.requestID ~= requestID or state.received > 0 then return end
        state.timedOut = true
        state.timedOutAt = time()
        fullLogRequestsSent[guildKey] = nil
        self:RecordIgnored("full log bootstrap timed out waiting for chunks", nil)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end)
    return true
end

function GuildSync:GetFullLogReplaceProviders(guildKey, officerFallback)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end

    local candidates = {}
    for _, player in pairs(guildData.roster or {}) do
        if player.online and player.name and not self:IsMe(player.name) then
            local rankIndex = tonumber(player.rankIndex)
            if not officerFallback and rankIndex == 0 and not GP:IsGuildMaster() then
                table.insert(candidates, player)
            elseif officerFallback and rankIndex and rankIndex > 0 then
                table.insert(candidates, player)
            end
        end
    end
    table.sort(candidates, function(a, b)
        local ar, br = tonumber(a.rankIndex) or 999, tonumber(b.rankIndex) or 999
        if ar ~= br then return ar < br end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    return candidates
end

function GuildSync:GetFullLogReplaceProvider(guildKey, officerFallback)
    local candidates = self:GetFullLogReplaceProviders(guildKey, officerFallback)
    local picked = candidates[1]
    if not picked then return nil end
    return picked.name, officerFallback and "officer" or "guild master", candidates, 1
end

function GuildSync:StartFullLogReplaceRequest(guildKey, targetName, targetRole, fallbackTried, candidates, candidateIndex)
    local EventLog = GP:GetModule("EventLog")
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not targetName then return false, GP.L["No suitable Event Log sync source is online."] end

    -- GP:LocalPlayerFullName() nil-guards GetNormalizedRealmName() for the pre-resolve window.
    local requestID = (GP:LocalPlayerFullName() or "?") .. "-logreplace-" .. time() .. "-" .. math.random(1000, 9999)
    fullLogRequestsSent[guildKey] = true
    guildData.fullLogBootstrapRequestedAt = time()
    self.fullLogBootstrap = {
        requestID = requestID,
        mode = "replace",
        requestedAt = guildData.fullLogBootstrapRequestedAt,
        requestedManual = true,
        targetName = targetName,
        targetRole = targetRole,
        fallbackTried = fallbackTried and true or false,
        candidates = candidates,
        candidateIndex = candidateIndex,
        received = 0,
        total = 0,
        applied = 0,
        considered = 0,
        entryChunks = {},
    }

    self:Broadcast({
        v = PROTOCOL_VERSION,
        op = "fulllogrequest",
        requestID = requestID,
        mode = "replace",
        requester = localFullPlayerName(),
        target = targetName,
        targetRole = targetRole,
        count = EventLog:CountDisplayable(guildKey),
    })
    self:RecordPeer(targetName, "Full log requested", nil, targetRole or "replace")
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)

    C_Timer.After(15, function()
        local state = self.fullLogBootstrap
        if not state or state.requestID ~= requestID or state.claimedAt or (state.received or 0) > 0 then return end
        if targetRole == "officer" and type(state.candidates) == "table" and (state.candidateIndex or 0) < #state.candidates then
            local nextIndex = (state.candidateIndex or 0) + 1
            local nextCandidate = state.candidates[nextIndex]
            if nextCandidate and nextCandidate.name then
                self:StartFullLogReplaceRequest(guildKey, nextCandidate.name, "officer", true, state.candidates, nextIndex)
                return
            end
        end
        if targetRole == "guild master" and not state.fallbackTried then
            local fallbackTarget, fallbackRole, fallbackCandidates, fallbackIndex = self:GetFullLogReplaceProvider(guildKey, true)
            if fallbackTarget then
                self:StartFullLogReplaceRequest(guildKey, fallbackTarget, fallbackRole, true, fallbackCandidates, fallbackIndex)
                return
            end
        end

        state.timedOut = true
        state.timedOutAt = time()
        state.failureReason = GP.L["No suitable Event Log sync source responded."]
        fullLogRequestsSent[guildKey] = nil
        self:RecordIgnored(state.failureReason, targetName)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end)

    C_Timer.After(FULL_LOG_BOOTSTRAP_TIMEOUT, function()
        local state = self.fullLogBootstrap
        if not state or state.requestID ~= requestID or state.completedAt then return end
        state.timedOut = true
        state.timedOutAt = time()
        state.failureReason = GP.L["Full Event Log sync timed out."]
        fullLogRequestsSent[guildKey] = nil
        self:RecordIgnored(state.failureReason, targetName)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end)
    return true
end

function GuildSync:RequestFullLogReplace()
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildKey then return false, GP.L["No roster data yet — try /gp scan."] end
    local state = self.fullLogBootstrap
    if state and state.requestID and not state.completedAt and not state.timedOut then
        return false, GP.L["A full Event Log sync is already in progress."]
    end

    local targetName, targetRole, candidates, candidateIndex = self:GetFullLogReplaceProvider(guildKey, false)
    if not targetName then
        targetName, targetRole, candidates, candidateIndex = self:GetFullLogReplaceProvider(guildKey, true)
    end
    if not targetName then
        return false, GP.L["No suitable Event Log sync source is online."]
    end
    return self:StartFullLogReplaceRequest(guildKey, targetName, targetRole, targetRole ~= "guild master", candidates, candidateIndex)
end

-- Outgoing: local changes -> network

function GuildSync:OnLocalAltsChanged(_event, _guildKey, op, guid, mainGUID, ts)
    if applyingRemote or not op then return end

    if op == "set" then
        self:Broadcast({ v = PROTOCOL_VERSION, op = "alt", guid = guid, main = mainGUID, ts = ts })
    elseif op == "clear" then
        self:Broadcast({ v = PROTOCOL_VERSION, op = "altclear", guid = guid, ts = ts })
    elseif op == "mainset" then
        self:Broadcast({ v = PROTOCOL_VERSION, op = "main", guid = guid, ts = ts })
    elseif op == "mainclear" then
        self:Broadcast({ v = PROTOCOL_VERSION, op = "mainclear", guid = guid, ts = ts })
    end
end

function GuildSync:OnLocalNicknamesChanged(_event, _guildKey, guid, nick, ts)
    if applyingRemote or not guid or not ts then return end
    self:Broadcast({ v = PROTOCOL_VERSION, op = "nick", guid = guid, nick = nick, ts = ts })
end

function GuildSync:OnLocalCustomNotesChanged(_event, _guildKey, scope, guid, note, ts)
    if applyingRemote or not guid or not ts then return end
    if scope ~= "officer" and not SYNC_GENERAL_NOTES then return end
    local CustomNotes = GP:GetModule("CustomNotes")
    if scope == "officer" and not CustomNotes:CanAccessOfficerNotes() then return end
    self:Broadcast({ v = PROTOCOL_VERSION, op = "customnote", scope = scope, guid = guid, note = note, ts = ts })
end

function GuildSync:OnLocalBirthdayChanged(_event, guildKey, guid, _day, _month, ts)
    if not SYNC_BIRTHDAYS then return end
    if applyingRemote or not guid or type(ts) ~= "number" then return end
    local birthday = GP:GetModule("Roster"):GetBirthdayForSync(guildKey, guid)
    self:Broadcast({ v = PROTOCOL_VERSION, op = "birthday", guid = guid, birthday = birthday, ts = ts })
end

function GuildSync:OnLocalFormerMemberChanged(_event, guildKey, guid, _player, ts)
    if applyingRemote or not guildKey or not guid or type(ts) ~= "number" then return end
    local formerMember, updatedAt = GP:GetModule("Roster"):GetFormerMemberForSync(guildKey, guid)
    if not formerMember then return end
    self:Broadcast({ v = PROTOCOL_VERSION, op = "formermember", guid = guid, formerMember = formerMember, ts = updatedAt or ts })
end

function GuildSync:OnLocalJoinDateChanged(_event, guildKey, guid, _firstSeen, _source, ts)
    if not SYNC_JOIN_DATES then return end
    if applyingRemote or not guid or type(ts) ~= "number" then return end
    local joinDate = GP:GetModule("Roster"):GetJoinDateForSync(guildKey, guid)
    self:Broadcast({ v = PROTOCOL_VERSION, op = "joindate", guid = guid, joinDate = joinDate, ts = ts })
end

function GuildSync:OnLocalMacroRuleChanged(_event, name, rule, ts)
    if applyingRemote or not name or type(ts) ~= "number" then return end
    local MacroTool = GP:GetModule("MacroTool")
    if not MacroTool:CanUse() then return end
    self:Broadcast({ v = PROTOCOL_VERSION, op = "macrorule", name = name, rule = rule, ts = ts })
end

function GuildSync:OnLocalMacroIgnoresChanged(_event, guildKey, guid, _action, _value, ts, changedGUIDs)
    if applyingRemote or type(ts) ~= "number" then return end
    local MacroTool = GP:GetModule("MacroTool")
    if not MacroTool:CanUse() then return end

    if type(changedGUIDs) == "table" and #changedGUIDs > 0 then
        for _, changedGUID in ipairs(changedGUIDs) do
            self:Broadcast({
                v = PROTOCOL_VERSION, op = "macroignore",
                guid = changedGUID,
                ignore = MacroTool:GetPlayerIgnoreForSync(guildKey, changedGUID),
                ts = ts,
            })
        end
        return
    end

    if guid then
        self:Broadcast({
            v = PROTOCOL_VERSION, op = "macroignore",
            guid = guid,
            ignore = MacroTool:GetPlayerIgnoreForSync(guildKey, guid),
            ts = ts,
        })
    end
end

function GuildSync:OnLocalBanListChanged(_event, guildKey, id, record, ts)
    if applyingRemote or not guildKey or not id or type(ts) ~= "number" then return end
    local BanList = GP:GetModule("BanList")
    if not BanList:CanUse() then return end
    self:Broadcast({
        v = PROTOCOL_VERSION, op = "ban",
        id = id,
        record = record,
        ts = ts,
    })
end

function GuildSync:OnLocalRecruitmentSettingsChanged(_event, guildKey, settings, ts)
    if applyingRemote or not guildKey or type(settings) ~= "table" or type(ts) ~= "number" then return end
    if not GP:IsGuildMaster() then return end
    self:Broadcast({
        v = PROTOCOL_VERSION, op = "recruitmentsettings",
        settings = settings,
        ts = ts,
    })
end

function GuildSync:OnLocalRecruitmentBlacklistChanged(_event, guildKey, id, record, ts)
    if applyingRemote or not guildKey or not id or type(ts) ~= "number" then return end
    self:Broadcast({
        v = PROTOCOL_VERSION, op = "recruitmentblacklist",
        id = id,
        record = record,
        ts = ts,
    })
end

function GuildSync:OnLocalLogEntryAdded(_event, guildKey, entry)
    if applyingRemote or not guildKey or type(entry) ~= "table" then return end
    if entry.type ~= "removed" and not (entry.type == "join" and entry.invitedBy and entry.recruitmentContact) then return end
    self:Broadcast({
        v = PROTOCOL_VERSION,
        op = "logentry",
        entry = entry,
        ts = entry.ts,
    })
end

-- Live single-record label changes, unlike the full-state "labels"
-- category above, have no single "requester" to check eligibility
function GuildSync:OnLocalLabelsChanged(_event, guildKey, kind, ...)
    if applyingRemote or not guildKey then return end
    local Labels = GP:GetModule("Labels")
    if not Labels:CanUse() then return end

    if kind == "definition" then
        local labelId, record, ts = ...
        if not labelId or type(ts) ~= "number" then return end
        self:Broadcast({ v = PROTOCOL_VERSION, op = "label", kind = "definition", labelId = labelId, record = record, ts = ts })
    elseif kind == "assignment" then
        local guid, labelId, isAssigned, ts = ...
        if not guid or not labelId or type(ts) ~= "number" then return end
        self:Broadcast({ v = PROTOCOL_VERSION, op = "label", kind = "assignment", guid = guid, labelId = labelId, assigned = isAssigned and true or false, ts = ts })
    end
end

-- Incoming: network -> local state

function GuildSync:ProcessPayload(guildKey, payload, sender)
    local peerName = payload.sourceName or sender
    if payload.op ~= "rawstart" and payload.op ~= "rawchunk" then
        self:RecordPeer(peerName, "Heard", nil, payload.op or "no op")
    end

    if payload.op == "rawstart" then
        self:HandleRawStart(guildKey, payload, sender)
    elseif payload.op == "rawchunk" then
        self:HandleRawChunk(guildKey, payload, sender)
    elseif payload.op == "rawmissing" then
        self:HandleRawMissing(guildKey, payload, sender)
    elseif payload.op == "hello" then
        self.lastHelloReceivedFrom = peerName
        self.lastHelloReceivedAt = time()
        self:RecordPeer(peerName, "Sync requested", nil, "Awaiting full-state reply")
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        self:HandleHello(guildKey, peerName, payload.requestID)
    elseif payload.op == "hellosatisfied" then
        self:HandleHelloSatisfied(payload)
    elseif payload.op == "ping" then
        self.lastPresenceReceivedFrom = peerName
        self.lastPresenceReceivedAt = time()
        self:RecordPeer(peerName, "Online", nil, payload.reason or "presence")
        self:SendToPeer({ v = PROTOCOL_VERSION, op = "pong", reason = "presence reply" }, nil)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    elseif payload.op == "pong" then
        self.lastPresenceReceivedFrom = peerName
        self.lastPresenceReceivedAt = time()
        self:RecordPeer(peerName, "Online", nil, payload.reason or "presence reply")
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    elseif payload.op == "bye" then
        -- Explicit logout notice: run unreachable-peer cleanup immediately.
        -- Quiet-peer timeout still covers crashes and hard exits.
        self:MarkPeerUnreachable(peerName, "peer logged out")
    elseif payload.op == "safetyhello" then
        self:RecordPeer(peerName, "Safety sync requested", nil, payload.reason or "startup safety")
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        self:HandleSafetyHello(guildKey, peerName, payload.requestID)
    elseif payload.op == "safetysatisfied" then
        self:HandleSafetySatisfied(payload)
    elseif payload.op == "safetyfull" then
        -- Safety payloads can arrive as the inner payload of a just-decoded
        -- raw transfer. Apply on the next frame so decode/deserialize and
        -- merge/count work do not all live in one event handler slice.
        C_Timer.After(0, function()
            self:ApplySafetyState(guildKey, payload, peerName)
        end)
    elseif payload.op == "full" then
        self:ReceiveFullStateCategory(guildKey, payload, peerName)
    elseif payload.op == "fulllogrequest" then
        self:RecordPeer(peerName, "Full log requested", nil, "Waiting for a peer to claim")
        self:HandleFullLogRequest(guildKey, payload, peerName)
    elseif payload.op == "fulllogclaim" then
        self:HandleFullLogClaim(payload, peerName)
    elseif payload.op == "fulllogchunk" then
        self:ApplyFullLogChunk(guildKey, payload, peerName)
    elseif payload.op == "logentry" then
        self:ApplyLogEntry(guildKey, payload)
    elseif payload.op == "alt" then
        self:ApplyAlt(guildKey, payload)
    elseif payload.op == "altclear" then
        self:ApplyAltClear(guildKey, payload)
    elseif payload.op == "main" then
        self:ApplyMain(guildKey, payload)
    elseif payload.op == "mainclear" then
        self:ApplyMainClear(guildKey, payload)
    elseif payload.op == "nick" then
        self:ApplyNick(guildKey, payload)
    elseif payload.op == "customnote" then
        self:ApplyCustomNote(guildKey, payload)
    elseif payload.op == "joindate" then
        self:ApplyJoinDate(guildKey, payload)
    elseif payload.op == "birthday" then
        self:ApplyBirthday(guildKey, payload)
    elseif payload.op == "formermember" then
        self:ApplyFormerMember(guildKey, payload)
    elseif payload.op == "macrorule" then
        self:ApplyMacroRule(payload)
    elseif payload.op == "macroignore" then
        self:ApplyMacroIgnore(guildKey, payload)
    elseif payload.op == "ban" then
        self:ApplyBan(guildKey, payload)
    elseif payload.op == "recruitmentsettings" then
        self:ApplyRecruitmentSettings(guildKey, payload, peerName)
    elseif payload.op == "recruitmentblacklist" then
        self:ApplyRecruitmentBlacklist(guildKey, payload)
    elseif payload.op == "label" then
        self:ApplyLabel(guildKey, payload)
    else
        self:RecordIgnored(string.format("unknown op: %s", tostring(payload.op)), sender)
    end

    if payload.op ~= "hello" and payload.op ~= "ping" and payload.op ~= "pong" and payload.op ~= "safetyhello" and payload.op ~= "safetyfull" and payload.op ~= "full" and payload.op ~= "rawstart" and payload.op ~= "rawchunk" and payload.op ~= "rawmissing" and payload.op ~= "fulllogrequest"
        and payload.op ~= "fulllogclaim" and payload.op ~= "fulllogchunk" then
        self:RecordPeer(peerName, "Live update", countsForOp(payload), payload.op)
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end
end

function GuildSync:OnChatMsgAddon(_event, prefix, message, _distribution, sender)
    if prefix ~= COMM_PREFIX then return end
    self.rawReceiveCount = (self.rawReceiveCount or 0) + 1
    self.lastRawReceivedFrom = sender
    self.lastRawReceivedAt = time()

    local ok, payload = self:Deserialize(message)
    if not ok or type(payload) ~= "table" then
        self.lastRejectedReason, self.lastRejectedAt = "undeserializable", time()
        return
    end
    if payload.v ~= PROTOCOL_VERSION then
        self.lastRejectedReason = string.format("protocol v%s (expected v%d)", tostring(payload.v), PROTOCOL_VERSION)
        self.lastRejectedAt = time()
        return
    end
    if self:IsOwnPayload(sender, payload) then
        self.lastIgnoredReason = "self echo"
        self.lastIgnoredFrom = sender
        self.lastIgnoredAt = time()
        self.lastIgnoredDetail = self.lastSelfCheck
        return
    end

    -- Never trust a remote-supplied guild key: distribution "GUILD" can
    -- only reach members of *our own* current guild anyway, so the guild
    -- this data belongs to is always whichever one we're actually in.
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self.lastRejectedReason, self.lastRejectedAt = "no local guild key yet", time()
        return
    end

    self:ProcessPayload(guildKey, payload, sender)
end

function GuildSync:ApplySafetyState(guildKey, payload, sender)
    local perfMark = GP:PerfMark()
    local BanList = GP:GetModule("BanList")
    local Recruitment = GP:GetModule("Recruitment")
    local considered, applied = 0, 0
    local receivedCounts = countsFromFullPayload(payload)

    local preMergeCounts = self:GetLocalCounts(guildKey)
    local skippedCategories, totalCategories = 0, 0

    local function finishSafety()
        GP:PerfRecord("GuildSync:ApplySafetyState", perfMark)
        self.lastSafetySyncReceivedAt = time()
        self.lastSafetySyncReceivedFrom = sender
        self.lastSafetySyncCounts = {
            considered = considered,
            applied = applied,
            receivedTotal = totalCounts(receivedCounts),
        }
        self:RecordPeer(sender, "Safety state received", receivedCounts,
            string.format("%d merged; %d newer; %d/%d categories already up to date",
                applied, considered, skippedCategories, totalCategories), "snapshot")
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)

        local requestID = payload and payload.safetyRequestID
        if requestID and self.pendingSafetyRequestID == requestID then
            self.pendingSafetyRequestID = nil
            satisfiedSafetyRequests[requestID] = time()
            self:Broadcast({ v = PROTOCOL_VERSION, op = "safetysatisfied", requestID = requestID })
        end
    end

    local function applyRecruitmentSettings()
        if payload.recruitmentSettingsTs and type(payload.recruitmentSettingsTs) == "number" and senderIsGuildMaster(guildKey, sender) then
            applyRemote(function()
                local current = Recruitment:GetGuildSettingsUpdatedAt(guildKey)
                if not current or payload.recruitmentSettingsTs > current then
                    considered = considered + 1
                    local ok = Recruitment:SetGuildSettingsFromSync(guildKey, payload.recruitmentSettings, payload.recruitmentSettingsTs)
                    if ok then applied = applied + 1 end
                end
            end)
        end
        finishSafety()
    end

    local function applyRecruitmentBlacklist()
        totalCategories = totalCategories + 1
        if countTable(payload.recruitmentBlacklistTs or {}) > (preMergeCounts.recruitmentBlacklist or 0) then
            applyTimestampMapBatched(payload.recruitmentBlacklistTs, function(id, ts)
                local current = Recruitment:GetBlacklistUpdatedAt(guildKey, id)
                if (not current or ts > current) and type(ts) == "number" then
                    considered = considered + 1
                    local ok = Recruitment:SetBlacklistFromSync(guildKey, id, payload.recruitmentBlacklist and payload.recruitmentBlacklist[id], ts)
                    if ok then applied = applied + 1 end
                end
            end, applyRecruitmentSettings)
        else
            skippedCategories = skippedCategories + 1
            applyRecruitmentSettings()
        end
    end

    if BanList:CanUse() then
        totalCategories = totalCategories + 1
        if countTable(payload.bansTs or {}) > (preMergeCounts.bans or 0) then
            -- First bulk ban catch-up should not log every imported record.
            local logBanEvents = BanList:GetTotalStoredCount(guildKey) > 0
            applyTimestampMapBatched(payload.bansTs, function(id, ts)
                local current = BanList:GetUpdatedAt(guildKey, id)
                if (not current or ts > current) and type(ts) == "number" then
                    considered = considered + 1
                    local ok = BanList:SetFromSync(guildKey, id, payload.bans and payload.bans[id], ts, logBanEvents)
                    if ok then applied = applied + 1 end
                end
            end, applyRecruitmentBlacklist)
        else
            skippedCategories = skippedCategories + 1
            applyRecruitmentBlacklist()
        end
    else
        applyRecruitmentBlacklist()
    end
end

function GuildSync:HandleHello(guildKey, sender, requestID)
    if requestID and satisfiedHelloRequests[requestID] then
        self:RecordIgnored("hello already satisfied by another peer", sender)
        return
    end
    C_Timer.After(math.random(10, 30) / 10, function()
        if requestID and satisfiedHelloRequests[requestID] then
            self:RecordIgnored("hello already satisfied by another peer", sender)
            return
        end
        self:SendFullState(guildKey, sender, requestID)
    end)
end

function GuildSync:HandleHelloSatisfied(payload)
    local requestID = payload and payload.requestID
    if not requestID then return end
    satisfiedHelloRequests[requestID] = time()
end

function GuildSync:HandleSafetyHello(guildKey, sender, requestID)
    if requestID and satisfiedSafetyRequests[requestID] then
        self:RecordIgnored("safety catch-up already satisfied by another peer", sender)
        return
    end
    if requestID and safetyRepliesSent[requestID] then
        self:RecordIgnored("safety catch-up reply already sent", sender)
        return
    end
    C_Timer.After(math.random(5, 15) / 10, function()
        if requestID and satisfiedSafetyRequests[requestID] then
            self:RecordIgnored("safety catch-up already satisfied by another peer", sender)
            return
        end
        if requestID and safetyRepliesSent[requestID] then
            self:RecordIgnored("safety catch-up reply already sent", sender)
            return
        end
        if requestID then safetyRepliesSent[requestID] = time() end
        self:SendSafetyState(guildKey, sender, requestID)
    end)
end

function GuildSync:HandleSafetySatisfied(payload)
    local requestID = payload and payload.requestID
    if not requestID then return end
    satisfiedSafetyRequests[requestID] = time()
end

local function formerMemberSyncCount(guildData)
    local count = 0
    for _, player in pairs((guildData and guildData.formerMembers) or {}) do
        if type(player) == "table" and type(player.name) == "string" and player.name ~= "" then
            local info = player.birthdayInfo
            local ts = math.max(
                tonumber(player.leftDate) or 0,
                tonumber(player.lastSeen) or 0,
                tonumber(player.firstSeen) or 0,
                tonumber(player.joinDateUpdated) or 0,
                type(info) == "table" and (tonumber(info.timeUpdated) or 0) or 0
            )
            if ts > 0 then count = count + 1 end
        end
    end
    return count
end

local function joinDateSyncCount(guildData)
    local count = 0
    local function addBucket(bucket)
        for _, player in pairs(bucket or {}) do
            if type(player) == "table" and type(player.joinDateUpdated) == "number" then
                count = count + 1
            end
        end
    end
    addBucket(guildData and guildData.roster)
    addBucket(guildData and guildData.formerMembers)
    return count
end

local function birthdaySyncCount(guildData)
    local count = 0
    local function addBucket(bucket)
        for _, player in pairs(bucket or {}) do
            local info = type(player) == "table" and player.birthdayInfo
            local dateInfo = type(info) == "table" and info.date
            if type(info) == "table" and type(info.timeUpdated) == "number" and type(dateInfo) == "table" then
                local day, month = tonumber(dateInfo[1]), tonumber(dateInfo[2])
                if day and month and day > 0 and month > 0 then
                    count = count + 1
                end
            end
        end
    end
    addBucket(guildData and guildData.roster)
    addBucket(guildData and guildData.formerMembers)
    return count
end

function GuildSync:GetLocalCounts(guildKey)
    local Alts = GP:GetModule("Alts")
    local Nicknames = GP:GetModule("Nicknames")
    local CustomNotes = GP:GetModule("CustomNotes")
    local MacroTool = GP:GetModule("MacroTool")
    local BanList = GP:GetModule("BanList")
    local Recruitment = GP:GetModule("Recruitment")
    local Labels = GP:GetModule("Labels")
    local guildData = guildKey and GP.db.global.guilds[guildKey]

    local _, altsUpdated, _, mainsUpdated = Alts:GetAllForSync(guildKey)
    local _, nicksUpdated = Nicknames:GetAllForSync(guildKey)
    local _, customNotesUpdated, _, customOfficerNotesUpdated = CustomNotes:GetAllForSync(guildKey)
    local macroRulesUpdated, macroIgnoresUpdated = {}, {}
    if MacroTool:CanUse() then
        local _, ruleTs = MacroTool:GetSavedRulesForSync()
        local _, ignoreTs = MacroTool:GetMacroIgnoresForSync(guildKey)
        macroRulesUpdated, macroIgnoresUpdated = ruleTs, ignoreTs
    end
    local bansUpdated = {}
    if BanList:CanUse() then
        local _, ts = BanList:GetAllForSync(guildKey)
        bansUpdated = ts
    end
    local _, recruitmentSettingsUpdated = Recruitment:GetGuildSettingsForSync(guildKey)
    local _, recruitmentBlacklistUpdated = Recruitment:GetBlacklistForSync(guildKey)
    -- This is a report of what the local client already has, not a
    -- requester-eligibility question (that only applies to deciding what
    -- to SEND a given peer) — gating on Labels:CanUse() alone, same as
    -- bansUpdated/macroRulesUpdated above, is correct here.
    local labelDefinitionsUpdated, labelAssignmentsUpdatedFlat = {}, {}
    if Labels:CanUse() then
        local _, defsUpdated, _, assignmentsUpdated = Labels:GetAllForSync(guildKey)
        local _, flatUpdated = flattenLabelAssignments(nil, assignmentsUpdated)
        labelDefinitionsUpdated, labelAssignmentsUpdatedFlat = defsUpdated, flatUpdated
    end

    local counts = countsFromFullPayload({
        altsTs = altsUpdated, mainsTs = mainsUpdated,
        nicksTs = nicksUpdated,
        customNotesTs = customNotesUpdated, customOfficerNotesTs = customOfficerNotesUpdated,
        macroRulesTs = macroRulesUpdated, macroIgnoresTs = macroIgnoresUpdated,
        bansTs = bansUpdated,
        recruitmentSettingsTs = recruitmentSettingsUpdated,
        recruitmentBlacklistTs = recruitmentBlacklistUpdated,
        labelDefinitionsTs = labelDefinitionsUpdated, labelAssignmentsTs = labelAssignmentsUpdatedFlat,
        log = {}, logRemoved = {},
    })
    counts.formerMembers = formerMemberSyncCount(guildData)
    counts.joinDates = joinDateSyncCount(guildData)
    counts.birthdays = birthdaySyncCount(guildData)
    return counts
end

function GuildSync:SendFullState(guildKey, requestedBy, helloRequestID)
    local Alts = GP:GetModule("Alts")
    local Nicknames = GP:GetModule("Nicknames")
    local CustomNotes = GP:GetModule("CustomNotes")
    local EventLog = GP:GetModule("EventLog")
    local MacroTool = GP:GetModule("MacroTool")
    local Roster = GP:GetModule("Roster")
    local BanList = GP:GetModule("BanList")
    local Recruitment = GP:GetModule("Recruitment")
    local Labels = GP:GetModule("Labels")

    local alts, altsUpdated, mains, mainsUpdated = {}, {}, {}, {}
    local nicks, nicksUpdated = {}, {}
    local customNotes, customNotesUpdated, customOfficerNotes, customOfficerNotesUpdated = {}, {}, {}, {}
    local joinDates, joinDatesUpdated = {}, {}
    local formerMembers, formerMembersUpdated = {}, {}
    local birthdays, birthdaysUpdated = {}, {}
    local log, logRemoved = {}, {}
    local macroRules, macroRulesUpdated, macroIgnores, macroIgnoresUpdated = {}, {}, {}, {}
    local bans, bansUpdated = {}, {}
    local recruitmentSettings, recruitmentSettingsUpdated, recruitmentBlacklist, recruitmentBlacklistUpdated
    local labelDefinitions, labelDefinitionsUpdated, labelAssignments, labelAssignmentsUpdated = {}, {}, {}, {}
    local categoryFields = {}

    local function finishSend()
        if helloRequestID and satisfiedHelloRequests[helloRequestID] then
            self:RecordIgnored("hello already satisfied before full-state send completed", requestedBy)
            return
        end

        -- Omit categories unavailable to this sender or disabled by settings.
        if not BanList:CanUse() then categoryFields.bans = nil end
        if not MacroTool:CanUse() then
            categoryFields.macroIgnores = nil
            categoryFields.macroRules = nil
        end
        if not SYNC_BIRTHDAYS then categoryFields.birthdays = nil end
        if not SYNC_GENERAL_NOTES then categoryFields.notesGeneral = nil end
        if not SYNC_JOIN_DATES then categoryFields.joinDates = nil end
        if not Labels:CanUse() or not requestedBy or not canRequesterViewOfficerData(guildKey, requestedBy) then
            categoryFields.labels = nil
        end
        if not SYNC_EVENT_LOG then categoryFields.log = nil end

        local expectedCategories = {}
        for _, category in ipairs(FULL_STATE_CATEGORIES) do
            if categoryFields[category] then
                expectedCategories[#expectedCategories + 1] = category
            end
        end

        local exchangeID = nextDeliveryID()
        for _, category in ipairs(expectedCategories) do
            local categoryPayload = categoryFields[category]
            categoryPayload.v = PROTOCOL_VERSION
            categoryPayload.op = "full"
            categoryPayload.exchangeID = exchangeID
            categoryPayload.exchangeKind = "full"
            categoryPayload.category = category
            categoryPayload.expectedCategories = expectedCategories
            categoryPayload.helloRequestID = helloRequestID
            if requestedBy then
                self:SendToPeer(categoryPayload, requestedBy)
            else
                self:Broadcast(categoryPayload)
            end
        end

        self.lastReplySentTo = requestedBy
        self.lastReplySentAt = time()
        self:MarkFullSyncExchange(guildKey, self.lastReplySentAt)
        self.lastReplySentCounts = {
            alts = countTable(altsUpdated), mains = countTable(mainsUpdated), nicks = countTable(nicksUpdated),
            customNotes = countTable(customNotesUpdated), customOfficerNotes = countTable(customOfficerNotesUpdated),
            formerMembers = countTable(formerMembersUpdated),
            joinDates = countTable(joinDatesUpdated),
            birthdays = countTable(birthdaysUpdated),
            macroRules = countTable(macroRulesUpdated), macroIgnores = countTable(macroIgnoresUpdated),
            bans = countTable(bansUpdated),
            recruitmentSettings = (recruitmentSettingsUpdated and 1 or 0) + countTable(recruitmentBlacklistUpdated or {}),
            logRemoved = countTable(logRemoved),
            log = #log,
        }
        local sentCounts = newCounts()
        addCount(sentCounts, "bans", countTable(bansUpdated))
        addCount(sentCounts, "recruitmentBlacklist", countTable(recruitmentBlacklistUpdated))
        addCount(sentCounts, "nicknames", countTable(nicksUpdated))
        addCount(sentCounts, "altsMains", countTable(altsUpdated) + countTable(mainsUpdated))
        addCount(sentCounts, "macroIgnores", countTable(macroIgnoresUpdated))
        addCount(sentCounts, "macroRules", countTable(macroRulesUpdated))
        addCount(sentCounts, "recruitmentItems", recruitmentSettingsUpdated and 1 or 0)
        addCount(sentCounts, "formerMembers", countTable(formerMembersUpdated))
        addCount(sentCounts, "birthdays", countTable(birthdaysUpdated))
        addCount(sentCounts, "notesOfficer", countTable(customOfficerNotesUpdated))
        addCount(sentCounts, "notesGeneral", countTable(customNotesUpdated))
        addCount(sentCounts, "joinDates", countTable(joinDatesUpdated))
        addCount(sentCounts, "log", #log + countTable(logRemoved))
        addCount(sentCounts, "labels",
            categoryFields.labels and (countTable(labelDefinitionsUpdated) + countTable(labelAssignmentsUpdated)) or 0)
        self:RecordPeer(requestedBy, "Full state sent", sentCounts,
            string.format("%d log entries, %d categories", #log, #expectedCategories), "snapshot")
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
    end

    local steps = {
        function()
            alts, altsUpdated, mains, mainsUpdated = Alts:GetAllForSync(guildKey)
            categoryFields.altsMains = { alts = alts, altsTs = altsUpdated, mains = mains, mainsTs = mainsUpdated }
        end,
        function()
            nicks, nicksUpdated = Nicknames:GetAllForSync(guildKey)
            categoryFields.nicknames = { nicks = nicks, nicksTs = nicksUpdated }
        end,
        function()
            customNotes, customNotesUpdated, customOfficerNotes, customOfficerNotesUpdated = CustomNotes:GetAllForSync(guildKey)
            if not SYNC_GENERAL_NOTES then
                customNotes, customNotesUpdated = {}, {}
            end
            categoryFields.notesOfficer = { customOfficerNotes = customOfficerNotes, customOfficerNotesTs = customOfficerNotesUpdated }
            categoryFields.notesGeneral = { customNotes = customNotes, customNotesTs = customNotesUpdated }
        end,
        function()
            if SYNC_JOIN_DATES then
                joinDates, joinDatesUpdated = Roster:GetJoinDatesForSync(guildKey)
            end
            categoryFields.joinDates = { joinDates = joinDates, joinDatesTs = joinDatesUpdated }
        end,
        function()
            formerMembers, formerMembersUpdated = Roster:GetFormerMembersForSync(guildKey)
            categoryFields.formerMembers = { formerMembers = formerMembers, formerMembersTs = formerMembersUpdated }
        end,
        function()
            if SYNC_BIRTHDAYS then
                birthdays, birthdaysUpdated = Roster:GetBirthdaysForSync(guildKey)
            end
            categoryFields.birthdays = { birthdays = birthdays, birthdaysTs = birthdaysUpdated }
        end,
        function()
            if SYNC_EVENT_LOG then
                log = EventLog:GetRecentForSync(guildKey, LOG_SYNC_DAYS, LOG_SYNC_MAX_ENTRIES)
                logRemoved = EventLog:GetRemovedForSync(guildKey)
            end
            categoryFields.log = { log = log, logRemoved = logRemoved }
        end,
        function()
            recruitmentSettings, recruitmentSettingsUpdated = Recruitment:GetGuildSettingsForSync(guildKey)
            recruitmentBlacklist, recruitmentBlacklistUpdated = Recruitment:GetBlacklistForSync(guildKey)
            categoryFields.recruitmentItems = { recruitmentSettings = recruitmentSettings, recruitmentSettingsTs = recruitmentSettingsUpdated }
            categoryFields.recruitmentBlacklist = { recruitmentBlacklist = recruitmentBlacklist, recruitmentBlacklistTs = recruitmentBlacklistUpdated }
        end,
        function()
            if MacroTool:CanUse() then
                macroRules, macroRulesUpdated = MacroTool:GetSavedRulesForSync()
                macroIgnores, macroIgnoresUpdated = MacroTool:GetMacroIgnoresForSync(guildKey)
            end
            categoryFields.macroIgnores = { macroIgnores = macroIgnores, macroIgnoresTs = macroIgnoresUpdated }
            categoryFields.macroRules = { macroRules = macroRules, macroRulesTs = macroRulesUpdated }
        end,
        function()
            if BanList:CanUse() then
                bans, bansUpdated = BanList:GetAllForSync(guildKey)
            end
            categoryFields.bans = { bans = bans, bansTs = bansUpdated }
        end,
        function()
            if Labels:CanUse() then
                local defs, defsUpdated, assignments, assignmentsUpdated = Labels:GetAllForSync(guildKey)
                labelDefinitions, labelDefinitionsUpdated = defs, defsUpdated
                labelAssignments, labelAssignmentsUpdated = flattenLabelAssignments(assignments, assignmentsUpdated)
            end
            categoryFields.labels = {
                labelDefinitions = labelDefinitions, labelDefinitionsTs = labelDefinitionsUpdated,
                labelAssignments = labelAssignments, labelAssignmentsTs = labelAssignmentsUpdated,
            }
        end,
        finishSend,
    }

    local index = 1
    local function runNext()
        local step = steps[index]
        index = index + 1
        if step then step() end
        if index <= #steps then
            C_Timer.After(0, runNext)
        end
    end
    runNext()
end

function GuildSync:HandleFullLogRequest(guildKey, payload, sender)
    if not payload or not payload.requestID or not sender then return end
    local replaceMode = payload.mode == "replace"
    if replaceMode then
        if payload.target and not self:IsMe(payload.target) then return end
        if payload.targetRole == "guild master" and not GP:IsGuildMaster() then return end
        if payload.targetRole == "officer" and not GP:IsOfficer() then return end
    else
        -- Don't serve routine/bootstrap full-log requests while Event Log sync
        -- is disabled. Manual replace requests are handled above and remain
        -- button-only.
        if not SYNC_EVENT_LOG then return end
    end

    local EventLog = GP:GetModule("EventLog")
    local entries = EventLog:GetFullForSync(guildKey)
    local requesterCount = tonumber(payload.count) or 0
    if not replaceMode and #entries <= requesterCount then return end
    local removed = EventLog:GetRemovedForSync(guildKey)
    local totalChunks = math.max(1, math.ceil(#entries / FULL_LOG_CHUNK_SIZE))

    C_Timer.After(math.random(20, 50) / 10, function()
        if fullLogClaims[payload.requestID] then return end
        fullLogClaims[payload.requestID] = UnitName("player") or "?"
        -- Full-log replacement uses the same raw Guild Sync route as full-state
        -- sync: Guild Paragon wrapper/chunking with outbound ChatThrottleLib
        -- pacing. Passing nil for replace-mode targets keeps delivery on the
        -- guild channel with a payload target marker instead of relying on
        -- direct whisper reachability.
        self:SendToPeer({
            v = PROTOCOL_VERSION,
            op = "fulllogclaim",
            requestID = payload.requestID,
            target = sender,
            mode = payload.mode,
            total = totalChunks,
            totalEntries = #entries,
        }, replaceMode and nil or sender)

        self.lastFullLogRequestReceivedAt = time()
        self.lastFullLogRequestReceivedFrom = sender
        self.lastFullLogRequestReceivedCount = requesterCount
        self.lastFullLogReplySentTo = sender
        self.lastFullLogReplySentAt = self.lastFullLogRequestReceivedAt
        self.lastFullLogReplySentCount = #entries
        self:RecordPeer(sender, "Sending full log", { log = #entries }, string.format("%d queued entries", #entries))
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)

        local function sendChunk(chunkIndex)
            if chunkIndex > totalChunks then
                self:RecordPeer(sender, "Full log sent", { log = #entries }, string.format("%d chunk(s)", totalChunks))
                GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
                return
            end

            local chunk = {}
            local startIndex = ((chunkIndex - 1) * FULL_LOG_CHUNK_SIZE) + 1
            local endIndex = math.min(#entries, chunkIndex * FULL_LOG_CHUNK_SIZE)
            for i = startIndex, endIndex do
                table.insert(chunk, entries[i])
            end
            self:SendToPeerSequential({
                v = PROTOCOL_VERSION,
                op = "fulllogchunk",
                requestID = payload.requestID,
                target = sender,
                mode = payload.mode,
                index = chunkIndex,
                total = totalChunks,
                totalEntries = #entries,
                entries = chunk,
                removed = chunkIndex == 1 and removed or nil,
            }, replaceMode and nil or sender, function()
                if chunkIndex == 1 or chunkIndex % 10 == 0 or chunkIndex == totalChunks then
                    self:RecordPeer(sender, "Sending full log", { log = #entries },
                        string.format("%d/%d chunks queued", chunkIndex, totalChunks))
                    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
                end
                sendChunk(chunkIndex + 1)
            end)
        end

        sendChunk(1)
    end)
end

function GuildSync:HandleFullLogClaim(payload, sender)
    if not payload or not payload.requestID then return end
    fullLogClaims[payload.requestID] = sender or true
    if payload.target and self:IsMe(payload.target) then
        local state = self.fullLogBootstrap
        if state and state.requestID == payload.requestID then
            state.claimedAt = time()
            state.mode = payload.mode or state.mode
            state.total = math.max(state.total or 0, tonumber(payload.total) or 0)
            state.totalEntries = tonumber(payload.totalEntries) or state.totalEntries or 0
        end
        self:RecordPeer(sender, "Full log claimed", nil, "Waiting for chunks")
    elseif payload.target then
        self:RecordIgnored("full log claim for another target", sender)
    end
end

function GuildSync:ApplyFullLogChunk(guildKey, payload, sender)
    if not payload or not payload.requestID then return end
    if not self:IsMe(payload.target) then
        self:RecordIgnored("full log chunk for another target", sender)
        return
    end
    local state = self.fullLogBootstrap
    if not state or state.requestID ~= payload.requestID then
        self:RecordIgnored("full log chunk for unknown request", sender)
        return
    end
    local senderKey = payload.sourceGUID or sender
    if state.fromKey and state.fromKey ~= senderKey then
        self:RecordIgnored("full log chunk from non-claiming peer", sender)
        return
    end
    state.chunksSeen = state.chunksSeen or {}
    local chunkIndex = tonumber(payload.index) or 0
    local chunkKey = tostring(senderKey or "?") .. ":" .. tostring(chunkIndex)
    if state.chunksSeen[chunkKey] then
        self:RecordIgnored("duplicate full log chunk", sender)
        return
    end
    state.chunksSeen[chunkKey] = true

    local EventLog = GP:GetModule("EventLog")
    if state.mode == "replace" or payload.mode == "replace" then
        state.mode = "replace"
        state.entryChunks = state.entryChunks or {}
        state.entryChunks[chunkIndex] = payload.entries or {}
        if payload.removed then state.removed = payload.removed end
        state.received = (state.received or 0) + 1
        state.total = math.max(state.total or 0, tonumber(payload.total) or 0)
        state.totalEntries = tonumber(payload.totalEntries) or state.totalEntries or 0
        state.from = sender
        state.fromKey = senderKey
        state.lastChunkAt = time()
        self.lastFullLogChunkReceivedAt = state.lastChunkAt
        self.lastFullLogChunkFrom = sender
        self.lastFullLogChunkCounts = {
            received = state.received,
            total = state.total,
            considered = state.considered or 0,
            applied = state.applied or 0,
            totalEntries = state.totalEntries,
        }

        if state.total <= 0 or state.received < state.total then
            self:RecordPeer(sender, "Receiving full log", { log = #(payload.entries or {}) },
                string.format("%d/%d chunks", state.received, state.total))
            GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
            return
        end

        local entries = {}
        for i = 1, state.total do
            local chunk = state.entryChunks[i]
            if type(chunk) ~= "table" then return end
            for _, entry in ipairs(chunk) do
                table.insert(entries, entry)
            end
        end

        applyRemote(function()
            state.considered, state.applied = EventLog:ReplaceFromSync(guildKey, entries, state.removed or {})
        end)
        state.completedAt = time()
        local guildData = GP.db.global.guilds[guildKey]
        if guildData then
            guildData.fullLogBootstrapCompleted = true
            guildData.fullLogBootstrapCompletedAt = state.completedAt
            guildData.fullLogBootstrapFrom = sender
            guildData.fullLogBootstrapApplied = state.applied
            guildData.fullLogBootstrapConsidered = state.considered
            guildData.fullLogReplaceCompletedAt = state.completedAt
            guildData.fullLogReplaceFrom = sender
            guildData.fullLogReplaceApplied = state.applied
            guildData.fullLogReplaceConsidered = state.considered
        end
        fullLogRequestsSent[guildKey] = nil
        self.lastFullLogBootstrapCompletedAt = state.completedAt
        self.lastFullLogBootstrapFrom = sender
        self.lastFullLogBootstrapCounts = {
            considered = state.considered,
            applied = state.applied,
            chunks = state.total,
            totalEntries = state.totalEntries,
        }
        GP:Print(string.format(GP.L["Full Event Log sync complete: imported %d of %d received record(s)."], state.applied, state.considered))
        self:RecordPeer(sender, "Full log replace complete", { log = state.applied },
            string.format("%d/%d chunks, %d imported", state.received, state.total, state.applied))
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        return
    end

    local removedConsidered, removedApplied = 0, 0
    local logConsidered, logApplied = 0, 0

    applyRemote(function()
        if payload.removed then
            removedConsidered, removedApplied = EventLog:MergeRemovedEntries(guildKey, payload.removed)
        end
        logConsidered, logApplied = EventLog:MergeEntries(guildKey, payload.entries or {})
    end)

    state.received = state.received + 1
    state.total = math.max(state.total or 0, tonumber(payload.total) or 0)
    state.totalEntries = tonumber(payload.totalEntries) or state.totalEntries or 0
    state.considered = (state.considered or 0) + logConsidered + removedConsidered
    state.applied = (state.applied or 0) + logApplied + removedApplied
    state.from = sender
    state.fromKey = senderKey
    state.lastChunkAt = time()
    self.lastFullLogChunkReceivedAt = state.lastChunkAt
    self.lastFullLogChunkFrom = sender
    self.lastFullLogChunkCounts = {
        received = state.received,
        total = state.total,
        considered = state.considered,
        applied = state.applied,
        totalEntries = state.totalEntries,
    }

    if state.total > 0 and state.received >= state.total then
        local guildData = GP.db.global.guilds[guildKey]
        if guildData then
            guildData.fullLogBootstrapCompleted = true
            guildData.fullLogBootstrapCompletedAt = time()
            guildData.fullLogBootstrapFrom = sender
            guildData.fullLogBootstrapApplied = state.applied
            guildData.fullLogBootstrapConsidered = state.considered
        end
        fullLogRequestsSent[guildKey] = nil
        self.lastFullLogBootstrapCompletedAt = guildData and guildData.fullLogBootstrapCompletedAt or time()
        self.lastFullLogBootstrapFrom = sender
        self.lastFullLogBootstrapCounts = {
            considered = state.considered,
            applied = state.applied,
            chunks = state.total,
            totalEntries = state.totalEntries,
        }
        GP:Print(string.format(GP.L["Event Log bootstrap complete: merged %d of %d received record(s)."], state.applied, state.considered))
        self:RecordPeer(sender, "Full log complete", countsForOp(payload),
            string.format("%d/%d chunks, %d merged", state.received, state.total, state.applied))
    else
        self:RecordPeer(sender, "Receiving full log", countsForOp(payload),
            string.format("%d/%d chunks", state.received, state.total))
    end

    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
end

-- One apply handler per FULL_STATE_CATEGORIES key.
local fullStateCategoryHandlers = {
    bans = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local BanList = GP:GetModule("BanList")
        if not BanList:CanUse() then done() return end
        if countTable(payload.bansTs or {}) <= (preMergeCounts.bans or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        -- Captured once, before any records apply — same "don't log a
        -- brand-new client's first-ever bulk catch-up as fresh activity"
        -- reasoning as ApplySafetyState above; see BanList:SetFromSync.
        local logBanEvents = BanList:GetTotalStoredCount(guildKey) > 0
        applyTimestampMapBatched(payload.bansTs, function(id, ts)
            local current = BanList:GetUpdatedAt(guildKey, id)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = BanList:SetFromSync(guildKey, id, payload.bans and payload.bans[id], ts, logBanEvents)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    recruitmentBlacklist = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Recruitment = GP:GetModule("Recruitment")
        if countTable(payload.recruitmentBlacklistTs or {}) <= (preMergeCounts.recruitmentBlacklist or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.recruitmentBlacklistTs, function(id, ts)
            local current = Recruitment:GetBlacklistUpdatedAt(guildKey, id)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = Recruitment:SetBlacklistFromSync(guildKey, id, payload.recruitmentBlacklist and payload.recruitmentBlacklist[id], ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    nicknames = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Nicknames = GP:GetModule("Nicknames")
        if countTable(payload.nicksTs or {}) <= (preMergeCounts.nicknames or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.nicksTs, function(guid, ts)
            local current = Nicknames:GetUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = Nicknames:Set(guildKey, guid, (payload.nicks and payload.nicks[guid]) or "", ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    altsMains = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Alts = GP:GetModule("Alts")
        if (countTable(payload.altsTs or {}) + countTable(payload.mainsTs or {})) <= (preMergeCounts.altsMains or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.altsTs, function(altGUID, ts)
            local current = Alts:GetAltUpdatedAt(guildKey, altGUID)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local mainGUID = payload.alts and payload.alts[altGUID]
                local ok = true
                if mainGUID then
                    ok = Alts:SetMain(guildKey, altGUID, mainGUID, ts)
                else
                    Alts:ClearMain(guildKey, altGUID, ts) -- no rejection path
                end
                if ok then ex.applied = ex.applied + 1 end
            end
        end, function()
            applyTimestampMapBatched(payload.mainsTs, function(guid, ts)
                local current = Alts:GetMainFlagUpdatedAt(guildKey, guid)
                if (not current or ts > current) and type(ts) == "number" then
                    ex.considered = ex.considered + 1
                    if payload.mains and payload.mains[guid] then
                        local ok = Alts:SetAsMain(guildKey, guid, ts)
                        if ok then ex.applied = ex.applied + 1 end
                    else
                        Alts:UnsetAsMain(guildKey, guid, ts) -- no rejection path
                        ex.applied = ex.applied + 1
                    end
                end
            end, done)
        end)
    end,

    macroIgnores = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local MacroTool = GP:GetModule("MacroTool")
        if not MacroTool:CanUse() then done() return end
        if countTable(payload.macroIgnoresTs or {}) <= (preMergeCounts.macroIgnores or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.macroIgnoresTs, function(guid, ts)
            local current = MacroTool:GetPlayerIgnoreUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = MacroTool:SetPlayerIgnoreFromSync(guildKey, guid, payload.macroIgnores and payload.macroIgnores[guid], ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    macroRules = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local MacroTool = GP:GetModule("MacroTool")
        if not MacroTool:CanUse() then done() return end
        if countTable(payload.macroRulesTs or {}) <= (preMergeCounts.macroRules or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.macroRulesTs, function(name, ts)
            local current = MacroTool:GetSavedRuleUpdatedAt(name)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = MacroTool:SetSavedRuleFromSync(name, payload.macroRules and payload.macroRules[name], ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    recruitmentItems = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Recruitment = GP:GetModule("Recruitment")
        if not (payload.recruitmentSettingsTs and type(payload.recruitmentSettingsTs) == "number" and senderIsGuildMaster(guildKey, sender)) then
            done()
            return
        end
        applyRemote(function()
            local current = Recruitment:GetGuildSettingsUpdatedAt(guildKey)
            if not current or payload.recruitmentSettingsTs > current then
                ex.considered = ex.considered + 1
                local ok = Recruitment:SetGuildSettingsFromSync(guildKey, payload.recruitmentSettings, payload.recruitmentSettingsTs)
                if ok then ex.applied = ex.applied + 1 end
            end
        end)
        done()
    end,

    formerMembers = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Roster = GP:GetModule("Roster")
        if countTable(payload.formerMembersTs or {}) <= (preMergeCounts.formerMembers or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        local stageApplied = 0
        applyTimestampMapBatched(payload.formerMembersTs, function(guid, ts)
            local current = Roster:GetFormerMemberUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = Roster:SetFormerMemberFromSync(guildKey, guid, payload.formerMembers and payload.formerMembers[guid], ts)
                if ok then
                    ex.applied = ex.applied + 1
                    stageApplied = stageApplied + 1
                end
            end
        end, function()
            if stageApplied > 0 then
                GP:SendMessage("GuildParagon_RosterScanned", guildKey)
            end
            done()
        end)
    end,

    birthdays = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Roster = GP:GetModule("Roster")
        if not SYNC_BIRTHDAYS then done() return end
        if countTable(payload.birthdaysTs or {}) <= (preMergeCounts.birthdays or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.birthdaysTs, function(guid, ts)
            local current = Roster:GetBirthdayUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local incoming = payload.birthdays and payload.birthdays[guid]
                if incoming and incoming.date then
                    local ok = Roster:SetBirthday(guildKey, guid, incoming.date[1], incoming.date[2], ts)
                    if ok then ex.applied = ex.applied + 1 end
                else
                    local ok = Roster:ClearBirthday(guildKey, guid, ts)
                    if ok then ex.applied = ex.applied + 1 end
                end
            end
        end, done)
    end,

    joinDates = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Roster = GP:GetModule("Roster")
        if not SYNC_JOIN_DATES then done() return end
        if countTable(payload.joinDatesTs or {}) <= (preMergeCounts.joinDates or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.joinDatesTs, function(guid, ts)
            local current = Roster:GetJoinDateUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local incoming = payload.joinDates and payload.joinDates[guid]
                if incoming then
                    local ok = Roster:SetJoinDateFromSync(guildKey, guid, incoming.firstSeen, incoming.source, ts)
                    if ok then ex.applied = ex.applied + 1 end
                end
            end
        end, done)
    end,

    notesOfficer = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local CustomNotes = GP:GetModule("CustomNotes")
        if not CustomNotes:CanAccessOfficerNotes() then done() return end
        if countTable(payload.customOfficerNotesTs or {}) <= (preMergeCounts.notesOfficer or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.customOfficerNotesTs, function(guid, ts)
            local current = CustomNotes:GetOfficerUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local incoming = (payload.customOfficerNotes and payload.customOfficerNotes[guid]) or ""
                if CustomNotes:ShouldKeepLocalValue(CustomNotes:GetOfficer(guildKey, guid), incoming) then
                    incoming = CustomNotes:GetOfficer(guildKey, guid)
                end
                local ok = CustomNotes:SetOfficer(guildKey, guid, incoming, ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    notesGeneral = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local CustomNotes = GP:GetModule("CustomNotes")
        if not SYNC_GENERAL_NOTES then done() return end
        if countTable(payload.customNotesTs or {}) <= (preMergeCounts.notesGeneral or 0) then
            ex.skippedCategories = ex.skippedCategories + 1
            done()
            return
        end
        applyTimestampMapBatched(payload.customNotesTs, function(guid, ts)
            local current = CustomNotes:GetUpdatedAt(guildKey, guid)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local incoming = (payload.customNotes and payload.customNotes[guid]) or ""
                if CustomNotes:ShouldKeepLocalValue(CustomNotes:Get(guildKey, guid), incoming) then
                    incoming = CustomNotes:Get(guildKey, guid)
                end
                local ok = CustomNotes:Set(guildKey, guid, incoming, ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, done)
    end,

    log = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local EventLog = GP:GetModule("EventLog")
        if not SYNC_EVENT_LOG then done() return end
        ex.removedConsidered, ex.removedApplied = EventLog:MergeRemovedEntries(guildKey, payload.logRemoved or {})
        ex.logConsidered, ex.logApplied = EventLog:MergeEntries(guildKey, payload.log or {})
        done()
    end,

    -- "labels": unlike
    -- every handler above, this category was only ever offered to us
    labels = function(guildKey, payload, sender, preMergeCounts, ex, done)
        local Labels = GP:GetModule("Labels")
        if not Labels:CanUse() then done() return end

        -- Deliberately NO count-based skip here, unlike every category
        -- above. `incomingCount <= preMergeCounts.labels` only tells us
        applyTimestampMapBatched(payload.labelDefinitionsTs, function(labelId, ts)
            local current = Labels:GetDefinitionUpdatedAt(guildKey, labelId)
            if (not current or ts > current) and type(ts) == "number" then
                ex.considered = ex.considered + 1
                local ok = Labels:SetDefinitionFromSync(guildKey, labelId, payload.labelDefinitions and payload.labelDefinitions[labelId], ts)
                if ok then ex.applied = ex.applied + 1 end
            end
        end, function()
            applyTimestampMapBatched(payload.labelAssignmentsTs, function(key, ts)
                local guid, labelId = splitLabelAssignmentKey(key)
                if guid and labelId and type(ts) == "number" then
                    local current = Labels:GetAssignmentUpdatedAt(guildKey, guid, labelId)
                    if not current or ts > current then
                        ex.considered = ex.considered + 1
                        local incoming = payload.labelAssignments and payload.labelAssignments[key]
                        local ok = Labels:SetAssignmentFromSync(guildKey, guid, labelId, incoming and true or false, ts)
                        if ok then ex.applied = ex.applied + 1 end
                    end
                end
            end, done)
        end)
    end,
}

function GuildSync:ReceiveFullStateCategory(guildKey, payload, sender)
    local category = payload and payload.category
    local exchangeID = payload and payload.exchangeID
    if type(category) ~= "string" or not fullStateCategoryHandlers[category] or exchangeID == nil then
        self:RecordIgnored("full state category message missing exchange fields", sender)
        return
    end
    if payload.helloRequestID == startupFullSyncRequestID then
        self:MarkStartupFullSyncResponseStarted("full state category received", sender)
    end

    local expectedList = payload.expectedCategories
    if type(expectedList) ~= "table" or #expectedList == 0 then
        expectedList = { category }
    end

    local key = guildKey .. "\30" .. tostring(sender) .. "\30" .. tostring(exchangeID)
    local ex = pendingFullExchanges[key]
    if not ex then
        local expected = {}
        for _, c in ipairs(expectedList) do expected[c] = true end
        ex = {
            guildKey = guildKey, sender = sender, exchangeKind = payload.exchangeKind or "full",
            helloRequestID = payload.helloRequestID,
            expected = expected, expectedList = expectedList,
            received = {}, startedAt = time(),
            considered = 0, applied = 0,
            logConsidered = 0, logApplied = 0, removedConsidered = 0, removedApplied = 0,
            receivedCounts = newCounts(), receivedDetail = newReceivedDetail(),
            skippedCategories = 0,
        }
        pendingFullExchanges[key] = ex
    end
    ex.lastActivityAt = time()

    if ex.received[category] then
        self:RecordIgnored("duplicate full state category", sender)
        return
    end
    if not ex.expected[category] then
        -- Not in this exchange's own manifest (stale/mismatched repeat, or
        -- a manifest packet lost while a category packet still got
        -- through) — still apply it, no harm in accepting genuinely newer
        -- data, but fold it into what we're waiting on rather than
        -- treating it as extra/unexpected.
        ex.expected[category] = true
        ex.expectedList[#ex.expectedList + 1] = category
    end

    addCount(ex.receivedCounts, category, categoryReceivedCount(category, payload))
    addReceivedDetail(ex.receivedDetail, category, payload)

    local preMergeCounts = self:GetLocalCounts(guildKey)
    fullStateCategoryHandlers[category](guildKey, payload, sender, preMergeCounts, ex, function()
        ex.received[category] = true
        local allReceived = true
        for c in pairs(ex.expected) do
            if not ex.received[c] then
                allReceived = false
                break
            end
        end
        if allReceived then
            pendingFullExchanges[key] = nil
            self:FinishFullExchange(ex)
        end
    end)
end

function GuildSync:FinishFullExchange(ex)
    local guildKey, sender = ex.guildKey, ex.sender
    local BanList = GP:GetModule("BanList")
    local MacroTool = GP:GetModule("MacroTool")
    local CustomNotes = GP:GetModule("CustomNotes")

    local receivedTotal = totalCounts(ex.receivedCounts)
    self.lastFullSyncReceived = time()
    self:MarkFullSyncExchange(guildKey, self.lastFullSyncReceived)
    self.lastFullSyncFrom = sender
    self.lastFullSyncCounts = {
        considered = ex.considered + ex.logConsidered + ex.removedConsidered,
        applied = ex.applied + ex.logApplied + ex.removedApplied,
        receivedTotal = receivedTotal,
        received = ex.receivedDetail,
    }
    self:RecordPeer(sender, "Full state received", ex.receivedCounts,
        string.format("%d merged; %d newer of %d received; %d/%d categories already up to date",
            self.lastFullSyncCounts.applied, self.lastFullSyncCounts.considered, receivedTotal,
            ex.skippedCategories, #ex.expectedList), "snapshot")
    GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)

    -- Fan-out suppression: the first matching reply tells other peers to
    -- stand down from the same request.
    if ex.helloRequestID and self.pendingHelloRequestID == ex.helloRequestID then
        self.pendingHelloRequestID = nil
        self:Broadcast({ v = PROTOCOL_VERSION, op = "hellosatisfied", requestID = ex.helloRequestID })
    end

    -- Auto-resync-on-mismatch: if this
    -- peer's reported total for a category we're actually eligible to
    local received = ex.receivedCounts
    local localCounts = self:GetLocalCounts(guildKey)
    local eligible = {
        bans = BanList:CanUse(),
        recruitmentBlacklist = true,
        nicknames = true,
        altsMains = true,
        macroIgnores = MacroTool:CanUse(),
        macroRules = MacroTool:CanUse(),
        formerMembers = true,
        birthdays = SYNC_BIRTHDAYS,
        notesOfficer = CustomNotes:CanAccessOfficerNotes(),
        notesGeneral = SYNC_GENERAL_NOTES,
        joinDates = SYNC_JOIN_DATES,
        log = SYNC_EVENT_LOG,
    }
    local missing = {}
    for category, isEligible in pairs(eligible) do
        if isEligible and (localCounts[category] or 0) < (received[category] or 0) then
            missing[#missing + 1] = category
        end
    end

    self.autoResyncStreak = self.autoResyncStreak or {}
    if self.lastFullSyncCounts.applied > 0 then
        -- Real progress was made against this sender — whatever was
        -- blocking convergence before (if anything) isn't blocking it
        -- now, so give the streak a clean slate.
        self.autoResyncStreak[sender] = nil
    end

    if #missing > 0 then
        self.lastAutoResyncAt = time()
        self.lastAutoResyncReason = string.format("%s: %s (auto retry paused)", sender, table.concat(missing, ", "))
        GP:SendMessage("GuildParagon_SyncStatusChanged", guildKey)
        if not AUTO_RESYNC_ENABLED then
            return
        end

        local streak = (self.autoResyncStreak[sender] or 0) + 1
        self.autoResyncStreak[sender] = streak
        -- Safety cap: a full sync that
        -- applies 0 records despite a category clearly being behind — seen
        if streak > MAX_AUTO_RESYNC_STREAK then
            if streak == MAX_AUTO_RESYNC_STREAK + 1 then
                GP:Print(string.format(
                    GP.L["Guild Sync: gave up auto-resyncing with %s after %d attempts with no new data merged (%s still behind) — check both clients' system clocks are correct, or use Sync Now to try manually."],
                    sender, MAX_AUTO_RESYNC_STREAK, table.concat(missing, ", ")))
            end
        else
            local now = time()
            if not self.lastAutoResyncAt or (now - self.lastAutoResyncAt) >= AUTO_RESYNC_COOLDOWN_SECONDS then
                self.lastAutoResyncAt = now
                self.lastAutoResyncReason = string.format("%s: %s", sender, table.concat(missing, ", "))
                C_Timer.After(math.random(20, 40) / 10, function()
                    self:RequestSync()
                end)
            end
        end
    end
end

function GuildSync:SweepStaleFullExchanges()
    local now = time()
    for key, ex in pairs(pendingFullExchanges) do
        local lastActivityAt = ex.lastActivityAt or ex.startedAt
        if lastActivityAt and (now - lastActivityAt) > FULL_EXCHANGE_TIMEOUT_SECONDS then
            local missingList = {}
            for _, category in ipairs(ex.expectedList) do
                if not ex.received[category] then
                    missingList[#missingList + 1] = category
                end
            end
            self.lastAbandonedFullExchange = {
                sender = ex.sender, exchangeKind = ex.exchangeKind,
                age = now - ex.startedAt,
                received = ex.expectedList and (#ex.expectedList - #missingList) or 0,
                expected = ex.expectedList and #ex.expectedList or 0,
                missing = missingList,
            }
            self:RecordIgnored(string.format("full state exchange abandoned (%d/%d categories, missing: %s)",
                self.lastAbandonedFullExchange.received, self.lastAbandonedFullExchange.expected,
                table.concat(missingList, ", ")), ex.sender)
            pendingFullExchanges[key] = nil

            if AUTO_RESYNC_ENABLED and not rawRecoveryPaused() then
                local now2 = time()
                if not self.lastAutoResyncAt or (now2 - self.lastAutoResyncAt) >= AUTO_RESYNC_COOLDOWN_SECONDS then
                    self.lastAutoResyncAt = now2
                    self.lastAutoResyncReason = string.format("%s: exchange timed out (%s)", ex.sender, table.concat(missingList, ", "))
                    C_Timer.After(math.random(20, 40) / 10, function()
                        self:RequestSync()
                    end)
                end
            end
        end
    end
end

-- Each ApplyX below is a one-record version of the same gate-then-apply
-- pattern used in ApplyFullState, for a single incremental message.

function GuildSync:ApplyAlt(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or not payload.main or type(ts) ~= "number" then return end
    local Alts = GP:GetModule("Alts")
    local current = Alts:GetAltUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function() Alts:SetMain(guildKey, guid, payload.main, ts) end)
end

function GuildSync:ApplyAltClear(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Alts = GP:GetModule("Alts")
    local current = Alts:GetAltUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function() Alts:ClearMain(guildKey, guid, ts) end)
end

function GuildSync:ApplyMain(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Alts = GP:GetModule("Alts")
    local current = Alts:GetMainFlagUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function() Alts:SetAsMain(guildKey, guid, ts) end)
end

function GuildSync:ApplyMainClear(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Alts = GP:GetModule("Alts")
    local current = Alts:GetMainFlagUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function() Alts:UnsetAsMain(guildKey, guid, ts) end)
end

function GuildSync:ApplyNick(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Nicknames = GP:GetModule("Nicknames")
    local current = Nicknames:GetUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function() Nicknames:Set(guildKey, guid, payload.nick or "", ts) end)
end

function GuildSync:ApplyCustomNote(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    if payload.scope ~= "officer" and not SYNC_GENERAL_NOTES then return end
    local CustomNotes = GP:GetModule("CustomNotes")

    if payload.scope == "officer" then
        if not CustomNotes:CanAccessOfficerNotes() then return end
        local current = CustomNotes:GetOfficerUpdatedAt(guildKey, guid)
        if current and ts <= current then return end
        applyRemote(function()
            local incoming = payload.note or ""
            if CustomNotes:ShouldKeepLocalValue(CustomNotes:GetOfficer(guildKey, guid), incoming) then
                incoming = CustomNotes:GetOfficer(guildKey, guid)
            end
            CustomNotes:SetOfficer(guildKey, guid, incoming, ts)
        end)
        return
    end

    local current = CustomNotes:GetUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function()
        local incoming = payload.note or ""
        if CustomNotes:ShouldKeepLocalValue(CustomNotes:Get(guildKey, guid), incoming) then
            incoming = CustomNotes:Get(guildKey, guid)
        end
        CustomNotes:Set(guildKey, guid, incoming, ts)
    end)
end

function GuildSync:ApplyBirthday(guildKey, payload)
    if not SYNC_BIRTHDAYS then return end
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Roster = GP:GetModule("Roster")
    local current = Roster:GetBirthdayUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function()
        if payload.birthday and payload.birthday.date then
            Roster:SetBirthday(guildKey, guid, payload.birthday.date[1], payload.birthday.date[2], ts)
        else
            Roster:ClearBirthday(guildKey, guid, ts)
        end
    end)
end

function GuildSync:ApplyFormerMember(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Roster = GP:GetModule("Roster")
    local current = Roster:GetFormerMemberUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function()
        local ok = Roster:SetFormerMemberFromSync(guildKey, guid, payload.formerMember, ts)
        if ok then
            GP:SendMessage("GuildParagon_RosterScanned", guildKey)
        end
    end)
end

function GuildSync:ApplyJoinDate(guildKey, payload)
    if not SYNC_JOIN_DATES then return end
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local Roster = GP:GetModule("Roster")
    local current = Roster:GetJoinDateUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    local incoming = payload.joinDate
    if not incoming then return end
    applyRemote(function()
        Roster:SetJoinDateFromSync(guildKey, guid, incoming.firstSeen, incoming.source, ts)
    end)
end

function GuildSync:ApplyMacroRule(payload)
    local name, ts = payload.name, payload.ts
    if not name or type(ts) ~= "number" then return end
    local MacroTool = GP:GetModule("MacroTool")
    if not MacroTool:CanUse() then return end
    local current = MacroTool:GetSavedRuleUpdatedAt(name)
    if current and ts <= current then return end
    applyRemote(function() MacroTool:SetSavedRuleFromSync(name, payload.rule, ts) end)
end

function GuildSync:ApplyMacroIgnore(guildKey, payload)
    local guid, ts = payload.guid, payload.ts
    if not guid or type(ts) ~= "number" then return end
    local MacroTool = GP:GetModule("MacroTool")
    if not MacroTool:CanUse() then return end
    local current = MacroTool:GetPlayerIgnoreUpdatedAt(guildKey, guid)
    if current and ts <= current then return end
    applyRemote(function() MacroTool:SetPlayerIgnoreFromSync(guildKey, guid, payload.ignore, ts) end)
end

function GuildSync:ApplyBan(guildKey, payload)
    local id, ts = payload.id, payload.ts
    if not id or type(ts) ~= "number" then return end
    local BanList = GP:GetModule("BanList")
    if not BanList:CanUse() then return end
    local current = BanList:GetUpdatedAt(guildKey, id)
    if current and ts <= current then return end
    applyRemote(function() BanList:SetFromSync(guildKey, id, payload.record, ts) end)
end

function GuildSync:ApplyLogEntry(guildKey, payload)
    if not guildKey or type(payload.entry) ~= "table" then return end
    local entry = payload.entry
    local allowed = entry.type == "removed"
        or (entry.type == "join" and entry.invitedBy and entry.recruitmentContact)
    if not allowed or not entry.guid or type(entry.ts) ~= "number" then return end
    local EventLog = GP:GetModule("EventLog")
    applyRemote(function()
        EventLog:MergeEntries(guildKey, { entry })
    end)
end

senderIsGuildMaster = function(guildKey, sender)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not sender then return false end
    local Roster = GP:GetModule("Roster")
    local senderKey = Roster:NormalizePlayerName(sender)
    if not senderKey then return false end
    for _, player in pairs(guildData.roster or {}) do
        if player.name and Roster:NormalizePlayerName(player.name) == senderKey then
            return tonumber(player.rankIndex) == 0
        end
    end
    return false
end

function GuildSync:ApplyRecruitmentSettings(guildKey, payload, sender)
    local ts = payload.ts
    if type(ts) ~= "number" or type(payload.settings) ~= "table" then return end
    if not senderIsGuildMaster(guildKey, sender) then return end
    local Recruitment = GP:GetModule("Recruitment")
    local current = Recruitment:GetGuildSettingsUpdatedAt(guildKey)
    if current and ts <= current then return end
    applyRemote(function() Recruitment:SetGuildSettingsFromSync(guildKey, payload.settings, ts) end)
end

function GuildSync:ApplyRecruitmentBlacklist(guildKey, payload)
    local id, ts = payload.id, payload.ts
    if not id or type(ts) ~= "number" then return end
    local Recruitment = GP:GetModule("Recruitment")
    local current = Recruitment:GetBlacklistUpdatedAt(guildKey, id)
    if current and ts <= current then return end
    applyRemote(function() Recruitment:SetBlacklistFromSync(guildKey, id, payload.record, ts) end)
end

-- Live single-record label update. Labels:CanUse() is the receiver-side
-- officer gate for broadcast updates.
function GuildSync:ApplyLabel(guildKey, payload)
    local Labels = GP:GetModule("Labels")
    if not Labels:CanUse() then return end
    local ts = payload.ts
    if type(ts) ~= "number" then return end

    if payload.kind == "definition" then
        local labelId = payload.labelId
        if not labelId then return end
        local current = Labels:GetDefinitionUpdatedAt(guildKey, labelId)
        if current and ts <= current then return end
        applyRemote(function() Labels:SetDefinitionFromSync(guildKey, labelId, payload.record, ts) end)
    elseif payload.kind == "assignment" then
        local guid, labelId = payload.guid, payload.labelId
        if not guid or not labelId then return end
        local current = Labels:GetAssignmentUpdatedAt(guildKey, guid, labelId)
        if current and ts <= current then return end
        applyRemote(function() Labels:SetAssignmentFromSync(guildKey, guid, labelId, payload.assigned and true or false, ts) end)
    end
end
