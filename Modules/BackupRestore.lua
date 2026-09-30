-- Guild Paragon - Backup / Restore
--
-- Local snapshots remain outside the active guild bucket. Envelope metadata is
-- additive so stable addon-file downgrades can still read the legacy fields.
local _, GP = ...
local BackupRestore = GP:NewModule("BackupRestore", "AceEvent-3.0")

local MAX_COPY_DEPTH = 32
local DEFAULT_MAX_BACKUPS = 3
local BACKUP_FORMAT = "GuildParagonBackup"
local ENVELOPE_VERSION = 1
local GUILD_DATA_SCHEMA_VERSION = 1
local VALID_CLASSES = { manual = true, automatic = true, preRestore = true }
local DEFAULT_CLASS_RETENTION = { manual = 3, automatic = 1, preRestore = 1 }
local AUTOMATIC_INTERVALS = { daily = 86400, threeDays = 259200, weekly = 604800 }
local LibDeflate = LibStub("LibDeflate")
local COMPARISON_CATEGORIES = {
    { key = "roster", flags = "synced/mixed" },
    { key = "formerMembers", flags = "synced/history" },
    { key = "alts", flags = "synced", updated = "altsUpdated" },
    { key = "mains", flags = "synced", updated = "mainsUpdated" },
    { key = "mainsSource", flags = "synced", updated = "mainsUpdated" },
    { key = "nicknames", flags = "synced", updated = "nicknamesUpdated" },
    { key = "customNotes", flags = "synced", updated = "customNotesUpdated" },
    { key = "customOfficerNotes", flags = "synced/officer", updated = "customOfficerNotesUpdated" },
    { key = "bans", flags = "synced/officer", updated = "bansUpdated" },
    { key = "recruitment", flags = "synced/local/mixed" },
    { key = "macroIgnores", flags = "synced/officer", updated = "macroIgnoresUpdated" },
    { key = "labelDefinitions", flags = "synced/officer", updated = "labelDefinitionsUpdated" },
    { key = "labelAssignments", flags = "synced/officer", updated = "labelAssignmentsUpdated" },
    { key = "log", flags = "manual/history" },
    { key = "housing", flags = "local" },
}

local function copyValue(value, depth, seen, pause)
    if pause then pause() end
    local valueType = type(value)
    if valueType ~= "table" then
        if valueType == "string" or valueType == "number" or valueType == "boolean" or valueType == "nil" then
            return value
        end
        return nil, "unsupportedType"
    end
    depth = (depth or 0) + 1
    if depth > MAX_COPY_DEPTH then return nil, "depthLimit" end
    seen = seen or {}
    if seen[value] then return nil, "cyclicTable" end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        if type(key) == "table" then seen[value] = nil return nil, "unsupportedKey" end
        local copiedKey, keyError = copyValue(key, depth, seen, pause)
        if keyError then seen[value] = nil return nil, keyError end
        local copiedChild, childError = copyValue(child, depth, seen, pause)
        if childError then seen[value] = nil return nil, childError end
        out[copiedKey] = copiedChild
    end
    seen[value] = nil
    return out
end

local function scalarToken(value)
    local valueType = type(value)
    if valueType == "string" then return "s" .. #value .. ":" .. value end
    if valueType == "number" then return "n" .. tostring(value) .. ";" end
    if valueType == "boolean" then return value and "b1" or "b0" end
    if valueType == "nil" then return "z" end
end

