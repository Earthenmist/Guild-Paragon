-- Small acknowledged packets. Only one fragment enters the throttle at once.
local _, GP = ...
local T = GP:NewModule("SyncTransfer", "AceEvent-3.0")
local PREFIX, BYTES, MAX_BYTES = "GPReconcile1", 180, 262144
local INTERVAL = 0.02
local SEGMENT_BYTES = 32768
local function sync() return GP:GetModule("GuildSync") end
local function engine() return GP:GetModule("SyncReconcile") end
local private={bans=true,macroRules=true,macroIgnores=true,labels=true,notesOfficer=true}
function T:Address(peer)
    local name=engine():NameKey(peer)
    local key=GP.SyncIBLT.Key(name)
    return string.format("%08x%08x",key[1],key[2])
end
function T:Reset()
    self.queue,self.incoming,self.completed,self.streams,self.waiting,self.awaitingPeer={},{},{},{},{},{}
    self.largePeer={}
    self.sequence=0
    self.nonce=string.format("%x%x",time(),math.random(0,16777215))
    self.active=nil
    self.nextLowFPSWire=nil
    self.ack={}
end
function T:OnEnable()
    self:Reset()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix,PREFIX)
    end
    self:RegisterEvent("CHAT_MSG_ADDON","Receive")
    self.ticker=C_Timer.NewTicker(INTERVAL,function() self:Tick() end)
end
function T:OnDisable()
    if self.ticker then self.ticker:Cancel() end
    self:Reset()
