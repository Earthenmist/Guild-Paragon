-- Guild Paragon - Upcoming birthday and guild-anniversary queries
local _, GP = ...

local UpcomingDates = GP:NewModule("UpcomingDates", "AceEvent-3.0")

local VALID_WINDOWS = { [7] = true, [14] = true, [30] = true }
local CALENDAR_TITLE_LIMIT = 31

local function guildDataFor(guildKey)
    return guildKey and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[guildKey] or nil
end

local function defaultGuildKey()
    local Roster = GP:GetModule("Roster", true)
    return Roster and Roster.GetGuildKey and Roster:GetGuildKey() or nil
end

local function isLeapYear(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function daysBeforeYear(year)
    local previous = year - 1
    return previous * 365 + math.floor(previous / 4) - math.floor(previous / 100) + math.floor(previous / 400)
end

local DAYS_BEFORE_MONTH = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }

local function serialDay(year, month, day)
    local serial = daysBeforeYear(year) + DAYS_BEFORE_MONTH[month] + day
    if month > 2 and isLeapYear(year) then serial = serial + 1 end
    return serial
end

local function trim(value)
    return strtrim(tostring(value or ""))
end

local function protectedCalendarState()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    if IsInInstance then
        local ok, inInstance, instanceType = pcall(IsInInstance)
        if ok and inInstance and instanceType ~= "neighborhood" and instanceType ~= "interior" then return true end
    end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
        if ok and active then return true end
    end
    return false
end

local function monthOffsetFor(year, month)
    if not C_Calendar or not C_Calendar.GetMonthInfo then return nil end
    local ok, current = pcall(C_Calendar.GetMonthInfo, 0)
    if not ok or type(current) ~= "table" then return nil end
    local currentYear, currentMonth = tonumber(current.year), tonumber(current.month)
    if not currentYear or not currentMonth then return nil end
    return (year - currentYear) * 12 + (month - currentMonth)
end

local function calendarTitle(row)
    local name = trim(row and (row.greetingName or row.name))
    local title
    if row and row.type == "birthday" then
        title = string.format(GP.L["Birthday: %s"], name)
    else
        title = string.format(GP.L["Guild anniversary: %s"], name)
    end
    return title:sub(1, CALENDAR_TITLE_LIMIT)
end

local function observedMonthDay(month, day, year)
    if month == 2 and day == 29 and not isLeapYear(year) then
        return 2, 28
    end
    return month, day
end

