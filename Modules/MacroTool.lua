-- Guild Paragon — Macro Tool decision engine
--
-- Collects candidates, explains every include/exclude decision, gates by
-- guild permissions/rank, and only builds a visible WoW macro on explicit
-- officer request.
local _, GP = ...

local MacroTool = GP:NewModule("MacroTool")

local ACTIONS = {
    kick = { permission = "remove", label = "Kick" },
    promote = { permission = "promote", label = "Promote" },
    demote = { permission = "demote", label = "Demote" },
    special = { permission = "promote", label = "Special" },
}

local EXECUTION_MACRO_NAME = "Paragon_Tool"
local EXECUTION_MACRO_ICON = "Interface\\AddOns\\GuildParagon\\Media\\GuildParagonIcon"
local FALLBACK_MACRO_ICON = "INV_MISC_QUESTIONMARK"
local EMPTY_EXECUTION_MACRO = "/run print(\"GuildParagon macro is empty.\")"
local MACRO_TEXT_LIMIT = 255
local EXECUTION_CALLBACK = "GuildParagon_MacroToolBatchDone"
local DEFAULT_EXECUTION_HOTKEY = "ALT-P"
local MAX_KICK_COMMANDS_PER_BATCH = 4
-- Saved rules are analyzed on demand only; no background rule audit runs
-- after roster scans.
local macroSystemFilterInstalled = false
local macroSuppressionWatcher
local pendingExecutionHotKeyRebind = 0
local pendingExecutionRankValidation = 0

local function safeCall(fn, fallback)
    return GP:SafeCall(fn, fallback)
end

