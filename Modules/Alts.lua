-- Alt/main relationships with per-record timestamps for sync conflict resolution.
local _, GP = ...

local Alts = GP:NewModule("Alts")

local MAIN_FLAG_SOURCE_AUTO = "auto"
local MAIN_FLAG_SOURCE_LEGACY = "legacy"
local MAIN_FLAG_SOURCE_MANUAL = "manual"

local function normalizeMainFlagSource(source, localEdit)
    if source == MAIN_FLAG_SOURCE_AUTO or source == MAIN_FLAG_SOURCE_MANUAL then
        return source
    end
    return localEdit and MAIN_FLAG_SOURCE_MANUAL or MAIN_FLAG_SOURCE_LEGACY
end

local function getGuildData(guildKey)
    local data = guildKey and GP.db.global.guilds[guildKey]
    if not data then return nil end
    if not data.alts then
        data.alts = {} -- self-heals SavedVariables saved before this module existed
    end
    if not data.mains then
        data.mains = {}
    end
    if not data.altsUpdated then
        data.altsUpdated = {}
    end
    if not data.altsCleared then
        data.altsCleared = {}
    end
    if not data.mainsUpdated then
        data.mainsUpdated = {}
    end
    if not data.mainsCleared then
        data.mainsCleared = {}
    end
    if not data.mainsSource then
        data.mainsSource = {}
    end
    -- Timestamp-less legacy records are treated as older than any synced edit.
    for guid in pairs(data.alts) do
        if not data.altsUpdated[guid] then
            data.altsUpdated[guid] = 0
        end
    end
    for guid in pairs(data.mains) do
        if not data.mainsUpdated[guid] then
            data.mainsUpdated[guid] = 0
        end
    end
    return data
end

function Alts:GetMain(guildKey, altGUID)
    local data = getGuildData(guildKey)
    return data and data.alts[altGUID]
end

function Alts:GetAlts(guildKey, mainGUID)
    local data = getGuildData(guildKey)
    local out = {}
    if not data then return out end
    for altGUID, linkedMain in pairs(data.alts) do
        if linkedMain == mainGUID then
            table.insert(out, altGUID)
        end
    end
    return out
end

local function findPlayer(guildData, guid)
    return guildData.roster[guid] or guildData.formerMembers[guid]
end

function Alts:IsMarkedMain(guildKey, guid)
    local data = getGuildData(guildKey)
    return (data and data.mains[guid]) and true or false
end

function Alts:IsMain(guildKey, guid)
    if self:IsMarkedMain(guildKey, guid) then return true end
    return #self:GetAlts(guildKey, guid) > 0
end

function Alts:SetAsMain(guildKey, guid, ts, source, quiet)
    local L = GP.L
    local localEdit = ts == nil
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end

    local player = findPlayer(data, guid)
    if not player then return false, L["Player not found."] end
    if not ts and not GP:IsOfficer() then return false, L["Guild data changes require officer access."] end

    source = normalizeMainFlagSource(source, localEdit)
    if data.alts[guid] then
        local taggedAt = self:GetAltUpdatedAt(guildKey, guid)
        if source ~= MAIN_FLAG_SOURCE_MANUAL and ts then
            data.mains[guid] = nil
            data.mainsUpdated[guid] = ts
            data.mainsCleared[guid] = true
            data.mainsSource[guid] = nil
            return true
        end
        if not ts or (taggedAt and taggedAt >= ts) then
            return false, L["This character is already tagged as someone else's alt — clear that first."]
        end
        self:ClearMain(guildKey, guid, ts, quiet)
    end

    ts = ts or time()
    local wasSet = data.mains[guid]
    local existingSource = self:GetMainFlagSource(guildKey, guid)
    if wasSet and existingSource == MAIN_FLAG_SOURCE_MANUAL and source ~= MAIN_FLAG_SOURCE_MANUAL then
        source = existingSource
    end
    -- Always stamp freshness; only log/broadcast when the value changes.
    data.mains[guid] = true
    data.mainsUpdated[guid] = ts
    data.mainsCleared[guid] = nil
    data.mainsSource[guid] = source

    if not wasSet then
        if not quiet then
            GP:GetModule("EventLog"):Add(guildKey, "markedmain", guid, player.name, {})
        end
        GP:SendMessage("GuildParagon_AltsChanged", guildKey, "mainset", guid, nil, ts, source)
    end
    return true
