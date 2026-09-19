-- Enrich observed guild events using unambiguous native guild-log evidence.
local _, GP = ...
local Attribution = GP:NewModule("EventAttribution")
local function readable(v, kind)
    if not GP:IsSecretValue(v) and type(v)==kind then return v end
end
local function nameKey(name)
    name=readable(name,"string")
    return name and name~="" and name:lower():gsub("%s","") or nil
end
local function short(name) return name:match("^[^-]+") end
local function sameName(a,b)
    if a:find("-",1,true) and b:find("-",1,true) then return a==b end
    return short(a)==short(b)
end
function Attribution:ReadEvidence(now)
    if type(GetNumGuildEvents)~="function" or type(GetGuildEventInfo)~="function" then return {} end
    local ok,count=pcall(GetNumGuildEvents)
    count=ok and readable(count,"number")
    if not count then return {} end
    local evidence, invites = {}, {}
    for i=1,math.min(count,500) do
        local success,kind,p1,p2,rank,years,months,days,hours=pcall(GetGuildEventInfo,i)
        kind=success and readable(kind,"string")
        p1,p2=readable(p1,"string"),readable(p2,"string")
        local n1,n2=nameKey(p1),nameKey(p2)
        years,months=readable(years,"number"),readable(months,"number")
        days,hours=readable(days,"number"),readable(hours,"number")
        -- Month/year ages cannot be reconstructed precisely enough for matching.
        if kind and years==0 and months==0 and days and days>=0 and hours and hours>=0 then
            local endTime=now-(days*24+hours)*3600
            if kind=="invite" and n2 then
                local previous=invites[n2]
                invites[n2]={actor=p1,ambiguous=not n1 or (previous and (previous.ambiguous or previous.actor~=p1))}
            elseif kind=="join" and n1 then
                local invitation=invites[n1]
                evidence[#evidence+1]={kind="join",target=n1,actor=invitation and not invitation.ambiguous and invitation.actor,
                    earliest=endTime-3900,latest=endTime+300}
                invites[n1]=nil
            elseif (kind=="promote" or kind=="demote" or kind=="remove") and n2 then
                evidence[#evidence+1]={kind=kind=="remove" and "removed" or kind,target=n2,actor=p1,
                    rank=readable(rank,"string"),earliest=endTime-3900,latest=endTime+300}
                if kind=="remove" then invites[n2]=nil end
            elseif kind=="quit" and n1 then
                -- A voluntary departure must also block ambiguous kick matches.
                evidence[#evidence+1]={kind="removed",target=n1,earliest=endTime-3900,latest=endTime+300}
                invites[n1]=nil
            end
        end
    end
    return evidence
end
function Attribution:Match(entry,evidence)
    local target=nameKey(entry.name)
    if not target or type(entry.ts)~="number" then return nil end
    local kind=entry.type=="leave" and "removed" or entry.type
    local matches={}
    for _,event in ipairs(evidence) do
        if event.kind==kind and sameName(target,event.target)
            and entry.ts>=event.earliest and entry.ts<=event.latest
            and ((kind~="promote" and kind~="demote") or not event.rank or event.rank=="" or event.rank==entry.toRank) then
            matches[#matches+1]=event
        end
    end
    return #matches==1 and matches[1] or nil, matches
end
function Attribution:Apply(entry,event)
    if not event.actor or event.actor=="" then return false end
    if (entry.type=="promote" or entry.type=="demote") and (not event.rank or event.rank=="" or event.rank~=entry.toRank) then return false end
    if entry.type=="join" then
        if entry.invitedBy then return false end
        entry.invitedBy=event.actor
    else
        if entry.actor or entry.removedBy then return false end
        entry.actor=event.actor
        if entry.type=="leave" then entry.type="removed" end
    end
    entry.actorSource="guildevent"
    return true
end
function Attribution:Refresh(guildKey)
    local roster=GP:GetModule("Roster")
    local safety=GP:GetModule("GuildApplicants",true)
    local function allowed()
        return safety and safety:IsSafe() and roster:GetGuildKey()==guildKey
    end
    if not guildKey or not allowed() then return end
    local guild=GP.db.global.guilds[guildKey]
    if not guild then return end
    local evidence=self:ReadEvidence(time())
    if #evidence==0 then return end
    local byName,cutoff={},time()
    for _,event in ipairs(evidence) do
        local key=short(event.target)
        byName[key]=byName[key] or {};table.insert(byName[key],event)
        cutoff=math.min(cutoff,event.earliest)
    end
    self.generation=(self.generation or 0)+1
    local generation=self.generation
    local log=guild.log or {}
    local index=#log
    local function step()
        if self.generation~=generation or not allowed() or guild.log~=log then return end
        local processed=0
        while index>0 and processed<200 do
            local entry=log[index];index=index-1;processed=processed+1
            if type(entry.ts)=="number" and entry.ts<cutoff then index=0;break end
            local key=nameKey(entry.name)
            if key then
                local unique,matches=self:Match(entry,byName[short(key)] or {})
                for _,event in ipairs(matches or {}) do
                    event.matches=(event.matches or 0)+1
                    if unique then event.entry=entry end
                end
            end
        end
        if index>0 then C_Timer.After(0,step);return end
        local changed=false
        for _,event in ipairs(evidence) do
            if event.matches==1 and event.entry and self:Apply(event.entry,event) then changed=true end
        end
        if changed then GP:SendMessage("GuildParagon_LogEntryAdded",guildKey,nil) end
    end
    C_Timer.After(0,step)
end
