-- Guild Paragon — GRM SavedVariables import
-- One-time bridge from Guild Roster Manager's SavedVariables into Guild Paragon.
local _, GP = ...

local GRMImport = GP:NewModule("GRMImport")

local function safeString(value)
    return type(value) == "string" and value or ""
end

local function countTable(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function countPlayers(t)
    local n = 0
    for _, value in pairs(t or {}) do
        if type(value) == "table" and safeString(value.GUID) ~= "" then
            n = n + 1
        end
    end
    return n
end

local function sameGuildName(a, b)
    a, b = safeString(a):lower(), safeString(b):lower()
    return a ~= "" and b ~= "" and a == b
end

local function availableGuildKeys(...)
    local seen, keys = {}, {}
    for i = 1, select("#", ...) do
        local db = select(i, ...)
        if type(db) == "table" then
            for key in pairs(db) do
                if type(key) == "string" and not seen[key] then
                    seen[key] = true
                    table.insert(keys, key)
                end
            end
        end
    end
    table.sort(keys)
    if #keys > 6 then
        local extra = #keys - 6
        for i = #keys, 7, -1 do table.remove(keys, i) end
        table.insert(keys, string.format(GP.L["...and %d more"], extra))
    end
    return table.concat(keys, ", ")
end

local function resolveGRMGuildKey(db, guildName, clubID)
    if type(db) ~= "table" then return nil end
    if type(db[guildName]) == "table" then return guildName end

    for key, value in pairs(db) do
        if type(value) == "table" then
            if clubID and value.grmClubID and tostring(value.grmClubID) == tostring(clubID) then
                return key
            end
            if sameGuildName(key, guildName) or sameGuildName(value.grmName, guildName) then
                return key
            end
        end
    end
    return nil
end

local function joinInfo(player)
    local hist = type(player) == "table" and player.joinDateHist
    local entry = type(hist) == "table" and hist[1]
    if type(entry) ~= "table" then return nil, "" end

    local ts = type(entry[5]) == "number" and entry[5] > 0 and entry[5] or nil
    return ts, safeString(entry[4])
end

local function copyValue(value, depth)
    if type(value) ~= "table" then return value end
    depth = depth or 0
    if depth > 6 then return nil end

    local out = {}
    for k, v in pairs(value) do
        out[k] = copyValue(v, depth + 1)
    end
    return out
end

local function grmSafeListIgnored(safeList, action, now)
    if action == "kick" and type(safeList) == "boolean" then
        return safeList
    end
    if type(safeList) ~= "table" then return false end

    local entry = safeList[action]
    if type(entry) == "boolean" then return entry end
    if type(entry) ~= "table" or not entry[1] then return false end

    local hasExpiry = entry[2] and true or false
    local expiry = tonumber(entry[4]) or 0
    return (not hasExpiry or expiry <= 0 or expiry > now)
end

local function importRankHistory(player, fallbackRankName, fallbackRankIndex, fallbackTs)
    local out = {}
    local raw = type(player) == "table" and player.rankHist

    if type(raw) == "table" then
        for i = #raw, 1, -1 do
            local entry = raw[i]
            if type(entry) == "table" then
                local ts = type(entry[6]) == "number" and entry[6] > 0 and entry[6] or nil
                if ts then
                    table.insert(out, {
                        rankName = safeString(entry[1]) ~= "" and entry[1] or fallbackRankName,
                        rankIndex = fallbackRankIndex,
                        ts = ts,
                        grmVerified = entry[7] and true or false,
                        grmChangeType = entry[8],
                    })
                end
            end
        end
    end

    if #out == 0 then
        table.insert(out, {
            rankName = fallbackRankName,
            rankIndex = fallbackRankIndex,
            ts = fallbackTs,
        })
    end
    return out
end

local function playerName(player, fallback)
    return safeString(player.name) ~= "" and player.name or fallback
end

local function mapPlayer(player, fallbackName, importedAt)
    local guid = safeString(player.GUID)
    if guid == "" then return nil end

    local joinedTs = joinInfo(player)
    local firstSeen = joinedTs or importedAt

    local rankName = safeString(player.rankName)
    local rankIndex = type(player.rankIndex) == "number" and player.rankIndex or 999
    local name = playerName(player, fallbackName)

    local mapped = {
        guid = guid,
        name = name,
        firstSeen = firstSeen,
        rankHistory = importRankHistory(player, rankName, rankIndex, firstSeen),
        noteHistory = {},
        officerNoteHistory = {},
        rankName = rankName,
        rankIndex = rankIndex,
        level = type(player.level) == "number" and player.level or 0,
        note = safeString(player.note),
        officerNote = safeString(player.officerNote),
        class = safeString(player.class),
        race = player.race,
        sex = player.sex,
        faction = player.faction,
        realmName = safeString(name):match("%-(.+)$") or "",
        zone = safeString(player.zone),
        timeEnteredZone = type(player.timeEnteredZone) == "number" and player.timeEnteredZone > 0 and player.timeEnteredZone or nil,
        online = player.isOnline and true or false,
        status = player.status,
        isMobile = player.isMobile and true or false,
        lastOnline = player.lastOnline,
        lastOnlineTime = copyValue(player.lastOnlineTime),
        guildRep = player.guildRep,
        achievementPoints = player.achievementPoints,
        mythicScore = player.MythicScore,
        birthdayInfo = copyValue(player.birthdayInfo),
        grmJoinDateHist = copyValue(player.joinDateHist),
        grmRankHist = copyValue(player.rankHist),
        grmBannedInfo = copyValue(player.bannedInfo),
        grmReasonBanned = safeString(player.reasonBanned),
        grmSafeList = copyValue(player.safeList),
        joinDateUnknown = player.joinDateUnknown and true or false,
        promoteDateUnknown = player.promoteDateUnknown and true or false,
        lastSeen = importedAt,
    }

    table.insert(mapped.noteHistory, { note = mapped.note, ts = importedAt })
    table.insert(mapped.officerNoteHistory, { note = mapped.officerNote, ts = importedAt })

    return mapped
end

local function normalizeName(name)
    return GP:GetModule("Roster"):NormalizePlayerName(name)
end

local function buildNameIndex(guildData)
    local byName, shortByName, ambiguousShort = {}, {}, {}
    local function addFull(key, guid)
        key = normalizeName(key)
        if key ~= "" then byName[key] = guid end
    end
    local function addShort(key, guid)
        key = normalizeName(key)
        if key == "" or ambiguousShort[key] then return end
        if shortByName[key] and shortByName[key] ~= guid then
            shortByName[key] = nil
            ambiguousShort[key] = true
        else
            shortByName[key] = guid
        end
    end

    for guid, player in pairs(guildData.roster) do
        addFull(player.name, guid)
        local shortName = GP:GetModule("Roster"):ShortName(player.name)
        addShort(shortName, guid)
    end
    for guid, player in pairs(guildData.formerMembers) do
        addFull(player.name, guid)
        local shortName = GP:GetModule("Roster"):ShortName(player.name)
        addShort(shortName, guid)
    end
    for key, guid in pairs(shortByName) do
        if not byName[key] then byName[key] = guid end
    end
    return byName
end

local function importMembers(target, grmMembers, former, importedAt)
    local imported, skipped = 0, 0

    for name, player in pairs(grmMembers or {}) do
        if type(player) == "table" then
            local mapped = mapPlayer(player, name, importedAt)
            if mapped and (not former or not target.roster[mapped.guid]) then
                if former then
                    mapped.leftDate = importedAt
                    target.formerMembers[mapped.guid] = mapped
                else
                    target.roster[mapped.guid] = mapped
                end

                -- Only GRM's real custom note text, verbatim — never a
                -- synthesized "Joined: <date>" fallback. The join date
                local noteText = ""
                if type(player.customNote) == "table" then
                    noteText = safeString(player.customNote[4])
                end
                if noteText ~= "" then
                    target.customNotes[mapped.guid] = noteText
                    target.customNotesUpdated[mapped.guid] = importedAt
                end

                local nick = player.nicknameDetails and safeString(player.nicknameDetails.nickname) or ""
                if nick ~= "" then
                    target.nicknames[mapped.guid] = nick
                    target.nicknamesUpdated[mapped.guid] = importedAt
                end

                imported = imported + 1
            else
                skipped = skipped + 1
            end
        end
    end

    return imported, skipped
end

local function importAltGroups(target, grmAltGroups, importedAt)
    local byName = buildNameIndex(target)
    local linked, marked, skipped = 0, 0, 0

    for _, group in pairs(grmAltGroups or {}) do
        if type(group) == "table" then
            local mainName = safeString(group.main)
            local mainGUID = mainName ~= "" and byName[normalizeName(mainName)] or nil

            if mainGUID then
                target.mains[mainGUID] = true
                target.mainsUpdated[mainGUID] = type(group.timeModified) == "number" and group.timeModified or importedAt
                marked = marked + 1

                for i = 1, #group do
                    local member = group[i]
                    local altName = type(member) == "table" and safeString(member.name) or ""
                    local altGUID = altName ~= "" and byName[normalizeName(altName)] or nil
                    if altGUID and altGUID ~= mainGUID then
                        target.alts[altGUID] = mainGUID
                        target.altsUpdated[altGUID] = type(group.timeModified) == "number" and group.timeModified or importedAt
                        linked = linked + 1
                    end
                end
            elseif #group > 1 then
                skipped = skipped + #group
            end
        end
    end

    return linked, marked, skipped
end

local function linkedGUIDs(target, guid)
    local mainGUID = target.alts[guid] or guid
    local seen, out = {}, {}
    local function add(memberGUID)
        if memberGUID and not seen[memberGUID] then
            seen[memberGUID] = true
            table.insert(out, memberGUID)
        end
    end

    add(mainGUID)
    for altGUID, linkedMain in pairs(target.alts) do
        if linkedMain == mainGUID then
            add(altGUID)
        end
    end
    return out
end

local function setMacroIgnore(target, guid, action, importedAt)
    target.macroIgnores[guid] = target.macroIgnores[guid] or {}
    if not target.macroIgnores[guid][action] then
        target.macroIgnores[guid][action] = true
        target.macroIgnoresUpdated[guid] = importedAt
        return 1
    end
    return 0
end

local function importMacroIgnores(target, importedAt)
    local imported, now = 0, time()
    local actions = { "kick", "promote", "demote" }

    for guid, player in pairs(target.roster) do
        for _, action in ipairs(actions) do
            if grmSafeListIgnored(player.grmSafeList, action, now) then
                for _, linkedGUID in ipairs(linkedGUIDs(target, guid)) do
                    if target.roster[linkedGUID] then
                        imported = imported + setMacroIgnore(target, linkedGUID, action, importedAt)
                    end
                end
            end
        end
    end

    target.macroIgnoresImportedFromGRM = now
    target.macroIgnoresImportedCount = imported
    return imported
end

local function importLogEntries(target, grmLog, importedAt)
    local imported = 0

    for i, entry in ipairs(grmLog or {}) do
        if type(entry) == "table" then
            local text = safeString(entry[2])
            if text ~= "" then
                imported = imported + 1
                target.logSeq = target.logSeq + 1
                table.insert(target.log, {
                    id = "grm-import-" .. tostring(importedAt) .. "-" .. tostring(i),
                    ts = importedAt - (#grmLog - i),
                    type = "grmimport",
                    guid = "GRM_IMPORT_" .. tostring(i),
                    name = "GRM",
                    text = text,
                })
            end
        end
    end

    return imported
end

function GRMImport:GetPlan()
    local guildName = GP:SafeOptionalString(GP:SafeCall(GetGuildInfo, nil, "player"))
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if not guildName or guildName == "" or not guildKey then
        return nil, GP.L["No roster data yet — try /gp scan."]
    end

    local clubID = GP:SafeCall(C_Club and C_Club.GetGuildClubId, nil)
    local grmGuildKey = resolveGRMGuildKey(_G.GRM_GuildMemberHistory_Save, guildName, clubID)
        or resolveGRMGuildKey(_G.GRM_PlayersThatLeftHistory_Save, guildName, clubID)
        or guildName

    local active = _G.GRM_GuildMemberHistory_Save and _G.GRM_GuildMemberHistory_Save[grmGuildKey]
    local former = _G.GRM_PlayersThatLeftHistory_Save and _G.GRM_PlayersThatLeftHistory_Save[grmGuildKey]
    local alts = _G.GRM_Alts and _G.GRM_Alts[grmGuildKey]
    local log = _G.GRM_LogReport_Save and _G.GRM_LogReport_Save[grmGuildKey]
    if not active and not former then
        local keys = availableGuildKeys(_G.GRM_GuildMemberHistory_Save, _G.GRM_PlayersThatLeftHistory_Save, _G.GRM_LogReport_Save, _G.GRM_Alts)
        if keys ~= "" then
            return nil, string.format(GP.L["No GRM SavedVariables found for %s. Available GRM guild key(s): %s"], guildName, keys)
        end
        return nil, string.format(GP.L["No GRM SavedVariables found for %s. Enable GRM once, log in, then try again."], guildName)
    end

    return {
        guildName = guildName,
        grmGuildKey = grmGuildKey,
        guildKey = guildKey,
        active = active or {},
        former = former or {},
        alts = alts or {},
        log = log or {},
        activeCount = countPlayers(active),
        formerCount = countPlayers(former),
        altGroupCount = countTable(alts),
        logCount = #((type(log) == "table" and log) or {}),
    }
end

function GRMImport:ImportCurrentGuild()
    local plan, err = self:GetPlan()
    if not plan then return nil, err end

    local importedAt = time()
    local target = {
        roster = {},
        formerMembers = {},
        log = {},
        logRemoved = {},
        logSeq = 0,
        alts = {}, altsUpdated = {},
        mains = {}, mainsUpdated = {},
        nicknames = {}, nicknamesUpdated = {},
        customNotes = {}, customNotesUpdated = {},
        customOfficerNotes = {}, customOfficerNotesUpdated = {},
        macroIgnores = {}, macroIgnoresUpdated = {},
        importedFromGRM = importedAt,
    }

    local activeImported, activeSkipped = importMembers(target, plan.active, false, importedAt)
    local formerImported, formerSkipped = importMembers(target, plan.former, true, importedAt)
    local linkedAlts, markedMains, skippedAltMembers = importAltGroups(target, plan.alts, importedAt)
    local macroIgnores = importMacroIgnores(target, importedAt)
    local importedLogEntries = importLogEntries(target, plan.log, importedAt)

    GP.db.global.guilds[plan.guildKey] = target
    GP:GetModule("Roster").currentGuildKey = plan.guildKey

    GP:SendMessage("GuildParagon_RosterScanned", plan.guildKey)
    GP:SendMessage("GuildParagon_LogEntryAdded", plan.guildKey, nil)
    GP:SendMessage("GuildParagon_AltsChanged", plan.guildKey, "import", nil, nil, importedAt)
    GP:SendMessage("GuildParagon_NicknamesChanged", plan.guildKey, nil, nil, importedAt)
    GP:SendMessage("GuildParagon_CustomNotesChanged", plan.guildKey, "general", nil, nil, importedAt)
    GP:SendMessage("GuildParagon_MacroIgnoresChanged", plan.guildKey, nil, nil, nil, importedAt)

    return {
        guildName = plan.guildName,
        guildKey = plan.guildKey,
        activeImported = activeImported,
        formerImported = formerImported,
        activeSkipped = activeSkipped,
        formerSkipped = formerSkipped,
        linkedAlts = linkedAlts,
        markedMains = markedMains,
        skippedAltMembers = skippedAltMembers,
        logEntries = importedLogEntries,
        customNotes = countTable(target.customNotes),
        nicknames = countTable(target.nicknames),
        macroIgnores = macroIgnores,
    }
end
