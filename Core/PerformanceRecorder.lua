-- Opt-in local performance history. No gameplay payloads are retained.
local ADDON, GP = ...
local Recorder = GP:NewModule("PerformanceRecorder")
GP.Recorder = Recorder
local SCHEMA, MAX_SESSIONS, MAX_RECENT, MAX_WORST = 2, 14, 200, 50
local ids = {
    "sync.receive", "sync.dispatch", "sync.concat", "sync.decompress", "sync.deserialize",
    "sync.serialize", "sync.compress", "sync.rawChunk", "sync.safetySetup", "sync.applyBatch",
    "sync.fullCategory", "sync.fullFinish", "sync.buildSafety", "sync.buildFull", "sync.buildStep",
    "sync.cleanup", "sync.presence", "sync.sendRaw", "sync.counts", "sync.fullLog",
    "roster.setup", "roster.gather", "roster.apply", "roster.depart", "roster.finish",
    "roster.beginApply", "roster.beginDepart", "roster.events", "frame.steps", "frame.batch",
    "ui.roster", "ui.sync", "ui.health", "ui.recruitment", "ui.log", "ui.exports",
    "sync.apply.safety", "sync.apply.bans", "sync.apply.recruitmentBlacklist", "sync.apply.nicknames", "sync.apply.altsMains", "sync.apply.macroIgnores", "sync.apply.macroRules", "sync.apply.recruitmentItems", "sync.apply.formerMembers", "sync.apply.birthdays", "sync.apply.joinDates", "sync.apply.notesOfficer", "sync.apply.notesGeneral", "sync.apply.log", "sync.apply.labels",
    "health.compute", "recruitment.scan", "monitor.probe", "diagnostic.memoryRefresh",
}
local LEGACY_IDS = #ids
for _, label in ipairs({
    "sync.peer","sync.peerTotals","sync.rawCleanup","sync.rawExpire",
    "sync.exchangeSweep","sync.hello","sync.safetyHello","sync.sendPeer",
    "sync.markOffline","sync.applyNick","sync.applyAlt","sync.applyMain",
    "sync.applyNote","sync.applyLog","sync.applyBan","sync.applyRecruitment",
    "sync.applyLabel","sync.buildFinish","sync.safetyFinish","sync.safetySettings",
    "notify.roster","notify.sync","notify.nicknames","notify.alts",
    "notify.log","ui.rosterList","ui.rosterRows","roster.count",
    "housing.autoScan","sync.rosterCallback","sync.admissionControl","sync.admissionAccept",
    "sync.safetyBans","sync.safetyBlacklist","ui.rosterDetail",
}) do ids[#ids+1]=label end
local TARGETED_IDS = #ids
ids[#ids+1] = "ui.companionPreview"
local index = {}; for i, label in ipairs(ids) do index[label] = i end
local active, session, db, watcher, depth = false, nil, nil, nil, 0
local starts, children, stackSessions, details = {}, {}, {}, {}
local loading, context, combat, graceUntil = true, "unknown", "unknown", 0
local latestID, latestMs, latestAt = 0, 0, 0
local lastTick, baseline, nextContext = nil, 0, 0
local capMs, backgroundCapMs = 0, 0
local clock = GetTimePreciseSec or GetTime
local function now() return clock() end
local function plain(v) return not GP:IsSecretValue(v) end
local function number(v)
    if not plain(v) or type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end
local function read(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and plain(value) then return value end
end
local function stat() return {n=0, total=0, own=0, peak=0, errors=0, loading=0, over10=0, over50=0, over100=0, over500=0} end
local function ringPush(ring, record, limit)
    ring.pos = ring.pos % limit + 1
    ring.data[ring.pos] = record
    ring.count = math.min(limit, ring.count + 1)
end
local function keepWorst(list, record)
    if #list >= MAX_WORST and record.ms <= list[#list].ms then return end
    local pos = #list + 1
    while pos > 1 and record.ms > list[pos-1].ms do pos = pos - 1 end
    table.insert(list, pos, record)
    list[MAX_WORST+1] = nil
end
local function refreshContext()
    context, combat = "unknown", "unknown"
    local ok, inside, kind = pcall(IsInInstance or function() end)
    if ok and plain(inside) and plain(kind) then
        if inside == false then context = read(IsResting) == true and "city" or "world"
        elseif inside == true then
            if kind == "raid" or kind == "party" or kind == "scenario" or kind == "arena" or kind == "pvp"
                or kind == "neighborhood" or kind == "interior" then context = kind end
        end
    end
    local function capPeriod(key)
        local raw=read(C_CVar and C_CVar.GetCVar,key)
        local fps=type(raw)=="string" and tonumber(raw) or number(raw)
        return fps and fps>0 and 1000/fps or 0
    end
    capMs,backgroundCapMs=capPeriod("maxFPS"),capPeriod("maxFPSBk")
    local value = read(InCombatLockdown)
    if value == true then combat = "combat" elseif value == false then combat = "calm" end
end
local function newSession()
    local version = read(C_AddOns and C_AddOns.GetAddOnMetadata, ADDON, "Version")
    local client = read(GetBuildInfo)
    local build = read(function() local _, value = GetBuildInfo(); return value end)
    local s = {diagnostics=2, started=time(), ended=time(), clockStart=now(), build=type(build)=="string" and build or "unknown", version=type(version)=="string" and version or "unknown",
        client=type(client)=="string" and client or "unknown", frames=0, measured=0,
        loading=0, unavailable=0, hitches=0, peak=0, gpTotal=0, gpSamples=0,
        addonTotal=0, addonSamples=0, appTotal=0, appSamples=0, capFrames=0, capSuspectSec=0,
        samplerMs=0, samplerPeak=0, bookMs=0, skippedDepth=0,
        hist={0,0,0,0,0,0}, contexts={}, operations={}, recent={data={},pos=0,count=0}, worst={},
        slow={data={},pos=0,count=0}, slowWorst={}}
    for i=1,#ids do s.operations[i] = stat() end
    for _, key in ipairs({"unknown","city","world","raid","party","scenario","arena","pvp","neighborhood","interior"}) do
        s.contexts[key] = {sec=0,hitches=0}
    end
    db.sessions[#db.sessions+1] = s
    if #db.sessions > MAX_SESSIONS then table.remove(db.sessions,1) end
    return s
end

-- Fixed identifiers prevent dynamic keys or private data entering the history.
function GP:MonitorWrap(label, fn)
    return function(...) return self:MonitorCall(label, fn, ...) end
end
-- Only allowlisted protocol names and bounded numbers enter detailed records.
local messageTypes = {}
for op in string.gmatch("rawstart rawchunk rawmissing hello hellosatisfied ping pong bye safetyhello safetysatisfied safetyfull full fulllogrequest fulllogclaim fulllogchunk logentry alt altclear main mainclear nick customnote joindate birthday formermember macrorule macroignore ban recruitmentsettings recruitmentblacklist label bulkoffer bulkready bulkbusy bulkhold bulkdone bulkcancel", "%S+") do messageTypes[op]=true end
function GP:MonitorDetail(key, value)
    if not active or depth==0 or not plain(key) or not plain(value) then return end
    if key=="message" then
        if type(value)~="string" or not messageTypes[value] then return end
    elseif key=="bytes" or key=="records" or key=="peers" or key=="step" or key=="requests" or key=="trigger" then
        value=number(value)
        if not value or value<0 or value>100000000 then return end
        value=math.floor(value)
    else return end
    details[depth]=details[depth] or {}
    details[depth][key]=value
end
local function finishCall(id, level, ok, ...)
    local ended = now()
    local elapsed = math.max(0, (ended-starts[level])*1000)
    local own = math.max(0, elapsed-children[level])
    local owner = stackSessions[level]
    depth = level-1
    if depth > 0 then children[depth] = children[depth] + elapsed end
    if active and session == owner then
        local s = session.operations[id]
        s.n=s.n+1; s.total=s.total+elapsed; s.own=s.own+own; s.peak=math.max(s.peak,elapsed)
        local duringLoading=loading or ended<graceUntil
        if duringLoading then s.loading=s.loading+1 end
        if not ok then s.errors=s.errors+1 end
        if elapsed>=10 then s.over10=s.over10+1 end
        if elapsed>=50 then s.over50=s.over50+1 end
        if elapsed>=100 then s.over100=s.over100+1 end
        if elapsed>=500 then s.over500=s.over500+1 end
        if elapsed>=10 then
            local rec = {at=time(), offset=(ended-owner.clockStart)*1000, id=id, ms=elapsed, own=own, ctx=context, combat=combat, loading=duringLoading}
            for _, key in ipairs({"message","bytes","records","peers","step","requests","trigger"}) do
                for d=level,1,-1 do
                    if details[d] and details[d][key]~=nil then rec[key]=details[d][key]; break end
                end
            end
            ringPush(session.slow,rec,MAX_RECENT); keepWorst(session.slowWorst,rec)
            if ended-latestAt>0.5 or elapsed>=latestMs then latestID,latestMs,latestAt=id,elapsed,ended end
        end
        session.bookMs=session.bookMs+math.max(0,(now()-ended)*1000)
    end
    details[level]=nil
    if not ok then error((...),0) end
    return ...
end
function GP:MonitorCall(label, fn, ...)
    if not active then return fn(...) end
    local id = index[label]
    if not id then return fn(...) end
    if depth>=32 then session.skippedDepth=session.skippedDepth+1; return fn(...) end
    depth=depth+1
    local level=depth
    starts[level],children[level],stackSessions[level],details[level]=now(),0,session,nil
    return finishCall(id,level,pcall(fn,...))
end

local function metric(method, ...)
    return number(read(method, ...))
end
function Recorder:Tick()
    if not active then return end
    local started=now()
    local previous=lastTick
    local delta=lastTick and started-lastTick or 0
    lastTick=started
    if started>=nextContext then refreshContext(); nextContext=started+2 end
    session.ended=time()
    local excluded
    if loading or started<graceUntil or (previous and previous<graceUntil) then excluded="loading"
    end
    if delta<=0 then return end
    if excluded then session[excluded]=session[excluded]+delta; baseline=0; return end
    local ms=delta*1000
    session.frames=session.frames+1; session.measured=session.measured+delta
    session.contexts[context].sec=session.contexts[context].sec+delta
    local bucket = ms<16.7 and 1 or ms<33.4 and 2 or ms<50 and 3 or ms<100 and 4 or ms<500 and 5 or 6
    session.hist[bucket]=session.hist[bucket]+1
    local P,M=C_AddOnProfiler,Enum and Enum.AddOnProfilerMetric
    local gp,all,app
    if P and M and read(P.IsEnabled)==true then
        gp=metric(P.GetAddOnMetric,ADDON,M.LastTime)
        all=metric(P.GetOverallMetric,M.LastTime)
        app=metric(P.GetApplicationMetric,M.LastTime)
    end
    if gp and gp>=0 then session.gpTotal=session.gpTotal+gp; session.gpSamples=session.gpSamples+1
    else gp=nil; session.unavailable=session.unavailable+delta end
    if all and all>=0 then session.addonTotal=session.addonTotal+all; session.addonSamples=session.addonSamples+1 else all=nil end
    if app and app>=0 then session.appTotal=session.appTotal+app; session.appSamples=session.appSamples+1 else app=nil end
    local matchesCap=capMs>0 and math.abs(ms-capMs)<capMs*0.08
    if matchesCap then session.capFrames=session.capFrames+1 end
    local suspect=backgroundCapMs>0 and math.abs(ms-backgroundCapMs)<backgroundCapMs*0.08
        and math.abs(backgroundCapMs-capMs)>backgroundCapMs*0.08
    if suspect then session.capSuspectSec=session.capSuspectSec+delta end
    local threshold=math.max(50,baseline*2,capMs*1.5)
    if ms>=threshold then
        session.hitches=session.hitches+1; session.peak=math.max(session.peak,ms)
        session.contexts[context].hitches=session.contexts[context].hitches+1
        local nearby=started-latestAt<=0.5
        local rec={at=time(),offset=(started-session.clockStart)*1000,ms=ms,gp=gp,all=all,app=app,ctx=context,combat=combat,cap=suspect,
            id=nearby and latestID or 0,nearMs=nearby and latestMs or 0,
            nearAge=nearby and (started-latestAt)*1000 or 0}
        ringPush(session.recent,rec,MAX_RECENT); keepWorst(session.worst,rec)
    end
    if baseline==0 then baseline=math.min(ms,50)
    elseif ms<threshold then baseline=baseline+(ms-baseline)*0.02 end
    local cost=math.max(0,(now()-started)*1000)
    session.samplerMs=session.samplerMs+cost; session.samplerPeak=math.max(session.samplerPeak,cost)
end
function Recorder:Start()
    if active then return end
    db.enabled=true; active=true; session=newSession()
    refreshContext(); lastTick=nil; baseline=0; nextContext=0
    latestID,latestMs,latestAt=0,0,0
    for i=1,32 do starts[i]=0; children[i]=0 end
    watcher:SetScript("OnUpdate",function() self:Tick() end)
end
function Recorder:Stop()
    if session then session.ended=time() end
    active=false; db.enabled=false; watcher:SetScript("OnUpdate",nil)
end
local function validSession(s)
    if type(s)~="table" or type(s.version)~="string" or type(s.client)~="string" or type(s.build)~="string" then return false end
    for _,key in ipairs({"started","ended","clockStart","frames","measured","loading","unavailable","hitches","peak",
        "gpTotal","gpSamples","addonTotal","addonSamples","appTotal","appSamples","capFrames","capSuspectSec",
        "samplerMs","samplerPeak","bookMs","skippedDepth"}) do if not number(s[key]) then return false end end
    if type(s.hist)~="table" or #s.hist~=6 or type(s.operations)~="table" or #s.operations~=#ids then return false end
    if type(s.contexts)~="table" then return false end
    for _,key in ipairs({"unknown","city","world","raid","party","scenario","arena","pvp","neighborhood","interior"}) do
        local c=s.contexts[key];if type(c)~="table" or not number(c.sec) or not number(c.hitches) then return false end
    end
    for _,r in ipairs(s.operations) do
        if type(r)~="table" then return false end
        for _,key in ipairs({"n","total","own","peak","errors","loading","over10","over50","over100","over500"}) do if not number(r[key]) then return false end end
    end
    for _,key in ipairs({"recent","slow"}) do
        local r=s[key]
        if type(r)~="table" or type(r.data)~="table" or not number(r.pos) or not number(r.count)
            or r.pos%1~=0 or r.count%1~=0 or r.pos<0 or r.pos>MAX_RECENT or r.count<0 or r.count>MAX_RECENT or #r.data~=r.count then return false end
    end
    for _,key in ipairs({"worst","slowWorst"}) do if type(s[key])~="table" or #s[key]>MAX_WORST then return false end end
    return true
end
function Recorder:OnEnable()
    -- Append-only operation IDs preserve format-1 history and recording preference.
    if type(GuildParagonPerfDB)=="table" and GuildParagonPerfDB.schema==1 then
        for _, old in ipairs(type(GuildParagonPerfDB.sessions)=="table" and GuildParagonPerfDB.sessions or {}) do
            if type(old)=="table" and type(old.operations)=="table" and #old.operations==LEGACY_IDS then
                for i=LEGACY_IDS+1,#ids do old.operations[i]=stat() end
            end
        end
        GuildParagonPerfDB.schema=SCHEMA
    end
    if type(GuildParagonPerfDB)~="table" or GuildParagonPerfDB.schema~=SCHEMA then
        GuildParagonPerfDB={schema=SCHEMA,enabled=false,sessions={}}
    end
    db=GuildParagonPerfDB
    for _, old in ipairs(type(db.sessions)=="table" and db.sessions or {}) do
        if type(old)=="table" and type(old.operations)=="table" and #old.operations==TARGETED_IDS then
            old.operations[#ids]=stat()
        end
    end
    if type(db.sessions)~="table" then db.sessions={} end
    local retained={}
    for i=math.max(1,#db.sessions-MAX_SESSIONS+1),#db.sessions do
        if validSession(db.sessions[i]) then retained[#retained+1]=db.sessions[i] end
    end
    db.sessions=retained
    db.enabled=db.enabled==true
    if not watcher then watcher=CreateFrame("Frame") end
    watcher:SetScript("OnEvent",function(_,event)
        if event=="PLAYER_LEAVING_WORLD" then loading=true
        elseif event=="PLAYER_ENTERING_WORLD" then
            if active and lastTick then session.loading=session.loading+math.max(0,now()-lastTick) end
            loading=false; graceUntil=now()+3; lastTick=nil
        elseif event=="PLAYER_LOGOUT" then if session then session.ended=time() end end
        refreshContext()
    end)
    for _, event in ipairs({"PLAYER_LEAVING_WORLD","PLAYER_ENTERING_WORLD","PLAYER_LOGOUT",
        "PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","ZONE_CHANGED_NEW_AREA"}) do watcher:RegisterEvent(event) end
    if GP.InstallPerformanceHooks then GP:InstallPerformanceHooks() end
    if db.enabled then self:Start() end
end
function Recorder:OnDisable()
    if db then self:Stop() end
    if watcher then watcher:UnregisterAllEvents() end
end
function Recorder:GetState() return active,session,db end

function Recorder:Report()
    local L=GP.L
    local lines={L["Guild Paragon performance recorder - format 2"],
        L["Frame readings are sampled; nearby operations are correlation, not exact frame attribution."],
        L["Sampled time may include background play. Background-cap matches are evidence only, not confirmed focus; no frames are discarded on that heuristic."],
        L["Operation totals are synchronous inclusive/own time; async waits are excluded. Do not sum inclusive totals."],
        L["Operation totals include loading calls, which are labelled separately; frame hitch counts exclude loading."],
        L["Monitor cost is included in GP. Sampler/bookkeeping estimates exclude some wrapper and clock overhead."],
        L["Local history: 14 sessions; each keeps 200 recent and 50 worst frames and slow calls. Normal logout/reload saves; crashes may lose data."],
        L["Buckets: <16.7, <33.4, <50, <100, <500, >=500 ms. Slow calls >=10 ms. No engine-cause or per-addon allocation claims."]}
    for n,s in ipairs(db.sessions) do
        lines[#lines+1]=string.format(L["Session %d: %s / client %s build %s; %d to %d"],n,s.version,s.client,s.build,s.started,s.ended)
        lines[#lines+1]=string.format(L["Sampled %.1fs / %d frames; loading %.1fs; GP metrics unavailable %.1fs; cap-matching frames %d"],s.measured,s.frames,s.loading,s.unavailable,s.capFrames)
        lines[#lines+1]=string.format(L["Hitches %d; peak %.2fms; GP/all-addons/application sampled averages %.3f / %.3f / %.3fms (%d / %d / %d samples)"],s.hitches,s.peak,s.gpTotal/math.max(1,s.gpSamples),s.addonTotal/math.max(1,s.addonSamples),s.appTotal/math.max(1,s.appSamples),s.gpSamples,s.addonSamples,s.appSamples)
        lines[#lines+1]=string.format(L["Sampler %.3fms/frame, peak %.3fms; operation bookkeeping %.3fms; depth skips %d"],s.samplerMs/math.max(1,s.frames),s.samplerPeak,s.bookMs,s.skippedDepth)
        lines[#lines+1]=string.format("possibleBackgroundCapSeconds=%.1f",s.capSuspectSec)
        lines[#lines+1]="diagnostics="..(s.diagnostics==2 and "2" or "1")
        lines[#lines+1]="hist="..table.concat(s.hist,",")
        for _,key in ipairs({"unknown","city","world","raid","party","scenario","arena","pvp","neighborhood","interior"}) do
            local c=s.contexts[key]
            if c.sec>0 then lines[#lines+1]=string.format("context=%s seconds=%.1f hitches=%d",key,c.sec,c.hitches) end
        end
        for i,r in ipairs(s.operations) do
            if r.n>0 then lines[#lines+1]=string.format("op=%s calls=%d inclusive=%.3f own=%.3f peak=%.3f errors=%d loadingCalls=%d >=10/50/100/500=%d/%d/%d/%d",ids[i],r.n,r.total,r.own,r.peak,r.errors,r.loading,r.over10,r.over50,r.over100,r.over500) end
        end
        local function frameLine(r,kind)
            return string.format("%s at=%d offsetMs=%.3f ms=%.2f gp=%s all=%s app=%s context=%s/%s nearby=%s nearMs=%.2f ageMs=%.2f capCandidate=%s",kind,r.at,r.offset,r.ms,r.gp and string.format("%.2f",r.gp) or "?",r.all and string.format("%.2f",r.all) or "?",r.app and string.format("%.2f",r.app) or "?",r.ctx,r.combat,ids[r.id] or "unknown",r.nearMs,r.nearAge,r.cap and "yes" or "no")
        end
        for _,r in ipairs(s.worst) do lines[#lines+1]=frameLine(r,"worstFrame") end
        for j=1,s.recent.count do
            local r=s.recent.data[(s.recent.pos-s.recent.count+j-1)%MAX_RECENT+1]
            lines[#lines+1]=frameLine(r,"recentFrame")
        end
        local function callLine(r,kind)
            local line = string.format("%s at=%d offsetMs=%.3f op=%s ms=%.3f own=%.3f context=%s/%s loading=%s",kind,r.at,r.offset,ids[r.id],r.ms,r.own,r.ctx,r.combat,r.loading and "yes" or "no")
            for _,key in ipairs({"message","bytes","records","peers","step","requests","trigger"}) do
                local value=r[key]
                if plain(value) and ((key=="message" and type(value)=="string" and messageTypes[value]) or (key~="message" and number(value))) then
                    line=line.." "..key.."="..tostring(value)
                end
            end
            return line
        end
        for _,r in ipairs(s.slowWorst) do lines[#lines+1]=callLine(r,"worstCall") end
        for j=1,s.slow.count do
            lines[#lines+1]=callLine(s.slow.data[(s.slow.pos-s.slow.count+j-1)%MAX_RECENT+1],"recentCall")
        end
    end
    return table.concat(lines,"\n")
end
function Recorder:Command(command)
    local L=GP.L
    refreshContext()
    if command=="start" then self:Start(); GP:Print(L["Performance recording started. Use /gp monitor export after playing; /gp monitor stop to disable."])
    elseif command=="stop" then self:Stop(); GP:Print(L["Performance recording stopped; saved history retained."])
    elseif command=="reset" then GP:Print(L["Use /gp monitor reset confirm to erase local performance history."])
    elseif command=="reset confirm" then self:Stop(); db.sessions={}; session=nil; GP:Print(L["Performance history cleared; recorder stopped."])
    elseif command=="export" then
        if loading or combat~="calm" or context=="unknown" or (context~="world" and context~="city" and context~="neighborhood" and context~="interior") then
            GP:Print(L["Export performance history outside combat and protected instances."]); return
        end
        self:ShowExport()
    else
        GP:Print(active and L["Performance recorder: ON"] or L["Performance recorder: OFF"])
        GP:Print(L["/gp monitor start | stop | status | export | reset"])
        if session then GP:Print(string.format(L["Current recording: %.1f minutes, %d hitches; worst frame %.1f ms."],session.measured/60,session.hitches,session.peak)) end
    end
end
