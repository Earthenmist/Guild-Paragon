-- Login reconciliation and change-triggered repair; no periodic snapshots.
local _, GP = ...
local E = GP:NewModule("SyncReconcile", "AceEvent-3.0")
local R,I=GP.SyncRecords,GP.SyncIBLT
local INTERVAL = 0.1
local function sync() return GP:GetModule("GuildSync") end
local function transfer() return GP:GetModule("SyncTransfer") end
local function roster() return GP:GetModule("Roster") end
local function sketchBatchSize()
    return sync().IsLowFrameRate and sync():IsLowFrameRate() and 15 or 75
end
function E:Name(peer)
    local admission=GP:GetModule("SyncAdmission",true)
    return admission and admission:PeerName(peer) or peer
end
function E:NameKey(peer) return roster():NormalizePlayerName(self:Name(peer)) end
function E:SamePeer(a,b)
    return self:NameKey(a)==self:NameKey(b)
end
function E:SupportsCompression(peer)
    local p=self.peers[self:NameKey(peer)]
    return p and p.compression==1
end
function E:SupportsSegments(peer)
    local p=self.peers[self:NameKey(peer)]
    return p and p.segments==1
end
function E:PeerAllowed(peer,category,sending)
    return self.guild and sync():IsEnabled() and sync():CanReconcileWith(self.guild,self:Name(peer),category,sending)
end
function E:CanSend(peer,p)
    if not self:PeerAllowed(peer) then return false end
    local known=self.peers[self:NameKey(peer)]
    if known and known.offline then return false end
    if p.op=="reply" and not (p.denied or p.busy or p.expired or p.oversized) then
        return self:PeerAllowed(peer,p.category,true)
    elseif p.op=="changed" or p.op=="live" then return self:PeerAllowed(peer,p.category,true) end
    return true
end
function E:Progress(peer)
    local served=self.serving[self:NameKey(peer)]
    if served then served.at=self.clock end
    local job=self.active
    if job and self:SamePeer(job.peer.name,peer) and job.wait then job.wait=self.clock end
end
function E:OnEnable()
    self.peers,self.serving,self.dirty={},{},{}
    self.clock,self.sequence=0,0
    self:RegisterMessage("GuildParagon_RosterScanned","RosterReady")
    self.ticker=C_Timer.NewTicker(INTERVAL,function() self:Tick() end)
end
function E:OnDisable()
    if self.ticker then self.ticker:Cancel() end
    self.guild,self.active=nil,nil
    self.peers,self.serving,self.dirty={},{},{}
end
function E:RosterReady(_,guild)
    if not guild then return end
    if self.guild~=guild then
        self.guild=guild
        self.peers,self.serving,self.dirty={},{},{}
        self.active=nil
        transfer():Reset()
        transfer().hello=true
        self.discovery,self.nextDiscovery=3,self.clock+15
    end
    self:RefreshPresence()
end
function E:RefreshPresence()
    if not self.guild or not sync().GetReconcilePresence then return end
    for _,p in pairs(self.peers) do
        local online,scanned=sync():GetReconcilePresence(self.guild,p.name)
        if online==false and scanned and scanned>(p.heardAt or 0) and not p.offline then
            self:Depart(p.name,"Roster reports offline")
        elseif online==true and p.offline and scanned and scanned>(p.departedAt or 0) then
            p.offline,p.retry,p.failures,p.welcomed=false,nil,0,false
            self:QueueAll(p)
            self:Status(p.name,"Online",GP.L["Waiting for peer response"])
        end
    end
end
function E:Heard(name)
    local p=self.peers[self:NameKey(name)]
    if not p then return end
    p.heardAt=time()
    if p.offline then
        p.offline,p.retry,p.failures,p.welcomed=false,nil,0,false
        self:QueueAll(p)
    end
    if sync().MarkPeerReachable then sync():MarkPeerReachable(name) end
