-- Guild Paragon core lifecycle and shared addon table.
local ADDON_NAME, GP = ...

LibStub("AceAddon-3.0"):NewAddon(GP, ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0")

GP.L = LibStub("AceLocale-3.0"):GetLocale(ADDON_NAME)

-- AceDB defaults: profile stores settings; global stores per-guild data.
GP.defaults = {
    profile = {
        minimapIcon = {
            hide = false,
            angle = 225,
        },
        scan = {
            login = true,
            rosterUpdates = true,
        },
        ui = {
            autoHideInCombat = true,
            scale = 1.0,
        },
        macroTool = {
            action = "kick",
            minOfflineDays = 180,
            minRankDays = 0,
            maxOfflineDays = 0,
            includeOnline = false,
            targetScope = "all",
            targetRankIndex = nil,
            targetRanks = {},
            specialSameRank = false,
            specialDisableDemote = false,
            allRanks = true,
            selectedRanks = {},
            levelMode = "all",
            minLevel = 1,
            maxLevel = 90,
            requireText = "",
            requireTextEmptyOnly = false,
            safeText = "",
            safeTextAllNotes = false,
            suppressMacroChatSpam = true,
            savedRules = {},
            savedRulesUpdated = {},
        },
        backupRestore = {
            maxBackups = 3,
        },
        eventLog = {
            numberedLines = true,
            categoryColors = true,
            toChat = {},
            filters = {
                join = true,
                leave = true,
                promote = true,
                demote = true,
                level = true,
                inactivereturn = true,
                note = true,
                officernote = true,
                customnote = true,
                customofficernote = true,
                nickname = true,
                altlinked = true,
                altcleared = true,
                markedmain = true,
                unmarkedmain = true,
                birthday = true,
                ban = true,
                grmimport = true,
                label = true,
            },
        },
        guildChat = {
            guild = true,
            officer = true,
            party = false,
            raid = false,
            achievements = false,
            nicknames = true,
            preferNickname = true,
            appendOwnNickname = false,
            showTags = true,
            showMainName = true,
            fallbackToMainName = true,
            classColor = true,
        },
        guildHealth = {
            showBirthdayIssues = true,
            ignoreAltsWhenMainActive = true,
            activeDays = 7,
            fadingDays = 14,
            atRiskDays = 30,
            goneDays = 60,
        },
        recruitment = {
            requireOfficer = false,
            manualReview = true,
            obeyBlockInvites = true,
            antiSpam = true,
            antiSpamDays = 14,
            pendingTimeoutDays = 7,
            messageDelay = 0.5,
            executorMode = "whisper",
            retailContextMenus = false,
            welcomeGuild = false,
            welcomeGuildMessage = "Welcome PLAYERNAME to GUILDNAME!",
            welcomeWhisper = false,
            welcomeWhisperMessage = "Welcome to GUILDNAME, PLAYERNAME!",
            gmEnforced = false,
            lockMessages = false,
            lockFilters = false,
            scannerEnabled = false,
            inviteQueueEnabled = false,
        },
        roster = {
            display = {
                classColorNames = true,
                showLevel = true,
                blizzardTooltips = true,
            },
            auditFilters = {
                issues = false,
                tag = false,
                join = false,
                promo = false,
                birthday = false,
                conflict = false,
            },
        },
    },
    global = {
        guilds = {
            -- ["GuildName-ClubID"] = { roster/former/log/sync tables }
        },
        backups = {
            -- ["GuildName-ClubID"] = { [backupID] = { metadata..., data = guildDataSnapshot } }
        },
    },
}

function GP:OnInitialize()
    -- "GuildParagonDB" is the account-wide SavedVariable, profile-aware via
    -- AceDB (true = per-character profile keying isn't forced; users can
    -- still create/share profiles later via AceDBOptions if we add it).
    self.db = LibStub("AceDB-3.0"):New("GuildParagonDB", self.defaults, true)

    self:RegisterChatCommand("gp", "SlashCommand")
    self:RegisterChatCommand("guildparagon", "SlashCommand")
end

local function buildPlaceholderTab(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local text = frame:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(GP.UI.Theme.font.muted)
    text:SetPoint("TOPLEFT")
    text:SetText(GP.L["This section hasn't been built yet — check back in a future update."])

    return frame
end

function GP:OnEnable()
    -- Passive heap sampling for /gp perf diagnostics.
    self:StartGCHeapTracking()

    -- Register tabs after every UI file has loaded; order is nav order.
    local MainWindow = self.UI.MainWindow
    MainWindow:RegisterTab("roster", self.L["Roster"], function(parent) return self.UI.RosterTab:Build(parent) end)
    MainWindow:RegisterTab("guildhealth", self.L["Guild Health"], function(parent) return self.UI.GuildHealthTab:Build(parent) end,
        function() return self:GetModule("GuildHealth"):CanUse() end)
    MainWindow:RegisterTab("log", self.L["Event Log"], function(parent) return self.UI.EventLogTab:Build(parent) end)
    MainWindow:RegisterTab("recruitment", self.L["Recruitment"], function(parent) return self.UI.RecruitmentTab:Build(parent) end,
        function() return self:GetModule("Recruitment"):CanUse() end)
    MainWindow:RegisterTab("bans", self.L["Ban List"], function(parent) return self.UI.BanListTab:Build(parent) end,
        function() return self:GetModule("BanList"):CanUse() end)
    MainWindow:RegisterTab("sync", self.L["Guild Sync"], function(parent) return self.UI.GuildSyncTab:Build(parent) end)
    MainWindow:RegisterTab("macro", self.L["Macro Tool"], function(parent) return self.UI.MacroToolTab:Build(parent) end,
        function() return self:GetModule("MacroTool"):CanUse() end)
    MainWindow:RegisterTab("settings", self.L["Settings"], function(parent) return self.UI.Settings:Build(parent) end)
    MainWindow:RegisterTab("help", self.L["Help"], function(parent) return self.UI.HelpTab:Build(parent) end)
end

function GP:IsOfficer()
    local CustomNotes = self:GetModule("CustomNotes", true)
    if CustomNotes and CustomNotes.CanAccessOfficerNotes then
        return CustomNotes:CanAccessOfficerNotes() and true or false
    end
    if C_GuildInfo and C_GuildInfo.CanViewOfficerNote then
        return self:SafeBool(self:SafeCall(C_GuildInfo.CanViewOfficerNote, false), false)
    end
    if CanViewOfficerNote then
        return self:SafeBool(self:SafeCall(CanViewOfficerNote, false), false)
    end
    if CanEditOfficerNote then
        return self:SafeBool(self:SafeCall(CanEditOfficerNote, false), false)
    end
    return false
end

function GP:IsSelfGUID(guid)
    return guid and UnitGUID and UnitGUID("player") == guid
end

local debouncePending = {}
function GP:DebounceCall(key, fn)
    if debouncePending[key] then return end
    debouncePending[key] = true
    C_Timer.After(0, function()
        debouncePending[key] = nil
        fn()
    end)
end

function GP:CanEditMemberProfile(guid)
    if self:IsOfficer() or self:IsSelfGUID(guid) then return true end
    if not guid or not UnitGUID then return false end

    local playerGUID = UnitGUID("player")
    if not playerGUID then return false end

    local Roster = self:GetModule("Roster", true)
    local Alts = self:GetModule("Alts", true)
    if not Roster or not Alts or not Roster.GetGuildKey then return false end

    local guildKey = Roster:GetGuildKey()
    if not guildKey then return false end

    local playerMain = Alts:GetMain(guildKey, playerGUID) or playerGUID
    local targetMain = Alts:GetMain(guildKey, guid) or guid
    return playerMain == targetMain
end

function GP:IsGuildMaster()
    local rankIndex
    if GetGuildInfo then
        local ok, guildName, rankName, index = pcall(GetGuildInfo, "player")
        if ok and guildName and rankName then rankIndex = index end
    end
    return tonumber(rankIndex) == 0
end

function GP:SlashCommand(input)
    input = strtrim(input or "")
    local cmd, rawRest = input:match("^(%S*)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""
    rawRest = rawRest or ""
    local rest = rawRest:lower()

    if cmd == "roster" then
        self:GetModule("Roster"):DumpRosterToChat()
    elseif cmd == "log" then
        local guildKey = self:GetModule("Roster").currentGuildKey
        self:GetModule("EventLog"):DumpToChat(guildKey, tonumber(rest))
    elseif cmd == "scan" then
        -- Scan() may finish on a later frame; print completion from its callback.
        local started, startErr
        started, startErr = self:GetModule("Roster"):Scan(false, function(ok, err)
            if not started then return end
            self:Print(ok and self.L["Roster scan complete."] or (err or self.L["Roster scan skipped."]))
        end)
        if not started then
            self:Print(startErr or self.L["Roster scan skipped."])
        end
    elseif cmd == "perf" then
        self:PrintPerformance()
    elseif cmd == "minimap" then
        local Launcher = self:GetModule("Launcher", true)
        if Launcher and Launcher.SetMinimapShown and Launcher.IsMinimapShown then
            local shown = not Launcher:IsMinimapShown()
            Launcher:SetMinimapShown(shown)
            self:Print(shown and self.L["Minimap button shown."] or self.L["Minimap button hidden. Addon compartment entry remains available."])
        end
    elseif cmd == "chatpreview" then
        local name = strtrim(rawRest)
        if name == "" then
            self:Print(self.L["Usage: /gp chatpreview CharacterName"])
            return
        end
        local hint = self:GetModule("GuildChat"):BuildHintForName(name)
        if hint then
            self:Print(string.format(self.L["Chat hint preview for %s: %s: Example guild message"], name, hint))
        else
            self:Print(string.format(self.L["No guild chat hint found for %s."], name))
        end
    elseif cmd == "fulllog" then
        if self:GetModule("GuildSync"):RequestFullLogBootstrap(nil, true) then
            self:Print(self.L["Requesting full Event Log history from online Guild Paragon users..."])
        else
            self:Print(self.L["Full Event Log sync is temporarily disabled, or no guild data is available yet."])
        end
    elseif cmd == "cleanuplog" then
        self:CleanupLog(rest == "confirm")
    elseif cmd == "trimlog" then
        self:TrimLog(rest == "confirm")
    elseif cmd == "normalizejoindates" then
        self:NormalizeJoinDates(rest == "confirm")
    elseif cmd == "migratejoindates" then
        self:MigrateJoinDates(rest == "confirm")
    elseif cmd == "stripjoindatenotes" then
        self:StripJoinDateNotes(rest == "confirm")
    elseif cmd == "fixgrmlogdates" then
        self:FixGRMLogDates(rest == "confirm")
    elseif cmd == "importgrm" then
        self:ImportGRM(rest == "confirm")
    else
        self.UI.MainWindow:Toggle()
    end
end

function GP:FixGRMLogDates(confirmed)
    if not self:IsOfficer() then
        self:Print(self.L["This command is restricted to guild officers."])
        return
    end

    local guildKey = self:GetModule("Roster").currentGuildKey or self:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self:Print(self.L["No log data yet — try /gp scan."])
        return
    end

    local EventLog = self:GetModule("EventLog")
    if not confirmed then
        local count = EventLog:GetGRMImportDateFixPlan(guildKey)
        if not count then
            self:Print(self.L["No log data yet — try /gp scan."])
        elseif count == 0 then
            self:Print(self.L["No imported GRM log dates need cleanup."])
        else
            self:Print(string.format(self.L["Found %d imported GRM log row(s) with duplicate dates. Run /gp fixgrmlogdates confirm to move those dates into Guild Paragon timestamps."], count))
        end
        return
    end

    local fixed, err = EventLog:FixGRMImportDates(guildKey)
    if not fixed then
        self:Print(err)
    elseif fixed == 0 then
        self:Print(self.L["No imported GRM log dates need cleanup."])
    else
        self:Print(string.format(self.L["Fixed %d imported GRM log row(s)."], fixed))
    end
end

function GP:NormalizeJoinDates(confirmed)
    if not self:IsOfficer() then
        self:Print(self.L["This command is restricted to guild officers."])
        return
    end

    local guildKey = self:GetModule("Roster").currentGuildKey or self:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self:Print(self.L["No roster data yet — try /gp scan."])
        return
    end

    local count = self:GetModule("CustomNotes"):NormalizeJoinDateFormat(guildKey, confirmed)
    if not count then
        self:Print(self.L["No roster data yet — try /gp scan."])
    elseif count == 0 then
        self:Print(self.L["No DD-MM-YY join dates found in custom notes."])
    elseif confirmed then
        self:Print(string.format(self.L["Normalized %d custom-note join date(s) to YYYY-MM-DD."], count))
    else
        self:Print(string.format(self.L["Found %d custom-note join date(s) using DD-MM-YY. Run /gp normalizejoindates confirm to convert them to YYYY-MM-DD."], count))
    end
end

function GP:MigrateJoinDates(confirmed)
    if not self:IsGuildMaster() then
        self:Print(self.L["This command is restricted to the guild master."])
        return
    end

    local guildKey = self:GetModule("Roster").currentGuildKey or self:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self:Print(self.L["No roster data yet — try /gp scan."])
        return
    end

    local count, err = self:GetModule("Roster"):MigrateNoteJoinDates(guildKey, confirmed)
    if not count then
        self:Print(err or self.L["No roster data yet — try /gp scan."])
    elseif count == 0 then
        self:Print(self.L["No unmigrated custom-note join dates found."])
    elseif confirmed then
        self:Print(string.format(self.L["Migrated %d join date(s) from custom notes to Guild Paragon's join-date field."], count))
    else
        self:Print(string.format(self.L["Found %d join date(s) still only in custom notes. Run /gp migratejoindates confirm to move them into Guild Paragon's join-date field."], count))
    end
end

function GP:StripJoinDateNotes(confirmed)
    if not self:IsGuildMaster() then
        self:Print(self.L["This command is restricted to the guild master."])
        return
    end

    local guildKey = self:GetModule("Roster").currentGuildKey or self:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self:Print(self.L["No roster data yet — try /gp scan."])
        return
    end

    local count, err = self:GetModule("CustomNotes"):StripJoinDateTags(guildKey, confirmed)
    if not count then
        self:Print(err or self.L["No roster data yet — try /gp scan."])
    elseif count == 0 then
        self:Print(self.L["No Joined:/Rejoined: tags found in custom notes."])
    elseif confirmed then
        self:Print(string.format(self.L["Removed Joined:/Rejoined: tags from %d custom note(s)."], count))
    else
        self:Print(string.format(self.L["Found %d custom note(s) with a Joined:/Rejoined: tag. Run /gp stripjoindatenotes confirm to remove them."], count))
    end
end

function GP:PrintPerformance()
    if UpdateAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
    end
    if UpdateAddOnCPUUsage then
        UpdateAddOnCPUUsage()
    end

    local memoryKb = GetAddOnMemoryUsage and GetAddOnMemoryUsage(ADDON_NAME) or 0
    local cpuMs = GetAddOnCPUUsage and GetAddOnCPUUsage(ADDON_NAME) or nil
    local Roster = self:GetModule("Roster")
    local stats = Roster:GetPerformanceStats()
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    local guildData = guildKey and self.db.global.guilds[guildKey]
    local activeCount, formerCount = 0, 0
    if guildData then
        activeCount, formerCount = Roster:CountMembers(guildData)
    end
    local EventLog = self:GetModule("EventLog")
    local currentLogCount = guildKey and EventLog:CountDisplayable(guildKey) or 0
    local totalLogCount = EventLog:GetDisplayableTotalCount()

    self:Print(string.format(self.L["Performance: %.1f MB memory, %d active, %d former."], (memoryKb or 0) / 1024, activeCount, formerCount))

    -- Passive whole-UI Lua heap sample.
    local gcHeap = self:GetGCHeapStats()
    if gcHeap.currentKB > 0 then
        if gcHeap.largestDropKB > 0 then
            self:Print(string.format(self.L["Lua GC: heap %.1f MB, high-water %.1f MB, largest drop %.1f MB %ds ago."],
                gcHeap.currentKB / 1024, gcHeap.highKB / 1024, gcHeap.largestDropKB / 1024,
                math.max(0, time() - gcHeap.largestDropAt)))
        else
            self:Print(string.format(self.L["Lua GC: heap %.1f MB, high-water %.1f MB. No drop observed yet this session."],
                gcHeap.currentKB / 1024, gcHeap.highKB / 1024))
        end
    end

    self:Print(string.format(self.L["Event Log: %d current guild, %d account-wide. Retention target: %d newest entries per guild."],
        currentLogCount, totalLogCount, EventLog:GetRetentionLimit()))
    if currentLogCount >= 75000 or totalLogCount >= 100000 then
        self:Print(self.L["Event Log warning: log history is very large. Consider /gp trimlog after exporting anything you want to keep."])
    elseif currentLogCount >= 50000 or totalLogCount >= 75000 then
        self:Print(self.L["Event Log warning: log history is above the normal retention target. /gp trimlog will dry-run cleanup."])
    elseif currentLogCount >= 25000 or totalLogCount >= 50000 then
        self:Print(self.L["Event Log notice: log history is growing. No action is required yet."])
    end
    self:Print(string.format(self.L["Roster scans: %d complete, %d requested, %d queued, %d coalesced, %d skipped; last %.2f ms, avg %.2f ms, max %.2f ms, last size %d."],
        stats.completed, stats.requested, stats.queued, stats.coalesced, stats.skippedReentrant,
        stats.lastMs, stats.avgMs, stats.maxMs, stats.lastMembers))

    -- Time-only scan counters; no memory sampling on the scan path.
    if stats.completed > 0 then
        self:Print(string.format(self.L["Roster scan timing: last %.0f ms, %ds ago; max %.0f ms, %ds ago."],
            stats.lastMs, math.max(0, time() - stats.lastAt),
            stats.maxMs, math.max(0, time() - stats.maxAt)))
    end

    if cpuMs and cpuMs > 0 then
        self:Print(string.format(self.L["CPU since UI load: %.2f ms. Blizzard only reports this when script profiling is enabled."], cpuMs))
    else
        self:Print(self.L["CPU since UI load: unavailable unless script profiling is enabled."])
    end

    -- Raw transfer decode timing, shown only by explicit /gp perf.
    local GuildSync = self:GetModule("GuildSync", true)
    local timing = GuildSync and GuildSync.lastHeavySyncTiming
    if timing then
        self:Print(string.format(
            self.L["Last raw sync decode (%s%s, %ds ago): concat %.2f ms, decompress %.2f ms, deserialize %.2f ms%s."],
            timing.op or "?", timing.category and (":" .. timing.category) or "",
            math.max(0, time() - (timing.at or time())),
            timing.concatMs or 0, timing.decompressMs or 0, timing.deserializeMs or 0,
            (timing.deferredMs or 0) > 0 and string.format(self.L[" (deferred %.0f ms by the heavy-sync scheduler)"], timing.deferredMs) or ""))
    end

    -- Calibrate measurement overhead on demand.
    local overhead = self:PerfCalibrateOverhead()
    self:Print(string.format(
        self.L["PerfTrace overhead: UpdateAddOnMemoryUsage() avg %.2f ms, max %.2f ms (%d samples)."],
        overhead.avgMs, overhead.maxMs, overhead.samples))

    -- Login-only allocation samples, shown only by explicit /gp perf.
    for _, entry in ipairs(self:PerfSnapshot(3)) do
        local rec = entry.rec
        self:Print(string.format(
            self.L["Allocation (%s): best +%.0f KB / %.1f ms (%ds ago), last %+.0f KB / %.1f ms%s."],
            entry.label, rec.bestKB, rec.bestMs, math.max(0, time() - (rec.bestAt or time())),
            rec.lastKB, rec.lastMs,
            rec.lastKB < 0 and self.L[" (a garbage collection likely ran during this pass)"] or ""))
    end
end

function GP:TrimLog(confirmed)
    if not self:IsOfficer() then
        self:Print(self.L["This command is restricted to guild officers."])
        return
    end

    local guildKey = self:GetModule("Roster").currentGuildKey or self:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self:Print(self.L["No roster data yet — try /gp scan."])
        return
    end

    local EventLog = self:GetModule("EventLog")
    local plan = EventLog:GetTrimPlan(guildKey)
    if plan.remove == 0 then
        self:Print(string.format(self.L["Event Log trim not needed: %d entries, retention target is %d."], plan.total, plan.retain))
        return
    end

    if not confirmed then
        self:Print(string.format(self.L["Event Log trim ready: %d entries found. This will remove the oldest %d and keep the newest %d. Run /gp trimlog confirm to continue."],
            plan.total, plan.remove, plan.retain))
        return
    end

    local removed, kept, previousTotal = EventLog:TrimToNewest(guildKey)
    self:Print(string.format(self.L["Event Log trimmed: removed %d oldest entries, kept %d newest entries from %d total."],
        removed, kept, previousTotal))
end

function GP:ImportGRM(confirmed)
    if not self:IsGuildMaster() then
        self:Print(self.L["This command is restricted to the guild master."])
        return
    end

    local Importer = self:GetModule("GRMImport")

    if not confirmed then
        local plan, err = Importer:GetPlan()
        if not plan then
            self:Print(err)
            return
        end
        self:Print(string.format(self.L["GRM import ready for %s: %d active, %d former, %d alt group(s), %d log record(s). This will wipe Guild Paragon data for this guild only. Run /gp importgrm confirm to continue."],
            plan.guildName, plan.activeCount, plan.formerCount, plan.altGroupCount, plan.logCount))
        return
    end

    local result, err = Importer:ImportCurrentGuild()
    if not result then
        self:Print(err)
        return
    end

    self:Print(string.format(self.L["GRM import complete for %s: %d active, %d former, %d alt link(s), %d main flag(s), %d nickname(s), %d custom note(s), %d macro ignore(s), %d log record(s). Skipped: %d member(s), %d alt record(s)."],
        result.guildName, result.activeImported, result.formerImported, result.linkedAlts, result.markedMains,
        result.nicknames, result.customNotes, result.macroIgnores, result.logEntries, result.activeSkipped + result.formerSkipped, result.skippedAltMembers))
end

function GP:CleanupLog(confirmed)
    if not self:IsOfficer() then
        self:Print(self.L["This command is restricted to guild officers."])
        return
    end

    local guildKey = self:GetModule("Roster").currentGuildKey or self:GetModule("Roster"):GetGuildKey()
    if not guildKey then
        self:Print(self.L["No roster data yet — try /gp scan."])
        return
    end

    local EventLog = self:GetModule("EventLog")

    if confirmed then
        local removed, batchCount = EventLog:RemoveSuspiciousBatches(guildKey)
        if removed == 0 then
            self:Print(self.L["No suspicious log entries found — nothing removed."])
        else
            self:Print(string.format(self.L["Removed %d suspicious log entries across %d batch(es)."], removed, batchCount))
        end
        return
    end

    local batches = EventLog:FindSuspiciousBatches(guildKey)
    if #batches == 0 then
        self:Print(self.L["No suspicious log entries found."])
        return
    end

    local total = 0
    for _, batch in ipairs(batches) do
        total = total + #batch.entries
    end
    self:Print(string.format(self.L["Found %d suspicious log entries across %d batch(es). Run /gp cleanuplog confirm to remove them."], total, #batches))

    for i, batch in ipairs(batches) do
        if i > 20 then
            self:Print(string.format(self.L["  ...and %d more batch(es)."], #batches - 20))
            break
        end
        self:Print("  " .. string.format(self.L["%s — %d %s event(s)"], date("%Y-%m-%d %H:%M", batch.ts), #batch.entries, batch.type))
    end
end
