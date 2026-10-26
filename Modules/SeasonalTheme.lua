-- Seasonal colours for in-game holidays. Hallow's End dates come from
-- Blizzard's calendar when it has been read, otherwise a fixed window.
local _, GP = ...
local Seasonal = GP:NewModule("SeasonalTheme", "AceEvent-3.0")

-- Calendar holiday IDs for Hallow's End.
local HALLOWS_END_IDS = { [324] = true, [1405] = true }
-- Used when the calendar has not given this year's dates: 19 Oct - 2 Nov.
local FALLBACK_START = { month = 10, day = 19, hour = 0, minute = 0 }
local FALLBACK_END = { month = 11, day = 2, hour = 23, minute = 59 }
local SCAN_DELAY = 10

local function readable(value)
    if GP:IsSecretValue(value) then return nil end
    return value
end

local function number(value)
    value = readable(value)
    if type(value) == "number" and value == value then return value end
end

-- Calendar times as sortable numbers (YYYYMMDDhhmm), so realm dates compare
-- without converting time zones.
local function timeKey(year, month, day, hour, minute)
    return (((year * 100 + month) * 100 + day) * 100 + (hour or 0)) * 100 + (minute or 0)
end

local function calendarKey(t)
    if type(t) ~= "table" then return nil end
    local year, month, day = number(t.year), number(t.month), number(t.monthDay)
    if not year or not month or not day then return nil end
    return timeKey(year, month, day, number(t.hour), number(t.minute))
end

function Seasonal:Now()
    local realm = C_DateAndTime and GP:SafeCall(C_DateAndTime.GetCurrentCalendarTime, nil)
    local key = calendarKey(realm)
    if key then return key, number(realm.year) end
    local t = date("*t")
    return timeKey(t.year, t.month, t.day, t.hour, t.min), t.year
end

function Seasonal:Enabled()
    local ui = GP.db and GP.db.profile and GP.db.profile.ui
    return not ui or ui.seasonalThemes ~= false
end

function Seasonal:Window(year)
    local stored = GP.db and GP.db.global.seasonal and GP.db.global.seasonal.hallowsend
    if type(stored) == "table" and stored.year == year
        and type(stored.startKey) == "number" and type(stored.endKey) == "number" then
        return stored.startKey, stored.endKey, "calendar"
    end
    return timeKey(year, FALLBACK_START.month, FALLBACK_START.day, FALLBACK_START.hour, FALLBACK_START.minute),
        timeKey(year, FALLBACK_END.month, FALLBACK_END.day, FALLBACK_END.hour, FALLBACK_END.minute), "fallback"
end

-- The season active right now, or nil.
function Seasonal:ActiveSeason()
    if not self:Enabled() then return nil end
    local ui = GP.db and GP.db.profile and GP.db.profile.ui
    if ui and ui.seasonPreview then return "hallowsend" end
    local now, year = self:Now()
    local startKey, endKey = self:Window(year)
    if now >= startKey and now <= endKey then return "hallowsend" end
end

-- Reads Hallow's End from the calendar months around today and stores this
-- year's window. Call after CALENDAR_UPDATE_EVENT_LIST so holidays are loaded.
function Seasonal:ScanCalendar()
    if not C_Calendar or type(C_Calendar.GetMonthInfo) ~= "function"
        or type(C_Calendar.GetNumDayEvents) ~= "function" or type(C_Calendar.GetDayEvent) ~= "function" then
        return false
    end
    local now, year = self:Now()
    local shown = GP:SafeCall(C_Calendar.GetMonthInfo, nil, 0)
    if type(shown) ~= "table" or not number(shown.year) or not number(shown.month) then return false end
    local month = math.floor(now / 1000000) % 100
    local base = (year - shown.year) * 12 + (month - shown.month)
    local best
    for offset = base - 1, base + 1 do
        local info = GP:SafeCall(C_Calendar.GetMonthInfo, nil, offset)
        local days = type(info) == "table" and number(info.numDays)
        for day = 1, days or 0 do
            local count = number(GP:SafeCall(C_Calendar.GetNumDayEvents, 0, offset, day)) or 0
            for index = 1, count do
                local ok, event = pcall(C_Calendar.GetDayEvent, offset, day, index)
                event = ok and readable(event)
                if type(event) == "table" and readable(event.calendarType) == "HOLIDAY"
                    and HALLOWS_END_IDS[number(event.eventID) or 0] then
                    local startKey, endKey = calendarKey(event.startTime), calendarKey(event.endTime)
                    if startKey and endKey and endKey >= now and (not best or startKey < best.startKey) then
                        best = { startKey = startKey, endKey = endKey, year = math.floor(startKey / 100000000) }
                    end
                end
            end
        end
    end
    if best and best.year == year then
        GP.db.global.seasonal = GP.db.global.seasonal or {}
        GP.db.global.seasonal.hallowsend = best
    end
    return true
end

function Seasonal:OnCalendarUpdated()
    if self:ScanCalendar() then self:UnregisterEvent("CALENDAR_UPDATE_EVENT_LIST") end
end

-- One calendar read per session, shortly after login. The result is used
-- from the next load, since colours are set before the UI is built.
function Seasonal:OnEnteringWorld()
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    C_Timer.After(SCAN_DELAY, function()
        if not C_Calendar or type(C_Calendar.OpenCalendar) ~= "function" then return end
        if GP:RegisterOptionalEvent(self, "CALENDAR_UPDATE_EVENT_LIST", "OnCalendarUpdated") then
            pcall(C_Calendar.OpenCalendar)
        end
    end)
end

-- /gp testseason: shows the seasonal colours outside the season, after a reload.
function Seasonal:TogglePreview()
    local ui = GP.db.profile.ui
    ui.seasonPreview = not ui.seasonPreview or nil
    GP:Print(ui.seasonPreview and GP.L["Seasonal colours preview on. Type /reload to see it; run the command again to turn it off."]
        or GP.L["Seasonal colours preview off. Type /reload to return to the normal colours."])
end

function Seasonal:OnInitialize()
    -- Runs before any themed frame exists, so the whole UI picks it up.
    local season = self:ActiveSeason()
    if season then GP.UI.Theme:ApplySeasonalPalette(season) end
end

function Seasonal:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
end