end
function E:Request()
    local guild=roster():GetGuildKey()
    if not guild then return false end
    self:RosterReady(nil,guild)
    for _,p in pairs(self.peers) do self:QueueAll(p) end
    transfer().hello=true
    self.discovery,self.nextDiscovery=3,self.clock+15
    return true
end
function E:QueueAll(peer)
    peer.applyFailures = nil
    for _,category in ipairs(R.categories) do peer.pending[category]=true end
end

-- Retain actionable failures separately from transient peer activity.
function E:GetApplyFailures(name)
    local p=self.peers and self.peers[self:NameKey(name)]
    local result={}
    for _,category in ipairs(R.categories) do
        local failure=p and p.applyFailures and p.applyFailures[category]
        if failure and self:PeerAllowed(name,category,false) then
            result[#result+1]={category=category,failure=failure}
        end
    end
    return result
end
function E:ApplyFailed(job,report)
    local p=job.peer
    p.applyFailures=p.applyFailures or {}
    local previous=p.applyFailures[job.category]
    local attempts=(previous and previous.attempts or 0)+1
    p.applyFailures[job.category]={attempts=attempts,issues=report and report.issues or {},
        count=report and report.rejected or 1,
        blocked=(report and report.permanentRejection) or attempts>=3,
        retry=self.clock+30}
    self.active=nil
    p.pending[job.category]=true
    self:Status(p.name,p.applyFailures[job.category].blocked and "Needs attention" or "Retry pending",job.category)
end
function E:Hello(name,nonce)
    name=self:Name(name)
    if not self:PeerAllowed(name) or #nonce>48 then return end
    local key=self:NameKey(name)
    local p=self.peers[key]
    if not p then p={name=name,pending={},nonce=nonce};self.peers[key]=p end
    if not p.seen or p.nonce~=nonce then
        p.seen,p.nonce=true,nonce
        p.compression=nil
        p.segments=nil
        p.welcomed=false
        self:QueueAll(p)
    end
    p.at,p.heardAt,p.offline,p.retry,p.failures=self.clock,time(),false,nil,0
    sync():RecordPeer(name,"Online",nil,"Category reconciliation available")
end
function E:Depart(name,reason)
    local p=self.peers[self:NameKey(name)]
    if not p then return end
    p.offline,p.departedAt,p.live=true,time(),{}
    p.notifying,p.welcoming,p.liveSending={},nil,nil
    if self.active and self.active.peer==p then self.active=nil end
    self.serving[self:NameKey(name)]=nil
    transfer():CancelPeer(name)
    self:Status(name,"Offline",GP.L[reason or "Peer logged out"])
end
function E:Dirty(category,source)
    if not R.fields[category] then return end
    self.dirty=self.dirty or {}
    self.dirty[category]=(self.dirty[category] or 0)+1
    if not source then
        for _,p in pairs(self.peers or {}) do
            if p.applyFailures then p.applyFailures[category]=nil end
            p.pending[category]=true
        end
    end
    if source then
        local p=self.peers[self:NameKey(source)]
        if p then p.notified=p.notified or {};p.notified[category]=self.dirty[category] end
    end
end
function E:Capture(payload)
    local category,record=R.LiveRecord(payload)
    if category then
        for _,p in pairs(self.peers or {}) do
            if p.applyFailures and p.applyFailures[category] then
                p.applyFailures[category]=nil
                p.pending[category]=true
            end
        end
        local ok,copy=sync():Deserialize(sync():Serialize(payload))
        if ok then
            for _,p in pairs(self.peers or {}) do
                p.live=p.live or {}
                local key=category..":"..record[1]..":"..record[2]
                local count=0;for _ in pairs(p.live) do count=count+1 end
                if count<256 or p.live[key] then p.live[key]={category=category,update=copy}
                else self:Dirty(category) end
            end
        else self:Dirty(category) end
        return true
    end
    if payload.op=="safetyfull" then
        self:Dirty("companionSettings");self:Dirty("recruitmentItems")
        self:Dirty("recruitmentBlacklist");self:Dirty("bans");return true
    end
    return false
end
function E:Status(peer,status,category)
    sync():RecordPeer(peer,status,nil,category)
    GP:SendMessage("GuildParagon_SyncStatusChanged",self.guild)
end
function E:GetStatusLines()
    local L=GP.L
    local peers,pending,attention=0,0,0
    for _,p in pairs(self.peers or {}) do
        for _,entry in ipairs(self:GetApplyFailures(p.name)) do
            if entry.failure.blocked then attention=attention+1 end
        end
        if not p.offline then
            peers=peers+1
            for _ in pairs(p.pending) do pending=pending+1 end
        end
    end
    local state
    if GP.SyncNative and not transfer():Ready() then state=L["Native sync APIs unavailable"]
    elseif not sync():CanRetryBulkSync() then state=L["Paused until safe"]
    elseif peers==0 then state=L["Waiting for a compatible peer"]
    elseif attention>0 and not self.active then state=L["Needs attention"]
    elseif pending>0 then state=L["Comparing category differences"]
    else state=L["Live updates ready"] end
    return {GP.SyncNative and L["Native guild sync"] or L["Guild data comparison"],state,
        string.format(L["Compatible peers: %d"],peers),
        string.format(L["Pending checks across peers: %d"],pending),
        string.format(L["Difference records received: %d"],self.recordsReceived or 0),
        string.format(L["Categories needing attention: %d (hover peer rows)"],attention),
        self.active and R.Label(self.active.category) or "",
        "",L["Checks for differences on login/reload; edits sync live."],
        L["Interrupted syncs retain progress and retry when available."],
        GP.SyncNative and L["All participants need Guild Paragon 1.7.0 or later."] or L["All participants need Guild Paragon 1.6.0 or later."],
        "",L["Event Log: manual replacement only."]}
end
function E:Send(peer,payload)
    return transfer():Send(peer,payload)
end
function E:Ask(job,op,extra)
    if self.active~=job then return end
    self.sequence=self.sequence+1
    local p=extra or {}
    p.op,p.id,p.category,p.session=op,transfer().nonce.."q"..self.sequence,job.category,job.session
    job.request,job.wait,job.delivered=p,self.clock,false
    local queued=transfer():Send(job.peer.name,p,function(ok)
        if self.active~=job or job.request~=p then return end
        if not ok then self:Stop(job,false,"No acknowledgement") else job.wait=self.clock;job.delivered=true end
    end)
    if not queued then self:Stop(job,false,"Local send queue full") end
end
function E:Stop(job,complete,reason)
    if self.active~=job then return end
    self.active=nil
    if complete then
        if job.peer.applyFailures then job.peer.applyFailures[job.category]=nil end
        job.peer.failures=0
        job.peer.pending[job.category]=job.changed and true or nil
        self:Status(job.peer.name,"Category checked",job.category)
    else
        job.peer.failures=math.min((job.peer.failures or 0)+1,4)
        job.peer.retry=self.clock+math.min(120,20*2^(job.peer.failures-1))
        if job.request then transfer():CancelPeer(job.peer.name,job.request.id) end
        self:Status(job.peer.name,"Sync deferred",GP.L[reason or "Comparison interrupted"])
    end
end
function E:BuildJob(peer,category)
    local job={peer=peer,category=category,started=self.clock}
    self.active=job
    self:Status(peer.name,"Comparing category",category)
    R.Build(self.guild,category,function() return self.active==job end,function(snapshot)
        if self.active~=job then return end
        if not snapshot then self:Stop(job,false,"Local snapshot failed");return end
        job.localState=snapshot
        self:Ask(job,"open",{count=snapshot.count,a=snapshot.a,b=snapshot.b})
    end)
end
function E:Tick()
    if not self.presenceCheck or time()>=self.presenceCheck then
        self.presenceCheck=time()+1;self:RefreshPresence()
    end
    if not self.guild or not sync():IsEnabled() or not sync():CanRetryBulkSync() then return end
    self.clock=self.clock+INTERVAL
    if self.discovery and self.discovery>0 and self.clock>=self.nextDiscovery then
        transfer().hello=true;self.discovery=self.discovery-1
        self.nextDiscovery=self.clock+15
    end
    for key,s in pairs(self.serving) do if self.clock-s.at>180 then self.serving[key]=nil end end
    for _,p in pairs(self.peers) do
        if not p.offline and not p.welcomed and not p.welcoming and (not p.welcomeRetry or p.welcomeRetry<=self.clock) then
            p.welcoming=true
            local queued=transfer():Send(p.name,{op="welcome",nonce=transfer().nonce,compression=1,segments=1},function(ok)
                p.welcoming=nil;p.welcomed=ok;p.welcomeRetry=self.clock+20
            end)
            if not queued then p.welcoming=nil end
            return
        end
    end
    -- Explicit edits use acknowledged record delivery; a failed delivery falls
    -- back to category reconciliation against the current saved state.
    for _,p in pairs(self.peers) do
        local key,item=next(p.live or {})
        if item and not p.offline and not p.liveSending then
            if not self:PeerAllowed(p.name,item.category,true) then p.live[key]=nil
            else
                p.liveSending=true
                local queued,reason=transfer():Send(p.name,{op="live",category=item.category,update=item.update},function(ok)
                    p.liveSending=nil
                    if p.live[key]==item then p.live[key]=nil end
                    if not ok then self:Dirty(item.category) end
                end)
                if not queued then
                    p.liveSending=nil
                    if reason=="oversized" then p.live[key]=nil;self:Dirty(item.category) end
                end
                return
            end
        end
    end
    -- Notifications are coalesced per category. Failed delivery remains pending.
    for category,revision in pairs(self.dirty) do
        for _,p in pairs(self.peers) do
            p.notified=p.notified or {};p.notifying=p.notifying or {}
            if not p.offline and p.notified[category]~=revision and not p.notifying[category] and (not p.noticeRetry or p.noticeRetry<=self.clock)
                and self:PeerAllowed(p.name,category,true) then
                p.notifying[category]=true
                local queued=transfer():Send(p.name,{op="changed",category=category},function(ok)
                    p.notifying[category]=nil
                    if ok then p.notified[category]=revision else p.noticeRetry=self.clock+30 end
                end)
                if not queued then p.notifying[category]=nil end
                return
            end
        end
    end
    local job=self.active
    if job then
        if not self:PeerAllowed(job.peer.name,job.category,false) then self:Stop(job,true);return end
        if job.wait and self.clock-job.wait>(job.delivered and 30 or 90) then
            self:Stop(job,false,job.delivered and "Reply timed out" or "Request delivery timed out")
        end
        return
    end
    local choices={}
    for _,p in pairs(self.peers) do
        if not p.offline and (not p.retry or p.retry<=self.clock) then choices[#choices+1]=p end
    end
    table.sort(choices,function(a,b) return (a.used or 0)<(b.used or 0) end)
    for _,category in ipairs(R.categories) do
        for _,p in ipairs(choices) do
            local failure=p.applyFailures and p.applyFailures[category]
            if p.pending[category] and (not failure or (not failure.blocked and failure.retry<=self.clock)) then
                if self:PeerAllowed(p.name,category,false) then
                    p.used=self.clock
                    self:BuildJob(p,category);return
                else p.pending[category]=nil end
            end
        end
    end
end
function E:Reply(peer,request,payload)
    payload.op,payload.id,payload.category="reply",request.id,request.category
    return self:Send(peer,payload)
end
function E:Serve(peer,p)
    if not self:PeerAllowed(peer,p.category,true) then self:Reply(peer,p,{denied=true});return end
    local key=self:NameKey(peer)
    if p.op=="open" then
        local count=0;for _ in pairs(self.serving) do count=count+1 end
        if count>=7 and not self.serving[key] then self:Reply(peer,p,{busy=true});return end
        local s={id=p.id,category=p.category,at=self.clock,guild=self.guild}
        self.serving[key]=s
        R.Build(self.guild,p.category,function() return self.serving[key]==s and self.guild==s.guild end,function(snapshot)
            if not snapshot or self.serving[key]~=s or not self:PeerAllowed(peer,p.category,true) then return end
            s.snapshot=snapshot
            local same=p.count==snapshot.count and p.a==snapshot.a and p.b==snapshot.b
            self:Reply(peer,p,{session=s.id,same=same,count=snapshot.count})
        end)
        return
    end
    local s=self.serving[key]
    if not s or not s.snapshot or s.id~=p.session or s.category~=p.category then self:Reply(peer,p,{expired=true});return end
    s.at=self.clock
    local snapshot=s.snapshot
    if p.op=="iblt" then
        if p.size~=16 and p.size~=64 and p.size~=256 then return end
        local cells=I.New(p.size)
        GP:RunFrameBatches("sync.iblt."..key,snapshot.keys,sketchBatchSize(),function(k) I.Add(cells,k,1) end,function()
            if self.serving[key]==s and self:PeerAllowed(peer,p.category,true) then self:Reply(peer,p,{cells=cells,session=s.id}) end
        end)
    elseif p.op=="inventory" then
        local offset=p.offset
        if type(offset)~="number" or offset<1 or offset%1~=0 or offset>snapshot.count+1 then return end
        local keys={}
        for n=offset,math.min(offset+63,snapshot.count) do keys[#keys+1]=snapshot.keys[n] end
        self:Reply(peer,p,{keys=keys,nextOffset=offset+#keys,finished=offset+#keys>snapshot.count,session=s.id})
    elseif p.op=="get" then
        if type(p.keys)~="table" or #p.keys>R.BatchLimit() then return end
        local records={}
        for _,k in ipairs(p.keys) do
            if type(k)~="table" or type(k[1])~="number" or type(k[2])~="number" then return end
            local r=snapshot.byID[I.ID(k)]
            if not r then self:Reply(peer,p,{expired=true});return end
            records[#records+1]=r
        end
        local queued,reason=self:Reply(peer,p,{records=records,session=s.id})
        if not queued then
            self:Reply(peer,p,reason=="oversized" and {oversized=true} or {busy=true})
        end
    end
end
function E:GetNext(job)
    if #job.wanted==0 then
        if job.nextOffset then self:Ask(job,"inventory",{offset=job.nextOffset})
        else self:Stop(job,true) end
        return
    end
    local keys={}
    for _=1,math.min(job.limit or R.BatchLimit(),#job.wanted) do keys[#keys+1]=table.remove(job.wanted) end
    job.expected=keys
    self:Ask(job,"get",{keys=keys})
end
function E:Response(peer,p)
    local job=self.active
    if not job or not job.request or not self:SamePeer(peer,job.peer.name) or p.id~=job.request.id or p.category~=job.category then return end
    if not self:PeerAllowed(peer,job.category,false) then self:Stop(job,true);return end
    if p.denied then self:Stop(job,true);return end
    if p.oversized and job.expected and #job.expected>1 then
        job.limit=math.max(1,math.floor(#job.expected/2))
        for _,k in ipairs(job.expected) do job.wanted[#job.wanted+1]=k end
        self:GetNext(job);return
    end
    if p.busy or p.expired or p.oversized then
        self:Stop(job,false,p.busy and "Peer is busy" or (p.expired and "Peer snapshot expired" or "Peer update required for large records"))
        if p.oversized then
            job.peer.retry=self.clock+300
            self:Status(peer,"Peer update required for large records",job.category)
        end
        return
    end
    job.wait=self.clock
    local op=job.request.op
    if op=="open" then
        if type(p.session)~="string" or type(p.count)~="number" or p.count<0
            or p.count~=math.floor(p.count) or p.count==math.huge then return end
        job.session=p.session
        if p.same or p.count==0 then self:Stop(job,true);return end
        -- The count gap is a lower bound on differences. Avoid sketches that
        -- cannot reasonably peel it; equal-sized edits still start small.
        local gap=math.abs(job.localState.count-p.count)
        if job.localState.count==0 or gap>128 then
            job.wanted={};self:Ask(job,"inventory",{offset=1});return
        end
        job.size=gap>32 and 256 or (gap>8 and 64 or 16)
        self:Ask(job,"iblt",{size=job.size})
    elseif op=="iblt" then
        if not I.Valid(p.cells,job.size) then return end
        local cells=I.New(job.size)
        GP:RunFrameBatches("sync.iblt.local",job.localState.keys,sketchBatchSize(),function(k) I.Add(cells,k,1) end,function()
            if self.active~=job then return end
            local _,missing=I.Peel(I.Subtract(cells,p.cells))
            if missing then job.wanted=missing;self:GetNext(job)
            elseif job.size<256 then job.size=job.size*4;self:Ask(job,"iblt",{size=job.size})
            else job.wanted={};self:Ask(job,"inventory",{offset=1}) end
        end)
    elseif op=="inventory" then
        if type(p.keys)~="table" or #p.keys>64 or type(p.nextOffset)~="number"
            or p.nextOffset~=job.request.offset+#p.keys or (#p.keys==0 and not p.finished) then return end
        job.wanted={}
        for _,k in ipairs(p.keys) do
            if type(k)~="table" or type(k[1])~="number" or type(k[2])~="number" then return end
            if not job.localState.byID[I.ID(k)] then job.wanted[#job.wanted+1]=k end
        end
        job.nextOffset=not p.finished and p.nextOffset or nil
        self:GetNext(job)
    elseif op=="get" then
        if type(p.records)~="table" or #p.records~=#job.expected then return end
        for n,r in ipairs(p.records) do
            if I.ID(I.Key(r))~=I.ID(job.expected[n]) then return end
        end
        local payload=R.Assemble(job.category,p.records)
        if not payload then return end
        job.request=nil
        sync():ApplyReconcileCategory(self.guild,job.category,payload,peer,function(ok,report)
            if self.active~=job then return end
            if ok==false then self:ApplyFailed(job,report);return end
            self.recordsReceived=(self.recordsReceived or 0)+#p.records
            self:GetNext(job)
        end)
    end
end
function E:Receive(peer,p)
    peer=self:Name(peer)
    if not self:PeerAllowed(peer) or not sync():CanRetryBulkSync() then return false end
    if p.op=="welcome" then
        if type(p.nonce)~="string" then return false end
        self:Hello(peer,p.nonce)
        local known=self.peers[self:NameKey(peer)]
        if known then known.compression=p.compression==1 and 1 or nil end
        if known then known.segments=p.segments==1 and 1 or nil end
        return true
    end
    if not R.fields[p.category] then return false end
    if p.op=="live" then
        if not self:PeerAllowed(peer,p.category,false) then return true end
        if type(p.update)~="table" or R.Category(p.update)~=p.category then return false end
        local category,record=R.LiveRecord(p.update)
        if not category or not R.Assemble(category,{record}) then return false end
        sync():ApplyReconcileLive(self.guild,p.update,peer,function(ok)
            if ok~=false then self.recordsReceived=(self.recordsReceived or 0)+1 end
        end)
        return true
    end
    if p.op=="changed" then
        local key=self:NameKey(peer)
        local known=self.peers[key]
        if known and self:PeerAllowed(peer,p.category,false) then
            if known.applyFailures then known.applyFailures[p.category]=nil end
            known.pending[p.category]=true
            -- An edit during an in-flight comparison requires another pass.
            local job=self.active
            if job and job.peer==known and job.category==p.category then job.changed=true end
        end
        return true
    end
    if type(p.id)~="string" or #p.id>80 then return false end
    if p.op=="reply" then self:Response(peer,p);return true end
    if p.op=="open" or p.op=="iblt" or p.op=="inventory" or p.op=="get" then self:Serve(peer,p);return true end
    return false
end
