-- Guild Paragon - Guild Health
-- Dashboard queries for officer attention signals.
local _, GP = ...

local GuildHealth = GP:NewModule("GuildHealth")

local ATTENTION_LIMIT = 50
local RETENTION_COHORTS = { 30, 60, 90 }
local MIN_JUDGED_DAYS = 14
local MAX_SCAN_DAYS = 90
local NEW_MEMBER_DAYS = 14
local DEFAULT_SEASON_START_HOUR = 6
local MYTHIC_SEASON_START_BY_REGION = {
    [1] = "2026-08-18 06:00", -- US
    [3] = "2026-08-19 06:00", -- EU
}

local SEVERITY_ORDER = {
    critical = 1,
    warning = 2,
    info = 3,
}

local ATTENTION_CATEGORY_ORDER = {
    newmember = 1,
    activity = 2,
    cleanup = 3,
}

local activeWithinDays

local function guildDataFor(guildKey)
    return guildKey and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[guildKey] or nil
end

local function defaultGuildKey()
    local Roster = GP:GetModule("Roster", true)
    return Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil
end

local function hasJoinDate(player)
    return type(player.firstSeen) == "number" and player.firstSeen > 0 and not player.joinDateUnknown
end

local function hasBirthday(player)
    local Roster = GP:GetModule("Roster", true)
    if not Roster or not Roster.GetBirthday then return false end
    local day, month = Roster:GetBirthday(player)
    return day ~= nil and month ~= nil
end

local function safeEventLog()
    return GP:GetModule("EventLog", true)
end

local function currentRegion()
    if type(GetCurrentRegion) ~= "function" then return nil end
    local ok, region = pcall(GetCurrentRegion)
    return ok and tonumber(region) or nil
end

local function parseDateText(text)
    text = tostring(text or "")
    local year, month, day, hour, minute = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d?):(%d%d)$")
    if not year then
        year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        hour, minute = DEFAULT_SEASON_START_HOUR, 0
    end
    year, month, day, hour, minute = tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute)
    if not year or not month or not day then return nil end
    if year < 2024 or year > 2099 or month < 1 or month > 12 or day < 1 or day > 31 or hour < 0 or hour > 23 or minute < 0 or minute > 59 then return nil end
    local ts = time({ year = year, month = month, day = day, hour = hour, min = minute })
    local check = date("*t", ts)
    if not check or check.year ~= year or check.month ~= month or check.day ~= day or check.hour ~= hour or check.min ~= minute then return nil end
    return ts
end

local function defaultSeasonStartDate(region)
    return MYTHIC_SEASON_START_BY_REGION[region] or MYTHIC_SEASON_START_BY_REGION[1]
end

local function normalizedDateText(text)
    local ts = parseDateText(text)
    return ts and date("%Y-%m-%d %H:%M", ts) or nil
end

local function currentMythicSeasonStart()
    local settings = GuildHealth:GetSettings()
    return parseDateText(settings.mythicSeasonStartDate) or parseDateText(defaultSeasonStartDate(currentRegion()))
end

local function loggedInSince(player, sinceTs)
    if not player or type(sinceTs) ~= "number" then return true end
    if player.online then
        return type(player.onlineSince) == "number" and player.onlineSince >= sinceTs
    end

    local hours = tonumber(player.lastOnline)
    if not hours then return false end
    if hours <= 0 then return time() >= sinceTs end

    return (time() - (hours * 60 * 60)) >= sinceTs
end

local function normalizeRankName(name)
    name = strtrim(tostring(name or ""))
    return name ~= "" and name:lower() or ""
end

local function currentRankSince(player)
    if not player then return nil end
    local currentRank = normalizeRankName(player.rankName)
    for i = #(player.rankHistory or {}), 1, -1 do
        local entry = player.rankHistory[i]
        if entry and normalizeRankName(entry.rankName) == currentRank and type(entry.ts) == "number" then
            return entry.ts
        end
    end
    return type(player.firstSeen) == "number" and player.firstSeen or nil
end