local function countTable(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function copyArray(t)
    local out = {}
    for i, v in ipairs(t or {}) do
        if type(v) == "table" then
            local copy = {}
            for key, value in pairs(v) do
                copy[key] = value
            end
            out[i] = copy
        else
            out[i] = v
        end
    end
    return out
end

local function requestRosterRefresh(delay)
    local Roster = GP:GetModule("Roster", true)
    if not Roster then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        GP:SafeCall(C_GuildInfo.GuildRoster, nil)
    elseif GuildRoster then
        GP:SafeCall(GuildRoster, nil)
    end
    if Roster.RequestScan then
        Roster:RequestScan(delay or 0.75)
    end
end

local function canDo(action)
    if action == "kick" then return safeCall(CanGuildRemove, false) and true or false end
    if action == "promote" then return safeCall(CanGuildPromote, false) and true or false end
    if action == "demote" then return safeCall(CanGuildDemote, false) and true or false end
    return false
end

local function canUseMacroTool()
    local CustomNotes = GP:GetModule("CustomNotes")
    return CustomNotes:CanAccessOfficerNotes()
end

local function getPlayerFullName()
    -- The previous realm fallback (GetNormalizedRealmName()) wasn't itself nil-guarded, so this could
    -- concatenate nil during the pre-resolve window right after login.
    -- GP:LocalPlayerFullName() is the shared, already-guarded equivalent.
    return GP:LocalPlayerFullName()
end

local function shortName(name)
    return name and name:match("^([^-]+)") or name
end

local function sameCharacter(a, b)
    if not a or not b then return false end
    return a == b or shortName(a) == shortName(b)
end

local function getMyRankIndex(guildData)
    local mine = getPlayerFullName()
    if not mine then return nil end
    for _, player in pairs(guildData.roster or {}) do
        if sameCharacter(player.name, mine) then
            return player.rankIndex
        end
    end
    return nil
end

local function offlineDays(player)
    if player.online then return 0 end
    if type(player.lastOnline) == "number" then
        return math.floor(player.lastOnline / 24)
    end

    local t = player.lastOnlineTime
    if type(t) ~= "table" then return nil end
    local hours = (tonumber(t[1]) or 0) * 8760 + (tonumber(t[2]) or 0) * 730 + (tonumber(t[3]) or 0) * 24 + (tonumber(t[4]) or 0)
    return math.floor(hours / 24)
end

local function rankDays(player, now)
    local hist = player and player.rankHistory
    if type(hist) ~= "table" then return nil end

    local latest
    for i = #hist, 1, -1 do
        local entry = hist[i]
        if type(entry) == "table" and type(entry.ts) == "number" and entry.ts > 0 then
            if player.rankIndex == nil or entry.rankIndex == nil or entry.rankIndex == player.rankIndex then
                latest = entry.ts
                break
            end
        end
    end
    if not latest then return nil end

    return math.max(0, math.floor(((now or time()) - latest) / 86400))
end

local function rankName(rankIndex)
    if rankIndex == nil then return nil end
    if GuildControlGetRankName then
        local ok, name = pcall(GuildControlGetRankName, rankIndex + 1)
        if ok and name and name ~= "" then return name end
    end
    return string.format(GP.L["Rank %d"], rankIndex)
end

local function rankExists(guildData, rankIndex)
    if rankIndex == nil then return false end
    if GuildControlGetNumRanks then
        local ok, count = pcall(GuildControlGetNumRanks)
        if ok and tonumber(count) then
            return rankIndex >= 0 and rankIndex < tonumber(count)
        end
    end
    for _, player in pairs(guildData.roster or {}) do
        if player.rankIndex == rankIndex then return true end
    end
    return false
end

local function contains(haystack, needle)
    if needle == "" then return false end
    return (haystack or ""):lower():find(needle, 1, true) and true or false
end

local function noteBlob(guildKey, guid, player)
    local CustomNotes = GP:GetModule("CustomNotes")
    local Nicknames = GP:GetModule("Nicknames")
    local canViewOfficer = CustomNotes:CanAccessOfficerNotes()
    return table.concat({
        player.name or "",
        player.note or "",
        canViewOfficer and player.officerNote or "",
        CustomNotes:Get(guildKey, guid) or "",
        canViewOfficer and CustomNotes:GetOfficer(guildKey, guid) or "",
        Nicknames:Get(guildKey, guid) or "",
    }, "\n")
end

local function publicNoteBlob(guildKey, guid, player)
    local CustomNotes = GP:GetModule("CustomNotes")
    local Nicknames = GP:GetModule("Nicknames")
    return table.concat({
        player.name or "",
        player.note or "",
        CustomNotes:Get(guildKey, guid) or "",
        Nicknames:Get(guildKey, guid) or "",
    }, "\n")
end

local function publicNotesEmpty(guildKey, guid, player)
    return strtrim(table.concat({
        player.note or "",
        GP:GetModule("CustomNotes"):Get(guildKey, guid) or "",
        GP:GetModule("Nicknames"):Get(guildKey, guid) or "",
    }, "")) == ""
end

local function isAlt(guildKey, guid)
    return GP:GetModule("Alts"):GetMain(guildKey, guid) ~= nil
end

local function isMain(guildKey, guid)
    return GP:GetModule("Alts"):IsMain(guildKey, guid)
end

local function buildAltGroupCache(guildKey, guildData)
    local Alts = GP:GetModule("Alts")
    local alts, _, mains = Alts:GetAllForSync(guildKey)
    local groupByGUID = {}
    local groupByMain = {}

    local function add(mainGUID, memberGUID)
        if not mainGUID or not memberGUID or not guildData.roster[memberGUID] then return end
        local group = groupByMain[mainGUID]
        if not group then
            group = { seen = {} }
            groupByMain[mainGUID] = group
        end
        if not group.seen[memberGUID] then
            group.seen[memberGUID] = true
            table.insert(group, memberGUID)
        end
    end

    for mainGUID in pairs(mains or {}) do
        add(mainGUID, mainGUID)
    end
    for altGUID, mainGUID in pairs(alts or {}) do
        add(mainGUID, mainGUID)
        add(mainGUID, altGUID)
    end

    for _, group in pairs(groupByMain) do
        group.seen = nil
        if #group > 1 then
            for _, memberGUID in ipairs(group) do
                groupByGUID[memberGUID] = group
            end
        end
    end

    return groupByGUID
end

local function linkedRecentActivity(guildData, groupByGUID, guid, minOfflineDays)
    local group = groupByGUID[guid]
    if not group then return nil end

    for _, linkedGUID in ipairs(group) do
        if linkedGUID ~= guid then
            local linked = guildData.roster[linkedGUID]
            if linked then
                if linked.online then
                    return linked, "online"
                end

                local days = offlineDays(linked)
                if minOfflineDays > 0 and days == nil then
                    return linked, "unknown"
                end
                if minOfflineDays > 0 and days < minOfflineDays then
                    return linked, days
                end
            end
        end
    end
    return nil
end

local function newResult(guid, player)
    return {
        guid = guid,
        player = player,
        include = true,
        reasons = {},
    }
end

local function reject(result, reason)
    result.include = false
    table.insert(result.reasons, reason)
end

local function accept(result, reason)
    table.insert(result.reasons, reason)
end

local function getLinkedGUIDs(guildData, guid)
    if not guildData or not guid then return {} end

    local mainGUID = (guildData.alts or {})[guid] or guid
    local seen, out = {}, {}
    local function add(memberGUID)
        if memberGUID and not seen[memberGUID] then
            seen[memberGUID] = true
            table.insert(out, memberGUID)
        end
    end

    add(mainGUID)
    for altGUID, linkedMain in pairs(guildData.alts or {}) do
        if linkedMain == mainGUID then
            add(altGUID)
        end
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

local function setIgnoreRaw(guildData, guid, action, value, ts)
    local ignore = guildData.macroIgnores[guid]
    if type(ignore) ~= "table" then
        ignore = {}
        guildData.macroIgnores[guid] = ignore
    end

    local changed = (ignore[action] and true or false) ~= (value and true or false)
    ignore[action] = value and true or nil
    if not next(ignore) then
        guildData.macroIgnores[guid] = nil
    end
    guildData.macroIgnoresUpdated[guid] = ts
    return changed
end

local function backfillGRMMacroIgnores(guildData)
    if guildData.macroIgnoresImportedFromGRM then return end

    local now = time()
    local imported = 0
    for guid, player in pairs(guildData.roster or {}) do
        local safeList = player.grmSafeList
        for action in pairs(ACTIONS) do
            if grmSafeListIgnored(safeList, action, now) then
                for _, linkedGUID in ipairs(getLinkedGUIDs(guildData, guid)) do
                    if (guildData.roster or {})[linkedGUID] then
                        if setIgnoreRaw(guildData, linkedGUID, action, true, guildData.importedFromGRM or now) then
                            imported = imported + 1
                        end
                    end
                end
            end
        end
    end

    guildData.macroIgnoresImportedFromGRM = now
    guildData.macroIgnoresImportedCount = imported
end

local RULE_FIELDS = {
    "action", "minOfflineDays", "minRankDays", "maxOfflineDays", "includeOnline", "targetScope", "targetRankIndex", "allRanks",
    "selectedRanks", "levelMode", "minLevel", "maxLevel", "requireText",
    "requireTextEmptyOnly", "safeText", "safeTextAllNotes",
    "specialSameRank", "specialDisableDemote",
}

local function copyTable(t)
    local out = {}
    for k, v in pairs(t or {}) do
        out[k] = type(v) == "table" and copyTable(v) or v
    end
    return out
end

local function copyRule(rule, ts)
    local out = {}
    for _, key in ipairs(RULE_FIELDS) do
        if rule[key] ~= nil then
            out[key] = type(rule[key]) == "table" and copyTable(rule[key]) or rule[key]
        end
    end
    out.savedAt = tonumber(rule.savedAt) or ts
    return out
end

local function actionUsesTargetRank(action)
    return action == "promote" or action == "demote" or action == "special"
end

local function resetWorkingRule(settings)
    settings.action = nil
    settings.minOfflineDays = 0
    settings.minRankDays = 0
    settings.maxOfflineDays = 0
    settings.includeOnline = false
    settings.targetScope = "all"
    settings.targetRankIndex = nil
    settings.targetRanks = {}
    settings.specialSameRank = false
    settings.specialDisableDemote = false
    settings.allRanks = true
    settings.selectedRanks = {}
    settings.levelMode = "all"
    settings.minLevel = 1
    settings.maxLevel = 90
    settings.requireText = ""
    settings.requireTextEmptyOnly = false
    settings.safeText = ""
    settings.safeTextAllNotes = false
    settings.currentRuleName = nil
end

local function protectedContentActive()
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
    local inInstance, instanceType
    if IsInInstance then
        inInstance, instanceType = IsInInstance()
    end
    return inInstance and instanceType and instanceType ~= "none"
end

local function macroSystemMessageFilter(_, event, message, ...)
    if event ~= "CHAT_MSG_SYSTEM" then return false, message, ... end
    if not MacroTool:IsChatSuppressionActive() then
        MacroTool:RefreshChatSuppressionFilter()
        return false, message, ...
    end

    local PostKick = GP:GetModule("PostKick", true)
    if PostKick and PostKick.ShouldSuppressMacroSystemMessage and PostKick:ShouldSuppressMacroSystemMessage(message) then
        return true
    end
    return false, message, ...
end

function MacroTool:GetSettings()
    local profile = GP.db.profile
    profile.macroTool = profile.macroTool or {}
    local s = profile.macroTool
    if s.action ~= nil and not ACTIONS[s.action] then s.action = nil end
    s.minOfflineDays = tonumber(s.minOfflineDays) or 180
    s.minRankDays = tonumber(s.minRankDays) or 0
    s.maxOfflineDays = tonumber(s.maxOfflineDays) or 0
    if s.includeOnline == nil then s.includeOnline = false end
    if s.targetScope ~= "alts" and s.targetScope ~= "mains" then s.targetScope = "all" end
    if type(s.targetRanks) ~= "table" then s.targetRanks = {} end
    local legacyTargetRankIndex = tonumber(s.targetRankIndex)
    if legacyTargetRankIndex and actionUsesTargetRank(s.action) and s.targetRanks[s.action] == nil then
        s.targetRanks[s.action] = legacyTargetRankIndex
    end
    s.targetRankIndex = actionUsesTargetRank(s.action) and tonumber(s.targetRanks[s.action]) or nil
    s.specialSameRank = s.specialSameRank and true or false
    s.specialDisableDemote = s.specialDisableDemote and true or false
    if s.allRanks == nil then s.allRanks = true end
    if type(s.selectedRanks) ~= "table" then s.selectedRanks = {} end
    if type(s.savedRules) ~= "table" then s.savedRules = {} end
    if type(s.savedRulesUpdated) ~= "table" then s.savedRulesUpdated = {} end
    for name, rule in pairs(s.savedRules) do
        if not s.savedRulesUpdated[name] then
            s.savedRulesUpdated[name] = type(rule) == "table" and tonumber(rule.savedAt) or 0
        end
    end
    if s.levelMode ~= "max" and s.levelMode ~= "range" then s.levelMode = "all" end
    s.minLevel = tonumber(s.minLevel) or 1
    s.maxLevel = tonumber(s.maxLevel) or 90
    s.requireText = s.requireText or ""
    s.requireTextEmptyOnly = s.requireTextEmptyOnly and true or false
    s.safeText = s.safeText or ""
    s.safeTextAllNotes = s.safeTextAllNotes and true or false
    if s.suppressMacroChatSpam == nil then s.suppressMacroChatSpam = true end
    s.suppressMacroChatSpam = s.suppressMacroChatSpam and true or false
    s.macroHotKey = s.macroHotKey or DEFAULT_EXECUTION_HOTKEY
    return s
end

function MacroTool:IsChatSuppressionEnabled()
    return self:GetSettings().suppressMacroChatSpam and true or false
end

function MacroTool:IsChatSuppressionActive()
    return self.macroToolVisible and self:IsChatSuppressionEnabled() and self:CanUse() and not protectedContentActive()
end

function MacroTool:RefreshChatSuppressionFilter()
    if not ChatFrame_AddMessageEventFilter or not ChatFrame_RemoveMessageEventFilter then
        macroSystemFilterInstalled = false
        return
    end
    local shouldInstall = self:IsChatSuppressionActive()
    if shouldInstall and not macroSystemFilterInstalled then
        local ok = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", macroSystemMessageFilter)
        macroSystemFilterInstalled = ok and true or false
    elseif not shouldInstall and macroSystemFilterInstalled then
        pcall(ChatFrame_RemoveMessageEventFilter, "CHAT_MSG_SYSTEM", macroSystemMessageFilter)
        macroSystemFilterInstalled = false
    end
end

function MacroTool:SetMacroToolVisible(visible)
    self.macroToolVisible = visible and true or false
    self:RefreshChatSuppressionFilter()
end

function MacroTool:ResetWorkingRule()
    resetWorkingRule(self:GetSettings())
end

function MacroTool:CanUse()
    return canUseMacroTool()
end

function MacroTool:SetSetting(key, value)
    local settings = self:GetSettings()
    if key == "action" then
        settings.action = ACTIONS[value] and value or nil
        settings.targetRankIndex = actionUsesTargetRank(settings.action) and tonumber(settings.targetRanks[settings.action]) or nil
    elseif key == "targetRankIndex" then
        if actionUsesTargetRank(settings.action) then
            settings.targetRanks[settings.action] = tonumber(value)
            settings.targetRankIndex = tonumber(value)
        else
            settings.targetRankIndex = nil
        end
    else
        settings[key] = value
    end
    if key == "suppressMacroChatSpam" then
        self:RefreshChatSuppressionFilter()
    end
end

function MacroTool:GetExecutionHotKey()
    return self:GetSettings().macroHotKey or DEFAULT_EXECUTION_HOTKEY
end

local function executionBindingAction()
    return "MACRO " .. EXECUTION_MACRO_NAME
end

function MacroTool:IsExecutionHotKeyBound()
    local hotKey = self:GetExecutionHotKey()
    if hotKey == "" then return true end
    if type(GetBindingAction) ~= "function" then return nil, GP.L["WoW keybinding APIs are not available right now."] end

    local ok, action = pcall(GetBindingAction, hotKey)
    if not ok then return nil, GP.L["WoW keybinding APIs are not available right now."] end
    return action == executionBindingAction(), action
end

function MacroTool:EnsureExecutionHotKeyBound()
    local hotKey = self:GetExecutionHotKey()
    if hotKey == "" then return true end

    local bound, actionOrErr = self:IsExecutionHotKeyBound()
    if bound == true then
        return true, string.format(GP.L["Hotkey %s is bound to %s."], hotKey, EXECUTION_MACRO_NAME)
    end
    if bound == nil then return false, actionOrErr end

    if InCombatLockdown and InCombatLockdown() then
        return false, string.format(GP.L["Hotkey %s is not bound to %s and cannot be repaired while in combat."], hotKey, EXECUTION_MACRO_NAME)
    end
    if type(GetMacroIndexByName) == "function" then
        local index = safeCall(function() return GetMacroIndexByName(EXECUTION_MACRO_NAME) end, 0) or 0
        if index == 0 then
            return false, string.format(GP.L["Build Macro will create %s and bind hotkey %s."], EXECUTION_MACRO_NAME, hotKey)
        end
    end

    return self:BindExecutionMacro()
end

function MacroTool:SetExecutionHotKey(hotKey)
    local settings = self:GetSettings()
    hotKey = strtrim(hotKey or "")
    if hotKey == "" then hotKey = DEFAULT_EXECUTION_HOTKEY end
    settings.macroHotKey = hotKey
    return self:BindExecutionMacro()
end

function MacroTool:ScheduleExecutionHotKeyRebind()
    pendingExecutionHotKeyRebind = (pendingExecutionHotKeyRebind or 0) + 1
    local token = pendingExecutionHotKeyRebind
    local function rebind()
        if token ~= pendingExecutionHotKeyRebind then return end
        self:BindExecutionMacro()
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, rebind)
        C_Timer.After(0.25, rebind)
    else
        rebind()
    end
