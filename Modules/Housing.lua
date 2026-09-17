-- Guild Paragon - Housing ownership scan
local _, GP = ...

local Housing = GP:NewModule("Housing", "AceEvent-3.0")

local LIST_TIMEOUT = 8
local SWEEP_GAP = 1
local SWEEP_TIMEOUT = 8
local SWEEP_QUARANTINE = 8
local MAX_DEBUG_UNMATCHED = 12
local AUTO_SCAN_TTL = 24 * 60 * 60
local VISIT_LOOKUP_TIMEOUT = 8
local LEGACY_OWNERSHIP = {}

local scan
local listTimer
local sweepTimer
local holdTimer
local autoScanRequested = {}
local visitByAddress = {}
local visitLookup
local visitLookupTimer
local neighborhoodListReady = false
local neighborhoodListRequested = false

local function guildKey()
    local Roster = GP:GetModule("Roster", true)
    return Roster and (Roster.currentGuildKey or Roster:GetGuildKey()) or nil
end

local function guildDataFor(key)
    return key and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[key] or nil
end

local function ensureHousing(guildData)
    guildData.housing = guildData.housing or {}
    guildData.housing.plotOwners = guildData.housing.plotOwners or {}
    guildData.housing.unmatchedOwners = guildData.housing.unmatchedOwners or {}
    guildData.housing.neighborhoods = guildData.housing.neighborhoods or {}
    return guildData.housing
end

local function clearTimer(timer)
    if timer then timer:Cancel() end
end

local function clearTimers()
    clearTimer(listTimer)
    clearTimer(sweepTimer)
    clearTimer(holdTimer)
    listTimer, sweepTimer, holdTimer = nil, nil, nil
end

local function bareName(name)
    name = GP:SafeOptionalString(name)
    if not name or name == "" then return nil end
    return name:match("^([^-]+)") or name
end

local function ownerName(plot)
    return bareName(plot and plot.ownerName)
end

local function newStats()
    return {
        subdivisions = 0,
        replies = 0,
        plots = 0,
        namedOwners = 0,
        matched = 0,
        unmatched = 0,
        emptyReplies = 0,
        badReplies = 0,
        requestFailed = 0,
        timedOut = 0,
        missing = 0,
        ambiguous = 0,
        linkedAmbiguous = 0,
    }
end

local function scanSummary(status, stats)
    return string.format(
        GP.L["Housing scan %s: %d subdivision(s), %d plot(s), %d named owner(s), %d matched, %d unmatched."],
        status or "unknown",
        stats and stats.subdivisions or 0,
        stats and stats.plots or 0,
        stats and stats.namedOwners or 0,
        stats and stats.matched or 0,
        stats and stats.unmatched or 0
    )
end

local function notify()
    if not scan then return end
    GP:SendMessage("GuildParagon_HousingScanUpdated", scan.guildKey, scan.done or 0, scan.total or 0, scan.status)
end

local function finish(status, message)
    clearTimers()
    local active = scan
    scan = nil
    if active then
        active.status = status
        local guildData = guildDataFor(active.guildKey)
        if guildData then
            local housing = ensureHousing(guildData)
            housing.lastScanStatus = status
            housing.lastScanMessage = message
            housing.lastScanStats = active.stats or newStats()
            housing.lastScanUnmatchedOwners = active.unmatched or {}
            if status == "complete" then
                housing.plotOwners = active.owners or {}
                housing.unmatchedOwners = active.unmatched or {}
                housing.neighborhoods = active.neighborhoods or {}
                housing.lastScan = time()
            end
        end
        if not active.silent then
            GP:Print(scanSummary(status, active.stats))
            if active.stats and active.stats.namedOwners > 0 and active.stats.matched == 0 then
                GP:Print(GP.L["Housing scan matched no roster members. Run /gp housingdebug to show sampled owner names."])
            elseif message and message ~= "" then
                GP:Print(message)
            end
        end
        GP:SendMessage("GuildParagon_HousingChanged", active.guildKey, status, message)
    end
