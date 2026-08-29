-- Guild Paragon — Event Log
-- Persistent history of guild membership events (join/leave/promote/demote/
local _, GP = ...

local EventLog = GP:NewModule("EventLog")

-- A real occurrence detected independently by two different online clients
-- (both saw the same leave/promote/etc. at roughly the same moment) won't
local DEDUPE_WINDOW_SECONDS = 600
local DEFAULT_RETAINED_LOG_ENTRIES = 50000
local SENSITIVE_DISPLAY_TYPES = {
    officernote = true,
    customofficernote = true,
    banwarning = true,
    grmimport = true,
    macromatch = true,
    labeladded = true,
    labelremoved = true,
}
local CATEGORY_BY_TYPE = {
    join = "join",
    joindate = "join",
    leave = "leave",
    removed = "leave",
    promote = "promote",
    demote = "demote",
    level = "level",
    inactivereturn = "inactivereturn",
    note = "note",
    officernote = "officernote",
    customnote = "customnote",
    customofficernote = "customofficernote",
    nickname = "nickname",
    altlinked = "alts",
    altcleared = "alts",
    markedmain = "alts",
    unmarkedmain = "alts",
    birthday = "birthday",
    banadded = "ban",
    banedited = "ban",
    banremoved = "ban",
    banwarning = "ban",
    macromatch = "macro",
    grmimport = "grmimport",
    labeladded = "label",
    labelremoved = "label",
}

local function nextEventId(guildData)
    guildData.logSeq = (guildData.logSeq or 0) + 1
    -- GP:LocalPlayerFullName() already yields "Name-Realm" or a nil-safe fallback.
    return (GP:LocalPlayerFullName() or "?") .. "-" .. guildData.logSeq
end

local function colorHexForClass(classFile)
    local c = classFile and C_ClassColor.GetClassColor(classFile)
    if not c then return nil end
    return string.format("%02x%02x%02x", math.floor((c.r or 1) * 255), math.floor((c.g or 1) * 255), math.floor((c.b or 1) * 255))
end

local function findPlayerByName(guildData, name)
    if not guildData or not name then return nil end
    local needle = name:lower()
    local shortNeedle = needle:match("^([^-]+)") or needle

    local function matches(player)
        local full = (player.name or ""):lower()
        local short = full:match("^([^-]+)") or full
        return full == needle or short == shortNeedle
    end

    for _, player in pairs(guildData.roster or {}) do
        if matches(player) then return player end
    end
    for _, player in pairs(guildData.formerMembers or {}) do
        if matches(player) then return player end
    end
    return nil
end

local function colorName(guildKey, guid, name)
    name = name or "?"
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    local player = guildData and guid and ((guildData.roster or {})[guid] or (guildData.formerMembers or {})[guid])
    if not player then
        player = findPlayerByName(guildData, name)
    end

    local hex = player and colorHexForClass(player.class)
    if not hex then return name end
    return "|cff" .. hex .. name .. "|r"
end

local function displayName(guildKey, guid, name, colored, linked)
    if linked then
        local Hyperlinks = GP:GetModule("Hyperlinks", true)
        if Hyperlinks and Hyperlinks.MemberLink then
            return Hyperlinks:MemberLink(guildKey, guid, name, colored)
        end
    end
    return colored and colorName(guildKey, guid, name) or (name or "?")
end

local MONTH_NUMBERS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

local function parseGRMLogTimestamp(text)
    local day, monthName, year, hour, minute, meridiem, rest = tostring(text or ""):match(
        "^%s*(%d%d?)%s+(%a+)%s+'(%d%d)%s+(%d%d?):(%d%d)%s*([AaPp][Mm])%s*:%s*(.*)$"
    )
    if not day then return nil end

    local month = MONTH_NUMBERS[monthName:sub(1, 3):lower()]
    day, year, hour, minute = tonumber(day), tonumber(year), tonumber(hour), tonumber(minute)
    if not day or not month or not year or not hour or not minute then return nil end

    year = 2000 + year
    meridiem = meridiem:lower()
    if meridiem == "pm" and hour < 12 then
        hour = hour + 12
    elseif meridiem == "am" and hour == 12 then
        hour = 0
    end

    local ts = time({ year = year, month = month, day = day, hour = hour, min = minute, sec = 0 })
    if not ts then return nil end
    return ts, rest
end

local function hasNoteValues(entry)
    return entry and (entry.fromNote ~= nil or entry.toNote ~= nil)
end

local function formatNoteChange(template, name, fromNote, toNote)
    return string.format(template, name, fromNote or "", toNote or "")
end

local function enrichJoinAttribution(existing, candidate)
    if not existing or not candidate or existing.type ~= "join" or candidate.type ~= "join" then return false end
    if not candidate.invitedBy or candidate.invitedBy == "" or existing.invitedBy then return false end
    existing.invitedBy = candidate.invitedBy
    existing.invitedByMode = candidate.invitedByMode
    existing.recruitmentContact = candidate.recruitmentContact and true or false
    existing.recruitmentContactedAt = candidate.recruitmentContactedAt
    existing.recruitmentResolvedAt = candidate.recruitmentResolvedAt
    return true
end

local function eventLogSettings()
    GP.db.profile.eventLog = GP.db.profile.eventLog or {}
    GP.db.profile.eventLog.toChat = GP.db.profile.eventLog.toChat or {}
    return GP.db.profile.eventLog
end

local function chatEchoBlocked()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
        if ok and active then return true end
    end
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        mapID = ok and GP:SafeNumber(mapID, 0) or 0
        if mapID > 0 then return true end
    end
    return false
end

local function shouldEchoToChat(entry)
    if not entry or chatEchoBlocked() then return false end
    if not EventLog:CanDisplayEntry(entry) then return false end

    local key = CATEGORY_BY_TYPE[entry.type]
    if not key or key == "grmimport" then return false end

    local settings = eventLogSettings()
    return settings.toChat[key] == true
end

function EventLog:Add(guildKey, entryType, guid, name, extra)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return end
    guildData.logRemoved = guildData.logRemoved or {}

    local entry = extra or {}
    entry.id = nextEventId(guildData)
    entry.ts = time()
    entry.type = entryType
    entry.guid = guid
    entry.name = name

    table.insert(guildData.log, entry)
    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, entry)
    if not entry.suppressChat and shouldEchoToChat(entry) then
        GP:Print(self:Render(entry, guildKey, true, true))
    end
