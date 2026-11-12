--
-- Post-kick follow-up workflow. After a locally initiated Blizzard roster kick
-- is confirmed by the next roster scan, the officer can decide whether the
-- kicked character and their linked characters should be banned and/or removed
-- too. Ordinary leaves and remote/synced departures cannot trigger it.
local _, GP = ...

local PostKick = GP:NewModule("PostKick")

local ATTEMPT_TTL = 180
local MACRO_CHAT_SUPPRESS_SECONDS = 12
local pendingByGuild = {}
local macroChatSuppressUntil = 0
local macroChatSuppressNames = {}

local function now()
    return time()
end

local function currentGuild()
    local Roster = GP:GetModule("Roster", true)
    if not Roster then return nil, nil end
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey, guildKey and GP.db.global.guilds[guildKey]
end

local function playerName(player)
    return player and player.name or nil
end

local function actorName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and name ~= "" then
            realm = realm and realm ~= "" and realm or (GetNormalizedRealmName and GetNormalizedRealmName() or nil)
            return realm and realm ~= "" and (name .. "-" .. realm) or name
        end
    end
    return UnitName and UnitName("player") or GP.L["Unknown"]
end

local function normalize(name)
    local Roster = GP:GetModule("Roster", true)
    if Roster and Roster.NormalizePlayerName then
        return Roster:NormalizePlayerName(name)
    end
    return tostring(name or ""):lower()
end

local function shortName(name)
    return tostring(name or ""):match("^([^-]+)") or tostring(name or "")
end

local function stripChatCodes(message)
    message = GP:SafeOptionalString(message)
    if not message then return nil end
    local ok, stripped = pcall(function()
        return message:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    end)
    return ok and stripped or nil
end

local function macroChatSuppressionEnabled()
    local MacroTool = GP:GetModule("MacroTool", true)
    if not MacroTool then return false end
    if MacroTool.IsChatSuppressionActive then
        return MacroTool:IsChatSuppressionActive()
    end
    return MacroTool.IsChatSuppressionEnabled and MacroTool:IsChatSuppressionEnabled()
end

function PostKick:ShouldSuppressMacroSystemMessage(message)
    if not macroChatSuppressionEnabled() then return false end
    local current = now()
    if current > (macroChatSuppressUntil or 0) then return false end

    local text = stripChatCodes(message)
    if not text then return false end
    text = text:lower()
    if text:find("number of messages", 1, true) and text:find("limited", 1, true) then
        return true
    end
    if not text:find("kicked out of the guild", 1, true) then return false end

    for nameKey, expires in pairs(macroChatSuppressNames) do
        if expires < current then
            macroChatSuppressNames[nameKey] = nil
        elseif text:find(nameKey, 1, true) then
            return true
        end
    end
    return false
end

local function sameCharacter(a, b)
    if not a or not b then return false end
    return normalize(a) == normalize(b)
end

local function getMyRankIndex(guildData)
    -- The previous realm fallback (GetNormalizedRealmName()) wasn't itself nil-guarded, so this could
    -- concatenate nil during the pre-resolve window right after login.
    local mine = GP:LocalPlayerFullName()
    if not mine then return nil end
    for _, player in pairs(guildData and guildData.roster or {}) do
        if sameCharacter(player.name, mine) then
            return player.rankIndex
        end
    end
    return nil
end

local function canKickLinked(guildData, player)
    if not player then return false end
    if CanGuildRemove and not GP:SafeBool(GP:SafeCall(CanGuildRemove, false), false) then
        return false
    end
    local myRankIndex = getMyRankIndex(guildData)
    if not myRankIndex or not player.rankIndex then return false end
    return player.rankIndex > myRankIndex
end

local function findPlayer(guildData, nameOrGUID)
    if not guildData or not nameOrGUID then return nil, nil end
    local key = tostring(nameOrGUID)
    local player = (guildData.roster or {})[key] or (guildData.formerMembers or {})[key]
    if player then return key, player end

    local Roster = GP:GetModule("Roster", true)
    if Roster and Roster.FindPlayerByName then
        local guid, found = Roster:FindPlayerByName(guildData, key, true)
        if guid and found then return guid, found end
    end
    return nil, nil
end

