-- Guild Paragon — Notifications
--
-- After login, summarises what changed in the guild since the account was last
-- online: one counted line per kind of change, built from the Event Log.
--
-- "Last online" is a per-guild timestamp shared by every character on the
-- account. It advances while the player is online and at logout, so the next
-- login covers exactly the time away. Entries are matched by their event time,
-- which synced entries keep, so changes recorded by other officers while the
-- player was away are included even though they arrive later.
local _, GP = ...
local Notifications = GP:NewModule("Notifications", "AceEvent-3.0")

-- Leaves are confirmed on the scan after the one that first misses a member,
-- and actors arrive from the guild event log shortly after the first scan.
local SETTLE_AFTER_SECOND_SCAN = 10
local SETTLE_MAX = 30
local CHECK_INTERVAL = 2
-- Log tails longer than this are read across frames.
local ENTRIES_PER_FRAME = 500

-- Summary line order. officer = only for players who can view officer notes.
Notifications.LINES = {
    { key = "join" },
    { key = "rejoin" },
    { key = "leave" },
    { key = "removed" },
    { key = "promote" },
    { key = "demote" },
    { key = "level" },
    { key = "inactivereturn" },
    { key = "note" },
    { key = "officernote", officer = true },
    { key = "remotealts" },
    -- Shown under "Needs attention" rather than with the other changes.
    { key = "banwarning", officer = true, attention = true },
    { key = "ban", officer = true },
}

local LINE_BY_TYPE = {
    join = "join", leave = "leave", removed = "removed", promote = "promote",
    demote = "demote", level = "level", inactivereturn = "inactivereturn",
    note = "note", officernote = "officernote", banwarning = "banwarning",
    banadded = "ban", banedited = "ban", banremoved = "ban",
    altlinked = "remotealts", altcleared = "remotealts",
    markedmain = "remotealts", unmarkedmain = "remotealts",
}

-- Summary builder. Pure: no WoW API or SavedVariables access, so it can be
-- driven entry by entry (batched) and tested outside the game.
-- opts.isOfficer, opts.allLevelUps, opts.canDisplay(entry) -> bool.
function Notifications.NewSummary(since, opts)
    local summary = { since = since, opts = opts or {}, counts = {}, seen = {}, actors = {}, total = 0 }
    for _, line in ipairs(Notifications.LINES) do
        summary.counts[line.key] = 0
        summary.seen[line.key] = {}
    end
    return summary
end

-- Categories the player can switch off, in Settings order. Each covers one or
-- more summary lines, attention items or the upcoming dates list.
Notifications.CATEGORIES = {
    { key = "joins", label = "Joins and rejoins", lines = { "join", "rejoin" } },
    { key = "leaves", label = "Leaves and removals", lines = { "leave", "removed" } },
    { key = "ranks", label = "Promotions and demotions", lines = { "promote", "demote" } },
    { key = "levels", label = "Level-ups", lines = { "level" } },
    { key = "returns", label = "Returns after a break", lines = { "inactivereturn" } },
    { key = "notes", label = "Note changes", lines = { "note", "officernote" } },
    { key = "alts", label = "Alt changes by others", lines = { "remotealts" } },
    { key = "bans", label = "Ban List changes", lines = { "ban" }, officer = true },
    { key = "banwarning", label = "Ban List matches", lines = { "banwarning" }, officer = true },
    { key = "applicants", label = "Applications awaiting review", officer = true },
    { key = "welcomes", label = "Recruits waiting for a welcome", officer = true },
    { key = "listing", label = "Guild Finder listing expiry", officer = true },
    { key = "upcoming", label = "Birthdays and anniversaries" },
}
Notifications.CATEGORY_OF = {}
for _, category in ipairs(Notifications.CATEGORIES) do
    for _, line in ipairs(category.lines or { category.key }) do
        Notifications.CATEGORY_OF[line] = category.key
    end
end

local OFFICER_LINES = {}
for _, line in ipairs(Notifications.LINES) do
    if line.officer then OFFICER_LINES[line.key] = true end
end

