-- Fixed operation boundaries for local diagnostics.
local _, GP = ...
local installed = false
function GP:InstallPerformanceHooks()
    if installed then return end
    installed = true
    local function hook(target, method, label)
        if target and type(target[method]) == "function" then target[method] = GP:MonitorWrap(label,target[method]) end
    end
    local sync=self:GetModule("GuildSync",true)
    for _, row in ipairs({
        {"OnChatMsgAddon","sync.receive"}, {"ProcessPayload","sync.dispatch"},
        {"DecompressRawMessage","sync.decompress"}, {"Deserialize","sync.deserialize"},
        {"Serialize","sync.serialize"}, {"CompressRawMessage","sync.compress"},
        {"HandleRawChunk","sync.rawChunk"}, {"ApplySafetyState","sync.safetySetup"},
        {"ReceiveFullStateCategory","sync.fullCategory"}, {"FinishFullExchange","sync.fullFinish"},
        {"BuildSafetyPayload","sync.buildSafety"}, {"SendFullState","sync.buildFull"},
        {"CleanupRuntimeCaches","sync.cleanup"}, {"SendPresencePing","sync.presence"},
        {"SendRawPayload","sync.sendRaw"}, {"GetLocalCounts","sync.counts"},
        {"ApplyFullLogChunk","sync.fullLog"},
        {"RecordPeer","sync.peer"},
        {"ComputeCategoryProgress","sync.peerTotals"},
        {"CleanupRawTransferCaches","sync.rawCleanup"},
        {"ExpireStaleRawReceives","sync.rawExpire"},
        {"SweepStaleFullExchanges","sync.exchangeSweep"},
        {"HandleHello","sync.hello"},
        {"HandleSafetyHello","sync.safetyHello"},
        {"SendToPeer","sync.sendPeer"},
        {"MarkPeerUnreachable","sync.markOffline"},
        {"ApplyNick","sync.applyNick"},
        {"ApplyAlt","sync.applyAlt"},
        {"ApplyMain","sync.applyMain"},
        {"ApplyCustomNote","sync.applyNote"},
        {"ApplyLogEntry","sync.applyLog"},
        {"ApplyBan","sync.applyBan"},
        {"ApplyRecruitmentSettings","sync.applyRecruitment"},
        {"ApplyLabel","sync.applyLabel"},
        {"OnRosterScanned","sync.rosterCallback"},

    }) do hook(sync,row[1],row[2]) end
    hook(self:GetModule("GuildHealth",true),"GetSummary","health.compute")
    hook(self:GetModule("Recruitment",true),"BuildScannerQueries","recruitment.scan")
    local roster=self:GetModule("Roster",true)
    hook(roster,"Scan","roster.setup")
    hook(roster,"CountMembers","roster.count")
    hook(self:GetModule("Housing",true),"MaybeAutoScan","housing.autoScan")
    hook(self:GetModule("SyncAdmission",true),"OnControl","sync.admissionControl")
    hook(self:GetModule("SyncAdmission",true),"Accept","sync.admissionAccept")
    local sendMessage=self.SendMessage
    local notifications={GuildParagon_RosterScanned="notify.roster", GuildParagon_SyncStatusChanged="notify.sync",
        GuildParagon_NicknamesChanged="notify.nicknames", GuildParagon_AltsChanged="notify.alts", GuildParagon_LogEntryAdded="notify.log"}
    if sendMessage then
        self.SendMessage=function(owner,event,...)
            local label=not GP:IsSecretValue(event) and notifications[event]
            if label then return GP:MonitorCall(label,sendMessage,owner,event,...) end
            return sendMessage(owner,event,...)
        end
    end
    hook(roster,"CorroborateJoinDatesFromGuildEventLog","roster.events")
    for _, row in ipairs({{"RosterTab","Refresh","ui.roster"},
        {"GuildSyncTab","RefreshStatus","ui.sync"}, {"GuildHealthTab","Refresh","ui.health"},
        {"RecruitmentTab","Refresh","ui.recruitment"}, {"EventLogTab","Refresh","ui.log"},
        {"ExportStatsTab","Refresh","ui.exports"}}) do hook(self.UI[row[1]],row[2],row[3]) end
end