end

function MacroTool:SaveRule(name, ts)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end

    name = strtrim(name or "")
    if name == "" then return false, GP.L["Enter a rule name first."] end

    local settings = self:GetSettings()
    if not ACTIONS[settings.action] then return false, GP.L["Select an action first."] end
    if settings.action == "special" and not settings.specialSameRank and not settings.targetRankIndex then
        return false, GP.L["Select a target rank first."]
    end

    local rule = {}
    for _, key in ipairs(RULE_FIELDS) do
        rule[key] = type(settings[key]) == "table" and copyTable(settings[key]) or settings[key]
    end
    if rule.action == "special" and rule.specialSameRank then
        rule.targetRankIndex = nil
    elseif not actionUsesTargetRank(rule.action) then
        rule.targetRankIndex = nil
    end
    ts = ts or time()
    rule.savedAt = ts
    settings.savedRules[name] = rule
    settings.savedRulesUpdated[name] = ts
    settings.currentRuleName = name
    GP:SendMessage("GuildParagon_MacroRuleChanged", name, copyTable(rule), ts)
    return true
end

function MacroTool:LoadRule(name)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end

    name = strtrim(name or "")
    local settings = self:GetSettings()
    local rule = settings.savedRules[name]
    if not rule then return false, GP.L["Saved rule not found."] end

    for _, key in ipairs(RULE_FIELDS) do
        if rule[key] ~= nil then
            settings[key] = type(rule[key]) == "table" and copyTable(rule[key]) or rule[key]
        elseif key == "targetRankIndex" then
            settings[key] = nil
        end
    end
    if type(settings.targetRanks) ~= "table" then settings.targetRanks = {} end
    if actionUsesTargetRank(settings.action) then
        settings.targetRanks[settings.action] = tonumber(rule.targetRankIndex)
        settings.targetRankIndex = tonumber(rule.targetRankIndex)
    else
        settings.targetRankIndex = nil
    end
    settings.currentRuleName = name
    self:GetSettings()
    return true
end

function MacroTool:DeleteRule(name, ts)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end

    name = strtrim(name or "")
    local settings = self:GetSettings()
    if not settings.savedRules[name] then return false, GP.L["Saved rule not found."] end

    ts = ts or time()
    settings.savedRules[name] = nil
    settings.savedRulesUpdated[name] = ts
    if settings.currentRuleName == name then settings.currentRuleName = nil end
    GP:SendMessage("GuildParagon_MacroRuleChanged", name, nil, ts)
    return true
end

function MacroTool:GetSavedRuleNames()
    local settings = self:GetSettings()
    local names = {}
    for name in pairs(settings.savedRules) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function MacroTool:GetSavedRule(name)
    local settings = self:GetSettings()
    local rule = settings.savedRules[name]
    return type(rule) == "table" and copyRule(rule, settings.savedRulesUpdated[name]) or nil
end

function MacroTool:GetSavedRuleUpdatedAt(name)
    local settings = self:GetSettings()
    return settings.savedRulesUpdated[name]
end

function MacroTool:GetSavedRulesForSync()
    local settings = self:GetSettings()
    local rules = {}
    for name, rule in pairs(settings.savedRules) do
        if type(rule) == "table" then
            rules[name] = copyRule(rule, settings.savedRulesUpdated[name])
        end
    end
    return rules, settings.savedRulesUpdated
end