-- Summary line an Event Log entry belongs to, or nil. Shared by the summary
-- and the Event Log's summary filter so both always agree.
function Notifications.LineFor(entry, opts)
    if type(entry) ~= "table" then return nil end
    local key = LINE_BY_TYPE[entry.type]
    if not key then return nil end
    if key == "join" and entry.rejoin then key = "rejoin" end
    if key == "level" and not opts.allLevelUps and not entry.atLevelCap then return nil end
    -- Alt changes count only when another player made them.
    if key == "remotealts" and not entry.remote then return nil end
    if OFFICER_LINES[key] and not opts.isOfficer then return nil end
    if opts.hidden and opts.hidden[Notifications.CATEGORY_OF[key]] then return nil end
    if opts.canDisplay and not opts.canDisplay(entry) then return nil end
    return key
end

function Notifications.AddEntry(summary, entry)
    if type(entry) ~= "table" or type(entry.ts) ~= "number" or entry.ts <= summary.since then return end
    local key = Notifications.LineFor(entry, summary.opts)
    if not key then return end
    -- Count members, not entries: repeated or synced copies of a change to the
    -- same member count once. Entries without a member count individually.
    local identity = entry.guid or entry.id or (tostring(entry.ts) .. ":" .. tostring(entry.name))
    if summary.seen[key][identity] then return end
    summary.seen[key][identity] = true
    summary.counts[key] = summary.counts[key] + 1
    summary.total = summary.total + 1
    if key == "removed" then
        local actor = entry.actor or entry.removedBy
        if type(actor) == "string" and actor ~= "" then
            summary.actors[actor] = true
        end
    end
end

-- Index of the first entry newer than `since` in a log sorted oldest first.
function Notifications.FirstIndexAfter(log, since)
    local low, high = 1, #log + 1
    while low < high do
        local mid = math.floor((low + high) / 2)
        local ts = type(log[mid]) == "table" and log[mid].ts
        if type(ts) == "number" and ts <= since then low = mid + 1 else high = mid end
    end
    return low
end

-- Single remover's name, when every counted removal names the same one.
function Notifications.SoleRemover(summary)
    local name
    for actor in pairs(summary.actors) do
        if name then return nil end
        name = actor
    end
    return name
end

-- Settings

function Notifications:Settings()
    GP.db.profile.notifications = GP.db.profile.notifications or {}
    local s = GP.db.profile.notifications
    if s.loginSummary == nil then s.loginSummary = true end
    if s.allLevelUps == nil then s.allLevelUps = false end
    -- Switched-off categories; everything is included by default.
    if type(s.hidden) ~= "table" then s.hidden = {} end
    -- s.loginPopup stays nil until changed: officers default to the popup,
    -- members to no popup.
    return s
end

function Notifications:IsHidden(categoryKey)
    return self:Settings().hidden[categoryKey] == true
end

function Notifications:SetHidden(categoryKey, hidden)
    self:Settings().hidden[categoryKey] = hidden and true or nil
    GP:SendMessage("GuildParagon_NotificationsChanged")
end

function Notifications:WantsPopup()
    local s = self:Settings()
    if s.loginPopup ~= nil then return s.loginPopup == true end
    return GP:IsOfficer() == true
end

-- Last-online marker (account-wide, per guild)

local function guildData()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey and GP.db.global.guilds[guildKey], guildKey
end

local function markerTable(data)
    data.notifications = data.notifications or {}
    return data.notifications
end

function Notifications:MarkOnline()
    local data = guildData()
    if data then markerTable(data).lastOnline = time() end
end

-- Read state: a summary is unread until its card or the bell flyout has been
-- shown. Stored per guild for the account, so alts share it.
function Notifications:UnreadCount()
    local summary = self.summary
    local total = self:VisibleTotal(summary)
    if total == 0 then return 0 end
    local data = guildData()
    local readThrough = data and data.notifications and data.notifications.readThrough
    if type(readThrough) == "number" and readThrough >= summary.builtAt then return 0 end
    return total
end

-- Counted changes in categories that are still switched on, so switching a
-- category off also hides it from a summary that was already built.
function Notifications:VisibleTotal(summary)
    if not summary then return 0 end
    local total = 0
    for key, count in pairs(summary.counts) do
        if not self:IsHidden(Notifications.CATEGORY_OF[key]) then total = total + count end
    end
    return total