function GuildHealth:GetSettings()
    GP.db.profile.guildHealth = GP.db.profile.guildHealth or {}
    local s = GP.db.profile.guildHealth
    if s.showBirthdayIssues == nil then s.showBirthdayIssues = true end
    if s.ignoreAltsWhenMainActive == nil then s.ignoreAltsWhenMainActive = true end
    if s.newMemberCheckNote == nil then s.newMemberCheckNote = true end
    if s.newMemberCheckLabel == nil then s.newMemberCheckLabel = true end
    if s.newMemberCheckBirthday == nil then s.newMemberCheckBirthday = true end
    if s.newMemberCheckAltMain == nil then s.newMemberCheckAltMain = true end
    local region = currentRegion()
    s.mythicSeasonStartDate = normalizedDateText(s.mythicSeasonStartDate) or defaultSeasonStartDate(region)
    s.activeDays = math.max(1, tonumber(s.activeDays) or 7)
    s.fadingDays = math.max(s.activeDays + 1, tonumber(s.fadingDays) or 14)
    s.atRiskDays = math.max(s.fadingDays + 1, tonumber(s.atRiskDays) or 30)
    s.goneDays = math.max(s.atRiskDays + 1, tonumber(s.goneDays) or 60)
    s.newMemberWindowDays = math.max(1, tonumber(s.newMemberWindowDays) or NEW_MEMBER_DAYS)
    s.newMemberPromotionDays = math.max(0, tonumber(s.newMemberPromotionDays) or 0)
    s.newMemberRankName = strtrim(tostring(s.newMemberRankName or ""))
    s.newMemberPromotionRankIndex = tonumber(s.newMemberPromotionRankIndex)
    return s
end

function GuildHealth:SaveSettings(values)
    local s = self:GetSettings()
    if type(values) ~= "table" then return s end

    if values.showBirthdayIssues ~= nil then s.showBirthdayIssues = values.showBirthdayIssues and true or false end
    if values.ignoreAltsWhenMainActive ~= nil then s.ignoreAltsWhenMainActive = values.ignoreAltsWhenMainActive and true or false end
    if values.activeDays ~= nil then s.activeDays = tonumber(values.activeDays) or s.activeDays end
    if values.fadingDays ~= nil then s.fadingDays = tonumber(values.fadingDays) or s.fadingDays end
    if values.atRiskDays ~= nil then s.atRiskDays = tonumber(values.atRiskDays) or s.atRiskDays end
    if values.goneDays ~= nil then s.goneDays = tonumber(values.goneDays) or s.goneDays end
    if values.mythicSeasonStartDate ~= nil then s.mythicSeasonStartDate = tostring(values.mythicSeasonStartDate or "") end
    if values.newMemberWindowDays ~= nil then s.newMemberWindowDays = tonumber(values.newMemberWindowDays) or s.newMemberWindowDays end
    if values.newMemberRankName ~= nil then s.newMemberRankName = tostring(values.newMemberRankName or "") end
    if values.newMemberPromotionRankIndex ~= nil then s.newMemberPromotionRankIndex = tonumber(values.newMemberPromotionRankIndex) end
    if values.newMemberPromotionDays ~= nil then s.newMemberPromotionDays = tonumber(values.newMemberPromotionDays) or s.newMemberPromotionDays end
    if values.newMemberCheckNote ~= nil then s.newMemberCheckNote = values.newMemberCheckNote and true or false end
    if values.newMemberCheckLabel ~= nil then s.newMemberCheckLabel = values.newMemberCheckLabel and true or false end
    if values.newMemberCheckBirthday ~= nil then s.newMemberCheckBirthday = values.newMemberCheckBirthday and true or false end
    if values.newMemberCheckAltMain ~= nil then s.newMemberCheckAltMain = values.newMemberCheckAltMain and true or false end
    self:GetSettings()
    GP:SendMessage("GuildParagon_GuildHealthSettingsChanged")
    return s
end

local function activeAltCounts(guildData, guildKey, guid)
    local Alts = GP:GetModule("Alts", true)
    if not Alts then return 0, 0 end

    local active, former = 0, 0
    for _, altGUID in ipairs(Alts:GetAlts(guildKey, guid) or {}) do
        if guildData.roster and guildData.roster[altGUID] then
            active = active + 1
        elseif guildData.formerMembers and guildData.formerMembers[altGUID] then
            former = former + 1
        end
    end
    return active, former
end

local function isTagged(guildData, guildKey, guid)
    local Alts = GP:GetModule("Alts", true)
    if not Alts then return false end
    return Alts:GetMain(guildKey, guid) ~= nil or Alts:IsMain(guildKey, guid)
end

local function addRow(rows, counts, row)
    counts.total = counts.total + 1
    counts[row.reasonKey] = (counts[row.reasonKey] or 0) + 1
    table.insert(rows, row)
end

local function addCounts(target, source)
    target.total = (target.total or 0) + (source.total or 0)
    for key, value in pairs(source or {}) do
        if key ~= "total" then
            target[key] = (target[key] or 0) + value
        end
    end
end