local function validMonthDay(month, day)
    month, day = tonumber(month), tonumber(day)
    if not month or not day or month < 1 or month > 12 or day < 1 then return false end
    local maximum = ({ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[month]
    return day <= maximum
end

local function currentServerDate()
    if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
        local ok, value = pcall(C_DateAndTime.GetCurrentCalendarTime)
        if ok and type(value) == "table" then
            local year = tonumber(value.year)
            local month = tonumber(value.month)
            local day = tonumber(value.monthDay or value.day)
            if year and validMonthDay(month, day) then
                return { year = year, month = month, day = day }
            end
        end
    end
    local value = date("*t")
    return { year = value.year, month = value.month, day = value.day }
end

local function nextOccurrence(month, day, today)
    if not validMonthDay(month, day) or type(today) ~= "table" then return nil end
    local year = tonumber(today.year)
    local currentMonth = tonumber(today.month)
    local currentDay = tonumber(today.day)
    if not year or not validMonthDay(currentMonth, currentDay) then return nil end

    local observedMonth, observedDay = observedMonthDay(month, day, year)
    local currentSerial = serialDay(year, currentMonth, currentDay)
    local occurrenceSerial = serialDay(year, observedMonth, observedDay)
    if occurrenceSerial < currentSerial then
        year = year + 1
        observedMonth, observedDay = observedMonthDay(month, day, year)
        occurrenceSerial = serialDay(year, observedMonth, observedDay)
    end
    return {
        year = year,
        month = observedMonth,
        day = observedDay,
        originalMonth = month,
        originalDay = day,
        daysRemaining = occurrenceSerial - currentSerial,
    }
end

local function completedYears(startYear, month, day, today)
    startYear = tonumber(startYear)
    if not startYear or startYear >= today.year then return 0 end
    local observedMonth, observedDay = observedMonthDay(month, day, today.year)
    local years = today.year - startYear
    if serialDay(today.year, today.month, today.day) < serialDay(today.year, observedMonth, observedDay) then
        years = years - 1
    end
    return math.max(0, years)
end

local function provenanceFor(player)
    local source = tostring(player.joinDateSource or "firstseen")
    if source == "manual" or source == "guildevent" then
        return "verified", false
    end
    if source == "customnote" or source:find("grm", 1, true) then
        return "imported", false
    end
    return "estimated", true
end

local function playerDate(timestamp)
    if type(timestamp) ~= "number" or timestamp <= 0 then return nil end
    local value = date("*t", timestamp)
    if not value or not validMonthDay(value.month, value.day) then return nil end
    return value
end

function UpcomingDates:GetSettings()
    GP.db.profile.upcomingDates = GP.db.profile.upcomingDates or {}
    local settings = GP.db.profile.upcomingDates
    if settings.showBirthdays == nil then settings.showBirthdays = true end
    if settings.showAnniversaries == nil then settings.showAnniversaries = true end
    if settings.includeEstimatedAnniversaries == nil then settings.includeEstimatedAnniversaries = false end
    settings.showBirthdays = settings.showBirthdays and true or false
    settings.showAnniversaries = settings.showAnniversaries and true or false
    settings.includeEstimatedAnniversaries = settings.includeEstimatedAnniversaries and true or false
    settings.reminderWindowDays = tonumber(settings.reminderWindowDays) or 14
    if not VALID_WINDOWS[settings.reminderWindowDays] then settings.reminderWindowDays = 14 end
    return settings
end

function UpcomingDates:SaveSettings(values)
    local settings = self:GetSettings()
    if type(values) ~= "table" then return settings end
    if values.showBirthdays ~= nil then settings.showBirthdays = values.showBirthdays and true or false end
    if values.showAnniversaries ~= nil then settings.showAnniversaries = values.showAnniversaries and true or false end
    if values.includeEstimatedAnniversaries ~= nil then
        settings.includeEstimatedAnniversaries = values.includeEstimatedAnniversaries and true or false
    end
    if VALID_WINDOWS[tonumber(values.reminderWindowDays)] then
        settings.reminderWindowDays = tonumber(values.reminderWindowDays)
    end
    GP:SendMessage("GuildParagon_UpcomingDatesSettingsChanged")
    return settings
end

function UpcomingDates:GetNextOccurrence(month, day, today)
    return nextOccurrence(tonumber(month), tonumber(day), today or currentServerDate())
end

function UpcomingDates:GetCompletedYears(startYear, month, day, today)
    return completedYears(startYear, tonumber(month), tonumber(day), today or currentServerDate())
end

function UpcomingDates:GetRows(guildKey, todayOverride)
    guildKey = guildKey or defaultGuildKey()
    local guildData = guildDataFor(guildKey)
    if not guildData then return {} end

    local settings = self:GetSettings()
    local today = todayOverride or currentServerDate()
    local window = settings.reminderWindowDays
    local rows = {}
    local Roster = GP:GetModule("Roster")
    local Nicknames = GP:GetModule("Nicknames")

    if settings.showBirthdays then
        local processed = {}
        for guid, player in pairs(guildData.roster or {}) do
            local representative, members = Nicknames:GetIdentityGUIDs(guildKey, guid)
            representative = representative or guid
            if not processed[representative] then
                processed[representative] = true
                local displayPlayer = guildData.roster[representative]
                local birthdayDay, birthdayMonth
                for _, memberGUID in ipairs(members or { guid }) do
                    local member = guildData.roster[memberGUID]
                    if member then
                        displayPlayer = displayPlayer or member
                        birthdayDay, birthdayMonth = Roster:GetBirthday(member)
                        if birthdayDay and birthdayMonth then break end
                    end
                end
                local occurrence = self:GetNextOccurrence(birthdayMonth, birthdayDay, today)
                if occurrence and occurrence.daysRemaining <= window and displayPlayer then
                    local shared = Nicknames:GetSharedNickname(guildKey, representative)
                    rows[#rows + 1] = {
                        id = "birthday:" .. representative,
                        type = "birthday",
                        guid = representative,
                        name = displayPlayer.name or "",
                        class = displayPlayer.class,
                        greetingName = shared ~= "" and shared or (displayPlayer.name or ""),
                        month = birthdayMonth,
                        day = birthdayDay,
                        occurrence = occurrence,
                        daysRemaining = occurrence.daysRemaining,
                    }
                end
            end
        end
    end

    if settings.showAnniversaries then
        for guid, player in pairs(guildData.roster or {}) do
            local joined = not player.joinDateUnknown and playerDate(player.firstSeen) or nil
            if joined then
                local provenance, estimated = provenanceFor(player)
                if not estimated or settings.includeEstimatedAnniversaries then
                    local occurrence = self:GetNextOccurrence(joined.month, joined.day, today)
                    if occurrence and occurrence.daysRemaining <= window then
                        rows[#rows + 1] = {
                            id = "anniversary:" .. guid,
                            type = "anniversary",
                            guid = guid,
                            name = player.name or "",
                            class = player.class,
                            greetingName = player.name or "",
                            month = joined.month,
                            day = joined.day,
                            startYear = joined.year,
                            years = self:GetCompletedYears(joined.year, joined.month, joined.day, occurrence),
                            provenance = provenance,
                            provenanceSource = player.joinDateSource or "firstseen",
                            estimated = estimated,
                            occurrence = occurrence,
                            daysRemaining = occurrence.daysRemaining,
                        }
                    end
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.daysRemaining ~= b.daysRemaining then return a.daysRemaining < b.daysRemaining end
        if a.type ~= b.type then return a.type < b.type end
        local aName, bName = tostring(a.name):lower(), tostring(b.name):lower()
        if aName ~= bName then return aName < bName end
        return a.id < b.id
    end)
    return rows
end

function UpcomingDates:GetGreeting(row)
    if type(row) ~= "table" then return "" end
    if row.type == "birthday" then
        return string.format(GP.L["Happy birthday, %s! Hope you have a great day!"], row.greetingName or row.name or "")
    end
    if row.type == "anniversary" then
        local years = tonumber(row.years) or 0
        if years == 1 then
            return string.format(GP.L["Happy 1-year guild anniversary, %s! Thank you for being part of the guild!"], row.name or "")
        end
        return string.format(GP.L["Happy %d-year guild anniversary, %s! Thank you for being part of the guild!"], years, row.name or "")
    end
    return ""
end

function UpcomingDates:GetCalendarPreview(row)
    if type(row) ~= "table" or type(row.occurrence) ~= "table" then return nil end
    return {
        row = row,
        title = calendarTitle(row),
        description = self:GetGreeting(row),
        year = tonumber(row.occurrence.year),
        month = tonumber(row.occurrence.month),
        day = tonumber(row.occurrence.day),
    }
end

function UpcomingDates:CanCreateCalendarEvent(preview)
    if protectedCalendarState() then return false, GP.L["Calendar creation is unavailable during combat or protected content."] end
    if preview and preview.row and preview.row.estimated then
        return false, GP.L["Estimated anniversaries cannot be added to the guild calendar."]
    end
    if not IsInGuild or not IsInGuild() then return false, GP.L["You must be in a guild to create a guild calendar announcement."] end
    if type(C_Calendar) ~= "table" or type(C_Calendar.CreateGuildAnnouncementEvent) ~= "function"
        or type(C_Calendar.AddEvent) ~= "function" then
        return false, GP.L["The guild calendar API is unavailable."]
    end
    if type(CanEditGuildEvent) ~= "function" then return false, GP.L["Guild calendar permission could not be verified."] end
    local permissionOK, allowed = pcall(CanEditGuildEvent)
    if not permissionOK or not allowed then return false, GP.L["You do not have permission to create guild calendar announcements."] end
    if self.calendarSubmission then return false, GP.L["A calendar announcement is already being created."] end
    if C_Calendar.IsActionPending and C_Calendar.IsActionPending() then return false, GP.L["Another calendar action is still pending."] end

    local year, month, day = tonumber(preview and preview.year), tonumber(preview and preview.month), tonumber(preview and preview.day)
    if not year or not validMonthDay(month, day) then return false, GP.L["Enter a valid calendar date."] end
    local today = currentServerDate()
    if serialDay(year, month, day) < serialDay(today.year, today.month, today.day) then
        return false, GP.L["Calendar announcements cannot be created in the past."]
    end
    if C_Calendar.GetMaxCreateDate then
        local ok, maximum = pcall(C_Calendar.GetMaxCreateDate)
        if not ok or type(maximum) ~= "table" then return false, GP.L["The calendar date limit is unavailable."] end
        if serialDay(year, month, day) > serialDay(maximum.year, maximum.month, maximum.monthDay) then
            return false, GP.L["That date is beyond the calendar creation limit."]
        end
    end
    preview.title = trim(preview.title):sub(1, CALENDAR_TITLE_LIMIT)
    preview.description = trim(preview.description)
    if preview.title == "" then return false, GP.L["Enter a calendar title."] end
    return true
end

function UpcomingDates:HasCalendarDuplicate(preview)
    if not C_Calendar or not C_Calendar.GetNumDayEvents or not C_Calendar.GetDayEvent then return nil end
    if C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end
    local offset = monthOffsetFor(preview.year, preview.month)
    if not offset then return nil end
    local countOK, count = pcall(C_Calendar.GetNumDayEvents, offset, preview.day)
    if not countOK or type(count) ~= "number" then return nil end
    local expected = preview.title:lower()
    for index = 1, count do
        local ok, event = pcall(C_Calendar.GetDayEvent, offset, preview.day, index)
        if not ok then return nil end
        if type(event) == "table" and event.calendarType == "GUILD_ANNOUNCEMENT"
            and trim(event.title):lower() == expected then
            return true
        end
    end
    return false
end

function UpcomingDates:CreateCalendarEvent(preview, allowDuplicate)
    local allowed, reason = self:CanCreateCalendarEvent(preview)
    if not allowed then return false, reason end
    local duplicate = self:HasCalendarDuplicate(preview)
    if duplicate == nil then return false, GP.L["The target calendar day could not be checked safely."] end
    if duplicate and not allowDuplicate then return false, GP.L["A matching guild announcement already exists."], "duplicate" end

    if C_Calendar.IsEventOpen and C_Calendar.IsEventOpen() then pcall(C_Calendar.CloseEvent) end
    local ok = pcall(function()
        C_Calendar.CreateGuildAnnouncementEvent()
        C_Calendar.EventSetDate(preview.month, preview.day, preview.year)
        C_Calendar.EventSetTitle(preview.title)
        C_Calendar.EventSetDescription(preview.description)
        C_Calendar.EventSetTime(0, 0)
        C_Calendar.EventSetType(Enum.CalendarEventType.Other)
    end)
    if not ok or not C_Calendar.CanAddEvent or not C_Calendar.CanAddEvent() then
        if C_Calendar.IsEventOpen and C_Calendar.IsEventOpen() then pcall(C_Calendar.CloseEvent) end
        return false, GP.L["The calendar announcement draft could not be prepared."]
    end

    local submission = { preview = preview, startedAt = GetTime and GetTime() or 0 }
    self.calendarSubmission = submission
    local added = pcall(C_Calendar.AddEvent)
    if not added then
        self.calendarSubmission = nil
        if C_Calendar.IsEventOpen and C_Calendar.IsEventOpen() then pcall(C_Calendar.CloseEvent) end
        return false, GP.L["The calendar announcement could not be submitted."]
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(10, function()
            if self.calendarSubmission ~= submission then return end
            self.calendarSubmission = nil
            GP:Print(GP.L["Calendar announcement confirmation timed out. Check the guild calendar before trying again."])
            GP:SendMessage("GuildParagon_UpcomingDatesCalendarChanged")
        end)
    end
    return true, GP.L["Creating guild calendar announcement..."]
end

function UpcomingDates:CALENDAR_NEW_EVENT(_, isCopy)
    if not self.calendarSubmission or isCopy then return end
    self.calendarSubmission = nil
    GP:Print(GP.L["Guild calendar announcement created."])
    GP:SendMessage("GuildParagon_UpcomingDatesCalendarChanged")
end

function UpcomingDates:CalendarError(_, reason, detail)
    if not self.calendarSubmission then return end
    self.calendarSubmission = nil
    local message = _G[reason] or tostring(reason or GP.L["Unknown calendar error."])
    if detail ~= nil and message:find("%", 1, true) then
        local ok, formatted = pcall(string.format, message, detail)
        if ok then message = formatted end
    end
    GP:Print(string.format(GP.L["Calendar announcement failed: %s"], message))
    GP:SendMessage("GuildParagon_UpcomingDatesCalendarChanged")
end

function UpcomingDates:CALENDAR_CLOSE_EVENT()
    if not self.calendarSubmission then return end
    self.calendarSubmission = nil
    GP:Print(GP.L["Calendar announcement closed before creation was confirmed."])
    GP:SendMessage("GuildParagon_UpcomingDatesCalendarChanged")
end

function UpcomingDates:OnEnable()
    self:RegisterEvent("CALENDAR_NEW_EVENT")
    self:RegisterEvent("CALENDAR_UPDATE_ERROR", "CalendarError")
    self:RegisterEvent("CALENDAR_UPDATE_ERROR_WITH_COUNT", "CalendarError")
    self:RegisterEvent("CALENDAR_UPDATE_ERROR_WITH_PLAYER_NAME", "CalendarError")
    self:RegisterEvent("CALENDAR_CLOSE_EVENT")
end
