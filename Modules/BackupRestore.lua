-- Guild Paragon — Backup / Restore
--
-- Manual current-guild snapshots. Backups live outside the guild data bucket
-- so restoring a guild does not destroy the restore points themselves.
local _, GP = ...

local BackupRestore = GP:NewModule("BackupRestore")

local MAX_COPY_DEPTH = 32
local DEFAULT_MAX_BACKUPS = 3

local function copyValue(value, depth)
    if type(value) ~= "table" then return value end
    depth = (depth or 0) + 1
    if depth > MAX_COPY_DEPTH then return nil end

    local out = {}
    for k, v in pairs(value) do
        if type(v) ~= "function" and type(k) ~= "function" then
            local copiedKey = copyValue(k, depth)
            if copiedKey ~= nil then
                out[copiedKey] = copyValue(v, depth)
            end
        end
    end
    return out
end

local function countTable(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function ensureRoot()
    GP.db.global.backups = GP.db.global.backups or {}
    return GP.db.global.backups
end

local function currentGuild()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey, guildKey and GP.db.global.guilds[guildKey]
end

local function summarizeGuildData(data)
    data = data or {}
    return {
        active = countTable(data.roster),
        former = countTable(data.formerMembers),
        log = #(data.log or {}),
        alts = countTable(data.alts),
        mains = countTable(data.mains),
        nicknames = countTable(data.nicknames),
        customNotes = countTable(data.customNotes),
        customOfficerNotes = countTable(data.customOfficerNotes),
        macroRules = countTable(data.macroRules or (GP.db.profile.macroTool and GP.db.profile.macroTool.savedRules)),
        macroIgnores = countTable(data.macroIgnores),
    }
end

local function sortedBackups(list)
    local out = {}
    for id, backup in pairs(list or {}) do
        if type(backup) == "table" then
            backup.id = id
            table.insert(out, backup)
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.createdAt) or 0) > (tonumber(b.createdAt) or 0)
    end)
    return out
end

function BackupRestore:GetBackups(guildKey)
    guildKey = guildKey or select(1, currentGuild())
    if not guildKey then return {} end
    return sortedBackups(ensureRoot()[guildKey])
end

function BackupRestore:GetMaxBackups()
    GP.db.profile.backupRestore = GP.db.profile.backupRestore or {}
    local maxBackups = tonumber(GP.db.profile.backupRestore.maxBackups) or DEFAULT_MAX_BACKUPS
    if maxBackups < 1 then maxBackups = DEFAULT_MAX_BACKUPS end
    maxBackups = math.floor(maxBackups)
    GP.db.profile.backupRestore.maxBackups = maxBackups
    return maxBackups
end

function BackupRestore:TrimBackups(guildKey, keep)
    if not GP:IsOfficer() then return 0, GP.L["Officer access is required."] end

    guildKey = guildKey or select(1, currentGuild())
    if not guildKey then return 0 end

    keep = tonumber(keep) or self:GetMaxBackups()
    keep = math.max(1, math.floor(keep))

    local list = ensureRoot()[guildKey]
    if not list then return 0 end

    local backups = sortedBackups(list)
    local removed = 0
    for i = keep + 1, #backups do
        if backups[i].id then
            list[backups[i].id] = nil
            removed = removed + 1
        end
    end

    if removed > 0 then
        GP:SendMessage("GuildParagon_BackupsChanged")
    end

    return removed
end

function BackupRestore:CreateBackup(name)
    if not GP:IsOfficer() then return nil, GP.L["Officer access is required."] end

    local guildKey, guildData = currentGuild()
    if not guildKey or not guildData then return nil, GP.L["No roster data yet — try /gp scan."] end

    local now = time()
    local id = string.format("%d-%06d", now, random(0, 999999))
    local root = ensureRoot()
    root[guildKey] = root[guildKey] or {}

    root[guildKey][id] = {
        id = id,
        name = strtrim(tostring(name or "")) ~= "" and strtrim(tostring(name)) or date("%Y-%m-%d %H:%M", now),
        guildKey = guildKey,
        createdAt = now,
        createdBy = UnitName and UnitName("player") or nil,
        summary = summarizeGuildData(guildData),
        data = copyValue(guildData),
    }

    local pruned = self:TrimBackups(guildKey, self:GetMaxBackups()) or 0
    GP:SendMessage("GuildParagon_BackupsChanged")
    return id, nil, pruned
end

function BackupRestore:RemoveBackup(guildKey, id)
    if not GP:IsOfficer() then return false, GP.L["Officer access is required."] end
    if not guildKey or not id then return false, GP.L["Select a backup first."] end

    local list = ensureRoot()[guildKey]
    if not list or not list[id] then return false, GP.L["Backup not found."] end
    list[id] = nil
    GP:SendMessage("GuildParagon_BackupsChanged")
    return true
end

function BackupRestore:RestoreBackup(guildKey, id)
    if not GP:IsOfficer() then return false, GP.L["Officer access is required."] end
    if not guildKey or not id then return false, GP.L["Select a backup first."] end

    local list = ensureRoot()[guildKey]
    local backup = list and list[id]
    if not backup or type(backup.data) ~= "table" then return false, GP.L["Backup not found."] end

    GP.db.global.guilds[guildKey] = copyValue(backup.data)
    GP.db.global.guilds[guildKey].restoredFromBackup = {
        id = id,
        name = backup.name,
        restoredAt = time(),
        restoredBy = UnitName and UnitName("player") or nil,
    }

    GP:SendMessage("GuildParagon_BackupsChanged")
    GP:SendMessage("GuildParagon_RosterScanned")
    return true
end

function BackupRestore:GetCurrentGuildKey()
    return select(1, currentGuild())
end