end

-- Remembers the attention items on screen when the bell flyout or login card
-- was shown, so the bell can tell new ones from ones already seen. Kept for
-- the session only: after a reload, open items count as new until seen.
local function attentionSnapshot(items)
    local seen = {}
    for _, item in ipairs(items) do
        if item.key == "applicants" then
            local ids = {}
            local Applicants = GP:GetModule("GuildApplicants", true)
            for guid in pairs(Applicants and Applicants.ids or {}) do ids[guid] = true end
            seen.applicants = { ids = ids }
        elseif item.key ~= "banwarning" then
            seen[item.key] = { count = item.count, expired = item.expired }
        end
    end
    return seen
end

function Notifications:MarkRead()
    local changed = self.glowPreview == true
    self.glowPreview = nil
    local data = guildData()
    if data and self.summary then
        local marker = markerTable(data)
        if marker.readThrough ~= self.summary.builtAt then
            marker.readThrough = self.summary.builtAt
            changed = true
        end
    end
    local hadUnseen = self:HasUnseen()
    self.attentionSeen = attentionSnapshot(self:CollectAttention())
    if changed or hadUnseen then GP:SendMessage("GuildParagon_NotificationsChanged") end
end

-- True while the bell holds something not yet seen: unread guild changes, a
-- new attention item, a new applicant, a higher welcome count, or a Guild
-- Finder listing that has since expired. Items that shrink lower the seen
-- value, so a later rise counts as new again.
function Notifications:HasUnseen()
    if self.glowPreview or self:UnreadCount() > 0 then return true end
    local seen = self.attentionSeen or {}
    local unseen = false
    local present = {}
    for _, item in ipairs(self:CollectAttention()) do
        local key = item.key
        present[key] = true
        local was = seen[key]
        if key == "banwarning" then
            -- Ban List matches are part of the unread guild changes.
        elseif not was then
            unseen = true
        elseif key == "applicants" then
            local Applicants = GP:GetModule("GuildApplicants", true)
            local ids = Applicants and Applicants.ids or {}
            for guid in pairs(ids) do
                if not was.ids[guid] then unseen = true end
            end
            for guid in pairs(was.ids) do
                if not ids[guid] then was.ids[guid] = nil end
            end
        elseif key == "listing" then
            if item.expired and not was.expired then unseen = true end
        elseif (item.count or 0) > (was.count or 0) then
            unseen = true
        else
            was.count = item.count
        end
    end
    for key in pairs(seen) do
        if not present[key] then seen[key] = nil end
    end
    return unseen
end

-- /gp testbell: makes the bell glow as if something new had arrived, without
-- changing any stored data. Opening the bell clears it like a real notice.
function Notifications:PreviewGlow()
    self.glowPreview = true
    GP.UI.MainWindow:Open()
    GP:SendMessage("GuildParagon_NotificationsChanged")
    GP:Print(GP.L["The notification bell is glowing as a test. Open it to clear the glow."])
end

-- Needs attention and coming up

-- Upcoming birthdays and anniversaries are listed for this many days ahead.
local UPCOMING_DAYS = 7

