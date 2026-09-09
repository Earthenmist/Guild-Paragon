-- Guild Paragon - frame-yield helpers
-- Small cooperative helpers for splitting non-urgent work across frames.
local _, GP = ...

local activeRuns = {}

local function nextToken(key)
    key = tostring(key or "default")
    activeRuns[key] = (activeRuns[key] or 0) + 1
    return key, activeRuns[key]
end

local function isCurrent(key, token)
    return activeRuns[key] == token
end

function GP:CancelFrameWork(key)
    key = tostring(key or "default")
    activeRuns[key] = (activeRuns[key] or 0) + 1
end

function GP:RunFrameSteps(key, steps, onDone)
    if type(steps) ~= "table" then
        if onDone then onDone(false) end
        return
    end

    local runKey, token = nextToken(key)
    local index = 1

    local function runNext()
        if not isCurrent(runKey, token) then return end

        local step = steps[index]
        index = index + 1
        if not step then
            if onDone then onDone(true) end
            return
        end

        local keepGoing = step()
        if keepGoing == false then
            if onDone then onDone(false) end
            return
        end

        if C_Timer and C_Timer.After then
            C_Timer.After(0, runNext)
        else
            runNext()
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, runNext)
    else
        runNext()
    end
end

function GP:RunFrameBatches(key, items, batchSize, processItem, onDone)
    if type(items) ~= "table" or type(processItem) ~= "function" then
        if onDone then onDone(false) end
        return
    end

    local runKey, token = nextToken(key)
    local index = 1
    local count = #items
    batchSize = math.max(1, tonumber(batchSize) or 50)

    local function runBatch()
        if not isCurrent(runKey, token) then return end

        local batchEnd = math.min(count, index + batchSize - 1)
        while index <= batchEnd do
            local keepGoing = processItem(items[index], index)
            if keepGoing == false then
                if onDone then onDone(false) end
                return
            end
            index = index + 1
        end

        if index > count then
            if onDone then onDone(true) end
            return
        end

        if C_Timer and C_Timer.After then
            C_Timer.After(0, runBatch)
        else
            runBatch()
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, runBatch)
    else
        runBatch()
    end
end
