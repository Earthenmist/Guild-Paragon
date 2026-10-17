-- Daily, local-only reminders for the guild's native Guild Finder listing.
local _, GP = ...
local Expiry = GP:NewModule("RecruitmentExpiry", "AceEvent-3.0")
local DAY = 86400
local function number(value)
    if not GP:IsSecretValue(value) and type(value)=="number" and value==value and math.abs(value)<1e14 then return value end
end
function Expiry:GetDays()
    local days=number(GP.db.profile.recruitmentExpiryDays)
    return days and math.max(0,math.min(30,math.floor(days))) or 10
end
function Expiry:SetDays(value)
    local days=tonumber(value)
    if not number(days) or days<0 or days>30 or days~=math.floor(days) then return false end
    GP.db.profile.recruitmentExpiryDays=days
    if days==0 then self:Dismiss() end
    self:Check()
    return true
end
function Expiry:Record(club)
    local records=GP.db.global.recruitmentExpiryChecks
    if type(records)~="table" then records={};GP.db.global.recruitmentExpiryChecks=records end
    local key=tostring(club)
    if type(records[key])~="table" then records[key]={} end
    return records[key]
end
function Expiry:Guild()
    if self.loading or self:GetDays()==0 then return nil end
    return GP.UI.GuildRecruitment:GetGuild()
end
function Expiry:Hide()
    if GP.UI.RecruitmentExpiry then GP.UI.RecruitmentExpiry:Hide() end
end
function Expiry:Dismiss()
    if self.notice then
        self:Record(self.notice.club).notified=number(GP:SafeCall(GetServerTime,nil))
    end
    self.notice=nil
    self:Hide()
end
function Expiry:Evaluate(club, now)
    local record=self:Record(club)
    local serverNow=number(GP:SafeCall(C_DateAndTime and C_DateAndTime.GetServerTimeLocal,nil))
    if not serverNow or not number(record.expires) or record.enabled~=true then self:Dismiss();return end
    local days=math.floor((record.expires-serverNow)/DAY)
    if days>=self:GetDays() then self:Dismiss();return end
    if self.notice and self.notice.club~=club then self:Dismiss() end
    local notified=number(record.notified)
    if not self.notice and notified and now>=notified and now-notified<DAY then return end
    -- Stamp only when the reminder can actually be displayed in a safe context.
    local first=not self.notice
    self.notice={club=club,days=math.max(0,days),expired=record.expires<=serverNow}
    if GP.UI.RecruitmentExpiry:Show(self.notice.days,self.notice.expired) and first then record.notified=now end
end
function Expiry:Read(club)
    if self:Guild()~=club then return false end
    local info=GP:SafeCall(C_ClubFinder.GetRecruitingClubInfoFromClubID,nil,club)
    if GP:IsSecretValue(info) or type(info)~="table" then return false end
    if GP:IsSecretValue(info.clubId) or info.clubId~=club then return false end
    local flags,updated=number(info.recruitmentFlags),number(info.lastUpdatedTime)
    local serverNow=number(GP:SafeCall(C_DateAndTime and C_DateAndTime.GetServerTimeLocal,nil))
    if not flags or not updated or updated<=0 or not serverNow or updated>serverNow+60 then return false end
    local enabled=GP:SafeCall(C_ClubFinder.IsListingEnabledFromFlags,nil,flags)
    if GP:IsSecretValue(enabled) or type(enabled)~="boolean" then return false end
    local now=number(GP:SafeCall(GetServerTime,nil))
    if not now then return false end
    local record=self:Record(club)
    -- Match Blizzard's 30-day posting lifetime and server-local timestamp basis.
    record.enabled,record.expires,record.checked=enabled,updated+30*DAY,now
    record.failures=0
    self.pending=nil
    self:Evaluate(club,now)
    return true
end
function Expiry:Check()
    local club=self:Guild()
    if not club then self.pending=nil;self:Hide();return end
    local now=number(GP:SafeCall(GetServerTime,nil))
    if not now then return end
    if self.notice and self.notice.club~=club then self:Dismiss() end
    self.currentClub=club
    local record=self:Record(club)
    local checked=number(record.checked)
    if checked and now>=checked and now-checked<DAY then self:Evaluate(club,now);return end
    if self.pending and self.pending.club==club and now-self.pending.at<45 then return end
    self.pending=nil
    self:Hide()
    local attempted=number(record.attempted)
    local failures=number(record.failures) or 0
    local retryDelay=failures>=3 and DAY or 300
    if attempted and now>=attempted and now-attempted<retryDelay then return end
    record.attempted,record.failures=now,failures+1
    self.pending={club=club,at=now}
    local requested=GP:SafeCall(C_ClubFinder.RequestPostingInformationFromClubId,nil,club)
    -- Blizzard returns false when the posting is already cached.
    if requested==false then self:Read(club)
    elseif requested~=true then self.pending=nil end
end
function Expiry:OnPostingReturned()
    if self.pending then self:Read(self.pending.club) end
end
function Expiry:OnPostingUpdated()
    local club=self:Guild() or self.currentClub
    self:Dismiss()
    self.pending=nil
    if club then
        local record=self:Record(club)
        record.checked,record.attempted=nil,nil
        self:Check()
    end
end
function Expiry:OnContext(event)
    if event=="PLAYER_LEAVING_WORLD" then self.loading=true
    elseif event=="PLAYER_ENTERING_WORLD" then self.loading=false end
    self:Check()
end
function Expiry:OnEnable()
    self.loading=true
    for _,event in ipairs({"PLAYER_ENTERING_WORLD","PLAYER_LEAVING_WORLD","PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","PLAYER_GUILD_UPDATE"})do
        self:RegisterEvent(event,"OnContext")
    end
    GP:RegisterOptionalEvent(self, "CLUB_FINDER_RECRUITMENT_POST_RETURNED","OnPostingReturned")
    GP:RegisterOptionalEvent(self, "CLUB_FINDER_POST_UPDATED","OnPostingUpdated")
    self.ticker=C_Timer.NewTicker(60,function()self:Check()end)
end
function Expiry:OnDisable()
    if self.ticker then self.ticker:Cancel();self.ticker=nil end
    self:UnregisterAllEvents()
    self.pending=nil;self.loading=true
    self:Dismiss()
end