end

function Alts:UnsetAsMain(guildKey, guid, ts, quiet)
    local L = GP.L
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    if not ts and not GP:IsOfficer() then return false, L["Guild data changes require officer access."] end

    ts = ts or time()
    local wasSet = data.mains[guid]
    -- Always stamp freshness; only log/broadcast when the value changes.
    data.mains[guid] = nil
    data.mainsUpdated[guid] = ts
    data.mainsCleared[guid] = true
    data.mainsSource[guid] = nil

    if wasSet then
        local player = findPlayer(data, guid)
        if player and not quiet then
            GP:GetModule("EventLog"):Add(guildKey, "unmarkedmain", guid, player.name, {})
        end
        GP:SendMessage("GuildParagon_AltsChanged", guildKey, "mainclear", guid, nil, ts)
    end
    return true
end

function Alts:SetMain(guildKey, altGUID, mainGUID, ts, quiet)
    local L = GP.L
    local localEdit = ts == nil
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    if not ts and not GP:IsOfficer() then return false, L["Guild data changes require officer access."] end

    if altGUID == mainGUID then
        return false, L["A character can't be tagged as their own alt."]
    end

    local altPlayer = findPlayer(data, altGUID)
    local mainPlayer = findPlayer(data, mainGUID)
    if not altPlayer or not mainPlayer then
        return false, L["Player not found."]
    end

    if data.alts[mainGUID] then
        return false, L["That character is already tagged as someone else's alt — untag them first."]
    end
    if #self:GetAlts(guildKey, altGUID) > 0 then
        return false, L["That character already has alts tagged to them — untag those first."]
    end
    if self:IsMarkedMain(guildKey, altGUID) then
        local markedAt = self:GetMainFlagUpdatedAt(guildKey, altGUID)
        local source = self:GetMainFlagSource(guildKey, altGUID)
        if not ts or (source == MAIN_FLAG_SOURCE_MANUAL and markedAt and markedAt >= ts) then
            return false, L["That character is marked as a main — unmark it first."]
        end
        self:UnsetAsMain(guildKey, altGUID, ts, quiet)
    end

    ts = ts or time()
    local oldMain = data.alts[altGUID]
    -- Always stamp freshness; only log/broadcast when the value changes.
    data.alts[altGUID] = mainGUID
    data.altsUpdated[altGUID] = ts
    data.altsCleared[altGUID] = nil

    if oldMain ~= mainGUID then
        if not quiet then
            GP:GetModule("EventLog"):Add(guildKey, "altlinked", altGUID, altPlayer.name, { mainName = mainPlayer.name })
        end
        GP:SendMessage("GuildParagon_AltsChanged", guildKey, "set", altGUID, mainGUID, ts)
        if localEdit then
            GP:SendMessage("GuildParagon_AltIdentityCommitted", guildKey, "link", altGUID, mainGUID, oldMain, ts)
        end
    end
    return true
end

function Alts:ClearMain(guildKey, altGUID, ts, quiet)
    local L = GP.L
    local localEdit = ts == nil
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    if not ts and not GP:IsOfficer() then return false, L["Guild data changes require officer access."] end

    ts = ts or time()
    local mainGUID = data.alts[altGUID]
    data.alts[altGUID] = nil
    data.altsUpdated[altGUID] = ts
    data.altsCleared[altGUID] = true

    if mainGUID then
        local altPlayer = findPlayer(data, altGUID)
        local mainPlayer = findPlayer(data, mainGUID)
        if altPlayer and not quiet then
            GP:GetModule("EventLog"):Add(guildKey, "altcleared", altGUID, altPlayer.name,
                { mainName = mainPlayer and mainPlayer.name or "?" })
        end
        GP:SendMessage("GuildParagon_AltsChanged", guildKey, "clear", altGUID, nil, ts)
        if localEdit then
            GP:SendMessage("GuildParagon_AltIdentityCommitted", guildKey, "unlink", altGUID, mainGUID, nil, ts)
        end
    end
    return true
end

