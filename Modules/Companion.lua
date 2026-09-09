-- Guild Paragon - Companion data detection
local _, GP = ...

local Companion = GP:NewModule("Companion", "AceEvent-3.0")

local APPLY_BATCH_SIZE = 10
local APPLY_BATCH_DELAY = 0.05
local DIFF_BATCH_SIZE = 20
local NOTE_MAX_CHARS = 150
local AUTO_APPLY_INITIAL_DELAY = 12
local AUTO_APPLY_RETRY_DELAY = 5
local AUTO_APPLY_MAX_RETRIES = 60
local AUTO_APPLY_STARTUP_WINDOW = 120

local FIELD_DEFINITIONS = {
    { key = "name", labelKey = "Name" },
    { key = "spec", labelKey = "Spec" },
    { key = "itemLevel", labelKey = "Item Level" },
    { key = "itemLevelEquipped", labelKey = "Equipped Item Level" },
    { key = "level", labelKey = "Level" },
    { key = "class", labelKey = "Class" },
    { key = "race", labelKey = "Race" },
    { key = "faction", labelKey = "Faction" },
    { key = "gender", labelKey = "Gender" },
    { key = "achievementPoints", labelKey = "Achievement Points" },
}

local VALID_FIELDS = {}
for _, field in ipairs(FIELD_DEFINITIONS) do
    VALID_FIELDS[field.key] = true
end

local function cleanText(value)
    if value == nil then return "" end
    if GP.CanAccessValue and not GP:CanAccessValue(value) then return "" end
    value = GP.SafeString and GP:SafeString(value, "") or tostring(value or "")
    value = value:gsub("%s+", " ")
    return strtrim(value)
end

local function comparable(value)
    value = cleanText(value):lower()
    value = value:gsub("[%s%-_']", "")
    return value
end

local function tableCount(tbl)
    local count = 0
    if type(tbl) ~= "table" then return count end
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

local function guildKey()
    local Roster = GP:GetModule("Roster", true)
    return Roster and (Roster.currentGuildKey or Roster:GetGuildKey()) or nil
end

local function guildDataFor(key)
    return key and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[key] or nil
end

local function copyFieldDefinitions()
    local fields = {}
    for index, field in ipairs(FIELD_DEFINITIONS) do
        fields[index] = { key = field.key, labelKey = field.labelKey }
    end
    return fields
end

local function normalizeNoteText(note)
    local CustomNotes = GP:GetModule("CustomNotes", true)
    if CustomNotes and CustomNotes.NormalizeText then
        return CustomNotes:NormalizeText(note)
    end
    return cleanText(note)
end

local function companionFullName(key, member)
    local name = cleanText(member and member.name)
    if name == "" then return cleanText(key) end
    local realm = cleanText(member and member.realm)
    if realm ~= "" then
        realm = realm:gsub("%s+", "")
        return name .. "-" .. realm
    end
    return cleanText(key)
end

