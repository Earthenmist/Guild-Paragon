-- Guild Paragon — Nicknames
-- One nickname per character. The 20-character limit is a practical UI
local _, GP = ...

local Nicknames = GP:NewModule("Nicknames", "AceEvent-3.0")

local NICKNAME_MAX_CHARS = 20
local IDENTITY_SCHEMA_VERSION = 1

local function findPlayer(data, guid)
    return data.roster[guid] or data.formerMembers[guid]
end

local function getGuildData(guildKey, pass)
    if pass then return pass.data end
    local data = guildKey and GP.db.global.guilds[guildKey]
    if not data then return nil end
    if not data.nicknames then
        data.nicknames = {} -- self-heals SavedVariables saved before this module existed
    end
    if not data.nicknamesUpdated then
        data.nicknamesUpdated = {}
    end
    if not data.sharedNicknames then
        data.sharedNicknames = {}
    end
    if not data.sharedNicknamesUpdated then
        data.sharedNicknamesUpdated = {}
    end
    if not data.sharedNicknameOrigins then
        data.sharedNicknameOrigins = {}
    end
    if not data.nicknameMigrationConflicts then
        data.nicknameMigrationConflicts = {}
    end
    if not data.nicknameMigrationAudit then
        data.nicknameMigrationAudit = {}
    end
    -- Per-key backfill, checked on every access — same
    -- fix and same reasoning as Modules/Alts.lua's getGuildData (see that
    for guid in pairs(data.nicknames) do
        if not data.nicknamesUpdated[guid] then
            data.nicknamesUpdated[guid] = 0
        end
    end
    return data
end

-- Resolves the stable identity key used by shared nicknames. Invalid or
-- chained alt data fails closed to the supplied character instead of joining
-- identities that the saved relationship data does not unambiguously prove.
function Nicknames:GetRepresentativeGUID(guildKey, guid, pass)
    local data = getGuildData(guildKey, pass)
    if not data or not guid or not findPlayer(data, guid) then return guid end

    local mainGUID = data.alts and data.alts[guid]
    if not mainGUID or mainGUID == guid or not findPlayer(data, mainGUID) then return guid end
    if data.alts[mainGUID] then return guid end
    if pass then return not pass.linkedMains[guid] and mainGUID or guid end
    for _, linkedMain in pairs(data.alts) do
        if linkedMain == guid then return guid end
    end
    return mainGUID
end