function Alts:PromoteToMain(guildKey, newMainGUID, ts)
    local L = GP.L
    local localEdit = ts == nil
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    if not ts and not GP:IsOfficer() then return false, L["Guild data changes require officer access."] end

    local newMainPlayer = findPlayer(data, newMainGUID)
    if not newMainPlayer then return false, L["Player not found."] end

    local oldMainGUID = data.alts[newMainGUID]
    if not oldMainGUID then
        return false, L["This character isn't tagged as an alt — nothing to promote."]
    end

    local oldMainPlayer = findPlayer(data, oldMainGUID)
    ts = ts or time()
    local EventLog = GP:GetModule("EventLog")

    -- Repoint siblings before swapping the old and new main records.
    for _, siblingGUID in ipairs(self:GetAlts(guildKey, oldMainGUID)) do
        if siblingGUID ~= newMainGUID then
            data.alts[siblingGUID] = newMainGUID
            data.altsUpdated[siblingGUID] = ts
            data.altsCleared[siblingGUID] = nil
            local siblingPlayer = findPlayer(data, siblingGUID)
            if siblingPlayer then
                EventLog:Add(guildKey, "altlinked", siblingGUID, siblingPlayer.name, { mainName = newMainPlayer.name })
            end
            GP:SendMessage("GuildParagon_AltsChanged", guildKey, "set", siblingGUID, newMainGUID, ts)
        end
    end

    -- Unlink the new main from its old main...
    data.alts[newMainGUID] = nil
    data.altsUpdated[newMainGUID] = ts
    data.altsCleared[newMainGUID] = true
    EventLog:Add(guildKey, "altcleared", newMainGUID, newMainPlayer.name,
        { mainName = oldMainPlayer and oldMainPlayer.name or "?" })
    GP:SendMessage("GuildParagon_AltsChanged", guildKey, "clear", newMainGUID, nil, ts)

    -- ...then fold the old main in as the new main's alt.
    data.alts[oldMainGUID] = newMainGUID
    data.altsUpdated[oldMainGUID] = ts
    data.altsCleared[oldMainGUID] = nil
    if oldMainPlayer then
        EventLog:Add(guildKey, "altlinked", oldMainGUID, oldMainPlayer.name, { mainName = newMainPlayer.name })
    end
    GP:SendMessage("GuildParagon_AltsChanged", guildKey, "set", oldMainGUID, newMainGUID, ts)

    -- Flip explicit main flags after the pointer swap.
    data.mains[newMainGUID] = true
    data.mainsUpdated[newMainGUID] = ts
    data.mainsCleared[newMainGUID] = nil
    data.mainsSource[newMainGUID] = MAIN_FLAG_SOURCE_MANUAL
    EventLog:Add(guildKey, "markedmain", newMainGUID, newMainPlayer.name, {})
    GP:SendMessage("GuildParagon_AltsChanged", guildKey, "mainset", newMainGUID, nil, ts, MAIN_FLAG_SOURCE_MANUAL)

    if data.mains[oldMainGUID] then
        data.mains[oldMainGUID] = nil
        data.mainsUpdated[oldMainGUID] = ts
        data.mainsCleared[oldMainGUID] = true
        data.mainsSource[oldMainGUID] = nil
        if oldMainPlayer then
            EventLog:Add(guildKey, "unmarkedmain", oldMainGUID, oldMainPlayer.name, {})
        end
        GP:SendMessage("GuildParagon_AltsChanged", guildKey, "mainclear", oldMainGUID, nil, ts)
    end

    -- One atomic identity notification follows the lower-level sync events so
    -- person-keyed consumers never react to the promotion's intermediate graph.
    if localEdit then
        GP:SendMessage("GuildParagon_AltIdentityCommitted", guildKey, "promote",
            newMainGUID, oldMainGUID, nil, ts)
    end

    return true
end

function Alts:GetAltUpdatedAt(guildKey, altGUID)
    local data = getGuildData(guildKey)
    return data and data.altsUpdated[altGUID]
end

function Alts:GetMainFlagUpdatedAt(guildKey, guid)
    local data = getGuildData(guildKey)
    return data and data.mainsUpdated[guid]
end

function Alts:GetMainFlagSource(guildKey, guid)
    local data = getGuildData(guildKey)
    return data and normalizeMainFlagSource(data.mainsSource[guid], false)
end

function Alts:GetAllForSync(guildKey)
    local data = getGuildData(guildKey)
    if not data then return {}, {}, {}, {}, {}, {}, {} end
    return data.alts, data.altsUpdated, data.mains, data.mainsUpdated, data.mainsSource, data.altsCleared, data.mainsCleared
end