end
function T:CancelPeer(peer,requestID)
    local removed={}
    local function matches(packet)
        return engine():SamePeer(packet.peer,peer) and (not requestID or packet.payload.id==requestID)
    end
    if self.active and matches(self.active) then removed[#removed+1]=self.active;self.active=nil end
    for id,packet in pairs(self.waiting) do
        if matches(packet) then
            self.waiting[id]=nil;self.awaitingPeer[engine():NameKey(packet.peer)]=nil
            removed[#removed+1]=packet
        end
    end
    for n=#(self.queue or {}),1,-1 do
        if matches(self.queue[n]) then removed[#removed+1]=table.remove(self.queue,n) end
    end
    if not requestID then
        self.streams[engine():NameKey(peer)]=nil
        for key,state in pairs(self.incoming) do
            if state.sender and engine():SamePeer(state.sender,peer) then self.incoming[key]=nil end
        end
        for n=#self.ack,1,-1 do if engine():SamePeer(self.ack[n].peer,peer) then table.remove(self.ack,n) end end
    end
    for _,packet in ipairs(removed) do self:ReleaseLarge(packet);if packet.done then packet.done(false) end end
end
function T:ReleaseLarge(packet)
    local key=engine():NameKey(packet.peer)
    if packet.source and self.largePeer[key]==packet.stream then self.largePeer[key]=nil end
end
function T:Send(peer,payload,done)
    if not self.queue then return false end
    local pending=#self.queue
    for _ in pairs(self.waiting) do pending=pending+1 end
    if pending>=32 then return false end
    local text=sync():Serialize({target=peer,payload=payload})
    local large=#text>MAX_BYTES
    if large then
        if not engine():SupportsSegments(peer) then return false,"oversized" end
        -- Retain only one additional large envelope beyond the active one.
        local count=self.active and self.active.source and 1 or 0
        for _,queued in ipairs(self.queue) do if queued.source then count=count+1 end end
        for _,queued in pairs(self.waiting) do if queued.source then count=count+1 end end
        if count>=2 then return false,"busy" end
    end
    -- Welcome stays readable before either side has learned capabilities.
    if not large and payload.op~="welcome" and engine():SupportsCompression(peer) then
        local encoded,meta=sync():CompressRawMessage(text)
        if meta then text="Z:"..#text..":"..encoded end
    end
    self.sequence=self.sequence+1
    local packet={peer=peer,text=text,id=self.nonce.."-"..self.sequence,position=1,attempts=0,done=done,payload=payload,public=not private[payload.category]}
    if large then
        packet.source,packet.stream,packet.segment=text,packet.id,1
        self:PrepareSegment(packet)
    end
    self.queue[#self.queue+1]=packet
    return true
end
function T:PrepareSegment(packet)
    local first=(packet.segment-1)*SEGMENT_BYTES+1
    local payload={op="segment",category=packet.payload.category,stream=packet.stream,
        index=packet.segment,bytes=#packet.source,data=packet.source:sub(first,first+SEGMENT_BYTES-1)}
    local text=sync():Serialize({target=packet.peer,payload=payload})
    if engine():SupportsCompression(packet.peer) then
        local encoded,meta=sync():CompressRawMessage(text)
        if meta then text="Z:"..#text..":"..encoded end
    end
    packet.text,packet.id=text,packet.stream.."-"..packet.segment
    packet.position,packet.attempts,packet.wait=1,0,nil
end
function T:AcceptSegment(sender,p,public)
    if type(p.stream)~="string" or #p.stream>40 or not p.stream:match("^[%x%-]+$")
        or type(p.bytes)~="number" or p.bytes<=MAX_BYTES or p.bytes%1~=0
        or type(p.index)~="number" or p.index<1 or p.index%1~=0
        or type(p.data)~="string" or #p.data>SEGMENT_BYTES
        or not GP.SyncRecords.fields[p.category] or (public and private[p.category])
        or not engine():PeerAllowed(sender,p.category,false) then return false end
    local total=math.ceil(p.bytes/SEGMENT_BYTES)
    if p.index>total or #p.data~=math.min(SEGMENT_BYTES,p.bytes-(p.index-1)*SEGMENT_BYTES) then return false end
    local key=engine():NameKey(sender)
    local s=self.streams[key]
    if not s or s.id~=p.stream then
        if p.index~=1 then return false end
        local count=0;for _ in pairs(self.streams) do count=count+1 end
        if not s and count>=7 then return false end
        s={id=p.stream,category=p.category,bytes=p.bytes,parts={},next=1,public=public}
        self.streams[key]=s
    end
    if s.category~=p.category or s.bytes~=p.bytes or s.public~=public then return false end
    if p.index~=s.next then return false end
    s.parts[p.index],s.next,s.at=p.data,p.index+1,self.clock or 0
    if p.index<total then return true end
    -- Only a complete envelope reaches the existing authority/merge handlers.
    local text=table.concat(s.parts)
    self.streams[key]=nil
    if #text~=s.bytes then return false end
    local ok,envelope=sync():Deserialize(text)
    local payload=ok and type(envelope)=="table" and envelope.payload
    return type(payload)=="table" and payload.op~="segment" and payload.category==s.category
        and type(envelope.target)=="string" and sync():IsMe(envelope.target)
        and engine():Receive(sender,payload)
end
function T:Wire(peer,text,done,public)
    if self.wirePending or not sync():CanRetryBulkSync() or not ChatThrottleLib then return false end
    if sync().IsLowFrameRate and sync():IsLowFrameRate() then
        local now=GetTime()
        if self.nextLowFPSWire and now<self.nextLowFPSWire then return false end
        self.nextLowFPSWire=now+0.1
    else self.nextLowFPSWire=nil end
    self.wirePending=true
    local whisper=peer and not public
    if public and peer then text="G:"..self:Address(peer)..":"..text end
    if whisper then sync():BeginSyncSuppression(peer) end
    local ok=pcall(function()
        ChatThrottleLib:SendAddonMessage("NORMAL",PREFIX,text,whisper and "WHISPER" or "GUILD",whisper and peer or nil,PREFIX,function(_,sent)
            self.wirePending=nil
            if whisper then sync():EndSyncSuppression(peer) end
            if done then done(sent~=false) end
        end)
    end)
    if not ok then
        self.wirePending=nil
        if whisper then sync():EndSyncSuppression(peer) end
        if done then done(false) end
    end
    return ok
end
function T:Tick()
    if not sync():IsEnabled() or not sync():CanRetryBulkSync() then return end
    self.clock=(self.clock or 0)+INTERVAL
    if self.hello then
        if self:Wire(nil,"H:"..self.nonce) then self.hello=nil end
        return
    end
    for key,state in pairs(self.incoming) do
        if self.clock-state.at>180 then self.incoming[key]=nil end
    end
    for key,at in pairs(self.completed) do if self.clock-at>300 then self.completed[key]=nil end end
    for key,s in pairs(self.streams) do if self.clock-(s.at or 0)>180 then self.streams[key]=nil end end
    -- A missing acknowledgement from one peer must not block all other peers.
    for id,p in pairs(self.waiting) do
        if self.clock-p.wait>=8 or not engine():CanSend(p.peer,p.payload) then
            self.waiting[id]=nil;self.awaitingPeer[engine():NameKey(p.peer)]=nil
            p.attempts=p.attempts+1
            if p.attempts>=3 or not engine():CanSend(p.peer,p.payload) then
                self:ReleaseLarge(p)
                if p.done then p.done(false) end
            else
                p.position,p.wait=1,nil;self.queue[#self.queue+1]=p
            end
        end
    end
    if self.ack then
        local a=self.ack[1]
        if a and self:Wire(a.peer,"A:"..a.id,nil,a.public) then table.remove(self.ack,1);return end
    end
    if not self.active then
        for n,packet in ipairs(self.queue) do
            local key=engine():NameKey(packet.peer)
            if not self.awaitingPeer[key] and (not packet.source or not self.largePeer[key] or self.largePeer[key]==packet.stream) then
                self.active=table.remove(self.queue,n)
                if packet.source then self.largePeer[key]=packet.stream end
                break
            end
        end
    end
    local p=self.active
    if not p then return end
    if not engine():CanSend(p.peer,p.payload) then self.active=nil;self:ReleaseLarge(p);if p.done then p.done(false) end;return end
    if p.needsSegment then self:PrepareSegment(p);p.needsSegment=nil end
    local total=math.ceil(#p.text/BYTES)
    if p.position>total then
        p.wait=self.clock;self.waiting[p.id]=p;self.awaitingPeer[engine():NameKey(p.peer)]=true
        self.active=nil;return
    end
    local index=p.position
    local text="D:"..p.id..":"..index..":"..total..":"..p.text:sub((index-1)*BYTES+1,index*BYTES)
    self:Wire(p.peer,text,function(sent)
        if self.active==p and sent then
            p.position=index+1
            if p.source then engine():Progress(p.peer) end
        end
    end,p.public)
end
function T:Ack(peer,id,public)
    self.ack=self.ack or {}
    if #self.ack<32 then self.ack[#self.ack+1]={peer=peer,id=id,public=public} end
end
function T:Receive(_,prefix,message,distribution,sender)
    if prefix~=PREFIX or GP:IsSecretValue(message) or GP:IsSecretValue(sender)
        or type(message)~="string" or type(sender)~="string" or #message>255 then return end
    if sync():IsMe(sender) or not engine():PeerAllowed(sender) then return end
    if message:sub(1,2)=="H:" and distribution=="GUILD" then
        engine():Hello(sender,message:sub(3));return
    end
    local public=distribution=="GUILD"
    if public then
        local address,inner=message:match("^G:([%x]+):(.*)$")
        if address~=self:Address(sync():GetReconcileName()) then return end
        message=inner
    elseif distribution~="WHISPER" then return end
    if message:sub(1,2)=="A:" then
        local id=message:sub(3)
        local p=self.active and self.active.id==id and self.active or self.waiting[id]
        if p and p.id==message:sub(3) and engine():SamePeer(p.peer,sender) then
            engine():Heard(sender)
            if self.active==p then self.active=nil end
            self.waiting[id]=nil;self.awaitingPeer[engine():NameKey(p.peer)]=nil
            if p.source and p.segment*SEGMENT_BYTES<#p.source then
                p.segment=p.segment+1;p.needsSegment=true;p.id=nil;p.wait=nil
                self.queue[#self.queue+1]=p
            else
                self:ReleaseLarge(p)
                if p.done then p.done(true) end
            end
        end
        return
    end
    local id,index,total,part=message:match("^D:([%x%-]+):(%d+):(%d+):(.*)$")
    index,total=tonumber(index),tonumber(total)
    if not id or #id>48 or not index or index<1 or not total or index>total or total>math.ceil(MAX_BYTES/BYTES) or #part>BYTES then return end
    engine():Heard(sender)
    local key=sender:lower()..":"..id
    if self.completed[key] then self:Ack(sender,id,public);return end
    local state=self.incoming[key]
    if not state then
        local count=0;for _ in pairs(self.incoming) do count=count+1 end
        if count>=16 then return end
        state={parts={},total=total,count=0,at=self.clock or 0,sender=sender}
        self.incoming[key]=state
    end
    if state.total~=total then return end
    engine():Progress(sender)
    if not state.parts[index] then state.parts[index]=part;state.count=state.count+1 end
    state.at=self.clock or 0
    if state.count==total and not state.decoding then
        state.decoding=true
        local function finish()
            if self.incoming[key]~=state then return end
            if not sync():CanRetryBulkSync() then C_Timer.After(1,finish);return end
            if not engine():PeerAllowed(sender) then self.incoming[key]=nil;return end
            local text=table.concat(state.parts)
            self.incoming[key]=nil
            if #text>MAX_BYTES then return end
            if text:sub(1,2)=="Z:" then
                local size,encoded=text:match("^Z:(%d+):(.*)$")
                size=tonumber(size)
                if not size or size<1 or size>MAX_BYTES then return end
                local decoded,plain=sync():DecompressRawMessage(encoded,"deflate-addon",size,#encoded)
                if not decoded then return end
                text=plain
            end
            local ok,envelope=sync():Deserialize(text)
            local payload=ok and type(envelope)=="table" and envelope.payload
            if type(payload)=="table" and type(envelope.target)=="string" and sync():IsMe(envelope.target)
                and not (public and private[payload.category])
                and (payload.op=="segment" and self:AcceptSegment(sender,payload,public)
                    or payload.op~="segment" and engine():Receive(sender,payload)) then
                self.completed[key]=self.clock or 0
                self:Ack(sender,id,public)
            end
        end
        C_Timer.After(0,finish)
    end
end