function MacroTool:SetSavedRuleFromSync(name, rule, ts)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end
    name = strtrim(name or "")
    if name == "" or type(ts) ~= "number" then return false end

    local settings = self:GetSettings()
    settings.savedRulesUpdated[name] = ts
    if type(rule) == "table" then
        settings.savedRules[name] = copyRule(rule, ts)
    else
        settings.savedRules[name] = nil
        if settings.currentRuleName == name then settings.currentRuleName = nil end
    end
    GP:SendMessage("GuildParagon_MacroRuleChanged", name, settings.savedRules[name] and copyTable(settings.savedRules[name]) or nil, ts)
    return true
end

local function getGuildData(guildKey)
    local guildData = guildKey and GP.db.global.guilds[guildKey]
    if not guildData then return nil end
    if type(guildData.macroIgnores) ~= "table" then guildData.macroIgnores = {} end
    if type(guildData.macroIgnoresUpdated) ~= "table" then guildData.macroIgnoresUpdated = {} end
    backfillGRMMacroIgnores(guildData)
    return guildData
end

function MacroTool:IsPlayerIgnored(guildKey, guid, action)
    local guildData = getGuildData(guildKey)
    if not guildData or not guid then return false end

    for _, linkedGUID in ipairs(getLinkedGUIDs(guildData, guid)) do
        local ignore = guildData.macroIgnores[linkedGUID]
        if type(ignore) == "table" and ignore[action] then
            return true
        end
    end
    return false
end

function MacroTool:SetPlayerIgnore(guildKey, guid, action, value, ts)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end
    if not ACTIONS[action] then return false, GP.L["Unknown macro action."] end
    local guildData = getGuildData(guildKey)
    if not guildData or not guid then return false, GP.L["Player not found."] end

    ts = ts or time()
    local changedGUIDs = {}
    for _, linkedGUID in ipairs(getLinkedGUIDs(guildData, guid)) do
        if (guildData.roster or {})[linkedGUID] then
            if setIgnoreRaw(guildData, linkedGUID, action, value, ts) then
                table.insert(changedGUIDs, linkedGUID)
            end
        end
    end
    if #changedGUIDs == 0 then return true end
    GP:SendMessage("GuildParagon_MacroIgnoresChanged", guildKey, guid, action, value, ts, changedGUIDs)
    return true
end

function MacroTool:GetPlayerIgnoreUpdatedAt(guildKey, guid)
    local guildData = getGuildData(guildKey)
    return guildData and guildData.macroIgnoresUpdated[guid]
end

function MacroTool:GetPlayerIgnoreForSync(guildKey, guid)
    local guildData = getGuildData(guildKey)
    local ignore = guildData and guildData.macroIgnores[guid]
    return type(ignore) == "table" and copyTable(ignore) or nil
end

function MacroTool:GetMacroIgnoresForSync(guildKey)
    local guildData = getGuildData(guildKey)
    if not guildData then return {}, {} end
    return guildData.macroIgnores, guildData.macroIgnoresUpdated
end

function MacroTool:SetPlayerIgnoreFromSync(guildKey, guid, ignore, ts)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end
    local guildData = getGuildData(guildKey)
    if not guildData or not guid or type(ts) ~= "number" then return false end

    if type(ignore) == "table" and next(ignore) then
        local cleaned = {}
        for action in pairs(ACTIONS) do
            if ignore[action] then cleaned[action] = true end
        end
        guildData.macroIgnores[guid] = next(cleaned) and cleaned or nil
    else
        guildData.macroIgnores[guid] = nil
    end
    guildData.macroIgnoresUpdated[guid] = ts
    GP:SendMessage("GuildParagon_MacroIgnoresChanged", guildKey, guid, nil, nil, ts)
    return true
end

