-- Guild Paragon — Custom Notes
-- Guild Paragon-owned member notes, separate from Blizzard's protected guild
local _, GP = ...

local CustomNotes = GP:NewModule("CustomNotes")

local NOTE_MAX_CHARS = 150
local JOIN_TAG_PATTERN = "joined%s*:"
local REJOIN_TAG_PATTERN = "rejoined%s*:"
local JOIN_DATE_NORMALIZE_PATTERNS = {
    "([Rr]ejoined:%s*)(%d%d)%-(%d%d)%-(%d%d)(%f[%D])",
    "([Jj]oined:%s*)(%d%d)%-(%d%d)%-(%d%d)(%f[%D])",
}

local function normalizeNoteText(note)
    note = tostring(note or "")
    note = note:gsub("[\r\n\t]+", " ")
    note = note:gsub("([Jj]oined:%s*%d%d%d%d%-%d%d%-%d%d)%s+/%s+", "%1 | ")
    note = note:gsub("([Rr]ejoined:%s*%d%d%d%d%-%d%d%-%d%d)%s+/%s+", "%1 | ")
    note = note:gsub("%s+/%s+", " ")
    note = note:gsub("%s+", " ")
    return strtrim(note)
end

local function hasLegacySeparatorArtifact(note)
    return type(note) == "string" and note:find("%s+/%s+") ~= nil
end

local function canonicalText(note)
    note = normalizeNoteText(note):lower()
    note = note:gsub("[^%w]+", "")
    return note
end

local function isSubsequence(shorter, longer)
    local j = 1
    for i = 1, #longer do
        if shorter:sub(j, j) == longer:sub(i, i) then
            j = j + 1
            if j > #shorter then return true end
        end
    end
    return false
end

local function canAccessOfficerNotes()
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

local function getGuildData(guildKey)
    local data = guildKey and GP.db.global.guilds[guildKey]
    if not data then return nil end

    data.customNotes = data.customNotes or {}
    data.customNotesUpdated = data.customNotesUpdated or {}
    data.customOfficerNotes = data.customOfficerNotes or {}
    data.customOfficerNotesUpdated = data.customOfficerNotesUpdated or {}

    for guid in pairs(data.customNotes) do
        if not data.customNotesUpdated[guid] then
            data.customNotesUpdated[guid] = 0
        end
    end
    for guid in pairs(data.customOfficerNotes) do
        if not data.customOfficerNotesUpdated[guid] then
            data.customOfficerNotesUpdated[guid] = 0
        end
    end

    return data
end

local function findPlayer(data, guid)
    return data and (data.roster[guid] or data.formerMembers[guid])
end

local function setNote(guildKey, guid, note, ts, officerOnly, quiet)
    local L = GP.L
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end

    if officerOnly and not canAccessOfficerNotes() then
        return false, L["Officer-only notes require officer access."]
    end
    if not officerOnly and not ts and not GP:IsOfficer() then
        return false, L["Custom notes require officer access."]
    end

    local player = findPlayer(data, guid)
    if not player then return false, L["Player not found."] end

    note = normalizeNoteText(note)
    if #note > NOTE_MAX_CHARS then
        return false, string.format(L["Custom notes must be %d characters or fewer."], NOTE_MAX_CHARS)
    end

    local values = officerOnly and data.customOfficerNotes or data.customNotes
    local updated = officerOnly and data.customOfficerNotesUpdated or data.customNotesUpdated
    local old = values[guid]
    local changed = not (old == note or (old == nil and note == ""))

    ts = ts or time()
    if note == "" then
        values[guid] = nil
    else
        values[guid] = note
    end
    updated[guid] = ts

    if changed and not quiet then
        GP:GetModule("EventLog"):Add(guildKey, officerOnly and "customofficernote" or "customnote", guid, player.name, {
            fromNote = old,
            toNote = note,
        })
    end

    GP:SendMessage("GuildParagon_CustomNotesChanged", guildKey, officerOnly and "officer" or "general", guid, note, ts)
    return true
end

local function normalizeJoinDateText(note)
    local changed = false
    local normalized = note or ""
    local function replace(prefix, day, month, year)
        local dd, mm, yy = tonumber(day), tonumber(month), tonumber(year)
        if not dd or not mm or not yy or dd < 1 or dd > 31 or mm < 1 or mm > 12 then
            return prefix .. day .. "-" .. month .. "-" .. year
        end
        changed = true
        return string.format("%s%04d-%02d-%02d", prefix, 2000 + yy, mm, dd)
    end
    for _, pattern in ipairs(JOIN_DATE_NORMALIZE_PATTERNS) do
        normalized = normalized:gsub(pattern, replace)
    end
    return normalized, changed
end

function CustomNotes:CanAccessOfficerNotes()
    return canAccessOfficerNotes()
end

function CustomNotes:NormalizeText(note)
    return normalizeNoteText(note)
end

