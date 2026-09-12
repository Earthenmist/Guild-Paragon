-- Admission for requested full-state and safety snapshots. Live updates bypass it.
local _, GP = ...
local Admission = GP:NewModule("SyncAdmission")
local LIMIT, BACKOFF, LEASE, MAX_SESSION = 3, 600, 180, 1200

local function sync() return GP:GetModule("GuildSync") end
local function fullPeerName(peer)
    if type(peer) ~= "string" or peer == "" then return nil end
    if not peer:find("-", 1, true) then
        peer = peer .. "-" .. (GetNormalizedRealmName and GetNormalizedRealmName() or "")
    end
    return peer
end
local function peerKey(peer)
    local full = fullPeerName(peer)
    return full and full:lower()
end

function Admission:PeerName(peer) return fullPeerName(peer) end

function Admission:Reset(guildKey)
    for _, slot in pairs(self.incoming or {}) do sync():DropBulkTransfer(slot.id) end
    for id in pairs(self.sending or {}) do sync():DropBulkTransfer(id) end
    self.guildKey = guildKey
    self.known, self.incoming, self.outgoing = {}, {}, {}
    self.sending, self.denied, self.finished = {}, {}, {}
    self.sequence = 0
    self.nonce = string.format("%06x%06x", math.random(0, 16777215), math.random(0, 16777215))
end

function Admission:Ready()
    if sync().IsEnabled and not sync():IsEnabled() then
        if self.guildKey then self:Reset(nil) end
        return false
    end
    local guildKey = GP:GetModule("Roster"):GetGuildKey()
    if self.guildKey ~= guildKey or not self.known then self:Reset(guildKey) end
    return guildKey ~= nil
end

function Admission:Observe(peer)
    if not self:Ready() then return end
    local key = peerKey(peer)
    if key then self.known[key] = true end
end

function Admission:Supports(peer)
    return self:Ready() and self.known[peerKey(peer)] == true
end

function Admission:Send(op, peer, id, kind, wait)
    return sync():SendBulkControl({op=op, to=peer, bid=id, kind=kind, wait=wait})
end

function Admission:Status(peer, status, detail)
    sync():RecordPeer(peer, status, nil, detail)
    GP:SendMessage("GuildParagon_SyncStatusChanged", self.guildKey)
end

function Admission:GetStats()
    if not self:Ready() then return 0, 0 end
    local active, deferred = 0, 0
    for _ in pairs(self.incoming) do active = active + 1 end
    for _, untilTime in pairs(self.denied) do
        if untilTime > time() then deferred = deferred + 1 end
    end
    return active, deferred
end

function Admission:Queue(guildKey, peer, kind, requestID)
    if not self:Ready() or guildKey ~= self.guildKey then return false end
    local key = peerKey(peer)
    if not key or (kind ~= "full" and kind ~= "safety") then return false end
    local entry = self.outgoing[key]
    if not entry then
        entry = {peer=peer, pending={}}
        self.outgoing[key] = entry
    end
    if entry.active and entry.active.kind == kind and entry.active.requestID == requestID then return true end
    entry.pending[kind] = {guildKey=guildKey, peer=peer, kind=kind, requestID=requestID}
    self:Pump(entry)
    return true
end

function Admission:Pump(entry)
    if entry.active or (entry.retryAt and entry.retryAt > time()) then return end
    -- A delayed retry uses the existing recovery guard, including Housing rules.
    if entry.retryAt and not sync():CanRetryBulkSync() then return end
    local job = entry.pending.full or entry.pending.safety
    if not job then return end
    entry.pending[job.kind] = nil
    self.sequence = self.sequence + 1
    job.id = self.nonce .. string.format("%x", self.sequence)
    job.state, job.deadline = "offered", time() + 30
    entry.active = job
    self:Send("bulkoffer", job.peer, job.id, job.kind)
end

