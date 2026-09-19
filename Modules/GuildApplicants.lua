-- Guild Finder snapshots and explicit, confirmed applicant responses.
local _, GP = ...
local Applicants = GP:NewModule("GuildApplicants", "AceEvent-3.0")
local REFRESH_SECONDS, REQUEST_TIMEOUT = 90, 20

local function readable(value)
    if GP:IsSecretValue(value) then return nil end
    return value
end

local function field(record, key, expected)
    local value = readable(record[key])
    if type(value) == expected then return value end
end

function Applicants:ClearRecords()
    self.applicants, self.history, self.historyAvailable = nil, nil, false
    self.notificationPending = nil
    self.confirmation, self.responses, self.actionMessage, self.refreshQueued = nil, {}, nil, nil
end

function Applicants:ReadList(history)
    local fn
    if history then fn = C_ClubFinder.ReturnPendingClubApplicantList
    else fn = C_ClubFinder.ReturnClubApplicantList end
    local ok, result = pcall(function()
        if type(fn) ~= "function" then return nil end
        local raw = readable(fn(self.clubID))
        if type(raw) ~= "table" then return nil end
        local rows, seen = {}, {}
        for _, record in ipairs(raw) do
            if not readable(record) or type(record) ~= "table" then return nil end
            local player = field(record, "playerGUID", "string")
            local status = field(record, "requestStatus", "number")
            if not player or player == "" or not status then return nil end
            if not seen[player] and (history or status == Enum.PlayerClubRequestStatus.Pending) then
                seen[player] = true
                local row = { playerGUID = player, requestStatus = status,
                    clubFinderGUID = field(record, "clubFinderGUID", "string"),
                    name = field(record, "name", "string"), message = field(record, "message", "string"),
                    level = field(record, "level", "number"), ilvl = field(record, "ilvl", "number"),
                    classID = field(record, "classID", "number"), specIds = {} }
                local specs = readable(record.specIds)
                if type(specs) == "table" then
                    for _, spec in ipairs(specs) do
                        spec = readable(spec)
                        if type(spec) == "number" then row.specIds[#row.specIds+1] = spec end
                    end
                end
                rows[#rows+1] = row
            end
        end
        return rows
    end)
    if ok then return result end
end

function Applicants:StatusLabel(status)
    local names = {Pending="Pending", Approved="Approved", AutoApproved="Approved", Joined="Joined",
        JoinedAnother="Joined another guild", Canceled="Cancelled", Declined="Declined"}
    for key, label in pairs(names) do
        if Enum.PlayerClubRequestStatus[key] == status then return GP.L[label] end
    end
    return GP.L["Unknown status"]
end

function Applicants:IsSafe()
    if self.loading or GP:SafeCall(InCombatLockdown, true) then return false end
    if C_ChallengeMode and GP:SafeCall(C_ChallengeMode.IsChallengeModeActive, true) then return false end
    if type(IsInInstance) ~= "function" then return false end
    local ok, inside, kind = pcall(IsInInstance)
    inside, kind = readable(inside), readable(kind)
    if not ok or inside == nil then return false end
    return not inside or kind == "neighborhood" or kind == "interior"
end

function Applicants:CanUse()
    if not self:IsSafe() then return false end
    return GP:SafeCall(IsInGuild, false) == true
        and C_ClubFinder and GP:SafeCall(C_ClubFinder.IsEnabled, false) == true
        and GP:SafeCall(CanGuildInvite, false) == true
        and (GP:SafeCall(IsGuildLeader, false) == true
            or (C_GuildInfo and GP:SafeCall(C_GuildInfo.IsGuildOfficer, false) == true))
end

function Applicants:NotifyChanged()
    local tab = GP.UI and GP.UI.GuildApplicantsTab
    if tab and tab.UpdateNotification then tab:UpdateNotification(self) end
    local window = GP.UI and GP.UI.MainWindow
    if window and window.SetTabLabel then
        window:SetTabLabel("applications", self.count and self.count > 0
            and string.format(GP.L["Applications (%d)"], self.count) or GP.L["Applications"])
    end
    GP:SendMessage("GuildParagon_ApplicantsChanged")
end

function Applicants:CheckContext()
    if not self:IsSafe() then
        self.pending = nil
        self.confirmation = nil
        self.state = "paused"
        self:NotifyChanged()
        return false
    end
    if not self:CanUse() then
        self.clubID, self.count, self.ids, self.pending, self.lastSuccess = nil, nil, nil, nil, nil
        self:ClearRecords()
        self.state = "unavailable"
        self:NotifyChanged()
        return false
    end
    local id = C_Club and GP:SafeCall(C_Club.GetGuildClubId, nil)
    id = readable(id)
    if type(id) ~= "number" and type(id) ~= "string" then
        self.pending, self.confirmation = nil, nil
        self.state = "waiting"
        self:NotifyChanged()
        return false
    end
    if id ~= self.clubID then
        self.clubID, self.count, self.ids, self.pending, self.lastSuccess = id, nil, nil, nil, nil
        self.lastRequest = nil
        self.state = "waiting"
        self:ClearRecords()
    end
    return true
end

function Applicants:Request()
    if not self:CheckContext() then return end
    local now = GetTime()
    if self.pending or (self.lastRequest and now-self.lastRequest < 15) then
        self.refreshQueued = true
        return
    end
    self.refreshQueued = nil
    self.lastRequest, self.pending, self.state = now, now, "refreshing"
    self:NotifyChanged()
    local fn = C_ClubFinder and C_ClubFinder.RequestApplicantList
    local ok = type(fn) == "function" and pcall(fn, Enum.ClubFinderRequestType.Guild)
    if not ok then
        self.pending, self.state = nil, "unavailable"
        self:NotifyChanged()
    end
end

function Applicants:OnRecruitsUpdated(_, requestType)
    if readable(requestType) ~= Enum.ClubFinderRequestType.Guild then return end
    if not self:CheckContext() then return end
    local list = self:ReadList(false)
    self.confirmation = nil
    if not list then
        self.pending, self.state = nil, "unavailable"
        self:NotifyChanged()
        return
    end
    local ids, count, hasNew = {}, #list, false
    for _, row in ipairs(list) do
        ids[row.playerGUID] = true
        if not self.ids or not self.ids[row.playerGUID] then hasNew = true end
    end
    self.applicants = list
    local history = self:ReadList(true)
    self.historyAvailable = history ~= nil
    if history then self.history = history end
    self.responses = self.responses or {}
    for id, sent in pairs(self.responses) do
        if not ids[id] then
            self.responses[id] = nil
            self.actionMessage = GP.L["Application list updated by Blizzard."]
        elseif GetTime()-sent >= REQUEST_TIMEOUT then
            self.responses[id] = nil
            self.actionMessage = GP.L["The application is still pending. Blizzard has not confirmed the response; refresh before trying again."]
        end
    end
    self.ids, self.count, self.pending, self.lastSuccess, self.state = ids, count, nil, time(), "ready"
    if count == 0 then self.notificationPending = nil end
    if count > 0 and hasNew and not self.snoozed then
        self.notificationPending = true
        GP:Print(string.format(GP.L["%d guild applications await review. Open Guild Paragon > Applications."], count))
    end
    self:NotifyChanged()
end

function Applicants:Tick()
    if not self:CheckContext() then return end
    local now = GetTime()
    if self.pending and now-self.pending >= REQUEST_TIMEOUT then
        self.pending, self.state = nil, "unavailable"
        self:NotifyChanged()
    end
    if not self.lastRequest or now-self.lastRequest >= REFRESH_SECONDS or self.state == "paused"
        or (self.refreshQueued and not self.pending and now-self.lastRequest >= 15) then self:Request() end
end

function Applicants:StatusText()
    if self.state == "paused" then return GP.L["Application checks paused until you return to safe content."] end
    if not self:CanUse() then return GP.L["Guild Finder requires an officer or guild leader with invite permission."] end
    local count = self.count and string.format(GP.L["%d applications awaiting review"], self.count) or GP.L["Applications not checked yet"]
    if self.state ~= "ready" then count = count .. " — " .. GP.L["Waiting for a fresh response from Blizzard."] end
    return count
end

function Applicants:ValidateAction(row, approve)
    if not self:CheckContext() or self.state ~= "ready" then return nil end
    if not row or type(approve) ~= "boolean" or type(C_ClubFinder.RespondToApplicant) ~= "function" then return nil end
    if self.responses and self.responses[row.playerGUID] then return nil end
    local list = self:ReadList(false)
    if not list then return nil end
    for _, current in ipairs(list) do
        if current.playerGUID == row.playerGUID and current.clubFinderGUID == row.clubFinderGUID
            and current.name == row.name and current.name and current.name ~= ""
            and current.clubFinderGUID and current.clubFinderGUID ~= "" then
            if approve then
                local ok, available = pcall(function()
                    local info = readable(C_Club.GetClubInfo(self.clubID))
                    local capacity = readable(C_Club.GetClubCapacity())
                    local count = type(info) == "table" and field(info, "memberCount", "number")
                    return type(count) == "number" and type(capacity) == "number" and count < capacity
                end)
                if not ok or not available then
                    return nil, GP.L["The guild is full or its capacity could not be checked."]
                end
            end
            return current
        end
    end
end

function Applicants:PrepareResponse(row, approve)
    self.confirmation = nil
    local current, reason = self:ValidateAction(row, approve)
    if not current then return nil, reason or GP.L["Application data changed or is unavailable. Refresh and select the applicant again."] end
    local token = {row=current, approve=approve, clubID=self.clubID, expires=GetTime()+30}
    self.confirmation = token
    return token
end

function Applicants:ConfirmResponse(token)
    if not token or token ~= self.confirmation then return false end
    self.confirmation = nil
    if GetTime() > token.expires then return false, GP.L["Confirmation expired. Select the applicant again."] end
    local oldClub = self.clubID
    local current, reason = self:ValidateAction(token.row, token.approve)
    if not current or self.clubID ~= token.clubID or oldClub ~= self.clubID then
        return false, reason or GP.L["Application data changed or is unavailable. Refresh and select the applicant again."]
    end
    -- Only called by the explicit confirmation button. Never force acceptance or report an applicant.
    self.responses = self.responses or {}
    self.responses[current.playerGUID] = GetTime()
    local ok = pcall(C_ClubFinder.RespondToApplicant, current.clubFinderGUID, current.playerGUID,
        token.approve, Enum.ClubFinderRequestType.Guild, current.name, false, false)
    local audit = GP:GetModule("ApplicantAudit", true)
    if audit and type(audit.Record) == "function" then
        local recorded, saved = pcall(audit.Record, audit, current, token.approve, ok)
        if not recorded or not saved then GP:Print(GP.L["The response could not be added to the local audit history."]) end
    end
    if not ok then self.responses[current.playerGUID] = nil end
    self.actionMessage = ok and GP.L["Response sent; waiting for Blizzard to update the application."]
        or GP.L["Blizzard could not process the response. Refresh and try again."]
    self:NotifyChanged()
    self.refreshQueued = true
    self:Request()
    return ok, self.actionMessage
end

function Applicants:OnTransition(event)
    self.confirmation = nil
    if event == "PLAYER_LEAVING_WORLD" then self.loading = true
    elseif event == "PLAYER_ENTERING_WORLD" then self.loading = false end
    if event == "PLAYER_GUILD_UPDATE" then
        self:ClearRecords()
        self.clubID, self.ids, self.count, self.lastRequest, self.lastSuccess, self.pending = nil, nil, nil, nil, nil, nil
    end
    self:Tick()
end

function Applicants:OnApplicationsUpdated(_, requestType)
    if readable(requestType) == Enum.ClubFinderRequestType.Guild then self:Request() end
end

function Applicants:OnEnable()
    self.loading = true
    self.state = "waiting"
    self:RegisterEvent("CLUB_FINDER_RECRUITS_UPDATED", "OnRecruitsUpdated")
    self:RegisterEvent("CLUB_FINDER_APPLICATIONS_UPDATED", "OnApplicationsUpdated")
    for _, event in ipairs({"PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_GUILD_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED"}) do
        self:RegisterEvent(event, "OnTransition")
    end
    self.ticker = C_Timer.NewTicker(10, function() self:Tick() end)
end

function Applicants:OnDisable()
    self:ClearRecords()
    if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    self:UnregisterAllEvents()
    self.count, self.ids, self.pending = nil, nil, nil
    self.state = "unavailable"
    self:NotifyChanged()
end
