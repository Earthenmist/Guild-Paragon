-- Guild Paragon — Nicknames
-- One nickname per character. The 20-character limit is a practical UI
local _, GP = ...

local Nicknames = GP:NewModule("Nicknames")

local NICKNAME_MAX_CHARS = 20

local function getGuildData(guildKey)
    local data = guildKey and GP.db.global.guilds[guildKey]
    if not data then return nil end
    if not data.nicknames then
        data.nicknames = {} -- self-heals SavedVariables saved before this module existed
    end
    if not data.nicknamesUpdated then
        data.nicknamesUpdated = {}
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

function Nicknames:Get(guildKey, guid)
    local data = getGuildData(guildKey)
    return (data and data.nicknames[guid]) or ""
end

function Nicknames:Set(guildKey, guid, nickname, ts)
    local L = GP.L
    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end

    local player = data.roster[guid] or data.formerMembers[guid]
    if not player then return false, L["Player not found."] end
    if not ts and not GP:CanEditMemberProfile(guid) then
        return false, L["You can only edit nicknames or birthdays for your own linked characters."]
    end

    nickname = strtrim(nickname or "")
    if #nickname > NICKNAME_MAX_CHARS then
        return false, string.format(L["Nicknames must be %d characters or fewer."], NICKNAME_MAX_CHARS)
    end

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