local function selectedFieldsFromOptions(options)
    local out = {}
    local seen = {}
    for _, key in ipairs(options and options.fields or {}) do
        key = cleanText(key)
        if VALID_FIELDS[key] and not seen[key] then
            out[#out + 1] = key
            seen[key] = true
        end
    end
    return out
end

local function generatedNote(member, fields)
    local parts = {}
    for _, key in ipairs(fields or {}) do
        local value = member and member[key]
        value = cleanText(value)
        if value ~= "" then parts[#parts + 1] = value end
    end
    return table.concat(parts, " - ")
end

local function appendNote(existing, incoming)
    existing = normalizeNoteText(existing)
    incoming = normalizeNoteText(incoming)
    if incoming == "" then return existing end
    if existing == "" then return incoming end
    if existing == incoming then return existing end
    return existing .. " | " .. incoming
end

local function companionProtectedContext()
    if InCombatLockdown and InCombatLockdown() then
        return true, GP.L["Companion note checks are paused while combat or protected content is active."]
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        return true, GP.L["Companion note checks are paused while combat or protected content is active."]
    end
    if IsInInstance then
        local ok, inInstance, instanceType = pcall(IsInInstance)
        if ok and inInstance and instanceType and instanceType ~= "none"
            and instanceType ~= "neighborhood" and instanceType ~= "interior" then
            return true, GP.L["Companion note checks are paused while combat or protected content is active."]
        end
    end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
        if ok and active then
            return true, GP.L["Companion note checks are paused while combat or protected content is active."]
        end
    end
    return false, nil
end

local function copySyncSettings(settings)
    if type(settings) ~= "table" then return nil end
    local fields = selectedFieldsFromOptions({ fields = settings.fields })
    return {
        enabled = settings.enabled and true or false,
        destination = settings.destination == "officer" and "officer" or "general",
        fields = fields,
        separator = " - ",
        setupAt = tonumber(settings.setupAt) or 0,
        setupBy = cleanText(settings.setupBy),
        updatedAt = tonumber(settings.updatedAt) or 0,
        updatedBy = cleanText(settings.updatedBy),
        autoApply = settings.autoApply and true or false,
        disabledAt = tonumber(settings.disabledAt) or nil,
        disabledBy = cleanText(settings.disabledBy),
        sourceGeneratedAt = tonumber(settings.sourceGeneratedAt) or 0,
        sourceStatus = cleanText(settings.sourceStatus),
        schemaVersion = 1,
    }
end

local function ensureSettings(key)
    local data = guildDataFor(key)
    if not data then return nil end
    data.companion = data.companion or {}
    return data.companion
end

local function currentGuildName()
    return cleanText(GP:SafeOptionalString(GP:SafeCall(GetGuildInfo, nil, "player")))
end

local function currentRealmName()
    local realm = GP:SafeOptionalString(GP:SafeCall(GetNormalizedRealmName, nil))
    if realm and realm ~= "" then return cleanText(realm) end
    realm = GP:SafeOptionalString(GP:SafeCall(GetRealmName, nil))
    return cleanText(realm)
end

local function currentClientToken()
    if WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
        return "_retail_"
    end
    return nil
end

local function snapshot()
    local status = _G.GuildParagonCompanionStatus
    local roster = _G.GuildParagonExternalRoster
    local out = {
        status = type(status) == "table" and status or nil,
        roster = type(roster) == "table" and roster or nil,
    }

    out.hasStatus = out.status ~= nil
    out.hasRoster = out.roster ~= nil
    out.installed = out.hasStatus and cleanText(out.status.status) ~= "not_configured"
    out.schemaVersion = tonumber(out.status and out.status.schemaVersion) or 0
    out.rosterSchemaVersion = tonumber(out.roster and out.roster.schemaVersion) or 0
    out.memberCount = tableCount(out.roster and out.roster.members)
    out.statusText = cleanText(out.status and out.status.status)
    out.companionVersion = cleanText(out.status and out.status.companionVersion)
    out.generatedAt = tonumber(out.status and out.status.generatedAt) or tonumber(out.roster and out.roster.generatedAt)
    out.lastSyncAt = tonumber(out.status and out.status.lastSyncAt)
    out.lastRosterCount = tonumber(out.status and out.status.lastRosterCount)
    out.lastWrittenCount = tonumber(out.status and out.status.lastWrittenCount)
    out.lastSkippedCount = tonumber(out.status and out.status.lastSkippedCount)
    out.guild = cleanText(out.status and out.status.guild)
    out.realm = cleanText(out.status and out.status.realm)
    out.region = cleanText(out.status and out.status.region)
    out.client = cleanText(out.status and out.status.client)

    local currentGuild = currentGuildName()
    local currentRealm = currentRealmName()
    local currentClient = currentClientToken()

    out.currentGuild = currentGuild
    out.currentRealm = currentRealm
    out.currentClient = currentClient
    out.guildMatches = out.guild ~= "" and currentGuild ~= "" and comparable(out.guild) == comparable(currentGuild)
    out.realmMatches = out.realm ~= "" and currentRealm ~= "" and comparable(out.realm) == comparable(currentRealm)
    out.clientMatches = out.client == "" or not currentClient or out.client == currentClient
    out.contextMatches = out.installed and out.hasRoster and out.guildMatches and out.realmMatches and out.clientMatches
    return out
end

function Companion:GetCurrentGuildKey()
    return guildKey()
end

function Companion:GetSettings(key)
    return ensureSettings(key or guildKey())
end

function Companion:GetSavedConfig(key)
    local settings = self:GetSettings(key)
    if not settings or not settings.enabled then return nil end
    return copySyncSettings(settings)
end

function Companion:IsSetupComplete(key)
    local settings = self:GetSettings(key)
    return settings and settings.enabled and settings.destination ~= nil
end

function Companion:CanView()
    return GP:IsOfficer() or GP:IsGuildMaster()
end

function Companion:CanEdit()
    return GP:IsGuildMaster()
end

function Companion:CanConfigure()
    if self:IsSetupComplete() then return self:CanEdit() end
    return self:CanView()
end

function Companion:GetSnapshot()
    return snapshot()
end

function Companion:CanStartSetup()
    if not self:CanView() then return false end
    local info = snapshot()
    return info.contextMatches, info
end

function Companion:GetDisplayStatus()
    local info = snapshot()
    local key = guildKey()
    info.guildKey = key
    info.setupComplete = self:IsSetupComplete(key)
    info.canView = self:CanView()
    info.canEdit = self:CanEdit()
    return info
end

function Companion:GetFieldDefinitions()
    return copyFieldDefinitions()
end

function Companion:BuildPreview(options)
    local info = snapshot()
    local key = guildKey()
    local data = guildDataFor(key)
    local fields = selectedFieldsFromOptions(options)
    local destination = options and options.destination == "officer" and "officer" or "general"
    local summary = {
        total = 0,
        matched = 0,
        changed = 0,
        unchanged = 0,
        missing = 0,
        blank = 0,
        destination = destination,
    }
    local rows = {}

    local blocked, blockReason = companionProtectedContext()
    if blocked then
        summary.blocked = true
        summary.blockedReason = blockReason
        info.protectedBlocked = true
        return summary, rows, info
    end

    if not info.contextMatches or not data or #fields == 0 then
        return summary, rows, info
    end

    local Roster = GP:GetModule("Roster", true)
    local values = destination == "officer" and data.customOfficerNotes or data.customNotes
    values = values or {}

    for memberKey, member in pairs(info.roster.members or {}) do
        summary.total = summary.total + 1
        local desired = normalizeNoteText(generatedNote(member, fields))
        if desired == "" then
            summary.blank = summary.blank + 1
        else
            local fullName = companionFullName(memberKey, member)
            local guid, player, matchType = nil, nil, "missing"
            if Roster and Roster.FindPlayerByName then
                guid, player, matchType = Roster:FindPlayerByName(data, fullName, false)
            end
            if guid and player then
                summary.matched = summary.matched + 1
                local current = normalizeNoteText(values[guid])
                local changed = current ~= desired
                if changed then summary.changed = summary.changed + 1 else summary.unchanged = summary.unchanged + 1 end
                rows[#rows + 1] = {
                    guid = guid,
                    name = player.name or fullName,
                    current = current,
                    desired = desired,
                    changed = changed,
                    matchType = matchType,
                }
            else
                summary.missing = summary.missing + 1
                rows[#rows + 1] = {
                    name = fullName,
                    current = "",
                    desired = desired,
                    changed = false,
                    matchType = "missing",
                }
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.matchType == "missing" and b.matchType ~= "missing" then return false end
        if b.matchType == "missing" and a.matchType ~= "missing" then return true end
        if a.changed ~= b.changed then return a.changed end
        return tostring(a.name) < tostring(b.name)
    end)

    return summary, rows, info
end

function Companion:SaveSettings(options)
    local key = guildKey()
    local settings = self:GetSettings(key)
    if not settings then return false, GP.L["No guild data is available yet."] end

    local setupComplete = self:IsSetupComplete(key)
    if setupComplete and not self:CanEdit() then
        return false, GP.L["Only the guild master can change Companion settings after setup."]
    end
    if not setupComplete and not self:CanView() then
        return false, GP.L["Only guild officers can set up Companion."]
    end

    local fields = selectedFieldsFromOptions(options)
    if #fields == 0 then return false, GP.L["Select at least one field to preview Companion notes."] end

    local info = snapshot()
    if not info.contextMatches and not setupComplete then
        return false, GP.L["Companion data must match this guild before setup can be saved."]
    end

    local now = time()
    local playerName = UnitName("player") or ""
    settings.enabled = true
    settings.destination = options and options.destination == "officer" and "officer" or "general"
    settings.fields = fields
    settings.separator = " - "
    settings.autoApply = options and options.autoApply and true or false
    settings.updatedAt = now
    settings.updatedBy = playerName
    settings.sourceGeneratedAt = info.generatedAt or info.lastSyncAt
    settings.sourceStatus = info.statusText
    settings.schemaVersion = 1
    if not setupComplete then
        settings.setupAt = now
        settings.setupBy = playerName
    end

    GP:SendMessage("GuildParagon_CompanionSettingsChanged", key)
    return true
end

function Companion:Disable()
    if not self:CanEdit() then
        return false, GP.L["Only the guild master can disable Companion."]
    end
    local key = guildKey()
    local settings = self:GetSettings(key)
    if not settings then return false, GP.L["No guild data is available yet."] end
    settings.enabled = false
    settings.disabledAt = time()
    settings.disabledBy = UnitName("player") or ""
    settings.updatedAt = settings.disabledAt
    settings.updatedBy = settings.disabledBy
    GP:SendMessage("GuildParagon_CompanionSettingsChanged", key)
    return true
end

function Companion:GetSettingsForSync(key)
    local settings = self:GetSettings(key)
    local updatedAt = tonumber(settings and settings.updatedAt) or 0
    if updatedAt <= 0 then return nil, nil end
    return copySyncSettings(settings), updatedAt
end

function Companion:GetSettingsUpdatedAt(key)
    local settings = self:GetSettings(key)
    return tonumber(settings and settings.updatedAt) or nil
end

function Companion:SetSettingsFromSync(key, incoming, ts)
    if type(incoming) ~= "table" or type(ts) ~= "number" then return false end
    local settings = self:GetSettings(key)
    if not settings then return false end
    local current = tonumber(settings.updatedAt) or 0
    if current > 0 and ts <= current then return false end

    settings.enabled = incoming.enabled and true or false
    settings.destination = incoming.destination == "officer" and "officer" or "general"
    settings.fields = selectedFieldsFromOptions({ fields = incoming.fields })
    settings.separator = " - "
    settings.autoApply = incoming.autoApply and true or false
    settings.setupAt = tonumber(incoming.setupAt) or 0
    settings.setupBy = cleanText(incoming.setupBy)
    settings.updatedAt = ts
    settings.updatedBy = cleanText(incoming.updatedBy)
    settings.disabledAt = tonumber(incoming.disabledAt) or nil
    settings.disabledBy = cleanText(incoming.disabledBy)
    settings.sourceGeneratedAt = tonumber(incoming.sourceGeneratedAt) or 0
    settings.sourceStatus = cleanText(incoming.sourceStatus)
    settings.schemaVersion = 1

    GP:SendMessage("GuildParagon_CompanionSettingsChanged", key)
    return true
end

function Companion:BuildNoteChanges()
    local config = self:GetSavedConfig()
    if not config then return {}, nil, GP.L["Companion setup has not been saved for this guild yet."] end

    local summary, rows, info = self:BuildPreview({ destination = config.destination, fields = config.fields })
    if summary and summary.blocked then
        return {}, summary, summary.blockedReason or GP.L["Companion note checks are paused while combat or protected content is active."]
    end
    if not info.contextMatches then
        return {}, summary, GP.L["Companion data must match this guild before notes can be applied."]
    end

    local changes = {}
    for _, row in ipairs(rows or {}) do
        if row.guid and row.changed and row.desired and row.desired ~= "" then
            changes[#changes + 1] = {
                guid = row.guid,
                name = row.name,
                desired = row.desired,
            }
        end
    end
    return changes, summary, nil
end

function Companion:BuildNoteChangesAsync(callback)
    callback = type(callback) == "function" and callback or function() end

    local config = self:GetSavedConfig()
    if not config then
        callback({}, nil, GP.L["Companion setup has not been saved for this guild yet."])
        return false
    end

    local info = snapshot()
    local key = guildKey()
    local data = guildDataFor(key)
    local fields = selectedFieldsFromOptions({ fields = config.fields })
    local destination = config.destination == "officer" and "officer" or "general"
    local summary = {
        total = 0,
        matched = 0,
        changed = 0,
        unchanged = 0,
        missing = 0,
        blank = 0,
        destination = destination,
    }

    local blocked, blockReason = companionProtectedContext()
    if blocked then
        summary.blocked = true
        summary.blockedReason = blockReason
        info.protectedBlocked = true
        callback({}, summary, blockReason)
        return false
    end

    if not info.contextMatches then
        callback({}, summary, GP.L["Companion data must match this guild before notes can be applied."])
        return false
    end
    if not data or #fields == 0 then
        callback({}, summary, nil)
        return true
    end

    local Roster = GP:GetModule("Roster", true)
    local values = destination == "officer" and data.customOfficerNotes or data.customNotes
    values = values or {}

    local members = {}
    for memberKey, member in pairs(info.roster.members or {}) do
        members[#members + 1] = { key = memberKey, member = member }
    end

    local changes = {}
    local abortReason
    GP:RunFrameBatches("Companion:BuildNoteChanges:" .. tostring(key), members, DIFF_BATCH_SIZE, function(entry)
        local blockedNow, blockedReason = companionProtectedContext()
        if blockedNow then
            summary.blocked = true
            summary.blockedReason = blockedReason
            info.protectedBlocked = true
            abortReason = blockedReason
            return false
        end

        local memberKey = entry.key
        local member = entry.member
        summary.total = summary.total + 1
        local desired = normalizeNoteText(generatedNote(member, fields))
        if desired == "" then
            summary.blank = summary.blank + 1
            return true
        end

        local fullName = companionFullName(memberKey, member)
        local guid, player = nil, nil
        if Roster and Roster.FindPlayerByName then
            guid, player = Roster:FindPlayerByName(data, fullName, false)
        end

        if guid and player then
            summary.matched = summary.matched + 1
            local current = normalizeNoteText(values[guid])
            if current ~= desired then
                summary.changed = summary.changed + 1
                changes[#changes + 1] = {
                    guid = guid,
                    name = player.name or fullName,
                    desired = desired,
                }
            else
                summary.unchanged = summary.unchanged + 1
            end
        else
            summary.missing = summary.missing + 1
        end

        return true
    end, function(success)
        if not success then
            callback({}, summary, abortReason or GP.L["Companion note work was cancelled."])
            return
        end
        callback(changes, summary, nil)
    end)

    return true
end

function Companion:BuildManagedNoteConflicts(action)
    local config = self:GetSavedConfig()
    if not config then return nil, {}, GP.L["Companion setup has not been saved for this guild yet."] end

    action = action == "clear" and "clear" or "move"
    local summary, previewRows, info = self:BuildPreview({ destination = config.destination, fields = config.fields })
    if summary and summary.blocked then
        return nil, {}, summary.blockedReason or GP.L["Companion note checks are paused while combat or protected content is active."]
    end
    if not info.contextMatches then
        return nil, {}, GP.L["Companion data must match this guild before existing notes can be prepared."]
    end

    local key = guildKey()
    local data = guildDataFor(key)
    if not data then return nil, {}, GP.L["No guild data is available yet."] end

    local sourceOfficer = config.destination == "officer"
    local targetOfficer = not sourceOfficer
    local targetValues = targetOfficer and data.customOfficerNotes or data.customNotes
    targetValues = targetValues or {}

    local out = {
        action = action,
        total = 0,
        cleared = 0,
        moved = 0,
        dropped = 0,
        source = config.destination,
        target = targetOfficer and "officer" or "general",
    }
    local rows = {}

    for _, row in ipairs(previewRows or {}) do
        local current = normalizeNoteText(row.current)
        if row.guid and row.matchType ~= "missing" and current ~= "" and current ~= row.desired then
            out.total = out.total + 1
            local targetCurrent = normalizeNoteText(targetValues[row.guid])
            local targetDesired
            local willMove = false
            local willDrop = false
            if action == "move" then
                targetDesired = appendNote(targetCurrent, current)
                if #targetDesired <= NOTE_MAX_CHARS then
                    willMove = true
                    out.moved = out.moved + 1
                else
                    targetDesired = targetCurrent
                    willDrop = true
                    out.dropped = out.dropped + 1
                end
            else
                willDrop = true
                out.dropped = out.dropped + 1
            end
            out.cleared = out.cleared + 1
            rows[#rows + 1] = {
                guid = row.guid,
                name = row.name,
                source = current,
                targetCurrent = targetCurrent,
                targetDesired = targetDesired,
                move = willMove,
                drop = willDrop,
            }
        end
    end

    return out, rows, nil
end

function Companion:GetMigrationStatus()
    return self.migrationState
end

function Companion:IsMigrationRunning()
    return self.migrationState and self.migrationState.running
end

function Companion:PrepareExistingNotes(action)
    if not self:CanEdit() then
        return false, GP.L["Only the guild master can prepare existing Companion notes."]
    end
    if self:IsApplyRunning() or self:IsMigrationRunning() then
        return false, GP.L["Companion note work is already running."]
    end

    local config = self:GetSavedConfig()
    if not config then return false, GP.L["Companion setup has not been saved for this guild yet."] end

    local summary, rows, err = self:BuildManagedNoteConflicts(action)
    if err then return false, err end

    local key = guildKey()
    local CustomNotes = GP:GetModule("CustomNotes", true)
    if not CustomNotes then return false, GP.L["Custom notes are not available."] end

    if #rows == 0 then
        self.migrationState = {
            running = false,
            action = summary and summary.action or action,
            total = 0,
            moved = 0,
            cleared = 0,
            dropped = 0,
            failed = 0,
            finishedAt = time(),
        }
        GP:SendMessage("GuildParagon_CompanionMigrationChanged", key)
        return true
    end

    local sourceOfficer = config.destination == "officer"
    self.migrationState = {
        running = true,
        action = summary.action,
        total = #rows,
        moved = 0,
        cleared = 0,
        dropped = 0,
        failed = 0,
        startedAt = time(),
    }
    GP:SendMessage("GuildParagon_CompanionMigrationChanged", key)

    local index = 1
    local ts = time()
    local function step()
        local processed = 0
        while processed < APPLY_BATCH_SIZE and index <= #rows do
            local row = rows[index]
            local shouldClear = row.drop and true or false
            if row.move then
                local moved = CustomNotes:SetManaged(key, row.guid, row.targetDesired, ts, not sourceOfficer)
                if moved then
                    self.migrationState.moved = self.migrationState.moved + 1
                    shouldClear = true
                else
                    self.migrationState.failed = self.migrationState.failed + 1
                end
            elseif row.drop then
                self.migrationState.dropped = self.migrationState.dropped + 1
            end

            if shouldClear then
                local cleared = CustomNotes:SetManaged(key, row.guid, "", ts, sourceOfficer)
                if cleared then
                    self.migrationState.cleared = self.migrationState.cleared + 1
                else
                    self.migrationState.failed = self.migrationState.failed + 1
                end
            end

            index = index + 1
            processed = processed + 1
        end

        if index <= #rows then
            GP:SendMessage("GuildParagon_CompanionMigrationChanged", key)
            C_Timer.After(APPLY_BATCH_DELAY, step)
        else
            self.migrationState.running = false
            self.migrationState.finishedAt = time()
            GP:SendMessage("GuildParagon_CompanionMigrationChanged", key)
        end
    end

    C_Timer.After(0, step)
    return true
end

function Companion:GetApplyStatus()
    return self.applyState
end

function Companion:IsApplyRunning()
    return self.applyState and self.applyState.running
end

function Companion:IsAutoApplyEnabled(key)
    local settings = self:GetSettings(key)
    return settings and settings.enabled and settings.autoApply and true or false
end

function Companion:GetAutoApplyStatus()
    return self.autoApplyState
end

function Companion:CanAutoApplyNow(key)
    key = key or guildKey()
    if not key then return false, GP.L["No guild data is available yet."] end
    if not self:IsAutoApplyEnabled(key) then return false, GP.L["Companion auto-apply is disabled."] end
    if not self:CanEdit() then return false, GP.L["Only the guild master can apply Companion notes."] end
    if self:IsApplyRunning() or self:IsMigrationRunning() then
        return false, GP.L["Companion note work is already running."]
    end
    local blocked, blockReason = companionProtectedContext()
    if blocked then return false, blockReason end

    local info = snapshot()
    if not info.contextMatches then
        return false, GP.L["Companion data must match this guild before notes can be applied."]
    end

    local GuildSync = GP:GetModule("GuildSync", true)
    if GuildSync and GuildSync.IsMutationInProgress and GuildSync:IsMutationInProgress(key) then
        return false, GP.L["Guild Sync is still finishing."]
    end

    return true
end

function Companion:ScheduleAutoApply(reason, delay)
    if self.autoApplyCycleStarted then return false end
    if self.enabledAt and (time() - self.enabledAt) > AUTO_APPLY_STARTUP_WINDOW then
        return false
    end
    local key = guildKey()
    if not key then return false end
    if not self:IsAutoApplyEnabled(key) then return false end

    self.autoApplyCycleStarted = true
    self.autoApplyToken = (self.autoApplyToken or 0) + 1
    local token = self.autoApplyToken
    self.autoApplyState = {
        pending = true,
        reason = reason or "scheduled",
        scheduledAt = time(),
        attempts = 0,
    }

    local function attempt()
        if token ~= self.autoApplyToken then return end
        if self.enabledAt and (time() - self.enabledAt) > AUTO_APPLY_STARTUP_WINDOW then
            self.autoApplyState.pending = false
            self.autoApplyState.skippedAt = time()
            self.autoApplyState.skippedReason = GP.L["Companion auto-apply startup window expired."]
            GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
            return
        end

        local currentKey = guildKey()
        if currentKey ~= key then
            self.autoApplyState.pending = false
            self.autoApplyState.skippedAt = time()
            self.autoApplyState.skippedReason = "guild changed"
            GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
            return
        end

        self.autoApplyState.attempts = (self.autoApplyState.attempts or 0) + 1
        local ok, err = self:CanAutoApplyNow(key)
        if not ok then
            if self.autoApplyState.attempts < AUTO_APPLY_MAX_RETRIES
                and (self:IsAutoApplyEnabled(key))
                and err == GP.L["Guild Sync is still finishing."] then
                C_Timer.After(AUTO_APPLY_RETRY_DELAY, attempt)
                return
            end
            self.autoApplyState.pending = false
            self.autoApplyState.skippedAt = time()
            self.autoApplyState.skippedReason = err
            GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
            return
        end

        self.autoApplyState.building = true
        GP:SendMessage("GuildParagon_CompanionApplyChanged", key)

        self:BuildNoteChangesAsync(function(changes, summary, buildErr)
            if token ~= self.autoApplyToken then return end
            self.autoApplyState.building = false

            if buildErr or #changes == 0 then
                self.autoApplyState.pending = false
                self.autoApplyState.finishedAt = time()
                self.autoApplyState.applied = 0
                self.autoApplyState.summary = summary
                self.autoApplyState.skippedReason = buildErr
                GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
                return
            end

            local canApply, applyErr = self:CanAutoApplyNow(key)
            if not canApply then
                self.autoApplyState.pending = false
                self.autoApplyState.skippedAt = time()
                self.autoApplyState.skippedReason = applyErr
                self.autoApplyState.summary = summary
                GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
                return
            end

            self.autoApplyState.pending = false
            self.autoApplyState.startedAt = time()
            self.autoApplyState.total = #changes
            self.autoApplyState.summary = summary

            local config = self:GetSavedConfig(key)
            local applied, errText = self:ApplyBuiltNoteChanges(changes, summary, config, key)
            if not applied then
                self.autoApplyState.skippedAt = time()
                self.autoApplyState.skippedReason = errText
                GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
            end
        end)
    end

    C_Timer.After(delay or AUTO_APPLY_INITIAL_DELAY, attempt)
    GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
    return true
end

function Companion:ApplySavedNotes()
    if not self:CanEdit() then
        return false, GP.L["Only the guild master can apply Companion notes."]
    end
    if self:IsApplyRunning() then
        return false, GP.L["Companion note apply is already running."]
    end

    local key = guildKey()
    local config = self:GetSavedConfig(key)
    if not config then return false, GP.L["Companion setup has not been saved for this guild yet."] end

    local changes, summary, err = self:BuildNoteChanges()
    if err then return false, err end
    if #changes == 0 then
        self.applyState = {
            running = false,
            destination = config.destination,
            total = 0,
            applied = 0,
            failed = 0,
            finishedAt = time(),
            summary = summary,
        }
        GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
        return true
    end

    return self:ApplyBuiltNoteChanges(changes, summary, config, key)
end

function Companion:ApplyBuiltNoteChanges(changes, summary, config, key)
    if not self:CanEdit() then
        return false, GP.L["Only the guild master can apply Companion notes."]
    end
    if self:IsApplyRunning() then
        return false, GP.L["Companion note apply is already running."]
    end

    key = key or guildKey()
    config = config or self:GetSavedConfig(key)
    if not config then return false, GP.L["Companion setup has not been saved for this guild yet."] end

    changes = changes or {}
    if #changes == 0 then
        self.applyState = {
            running = false,
            destination = config.destination,
            total = 0,
            applied = 0,
            failed = 0,
            finishedAt = time(),
            summary = summary,
        }
        GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
        return true
    end

    local CustomNotes = GP:GetModule("CustomNotes", true)
    if not CustomNotes then return false, GP.L["Custom notes are not available."] end

    self.applyState = {
        running = true,
        destination = config.destination,
        total = #changes,
        applied = 0,
        failed = 0,
        startedAt = time(),
        summary = summary,
    }
    GP:SendMessage("GuildParagon_CompanionApplyChanged", key)

    local index = 1
    local ts = time()
    local function step()
        local processed = 0
        while processed < APPLY_BATCH_SIZE and index <= #changes do
            local change = changes[index]
            local ok
            if CustomNotes.SetManaged then
                ok = CustomNotes:SetManaged(key, change.guid, change.desired, ts, config.destination == "officer")
            elseif config.destination == "officer" then
                ok = CustomNotes:SetOfficer(key, change.guid, change.desired, ts)
            else
                ok = CustomNotes:Set(key, change.guid, change.desired, ts)
            end
            if ok then
                self.applyState.applied = self.applyState.applied + 1
            else
                self.applyState.failed = self.applyState.failed + 1
            end
            index = index + 1
            processed = processed + 1
        end

        if index <= #changes then
            GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
            C_Timer.After(APPLY_BATCH_DELAY, step)
        else
            self.applyState.running = false
            self.applyState.finishedAt = time()
            GP:SendMessage("GuildParagon_CompanionApplyChanged", key)
        end
    end

    C_Timer.After(0, step)
    return true
end

function Companion:OnEnable()
    self.enabledAt = time()
    self:RegisterMessage("GuildParagon_RosterScanned", function()
        GP:SendMessage("GuildParagon_CompanionStatusChanged")
        self:ScheduleAutoApply("roster scanned")
    end)
    self:RegisterMessage("GuildParagon_SyncStatusChanged", function()
        GP:SendMessage("GuildParagon_CompanionApplyChanged", guildKey())
    end)
    self:RegisterMessage("GuildParagon_CompanionSettingsChanged", function()
        GP:SendMessage("GuildParagon_CompanionApplyChanged", guildKey())
    end)
    C_Timer.After(AUTO_APPLY_INITIAL_DELAY, function()
        self:ScheduleAutoApply("login")
    end)
end
