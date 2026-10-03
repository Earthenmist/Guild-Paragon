-- Explicit, single-member rank macro preparation; execution uses the native macro binding.
local _, GP = ...
local Ranks = GP:NewModule("RosterRanks", "AceEvent-3.0")
local function safe(v, kind)
    if not GP:IsSecretValue(v) and type(v) == kind then return v end
end
function Ranks:CanUse()
    if self.loading or GP:SafeCall(InCombatLockdown,true) or not GP:SafeCall(IsInGuild,false) then return false end
    if C_ChallengeMode and GP:SafeCall(C_ChallengeMode.IsChallengeModeActive,true) then return false end
    local ok,inside,kind=pcall(IsInInstance)
    inside,kind=safe(inside,"boolean"),safe(kind,"string")
    if not ok or inside == nil or (inside and kind ~= "neighborhood" and kind ~= "interior") then return false end
    local macro=GP:GetModule("MacroTool",true)
    return macro and macro:CanUse() and (GP:SafeCall(CanGuildPromote,false) == true or GP:SafeCall(CanGuildDemote,false) == true)
end
function Ranks:Snapshot(guid)
    if not self:CanUse() or not safe(guid,"string") then return nil end
    local own=GP:SafeCall(UnitGUID,nil,"player")
    if not safe(own,"string") or guid == own then return nil end
    local club=GP:SafeCall(C_Club and C_Club.GetGuildClubId,nil)
    if not safe(club,"number") and not safe(club,"string") then return nil end
    local count=GP:SafeCall(GetNumGuildMembers,nil)
    if not safe(count,"number") or count < 1 or count > 2000 then return nil end
    for i=1,count do
        local ok,info=pcall(function()return {GetGuildRosterInfo(i)}end)
        if ok and safe(info[17],"string") == guid then
            local name, rank=safe(info[1],"string"),safe(info[3],"number")
            if name and rank and rank > 0 and rank < 20 and rank == math.floor(rank) then
                return {guid=guid,name=name,rank=rank,club=club,rankName=safe(info[2],"string"),class=safe(info[11],"string"),online=safe(info[9],"boolean")}
            end
            return nil
        end
    end
end
function Ranks:Allowed(member, order)
    if not member or not safe(order,"number") or order ~= math.floor(order) or order < 2 or order > 20 then return nil end
    local count=GP:SafeCall(GuildControlGetNumRanks,nil)
    if not safe(count,"number") or order > count or order == member.rank+1 then return nil end
    local permission
    if order < member.rank+1 then permission=CanGuildPromote else permission=CanGuildDemote end
    if GP:SafeCall(permission,false) ~= true then return nil end
    if GP:SafeCall(C_GuildInfo and C_GuildInfo.IsGuildRankAssignmentAllowed,false,member.guid,order) ~= true then return nil end
    local name=GP:SafeCall(GuildControlGetRankName,nil,order)
    return safe(name,"string")
end
function Ranks:Options(guid)
    local member=self:Snapshot(guid)
    local rows={}
    if not member then return rows end
    for order=2,20 do
        local name=self:Allowed(member,order)
        if name then rows[#rows+1]={order=order,name=name} end
    end
    return rows
end
function Ranks:Prepare(guid,order)
    self.token=nil
    local member=self:Snapshot(guid)
    local name=self:Allowed(member,order)
    if not name then return nil end
    member.order,member.rankName,member.expires=order,name,GetTime()+30
    self.token=member
    return member
end
function Ranks:Confirm(token)
    if not token or token ~= self.token then return false end
    self.token=nil
    local current=self:Snapshot(token.guid)
    if GetTime() > token.expires or not current or current.club ~= token.club or current.name ~= token.name
        or current.rank ~= token.rank or self:Allowed(current,token.order) ~= token.rankName then
        GP:Print(GP.L["Rank change cancelled: the member, ranks or permissions changed. Select the member again."])
        return false
    end
    -- Never replace an existing armed batch or its remaining steps.
    local macro=GP:GetModule("MacroTool")
    local state=macro:GetExecutionState()
    if state.activeToken or state.remaining > 0 then
        GP:Print(GP.L["Finish or clear the current Macro Tool queue before preparing a rank change."])
        return false
    end
    -- A character name is one slash-command argument, never executable text.
    if current.name:find("[%s%c/|;%[%]]") then
        GP:Print(GP.L["The member name cannot be used in a rank macro."])
        return false
    end
    local row={
        guid=current.guid, include=true, source="rosterRank",
        reasons={GP.L["Prepared from roster. Use Clear Macro to cancel."]},
        player={guid=current.guid,name=current.name,rankIndex=current.rank,rankName=current.rankName,class=current.class,online=current.online},
        action=token.order < current.rank+1 and "promote" or "demote",
        targetRankIndex=token.order-1, targetRankName=token.rankName,
    }
    local previous=macro.executionQueue
    local ok,message=macro:BuildExecutionBatch({row})
    if not ok then
        macro.executionQueue=previous
        GP:SendMessage("GuildParagon_MacroExecutorChanged")
        GP:Print(message or GP.L["Could not prepare the rank macro."])
        return false
    end
    GP:Print(GP.L["Rank macro prepared. Review it in Macro Tool, then press its keybind or use Paragon_Tool on your action bar. Each press moves one rank."])
    return true
end
function Ranks:OnContext(event)
    self.token=nil
    if event == "PLAYER_LEAVING_WORLD" then self.loading=true
    elseif event == "PLAYER_ENTERING_WORLD" then self.loading=false end
    GP:SendMessage("GuildParagon_RankAccessChanged")
end
function Ranks:OnEnable()
    self.loading=true
    for _,event in ipairs({"PLAYER_ENTERING_WORLD","PLAYER_LEAVING_WORLD","PLAYER_GUILD_UPDATE","PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","GUILD_RANKS_UPDATE"})do
        self:RegisterEvent(event,"OnContext")
    end
end

function Ranks:OnDisable()
    self:UnregisterAllEvents()
    self.token,self.loading=nil,true
    GP:SendMessage("GuildParagon_RankAccessChanged")
end