function Nicknames:GetIdentityGUIDs(guildKey, guid, pass)
    local data = getGuildData(guildKey, pass)
    local representative = self:GetRepresentativeGUID(guildKey, guid, pass)
    local members = {}
    if not data or not representative or not findPlayer(data, representative) then
        return representative, members
    end

    if pass and pass.groups[representative] then return representative, pass.groups[representative] end
    members[1] = representative
    if pass then
        for _, altGUID in ipairs(pass.byMain[representative] or {}) do
            if altGUID ~= representative and findPlayer(data, altGUID)
                and self:GetRepresentativeGUID(guildKey, altGUID, pass)==representative then
                members[#members+1]=altGUID
            end
        end
        table.sort(members)
        pass.groups[representative]=members
        return representative,members
    end
    for altGUID, mainGUID in pairs(data.alts or {}) do
        if mainGUID == representative and altGUID ~= representative and findPlayer(data, altGUID)
            and self:GetRepresentativeGUID(guildKey, altGUID) == representative then
            members[#members + 1] = altGUID
        end
    end
    table.sort(members)
    return representative, members
end

local function collectKnownGUIDs(data)
    local known = {}
    for guid in pairs(data.roster or {}) do known[guid] = true end
    for guid in pairs(data.formerMembers or {}) do known[guid] = true end
    return known
end

local function isNewerDecision(candidate, current)
    if not current then return true end
    if candidate.updatedAt ~= current.updatedAt then
        return candidate.updatedAt > current.updatedAt
    end
    if candidate.originGUID ~= current.originGUID then
        return candidate.originGUID > current.originGUID
    end
    return candidate.value > current.value
end

local function collectLegacyDecisions(data, members)
    local decisions = {}
    for _, memberGUID in ipairs(members) do
        local updatedAt = tonumber(data.nicknamesUpdated[memberGUID])
        if updatedAt then
            decisions[#decisions + 1] = {
                originGUID = memberGUID,
                value = data.nicknames[memberGUID] or "",
                updatedAt = updatedAt,
            }
        end
    end
    return decisions
end

local function selectWinningDecision(decisions)
    local winner
    local greatestTimestamp = 0
    local greatestTimestampValues = {}
    for _, decision in ipairs(decisions) do
        if isNewerDecision(decision, winner) then winner = decision end
        greatestTimestamp = math.max(greatestTimestamp, decision.updatedAt)
    end
    for _, decision in ipairs(decisions) do
        if decision.updatedAt == greatestTimestamp then
            greatestTimestampValues[decision.value] = true
        end
    end
    local valueCount = 0
    for _ in pairs(greatestTimestampValues) do valueCount = valueCount + 1 end
    return winner, valueCount > 1
end

-- Creates only additive 1.2.0 state. Legacy per-character values and
-- timestamps remain byte-for-byte available to stable clients, and this
-- migration deliberately emits no event-log entry or Guild Sync message.
function Nicknames:MigrateLegacyIdentityState(guildKey)
    local data = getGuildData(guildKey)
    if not data then return false end
    if (tonumber(data.nicknameIdentitySchemaVersion) or 0) >= IDENTITY_SCHEMA_VERSION then return false end

    local known = collectKnownGUIDs(data)
    local processed = {}
    local shared = {}
    local sharedUpdated = {}
    local sharedOrigins = {}
    local conflicts = {}

    for guid in pairs(known) do
        local representative, members = self:GetIdentityGUIDs(guildKey, guid)
        if representative and not processed[representative] then
            processed[representative] = true
            local values = {}
            local distinct = {}
            local newest = 0
            local newestNonEmpty = 0

            for _, memberGUID in ipairs(members) do
                local updatedAt = data.nicknamesUpdated[memberGUID]
                if updatedAt ~= nil then
                    local value = data.nicknames[memberGUID] or ""
                    values[memberGUID] = { value = value, updatedAt = updatedAt }
                    newest = math.max(newest, tonumber(updatedAt) or 0)
                    if value ~= "" then
                        distinct[value] = true
                        newestNonEmpty = math.max(newestNonEmpty, tonumber(updatedAt) or 0)
                    end
                end
            end

            local distinctCount = 0
            local agreedValue
            for value in pairs(distinct) do
                distinctCount = distinctCount + 1
                agreedValue = value
            end

            if distinctCount == 1 then
                shared[representative] = agreedValue
                sharedUpdated[representative] = newestNonEmpty
                local agreeingDecisions = {}
                for _, decision in ipairs(collectLegacyDecisions(data, members)) do
                    if decision.value == agreedValue then
                        agreeingDecisions[#agreeingDecisions + 1] = decision
                    end
                end
                local winner = selectWinningDecision(agreeingDecisions)
                sharedOrigins[representative] = winner and winner.originGUID or representative
            elseif distinctCount > 1 then
                conflicts[representative] = { members = values }
            elseif next(values) then
                sharedUpdated[representative] = newest
                local winner = selectWinningDecision(collectLegacyDecisions(data, members))
                sharedOrigins[representative] = winner and winner.originGUID or representative
            end
        end
    end

    data.sharedNicknames = shared
    data.sharedNicknamesUpdated = sharedUpdated
    data.sharedNicknameOrigins = sharedOrigins
    data.nicknameMigrationConflicts = conflicts
    data.nicknameIdentitySchemaVersion = IDENTITY_SCHEMA_VERSION
    return true
end

-- Reconciles additive canonical state only. The caller decides when it is safe
-- to project a returned decision to legacy GUIDs, which prevents per-record
-- projection during batched full-state application.
function Nicknames:ReconcileIdentityState(guildKey, guid, pass)
    local data = getGuildData(guildKey, pass)
    if not data then return nil end
    if not pass then self:MigrateLegacyIdentityState(guildKey) end

    local representative, members = self:GetIdentityGUIDs(guildKey, guid, pass)
    if not representative or #members == 0 then return nil end
    local decisions = collectLegacyDecisions(data, members)
    local conflict = data.nicknameMigrationConflicts[representative]

    if conflict then
        local distinct = {}
        local inventory = {}
        for _, decision in ipairs(decisions) do
            distinct[decision.value] = true
            inventory[decision.originGUID] = {
                value = decision.value,
                updatedAt = decision.updatedAt,
            }
        end
        conflict.members = inventory

        local distinctCount = 0
        local agreedValue
        for value in pairs(distinct) do
            distinctCount = distinctCount + 1
            agreedValue = value
        end
        if distinctCount ~= 1 then
            GP:SendMessage("GuildParagon_NicknameConflictSuppressed", guildKey, representative)
            return { representative = representative, unresolved = true }
        end

        local winner = selectWinningDecision(decisions)
        data.nicknameMigrationConflicts[representative] = nil
        if agreedValue == "" then data.sharedNicknames[representative] = nil
        else data.sharedNicknames[representative] = agreedValue end
        data.sharedNicknamesUpdated[representative] = winner.updatedAt
        data.sharedNicknameOrigins[representative] = winner.originGUID
        return { representative = representative, adoptedAgreement = true, decision = winner }
    end

    local canonicalTimestamp = tonumber(data.sharedNicknamesUpdated[representative])
    if canonicalTimestamp then
        decisions[#decisions + 1] = {
            originGUID = data.sharedNicknameOrigins[representative] or representative,
            value = data.sharedNicknames[representative] or "",
            updatedAt = canonicalTimestamp,
        }
    end

    local winner, tiedValues = selectWinningDecision(decisions)
    if not winner then return { representative = representative } end
    if tiedValues then
        winner = {
            originGUID = winner.originGUID,
            value = winner.value,
            updatedAt = winner.updatedAt + 1,
        }
    end

    local oldValue = data.sharedNicknames[representative] or ""
    local oldTimestamp = tonumber(data.sharedNicknamesUpdated[representative])
    local oldOrigin = data.sharedNicknameOrigins[representative]
    local changed = oldValue ~= winner.value or oldTimestamp ~= winner.updatedAt or oldOrigin ~= winner.originGUID
    if winner.value == "" then data.sharedNicknames[representative] = nil
    else data.sharedNicknames[representative] = winner.value end
    data.sharedNicknamesUpdated[representative] = winner.updatedAt
    data.sharedNicknameOrigins[representative] = winner.originGUID

    local needsProjection = false
    for _, memberGUID in ipairs(members) do
        if (data.nicknames[memberGUID] or "") ~= winner.value
            or tonumber(data.nicknamesUpdated[memberGUID]) ~= winner.updatedAt then
            needsProjection = true
            break
        end
    end
    return {
        representative = representative,
        changed = changed,
        decision = winner,
        needsProjection = needsProjection,
    }
end

function Nicknames:GetMigrationConflicts(guildKey)
    local data = getGuildData(guildKey)
    if not data then return {} end
    self:MigrateLegacyIdentityState(guildKey)
    return data.nicknameMigrationConflicts
end

function Nicknames:GetMigrationConflict(guildKey, guid)
    local data = getGuildData(guildKey)
    if not data then return nil end
    self:MigrateLegacyIdentityState(guildKey)
    local linkedMain = data.alts and data.alts[guid]
    if linkedMain and data.nicknameMigrationConflicts[linkedMain] then
        return data.nicknameMigrationConflicts[linkedMain], linkedMain
    end
    return data.nicknameMigrationConflicts[guid], guid
end

function Nicknames:GetMigrationConflictCount(guildKey)
    local count = 0
    for _ in pairs(self:GetMigrationConflicts(guildKey)) do count = count + 1 end
    return count
end

local function normalizeNickname(nickname)
    nickname = strtrim(nickname or "")
    if #nickname > NICKNAME_MAX_CHARS then
        return nil, string.format(GP.L["Nicknames must be %d characters or fewer."], NICKNAME_MAX_CHARS)
    end
    return nickname
end

local function getAliasBucket(guildKey, create)
    if not guildKey or not GP.db or not GP.db.profile then return nil end
    local aliases = GP.db.profile.personalAliases
    if not aliases and create then
        aliases = {}
        GP.db.profile.personalAliases = aliases
    end
    if not aliases then return nil end
    if not aliases[guildKey] and create then aliases[guildKey] = {} end
    return aliases[guildKey]
end

function Nicknames:GetSharedNickname(guildKey, guid)
    local data = getGuildData(guildKey)
    if not data then return "" end
    self:MigrateLegacyIdentityState(guildKey)
    local representative = self:GetRepresentativeGUID(guildKey, guid)
    if data.nicknameMigrationConflicts[representative] then
        return data.nicknames[guid] or ""
    end
    return data.sharedNicknames[representative] or data.nicknames[guid] or ""
end

function Nicknames:GetPersonalAlias(guildKey, guid)
    local representative = self:GetRepresentativeGUID(guildKey, guid)
    local aliases = getAliasBucket(guildKey, false)
    return (aliases and aliases[representative]) or ""
end

function Nicknames:SetPersonalAlias(guildKey, guid, alias)
    local data = getGuildData(guildKey)
    if not data or not findPlayer(data, guid) then return false, GP.L["Player not found."] end
    local normalized, err = normalizeNickname(alias)
    if not normalized then return false, err end

    local representative = self:GetRepresentativeGUID(guildKey, guid)
    local aliases = getAliasBucket(guildKey, true)
    if normalized == "" then aliases[representative] = nil
    else aliases[representative] = normalized end
    GP:SendMessage("GuildParagon_PersonalAliasChanged", guildKey, representative, normalized)
    return true
end

function Nicknames:GetDisplayName(guildKey, guid)
    local data = getGuildData(guildKey)
    if not data then return "" end
    local representative = self:GetRepresentativeGUID(guildKey, guid)
    local alias = self:GetPersonalAlias(guildKey, representative)
    if alias ~= "" then return alias, "alias" end

    local shared = self:GetSharedNickname(guildKey, guid)
    if shared ~= "" then return shared, "nickname" end

    local representativePlayer = findPlayer(data, representative)
    if representativePlayer and representativePlayer.name then
        return representativePlayer.name, representative == guid and "character" or "main"
    end
    local player = findPlayer(data, guid)
    return (player and player.name) or "", "character"
end

local function getGroupMaximum(data, members, representative)
    local maximum = tonumber(data.sharedNicknamesUpdated[representative]) or 0
    for _, memberGUID in ipairs(members) do
        maximum = math.max(maximum, tonumber(data.nicknamesUpdated[memberGUID]) or 0)
    end
    return maximum
end

-- Writes one already-selected canonical decision to every legacy character
-- record exactly once. Emitting one normal incremental message per member
-- keeps 1.1.4 clients compatible without introducing a new payload shape.
function Nicknames:ProjectIdentityDecision(guildKey, guid, decision, emitMessages, excludeMessageGUID, pass)
    local data = getGuildData(guildKey, pass)
    if not data or not decision or type(decision.updatedAt) ~= "number" then return {} end

    local representative, members = self:GetIdentityGUIDs(guildKey, guid, pass)
    if not representative or data.nicknameMigrationConflicts[representative] then return {} end
    if (data.sharedNicknames[representative] or "") ~= (decision.value or "")
        or data.sharedNicknamesUpdated[representative] ~= decision.updatedAt then
        return {}
    end

    local projected = {}
    for _, memberGUID in ipairs(members) do
        if decision.value == "" then data.nicknames[memberGUID] = nil
        else data.nicknames[memberGUID] = decision.value end
        data.nicknamesUpdated[memberGUID] = decision.updatedAt
        projected[#projected + 1] = memberGUID
    end

    local emittedCount = 0
    if emitMessages then
        for _, memberGUID in ipairs(projected) do
            if memberGUID ~= excludeMessageGUID then
                GP:SendMessage("GuildParagon_NicknamesChanged", guildKey, memberGUID,
                    decision.value, decision.updatedAt)
                emittedCount = emittedCount + 1
            end
        end
    end
    GP:SendMessage("GuildParagon_NicknameProjectionCompleted", guildKey, representative,
        decision.originGUID, decision.updatedAt, #projected, emittedCount)
    return projected
end

function Nicknames:SetShared(guildKey, guid, nickname)
    local data = getGuildData(guildKey)
    if not data then return false, GP.L["No roster data yet."] end
    local player = findPlayer(data, guid)
    if not player then return false, GP.L["Player not found."] end
    if not GP:CanEditMemberProfile(guid) then
        return false, GP.L["You can only edit nicknames or birthdays for your own linked characters."]
    end

    local normalized, err = normalizeNickname(nickname)
    if not normalized then return false, err end
    self:MigrateLegacyIdentityState(guildKey)
    local representative, members = self:GetIdentityGUIDs(guildKey, guid)
    if not representative or #members == 0 then return false, GP.L["Player not found."] end

    local conflict = data.nicknameMigrationConflicts[representative]
    if not conflict and (data.sharedNicknames[representative] or "") == normalized then
        local canonicalRevision = tonumber(data.sharedNicknamesUpdated[representative])
        local fullyProjected = canonicalRevision ~= nil
        for _, memberGUID in ipairs(members) do
            if (data.nicknames[memberGUID] or "") ~= normalized
                or tonumber(data.nicknamesUpdated[memberGUID]) ~= canonicalRevision then
                fullyProjected = false
                break
            end
        end
        if fullyProjected then return true end
    end

    if conflict then
        data.nicknameMigrationAudit[representative] = {
            resolvedAt = time(),
            resolvedBy = guid,
            members = conflict.members,
        }
        data.nicknameMigrationConflicts[representative] = nil
    end

    local revision = math.max(time(), getGroupMaximum(data, members, representative) + 1)
    if normalized == "" then data.sharedNicknames[representative] = nil
    else data.sharedNicknames[representative] = normalized end
    data.sharedNicknamesUpdated[representative] = revision
    data.sharedNicknameOrigins[representative] = guid

    self:ProjectIdentityDecision(guildKey, representative, {
        value = normalized,
        updatedAt = revision,
        originGUID = guid,
    }, true)
    GP:GetModule("EventLog"):Add(guildKey, "nickname", guid, player.name, { toNick = normalized })
    return true
end

function Nicknames:OnRosterScanned(_, guildKey)
    local migrated = self:MigrateLegacyIdentityState(guildKey)
    if not migrated then self:NormalizeIdentityState(guildKey) end
    if not migrated then return end
    local count = self:GetMigrationConflictCount(guildKey)
    if count == 0 then return end

    local notices = GP.db.profile.nicknameConflictNotices
    notices[guildKey] = notices[guildKey] or {}
    if notices[guildKey][IDENTITY_SCHEMA_VERSION] then return end
    notices[guildKey][IDENTITY_SCHEMA_VERSION] = true
    GP:Print(string.format(GP.L["Found %d linked nickname conflict(s). Open Roster and look for [!] markers."], count))
end

local function moveRepresentativeState(data, oldRepresentative, newRepresentative)
    if not oldRepresentative or not newRepresentative or oldRepresentative == newRepresentative then return end
    data.sharedNicknames[newRepresentative] = data.sharedNicknames[oldRepresentative]
    data.sharedNicknamesUpdated[newRepresentative] = data.sharedNicknamesUpdated[oldRepresentative]
    data.sharedNicknameOrigins[newRepresentative] = data.sharedNicknameOrigins[oldRepresentative]
    if data.nicknameMigrationConflicts[oldRepresentative] then
        data.nicknameMigrationConflicts[newRepresentative] = data.nicknameMigrationConflicts[oldRepresentative]
    end
    if data.nicknameMigrationAudit[oldRepresentative] then
        data.nicknameMigrationAudit[newRepresentative] = data.nicknameMigrationAudit[oldRepresentative]
    end
    data.sharedNicknames[oldRepresentative] = nil
    data.sharedNicknamesUpdated[oldRepresentative] = nil
    data.sharedNicknameOrigins[oldRepresentative] = nil
    data.nicknameMigrationConflicts[oldRepresentative] = nil
    data.nicknameMigrationAudit[oldRepresentative] = nil
end

-- Reuse initialized data and relationship indexes only until a callback can mutate
-- guild state. No cache survives this synchronous normalization invocation.
local function normalizationPass(data)
    if (tonumber(data.nicknameIdentitySchemaVersion) or 0)<IDENTITY_SCHEMA_VERSION then return nil end
    local pass={data=data,linkedMains={},byMain={},groups={}}
    for alt, main in pairs(data.alts or {}) do
        pass.linkedMains[main]=true
        local group=pass.byMain[main]
        if not group then group={};pass.byMain[main]=group end
        group[#group+1]=alt
    end
    return pass
end

function Nicknames:NormalizeIdentityState(guildKey)
    local data = getGuildData(guildKey)
    if not data then return end
    local pass = normalizationPass(data)
    local aliases = getAliasBucket(guildKey, true)

    local aliasKeys = {}
    for guid in pairs(aliases) do aliasKeys[#aliasKeys + 1] = guid end
    GP:MonitorDetail("aliases", #aliasKeys)
    for _, guid in ipairs(aliasKeys) do
        local representative = self:GetRepresentativeGUID(guildKey, guid, pass)
        if representative ~= guid then
            if not aliases[representative] then aliases[representative] = aliases[guid] end
            aliases[guid] = nil
        end
    end

    local canonicalKeys = {}
    for guid in pairs(data.sharedNicknamesUpdated) do canonicalKeys[#canonicalKeys + 1] = guid end
    GP:MonitorDetail("identities", #canonicalKeys)
    for _, guid in ipairs(canonicalKeys) do
        local representative = self:GetRepresentativeGUID(guildKey, guid, pass)
        if representative ~= guid then
            local oldRevision = tonumber(data.sharedNicknamesUpdated[guid]) or 0
            local currentRevision = tonumber(data.sharedNicknamesUpdated[representative]) or -1
            if oldRevision > currentRevision then
                moveRepresentativeState(data, guid, representative)
            else
                if data.nicknameMigrationConflicts[guid] and not data.nicknameMigrationConflicts[representative] then
                    data.nicknameMigrationConflicts[representative] = data.nicknameMigrationConflicts[guid]
                end
                if data.nicknameMigrationAudit[guid] and not data.nicknameMigrationAudit[representative] then
                    data.nicknameMigrationAudit[representative] = data.nicknameMigrationAudit[guid]
                end
                data.sharedNicknames[guid] = nil
                data.sharedNicknamesUpdated[guid] = nil
                data.sharedNicknameOrigins[guid] = nil
                data.nicknameMigrationConflicts[guid] = nil
                data.nicknameMigrationAudit[guid] = nil
            end
        end
    end

    local reconciled = {}
    local knownCount = 0
    for guid in pairs(collectKnownGUIDs(data)) do
        knownCount = knownCount + 1
        local representative = self:GetRepresentativeGUID(guildKey, guid, pass)
        if representative and not reconciled[representative] then
            reconciled[representative] = true
            local result = self:ReconcileIdentityState(guildKey, representative, pass)
            if result and result.unresolved then pass = nil end
            if result and not result.unresolved and result.needsProjection and result.decision then
                self:ProjectIdentityDecision(guildKey, result.representative, result.decision, true, nil, pass)
                pass = nil
            end
        end
    end
    GP:MonitorDetail("known", knownCount)
end

function Nicknames:OnAltIdentityCommitted(_, guildKey, operation, guid, relatedGUID)
    local data = getGuildData(guildKey)
    if not data then return end
    self:MigrateLegacyIdentityState(guildKey)
    local aliases = getAliasBucket(guildKey, true)

    if operation == "promote" then
        moveRepresentativeState(data, relatedGUID, guid)
        if aliases[relatedGUID] and not aliases[guid] then aliases[guid] = aliases[relatedGUID] end
        aliases[relatedGUID] = nil
        return
    end

    if operation == "link" then
        if aliases[guid] and not aliases[relatedGUID] then aliases[relatedGUID] = aliases[guid] end
        aliases[guid] = nil
        local result = self:ReconcileIdentityState(guildKey, relatedGUID)
        if result and not result.unresolved and result.needsProjection and result.decision then
            self:ProjectIdentityDecision(guildKey, result.representative, result.decision, true)
        end
        data.sharedNicknames[guid] = nil
        data.sharedNicknamesUpdated[guid] = nil
        data.sharedNicknameOrigins[guid] = nil
        return
    end

    if operation == "unlink" then
        local remainingRepresentative = relatedGUID
        local remainingValue = data.sharedNicknames[remainingRepresentative] or ""
        local remainingRevision = tonumber(data.sharedNicknamesUpdated[remainingRepresentative]) or 0
        local detachedRevision = math.max(time(), remainingRevision + 1,
            (tonumber(data.nicknamesUpdated[guid]) or 0) + 1)
        data.sharedNicknames[guid] = nil
        data.sharedNicknamesUpdated[guid] = detachedRevision
        data.sharedNicknameOrigins[guid] = guid
        data.nicknameMigrationConflicts[guid] = nil
        data.nicknameMigrationAudit[guid] = nil
        self:ProjectIdentityDecision(guildKey, guid,
            { value = "", updatedAt = detachedRevision, originGUID = guid }, true)

        -- The remaining group keeps its existing decision and local alias.
        if remainingValue == "" and remainingRevision == 0 then
            data.sharedNicknames[remainingRepresentative] = nil
        end
    end
end

function Nicknames:OnEnable()
    self:RegisterMessage("GuildParagon_RosterScanned", "OnRosterScanned")
    self:RegisterMessage("GuildParagon_AltIdentityCommitted", "OnAltIdentityCommitted")
end

-- Raw per-character compatibility projection. User-facing and administrative
-- consumers must choose GetSharedNickname or GetDisplayName explicitly.
function Nicknames:Get(guildKey, guid)
    local data = getGuildData(guildKey)
    return (data and data.nicknames[guid]) or ""
end

function Nicknames:Set(guildKey, guid, nickname, ts)
    local L = GP.L
    if not ts then return self:SetShared(guildKey, guid, nickname) end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end

    local player = data.roster[guid] or data.formerMembers[guid]
    if not player then return false, L["Player not found."] end
    nickname = normalizeNickname(nickname)
    if nickname == nil then return false, string.format(L["Nicknames must be %d characters or fewer."], NICKNAME_MAX_CHARS) end

    ts = ts or time()
    local old = data.nicknames[guid]
    local changed = not (old == nickname or (old == nil and nickname == ""))

    if nickname == "" then
        data.nicknames[guid] = nil
    else
        data.nicknames[guid] = nickname
    end
    -- nicknamesUpdated stamps unconditionally (same tombstone-freshness
    -- reasoning as Modules/Alts.lua's file header) — only the EventLog
    data.nicknamesUpdated[guid] = ts

    if changed then
        GP:GetModule("EventLog"):Add(guildKey, "nickname", guid, player.name, { toNick = nickname })
        GP:SendMessage("GuildParagon_NicknamesChanged", guildKey, guid, nickname, ts)
    end
    return true
end

function Nicknames:GetUpdatedAt(guildKey, guid)
    local data = getGuildData(guildKey)
    return data and data.nicknamesUpdated[guid]
end

function Nicknames:GetAllForSync(guildKey)
    local data = getGuildData(guildKey)
    if not data then return {}, {} end
    return data.nicknames, data.nicknamesUpdated
end

function Nicknames:GetResolvedLegacyReplay(guildKey)
    local data = getGuildData(guildKey)
    local replay = {}
    if not data then return replay end
    self:MigrateLegacyIdentityState(guildKey)

    -- Resolve against this synchronous snapshot once. Calling the public lookup
    -- for every record repeatedly backfills nicknames and scans all alt links.
    local referencedAsMain = {}
    for _, mainGUID in pairs(data.alts or {}) do referencedAsMain[mainGUID] = true end
    for guid, updatedAt in pairs(data.nicknamesUpdated) do
        local representative = guid
        local mainGUID = data.alts and data.alts[guid]
        if findPlayer(data, guid) and mainGUID and mainGUID ~= guid
            and findPlayer(data, mainGUID) and not data.alts[mainGUID]
            and not referencedAsMain[guid] then
            representative = mainGUID
        end
        if not data.nicknameMigrationConflicts[representative] and type(updatedAt) == "number" then
            replay[#replay + 1] = { guid = guid, nick = data.nicknames[guid] or "", ts = updatedAt }
        end
    end
    table.sort(replay, function(a, b) return a.guid < b.guid end)
    return replay
end