end

local function queueEntry(info)
    if not info or not info.neighborhoodGUID or not info.neighborhoodName or info.neighborhoodName == "" then
        return nil
    end
    local reason = Enum and Enum.HouseFinderSuggestionReason
    if not reason or info.suggestionReason ~= reason.Guild then return nil end
    return {
        guid = info.neighborhoodGUID,
        name = info.neighborhoodName,
        ordinal = nil,
    }
end

local function buildQueue(neighborhoodInfos)
    local queue = {}
    local ordinal = 0
    for _, info in ipairs(neighborhoodInfos or {}) do
        local entry = queueEntry(info)
        if entry then
            ordinal = ordinal + 1
            entry.ordinal = ordinal
            queue[#queue + 1] = entry
        end
    end
    return queue
end

local function addNameCandidate(bucket, key, guid, player)
    if key == "" then return end
    local current = bucket[key]
    local candidate = { guid = guid, player = player }
    if current == nil then
        bucket[key] = candidate
    elseif current.ambiguous then
        current.candidates[#current.candidates + 1] = candidate
    else
        bucket[key] = {
            ambiguous = true,
            candidates = { current, candidate },
        }
    end
end

local function buildRosterNameIndex(guildData)
    local Roster = GP:GetModule("Roster", true)
    local index = { exact = {}, short = {}, rosterCount = 0 }
    if not Roster or not guildData then return index end

    for guid, player in pairs(guildData.roster or {}) do
        local name = player and player.name
        local exact = Roster:NormalizePlayerName(name)
        local short = Roster:NormalizePlayerName(Roster:ShortName(name))
        if exact ~= "" then
            index.rosterCount = index.rosterCount + 1
            addNameCandidate(index.exact, exact, guid, player)
        end
        addNameCandidate(index.short, short, guid, player)
    end
    return index
end

local function resolveLinkedAmbiguity(active, match)
    local candidates = match and match.candidates
    if not candidates or #candidates == 0 then return nil, nil, "ambiguous" end

    local Alts = GP:GetModule("Alts", true)
    if not Alts then return nil, nil, "ambiguous" end

    local groupGUID
    for _, candidate in ipairs(candidates) do
        local root = Alts:GetMain(active.guildKey, candidate.guid) or candidate.guid
        if groupGUID and groupGUID ~= root then
            return nil, nil, "ambiguous"
        end
        groupGUID = root
    end

    local player = groupGUID and ((active.guildData.roster or {})[groupGUID] or (active.guildData.formerMembers or {})[groupGUID])
    if not player then return nil, nil, "ambiguous" end
    return groupGUID, player, "linked"
end

local function findRosterOwner(active, name)
    local Roster = GP:GetModule("Roster", true)
    if not Roster then return nil, nil, "missing" end

    local key = Roster:NormalizePlayerName(name)
    local exact = active.nameIndex and active.nameIndex.exact and active.nameIndex.exact[key]
    if exact and exact.ambiguous then return resolveLinkedAmbiguity(active, exact) end
    if exact then return exact.guid, exact.player, "exact" end

    local short = active.nameIndex and active.nameIndex.short and active.nameIndex.short[key]
    if short and short.ambiguous then return resolveLinkedAmbiguity(active, short) end
    if short then return short.guid, short.player, "short" end

    return Roster:FindPlayerByName(active.guildData, name, false)
end

local function recordOwner(active, entry, plot)
    local name = ownerName(plot)
    if not name then return end
    active.stats.namedOwners = active.stats.namedOwners + 1

    local guid, player, match = findRosterOwner(active, name)
    local record = {
        ownerName = name,
        neighborhoodName = entry.name,
        neighborhoodGUID = entry.guid,
        subdivision = entry.ordinal,
        plotID = plot.plotID,
        updated = active.startedAt,
    }

    if guid and player then
        record.match = match
        active.owners[guid] = record
        active.stats.matched = active.stats.matched + 1
        if match == "linked" then
            active.stats.linkedAmbiguous = active.stats.linkedAmbiguous + 1
        end
    else
        record.reason = match or "missing"
        active.unmatched[#active.unmatched + 1] = record
        active.stats.unmatched = active.stats.unmatched + 1
        if record.reason == "ambiguous" then
            active.stats.ambiguous = active.stats.ambiguous + 1
        else
            active.stats.missing = active.stats.missing + 1
        end
    end
end

local function plainMapPosition(position)
    if not position then return nil end
    local x, y = position.x or position[1], position.y or position[2]
    if (x == nil or y == nil) and position.GetXY then
        local ok, px, py = pcall(position.GetXY, position)
        if ok then x, y = px, py end
    end
    x, y = GP:SafeNumber(x, nil), GP:SafeNumber(y, nil)
    if not x or not y then return nil end
    return { x = x, y = y }
end

local function recordNeighborhood(active, entry, plotList)
    local plots = {}
    for _, plot in ipairs(plotList or {}) do
        local plotID = GP:SafeNumber(plot and plot.plotID, nil)
        local position = plainMapPosition(plot and plot.mapPosition)
        if plotID then
            plots[#plots + 1] = {
                plotID = plotID,
                plotName = GP:SafeOptionalString(plot.plotName),
                ownerName = ownerName(plot),
                ownerType = GP:SafeNumber(plot.ownerType, 0),
                mapPosition = position,
            }
        end
    end
    table.sort(plots, function(a, b) return a.plotID < b.plotID end)

    local uiMapID
    if C_Housing and C_Housing.GetUIMapIDForNeighborhood then
        local ok, value = pcall(C_Housing.GetUIMapIDForNeighborhood, entry.guid)
        if ok then uiMapID = GP:SafeNumber(value, nil) end
    end
    active.neighborhoods[entry.guid] = {
        neighborhoodGUID = entry.guid,
        neighborhoodName = entry.name,
        subdivision = entry.ordinal,
        uiMapID = uiMapID,
        plots = plots,
        updated = active.startedAt,
    }
end

local function processPlots(active, entry, plotList)
    recordNeighborhood(active, entry, plotList)
    for _, plot in ipairs(plotList or {}) do
        recordOwner(active, entry, plot)
    end
end

local advance

local function skipStep(reason)
    if not scan then return end
    scan.partial = true
    scan.message = reason
    if reason == GP.L["Housing scan timed out waiting for a subdivision."] then
        scan.stats.timedOut = scan.stats.timedOut + 1
    end
    scan.done = (scan.done or 0) + 1
    notify()
    holdTimer = C_Timer.NewTimer(SWEEP_QUARANTINE, advance)
end

local function startStep(entry)
    if not scan then return end
    scan.pending = entry
    local ok = pcall(C_Housing.RequestHouseFinderNeighborhoodData, entry.guid, entry.name)
    if not ok then
        scan.stats.requestFailed = scan.stats.requestFailed + 1
        skipStep(GP.L["Housing scan could not request one subdivision."])
        return
    end
    sweepTimer = C_Timer.NewTimer(SWEEP_TIMEOUT, function()
        skipStep(GP.L["Housing scan timed out waiting for a subdivision."])
    end)
    notify()
end

advance = function()
    clearTimer(sweepTimer)
    clearTimer(holdTimer)
    sweepTimer, holdTimer = nil, nil

    if not scan then return end
    if #scan.queue == 0 then
        finish(scan.partial and "partial" or "complete", scan.message)
        return
    end

    local entry = table.remove(scan.queue, 1)
    holdTimer = C_Timer.NewTimer(SWEEP_GAP, function()
        startStep(entry)
    end)
end

function Housing:OnEnable()
    self:RegisterEvent("NEIGHBORHOOD_LIST_UPDATED")
    self:RegisterEvent("HOUSE_FINDER_NEIGHBORHOOD_DATA_RECIEVED")
    self:RegisterEvent("VIEW_HOUSES_LIST_RECIEVED")
end

function Housing:IsScanning()
    return scan ~= nil
end

function Housing:GetProgress()
    if not scan then return 0, 0, nil end
    return scan.done or 0, scan.total or 0, scan.status
end

function Housing:StartScan(silent)
    if scan then return false, GP.L["Housing scan is already running."] end
    if not C_Housing or not C_Housing.HouseFinderRequestNeighborhoods or not C_Housing.RequestHouseFinderNeighborhoodData then
        return false, GP.L["Housing scan API is not available."]
    end

    local key = guildKey()
    local guildData = guildDataFor(key)
    if not guildData or not guildData.roster then
        return false, GP.L["No roster data yet — try /gp scan."]
    end

    scan = {
        guildKey = key,
        guildData = guildData,
        startedAt = time(),
        status = "list",
        done = 0,
        total = 0,
        queue = {},
        owners = {},
        unmatched = {},
        neighborhoods = {},
        nameIndex = buildRosterNameIndex(guildData),
        stats = newStats(),
        silent = silent and true or false,
    }
    scan.stats.rosterCount = scan.nameIndex.rosterCount or 0

    neighborhoodListRequested = true
    local ok = pcall(C_Housing.HouseFinderRequestNeighborhoods)
    if not ok then
        neighborhoodListRequested = false
        finish("failed", GP.L["Housing scan could not request the House Finder list."])
        return false, GP.L["Housing scan could not request the House Finder list."]
    end

    listTimer = C_Timer.NewTimer(LIST_TIMEOUT, function()
        finish("failed", GP.L["Housing scan timed out waiting for the House Finder list."])
    end)
    notify()
    return true
end

function Housing:NEIGHBORHOOD_LIST_UPDATED(_event, _result, neighborhoodInfos)
    neighborhoodListReady = true
    neighborhoodListRequested = false
    GP:SendMessage("GuildParagon_HousingNeighborhoodListReady")
    if not scan or scan.status ~= "list" then return end
    clearTimer(listTimer)
    listTimer = nil

    local queue = buildQueue(neighborhoodInfos)
    if #queue == 0 then
        finish("failed", GP.L["Housing scan found no guild neighborhoods in the House Finder list."])
        return
    end

    scan.queue = queue
    scan.total = #queue
    scan.stats.subdivisions = #queue
    scan.done = 0
    scan.status = "sweep"
    notify()
    advance()
end

function Housing:HOUSE_FINDER_NEIGHBORHOOD_DATA_RECIEVED(_event, plotList)
    if not scan or scan.status ~= "sweep" or not scan.pending then return end
    clearTimer(sweepTimer)
    sweepTimer = nil

    local entry = scan.pending
    scan.pending = nil
    if type(plotList) == "table" and #plotList > 0 then
        scan.stats.replies = scan.stats.replies + 1
        scan.stats.plots = scan.stats.plots + #plotList
        processPlots(scan, entry, plotList)
    elseif type(plotList) == "table" then
        scan.stats.emptyReplies = scan.stats.emptyReplies + 1
        scan.partial = true
        scan.message = GP.L["One or more housing subdivisions returned no plot data."]
    else
        scan.stats.badReplies = scan.stats.badReplies + 1
        scan.partial = true
        scan.message = GP.L["One or more housing subdivisions returned no plot data."]
    end

    scan.done = (scan.done or 0) + 1
    notify()
    advance()
end

function Housing:MaybeAutoScan(requestedGuildKey)
    if scan then return false end
    local key = requestedGuildKey or guildKey()
    if not key or autoScanRequested[key] then return false end

    local guildData = guildDataFor(key)
    local housing = guildData and guildData.housing
    local lastScan = housing and GP:SafeNumber(housing.lastScan, 0) or 0
    if lastScan > 0 and (time() - lastScan) < AUTO_SCAN_TTL then return false end

    autoScanRequested[key] = true
    return self:StartScan(true)
end

function Housing:IsNeighborhoodListReady()
    return neighborhoodListReady
end

function Housing:EnsureNeighborhoodList()
    if neighborhoodListReady then return true end
    if neighborhoodListRequested then return false end
    if not C_Housing or not C_Housing.HouseFinderRequestNeighborhoods then return false end
    neighborhoodListRequested = true
    local ok = pcall(C_Housing.HouseFinderRequestNeighborhoods)
    if not ok then neighborhoodListRequested = false end
    return ok
end

local function visitAddress(neighborhoodGUID, plotID)
    if not neighborhoodGUID or not plotID then return nil end
    return tostring(neighborhoodGUID) .. ":" .. tostring(plotID)
end

local function finishVisitLookup(houseGUID, message)
    if visitLookupTimer then
        visitLookupTimer:Cancel()
        visitLookupTimer = nil
    end
    local requested = visitLookup
    visitLookup = nil
    if not requested then return end
    if houseGUID then visitByAddress[requested.address] = houseGUID end
    GP:SendMessage("GuildParagon_HousingVisitPrepared", requested.guildKey, requested.guid, houseGUID, message)
end

function Housing:GetPreparedVisit(guildKey, guid)
    local ownership = self:GetPlotOwnership(guildKey, guid)
    local address = ownership and visitAddress(ownership.neighborhoodGUID, ownership.plotID)
    local houseGUID = address and visitByAddress[address]
    if not ownership or not houseGUID then return nil end
    return ownership.neighborhoodGUID, houseGUID, ownership.plotID
end

function Housing:PrepareVisit(guildKey, guid)
    if self:GetPreparedVisit(guildKey, guid) then
        return true, GP.L["Housing visit is ready."]
    end
    if visitLookup then
        return false, GP.L["Another housing visit is being prepared."]
    end
    if InCombatLockdown and InCombatLockdown() then
        return false, GP.L["Housing visits are unavailable during combat."]
    end
    if not C_Housing or not C_Housing.GetOthersOwnedHouses then
        return false, GP.L["Housing visit lookup is unavailable."]
    end

    local ownership = self:GetPlotOwnership(guildKey, guid)
    local address = ownership and visitAddress(ownership.neighborhoodGUID, ownership.plotID)
    if not address then return false, GP.L["Housing plot address is incomplete."] end

    visitLookup = { guildKey = guildKey, guid = guid, address = address }
    local ok = pcall(C_Housing.GetOthersOwnedHouses, guid, nil, true)
    if not ok then
        visitLookup = nil
        return false, GP.L["Housing visit lookup failed."]
    end
    visitLookupTimer = C_Timer.NewTimer(VISIT_LOOKUP_TIMEOUT, function()
        finishVisitLookup(nil, GP.L["Housing visit lookup timed out."])
    end)
    return false, GP.L["Preparing housing visit…"]
end

function Housing:VIEW_HOUSES_LIST_RECIEVED(_event, houseInfos)
    if not visitLookup then return end
    local houseGUID
    if type(houseInfos) == "table" then
        for _, house in ipairs(houseInfos) do
            if visitAddress(house.neighborhoodGUID, house.plotID) == visitLookup.address
                and house.houseGUID and house.houseGUID ~= "" then
                houseGUID = house.houseGUID
                break
            end
        end
    end
    finishVisitLookup(houseGUID, houseGUID
        and GP.L["Housing visit is ready — click the address again."]
        or GP.L["No visitable house was returned for this plot."])
end

function Housing:GetPlotOwnership(guildKey, guid)
    local guildData = guildDataFor(guildKey)
    local housing = guildData and guildData.housing
    local ownership = housing and housing.plotOwners and housing.plotOwners[guid] or nil
    if type(ownership) == "table" then return ownership end
    -- Early v1.1.2 test data stored ownership as a boolean before plot details
    -- were persisted. Keep that owner visible until the next scan replaces it.
    if ownership == true then return LEGACY_OWNERSHIP end
    return nil
end

function Housing:GetNeighborhoods(guildKey)
    local guildData = guildDataFor(guildKey)
    local housing = guildData and guildData.housing
    local out = {}
    for _, neighborhood in pairs(housing and housing.neighborhoods or {}) do
        if type(neighborhood) == "table" then out[#out + 1] = neighborhood end
    end
    table.sort(out, function(a, b)
        local left, right = tonumber(a.subdivision) or math.huge, tonumber(b.subdivision) or math.huge
        if left ~= right then return left < right end
        return tostring(a.neighborhoodName or "") < tostring(b.neighborhoodName or "")
    end)
    return out
end

function Housing:GetPlotOwnerGUID(guildKey, neighborhoodGUID, plotID)
    local guildData = guildDataFor(guildKey)
    local housing = guildData and guildData.housing
    for guid, ownership in pairs(housing and housing.plotOwners or {}) do
        if type(ownership) == "table" and ownership.neighborhoodGUID == neighborhoodGUID
            and tonumber(ownership.plotID) == tonumber(plotID) then
            return guid
        end
    end
    return nil
end

function Housing:FormatPlotOwnership(ownership)
    if type(ownership) ~= "table" then return GP.L["Subdivision"] end
    if ownership.subdivision and ownership.plotID then
        return string.format(GP.L["Subdivision #%s · Plot #%s"], tostring(ownership.subdivision), tostring(ownership.plotID))
    end
    if ownership.subdivision then
        return string.format(GP.L["Subdivision #%s"], tostring(ownership.subdivision))
    end
    if ownership.plotID then
        return string.format(GP.L["Plot #%s"], tostring(ownership.plotID))
    end
    return GP.L["Subdivision"]
end

function Housing:IsPlotOwner(guildKey, guid)
    return self:GetPlotOwnership(guildKey, guid) ~= nil
end

function Housing:GetSummary(guildKey)
    local guildData = guildDataFor(guildKey)
    local housing = guildData and guildData.housing
    if not housing then return 0, nil, nil end
    local count = 0
    for _ in pairs(housing.plotOwners or {}) do count = count + 1 end
    return count, housing.lastScan, housing.lastScanStatus
end

function Housing:DumpLastScan()
    local key = guildKey()
    local guildData = guildDataFor(key)
    local housing = guildData and guildData.housing
    local stats = housing and housing.lastScanStats
    if not stats then
        GP:Print(GP.L["No housing scan summary is available yet."])
        return
    end

    GP:Print(scanSummary(housing.lastScanStatus, stats))
    if stats.emptyReplies > 0 or stats.badReplies > 0 or stats.requestFailed > 0 or stats.timedOut > 0 then
        GP:Print(string.format(
            GP.L["Housing scan issues: %d empty, %d invalid, %d request failed, %d timed out."],
            stats.emptyReplies or 0,
            stats.badReplies or 0,
            stats.requestFailed or 0,
            stats.timedOut or 0
        ))
    end

    GP:Print(string.format(
        GP.L["Housing scan roster matches: %d roster member(s), %d missing, %d ambiguous, %d linked-group resolved."],
        stats.rosterCount or 0,
        stats.missing or 0,
        stats.ambiguous or 0,
        stats.linkedAmbiguous or 0
    ))

    local unmatched = housing.lastScanUnmatchedOwners or housing.unmatchedOwners or {}
    local shown = math.min(#unmatched, MAX_DEBUG_UNMATCHED)
    if shown == 0 then return end
    GP:Print(string.format(GP.L["Sample unmatched housing owners (%d of %d):"], shown, #unmatched))
    for i = 1, shown do
        local record = unmatched[i]
        GP:Print(string.format(
            "%s - %s #%s (%s)",
            record.ownerName or "?",
            record.neighborhoodName or "?",
            record.subdivision or "?",
            record.reason or "missing"
        ))
    end
end