end

function EventLog:AddJoin(guildKey, guid, name, extra)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return end
    extra = extra or {}
    local currentTime = time()

    for index = #(guildData.log or {}), 1, -1 do
        local existing = guildData.log[index]
        if existing and existing.type == "join" and existing.guid == guid and type(existing.ts) == "number" then
            local delta = currentTime - existing.ts
            if delta > DEDUPE_WINDOW_SECONDS then break end
            if math.abs(delta) <= DEDUPE_WINDOW_SECONDS then
                local changed = enrichJoinAttribution(existing, extra)
                if extra.rejoin ~= nil and existing.rejoin ~= extra.rejoin then
                    existing.rejoin = extra.rejoin and true or false
                    changed = true
                end
                if changed then
                    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, existing)
                end
                return existing
            end
        end
    end

    self:Add(guildKey, "join", guid, name, extra)
    return extra
end

local function isRemoved(guildData, entry)
    return guildData and entry and entry.id and guildData.logRemoved and guildData.logRemoved[entry.id]
end

function EventLog:IsRemoved(guildKey, entry)
    return isRemoved(GP.db.global.guilds[guildKey], entry) and true or false
end

function EventLog:IsDuplicate(guildKey, candidate)
    local log = self:GetLog(guildKey)
    if not log or not candidate.ts then return false end

    for i = #log, 1, -1 do
        local entry = log[i]
        if entry.ts and (candidate.ts - entry.ts) > DEDUPE_WINDOW_SECONDS then
            break
        end
        if candidate.id and entry.id == candidate.id then
            return true
        end
        if candidate.type == "grmimport" and entry.type == "grmimport"
            and entry.ts == candidate.ts and entry.text == candidate.text then
            return true
        end
        if entry.type == candidate.type and entry.guid == candidate.guid
            and entry.ts and math.abs(entry.ts - candidate.ts) <= DEDUPE_WINDOW_SECONDS then
            enrichJoinAttribution(entry, candidate)
            return true
        end
    end
    return false