local function sortRows(rows, categoryFirst)
    table.sort(rows, function(a, b)
        if categoryFirst then
            local ac = ATTENTION_CATEGORY_ORDER[a.category] or 99
            local bc = ATTENTION_CATEGORY_ORDER[b.category] or 99
            if ac ~= bc then return ac < bc end
        end
        local av = SEVERITY_ORDER[a.severity] or 99
        local bv = SEVERITY_ORDER[b.severity] or 99
        if av ~= bv then return av < bv end
        local an, bn = tostring(a.name or ""), tostring(b.name or "")
        if an ~= bn then return an < bn end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
end

local function capRows(rows, categoryFirst)
    sortRows(rows, categoryFirst)
    local visibleRows = {}
    for i = 1, math.min(#rows, ATTENTION_LIMIT) do
        visibleRows[i] = rows[i]
    end
    return visibleRows
end

local function buildHygieneRows(guildData, guildKey)
    local rows = {}
    local counts = { total = 0 }
    local settings = GuildHealth:GetSettings()
    for guid, player in pairs(guildData.roster or {}) do
        local name = player.name or GP.L["Unknown"]
        if settings.showBirthdayIssues and not hasBirthday(player) then
            addRow(rows, counts, {
                id = "cleanup:birthday:" .. guid,
                category = "cleanup",
                severity = "warning",
                reasonKey = "birthday",
                title = string.format(GP.L["%s is missing a birthday"], name),
                detail = GP.L["Roster profile has no birthday recorded."],
                source = GP.L["Roster profile"],
                guid = guid,
                name = name,
            })
        end

        if not isTagged(guildData, guildKey, guid) then
            addRow(rows, counts, {
                id = "cleanup:tag:" .. guid,
                category = "cleanup",
                severity = "warning",
                reasonKey = "tag",
                title = string.format(GP.L["%s needs an alt/main tag"], name),
                detail = GP.L["Character is not marked as a main and is not linked as an alt."],
                source = GP.L["Alt/main data"],
                guid = guid,
                name = name,
            })
        end

        if not hasJoinDate(player) then
            addRow(rows, counts, {
                id = "cleanup:joinmissing:" .. guid,
                category = "cleanup",
                severity = "warning",
                reasonKey = "joinMissing",
                title = string.format(GP.L["%s is missing a join date"], name),
                detail = GP.L["Join date is missing or marked unknown."],
                source = GP.L["Roster profile"],
                guid = guid,
                name = name,
            })
        elseif player.joinDateSource == nil or player.joinDateSource == "firstseen" then
            addRow(rows, counts, {
                id = "cleanup:joinunconfirmed:" .. guid,
                category = "cleanup",
                severity = "info",
                reasonKey = "joinUnconfirmed",
                title = string.format(GP.L["%s has an unconfirmed join date"], name),
                detail = GP.L["Join date is based on first seen data, not a roster-log, note import, or manual confirmation."],
                source = GP.L["Roster profile"],
                guid = guid,
                name = name,
            })
        end

        local activeAlts, formerAlts = activeAltCounts(guildData, guildKey, guid)
        if activeAlts == 0 and formerAlts > 0 then
            addRow(rows, counts, {
                id = "cleanup:formeralts:" .. guid,
                category = "cleanup",
                severity = "info",
                reasonKey = "formerAlts",
                title = string.format(GP.L["%s only has former linked alts"], name),
                detail = string.format(GP.L["%d former linked alt(s) remain in history; no linked alts are currently in the guild."], formerAlts),
                source = GP.L["Alt/main data"],
                guid = guid,
                name = name,
            })
        end
    end

    sortRows(rows)
    return rows, counts
end

local function offlineDays(player)
    if not player or player.online then return nil end
    local hours = tonumber(player.lastOnline)
    if not hours then return nil end
    if hours <= 0 then return 0 end
    return math.floor(hours / 24)
end

activeWithinDays = function(player, days)
    if not player then return false end
    if player.online then return true end
    local offline = offlineDays(player)
    return offline ~= nil and offline < days
end

local function buildLinkedActivityGroups(guildData, days)
    local groups, groupByGUID = {}, {}
    for guid, player in pairs(guildData.roster or {}) do
        local mainGUID = guildData.alts and guildData.alts[guid] or nil
        local key = mainGUID or guid
        local group = groups[key]
        if not group then
            group = {
                guid = key,
                displayGUID = key,
                displayPlayer = (guildData.roster and guildData.roster[key]) or (guildData.formerMembers and guildData.formerMembers[key]),
                active = false,
                latestDays = nil,
                members = {},
            }
            groups[key] = group
        end

        table.insert(group.members, { guid = guid, player = player })
        groupByGUID[key] = group
        groupByGUID[guid] = group
        if guid == key or not group.displayPlayer then
            group.displayGUID = guid
            group.displayPlayer = player
        end
        if activeWithinDays(player, days) then
            group.active = true
        end

        local memberDays = offlineDays(player)
        if memberDays and (not group.latestDays or memberDays < group.latestDays) then
            group.latestDays = memberDays
        end
    end
    return groups, groupByGUID
end

local function buildLinkedActivityContext(guildData, days)
    local _, groupByGUID = buildLinkedActivityGroups(guildData, days)
    return groupByGUID
end

local function linkedGroupActive(activityContext, guid)
    local group = activityContext and activityContext[guid]
    return group and group.active or false
end

local function buildMacroIgnoreContext(guildData)
    local groups, groupByGUID = {}, {}
    for guid in pairs(guildData.roster or {}) do
        local key = guildData.alts and guildData.alts[guid] or guid
        groups[key] = groups[key] or { actions = {} }
        groupByGUID[key] = groups[key]
        groupByGUID[guid] = groups[key]
    end
    for guid, ignore in pairs(guildData.macroIgnores or {}) do
        local key = guildData.alts and guildData.alts[guid] or guid
        groups[key] = groups[key] or { actions = {} }
        groupByGUID[key] = groups[key]
        groupByGUID[guid] = groups[key]
        if type(ignore) == "table" then
            for action, enabled in pairs(ignore) do
                if enabled then groups[key].actions[action] = true end
            end
        end
    end
    return groupByGUID
end

local function macroIgnored(ignoreContext, guid, action)
    local group = ignoreContext and ignoreContext[guid]
    return group and group.actions and group.actions[action] or false
end

local function shouldSuppressAltActivity(guid, settings, activityContext)
    if not settings.ignoreAltsWhenMainActive then return false end
    return linkedGroupActive(activityContext, guid)
end

local function buildActivityRows(guildData, guildKey, context)
    local rows = {}
    local counts = { total = 0 }
    local settings = (context and context.settings) or GuildHealth:GetSettings()
    local activityGroups = context and context.activityGroups or buildLinkedActivityGroups(guildData, settings.activeDays)
    local ignoreContext = context and context.ignoreContext or buildMacroIgnoreContext(guildData)
    for _, group in pairs(activityGroups) do
        local guid = group.displayGUID or group.guid
        local player = group.displayPlayer
        local days = group.latestDays
        if days and days >= settings.fadingDays
            and not macroIgnored(ignoreContext, guid, "kick")
            and not (settings.ignoreAltsWhenMainActive and group.active) then
            local severity, tier
            if days >= settings.goneDays then
                severity, tier = "critical", string.format(GP.L["%d+ days offline"], settings.goneDays)
            elseif days >= settings.atRiskDays then
                severity, tier = "warning", string.format(GP.L["%d+ days offline"], settings.atRiskDays)
            else
                severity, tier = "info", string.format(GP.L["%d+ days offline"], settings.fadingDays)
            end

            local name = player.name or GP.L["Unknown"]
            addRow(rows, counts, {
                id = "activity:offline:" .. guid,
                category = "activity",
                severity = severity,
                reasonKey = "offline",
                title = string.format(GP.L["%s's group is %d day(s) offline"], name, days),
                detail = string.format(GP.L["Highest inactivity tier crossed: %s."], tier),
                source = GP.L["Roster last online"],
                guid = guid,
                name = name,
                members = group.members,
            })
        end
    end

    sortRows(rows)
    return rows, counts
end

local function hasAnyNote(guildKey, guid, player)
    if type(player.note) == "string" and strtrim(player.note) ~= "" then return true end
    local CustomNotes = GP:GetModule("CustomNotes", true)
    local custom = CustomNotes and CustomNotes.Get and CustomNotes:Get(guildKey, guid) or nil
    return type(custom) == "string" and strtrim(custom) ~= ""
end

local function hasAnyLabel(guildKey, guid)
    local Labels = GP:GetModule("Labels", true)
    if not Labels or not Labels.GetLabelsForPlayer then return false end
    return #(Labels:GetLabelsForPlayer(guildKey, guid) or {}) > 0
end

local function buildNewMemberRows(guildData, guildKey, context)
    local rows = {}
    local counts = { total = 0 }
    local settings = (context and context.settings) or GuildHealth:GetSettings()
    local now = time()
    local cutoff = now - (settings.newMemberWindowDays * 24 * 60 * 60)
    local rankFilter = normalizeRankName(settings.newMemberRankName)
    local ignoreContext = context and context.ignoreContext or buildMacroIgnoreContext(guildData)

    for guid, player in pairs(guildData.roster or {}) do
        local rankMatches = rankFilter == "" or normalizeRankName(player.rankName) == rankFilter
        if rankMatches and type(player.firstSeen) == "number" and player.firstSeen >= cutoff then
            local missing = {}
            if settings.newMemberCheckNote and not hasAnyNote(guildKey, guid, player) then table.insert(missing, GP.L["note"]) end
            if settings.newMemberCheckLabel and not hasAnyLabel(guildKey, guid) then table.insert(missing, GP.L["label"]) end
            if settings.newMemberCheckBirthday and settings.showBirthdayIssues and not hasBirthday(player) then table.insert(missing, GP.L["birthday"]) end
            if settings.newMemberCheckAltMain and not isTagged(guildData, guildKey, guid) then table.insert(missing, GP.L["alt/main tag"]) end
            if settings.newMemberPromotionDays > 0 and rankFilter ~= "" and not macroIgnored(ignoreContext, guid, "promote") then
                local rankSince = currentRankSince(player)
                local daysInRank = rankSince and math.max(0, math.floor((now - rankSince) / (24 * 60 * 60))) or 0
                if rankSince and daysInRank >= settings.newMemberPromotionDays then
                    table.insert(missing, GP.L["promotion review"])
                end
            end

            if #missing > 0 then
                local name = player.name or GP.L["Unknown"]
                local ageDays = math.max(0, math.floor((now - player.firstSeen) / (24 * 60 * 60)))
                local hasPromotionReview = false
                for _, reason in ipairs(missing) do
                    if reason == GP.L["promotion review"] then
                        hasPromotionReview = true
                        break
                    end
                end
                local promotionOnly = #missing == 1 and hasPromotionReview
                if hasPromotionReview and not promotionOnly then
                    counts.promotionReview = (counts.promotionReview or 0) + 1
                end
                addRow(rows, counts, {
                    id = "newmember:followup:" .. guid,
                    category = "newmember",
                    severity = #missing >= 3 and "warning" or "info",
                    reasonKey = promotionOnly and "promotionReview" or "newMemberFollowup",
                    title = promotionOnly and string.format(GP.L["%s needs promotion review"], name) or string.format(GP.L["%s needs new-member follow-up"], name),
                    detail = promotionOnly and string.format(GP.L["Joined %d day(s) ago; needs promotion review."], ageDays) or string.format(GP.L["Joined %d day(s) ago; missing %s."], ageDays, table.concat(missing, ", ")),
                    source = GP.L["Roster profile"],
                    guid = guid,
                    name = name,
                    promotionReview = hasPromotionReview,
                })
            end
        end
    end

    sortRows(rows)
    return rows, counts
end

local function percent(part, total)
    if not total or total <= 0 then return 0 end
    return math.floor((part / total) * 100 + 0.5)
end

local function activeRosterCount(guildData)
    local count = 0
    for _ in pairs(guildData.roster or {}) do
        count = count + 1
    end
    return count
end

local function countActivityGroups(groups)
    local total, active = 0, 0
    for _, group in pairs(groups or {}) do
        total = total + 1
        if group.active then
            active = active + 1
        end
    end
    return active, total
end

local function buildSummaryContext(guildData, settings)
    local groupsByDays = {}
    local function groupsForDays(days)
        days = tonumber(days) or 0
        if not groupsByDays[days] then
            groupsByDays[days] = buildLinkedActivityGroups(guildData, days)
        end
        return groupsByDays[days]
    end

    return {
        settings = settings,
        activityGroups = groupsForDays(settings.activeDays),
        active30Groups = groupsForDays(30),
        active3Groups = groupsForDays(3),
        ignoreContext = buildMacroIgnoreContext(guildData),
    }
end

local function riskBandForGroup(group, settings, ignoreContext)
    local guid = group and (group.displayGUID or group.guid)
    if not guid then return nil end
    if group.active then return "active" end
    if macroIgnored(ignoreContext, guid, "kick") then return nil end

    local days = group.latestDays
    if not days then return "unknown" end
    if days >= settings.goneDays then return "gone" end
    if days >= settings.atRiskDays then return "atRisk" end
    if days >= settings.fadingDays then return "fading" end
    return "cooling"
end

local function buildRetentionRisk(guildData, guildKey, settings, context)
    local bands = {
        active = { key = "active", label = string.format(GP.L["Active (<%d days)"], settings.activeDays), count = 0, color = "success" },
        cooling = { key = "cooling", label = string.format(GP.L["Cooling (%d-%d days)"], settings.activeDays, settings.fadingDays - 1), count = 0, color = "warning" },
        fading = { key = "fading", label = string.format(GP.L["Fading (%d-%d days)"], settings.fadingDays, settings.atRiskDays - 1), count = 0, color = "warning" },
        atRisk = { key = "atRisk", label = string.format(GP.L["At Risk (%d-%d days)"], settings.atRiskDays, settings.goneDays - 1), count = 0, color = "danger" },
        gone = { key = "gone", label = string.format(GP.L["Gone (%d+ days)"], settings.goneDays), count = 0, color = "textDisabled" },
        unknown = { key = "unknown", label = GP.L["Unknown"], count = 0, color = "textSecondary" },
    }

    local activityGroups = context and context.activityGroups or buildLinkedActivityGroups(guildData, settings.activeDays)
    local ignoreContext = context and context.ignoreContext or buildMacroIgnoreContext(guildData)
    for _, group in pairs(activityGroups) do
        local band = riskBandForGroup(group, settings, ignoreContext)
        if band and bands[band] then
            bands[band].count = bands[band].count + 1
        end
    end

    return {
        bands.active,
        bands.cooling,
        bands.fading,
        bands.atRisk,
        bands.gone,
        bands.unknown,
    }
end

local function classDisplayName(classFile)
    if type(classFile) ~= "string" or classFile == "" then return GP.L["Unknown"] end
    local localized = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
    if localized then return localized end
    return classFile:sub(1, 1) .. classFile:sub(2):lower()
end

local function classColor(classFile)
    local c = classFile and C_ClassColor and C_ClassColor.GetClassColor(classFile)
    c = c or (classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
    if c then return { c.r, c.g, c.b, 1 } end
    return { 0.541, 0.561, 0.612, 1 }
end

local function buildRosterComposition(guildData, settings)
    local byClass = {}
    for _, player in pairs(guildData.roster or {}) do
        local classFile = player.class or "UNKNOWN"
        local record = byClass[classFile]
        if not record then
            record = {
                classFile = classFile,
                label = classDisplayName(classFile),
                color = classColor(classFile),
                active = 0,
                total = 0,
            }
            byClass[classFile] = record
        end
        record.total = record.total + 1
        if activeWithinDays(player, settings.activeDays) then
            record.active = record.active + 1
        end
    end

    local rows = {}
    for _, record in pairs(byClass) do table.insert(rows, record) end
    table.sort(rows, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return tostring(a.label) < tostring(b.label)
    end)
    return rows
end

local function buildMythicRatings(guildData)
    local buckets = {
        { key = "none", label = GP.L["No Rating"], count = 0 },
        { key = "low", label = GP.L["1 - 1999"], count = 0 },
        { key = "mid", label = GP.L["2000 - 2499"], count = 0 },
        { key = "high", label = GP.L["2500 - 2999"], count = 0 },
        { key = "elite", label = GP.L["3000 - 3399"], count = 0 },
        { key = "top", label = GP.L["3400+"], count = 0 },
    }
    local total, rated, sum = 0, 0, 0
    local seasonStart = currentMythicSeasonStart()
    for _, player in pairs(guildData.roster or {}) do
        total = total + 1
        local score = tonumber(player.mythicScore) or 0
        if score > 0 and not loggedInSince(player, seasonStart) then
            score = 0
        end
        if score <= 0 then
            buckets[1].count = buckets[1].count + 1
        elseif score < 2000 then
            buckets[2].count = buckets[2].count + 1
            rated, sum = rated + 1, sum + score
        elseif score < 2500 then
            buckets[3].count = buckets[3].count + 1
            rated, sum = rated + 1, sum + score
        elseif score < 3000 then
            buckets[4].count = buckets[4].count + 1
            rated, sum = rated + 1, sum + score
        elseif score < 3400 then
            buckets[5].count = buckets[5].count + 1
            rated, sum = rated + 1, sum + score
        else
            buckets[6].count = buckets[6].count + 1
            rated, sum = rated + 1, sum + score
        end
    end
    return {
        total = total,
        rated = rated,
        average = rated > 0 and math.floor(sum / rated + 0.5) or 0,
        buckets = buckets,
    }
end

local function buildGrowthTrend(guildData, guildKey, total)
    local EventLog = safeEventLog()
    local log = EventLog and EventLog:GetLog(guildKey) or nil
    if type(log) ~= "table" then return { joins = 0, leaves = 0, score = 50 } end

    local oldest = time() - (30 * 24 * 60 * 60)
    local joins, leaves = 0, 0
    for i = #log, 1, -1 do
        local entry = log[i]
        if type(entry) == "table" and type(entry.ts) == "number" then
            if entry.ts < oldest then break end
            if entry.type == "join" then joins = joins + 1 end
            if entry.type == "leave" or entry.type == "removed" then leaves = leaves + 1 end
        end
    end

    total = math.max(1, tonumber(total) or activeRosterCount(guildData))
    local score = math.max(0, math.min(100, 50 + percent(joins - leaves, total)))
    return { joins = joins, leaves = leaves, score = score }
end

local function buildOverview(guildData, guildKey, context)
    local settings = (context and context.settings) or GuildHealth:GetSettings()
    local active7, total = countActivityGroups(context and context.activityGroups or buildLinkedActivityGroups(guildData, settings.activeDays))
    local active30 = countActivityGroups(context and context.active30Groups or buildLinkedActivityGroups(guildData, 30))
    local active3 = countActivityGroups(context and context.active3Groups or buildLinkedActivityGroups(guildData, 3))

    local risk = buildRetentionRisk(guildData, guildKey, settings, context)
    local growth = buildGrowthTrend(guildData, guildKey, total)
    local activePct = percent(active7, total)
    local retentionPct = percent(active30, total)
    local engagementPct = percent(active3, total)
    local score = math.floor((activePct + retentionPct + growth.score + engagementPct) / 4 + 0.5)

    return {
        vitality = {
            score = score,
            total = total,
            active = active7,
            activePct = activePct,
            retentionPct = retentionPct,
            growthPct = growth.score,
            engagementPct = engagementPct,
            growthJoins = growth.joins,
            growthLeaves = growth.leaves,
        },
        retentionRisk = risk,
        rosterComposition = buildRosterComposition(guildData, settings),
        mythicRatings = buildMythicRatings(guildData),
    }
end

local function normalizedRecruiter(name)
    name = tostring(name or "")
    return name ~= "" and name or GP.L["Unknown"]
end

local function classifyRecruit(guildData, guid)
    if guid and guildData.roster and guildData.roster[guid] then return "retained" end
    if guid and guildData.formerMembers and guildData.formerMembers[guid] then return "left" end
    return "unknown"
end

local function ensureRecruiter(summary, recruiter)
    summary[recruiter] = summary[recruiter] or {
        recruiter = recruiter,
        cohorts = {},
    }
    local record = summary[recruiter]
    for _, days in ipairs(RETENTION_COHORTS) do
        record.cohorts[days] = record.cohorts[days] or {
            tracked = 0,
            retained = 0,
            left = 0,
            rejoined = 0,
            tooNew = 0,
            judged = 0,
            unknown = 0,
        }
    end
    return record
end

function GuildHealth:CanUse()
    return GP:IsOfficer()
end

function GuildHealth:GetRecruiterRetentionSummary(guildKey, options)
    guildKey = guildKey or defaultGuildKey()
    local guildData = guildDataFor(guildKey)
    local EventLog = safeEventLog()
    local log = EventLog and EventLog:GetLog(guildKey) or nil
    local selectedCohort = tonumber(options and options.cohortDays) or 30
    if not guildData or type(log) ~= "table" then
        return { cohorts = RETENTION_COHORTS, selectedCohort = selectedCohort, recruiters = {}, totalRecruiters = 0, tooNew = 0 }
    end

    local now = time()
    local oldest = now - (MAX_SCAN_DAYS * 24 * 60 * 60)
    local latestByGUID = {}

    for i = #log, 1, -1 do
        local entry = log[i]
        if type(entry) == "table" and type(entry.ts) == "number" then
            if entry.ts < oldest then break end
            if entry.type == "join" and entry.guid and entry.invitedBy and entry.invitedBy ~= ""
                and not (EventLog.IsRemoved and EventLog:IsRemoved(guildKey, entry))
                and not latestByGUID[entry.guid] then
                latestByGUID[entry.guid] = entry
            end
        end
    end

    local byRecruiter = {}
    local totalTooNew = 0
    for guid, entry in pairs(latestByGUID) do
        local recruiter = normalizedRecruiter(entry.invitedBy)
        local record = ensureRecruiter(byRecruiter, recruiter)
        local ageDays = math.max(0, math.floor((now - entry.ts) / (24 * 60 * 60)))
        local state = classifyRecruit(guildData, guid)

        for _, days in ipairs(RETENTION_COHORTS) do
            if ageDays <= days then
                local cohort = record.cohorts[days]
                cohort.tracked = cohort.tracked + 1
                if entry.rejoin then cohort.rejoined = cohort.rejoined + 1 end
                if ageDays < MIN_JUDGED_DAYS then
                    cohort.tooNew = cohort.tooNew + 1
                    if days == selectedCohort then totalTooNew = totalTooNew + 1 end
                else
                    cohort.judged = cohort.judged + 1
                    cohort[state] = (cohort[state] or 0) + 1
                end
            end
        end
    end

    local recruiters = {}
    for _, record in pairs(byRecruiter) do
        for _, days in ipairs(RETENTION_COHORTS) do
            local cohort = record.cohorts[days]
            if cohort.judged >= 3 then
                cohort.retentionPct = math.floor(((cohort.retained or 0) / cohort.judged) * 100 + 0.5)
            end
        end
        table.insert(recruiters, record)
    end

    table.sort(recruiters, function(a, b)
        local ac = a.cohorts[selectedCohort] or a.cohorts[30]
        local bc = b.cohorts[selectedCohort] or b.cohorts[30]
        if (ac.tracked or 0) ~= (bc.tracked or 0) then return (ac.tracked or 0) > (bc.tracked or 0) end
        return tostring(a.recruiter) < tostring(b.recruiter)
    end)

    return {
        cohorts = RETENTION_COHORTS,
        selectedCohort = selectedCohort,
        recruiters = recruiters,
        totalRecruiters = #recruiters,
        tooNew = totalTooNew,
    }
end

function GuildHealth:GetSummary(guildKey, options)
    guildKey = guildKey or defaultGuildKey()
    local guildData = guildDataFor(guildKey)
    if not guildData then
        return {
            cards = { attention = 0, hygiene = GP.L["0 cleanup items"], newMember = 0 },
            rows = {},
            rowTotal = 0,
            hygieneCounts = {},
            activityCounts = {},
            newMemberCounts = {},
            rowsByCategory = { cleanup = {}, activity = {}, newmember = {} },
            totalsByCategory = { cleanup = 0, activity = 0, newmember = 0 },
            retention = self:GetRecruiterRetentionSummary(guildKey, options),
            overview = {
                vitality = { score = 0, total = 0, active = 0, activePct = 0, retentionPct = 0, growthPct = 0, engagementPct = 0, growthJoins = 0, growthLeaves = 0 },
                retentionRisk = {},
                rosterComposition = {},
                mythicRatings = { total = 0, rated = 0, average = 0, buckets = {} },
            },
        }
    end

    local settings = self:GetSettings()
    local summaryContext = buildSummaryContext(guildData, settings)
    local hygieneRows, hygieneCounts = buildHygieneRows(guildData, guildKey)
    local activityRows, activityCounts = buildActivityRows(guildData, guildKey, summaryContext)
    local newMemberRows, newMemberCounts = buildNewMemberRows(guildData, guildKey, summaryContext)
    local allRows, totalCounts = {}, { total = 0 }
    for _, row in ipairs(hygieneRows) do table.insert(allRows, row) end
    for _, row in ipairs(activityRows) do table.insert(allRows, row) end
    for _, row in ipairs(newMemberRows) do table.insert(allRows, row) end
    addCounts(totalCounts, hygieneCounts)
    addCounts(totalCounts, activityCounts)
    addCounts(totalCounts, newMemberCounts)

    local retention = self:GetRecruiterRetentionSummary(guildKey, options)
    return {
        cards = {
            attention = totalCounts.total,
            hygiene = string.format(GP.L["%d cleanup item(s)"], hygieneCounts.total),
            newMember = newMemberCounts.promotionReview or 0,
        },
        rows = capRows(allRows, true),
        rowTotal = totalCounts.total,
        rowLimit = ATTENTION_LIMIT,
        rowsByCategory = {
            cleanup = capRows(hygieneRows),
            activity = capRows(activityRows),
            newmember = capRows(newMemberRows),
        },
        totalsByCategory = {
            cleanup = hygieneCounts.total,
            activity = activityCounts.total,
            newmember = newMemberCounts.total,
        },
        hygieneCounts = hygieneCounts,
        activityCounts = activityCounts,
        newMemberCounts = newMemberCounts,
        retention = retention,
        overview = buildOverview(guildData, guildKey, summaryContext),
    }
end