-- Open items that need an officer's action. Each item: key, count or days.
function Notifications:CollectAttention()
    local items = {}
    local _, guildKey = guildData()
    local Applicants = GP:GetModule("GuildApplicants", true)
    if Applicants and not self:IsHidden("applicants") and Applicants.state == "ready" and (Applicants.count or 0) > 0 and Applicants:CanUse() then
        items[#items + 1] = { key = "applicants", count = Applicants.count }
    end
    local Recruitment = GP:GetModule("Recruitment", true)
    if Recruitment and guildKey and not self:IsHidden("welcomes") and Recruitment:CanUse() then
        local count = Recruitment:GetAwaitingWelcomeCount(guildKey)
        if count > 0 then items[#items + 1] = { key = "welcomes", count = count } end
    end
    local Expiry = GP:GetModule("RecruitmentExpiry", true)
    if Expiry and Expiry.notice and not self:IsHidden("listing") then
        items[#items + 1] = { key = "listing", days = Expiry.notice.days, expired = Expiry.notice.expired }
    end
    local summary = self.summary
    if summary and not self:IsHidden("banwarning") and (summary.counts.banwarning or 0) > 0 then
        items[#items + 1] = { key = "banwarning", count = summary.counts.banwarning }
    end
    return items
end

-- Birthdays and guild anniversaries in the next week, soonest first, using
-- the Upcoming Dates settings for which kinds to include.
function Notifications:CollectUpcoming()
    local UpcomingDates = GP:GetModule("UpcomingDates", true)
    local GuildHealth = GP:GetModule("GuildHealth", true)
    if not UpcomingDates or self:IsHidden("upcoming") then return {} end
    if GuildHealth and not GuildHealth:CanUsePage("upcoming") then return {} end
    local _, guildKey = guildData()
    local rows = {}
    for _, row in ipairs(UpcomingDates:GetRows(guildKey)) do
        if type(row.daysRemaining) == "number" and row.daysRemaining <= UPCOMING_DAYS then
            rows[#rows + 1] = row
        end
    end
    return rows
end

-- Bell badge: unseen guild changes plus open attention items. Ban List
-- matches are already part of the unseen changes.
function Notifications:BadgeCount()
    local count = self:UnreadCount()
    for _, item in ipairs(self:CollectAttention()) do
        if item.key ~= "banwarning" then count = count + 1 end
    end
    return count
end

-- Lifecycle

-- Applicant and Guild Finder reminder cards wait while the login card is
-- being prepared, so login shows one card. They are released at most this
-- long after login even if no roster scan completes.
local HOLD_MAX = 120

function Notifications:OnEnable()
    self.state = "waiting"
    self.scans = 0
    self.enabledAt = GetTime()
    self:RegisterMessage("GuildParagon_RosterScanned", "OnRosterScanned")
    self:RegisterEvent("PLAYER_LOGOUT", "OnLogout")
    self:RegisterEvent("PLAYER_LEAVING_WORLD", function() self.loading = true end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        self.loading = false
        self:TryShowPending()
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "TryShowPending")
    C_Timer.After(HOLD_MAX, function()
        if (self.state == "waiting" or self.state == "building") and not self.popupPending then
            self:ReleaseLoginCards()
        end
    end)
end

function Notifications:HoldsLoginCards()
    if self.popupPending then return true end
    if self.state ~= "waiting" and self.state ~= "building" then return false end
    if not self.enabledAt or GetTime() - self.enabledAt >= HOLD_MAX then return false end
    return self:Settings().loginSummary == true and self:WantsPopup()
end

-- Lets held reminder cards show normally, after acknowledging the ones the
-- login card already included.
function Notifications:ReleaseLoginCards(included)
    included = included or {}
    local Applicants = GP:GetModule("GuildApplicants", true)
    if Applicants then
        if included.applicants then Applicants.notificationPending = nil end
        Applicants:NotifyChanged()
    end
    local Expiry = GP:GetModule("RecruitmentExpiry", true)
    if Expiry then
        if included.listing then Expiry:Dismiss() else Expiry:Check() end
    end
end

function Notifications:OnRosterScanned()
    local data, guildKey = guildData()
    if not data then return end
    if self.state ~= "waiting" then
        -- Keeps the marker current while online, so a crash or disconnect
        -- still leaves an accurate "last online" for the next login.
        if self.state == "ready" and guildKey == self.guildKey then self:MarkOnline() end
        return
    end
    -- The roster also announces chat-presence refreshes; only completed scans count.
    local scannedAt = data.lastScan
    if type(scannedAt) ~= "number" or scannedAt == self.lastScanSeen then return end
    self.lastScanSeen = scannedAt
    self.scans = self.scans + 1
    if self.scans == 1 then
        self.guildKey = guildKey
        self.firstScanAt = GetTime()
        self.ticker = C_Timer.NewTicker(CHECK_INTERVAL, function() self:CheckSettled() end)
    else
        self.secondScanAt = self.secondScanAt or GetTime()
    end
end

function Notifications:CheckSettled()
    if self.state ~= "waiting" or not self.firstScanAt then return end
    local now = GetTime()
    local settled = (now - self.firstScanAt) >= SETTLE_MAX
        or (self.secondScanAt and (now - self.secondScanAt) >= SETTLE_AFTER_SECOND_SCAN)
    if not settled then return end
    if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    self:BuildLoginSummary()
end

function Notifications:BuildLoginSummary()
    local data, guildKey = guildData()
    if not data or guildKey ~= self.guildKey then
        self.state = "done"
        self:ReleaseLoginCards()
        return
    end
    local marker = markerTable(data)
    local since = marker.lastOnline
    -- First run (or summaries switched off): start tracking from now.
    if type(since) ~= "number" or not self:Settings().loginSummary then
        self.state = "ready"
        self:MarkOnline()
        self:ReleaseLoginCards()
        return
    end

    self.state = "building"
    local EventLog = GP:GetModule("EventLog")
    local summary = Notifications.NewSummary(since, {
        isOfficer = GP:IsOfficer() == true,
        allLevelUps = self:Settings().allLevelUps == true,
        hidden = self:Settings().hidden,
        canDisplay = function(entry) return EventLog:CanDisplayEntry(entry) end,
    })
    local log = data.log or {}
    local index = Notifications.FirstIndexAfter(log, since)
    local token = {}
    self.buildToken = token
    local function step()
        if self.buildToken ~= token then return end
        local last = math.min(#log, index + ENTRIES_PER_FRAME - 1)
        for i = index, last do
            Notifications.AddEntry(summary, log[i])
        end
        index = last + 1
        if index <= #log then
            C_Timer.After(0, step)
            return
        end
        self:FinishLoginSummary(summary)
    end
    step()
end

function Notifications:FinishLoginSummary(summary)
    summary.builtAt = time()
    self.summary = summary
    self.state = "ready"
    self:MarkOnline()
    GP:SendMessage("GuildParagon_NotificationsChanged")
    if self:WantsPopup() and (self:VisibleTotal(summary) > 0 or #self:CollectAttention() > 0) then
        self.popupPending = true
        self:TryShowPending()
    else
        self:ReleaseLoginCards()
    end
end

function Notifications:OnLogout()
    -- Before the summary is built the marker is left alone, so a short session
    -- does not hide the changes it never showed.
    if self.state == "ready" then self:MarkOnline() end
end

function Notifications:IsSafe()
    if self.loading or GP:SafeCall(InCombatLockdown, true) then return false end
    if C_ChallengeMode and GP:SafeCall(C_ChallengeMode.IsChallengeModeActive, true) then return false end
    if type(IsInInstance) ~= "function" then return false end
    local ok, inside, kind = pcall(IsInInstance)
    if not ok or GP:IsSecretValue(inside) or GP:IsSecretValue(kind) then return false end
    return not inside or kind == "neighborhood" or kind == "interior"
end

function Notifications:TryShowPending()
    if not self.popupPending or not self.summary then return end
    if not self:IsSafe() then
        -- Re-checked on leaving combat or a loading screen; instances retry here.
        if not self.retryTimer then
            self.retryTimer = C_Timer.NewTicker(10, function()
                if not self.popupPending then
                    self.retryTimer:Cancel(); self.retryTimer = nil
                    return
                end
                self:TryShowPending()
            end)
        end
        return
    end
    self.popupPending = nil
    if self.retryTimer then self.retryTimer:Cancel(); self.retryTimer = nil end
    -- Attention items are read again here: applications may have arrived
    -- while the card waited for a safe moment.
    local attention = self:CollectAttention()
    if self:VisibleTotal(self.summary) == 0 and #attention == 0 then
        self:ReleaseLoginCards()
        return
    end
    local included = {}
    for _, item in ipairs(attention) do included[item.key] = true end
    GP.UI.Notifications:ShowSummary(self.summary, attention)
    self:MarkRead()
    self:ReleaseLoginCards(included)
end

-- Shows the most recent login summary on request, even when it is empty.
function Notifications:ShowLastSummary()
    if not self.summary then
        GP:Print(GP.L["No login summary yet. It is built shortly after your first roster scan."])
        return
    end
    GP.UI.Notifications:ShowSummary(self.summary, self:CollectAttention())
    self:MarkRead()
end