function Admission:Retire(entry, retry)
    local job = entry.active
    if not job then return end
    self.sending[job.id] = nil
    sync():DropBulkTransfer(job.id)
    entry.active = nil
    if retry then
        -- Store only the request, never a built snapshot, while waiting.
        entry.pending[job.kind] = entry.pending[job.kind] or {
            guildKey=job.guildKey, peer=job.peer, kind=job.kind, requestID=job.requestID,
        }
        entry.retryAt = time() + BACKOFF + math.random(0, 30)
        self:Status(job.peer, "Sync deferred", GP.L["Full/safety sync will retry in 10 minutes."])
    end
end

function Admission:IsSending(id)
    return self:Ready() and self.sending[id] ~= nil
end

function Admission:GetTarget(id)
    local job = self.sending and self.sending[id]
    return job and job.peer
end

function Admission:Accept(peer, id, kind)
    if not self:Ready() then return false end
    local slot = self.incoming[peerKey(peer)]
    if not slot or slot.id ~= id or slot.closing or slot.expires <= time()
        or (kind and slot.kind ~= kind) then return false end
    slot.expires = math.min(time() + LEASE, slot.deadline)
    return true
end

function Admission:BeginApply(peer, id, kind)
    if not self:Accept(peer, id, kind) then return false end
    local slot = self.incoming[peerKey(peer)]
    slot.applying = (slot.applying or 0) + 1
    return true
end

function Admission:CloseIncoming(key, notify)
    local slot = self.incoming[key]
    if not slot then return end
    if not slot.closing then sync():DropBulkTransfer(slot.id, true) end
    slot.closing = true
    slot.notify = slot.notify or notify
    -- An already-running batched apply keeps its slot until its callback ends.
    if (slot.applying or 0) == 0 then
        self.incoming[key] = nil
        if slot.notify then self:Send("bulkcancel", slot.peer, slot.id) end
    end
end

function Admission:EndApply(peer, id)
    local key = peerKey(peer)
    local slot = self.incoming[key]
    if not slot or slot.id ~= id then return false end
    slot.applying = math.max(0, (slot.applying or 0) - 1)
    if slot.closing then self:CloseIncoming(key); return false end
    return true
end

function Admission:AbortIncoming(peer, id)
    local key = peerKey(peer)
    local slot = self.incoming and self.incoming[key]
    if not slot or slot.id ~= id then return end
    self:CloseIncoming(key, true)
end

function Admission:AbortSending(id)
    for _, entry in pairs(self.outgoing or {}) do
        if entry.active and entry.active.id == id then
            self:Send("bulkcancel", entry.peer, id)
            self:Retire(entry, false)
            return
        end
    end
end

function Admission:PeerUnavailable(peer)
    if not self:Ready() then return end
    local key = peerKey(peer)
    local slot = self.incoming[key]
    if slot then
        self:CloseIncoming(key)
    end
    local entry = self.outgoing[key]
    if entry then entry.unavailable = true end
    if entry and entry.active then
        if sync():CanRetryBulkSync() then self:Send("bulkcancel", peer, entry.active.id) end
        self:Retire(entry, true)
    end
end

function Admission:PeerAvailable(peer)
    if not self:Ready() then return end
    local entry = self.outgoing[peerKey(peer)]
    if entry and entry.unavailable then
        entry.unavailable = nil
        entry.retryAt = nil
        self:Pump(entry)
    end
end

function Admission:Complete(peer, id)
    if not id or not self:Accept(peer, id) then return end
    local key = peerKey(peer)
    if (self.incoming[key].applying or 0) > 0 then return end
    self.incoming[key] = nil
    self.finished[key .. ":" .. id] = time() + BACKOFF
    sync():DropBulkTransfer(id, true)
    self:Send("bulkdone", peer, id)
    GP:SendMessage("GuildParagon_SyncStatusChanged", self.guildKey)
end

