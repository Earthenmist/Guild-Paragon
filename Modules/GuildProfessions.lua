local _, GP = ...
local Professions = GP:NewModule("GuildProfessions")
-- Primary profession skill lines; exclude secondary and expansion activity skills.
local PRIMARY = {
    [171]=true, [164]=true, [333]=true, [202]=true, [182]=true,
    [773]=true, [755]=true, [165]=true, [186]=true, [393]=true, [197]=true,
}

function Professions:CanUse()
    return not GP:IsForeverClient() and type(GetNumGuildTradeSkill) == "function"
        and type(GetGuildTradeSkillInfo) == "function"
end

function Professions:Begin()
    if not self:CanUse() or self.active then return end
    self.active = true
    self.collapsed = {}
    self.offline = GP:SafeCall(GetGuildRosterShowOffline, false)
end

function Professions:Finish()
    GP:CancelFrameWork("guildProfessions")
    if not self.active then return end
    self.active = false
    if self:CanUse() then
        for id in pairs(self.collapsed or {}) do
            GP:SafeCall(CollapseGuildTradeSkillHeader, nil, id)
        end
        if type(self.offline) == "boolean" then GP:SafeCall(SetGuildRosterShowOffline, nil, self.offline) end
    end
    self.collapsed = nil
end

function Professions:Request(showOffline)
    if not self:CanUse() or not self.active or GP:SafeCall(IsInGuild,false)~=true then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    GP:SafeCall(SetGuildRosterShowOffline, nil, showOffline == true)
    GP:SafeCall(QueryGuildRecipes, nil)
    if C_GuildInfo then GP:SafeCall(C_GuildInfo.GuildRoster, nil) end
    return true
end

function Professions:Expand(group)
    if not self:CanUse() or not self.active or not group then return end
    if group.collapsed and not self.collapsed[group.id] then
        self.collapsed[group.id] = true
        GP:SafeCall(ExpandGuildTradeSkillHeader, nil, group.id)
        return true
    end
    return false
end

function Professions:Read(done)
    if not self:CanUse() or not self.active or GP:SafeCall(IsInGuild,false)~=true then done({}); return end
    local indices, groups, current = {}, {}, nil
    local count = GP:SafeNumber(GP:SafeCall(GetNumGuildTradeSkill, 0), 0)
    for i=1,count do indices[i]=i end
    GP:RunFrameBatches("guildProfessions", indices, 50, function(index)
        local ok,id,collapsed,icon,header,numOnline,_,numPlayers,display,name,_,online,zone,skill,class = pcall(GetGuildTradeSkillInfo,index)
        if not ok then return end
        id = GP:SafeNumber(id, nil)
        header = GP:SafeOptionalString(header)
        if header then
            current = nil
            if not id or not PRIMARY[id] then return end
            current = {id=id,name=header,icon=GP:SafeValue(icon,nil),collapsed=GP:SafeValue(collapsed,false)==true,
                online=GP:SafeNumber(numOnline,0),total=GP:SafeNumber(numPlayers,0),members={}}
            groups[#groups+1] = current
        elseif current then
            name = GP:SafeOptionalString(name) or GP:SafeOptionalString(display)
            if name then
                current.members[#current.members+1] = {name=name,id=id or current.id,
                    online=GP:SafeValue(online,false)==true,zone=GP:SafeOptionalString(zone) or "",
                    skill=GP:SafeNumber(skill,nil),class=GP:SafeOptionalString(class)}
            end
        end
    end,function(ok) if ok and self.active then done(groups) end end)
end

function Professions:Members(group, search, showOffline)
    local rows = {}
    search = (search or ""):lower()
    for _,member in ipairs(group and group.members or {}) do
        if (showOffline or member.online) and (search=="" or member.name:lower():find(search,1,true)) then
            rows[#rows+1]=member
        end
    end
    table.sort(rows,function(a,b)
        if a.online ~= b.online then return a.online end
        return a.name:lower()<b.name:lower()
    end)
    return rows
end

function Professions:CanView(id)
    if id == 182 or id == 186 or id == 393 then return false end
    return self:CanUse() and GP:SafeCall(CanViewGuildRecipes,false,id)==true
end

function Professions:View(id, name)
    if not self:CanView(id) or (InCombatLockdown and InCombatLockdown()) then return false end
    local fn = name and GetGuildMemberRecipes or ViewGuildRecipes
    if type(fn)~="function" then return false end
    if name then return pcall(fn,name,id) end
    return pcall(fn,id)
end