function MacroTool:Analyze(guildKey, settingsOverride)
    if not self:CanUse() then return nil, GP.L["Macro Tool requires officer access."] end

    local guildData = getGuildData(guildKey)
    if not guildData then return nil, GP.L["No roster data yet — try /gp scan."] end

    local settings = settingsOverride and copyRule(settingsOverride, tonumber(settingsOverride.savedAt) or 0) or self:GetSettings()
    if settings.targetScope ~= "alts" and settings.targetScope ~= "mains" then settings.targetScope = "all" end
    if settings.levelMode ~= "max" and settings.levelMode ~= "range" then settings.levelMode = "all" end
    if type(settings.selectedRanks) ~= "table" then settings.selectedRanks = {} end
    settings.allRanks = settings.allRanks ~= false
    settings.minLevel = tonumber(settings.minLevel) or 1
    settings.maxLevel = tonumber(settings.maxLevel) or 90
    settings.specialSameRank = settings.specialSameRank and true or false
    settings.specialDisableDemote = settings.specialDisableDemote and true or false
    local action = settings.action
    if not ACTIONS[action] then
        return {
            action = nil,
            actionLabel = "",
            myRankIndex = getMyRankIndex(guildData),
            permission = true,
            queued = 0,
            ignored = 0,
            total = countTable(guildData.roster or {}),
            rows = {},
            idle = true,
        }
    end

    local minOfflineDays = math.max(0, tonumber(settings.minOfflineDays) or 0)
    local minRankDays = math.max(0, tonumber(settings.minRankDays) or 0)
    local maxOfflineDays = math.max(0, tonumber(settings.maxOfflineDays) or 0)
    local requireText = strtrim(settings.requireText or ""):lower()
    local safeText = strtrim(settings.safeText or ""):lower()
    local myRankIndex = getMyRankIndex(guildData)
    local now = time()
    local rows, queued, ignored = {}, 0, 0
    local permission = action == "special" and (canDo("promote") or canDo("demote")) or canDo(action)
    local checksLinkedActivity = action == "kick" or action == "demote"
    local altGroups = checksLinkedActivity and buildAltGroupCache(guildKey, guildData) or nil

    if action == "special" then
        local Alts = GP:GetModule("Alts")
        local alts = Alts:GetAllForSync(guildKey)
        for altGUID, mainGUID in pairs(alts or {}) do
            local alt = guildData.roster[altGUID]
            local main = guildData.roster[mainGUID]
            if alt and main then
                local result = newResult(altGUID, alt)
                result.action = "special"
                result.mainGUID = mainGUID
                result.mainName = main.name
                result.offlineDays = offlineDays(alt)
                result.rankDays = rankDays(alt, now)
                result.isAlt = true
                result.isMain = false
                result.targetRankIndex = settings.specialSameRank and main.rankIndex or settings.targetRankIndex
                result.targetRankName = rankName(result.targetRankIndex)

                if self:IsPlayerIgnored(guildKey, altGUID, "special") then
                    reject(result, GP.L["Ignored by this player's Macro Rules setting."])
                end

                if not myRankIndex then
                    reject(result, GP.L["Could not confirm your guild rank."])
                elseif alt.rankIndex == nil or main.rankIndex == nil then
                    reject(result, GP.L["Member rank is unknown."])
                elseif alt.rankIndex <= myRankIndex then
                    reject(result, GP.L["Protected rank: same or higher than your rank."])
                end

                if not settings.allRanks and main.rankIndex and not settings.selectedRanks[main.rankIndex] then
                    reject(result, GP.L["Main rank is not selected for this rule."])
                end

                if minOfflineDays > 0 and not main.online then
                    local mainOffline = offlineDays(main)
                    if mainOffline == nil then
                        reject(result, string.format(GP.L["Main %s has unknown offline duration."], main.name or GP.L["Unknown"]))
                    elseif mainOffline >= minOfflineDays then
                        reject(result, string.format(GP.L["Main %s is offline for %d day(s)."], main.name or GP.L["Unknown"], mainOffline))
                    end
                end

                if not result.targetRankIndex or not rankExists(guildData, result.targetRankIndex) then
                    reject(result, GP.L["Target rank is unknown."])
                elseif result.targetRankIndex == alt.rankIndex then
                    reject(result, GP.L["Alt is already at the target rank."])
                elseif myRankIndex and result.targetRankIndex <= myRankIndex then
                    reject(result, GP.L["Target rank is protected."])
                elseif result.targetRankIndex < alt.rankIndex then
                    result.actualAction = "promote"
                    if not canDo("promote") then
                        reject(result, GP.L["Current character lacks guild permission for this action."])
                    elseif self:IsPlayerIgnored(guildKey, altGUID, "promote") then
                        reject(result, GP.L["Ignored by this player's Macro Rules setting."])
                    else
                        accept(result, string.format(GP.L["Would promote alt to %s."], result.targetRankName or GP.L["Unknown"]))
                    end
                else
                    result.actualAction = "demote"
                    if settings.specialDisableDemote then
                        reject(result, GP.L["Demotion is disabled for this special rule."])
                    elseif not canDo("demote") then
                        reject(result, GP.L["Current character lacks guild permission for this action."])
                    elseif self:IsPlayerIgnored(guildKey, altGUID, "demote") then
                        reject(result, GP.L["Ignored by this player's Macro Rules setting."])
                    else
                        accept(result, string.format(GP.L["Would demote alt to %s."], result.targetRankName or GP.L["Unknown"]))
                    end
                end

                if result.include then
                    queued = queued + 1
                    accept(result, string.format(GP.L["Linked to main %s."], main.name or GP.L["Unknown"]))
                else
                    ignored = ignored + 1
                end
                table.insert(rows, result)
            end
        end

        table.sort(rows, function(a, b)
            if a.include ~= b.include then return a.include end
            return (a.player.name or "") < (b.player.name or "")
        end)

        return {
            action = action,
            actionLabel = ACTIONS[action].label,
            myRankIndex = myRankIndex,
            permission = permission,
            queued = queued,
            ignored = ignored,
            total = queued + ignored,
            rows = rows,
        }
    end

    for guid, player in pairs(guildData.roster or {}) do
        local result = newResult(guid, player)
        result.action = action
        result.offlineDays = offlineDays(player)
        result.rankDays = rankDays(player, now)
        result.isAlt = isAlt(guildKey, guid)
        result.isMain = isMain(guildKey, guid)
        if action == "promote" and player.rankIndex then
            result.targetRankIndex = settings.targetRankIndex or (player.rankIndex - 1)
            result.targetRankName = rankName(result.targetRankIndex)
        elseif action == "demote" and player.rankIndex then
            result.targetRankIndex = settings.targetRankIndex or (player.rankIndex + 1)
            result.targetRankName = rankName(result.targetRankIndex)
        end

        if self:IsPlayerIgnored(guildKey, guid, action) then
            reject(result, GP.L["Ignored by this player's Macro Rules setting."])
        end

        if not permission then
            reject(result, GP.L["Current character lacks guild permission for this action."])
        end
        if not myRankIndex then
            reject(result, GP.L["Could not confirm your guild rank."])
        elseif player.rankIndex == nil then
            reject(result, GP.L["Member rank is unknown."])
        elseif player.rankIndex <= myRankIndex then
            reject(result, GP.L["Protected rank: same or higher than your rank."])
        end

        if action == "promote" and result.targetRankIndex then
            if not rankExists(guildData, result.targetRankIndex) then
                reject(result, GP.L["Target rank is unknown."])
            elseif result.targetRankIndex >= player.rankIndex then
                reject(result, GP.L["Target rank is not above the current rank."])
            elseif myRankIndex and result.targetRankIndex <= myRankIndex then
                reject(result, GP.L["Promotion would reach a rank you cannot safely assign."])
            else
                accept(result, string.format(GP.L["Would promote to %s."], result.targetRankName or GP.L["Unknown"]))
            end
        elseif action == "demote" and result.targetRankIndex then
            if not rankExists(guildData, result.targetRankIndex) then
                reject(result, GP.L["Target rank is unknown."])
            elseif result.targetRankIndex <= player.rankIndex then
                reject(result, GP.L["Target rank is not below the current rank."])
            else
                accept(result, string.format(GP.L["Would demote to %s."], result.targetRankName or GP.L["Unknown"]))
            end
        end

        if action == "promote" and minRankDays > 0 then
            if result.rankDays == nil then
                reject(result, GP.L["Time at current rank is unknown."])
            elseif result.rankDays < minRankDays then
                reject(result, string.format(GP.L["At current rank for %d day(s), below threshold."], result.rankDays))
            else
                accept(result, string.format(GP.L["At current rank for %d day(s)."], result.rankDays))
            end
        end

        if action == "promote" and maxOfflineDays > 0 then
            if not player.online and result.offlineDays == nil then
                reject(result, GP.L["Offline duration is unknown."])
            elseif not player.online and result.offlineDays > maxOfflineDays then
                reject(result, string.format(GP.L["Last online %d day(s) ago, outside recent threshold."], result.offlineDays))
            else
                accept(result, string.format(GP.L["Online within %d day(s)."], maxOfflineDays))
            end
        end

        if player.online and not settings.includeOnline then
            reject(result, GP.L["Online members are excluded."])
        elseif not player.online and minOfflineDays > 0 then
            if result.offlineDays == nil then
                reject(result, GP.L["Offline duration is unknown."])
            elseif result.offlineDays < minOfflineDays then
                reject(result, string.format(GP.L["Offline for %d day(s), below threshold."], result.offlineDays))
            end
        end

        if checksLinkedActivity then
            local linked, linkedStatus = linkedRecentActivity(guildData, altGroups, guid, minOfflineDays)
            if linked then
                if linkedStatus == "online" then
                    reject(result, string.format(GP.L["Linked character %s is online."], linked.name or GP.L["Unknown"]))
                elseif linkedStatus == "unknown" then
                    reject(result, string.format(GP.L["Linked character %s has unknown offline duration."], linked.name or GP.L["Unknown"]))
                else
                    reject(result, string.format(GP.L["Linked character %s was online %d day(s) ago, below threshold."],
                        linked.name or GP.L["Unknown"], linkedStatus))
                end
            end
        end

        if settings.targetScope == "alts" and not result.isAlt then
            reject(result, GP.L["Rule applies to alts only."])
        elseif settings.targetScope == "mains" and not result.isMain then
            reject(result, GP.L["Rule applies to mains only."])
        end

        if not settings.allRanks and player.rankIndex and not settings.selectedRanks[player.rankIndex] then
            reject(result, GP.L["Rank is not selected for this rule."])
        end

        if settings.levelMode == "max" and player.level and player.level < 90 then
            reject(result, GP.L["Not max level."])
        elseif settings.levelMode == "range" then
            local minLevel = math.min(settings.minLevel, settings.maxLevel)
            local maxLevel = math.max(settings.minLevel, settings.maxLevel)
            if not player.level or player.level < minLevel or player.level > maxLevel then
                reject(result, string.format(GP.L["Level is outside %d-%d."], minLevel, maxLevel))
            end
        end

        if requireText ~= "" then
            if settings.requireTextEmptyOnly and not publicNotesEmpty(guildKey, guid, player) then
                reject(result, GP.L["Required text only applies to empty notes."])
            elseif not contains(publicNoteBlob(guildKey, guid, player), requireText) then
                reject(result, GP.L["Required text was not found."])
            end
        end

        local safeBlob = settings.safeTextAllNotes and noteBlob(guildKey, guid, player) or publicNoteBlob(guildKey, guid, player)
        if safeText ~= "" and contains(safeBlob, safeText) then
            reject(result, GP.L["Safe text matched name or notes."])
        end

        if result.include then
            queued = queued + 1
            accept(result, GP.L["Queued by current macro rules."])
        else
            ignored = ignored + 1
        end
        table.insert(rows, result)
    end

    table.sort(rows, function(a, b)
        if a.include ~= b.include then return a.include end
        local ar, br = a.player.rankIndex or 999, b.player.rankIndex or 999
        if ar ~= br then return ar < br end
        return (a.player.name or "") < (b.player.name or "")
    end)

    return {
        action = action,
        actionLabel = ACTIONS[action].label,
        myRankIndex = myRankIndex,
        permission = permission,
        queued = queued,
        ignored = ignored,
        total = queued + ignored,
        rows = rows,
    }