local function appendCanonical(value, output, depth, pause)
    if pause then pause() end
    local token = scalarToken(value)
    if token then output[#output + 1] = token return true end
    if type(value) ~= "table" or depth > MAX_COPY_DEPTH then return false end
    local entries = {}
    for key, child in pairs(value) do
        local keyToken = scalarToken(key)
        if not keyToken then return false end
        entries[#entries + 1] = { keyToken = keyToken, value = child }
    end
    table.sort(entries, function(a, b) return a.keyToken < b.keyToken end)
    output[#output + 1] = "t" .. #entries .. "{"
    for _, entry in ipairs(entries) do
        output[#output + 1] = entry.keyToken
        if not appendCanonical(entry.value, output, depth + 1, pause) then return false end
    end
    output[#output + 1] = "}"
    return true
end

local function integrityFor(data, pause)
    local output = {}
    if not appendCanonical(data, output, 1, pause) then return nil, nil, "serializeFailed" end
    local serialized = table.concat(output)
    return LibDeflate:Adler32(serialized), #serialized
end

local function categoryDiff(current, stored, category, pause)
    current, stored = current or {}, stored or {}
    if type(current) ~= "table" or type(stored) ~= "table" then
        local currentChecksum = select(1, integrityFor(current, pause))
        local storedChecksum = select(1, integrityFor(stored, pause))
        return { category = category, added = 0, removed = 0, changed = currentChecksum ~= storedChecksum and 1 or 0 }
    end
    if category == "log" then
        return { category = category, current = #current, stored = #stored, changed = #current ~= #stored and 1 or 0 }
    end
    local added, removed, changed = 0, 0, 0
    for key, storedValue in pairs(stored) do
        if pause then pause() end
        if current[key] == nil then
            added = added + 1
        else
            local currentChecksum = select(1, integrityFor(current[key], pause))
            local storedChecksum = select(1, integrityFor(storedValue, pause))
            if currentChecksum ~= storedChecksum then changed = changed + 1 end
        end
    end
    for key in pairs(current) do
        if pause then pause() end
        if stored[key] == nil then removed = removed + 1 end
    end
    return { category = category, added = added, removed = removed, changed = changed }
end

local function countNewerCurrent(currentUpdated, storedUpdated, pause)
    local newer = 0
    for key, currentTimestamp in pairs(currentUpdated or {}) do
        if pause then pause() end
        if type(currentTimestamp) == "number"
            and currentTimestamp > (tonumber((storedUpdated or {})[key]) or 0) then
            newer = newer + 1
        end
    end
    return newer
end

local function rosterRisks(currentRoster, storedRoster, pause)
    local risks = { joinDates = 0, birthdays = 0 }
    for guid, current in pairs(currentRoster or {}) do
        if pause then pause() end
        local stored = (storedRoster or {})[guid] or {}
        if (tonumber(current.joinDateUpdated) or 0) > (tonumber(stored.joinDateUpdated) or 0) then
            risks.joinDates = risks.joinDates + 1
        end
        local currentBirthday = type(current.birthdayInfo) == "table" and current.birthdayInfo or {}
        local storedBirthday = type(stored.birthdayInfo) == "table" and stored.birthdayInfo or {}
        if (tonumber(currentBirthday.timeUpdated) or 0) > (tonumber(storedBirthday.timeUpdated) or 0) then
            risks.birthdays = risks.birthdays + 1
        end
    end
    return risks, risks.joinDates + risks.birthdays
end

local function recruitmentRisks(current, stored, pause)
    current, stored = current or {}, stored or {}
    local risks = {
        gmPolicy = (tonumber(current.gmSettingsUpdated) or 0) > (tonumber(stored.gmSettingsUpdated) or 0) and 1 or 0,
        blacklist = countNewerCurrent(current.blacklistUpdated, stored.blacklistUpdated, pause),
        localState = 0,
    }
    for _, key in ipairs({ "antiSpamUpdated", "pendingInvitesUpdated", "messagesUpdated", "filtersUpdated", "customZonesUpdated" }) do
        risks.localState = risks.localState + countNewerCurrent(current[key], stored[key], pause)
    end
    local currentAnalytics = type(current.analytics) == "table" and current.analytics or {}
    local storedAnalytics = type(stored.analytics) == "table" and stored.analytics or {}
    if (tonumber(currentAnalytics.updatedAt) or 0) > (tonumber(storedAnalytics.updatedAt) or 0) then
        risks.localState = risks.localState + 1
    end
    return risks, risks.gmPolicy + risks.blacklist + risks.localState
end

local function applyEmbeddedRisks(row, category, currentData, storedData, pause)
    if category == "roster" then
        row.risks, row.riskTotal = rosterRisks(currentData.roster, storedData.roster, pause)
    elseif category == "recruitment" then
        row.risks, row.riskTotal = recruitmentRisks(currentData.recruitment, storedData.recruitment, pause)
    end
end

local function countTable(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end

local function ensureRoot()
    GP.db.global.backups = GP.db.global.backups or {}
    return GP.db.global.backups
end

local function ensureAuditRoot()
    GP.db.global.backupRestoreAudit = GP.db.global.backupRestoreAudit or {}
    return GP.db.global.backupRestoreAudit
end

local function ensureQuarantineRoot()
    GP.db.global.backupQuarantine = GP.db.global.backupQuarantine or {}
    return GP.db.global.backupQuarantine
end

local function ensureScheduleRoot()
    GP.db.global.backupSchedule = GP.db.global.backupSchedule or {}
    return GP.db.global.backupSchedule
end

local function currentGuild()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey, guildKey and GP.db.global.guilds[guildKey]
end

local function currentGuildIdentity()
    local guildKey, guildData = currentGuild()
    if not guildKey or not guildData then return nil end
    local guildName
    if GetGuildInfo then
        local ok, value = pcall(GetGuildInfo, "player")
        if ok then guildName = value end
    end
    if not guildName or guildName == "" then return nil end
    return guildKey, guildData, guildName
end

function BackupRestore:IsBoundaryBusy(guildKey)
    local Roster = GP:GetModule("Roster")
    local GuildSync = GP:GetModule("GuildSync")
    return Roster:IsScanInProgress() or GuildSync:IsMutationInProgress(guildKey)
end

function BackupRestore:OnGuildDataMutation(event)
    self.boundaryRevision = (self.boundaryRevision or 0) + 1
    if event == "GuildParagon_RosterScanned" and not self.restoreInProgress then
        C_Timer.After(1, function() self:CheckAutomaticBackup("rosterRefresh") end)
    end
end

function BackupRestore:GetAutomaticSchedule(guildKey)
    guildKey = guildKey or select(1, currentGuild())
    if not guildKey then return nil end
    local root = ensureScheduleRoot()
    root[guildKey] = root[guildKey] or {
        enabled = false,
        interval = "daily",
        keep = DEFAULT_CLASS_RETENTION.automatic,
    }
    local schedule = root[guildKey]
    if not AUTOMATIC_INTERVALS[schedule.interval] then schedule.interval = "daily" end
    schedule.keep = math.max(1, math.min(3, math.floor(tonumber(schedule.keep) or 1)))
    return schedule
end

function BackupRestore:SetAutomaticEnabled(enabled)
    local guildKey = select(1, currentGuildIdentity())
    if not guildKey then return false, GP.L["Current guild identity could not be verified."] end
    if enabled and not GP:IsOfficer() then return false, GP.L["Officer access is required."] end
    local schedule = self:GetAutomaticSchedule(guildKey)
    schedule.enabled = enabled and true or false
    if schedule.enabled then schedule.lastReason = nil end
    GP:SendMessage("GuildParagon_BackupScheduleChanged")
    if schedule.enabled then self:CheckAutomaticBackup("enabled") end
    return true
end

function BackupRestore:SetAutomaticInterval(interval)
    if not GP:IsOfficer() then return false, GP.L["Officer access is required."] end
    if not AUTOMATIC_INTERVALS[interval] then return false end
    local schedule = self:GetAutomaticSchedule()
    if not schedule then return false, GP.L["Current guild identity could not be verified."] end
    schedule.interval = interval
    GP:SendMessage("GuildParagon_BackupScheduleChanged")
    self:CheckAutomaticBackup("settingsChanged")
    return true
end

function BackupRestore:SetAutomaticRetention(keep)
    if not GP:IsOfficer() then return false, GP.L["Officer access is required."] end
    local schedule = self:GetAutomaticSchedule()
    if not schedule then return false, GP.L["Current guild identity could not be verified."] end
    schedule.keep = math.max(1, math.min(3, math.floor(tonumber(keep) or 1)))
    GP:SendMessage("GuildParagon_BackupScheduleChanged")
    return true
end

function BackupRestore:GetAutomaticStatus(guildKey)
    local schedule = self:GetAutomaticSchedule(guildKey)
    if not schedule then return nil end
    local interval = AUTOMATIC_INTERVALS[schedule.interval] or AUTOMATIC_INTERVALS.daily
    return {
        enabled = schedule.enabled == true,
        interval = schedule.interval,
        keep = schedule.keep,
        lastSuccess = schedule.lastSuccess,
        nextEligible = schedule.lastSuccess and (schedule.lastSuccess + interval) or nil,
        lastReason = schedule.lastReason,
        lastReasonAt = schedule.lastReasonAt,
        inProgress = self.automaticInProgress == true,
    }
end

function BackupRestore:CheckAutomaticBackup(trigger)
    local guildKey = select(1, currentGuildIdentity())
    local schedule = guildKey and self:GetAutomaticSchedule(guildKey)
    if not schedule or not schedule.enabled or self.automaticInProgress then return false end
    local now = time()
    local nextEligible = schedule.lastSuccess
        and (schedule.lastSuccess + (AUTOMATIC_INTERVALS[schedule.interval] or AUTOMATIC_INTERVALS.daily)) or nil
    if nextEligible and now < nextEligible then return false end

    local reason
    if not GP:IsOfficer() then
        reason = GP.L["Officer access is required."]
    elseif InCombatLockdown and InCombatLockdown() then
        reason = GP.L["Automatic backup deferred while in combat."]
    elseif self:IsBoundaryBusy(guildKey) then
        reason = GP.L["Automatic backup deferred while guild data is changing."]
    end
    if reason then
        schedule.lastReason, schedule.lastReasonAt, schedule.lastTrigger = reason, now, trigger
        GP:SendMessage("GuildParagon_BackupScheduleChanged")
        return false, reason
    end

    self.automaticInProgress = true
    schedule.lastAttempt, schedule.lastTrigger, schedule.lastReason = now, trigger, nil
    GP:SendMessage("GuildParagon_BackupScheduleChanged")
    self:CreateBackupAsync(GP.L["Automatic backup"], "automatic", nil, function(id, err)
        self.automaticInProgress = false
        if id then
            schedule.lastSuccess, schedule.lastBackupID, schedule.lastReason = time(), id, nil
        else
            schedule.lastReason, schedule.lastReasonAt = err or GP.L["Automatic backup failed."], time()
        end
        GP:SendMessage("GuildParagon_BackupScheduleChanged")
    end)
    return true
end

local function summarizeGuildData(data)
    data = data or {}
    return {
        active = countTable(data.roster), former = countTable(data.formerMembers), log = #(data.log or {}),
        alts = countTable(data.alts), mains = countTable(data.mains), nicknames = countTable(data.nicknames),
        customNotes = countTable(data.customNotes), customOfficerNotes = countTable(data.customOfficerNotes),
        macroRules = countTable(data.macroRules or (GP.db.profile.macroTool and GP.db.profile.macroTool.savedRules)),
        macroIgnores = countTable(data.macroIgnores),
    }
end

local function addonVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata("GuildParagon", "Version") or "unknown"
    end
    return GetAddOnMetadata and GetAddOnMetadata("GuildParagon", "Version") or "unknown"
end

local function backupClass(backup)
    local value = type(backup) == "table" and backup.backupClass or nil
    return VALID_CLASSES[value] and value or "manual"
end

local function validateBackup(backup, guildKey, verifyIntegrity, pause)
    if type(backup) ~= "table" or type(backup.data) ~= "table" then return false, "corrupt" end
    if type(backup.guildKey) ~= "string" or backup.guildKey == "" then return false, "corrupt" end
    if guildKey and backup.guildKey ~= guildKey then return false, "wrongGuild" end
    if backup.formatMarker and backup.formatMarker ~= BACKUP_FORMAT then return false, "unsupported" end
    if backup.envelopeVersion and tonumber(backup.envelopeVersion) ~= ENVELOPE_VERSION then return false, "unsupported" end
    if backup.backupClass and not VALID_CLASSES[backup.backupClass] then return false, "unsupported" end
    if backup.integrityAlgorithm then
        if backup.integrityAlgorithm ~= "adler32-canonical-v1" or type(backup.integrityChecksum) ~= "number" then
            return false, "unsupported"
        end
        if verifyIntegrity then
            local checksum, size = integrityFor(backup.data, pause)
            if not checksum or checksum ~= backup.integrityChecksum then return false, "integrity" end
            if backup.decodedSize and size ~= backup.decodedSize then return false, "integrity" end
        end
    end
    return true, "ready"
end

local function backupView(id, backup, guildKey)
    local view = {}
    for key, value in pairs(backup) do view[key] = value end
    view.id = id
    view.backupClass = backupClass(backup)
    view.isValid, view.validationState = validateBackup(backup, guildKey)
    return view
end

local function sortedBackups(list, guildKey)
    local out = {}
    for id, backup in pairs(list or {}) do
        if type(backup) == "table" then out[#out + 1] = backupView(id, backup, guildKey) end
    end
    table.sort(out, function(a, b) return (tonumber(a.createdAt) or 0) > (tonumber(b.createdAt) or 0) end)
    return out
end

function BackupRestore:MigrateLegacyBackups()
    local changed = 0
    for guildKey, list in pairs(ensureRoot()) do
        if type(list) == "table" then
            for id, backup in pairs(list) do
                if type(backup) == "table" and type(backup.data) == "table" then
                    local touched = false
                    if backup.id == nil then backup.id = id touched = true end
                    if backup.formatMarker == nil then backup.formatMarker = BACKUP_FORMAT touched = true end
                    if backup.envelopeVersion == nil then backup.envelopeVersion = ENVELOPE_VERSION touched = true end
                    if backup.guildDataSchemaVersion == nil then backup.guildDataSchemaVersion = GUILD_DATA_SCHEMA_VERSION touched = true end
                    if backup.backupClass == nil then backup.backupClass = "manual" touched = true end
                    if backup.sourceGuildKey == nil then backup.sourceGuildKey = backup.guildKey or guildKey touched = true end
                    if backup.migratedFromLegacy == nil then backup.migratedFromLegacy = true touched = true end
                    if touched then changed = changed + 1 end
                end
            end
        end
    end
    if changed > 0 then GP:SendMessage("GuildParagon_BackupsChanged") end
    return changed
end

function BackupRestore:GetBackups(guildKey)
    guildKey = guildKey or select(1, currentGuild())
    return guildKey and sortedBackups(ensureRoot()[guildKey], guildKey) or {}
end

function BackupRestore:GetQuarantineStatus(guildKey)
    guildKey = guildKey or select(1, currentGuild())
    local record = guildKey and ensureQuarantineRoot()[guildKey]
    if not record then return nil end
    return {
        sourceBackupID = record.sourceBackupID,
        validationState = record.validationState,
        reason = record.reason,
        stagedAt = record.stagedAt,
        failedAt = record.failedAt,
    }
end

function BackupRestore:GetComparison(guildKey, id)
    local currentKey, currentData = currentGuild()
    if not guildKey or guildKey ~= currentKey or not currentData then return nil end
    local backup = ensureRoot()[guildKey] and ensureRoot()[guildKey][id]
    local valid = backup and validateBackup(backup, guildKey)
    if not valid then return nil end
    local rows = {}
    for _, definition in ipairs(COMPARISON_CATEGORIES) do
        local category = definition.key
        local row = categoryDiff(currentData[category], backup.data[category], category)
        row.flags = definition.flags
        row.newerCurrent = definition.updated
            and countNewerCurrent(currentData[definition.updated], backup.data[definition.updated]) or 0
        applyEmbeddedRisks(row, category, currentData, backup.data)
        if row.added ~= 0 or row.removed ~= 0 or row.changed ~= 0
            or row.newerCurrent > 0 or (row.riskTotal or 0) > 0 then rows[#rows + 1] = row end
    end
    return rows
end

function BackupRestore:GetComparisonAsync(guildKey, id, callback)
    local currentKey, currentData = currentGuild()
    local backup = guildKey and ensureRoot()[guildKey] and ensureRoot()[guildKey][id]
    if guildKey ~= currentKey or not currentData or not backup or not validateBackup(backup, guildKey) then
        if callback then callback(nil) end
        return
    end
    local work = coroutine.create(function()
        local sliceStarted = debugprofilestop and debugprofilestop() or 0
        local function pause()
            if debugprofilestop and debugprofilestop() - sliceStarted >= 4 then
                coroutine.yield()
                sliceStarted = debugprofilestop()
            end
        end
        local rows = {}
        for _, definition in ipairs(COMPARISON_CATEGORIES) do
            local category = definition.key
            local row = categoryDiff(currentData[category], backup.data[category], category, pause)
            row.flags = definition.flags
            row.newerCurrent = definition.updated
                and countNewerCurrent(currentData[definition.updated], backup.data[definition.updated], pause) or 0
            applyEmbeddedRisks(row, category, currentData, backup.data, pause)
            if row.added ~= 0 or row.removed ~= 0 or row.changed ~= 0
                or row.newerCurrent > 0 or (row.riskTotal or 0) > 0 then rows[#rows + 1] = row end
        end
        return rows
    end)
    local function resumeWork()
        local results = { coroutine.resume(work) }
        if not results[1] then if callback then callback(nil) end return end
        if coroutine.status(work) == "dead" then
            if callback then callback(results[2]) end
            return
        end
        C_Timer.After(0, resumeWork)
    end
    C_Timer.After(0, resumeWork)
end

function BackupRestore:GetMaxBackups()
    GP.db.profile.backupRestore = GP.db.profile.backupRestore or {}
    local maximum = tonumber(GP.db.profile.backupRestore.maxBackups) or DEFAULT_MAX_BACKUPS
    if maximum < 1 then maximum = DEFAULT_MAX_BACKUPS end
    maximum = math.floor(maximum)
    GP.db.profile.backupRestore.maxBackups = maximum
    return maximum
end

function BackupRestore:CanCreateLocalBackup(ignoreSnapshot)
    if self.snapshotInProgress and not ignoreSnapshot then return false, GP.L["A backup is already being created."] end
    if not GP:IsOfficer() then return false, GP.L["Officer access is required."] end
    local guildKey = currentGuildIdentity()
    if not guildKey then return false, GP.L["Current guild identity could not be verified."] end
    if self:IsBoundaryBusy(guildKey) then return false, GP.L["Guild data is currently changing. Try again shortly."] end
    return true
end

function BackupRestore:CanRestoreBackup(guildKey)
    if not GP:IsGuildMaster() then return false, GP.L["Only the guild master can restore a backup."] end
    local currentKey = currentGuildIdentity()
    if not currentKey or currentKey ~= guildKey then return false, GP.L["Current guild identity could not be verified."] end
    return true
end

function BackupRestore:CanDeleteBackup(guildKey, backup)
    if backupClass(backup) == "preRestore" then
        if not GP:IsGuildMaster() then return false, GP.L["Only the guild master can remove a pre-restore backup."] end
    elseif not GP:IsOfficer() then
        return false, GP.L["Officer access is required."]
    end
    local currentKey = currentGuildIdentity()
    if not currentKey or currentKey ~= guildKey then return false, GP.L["Current guild identity could not be verified."] end
    return true
end

function BackupRestore:TrimBackups(guildKey, class, keep)
    if not GP:IsOfficer() then return 0, GP.L["Officer access is required."] end
    guildKey = guildKey or select(1, currentGuild())
    if not guildKey then return 0 end
    class = VALID_CLASSES[class] and class or "manual"
    keep = math.max(1, math.floor(tonumber(keep) or DEFAULT_CLASS_RETENTION[class] or DEFAULT_MAX_BACKUPS))
    local list = ensureRoot()[guildKey]
    if not list then return 0 end
    local backups = {}
    for _, backup in ipairs(sortedBackups(list, guildKey)) do
        if backup.backupClass == class then backups[#backups + 1] = backup end
    end
    local removed = 0
    for index = keep + 1, #backups do
        list[backups[index].id] = nil
        removed = removed + 1
    end
    if removed > 0 then GP:SendMessage("GuildParagon_BackupsChanged") end
    return removed
end

function BackupRestore:CreateBackup(name, class, internal, pause, ignoreSnapshot)
    local allowed, reason = self:CanCreateLocalBackup(ignoreSnapshot)
    if not allowed then return nil, reason end
    class = VALID_CLASSES[class] and class or "manual"
    if class == "preRestore" and not internal then
        return nil, GP.L["Pre-restore backups are created automatically during restore."]
    end
    local guildKey, guildData, guildName = currentGuildIdentity()
    local boundaryRevision = self.boundaryRevision or 0
    local startedAt = debugprofilestop and debugprofilestop() or 0
    local snapshot, copyError = copyValue(guildData, nil, nil, pause)
    if copyError then return nil, GP.L["The backup snapshot could not be copied safely."] end
    local checksum, decodedSize, integrityError = integrityFor(snapshot, pause)
    if integrityError then return nil, GP.L["The backup snapshot could not be validated."] end
    local now = time()
    local snapshotMilliseconds = not pause and debugprofilestop and (debugprofilestop() - startedAt) or nil
    local id = string.format("%d-%06d", now, random(0, 999999))
    if self:IsBoundaryBusy(guildKey) or boundaryRevision ~= (self.boundaryRevision or 0) then
        return nil, GP.L["Guild data changed while the snapshot was being created. Try again."]
    end
    local root = ensureRoot()
    root[guildKey] = root[guildKey] or {}
    root[guildKey][id] = {
        id = id, name = strtrim(tostring(name or "")) ~= "" and strtrim(tostring(name)) or date("%Y-%m-%d %H:%M", now),
        guildKey = guildKey, createdAt = now, createdBy = UnitName and UnitName("player") or nil,
        summary = summarizeGuildData(snapshot), data = snapshot,
        formatMarker = BACKUP_FORMAT, envelopeVersion = ENVELOPE_VERSION,
        guildDataSchemaVersion = GUILD_DATA_SCHEMA_VERSION, addonVersion = addonVersion(), backupClass = class,
        sourceGuildKey = guildKey, sourceGuildName = guildName,
        integrityAlgorithm = "adler32-canonical-v1", integrityChecksum = checksum, decodedSize = decodedSize,
        snapshotMilliseconds = snapshotMilliseconds,
    }
    local retention = class == "manual" and self:GetMaxBackups()
        or class == "automatic" and self:GetAutomaticSchedule(guildKey).keep
        or DEFAULT_CLASS_RETENTION[class]
    local pruned = self:TrimBackups(guildKey, class, retention) or 0
    GP:SendMessage("GuildParagon_BackupsChanged")
    return id, nil, pruned
end

function BackupRestore:CreateBackupAsync(name, class, internal, callback)
    local allowed, reason = self:CanCreateLocalBackup()
    if not allowed then if callback then callback(nil, reason) end return end
    self.snapshotInProgress = true
    local work = coroutine.create(function()
        local sliceStarted = debugprofilestop and debugprofilestop() or 0
        local function pause()
            if debugprofilestop and debugprofilestop() - sliceStarted >= 4 then
                coroutine.yield()
                sliceStarted = debugprofilestop()
            end
        end
        return self:CreateBackup(name, class, internal, pause, true)
    end)
    local workMilliseconds = 0
    local function resumeWork()
        local startedAt = debugprofilestop and debugprofilestop() or 0
        local results = { coroutine.resume(work) }
        if debugprofilestop then workMilliseconds = workMilliseconds + (debugprofilestop() - startedAt) end
        if not results[1] then
            self.snapshotInProgress = false
            if callback then callback(nil, GP.L["The backup snapshot could not be copied safely."]) end
            return
        end
        if coroutine.status(work) == "dead" then
            self.snapshotInProgress = false
            local id, err, pruned = results[2], results[3], results[4]
            local guildKey = select(1, currentGuild())
            local backup = id and guildKey and ensureRoot()[guildKey] and ensureRoot()[guildKey][id]
            if backup then backup.snapshotMilliseconds = workMilliseconds end
            if callback then callback(id, err, pruned) end
            return
        end
        C_Timer.After(0, resumeWork)
    end
    C_Timer.After(0, resumeWork)
end

function BackupRestore:RemoveBackup(guildKey, id)
    if not guildKey or not id then return false, GP.L["Select a backup first."] end
    local list = ensureRoot()[guildKey]
    local backup = list and list[id]
    if not backup then return false, GP.L["Backup not found."] end
    local allowed, reason = self:CanDeleteBackup(guildKey, backup)
    if not allowed then return false, reason end
    list[id] = nil
    GP:SendMessage("GuildParagon_BackupsChanged")
    return true
end

function BackupRestore:RestoreBackup(guildKey, id, pause)
    if not guildKey or not id then return false, GP.L["Select a backup first."] end
    local allowed, reason = self:CanRestoreBackup(guildKey)
    if not allowed then return false, reason end
    if self:IsBoundaryBusy(guildKey) then return false, GP.L["Guild data is currently changing. Try again shortly."] end
    local boundaryRevision = self.boundaryRevision or 0
    local list = ensureRoot()[guildKey]
    local backup = list and list[id]
    if not backup then return false, GP.L["Backup not found."] end
    local valid, state = validateBackup(backup, guildKey, true, pause)
    if not valid then
        return false, state == "unsupported" and GP.L["This backup format is not supported."]
            or GP.L["This backup is corrupt and cannot be restored."]
    end
    local candidate, copyError = copyValue(backup.data, nil, nil, pause)
    if copyError then return false, GP.L["This backup is corrupt and cannot be restored."] end
    local quarantine = ensureQuarantineRoot()
    quarantine[guildKey] = {
        sourceBackupID = id, stagedAt = time(), validationState = "ready", data = candidate,
        integrityAlgorithm = backup.integrityAlgorithm, integrityChecksum = backup.integrityChecksum,
        decodedSize = backup.decodedSize,
    }
    local safetyID, safetyError = self:CreateBackup(GP.L["Before restore"], "preRestore", true, pause)
    if not safetyID then return false, safetyError or GP.L["The pre-restore safety backup could not be created."] end
    if self:IsBoundaryBusy(guildKey) or boundaryRevision ~= (self.boundaryRevision or 0) then
        return false, GP.L["Guild data changed during restore validation. Active data was not replaced."]
    end
    local auditRoot = ensureAuditRoot()
    auditRoot[guildKey] = auditRoot[guildKey] or {}
    auditRoot[guildKey][#auditRoot[guildKey] + 1] = {
        sourceBackupID = id, preRestoreBackupID = safetyID, restoredAt = time(),
        restoredBy = UnitName and UnitName("player") or nil,
    }
    GP.db.global.guilds[guildKey] = candidate
    GP.db.global.guilds[guildKey].restoredFromBackup = {
        id = id, name = backup.name, preRestoreBackupID = safetyID, restoredAt = time(),
        restoredBy = UnitName and UnitName("player") or nil,
    }
    GP:SendMessage("GuildParagon_BackupsChanged")
    GP:SendMessage("GuildParagon_RosterScanned")
    quarantine[guildKey] = nil
    return true
end

function BackupRestore:RestoreBackupAsync(guildKey, id, callback)
    local allowed, reason = self:CanRestoreBackup(guildKey)
    if not allowed then if callback then callback(false, reason) end return end
    self.restoreInProgress = true
    local work = coroutine.create(function()
        local sliceStarted = debugprofilestop and debugprofilestop() or 0
        local function pause()
            if debugprofilestop and debugprofilestop() - sliceStarted >= 4 then
                coroutine.yield()
                sliceStarted = debugprofilestop()
            end
        end
        return self:RestoreBackup(guildKey, id, pause)
    end)
    local function resumeWork()
        local results = { coroutine.resume(work) }
        if not results[1] then
            self.restoreInProgress = false
            local reason = GP.L["This backup is corrupt and cannot be restored."]
            local quarantine = ensureQuarantineRoot()
            quarantine[guildKey] = quarantine[guildKey] or { sourceBackupID = id, stagedAt = time() }
            quarantine[guildKey].validationState = "failed"
            quarantine[guildKey].failedAt = time()
            quarantine[guildKey].reason = reason
            if callback then callback(false, reason) end
            return
        end
        if coroutine.status(work) == "dead" then
            self.restoreInProgress = false
            if not results[2] then
                local quarantine = ensureQuarantineRoot()
                quarantine[guildKey] = quarantine[guildKey] or { sourceBackupID = id, stagedAt = time() }
                quarantine[guildKey].validationState = "failed"
                quarantine[guildKey].failedAt = time()
                quarantine[guildKey].reason = results[3]
            end
            if callback then callback(results[2], results[3]) end
            return
        end
        C_Timer.After(0, resumeWork)
    end
    C_Timer.After(0, resumeWork)
end

function BackupRestore:GetCurrentGuildKey()
    return select(1, currentGuild())
end

function BackupRestore:OnEnable()
    self:MigrateLegacyBackups()
    self.boundaryRevision = 0
    local messages = {
        "GuildParagon_RosterScanned", "GuildParagon_AltsChanged", "GuildParagon_NicknamesChanged",
        "GuildParagon_CustomNotesChanged", "GuildParagon_FormerMemberChanged", "GuildParagon_JoinDateChanged",
        "GuildParagon_BirthdayChanged", "GuildParagon_MacroRuleChanged", "GuildParagon_MacroIgnoresChanged",
        "GuildParagon_BanListChanged", "GuildParagon_RecruitmentSettingsChanged",
        "GuildParagon_RecruitmentBlacklistChanged", "GuildParagon_LogEntryAdded", "GuildParagon_LabelsChanged",
    }
    for _, message in ipairs(messages) do self:RegisterMessage(message, "OnGuildDataMutation") end
    C_Timer.After(10, function() self:CheckAutomaticBackup("login") end)
end