local function linkedGroup(guildKey, guildData, guid)
    local Alts = GP:GetModule("Alts", true)
    if not Alts or not guildKey or not guildData or not guid then return {} end

    local mainGUID = Alts:GetMain(guildKey, guid) or guid
    local group = { mainGUID }
    for _, altGUID in ipairs(Alts:GetAlts(guildKey, mainGUID) or {}) do
        table.insert(group, altGUID)
    end

    local linked = {}
    for _, memberGUID in ipairs(group) do
        if memberGUID ~= guid then
            local member = (guildData.roster or {})[memberGUID]
            if member then
                table.insert(linked, {
                    guid = memberGUID,
                    name = member.name,
                    player = member,
                    kickable = canKickLinked(guildData, member),
                })
            end
        end
    end
    table.sort(linked, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return linked
end

local function prune(guildKey)
    local bucket = pendingByGuild[guildKey]
    if not bucket then return end
    local cutoff = now() - ATTEMPT_TTL
    for key, attempt in pairs(bucket) do
        if not attempt.ts or attempt.ts < cutoff then
            bucket[key] = nil
        end
    end
end

local function storeAttempt(guildKey, key, attempt)
    pendingByGuild[guildKey] = pendingByGuild[guildKey] or {}
    pendingByGuild[guildKey][key] = attempt
end

function PostKick:RecordMacroKickAttempt(guildKey, guid, player)
    if not GP:IsOfficer() or not guildKey or not player then return end
    prune(guildKey)

    local name = playerName(player)
    if not name or name == "" then return end

    local attempt = {
        source = "macro",
        ts = now(),
        guildKey = guildKey,
        guid = guid,
        name = name,
        player = player,
        actor = actorName(),
    }
    if guid then storeAttempt(guildKey, guid, attempt) end
    storeAttempt(guildKey, "name:" .. normalize(name), attempt)

    macroChatSuppressUntil = math.max(macroChatSuppressUntil or 0, now() + MACRO_CHAT_SUPPRESS_SECONDS)
    macroChatSuppressNames[normalize(name)] = macroChatSuppressUntil
    macroChatSuppressNames[normalize(shortName(name))] = macroChatSuppressUntil
end

local function recordBlizzardKick(nameOrGUID)
    if not GP:IsOfficer() then return end

    local guildKey, guildData = currentGuild()
    if not guildKey or not guildData then return end
    prune(guildKey)

    local guid, player = findPlayer(guildData, nameOrGUID)
    local name = playerName(player) or tostring(nameOrGUID or "")
    if name == "" then return end
    local existing = (guid and pendingByGuild[guildKey] and pendingByGuild[guildKey][guid])
        or (pendingByGuild[guildKey] and pendingByGuild[guildKey]["name:" .. normalize(name)])
    if existing and existing.source == "macro" and existing.ts and (now() - existing.ts) <= ATTEMPT_TTL then
        return
    end

    local attempt = {
        source = "blizzard",
        ts = now(),
        guildKey = guildKey,
        guid = guid,
        name = name,
        player = player,
        actor = actorName(),
    }
    if guid then storeAttempt(guildKey, guid, attempt) end
    storeAttempt(guildKey, "name:" .. normalize(name), attempt)

    local Roster = GP:GetModule("Roster", true)
    if Roster and Roster.RequestScan then
        Roster:RequestScan(0.75)
        if C_Timer and C_Timer.After then
            C_Timer.After(2, function()
                local currentKey = select(1, currentGuild())
                if currentKey == guildKey then Roster:RequestScan(0.1) end
            end)
        end
    end
end

function PostKick:OnEnable()
    if C_GuildInfo and C_GuildInfo.Uninvite then
        hooksecurefunc(C_GuildInfo, "Uninvite", recordBlizzardKick)
    end
    if C_GuildInfo and C_GuildInfo.RemoveFromGuild then
        hooksecurefunc(C_GuildInfo, "RemoveFromGuild", recordBlizzardKick)
    end
end

function PostKick:OnRosterDeparture(guildKey, guid, player)
    if not GP:IsOfficer() or not guildKey or not player then return end
    prune(guildKey)

    local bucket = pendingByGuild[guildKey]
    if not bucket then return end
    local attempt = (guid and bucket[guid]) or bucket["name:" .. normalize(player.name)]
    if not attempt or (attempt.source ~= "blizzard" and attempt.source ~= "macro") then return end

    if attempt.guid then bucket[attempt.guid] = nil end
    if attempt.name then bucket["name:" .. normalize(attempt.name)] = nil end

    local EventLog = GP:GetModule("EventLog", true)
    if EventLog and EventLog.Add then
        EventLog:Add(guildKey, "removed", guid or attempt.guid, player.name or attempt.name, {
            actor = attempt.actor or actorName(),
            source = attempt.source,
            suppressChat = attempt.source == "macro",
        })
    end

    if attempt.source == "macro" then
        return true
    end

    local guildData = GP.db.global.guilds[guildKey]
    local context = {
        guildKey = guildKey,
        guid = guid or attempt.guid,
        name = player.name or attempt.name,
        player = player,
        linked = linkedGroup(guildKey, guildData, guid or attempt.guid),
    }

    if GP.UI.PostKickPrompt and GP.UI.PostKickPrompt.Show then
        GP.UI.PostKickPrompt:Show(context)
    end
    return true
end

function PostKick:AddBans(context, reason, includeLinked)
    if not context or not context.guildKey then return false, GP.L["Player not found."] end
    local BanList = GP:GetModule("BanList", true)
    if not BanList or not BanList.CanUse or not BanList:CanUse() then
        return false, GP.L["Officer access is required."]
    end

    local dateText = date("%Y-%m-%d")
    local count = 0
    local ok, err = BanList:AddOrUpdate(context.guildKey, context.name, reason or "", dateText)
    if not ok then return false, err end
    count = count + 1

    if includeLinked then
        for _, linked in ipairs(context.linked or {}) do
            ok, err = BanList:AddOrUpdate(context.guildKey, linked.name, reason or "", dateText)
            if ok then
                count = count + 1
            end
        end
    end
    return true, nil, count
end

function PostKick:BuildLinkedKickMacro(context)
    local MacroTool = GP:GetModule("MacroTool", true)
    if not MacroTool or not MacroTool.BuildExecutionBatch then
        return false, GP.L["Macro Tool is not available."]
    end
    if InCombatLockdown and InCombatLockdown() then
        return false, GP.L["Cannot build the macro while in combat."]
    end

    local rows = {}
    for _, linked in ipairs(context and context.linked or {}) do
        if linked.kickable and linked.player then
            table.insert(rows, {
                guid = linked.guid,
                player = linked.player,
                action = "kick",
                include = true,
                reasons = { GP.L["Queued by post-kick linked-character cleanup."] },
            })
        end
    end
    if #rows == 0 then return false, GP.L["No linked characters can be removed by this character."] end

    if GP.UI.MacroToolTab then
        GP.UI.MacroToolTab.preserveOnNextSelect = true
    end
    if GP.UI.MainWindow and GP.UI.MainWindow.SelectTabByID then
        GP.UI.MainWindow:SelectTabByID("macro")
    end

    local ok, err = MacroTool:BuildExecutionBatch(rows)
    return ok, err, #rows
end