function CustomNotes:ShouldKeepLocalValue(current, incomingRaw)
    local currentText = normalizeNoteText(current)
    local incomingText = normalizeNoteText(incomingRaw)
    if currentText == "" or incomingText == "" or currentText == incomingText then return false end

    if hasLegacySeparatorArtifact(incomingRaw) and not hasLegacySeparatorArtifact(currentText) then
        return true
    end

    local currentCanonical = canonicalText(currentText)
    local incomingCanonical = canonicalText(incomingText)
    if #currentCanonical > #incomingCanonical and #incomingCanonical >= 12
        and isSubsequence(incomingCanonical, currentCanonical) then
        return true
    end

    return false
end

function CustomNotes:RepairStoredNotes(guildKey)
    local data = getGuildData(guildKey)
    if not data then return 0 end

    local repaired = 0
    local function repair(values)
        for guid, note in pairs(values or {}) do
            local normalized = normalizeNoteText(note)
            if normalized ~= note then
                values[guid] = normalized ~= "" and normalized or nil
                repaired = repaired + 1
            end
        end
    end

    repair(data.customNotes)
    if canAccessOfficerNotes() then
        repair(data.customOfficerNotes)
    end
    return repaired
end

function CustomNotes:Get(guildKey, guid)
    local data = getGuildData(guildKey)
    return normalizeNoteText(data and data.customNotes[guid])
end

function CustomNotes:GetOfficer(guildKey, guid)
    if not canAccessOfficerNotes() then return "" end
    local data = getGuildData(guildKey)
    return normalizeNoteText(data and data.customOfficerNotes[guid])
end

function CustomNotes:Set(guildKey, guid, note, ts)
    return setNote(guildKey, guid, note, ts, false, false)
end

function CustomNotes:SetOfficer(guildKey, guid, note, ts)
    return setNote(guildKey, guid, note, ts, true, false)
end

local function stripJoinDateTagFromNote(note)
    note = tostring(note or "")
    local out = note
    for _, word in ipairs({ "[Rr]ejoined", "[Jj]oined" }) do
        -- Tag with content on both sides ("A | Tagged: date | B"): drop the
        -- tag plus its own leading separator, leaving the rest intact.
        out = out:gsub("%s*|%s*" .. word .. ":%s*[%d%-]+", "")
        -- Tag at the very start, something after it ("Tagged: date | B").
        out = out:gsub("^%s*" .. word .. ":%s*[%d%-]+%s*|%s*", "")
        -- Tag is the entire note.
        out = out:gsub("^%s*" .. word .. ":%s*[%d%-]+%s*$", "")
    end
    return strtrim(out)
end

function CustomNotes:StripJoinDateTags(guildKey, confirmed)
    local data = getGuildData(guildKey)
    if not data then return nil, GP.L["No roster data yet — try /gp scan."] end
    if not GP:IsGuildMaster() then return nil, GP.L["This command is restricted to the guild master."] end

    local candidates = {}
    for guid, note in pairs(data.customNotes or {}) do
        local lower = note:lower()
        if lower:find(JOIN_TAG_PATTERN) or lower:find(REJOIN_TAG_PATTERN) then
            local stripped = stripJoinDateTagFromNote(note)
            if stripped ~= note then
                table.insert(candidates, { guid = guid, note = stripped })
            end
        end
    end

    if confirmed then
        local ts = time()
        for _, candidate in ipairs(candidates) do
            setNote(guildKey, candidate.guid, candidate.note, ts, false, true)
        end
    end

    return #candidates
end

function CustomNotes:NormalizeJoinDateFormat(guildKey, confirmed)
    local data = getGuildData(guildKey)
    if not data then return nil end

    local candidates = {}
    for guid, note in pairs(data.customNotes or {}) do
        local normalized, changed = normalizeJoinDateText(note)
        if changed and normalized ~= note then
            table.insert(candidates, { guid = guid, note = normalized })
        end
    end

    if confirmed then
        local ts = time()
        for _, candidate in ipairs(candidates) do
            setNote(guildKey, candidate.guid, candidate.note, ts, false, true)
        end
    end

    return #candidates
end

function CustomNotes:GetUpdatedAt(guildKey, guid)
    local data = getGuildData(guildKey)
    return data and data.customNotesUpdated[guid]
end

function CustomNotes:GetOfficerUpdatedAt(guildKey, guid)
    local data = getGuildData(guildKey)
    return data and data.customOfficerNotesUpdated[guid]
end

function CustomNotes:GetAllForSync(guildKey)
    local data = getGuildData(guildKey)
    if not data then return {}, {}, {}, {} end
    self:RepairStoredNotes(guildKey)
    if not canAccessOfficerNotes() then
        return data.customNotes, data.customNotesUpdated, {}, {}
    end
    return data.customNotes, data.customNotesUpdated, data.customOfficerNotes, data.customOfficerNotesUpdated
end
