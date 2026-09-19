-- Bounded local response history with officer-only, incremental peer exchange.
local _, GP = ...
local Audit = GP:NewModule("ApplicantAudit", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")
local PREFIX, LIMIT, DAYS = "GPAudit1", 200, 30*86400
local function value(v, kind)
    if not GP:IsSecretValue(v) and type(v) == kind then return v end
end
local function str(v, max)
    v = value(v, "string")
    if v and #v > 0 and #v <= (max or 160) then return v end
end
local function integer(v, low, high)
    v = value(v, "number")
    return v and v == v and v >= low and v <= high and v == math.floor(v) and v or nil
end
local function clean(r)
    if not value(r, "table") then return nil end
    local out = {id=str(r.id,240), actorGUID=str(r.actorGUID), actor=str(r.actor),
        playerGUID=str(r.playerGUID), posting=str(r.posting), applicant=str(r.applicant),
        at=integer(r.at,time()-DAYS,time()+300), seq=integer(r.seq,1,1e12),
        approve=value(r.approve,"boolean"), sent=value(r.sent,"boolean")}
    if not out.id or not out.actorGUID or not out.actor or not out.playerGUID or not out.posting
        or not out.applicant or not out.at or not out.seq or out.approve == nil or out.sent == nil then return nil end
    if out.id ~= out.actorGUID .. ":" .. out.at .. ":" .. out.seq then return nil end
    return out
end
local function newer(a,b)
    return a.at > b.at or (a.at == b.at and a.id > b.id)
end
local function equal(a,b)
    for k,v in pairs(a) do if b[k] ~= v then return false end end
    for k,v in pairs(b) do if a[k] ~= v then return false end end
    return true
end
function Audit:Context(sharing)
    local applicants = GP:GetModule("GuildApplicants", true)
    if not applicants or not applicants:CanUse() or (sharing and not GP:IsOfficer()) then return nil end
    local roster = GP:GetModule("Roster", true)
    local key = roster and roster:GetGuildKey()
    local data = key and GP.db and GP.db.global.guilds[key]
    if not data then return nil end
    data.applicantAudit = data.applicantAudit or {records={}, sequence=0}
    if sharing and self.activeKey ~= key then
        self.activeKey=key;self.queue={};self.peers={};self.lastHello=nil
    end
    return key, data.applicantAudit, data
end
function Audit:Records(store)
    local rows = {}
    for id,r in pairs(store.records) do
        local record = clean(r)
        if record and record.id == id then rows[#rows+1]=record else store.records[id]=nil end
    end
    table.sort(rows,newer)
    for i=#rows,LIMIT+1,-1 do store.records[rows[i].id]=nil; rows[i]=nil end
    return rows
end
function Audit:PeerAllowed(name, data)
    name = str(name)
    if not name then return false end
    local roster = GP:GetModule("Roster")
    local guid, player, match = roster:FindPlayerByName(data,name,false)
    if guid == GP:SafeCall(UnitGUID,nil,"player") then return false end
    if not player or match ~= "exact" or not value(player.online,"boolean") then return false end
    local rank = integer(player.rankIndex,0,20)
    if not rank then return false end
    local flags = GP:SafeCall(C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags,nil,rank+1)
    return value(flags,"table") and value(flags[12],"boolean") == true or false
end
function Audit:Record(row, approve, sent)
    local key, store = self:Context(false)
    if not key then return false end
    local actorGUID = str(GP:SafeCall(UnitGUID,nil,"player"))
    local actorName = str(GP:SafeCall(UnitName,nil,"player"))
    local realm = str(GP:SafeCall(GetNormalizedRealmName,nil))
    if not actorGUID or not actorName or not realm then return false end
    store.sequence = (integer(store.sequence,0,1e12-1) or 0)+1
    local at = time()
    local record = clean({id=actorGUID .. ":" .. at .. ":" .. store.sequence,
        actorGUID=actorGUID,actor=actorName .. "-" .. realm,at=at,seq=store.sequence,
        playerGUID=row.playerGUID,posting=row.clubFinderGUID,applicant=row.name,approve=approve,sent=sent})
    if not record then return false end
    store.records[record.id] = record
    self:Records(store)
    self.dirty = true
    GP:SendMessage("GuildParagon_ApplicantAuditChanged")
    return true
end
function Audit:Queue(payload, target, key)
    self.queue = self.queue or {}
    if #self.queue >= 128 then return end
    payload.v, payload.guild = 1, key
    self.queue[#self.queue+1] = {payload=payload,target=target,key=key}
end
function Audit:Manifest(store, target, key, reply)
    local ids = {}
    for _,r in ipairs(self:Records(store)) do ids[r.id]=true end
    self:Queue({op="manifest",ids=ids,reply=reply},target,key)
end
function Audit:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= PREFIX or not str(message,64000) or not str(sender) then return end
    local key, store, data = self:Context(true)
    if not key or not self:PeerAllowed(sender,data) then return end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then return end
    local ok,p = self:Deserialize(message)
    if not ok or type(p) ~= "table" or p.v ~= 1 or p.guild ~= key then return end
    self.peers = self.peers or {}
    if not self.peers[sender] then
        local count=0;for _ in pairs(self.peers) do count=count+1 end
        if count >= 50 then return end
        self.peers[sender]={}
    end
    local peer = self.peers[sender]
    local now = GetTime()
    if p.op == "hello" then
        if peer.hello and now-peer.hello < 60 then return end
        peer.hello=now
        self:Manifest(store,sender,key,true)
    elseif p.op == "manifest" and distribution == "WHISPER" then
        if type(p.ids) ~= "table" or (peer.manifest and now-peer.manifest < 15) then return end
        local count=0
        for id,present in pairs(p.ids) do
            count=count+1
            if count > LIMIT or not str(id,240) or present ~= true then return end
        end
        peer.manifest=now
        local batch={}
        for _,r in ipairs(self:Records(store)) do
            if not p.ids[r.id] then
                batch[#batch+1]=r
                if #batch == 5 then self:Queue({op="records",records=batch},sender,key); batch={} end
            end
        end
        if #batch > 0 then self:Queue({op="records",records=batch},sender,key) end
        if p.reply == true then self:Manifest(store,sender,key,false) end
    elseif p.op == "records" and distribution == "WHISPER" then
        if type(p.records) ~= "table" or #p.records > 5 then return end
        local records={}
        for _,raw in pairs(p.records) do
            if #records >= 5 then return end
            local r=clean(raw)
            if not r then return end
            records[#records+1]=r
        end
        local changed=false
        for _,r in ipairs(records) do
            local previous=store.records[r.id]
            -- Conflicting copies of one response must not silently change its actor/action.
            if not previous then store.records[r.id]=r;changed=true
            elseif not equal(previous,r) then self.conflicts=(self.conflicts or 0)+1 end
        end
        self:Records(store)
        if changed then GP:SendMessage("GuildParagon_ApplicantAuditChanged") end
    end
end
function Audit:Tick()
    local key, store, data = self:Context(true)
    if not key then self.queue={};self.peers={};self.activeKey=nil;return end
    if key ~= self.activeKey then
        self.activeKey=key;self.queue={};self.peers={};self.lastHello=nil
    end
    local now=GetTime()
    if not self.lastHello or now-self.lastHello >= (self.dirty and 60 or 300) then
        self.lastHello=now;self.dirty=nil
        -- Discovery contains no applicant identities or response records.
        self:SendCommMessage(PREFIX,self:Serialize({v=1,op="hello",guild=key}),"GUILD",nil,"BULK")
    end
    local job=table.remove(self.queue,1)
    if job and job.key == key and self:PeerAllowed(job.target,data) then
        self:SendCommMessage(PREFIX,self:Serialize(job.payload),"WHISPER",job.target,"BULK")
    end
end
function Audit:Text(row)
    local _,store=self:Context(false)
    if not store or not row then return GP.L["Officer unknown: no recorded Guild Paragon response."] end
    local lines={}
    for _,r in ipairs(self:Records(store)) do
        if r.playerGUID == row.playerGUID and r.posting == row.clubFinderGUID then
            local action = r.approve and GP.L["Approval"] or GP.L["Decline"]
            local wording = r.sent and GP.L["%s submitted by %s — %s"] or GP.L["%s request failed for %s — %s"]
            lines[#lines+1]=string.format(wording,action,r.actor:gsub("|","||"),date("%d %b %Y %H:%M:%S",r.at))
            if #lines == 5 then break end
        end
    end
    if #lines == 0 then return GP.L["Officer unknown: no recorded Guild Paragon response."] end
    return GP.L["Recent Guild Paragon responses for this applicant (may include earlier applications):"]
        .. "\n" .. table.concat(lines,"\n") .. "\n" .. GP.L["Blizzard's status is shown above; it does not identify the reviewing officer."]
end
function Audit:OnEnable()
    self.queue,self.peers={},{}
    self:RegisterComm(PREFIX,"OnCommReceived")
    self.ticker=C_Timer.NewTicker(2,function() self:Tick() end)
end
function Audit:OnDisable()
    if self.ticker then self.ticker:Cancel();self.ticker=nil end
    self:UnregisterAllComm();self.queue={};self.peers={}
end