end

function EventLog:GetRecentForSync(guildKey, days, maxCount)
    local log = self:GetLog(guildKey)
    if not log then return {} end
    local guildData = GP.db.global.guilds[guildKey]

    local cutoff = time() - (days * 24 * 3600)
    local recent = {}
    for i = #log, 1, -1 do
        local entry = log[i]
        if not entry.ts or entry.ts < cutoff then break end -- ts-ascending array; nothing before this point is newer either
        if self:CanDisplayEntry(entry) and not isRemoved(guildData, entry) then
            table.insert(recent, entry)
            if #recent >= maxCount then break end
        end
    end
    return recent
end

local function copyEntry(entry)
    local out = {}
    for key, value in pairs(entry) do
        out[key] = value
    end
    return out
end

function EventLog:GetFullForSync(guildKey)
    local log = self:GetLog(guildKey)
    if not log then return {} end
    local guildData = GP.db.global.guilds[guildKey]

    local entries = {}
    for _, entry in ipairs(log) do
        if type(entry) == "table" and self:CanDisplayEntry(entry) and not isRemoved(guildData, entry) then
            table.insert(entries, copyEntry(entry))
        end
    end
    return entries
end

function EventLog:MergeEntries(guildKey, entries)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return 0, 0 end
    guildData.logRemoved = guildData.logRemoved or {}

    local knownIDs, knownGRMImports = {}, {}
    for _, entry in ipairs(guildData.log or {}) do
        if entry.id then
            knownIDs[entry.id] = true
        end
        if entry.type == "grmimport" and entry.ts and entry.text then
            knownGRMImports[entry.ts .. "\001" .. tostring(entry.text)] = true
        end
    end

    local considered, toInsert, changedExisting = 0, {}, false
    for _, candidate in ipairs(entries) do
        considered = considered + 1
        if type(candidate) == "table" and candidate.type == "removed" and candidate.guid and type(candidate.ts) == "number" then
            for index = #(guildData.log or {}), 1, -1 do
                local existing = guildData.log[index]
                if existing and existing.guid == candidate.guid and existing.type == "leave"
                    and type(existing.ts) == "number" and math.abs(existing.ts - candidate.ts) <= DEDUPE_WINDOW_SECONDS then
                    table.remove(guildData.log, index)
                    if existing.id then guildData.logRemoved[existing.id] = time() end
                    changedExisting = true
                    break
                end
            end
        end
        if type(candidate) == "table" and candidate.type == "join" and candidate.guid and type(candidate.ts) == "number" and candidate.invitedBy then
            for index = #(guildData.log or {}), 1, -1 do
                local existing = guildData.log[index]
                if existing and existing.guid == candidate.guid and existing.type == "join"
                    and type(existing.ts) == "number" and math.abs(existing.ts - candidate.ts) <= DEDUPE_WINDOW_SECONDS then
                    changedExisting = enrichJoinAttribution(existing, candidate) or changedExisting
                    break
                end
            end
        end
        local grmKey = type(candidate) == "table" and candidate.type == "grmimport" and candidate.ts and candidate.text
            and (candidate.ts .. "\001" .. tostring(candidate.text))
        if type(candidate) == "table" and type(candidate.ts) == "number" and candidate.type and (candidate.guid or candidate.type == "grmimport")
            and not (candidate.id and knownIDs[candidate.id])
            and not (grmKey and knownGRMImports[grmKey])
            and self:CanDisplayEntry(candidate)
            and not isRemoved(guildData, candidate)
            and not self:IsDuplicate(guildKey, candidate) then
            table.insert(toInsert, candidate)
            if candidate.id then knownIDs[candidate.id] = true end
            if grmKey then knownGRMImports[grmKey] = true end
        end
    end

    if #toInsert > 0 then
        for _, entry in ipairs(toInsert) do
            table.insert(guildData.log, entry)
        end
        table.sort(guildData.log, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
        GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    elseif changedExisting then
        GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    end

    return considered, #toInsert
end

function EventLog:ReplaceFromSync(guildKey, entries, removed)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData or type(entries) ~= "table" then return 0, 0 end

    local cleaned = {}
    for _, candidate in ipairs(entries) do
        if type(candidate) == "table" and type(candidate.ts) == "number" and candidate.type and (candidate.guid or candidate.type == "grmimport")
            and self:CanDisplayEntry(candidate) then
            table.insert(cleaned, copyEntry(candidate))
        end
    end
    table.sort(cleaned, function(a, b) return (a.ts or 0) < (b.ts or 0) end)

    local removedCopy = {}
    if type(removed) == "table" then
        for entryID, ts in pairs(removed) do
            if type(entryID) == "string" and type(ts) == "number" then
                removedCopy[entryID] = ts
            end
        end
    end

    guildData.log = cleaned
    guildData.logRemoved = removedCopy
    guildData.logSeq = math.max(tonumber(guildData.logSeq) or 0, #cleaned)
    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    return #entries, #cleaned
end

function EventLog:Render(entry, guildKey, colored, linked)
    local L = GP.L
    local rawName = entry.name or "?"
    local name = displayName(guildKey, entry.guid, rawName, colored, linked)

    if entry.type == "join" then
        if entry.invitedBy and entry.invitedBy ~= "" then
            if entry.rejoin then
                return string.format(L["%s has rejoined the guild. Invited by %s."], name, entry.invitedBy)
            end
            return string.format(L["%s has joined the guild. Invited by %s."], name, entry.invitedBy)
        end
        if entry.rejoin then
            return string.format(L["%s has rejoined the guild."], name)
        end
        return string.format(L["%s has joined the guild."], name)
    elseif entry.type == "joindate" then
        return string.format(L["%s's join date was set to %s from %s."], name, entry.date or "?", entry.source or "?")
    elseif entry.type == "leave" then
        return string.format(L["%s has left the guild."], name)
    elseif entry.type == "removed" then
        local actor = entry.actor or entry.removedBy or L["Unknown"]
        return string.format(L["%s was removed from the guild by %s."], name, actor)
    elseif entry.type == "promote" then
        return string.format(L["%s was promoted from %s to %s."], name, entry.fromRank or "?", entry.toRank or "?")
    elseif entry.type == "demote" then
        return string.format(L["%s was demoted from %s to %s."], name, entry.fromRank or "?", entry.toRank or "?")
    elseif entry.type == "level" then
        local toLevel = entry.toLevel or entry.level or "?"
        local gained = GP:SafeNumber(entry.gained, 1)
        local gainedText = gained == 1 and L["level"] or L["levels"]
        if entry.atLevelCap then
            return string.format(L["%s has reached the %s level cap! Hurray! (+%d %s)"], name, tostring(toLevel), gained, gainedText)
        end
        return string.format(L["%s has leveled to %s (+%d %s)"], name, tostring(toLevel), gained, gainedText)
    elseif entry.type == "inactivereturn" then
        return string.format(L["%s has come online after being inactive for %s."], name, entry.inactiveText or "?")
    elseif entry.type == "note" then
        if hasNoteValues(entry) then
            return formatNoteChange(L["%s's note changed from \"%s\" to \"%s\"."], name, entry.fromNote, entry.toNote)
        end
        return string.format(L["%s's note changed."], name)
    elseif entry.type == "officernote" then
        if hasNoteValues(entry) then
            return formatNoteChange(L["%s's officer note changed from \"%s\" to \"%s\"."], name, entry.fromNote, entry.toNote)
        end
        return string.format(L["%s's officer note changed."], name)
    elseif entry.type == "altlinked" then
        local mainName = displayName(guildKey, nil, entry.mainName, colored, false)
        return string.format(L["%s was tagged as an alt of %s."], name, mainName)
    elseif entry.type == "altcleared" then
        local mainName = displayName(guildKey, nil, entry.mainName, colored, false)
        return string.format(L["%s is no longer linked to %s."], name, mainName)
    elseif entry.type == "markedmain" then
        return string.format(L["%s was marked as a main character."], name)
    elseif entry.type == "unmarkedmain" then
        return string.format(L["%s is no longer marked as a main character."], name)
    elseif entry.type == "nickname" then
        if entry.toNick and entry.toNick ~= "" then
            return string.format(L["%s's nickname was set to \"%s\"."], name, entry.toNick)
        end
        return string.format(L["%s's nickname was cleared."], name)
    elseif entry.type == "customnote" then
        if hasNoteValues(entry) then
            return formatNoteChange(L["%s's custom note changed from \"%s\" to \"%s\"."], name, entry.fromNote, entry.toNote)
        end
        return string.format(L["%s's custom note changed."], name)
    elseif entry.type == "customofficernote" then
        if hasNoteValues(entry) then
            return formatNoteChange(L["%s's custom officer note changed from \"%s\" to \"%s\"."], name, entry.fromNote, entry.toNote)
        end
        return string.format(L["%s's custom officer note changed."], name)
    elseif entry.type == "birthday" then
        if entry.cleared then
            return string.format(L["%s's birthday was cleared."], name)
        end
        return string.format(L["%s's birthday was set to %02d-%02d."], name, entry.day or 0, entry.month or 0)
    elseif entry.type == "banadded" then
        return string.format(L["%s was added to the Ban List."], name)
    elseif entry.type == "banedited" then
        return string.format(L["%s's Ban List record was updated."], name)
    elseif entry.type == "banremoved" then
        return string.format(L["%s was removed from the Ban List."], name)
    elseif entry.type == "banwarning" then
        local bannedName = colored and colorName(guildKey, nil, entry.bannedName) or (entry.bannedName or "?")
        return string.format(L["Ban List warning: %s %s the guild. Ban record: %s. Reason: %s"],
            name,
            entry.rejoin and L["rejoined"] or L["joined"],
            bannedName,
            entry.reason or L["No Ban Reason Given"])
    elseif entry.type == "macromatch" then
        local ruleCount = GP:SafeNumber(entry.ruleCount, 0)
        local ruleNames = entry.ruleNames or L["Unknown"]
        if ruleCount == 1 then
            return string.format(L["%s matches 1 saved macro rule - %s."], name, ruleNames)
        end
        return string.format(L["%s matches %d saved macro rules - %s."], name, ruleCount, ruleNames)
    elseif entry.type == "grmimport" then
        return entry.text or L["Imported GRM log entry."]
    elseif entry.type == "labeladded" then
        return string.format(L["%s was tagged with the \"%s\" label."], name, entry.labelName or entry.labelId or "?")
    elseif entry.type == "labelremoved" then
        return string.format(L["%s's \"%s\" label was removed."], name, entry.labelName or entry.labelId or "?")
    end

    return string.format(L["Unknown event for %s."], entry.name or "?")
end

function EventLog:GetLog(guildKey)
    local guildData = GP.db.global.guilds[guildKey]
    return guildData and guildData.log or nil
end

function EventLog:CanDisplayEntry(entry)
    if not entry or not SENSITIVE_DISPLAY_TYPES[entry.type] then return true end
    return GP:IsOfficer()
end

function EventLog:GetCategoryKey(entryType)
    return CATEGORY_BY_TYPE[entryType]
end

function EventLog:CountDisplayable(guildKey)
    local log = self:GetLog(guildKey)
    if not log then return 0 end
    local guildData = GP.db.global.guilds[guildKey]
    local total = 0
    for _, entry in ipairs(log) do
        if self:CanDisplayEntry(entry) and not isRemoved(guildData, entry) then total = total + 1 end
    end
    return total
end

function EventLog:GetDisplayableTotalCount()
    local total = 0
    for guildKey in pairs(GP.db.global.guilds or {}) do
        total = total + self:CountDisplayable(guildKey)
    end
    return total
end

function EventLog:GetRemovedForSync(guildKey)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    guildData.logRemoved = guildData.logRemoved or {}
    return guildData.logRemoved
end

function EventLog:MergeRemovedEntries(guildKey, removed)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData or type(removed) ~= "table" then return 0, 0 end
    guildData.logRemoved = guildData.logRemoved or {}

    local considered, applied = 0, 0
    for entryID, ts in pairs(removed) do
        considered = considered + 1
        if type(entryID) == "string" and type(ts) == "number"
            and (not guildData.logRemoved[entryID] or ts > guildData.logRemoved[entryID]) then
            guildData.logRemoved[entryID] = ts
            applied = applied + 1
        end
    end

    if applied > 0 and guildData.log then
        local kept = {}
        for _, entry in ipairs(guildData.log) do
            if not isRemoved(guildData, entry) then table.insert(kept, entry) end
        end
        guildData.log = kept
        GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    end

    return considered, applied
end

function EventLog:GetRetentionLimit()
    return DEFAULT_RETAINED_LOG_ENTRIES
end

function EventLog:GetTotalCount()
    local total = 0
    for _, guildData in pairs(GP.db.global.guilds or {}) do
        total = total + (guildData.log and #guildData.log or 0)
    end
    return total
end

function EventLog:GetTrimPlan(guildKey, retainCount)
    retainCount = retainCount or DEFAULT_RETAINED_LOG_ENTRIES
    local log = self:GetLog(guildKey)
    local total = log and #log or 0
    local removeCount = math.max(0, total - retainCount)
    return {
        total = total,
        retain = retainCount,
        remove = removeCount,
    }
end

function EventLog:TrimToNewest(guildKey, retainCount)
    retainCount = retainCount or DEFAULT_RETAINED_LOG_ENTRIES
    local guildData = GP.db.global.guilds[guildKey]
    local log = guildData and guildData.log
    if not log then return 0, 0, 0 end

    local total = #log
    local removeCount = math.max(0, total - retainCount)
    if removeCount == 0 then
        return 0, total, total
    end

    local kept = {}
    for i = removeCount + 1, total do
        table.insert(kept, log[i])
    end
    guildData.log = kept

    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    return removeCount, #kept, total
end

function EventLog:DumpToChat(guildKey, count)
    count = count or 15
    local log = self:GetLog(guildKey)
    local guildData = GP.db.global.guilds[guildKey]

    if not guildKey or not log then
        GP:Print(GP.L["No log data yet — try /gp scan."])
        return
    end

    local visible = {}
    for i = #log, 1, -1 do
        if self:CanDisplayEntry(log[i]) and not isRemoved(guildData, log[i]) then
            table.insert(visible, log[i])
            if #visible >= count then break end
        end
    end

    local total = self:CountDisplayable(guildKey)
    GP:Print(string.format(GP.L["Showing last %d of %d log entries for %s:"], #visible, total, guildKey))

    for _, entry in ipairs(visible) do
        GP:Print("  " .. date("%Y-%m-%d %H:%M", entry.ts) .. " — " .. self:Render(entry, guildKey, true, true))
    end
end

-- Default: how many entries at the same (type, timestamp) it takes before
-- a batch is treated as suspicious. A real, human-driven mass departure at
local SUSPICIOUS_BATCH_THRESHOLD = 10

local SUSPICIOUS_TYPES = {
    leave = true,
    note = true,
    officernote = true,
}

function EventLog:FindSuspiciousBatches(guildKey, threshold)
    threshold = threshold or SUSPICIOUS_BATCH_THRESHOLD
    local log = self:GetLog(guildKey)
    if not log then return {} end

    local groups, order = {}, {}
    for _, entry in ipairs(log) do
        if SUSPICIOUS_TYPES[entry.type] or (entry.type == "join" and entry.rejoin) then
            local key = entry.type .. "|" .. tostring(entry.ts)
            if not groups[key] then
                groups[key] = { type = entry.type, ts = entry.ts, entries = {} }
                table.insert(order, key)
            end
            table.insert(groups[key].entries, entry)
        end
    end

    local batches = {}
    for _, key in ipairs(order) do
        if #groups[key].entries >= threshold then
            table.insert(batches, groups[key])
        end
    end
    table.sort(batches, function(a, b) return a.ts < b.ts end)
    return batches
end

function EventLog:RemoveSuspiciousBatches(guildKey, threshold)
    local guildData = GP.db.global.guilds[guildKey]
    if not guildData or not guildData.log then return 0, 0 end

    local batches = self:FindSuspiciousBatches(guildKey, threshold)
    if #batches == 0 then return 0, 0 end

    local toRemove = {}
    for _, batch in ipairs(batches) do
        for _, entry in ipairs(batch.entries) do
            toRemove[entry] = true
        end
    end

    local kept, removed = {}, 0
    for _, entry in ipairs(guildData.log) do
        if toRemove[entry] then
            removed = removed + 1
        else
            table.insert(kept, entry)
        end
    end
    guildData.log = kept

    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    return removed, #batches
end

function EventLog:RemoveEntry(guildKey, entryID)
    if not GP:IsOfficer() then return false, GP.L["This command is restricted to guild officers."] end

    local guildData = GP.db.global.guilds[guildKey]
    if not guildData or not guildData.log or not entryID then return false, GP.L["No log data yet — try /gp scan."] end
    guildData.logRemoved = guildData.logRemoved or {}

    local kept, removed = {}, false
    for _, entry in ipairs(guildData.log) do
        if entry.id == entryID then
            removed = true
            guildData.logRemoved[entryID] = time()
        else
            table.insert(kept, entry)
        end
    end
    if not removed then return false, GP.L["Log entry not found."] end

    guildData.log = kept
    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    return true
end

function EventLog:RemoveEntries(guildKey, entryIDs)
    if not GP:IsOfficer() then return false, GP.L["This command is restricted to guild officers."] end

    local guildData = GP.db.global.guilds[guildKey]
    if not guildData or not guildData.log or type(entryIDs) ~= "table" then return false, GP.L["No log data yet — try /gp scan."] end
    guildData.logRemoved = guildData.logRemoved or {}

    local remove = {}
    for _, entryID in ipairs(entryIDs) do
        if type(entryID) == "string" then remove[entryID] = true end
    end
    if not next(remove) then return false, GP.L["No log entries selected."] end

    local kept, removed = {}, 0
    local now = time()
    for _, entry in ipairs(guildData.log) do
        if entry.id and remove[entry.id] then
            removed = removed + 1
            guildData.logRemoved[entry.id] = now
        else
            table.insert(kept, entry)
        end
    end
    if removed == 0 then return false, GP.L["Log entry not found."] end

    guildData.log = kept
    GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    return removed
end

function EventLog:GetGRMImportDateFixPlan(guildKey)
    local log = self:GetLog(guildKey)
    if not log then return nil end

    local count = 0
    for _, entry in ipairs(log) do
        if entry.type == "grmimport" then
            local ts, text = parseGRMLogTimestamp(entry.text)
            if ts and (entry.ts ~= ts or entry.text ~= text) then
                count = count + 1
            end
        end
    end
    return count
end

function EventLog:FixGRMImportDates(guildKey)
    if not GP:IsOfficer() then return false, GP.L["This command is restricted to guild officers."] end

    local log = self:GetLog(guildKey)
    if not log then return false, GP.L["No log data yet — try /gp scan."] end

    local fixed = 0
    for _, entry in ipairs(log) do
        if entry.type == "grmimport" then
            local ts, text = parseGRMLogTimestamp(entry.text)
            if ts and (entry.ts ~= ts or entry.text ~= text) then
                entry.ts = ts
                entry.text = text
                fixed = fixed + 1
            end
        end
    end

    if fixed > 0 then
        table.sort(log, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
        GP:SendMessage("GuildParagon_LogEntryAdded", guildKey, nil)
    end
    return fixed
end