function Admission:CancelRequest(kind, requestID)
    if not self:Ready() or not requestID then return end
    for _, entry in pairs(self.outgoing) do
        local pending = entry.pending[kind]
        if pending and pending.requestID == requestID then entry.pending[kind] = nil end
        local job = entry.active
        if job and job.kind == kind and job.requestID == requestID and job.state == "offered" then
            self:Send("bulkcancel", job.peer, job.id)
            self:Retire(entry, false)
        end
    end
end

function Admission:OnControl(payload, peer)
    if not self:Ready() or not sync():IsMe(payload.to) then return end
    if type(payload.bid) ~= "string" or #payload.bid > 40 then return end
    local key, now = peerKey(peer), time()
    if not key then return end
    self.known[key] = true
    local id, op = payload.bid, payload.op
    local slot = self.incoming[key]
    if op == "bulkoffer" then
        if payload.kind ~= "full" and payload.kind ~= "safety" then return end
        if (self.finished[key .. ":" .. id] or 0) > now then
            self:Send("bulkdone", peer, id)
            return
        end
        if slot and slot.id == id and slot.kind == payload.kind then
            self:Send("bulkready", peer, id)
            return
        end
        local count = self:GetStats()
        if slot or count >= LIMIT or (self.denied[key] or 0) > now then
            if (self.denied[key] or 0) <= now then self.denied[key] = now + BACKOFF end
            self:Send("bulkbusy", peer, id, nil, self.denied[key] - now)
            self:Status(peer, "Sync deferred", GP.L["Three sync peers are active; retry in 10 minutes."])
            return
        end
        self.incoming[key] = {id=id, peer=peer, kind=payload.kind, expires=now+LEASE, deadline=now+MAX_SESSION}
        self:Send("bulkready", peer, id)
        self:Status(peer, "Sync admitted", GP.L["Full/safety sync slot reserved."])
    elseif op == "bulkhold" then
        if not self:Accept(peer, id) then
            self:Send(self.finished[key .. ":" .. id] and "bulkdone" or "bulkcancel", peer, id)
        end
    elseif op == "bulkcancel" and slot and slot.id == id then
        self:CloseIncoming(key)
    else
        local entry = self.outgoing[key]
        local job = entry and entry.active
        if not job or job.id ~= id then return end
        if op == "bulkready" and job.state == "offered" then
            job.state, job.deadline, job.heartbeat = "sending", now + MAX_SESSION, now + 30
            self.sending[id] = job
            if job.kind == "full" then
                sync():SendFullState(job.guildKey, job.peer, job.requestID, id)
            else
                sync():SendSafetyState(job.guildKey, job.peer, job.requestID, id)
            end
        elseif op == "bulkdone" then
            self:Retire(entry, false)
            self:Pump(entry)
        elseif op == "bulkbusy" or op == "bulkcancel" then
            self:Retire(entry, true)
        end
    end
end

function Admission:Tick()
    if not self:Ready() then return end
    local now = time()
    for key, slot in pairs(self.incoming) do
        if slot.expires <= now then
            self:CloseIncoming(key)
        end
    end
    for key, expires in pairs(self.finished) do if expires <= now then self.finished[key] = nil end end
    for key, expires in pairs(self.denied) do if expires <= now then self.denied[key] = nil end end
    for key, entry in pairs(self.outgoing) do
        local job = entry.active
        if job and job.deadline <= now then
            if sync():CanRetryBulkSync() then self:Send("bulkcancel", job.peer, job.id) end
            self:Retire(entry, true)
        elseif job and job.state == "sending" and job.heartbeat <= now then
            job.heartbeat = now + 30
            self:Send("bulkhold", job.peer, job.id)
        end
        self:Pump(entry)
        if not entry.active and not next(entry.pending) and (entry.retryAt or 0) <= now then
            self.outgoing[key] = nil
        end
    end
end

function Admission:OnEnable()
    self:Ready()
    self.ticker = C_Timer.NewTicker(2, function() self:Tick() end)
end

function Admission:OnDisable()
    if self.ticker then self.ticker:Cancel(); self.ticker = nil end
    self:Reset(nil)
end
