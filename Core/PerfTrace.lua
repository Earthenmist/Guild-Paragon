-- Lightweight diagnostics for /gp perf.
-- Samples addon memory and the shared Lua heap without forcing collection.
local ADDON_NAME, GP = ...

-- label -> { lastKB, lastMs, lastAt, bestKB, bestMs, bestAt }
-- Login-only state; never written to SavedVariables.
local records = {}
local order = {}

local function nowMs()
    return debugprofilestop and debugprofilestop() or 0
end

-- Calibrated only when /gp perf is requested.
local overheadCalibration

function GP:PerfCalibrateOverhead()
    if overheadCalibration then return overheadCalibration end

    local sampleCount = 3
    local total, worst = 0, 0
    for _ = 1, sampleCount do
        local start = nowMs()
        self:PerfMark()
        local elapsed = nowMs() - start
        if elapsed < 0 then elapsed = 0 end
        total = total + elapsed
        if elapsed > worst then worst = elapsed end
    end

    overheadCalibration = { avgMs = total / sampleCount, maxMs = worst, samples = sampleCount }
    return overheadCalibration
end

function GP:PerfMark()
    if UpdateAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
    end
    return {
        kb = (GetAddOnMemoryUsage and GetAddOnMemoryUsage(ADDON_NAME)) or 0,
        ms = nowMs(),
    }
end

function GP:PerfRecord(label, startMark, endMark)
    endMark = endMark or self:PerfMark()
    if type(label) ~= "string" or type(startMark) ~= "table" then
        return endMark
    end

    local deltaKB = endMark.kb - startMark.kb
    local deltaMs = endMark.ms - startMark.ms
    if deltaMs < 0 then deltaMs = 0 end

    local rec = records[label]
    if not rec then
        rec = {}
        records[label] = rec
        order[#order + 1] = label
    end

    rec.lastKB = deltaKB
    rec.lastMs = deltaMs
    rec.lastAt = time()

    if not rec.bestKB or deltaKB > rec.bestKB then
        rec.bestKB = deltaKB
        rec.bestMs = deltaMs
        rec.bestAt = time()
    end

    return endMark
end

function GP:PerfSnapshot(limit)
    limit = limit or 3
    local ranked = {}
    for _, label in ipairs(order) do
        local rec = records[label]
        if rec.bestKB and rec.bestKB > 0 then
            ranked[#ranked + 1] = { label = label, rec = rec }
        end
    end
    table.sort(ranked, function(a, b) return a.rec.bestKB > b.rec.bestKB end)

    local result = {}
    for i = 1, math.min(limit, #ranked) do
        result[i] = ranked[i]
    end
    return result
end

-- Passive shared Lua heap sampling for /gp perf.
local gcHeap = {
    currentKB = 0,
    highKB = 0,
    largestDropKB = 0,
    largestDropAt = 0,
}
local gcHeapTicker

local function sampleGCHeap()
    local kb = collectgarbage("count")
    local previous = gcHeap.currentKB
    gcHeap.currentKB = kb
    if kb > gcHeap.highKB then
        gcHeap.highKB = kb
    end
    if previous > 0 and previous > kb then
        local drop = previous - kb
        if drop > gcHeap.largestDropKB then
            gcHeap.largestDropKB = drop
            gcHeap.largestDropAt = time()
        end
    end
end

function GP:StartGCHeapTracking()
    if gcHeapTicker then return end
    sampleGCHeap()
    if C_Timer and C_Timer.NewTicker then
        gcHeapTicker = C_Timer.NewTicker(2, sampleGCHeap)
    end
end

function GP:GetGCHeapStats()
    return gcHeap
end