end

local function rowMoveCount(row)
    if type(row) ~= "table" then return 1 end
    local action = row.actualAction or row.action
    if action == "promote" or action == "demote" then
        local currentRank = tonumber(row.player and row.player.rankIndex)
        local targetRank = tonumber(row.targetRankIndex)
        if currentRank and targetRank then
            return math.max(1, math.abs(currentRank - targetRank))
        end
    end
    return 1
end

function MacroTool:BuildMacroPlan(row, options)
    options = options or {}
    if not self:CanUse() then return nil, GP.L["Macro Tool requires officer access."] end
    if type(row) ~= "table" or not row.include or type(row.player) ~= "table" then
        return nil, GP.L["Select a queued macro action first."]
    end

    local action = row.actualAction or row.action
    local command
    if action == "kick" then
        command = "/gremove"
    elseif action == "promote" then
        command = "/gpromote"
    elseif action == "demote" then
        command = "/gdemote"
    else
        return nil, GP.L["Unknown macro action."]
    end

    local name = row.player.name
    if not name or name == "" then
        return nil, GP.L["Player not found."]
    end

    local moves = rowMoveCount(row)
    if action == "promote" or action == "demote" then
        local currentRank = tonumber(row.player.rankIndex)
        local targetRank = tonumber(row.targetRankIndex)
        if not currentRank or not targetRank then
            return nil, GP.L["Target rank is unknown."]
        end
    end

    local commandCount = options.singleRankMove and 1 or moves
    local lines = {}
    for _ = 1, commandCount do
        local nextLine = command .. " " .. name
        local candidate = (#lines == 0) and nextLine or (table.concat(lines, "\n") .. "\n" .. nextLine)
        if #candidate > MACRO_TEXT_LIMIT then break end
        table.insert(lines, nextLine)
    end

    if #lines == 0 then
        return nil, GP.L["Macro command is too long for WoW's macro limit."]
    end

    local body = table.concat(lines, "\n")
    return {
        macroName = EXECUTION_MACRO_NAME,
        icon = EXECUTION_MACRO_ICON,
        body = body,
        macroSize = #body,
        action = action,
        actionLabel = ACTIONS[action] and ACTIONS[action].label or action,
        playerName = name,
        targetRankName = row.targetRankName,
        moves = moves,
        commandLines = #lines,
        truncated = not options.singleRankMove and #lines < moves,
    }
end

function MacroTool:BuildMacroPlanForRows(rows, options)
    options = options or {}
    if type(rows) ~= "table" or #rows == 0 then
        return nil, GP.L["Select a queued macro action first."]
    end
    if #rows == 1 and not options.callbackToken then
        local plan, err = self:BuildMacroPlan(rows[1], { singleRankMove = options.singleRankMove })
        if plan and options.singleRankMove then
            plan.totalMoves = math.max(1, tonumber(rows[1].remainingMoves) or rowMoveCount(rows[1]))
            plan.moves = math.max(1, tonumber(plan.commandLines) or 1)
            plan.selectedCount = 1
            plan.requestedCount = 1
            plan.batchRows = { rows[1] }
        end
        return plan, err
    end

    local lines = {}
    if options.callbackToken and options.callbackToken ~= "" then
        table.insert(lines, string.format("/run %s(\"%s\")", EXECUTION_CALLBACK, options.callbackToken))
    end

    local included, moves, totalMoves, kickCommands, truncated, firstAction = 0, 0, 0, 0, false, nil
    local batchRows = {}
    for _, row in ipairs(rows) do
        local rowAction = row.actualAction or row.action
        if rowAction == "kick" and options.maxKickCommands and kickCommands >= options.maxKickCommands then
            truncated = true
            break
        end
        local plan, err = self:BuildMacroPlan(row, { singleRankMove = options.singleRankMove })
        if not plan then
            return nil, err
        end

        local planLines = { strsplit("\n", plan.body) }
        local addedForRow = 0
        local beforeRow = #lines
        for _, line in ipairs(planLines) do
            local candidate = (#lines == 0) and line or (table.concat(lines, "\n") .. "\n" .. line)
            if #candidate > MACRO_TEXT_LIMIT then
                truncated = true
                break
            end
            table.insert(lines, line)
            addedForRow = addedForRow + 1
        end

        if addedForRow > 0 then
            included = included + 1
            moves = moves + addedForRow
            totalMoves = totalMoves + math.max(1, tonumber(row.remainingMoves) or rowMoveCount(row))
            if rowAction == "kick" then
                kickCommands = kickCommands + addedForRow
            end
            firstAction = firstAction or plan.action
            table.insert(batchRows, row)
        elseif beforeRow == #lines then
            truncated = true
            break
        end
        if truncated then break end
        if plan.truncated then
            truncated = true
            break
        end
    end

    if #lines == 0 or (options.callbackToken and included == 0) then
        return nil, GP.L["Macro command is too long for WoW's macro limit."]
    end

    local body = table.concat(lines, "\n")
    return {
        macroName = EXECUTION_MACRO_NAME,
        icon = EXECUTION_MACRO_ICON,
        body = body,
        macroSize = #body,
        action = firstAction or "bulk",
        actionLabel = GP.L["Multiple"],
        playerName = string.format(GP.L["%d selected"], included),
        moves = moves,
        totalMoves = totalMoves,
        commandLines = #lines,
        selectedCount = included,
        requestedCount = #rows,
        batchRows = batchRows,
        truncated = truncated or included < #rows,
    }
end

function MacroTool:ResetExecutionQueue()
    pendingExecutionRankValidation = pendingExecutionRankValidation + 1
    self.executionQueue = {
        rows = {},
        activeToken = nil,
        activeCount = 0,
        batchNumber = 0,
        completed = 0,
        history = {},
        validationEntries = {},
    }
    GP:SendMessage("GuildParagon_MacroExecutorChanged")
end

function MacroTool:QueueRankValidation(row)
    local action = row and (row.actualAction or row.action)
    if action ~= "promote" and action ~= "demote" then return end
    if not row.guid or type(row.player) ~= "table" then return end

    local startRank = tonumber(row.player.rankIndex)
    if not startRank then return end

    local totalMoves = math.max(1, tonumber(row.totalMoves) or rowMoveCount(row))
    local remainingMoves = math.max(0, tonumber(row.remainingMoves) or 0)
    local completedMoves = math.max(1, totalMoves - remainingMoves)
    local delta = action == "promote" and -1 or 1
    local expectedRank = startRank + (delta * completedMoves)
    local targetRank = tonumber(row.targetRankIndex)
    if targetRank then
        if action == "promote" then
            expectedRank = math.max(targetRank, expectedRank)
        else
            expectedRank = math.min(targetRank, expectedRank)
        end
    end

    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    self.executionQueue.validationEntries = self.executionQueue.validationEntries or {}
    self.executionQueue.validationEntries[row.guid] = {
        guid = row.guid,
        name = row.player.name or row.name,
        expectedRankIndex = expectedRank,
    }
end

function MacroTool:AppendExecutionHistory(text)
    if not text or text == "" then return end
    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    self.executionQueue.history = self.executionQueue.history or {}
    table.insert(self.executionQueue.history, 1, { time = time(), text = text })
    while #self.executionQueue.history > 4 do
        table.remove(self.executionQueue.history)
    end
    GP:SendMessage("GuildParagon_MacroExecutorChanged")
end

function MacroTool:ValidateExecutionRankChanges(entries, token, isRetry)
    if token ~= pendingExecutionRankValidation then return end
    if type(entries) ~= "table" or not next(entries) then return end

    local Roster = GP:GetModule("Roster", true)
    local guildKey = Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil
    local guildData = guildKey and getGuildData(guildKey)
    local failed = {}

    for _, entry in pairs(entries) do
        local player = guildData and guildData.roster and guildData.roster[entry.guid]
        if not player and Roster and Roster.FindPlayerByName then
            local _, found = Roster:FindPlayerByName(guildData, entry.name, false)
            player = found
        end
        if not player or tonumber(player.rankIndex) ~= tonumber(entry.expectedRankIndex) then
            table.insert(failed, entry.name or entry.guid or GP.L["Unknown"])
        end
    end

    if #failed == 0 then
        local msg = GP.L["Macro rank changes have been validated."]
        GP:Print(msg)
        self:AppendExecutionHistory(msg)
        return
    end

    if not isRetry then
        local msg = GP.L["Not all macro changes validated. One moment..."]
        GP:Print(msg)
        self:AppendExecutionHistory(msg)
        requestRosterRefresh(0.1)
        if C_Timer and C_Timer.After then
            C_Timer.After(3, function()
                MacroTool:ValidateExecutionRankChanges(entries, token, true)
            end)
        else
            self:ValidateExecutionRankChanges(entries, token, true)
        end
        return
    end

    local msg = GP.L["Warning! Macro changes were not able to be validated. Please verify expected results before using the macro tool further."]
    GP:Print(msg)
    self:AppendExecutionHistory(msg)
end

function MacroTool:ScheduleExecutionRankValidation()
    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    local entries = self.executionQueue.validationEntries
    if type(entries) ~= "table" or not next(entries) then return end

    self.executionQueue.validationEntries = {}
    pendingExecutionRankValidation = pendingExecutionRankValidation + 1
    local token = pendingExecutionRankValidation
    requestRosterRefresh(0.1)
    if C_Timer and C_Timer.After then
        C_Timer.After(2.5, function()
            MacroTool:ValidateExecutionRankChanges(entries, token, false)
        end)
    else
        self:ValidateExecutionRankChanges(entries, token, false)
    end
end

function MacroTool:GetExecutionState()
    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    local remainingMoves = 0
    for _, row in ipairs(self.executionQueue.rows or {}) do
        remainingMoves = remainingMoves + math.max(1, tonumber(row.remainingMoves) or rowMoveCount(row))
    end
    return {
        remaining = #(self.executionQueue.rows or {}),
        remainingMoves = remainingMoves,
        completed = self.executionQueue.completed or 0,
        batchNumber = self.executionQueue.batchNumber or 0,
        activeCount = self.executionQueue.activeCount or 0,
        activeToken = self.executionQueue.activeToken,
        activePlan = self.executionQueue.activePlan,
        history = self.executionQueue.history,
    }
end

function MacroTool:GetExecutionRows()
    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    return self.executionQueue.rows or {}
end

function MacroTool:BuildExecutionBatch(rows)
    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    if self.executionQueue.activeToken then
        return false, GP.L["A macro batch is already armed. Press it or Clear Macro first."]
    end

    if type(rows) == "table" and #rows > 0 then
        pendingExecutionRankValidation = pendingExecutionRankValidation + 1
        self.executionQueue = {
            rows = copyArray(rows),
            activeToken = nil,
            activeCount = 0,
            batchNumber = 0,
            completed = 0,
            history = {},
            validationEntries = {},
        }
        for _, row in ipairs(self.executionQueue.rows) do
            row.remainingMoves = rowMoveCount(row)
            row.totalMoves = row.remainingMoves
        end
    end

    if #(self.executionQueue.rows or {}) == 0 then
        return false, GP.L["No queued macro actions remain."]
    end

    local token = tostring(time()) .. tostring(random(1000, 9999))
    local plan, err = self:BuildMacroPlanForRows(self.executionQueue.rows, {
        callbackToken = token,
        singleRankMove = true,
        maxKickCommands = MAX_KICK_COMMANDS_PER_BATCH,
    })
    if not plan then return false, err end

    self.executionQueue.activeToken = token
    self.executionQueue.activeCount = #(plan.batchRows or {})
    self.executionQueue.batchNumber = (self.executionQueue.batchNumber or 0) + 1
    plan.batchNumber = self.executionQueue.batchNumber
    local requeued = 0
    for _, row in ipairs(plan.batchRows or {}) do
        if (tonumber(row.remainingMoves) or 1) > 1 then
            requeued = requeued + 1
        end
    end
    plan.remainingAfterBatch = math.max(0, #self.executionQueue.rows - self.executionQueue.activeCount + requeued)

    local ok, msg = self:CreateOrUpdateExecutionMacro(plan)
    local bindOK, bindMsg
    if ok then
        bindOK, bindMsg = self:BindExecutionMacro()
        self:ScheduleExecutionHotKeyRebind()
        self.executionQueue.activePlan = plan
        self.executionQueue.history = self.executionQueue.history or {}
        table.insert(self.executionQueue.history, 1, {
            time = time(),
            text = string.format(GP.L["Batch %d armed: %d action(s), %d step(s), %d/%d chars."],
                plan.batchNumber or 0, plan.selectedCount or self.executionQueue.activeCount or 0,
                plan.moves or 0, plan.macroSize or #(plan.body or ""), MACRO_TEXT_LIMIT),
        })
        local hotKey = self:GetExecutionHotKey()
        local _, action = self:IsExecutionHotKeyBound()
        table.insert(self.executionQueue.history, 1, {
            time = time(),
            text = string.format(GP.L["Hotkey check: %s -> %s"], hotKey ~= "" and hotKey or GP.L["None"], action or GP.L["None"]),
        })
        while #self.executionQueue.history > 4 do
            table.remove(self.executionQueue.history)
        end
        GP:SendMessage("GuildParagon_MacroExecutorChanged", plan)
    else
        self.executionQueue.activeToken = nil
        self.executionQueue.activeCount = 0
        self.executionQueue.activePlan = nil
    end
    if ok and bindOK == false and bindMsg and bindMsg ~= "" then
        msg = (msg and msg ~= "") and (msg .. " " .. bindMsg) or bindMsg
    end
    return ok, msg, plan
end

function MacroTool:BindExecutionMacro()
    if InCombatLockdown and InCombatLockdown() then
        return false, GP.L["Cannot bind the macro hotkey while in combat."]
    end
    if not SetBindingMacro then
        return false, GP.L["WoW keybinding APIs are not available right now."]
    end

    local hotKey = self:GetExecutionHotKey()
    if hotKey == "" then return true end

    if SetBinding then
        pcall(SetBinding, hotKey)
    end
    local ok, bound = pcall(SetBindingMacro, hotKey, EXECUTION_MACRO_NAME)
    if not ok or bound == false then
        return false, string.format(GP.L["Could not bind %s to %s."], hotKey, EXECUTION_MACRO_NAME)
    end
    if SaveBindings and GetCurrentBindingSet then
        pcall(SaveBindings, GetCurrentBindingSet())
    end
    bound = self:IsExecutionHotKeyBound()
    if bound == false then
        return false, string.format(GP.L["Could not bind %s to %s."], hotKey, EXECUTION_MACRO_NAME)
    end
    return true, string.format(GP.L["Hotkey %s is bound to %s."], hotKey, EXECUTION_MACRO_NAME)
end

function MacroTool:OnExecutionMacroPressed(token)
    self.executionQueue = self.executionQueue or { rows = {}, completed = 0, batchNumber = 0 }
    if token ~= self.executionQueue.activeToken then return end

    local count = self.executionQueue.activeCount or 0
    local activePlan = self.executionQueue.activePlan
    local Roster = GP:GetModule("Roster", true)
    local PostKick = GP:GetModule("PostKick", true)
    local guildKey = Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil
    for _ = 1, count do
        local row = table.remove(self.executionQueue.rows, 1)
        if row then
            local action = row.actualAction or row.action
            if action == "kick" and PostKick and PostKick.RecordMacroKickAttempt and guildKey then
                PostKick:RecordMacroKickAttempt(guildKey, row.guid, row.player)
            end
            row.remainingMoves = math.max(0, (tonumber(row.remainingMoves) or rowMoveCount(row)) - 1)
            self:QueueRankValidation(row)
            if row.remainingMoves > 0 then
                table.insert(self.executionQueue.rows, row)
            end
        end
    end
    self.executionQueue.completed = (self.executionQueue.completed or 0) + count
    self.executionQueue.activeToken = nil
    self.executionQueue.activeCount = 0
    self.executionQueue.activePlan = nil
    self.executionQueue.history = self.executionQueue.history or {}
    table.insert(self.executionQueue.history, 1, {
        time = time(),
        text = string.format(GP.L["Batch %d pressed: %d action(s) consumed; %d action(s) remain."],
            activePlan and activePlan.batchNumber or self.executionQueue.batchNumber or 0,
            count,
            #(self.executionQueue.rows or {})),
    })
    while #self.executionQueue.history > 4 do
        table.remove(self.executionQueue.history)
    end

    self:ClearExecutionMacro(true)
    GP:SendMessage("GuildParagon_MacroExecutorChanged")
    requestRosterRefresh(0.75)
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            requestRosterRefresh(0.1)
        end)
    end
    if #(self.executionQueue.rows or {}) == 0 then
        self:ScheduleExecutionRankValidation()
    end

    local function rebuildNextBatch()
        if self.executionQueue and not self.executionQueue.activeToken and #(self.executionQueue.rows or {}) > 0 then
            self:BuildExecutionBatch()
        end
    end
    if #(self.executionQueue.rows or {}) > 0 then
        if C_Timer and C_Timer.After then
            C_Timer.After(0.15, rebuildNextBatch)
        else
            rebuildNextBatch()
        end
    end
end

function MacroTool:CreateOrUpdateExecutionMacro(plan)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end
    if InCombatLockdown and InCombatLockdown() then
        return false, GP.L["Cannot build the macro while in combat."]
    end
    if type(plan) ~= "table" or type(plan.body) ~= "string" or plan.body == "" then
        return false, GP.L["Select a queued macro action first."]
    end
    if not GetMacroIndexByName or not CreateMacro or not EditMacro then
        return false, GP.L["WoW macro APIs are not available right now."]
    end

    local index = safeCall(function() return GetMacroIndexByName(EXECUTION_MACRO_NAME) end, 0) or 0
    if index == 0 then
        local accountMacros = safeCall(function()
            local account = GetNumMacros()
            return account
        end, 0) or 0
        local maxAccountMacros = MAX_ACCOUNT_MACROS or 120
        if accountMacros >= maxAccountMacros then
            return false, string.format(GP.L["No account macro slot is available for %s."], EXECUTION_MACRO_NAME)
        end

        local ok, created = pcall(CreateMacro, EXECUTION_MACRO_NAME, plan.icon or EXECUTION_MACRO_ICON, plan.body, false)
        if not ok or not created then
            ok, created = pcall(CreateMacro, EXECUTION_MACRO_NAME, FALLBACK_MACRO_ICON, plan.body, false)
        end
        if not ok or not created then
            return false, GP.L["Could not create the Guild Paragon macro."]
        end
        local bindOK, bindMsg = self:BindExecutionMacro()
        local msg = string.format(GP.L["Created %s for %s."], EXECUTION_MACRO_NAME, plan.playerName or GP.L["Unknown"])
        return true, (bindOK == false and (msg .. " " .. (bindMsg or "")) or msg)
    end

    local ok = pcall(EditMacro, index, EXECUTION_MACRO_NAME, plan.icon or EXECUTION_MACRO_ICON, plan.body)
    if not ok then
        ok = pcall(EditMacro, index, EXECUTION_MACRO_NAME, FALLBACK_MACRO_ICON, plan.body)
    end
    if not ok then
        return false, GP.L["Could not update the Guild Paragon macro."]
    end
    local bindOK, bindMsg = self:BindExecutionMacro()
    local msg = string.format(GP.L["Updated %s for %s."], EXECUTION_MACRO_NAME, plan.playerName or GP.L["Unknown"])
    return true, (bindOK == false and (msg .. " " .. (bindMsg or "")) or msg)
end

function MacroTool:ClearExecutionMacro(silent)
    if not self:CanUse() then return false, GP.L["Macro Tool requires officer access."] end
    if InCombatLockdown and InCombatLockdown() then
        return false, GP.L["Cannot clear the macro while in combat."]
    end
    if not GetMacroIndexByName or not EditMacro then
        return false, GP.L["WoW macro APIs are not available right now."]
    end

    local index = safeCall(function() return GetMacroIndexByName(EXECUTION_MACRO_NAME) end, 0) or 0
    if index == 0 then
        if not silent then
            self:ResetExecutionQueue()
        end
        return true, string.format(GP.L["No %s macro exists yet."], EXECUTION_MACRO_NAME)
    end

    local ok = pcall(EditMacro, index, EXECUTION_MACRO_NAME, EXECUTION_MACRO_ICON, EMPTY_EXECUTION_MACRO)
    if not ok then
        ok = pcall(EditMacro, index, EXECUTION_MACRO_NAME, FALLBACK_MACRO_ICON, EMPTY_EXECUTION_MACRO)
    end
    if not ok then
        return false, GP.L["Could not clear the Guild Paragon macro."]
    end
    if not silent then
        self:ResetExecutionQueue()
    end
    return true, string.format(GP.L["Cleared %s."], EXECUTION_MACRO_NAME)
end

function MacroTool:PurgeOrphanedMatchAuditState()
    local guilds = GP.db.global and GP.db.global.guilds
    if type(guilds) ~= "table" then return end

    for _, guildData in pairs(guilds) do
        if guildData.macroRuleMatchState ~= nil then
            guildData.macroRuleMatchState = nil
        end
        if guildData.macroRuleMatchStateInitialized ~= nil then
            guildData.macroRuleMatchStateInitialized = nil
        end
    end
end

function MacroTool:OnEnable()
    self:PurgeOrphanedMatchAuditState()
    _G[EXECUTION_CALLBACK] = function(token)
        MacroTool:OnExecutionMacroPressed(token)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(1, function()
            MacroTool:EnsureExecutionHotKeyBound()
        end)
    else
        self:EnsureExecutionHotKeyBound()
    end
    if not macroSuppressionWatcher then
        macroSuppressionWatcher = CreateFrame("Frame")
        macroSuppressionWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
        macroSuppressionWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
        macroSuppressionWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
        macroSuppressionWatcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        macroSuppressionWatcher:SetScript("OnEvent", function()
            MacroTool:RefreshChatSuppressionFilter()
        end)
    end
end

function MacroTool:AnalyzeSavedRules(guildKey, includeRows)
    if not self:CanUse() then return nil, GP.L["Macro Tool requires officer access."] end

    local names = self:GetSavedRuleNames()
    local summary = {
        queued = 0,
        ignored = 0,
        total = 0,
        rules = 0,
        rows = {},
    }

    for _, name in ipairs(names) do
        local rule = self:GetSavedRule(name)
        if type(rule) == "table" and ACTIONS[rule.action] then
            local report = self:Analyze(guildKey, rule)
            if report and not report.idle then
                summary.rules = summary.rules + 1
                summary.queued = summary.queued + (tonumber(report.queued) or 0)
                summary.ignored = summary.ignored + (tonumber(report.ignored) or 0)
                summary.total = summary.total + (tonumber(report.total) or 0)
                if includeRows then
                    for _, row in ipairs(report.rows or {}) do
                        if row.include then
                            row.savedRuleName = name
                            table.insert(summary.rows, row)
                        end
                    end
                end
            end
        end
    end

    return summary
end

-- Background saved-rule auditing is intentionally absent. The Macro Tool UI
-- still uses the on-demand AnalyzeSavedRules path above.
