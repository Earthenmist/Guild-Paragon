-- Guild Paragon — Ban List
--
-- Officer-only registry of banned players. Guild Paragon keeps a dedicated
-- table so future sync/import/export flows have one narrow surface.
local _, GP = ...

local BanList = GP:NewModule("BanList")
local BAN_JOIN_POPUP = "GUILDPARAGON_BAN_JOIN_WARNING"

StaticPopupDialogs[BAN_JOIN_POPUP] = StaticPopupDialogs[BAN_JOIN_POPUP] or {
    text = "%s",
    button1 = OKAY,
    button2 = GP.L["Ban List"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnCancel = function(_, _, reason)
        if reason == "clicked" and GP.UI and GP.UI.MainWindow and GP.UI.MainWindow.SelectTabByID then
            GP.UI.MainWindow:SelectTabByID("bans")
        end
    end,
}

local function trim(value)
    return strtrim(tostring(value or ""))
end

local function countTable(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function currentGuild()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey, guildKey and GP.db.global.guilds[guildKey]
end

local function ensureTables(guildData)
    guildData.bans = guildData.bans or {}
    guildData.bansUpdated = guildData.bansUpdated or {}
    return guildData.bans, guildData.bansUpdated
end

local function playerKey(guildData, name, guid)
    if guid and guid ~= "" then return guid end
    local normalized = GP:GetModule("Roster"):NormalizePlayerName(name)
    if normalized ~= "" then return "name:" .. normalized end
    return nil
end

local function parseDate(text)
    text = trim(text)
    local year, month, day = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or not month or not day then return nil end
    if month < 1 or month > 12 or day < 1 or day > 31 then return nil end

    local ts = time({ year = year, month = month, day = day, hour = 12 })
    if not ts or date("%Y-%m-%d", ts) ~= string.format("%04d-%02d-%02d", year, month, day) then return nil end
    return ts
end

local function findPlayer(guildData, name, includeFormer)
    if not name or name == "" then return nil, nil end
    local Roster = GP:GetModule("Roster")
    local guid, player = Roster:FindPlayerByName(guildData, name, includeFormer)
    return guid, player
end

local function normalizeName(name)
    return GP:GetModule("Roster"):NormalizePlayerName(name)
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

local function getLinkedGUIDs(guildKey, guildData, guid)
    local Alts = GP:GetModule("Alts", true)
    if not Alts or not guildKey or not guildData or not guid then return { guid } end

    local mainGUID = Alts:GetMain(guildKey, guid) or guid
    local seen, out = {}, {}
    local function add(memberGUID)
        if memberGUID and not seen[memberGUID] then
            seen[memberGUID] = true
            table.insert(out, memberGUID)
        end
    end

    add(mainGUID)
    for _, altGUID in ipairs(Alts:GetAlts(guildKey, mainGUID) or {}) do
        add(altGUID)
    end
    return out
end

local function copyRecord(record)
    if type(record) ~= "table" then return nil end
    return {
        id = record.id,
        active = record.active and true or false,
        name = record.name,
        guid = record.guid,
        class = record.class,
        rankName = record.rankName,
        rankIndex = record.rankIndex,
        reason = record.reason,
        bannedAt = record.bannedAt,
        bannedBy = record.bannedBy,
        removedAt = record.removedAt,
        removedBy = record.removedBy,
        source = record.source,
    }
end

local function seedGRMBans(guildData)
    if guildData.bansSeededFromGRM then return end

    local bans, updated = ensureTables(guildData)
    local imported = 0
    local function scan(bucket)
        for guid, player in pairs(bucket or {}) do
            local info = player.grmBannedInfo
            if type(info) == "table" and info[1] then
                local id = playerKey(guildData, player.name, guid)
                if id and not bans[id] then
                    bans[id] = {
                        id = id,
                        active = true,
                        name = player.name,
                        guid = guid,
                        class = player.class,
                        rankName = player.rankName,
                        rankIndex = player.rankIndex,
                        reason = trim(player.grmReasonBanned),
                        bannedAt = tonumber(info[2]) or player.lastSeen or time(),
                        bannedBy = trim(info[4]),
                        source = "grm",
                    }
                    updated[id] = bans[id].bannedAt or time()
                    imported = imported + 1
                end
            end
        end
    end

    scan(guildData.roster)
    scan(guildData.formerMembers)
    guildData.bansSeededFromGRM = time()
    guildData.bansSeededFromGRMCount = imported
end

function BanList:CanUse()
    return GP:IsOfficer()
end

function BanList:GetCurrentGuildKey()
    return select(1, currentGuild())
end

function BanList:GetRecords(guildKey, search)
    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {} end
    seedGRMBans(guildData)

    local bans = ensureTables(guildData)
    local query = GP:GetModule("Roster"):NormalizePlayerName(search or "")
    local out = {}
    for _, record in pairs(bans or {}) do
        if record.active then
            local name = record.name or ""
            local reason = record.reason or ""
            if query == "" or GP:GetModule("Roster"):NormalizePlayerName(name):find(query, 1, true)
                or reason:lower():find(query, 1, true) then
                table.insert(out, copyRecord(record))
            end
        end
    end

    table.sort(out, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return out
end

function BanList:GetRecord(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil end
    seedGRMBans(guildData)
    return copyRecord(guildData.bans and guildData.bans[id])
end

function BanList:GetActiveCount(guildKey)
    return #self:GetRecords(guildKey)
end

function BanList:FindActiveMatch(guildKey, guid, player)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil end
    seedGRMBans(guildData)

    local bans = ensureTables(guildData)
    local linked = {}
    local linkedNames = {}
    for _, linkedGUID in ipairs(getLinkedGUIDs(guildKey, guildData, guid)) do
        linked[linkedGUID] = true
        local linkedPlayer = (guildData.roster or {})[linkedGUID] or (guildData.formerMembers or {})[linkedGUID]
        local normalized = normalizeName(linkedPlayer and linkedPlayer.name)
        if normalized ~= "" then linkedNames[normalized] = true end
    end
    local playerName = normalizeName(player and player.name)
    if playerName ~= "" then linkedNames[playerName] = true end

    for id, record in pairs(bans or {}) do
        if record.active then
            if record.guid and linked[record.guid] then
                return copyRecord(record)
            end
            if record.id and linked[record.id] then
                return copyRecord(record)
            end
        end
    end

    if next(linkedNames) then
        for _, record in pairs(bans or {}) do
            if record.active and linkedNames[normalizeName(record.name)] then
                return copyRecord(record)
            end
        end
    end

    return nil
end

function BanList:CheckJoinWarning(guildKey, guid, player, rejoin)
    if not self:CanUse() then return end
    if not guildKey or not guid or not player then return end

    local record = self:FindActiveMatch(guildKey, guid, player)
    if not record then return end

    local guildData = GP.db.global.guilds[guildKey]
    if not guildData then return end
    guildData.banJoinAlerts = guildData.banJoinAlerts or {}

    local alertKey = guid .. "\001" .. tostring(record.id or record.guid or record.name or "")
    local current = time()
    if guildData.banJoinAlerts[alertKey] and current - guildData.banJoinAlerts[alertKey] < 300 then
        return
    end
    guildData.banJoinAlerts[alertKey] = current

    local reason = record.reason and record.reason ~= "" and record.reason or GP.L["No Ban Reason Given"]
    GP:GetModule("EventLog"):Add(guildKey, "banwarning", guid, player.name, {
        banID = record.id,
        bannedName = record.name,
        reason = reason,
        rejoin = rejoin and true or false,
    })

    GP:Print(string.format(GP.L["Ban List warning: %s has %s the guild. Ban record: %s. Reason: %s"],
        player.name or GP.L["Unknown"],
        rejoin and GP.L["rejoined"] or GP.L["joined"],
        record.name or GP.L["Unknown"],
        reason))
    StaticPopup_Show(BAN_JOIN_POPUP, string.format(GP.L["Ban List warning: %s has %s the guild.\n\nBan record: %s\nReason: %s"],
        player.name or GP.L["Unknown"],
        rejoin and GP.L["rejoined"] or GP.L["joined"],
        record.name or GP.L["Unknown"],
        reason))
end

function BanList:AddOrUpdate(guildKey, name, reason, bannedDateText, existingID)
    if not self:CanUse() then return false, GP.L["Officer access is required."] end

    guildKey = guildKey or self:GetCurrentGuildKey()
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end

    name = fullName(name)
    if not name then return false, GP.L["Type a character name first."] end

    local guid, player = findPlayer(guildData, name, true)
    if player then name = player.name or name end

    local parsedDate = parseDate(bannedDateText)
    if trim(bannedDateText) ~= "" and not parsedDate then
        return false, GP.L["Use YYYY-MM-DD for the ban date."]
    end

    local bans, updated = ensureTables(guildData)
    local now = time()
    local requestedID = playerKey(guildData, name, guid)
    local id = requestedID or existingID
    if not id then return false, GP.L["Type a character name first."] end

    local previous = existingID and bans[existingID] or bans[id]
    local removedOldID
    if existingID and existingID ~= id then
        bans[existingID] = nil
        updated[existingID] = now
        removedOldID = existingID
    end

    local actor = UnitName and UnitName("player") or ""

    bans[id] = {
        id = id,
        active = true,
        name = name,
        guid = guid or (previous and previous.guid),
        class = (player and player.class) or (previous and previous.class),
        rankName = (player and player.rankName) or (previous and previous.rankName),
        rankIndex = (player and player.rankIndex) or (previous and previous.rankIndex),
        reason = trim(reason),
        bannedAt = parsedDate or (previous and previous.bannedAt) or now,
        bannedBy = actor,
        source = previous and previous.source or "manual",
    }
    updated[id] = now

    local EventLog = GP:GetModule("EventLog")
    EventLog:Add(guildKey, previous and previous.active and "banedited" or "banadded", bans[id].guid, bans[id].name, {
        banID = id,
        reason = bans[id].reason,
        bannedAt = bans[id].bannedAt,
        bannedBy = actor,
    })

    if removedOldID then
        GP:SendMessage("GuildParagon_BanListChanged", guildKey, removedOldID, nil, now)
    end
    GP:SendMessage("GuildParagon_BanListChanged", guildKey, id, bans[id], now)
    return true, nil, id
end

function BanList:Remove(guildKey, id)
    if not self:CanUse() then return false, GP.L["Officer access is required."] end

    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return false, GP.L["No roster data yet — try /gp scan."] end
    seedGRMBans(guildData)

    local bans, updated = ensureTables(guildData)
    local record = bans[id]
    if not record or not record.active then return false, GP.L["Ban record not found."] end

    local now = time()
    record.active = false
    record.removedAt = now
    record.removedBy = UnitName and UnitName("player") or ""
    updated[id] = now

    GP:GetModule("EventLog"):Add(guildKey, "banremoved", record.guid, record.name, {
        banID = id,
        removedBy = record.removedBy,
    })

    GP:SendMessage("GuildParagon_BanListChanged", guildKey, id, record, now)
    return true
end

function BanList:GetTotalStoredCount(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return 0 end
    local bans = ensureTables(guildData)
    return countTable(bans)
end

function BanList:GetUpdatedAt(guildKey, id)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id then return nil end
    local _, updated = ensureTables(guildData)
    return updated[id]
end

function BanList:GetAllForSync(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return {}, {} end
    seedGRMBans(guildData)
    local bans, updated = ensureTables(guildData)
    local out = {}
    for id, record in pairs(bans or {}) do
        out[id] = copyRecord(record)
    end
    return out, updated
end

function BanList:SetFromSync(guildKey, id, record, ts, logEvent)
    if not self:CanUse() then return false, GP.L["Officer access is required."] end
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData or not id or type(ts) ~= "number" then return false end

    local bans, updated = ensureTables(guildData)
    local previous = bans[id]
    if type(record) == "table" then
        local copy = copyRecord(record)
        copy.id = copy.id or id
        bans[id] = copy
    else
        bans[id] = nil
    end
    updated[id] = ts

    if logEvent == nil then logEvent = true end
    if logEvent then
        local newRecord = bans[id]
        local wasActive = previous and previous.active
        local isActive = newRecord and newRecord.active
        local EventLog = GP:GetModule("EventLog")
        if isActive and not wasActive then
            EventLog:Add(guildKey, "banadded", newRecord.guid, newRecord.name, {
                banID = id,
                reason = newRecord.reason,
                bannedAt = newRecord.bannedAt,
                bannedBy = newRecord.bannedBy,
            })
        elseif isActive and wasActive then
            EventLog:Add(guildKey, "banedited", newRecord.guid, newRecord.name, {
                banID = id,
                reason = newRecord.reason,
                bannedAt = newRecord.bannedAt,
                bannedBy = newRecord.bannedBy,
            })
        elseif wasActive and not isActive then
            EventLog:Add(guildKey, "banremoved", previous.guid, previous.name, {
                banID = id,
                removedBy = (newRecord and newRecord.removedBy) or previous.removedBy,
            })
        end
    end

    GP:SendMessage("GuildParagon_BanListChanged", guildKey, id, bans[id], ts)
    return true
end
