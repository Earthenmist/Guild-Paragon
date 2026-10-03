-- Category adapters retain the existing saved-data and merge contracts.
local _, GP = ...
local R = {}
GP.SyncRecords = R
local categoryLabels={recruitmentItems="Recruitment settings",recruitmentBlacklist="Do-not-invite",
    bans="Bans",altsMains="Alts and mains",nicknames="Nicknames",labels="Labels",
    birthdays="Birthdays",joinDates="Join dates",notesGeneral="Custom notes",
    notesOfficer="Custom officer notes",macroRules="Macro rules",macroIgnores="Macro ignores",
    formerMembers="Former members",companionSettings="Companion settings",healthSettings="Guild Health settings"}
function R.Label(category)
    local label=categoryLabels[category]
    return label and GP.L[label] or category or ""
end
R.categories = {"formerMembers", "altsMains", "nicknames", "joinDates", "birthdays",
    "notesGeneral", "notesOfficer", "macroRules", "macroIgnores",
    "recruitmentItems", "recruitmentBlacklist", "bans", "labels", "companionSettings", "healthSettings"}
function R.BatchLimit() return GP.SyncNative and 64 or 16 end
R.fields = {
    bans={{"bansTs","bans"}}, recruitmentBlacklist={{"recruitmentBlacklistTs","recruitmentBlacklist"}},
    nicknames={{"nicksTs","nicks"}}, altsMains={{"altsTs","alts","altsCleared"},{"mainsTs","mains","mainsCleared","mainsSource"}},
    macroIgnores={{"macroIgnoresTs","macroIgnores"}},
    macroRules={{"macroRulesTs","macroRules"},{"labelMacroRulesTs","labelMacroRules"}},
    formerMembers={{"formerMembersTs","formerMembers"}}, birthdays={{"birthdaysTs","birthdays"}},
    joinDates={{"joinDatesTs","joinDates"}}, notesGeneral={{"customNotesTs","customNotes"}},
    notesOfficer={{"customOfficerNotesTs","customOfficerNotes"}},
    labels={{"labelDefinitionsTs","labelDefinitions"},{"labelAssignmentsTs","labelAssignments"}},
    recruitmentItems={{"recruitmentSettingsTs","recruitmentSettings", scalar=true}},
    companionSettings={{"companionSettingsTs","companionSettings", scalar=true}},
    healthSettings={{"healthSettingsTs","healthSettings", scalar=true}},
}
R.live = {alt="altsMains",altclear="altsMains",main="altsMains",mainclear="altsMains",
    nick="nicknames",birthday="birthdays",joindate="joinDates",formermember="formerMembers",
    macrorule="macroRules",labelmacrorule="macroRules",macroignore="macroIgnores",ban="bans",
    recruitmentsettings="recruitmentItems",recruitmentblacklist="recruitmentBlacklist",label="labels"}
function R.Category(p)
    if p.op=="customnote" then return p.scope=="officer" and "notesOfficer" or "notesGeneral" end
    return R.live[p.op]
end
function R.LiveRecord(p)
    local category=R.Category(p)
    if not category or type(p.ts)~="number" then return nil end
    local group,key,value,clear,source=1,p.guid
    if p.op=="alt" then value=p.main
    elseif p.op=="altclear" then clear=true
    elseif p.op=="main" then group,value,source=2,true,p.source
    elseif p.op=="mainclear" then group,clear=2,true
    elseif p.op=="nick" then value=p.nick
    elseif p.op=="customnote" then value=p.note
    elseif p.op=="birthday" then value=p.birthday
    elseif p.op=="joindate" then value=p.joinDate
    elseif p.op=="formermember" then value=p.formerMember
    elseif p.op=="macroignore" then value=p.ignore
    elseif p.op=="macrorule" or p.op=="labelmacrorule" then
        group,key,value=p.op=="labelmacrorule" and 2 or 1,p.name,p.rule
    elseif p.op=="ban" or p.op=="recruitmentblacklist" then key,value=p.id,p.record
    elseif p.op=="recruitmentsettings" then key,value="settings",p.settings
    elseif p.op=="label" then
        if p.kind=="definition" then key,value=p.labelId,p.record
        elseif p.kind=="assignment" and type(p.guid)=="string" and type(p.labelId)=="string" then
            group,key,value=2,p.guid.."\30"..p.labelId,p.assigned and true or false
        else return nil end
    end
    if type(key)~="string" then return nil end
    return category,{group,key,p.ts,value,clear,source}
end

function R.Payload(guild,category)
    local function module(name) return GP:GetModule(name) end
    local p={}
    if category=="altsMains" then
        p.alts,p.altsTs,p.mains,p.mainsTs,p.mainsSource,p.altsCleared,p.mainsCleared=module("Alts"):GetAllForSync(guild)
    elseif category=="nicknames" then p.nicks,p.nicksTs=module("Nicknames"):GetAllForSync(guild)
    elseif category=="notesGeneral" or category=="notesOfficer" then
        p.customNotes,p.customNotesTs,p.customOfficerNotes,p.customOfficerNotesTs=module("CustomNotes"):GetAllForSync(guild)
    elseif category=="birthdays" then p.birthdays,p.birthdaysTs=module("Roster"):GetBirthdaysForSync(guild)
    elseif category=="joinDates" then p.joinDates,p.joinDatesTs=module("Roster"):GetJoinDatesForSync(guild)
    elseif category=="formerMembers" then p.formerMembers,p.formerMembersTs=module("Roster"):GetFormerMembersForSync(guild)
    elseif category=="bans" then p.bans,p.bansTs=module("BanList"):GetAllForSync(guild)
    elseif category=="macroIgnores" then p.macroIgnores,p.macroIgnoresTs=module("MacroTool"):GetMacroIgnoresForSync(guild)
    elseif category=="macroRules" then
        p.macroRules,p.macroRulesTs,p.labelMacroRules,p.labelMacroRulesTs=module("MacroTool"):GetSavedRulesForSync()
    elseif category=="recruitmentItems" then p.recruitmentSettings,p.recruitmentSettingsTs=module("Recruitment"):GetGuildSettingsForSync(guild)
    elseif category=="recruitmentBlacklist" then p.recruitmentBlacklist,p.recruitmentBlacklistTs=module("Recruitment"):GetBlacklistForSync(guild)
    elseif category=="healthSettings" then
        local health=GP:GetModule("GuildHealth",true)
        if health then p.healthSettings,p.healthSettingsTs=health:GetSettingsForSync(guild) end
    elseif category=="companionSettings" then
        local c=GP:GetModule("Companion",true)
        if c then p.companionSettings,p.companionSettingsTs=c:GetSettingsForSync(guild) end
    elseif category=="labels" then
        p.labelDefinitions,p.labelDefinitionsTs,p.labelAssignments,p.labelAssignmentsTs=module("Labels"):GetAllForSync(guild)
    end
    return p
end

-- A record includes its timestamp and explicit clear fields. Missing values
-- are meaningful only when accompanied by that timestamp.
function R.Build(guild,category,alive,done)
    local fields=R.fields[category]
    if not fields then done(nil);return end
    local payload=R.Payload(guild,category)
    local result={records={},keys={},byID={},count=0,a=0,b=0}
    local group,key=1,nil
    local labelGUID,labelID
    local function step()
        if not alive() then done(nil);return end
        if not GP:GetModule("GuildSync"):CanRetryBulkSync() then C_Timer.After(1,step);return end
        local sync=GP:GetModule("GuildSync")
        local batchSize=sync.IsLowFrameRate and sync:IsLowFrameRate() and 10 or 50
        for _=1,batchSize do
            local f=fields[group]
            if not f then done(result);return end
            local ts
            local nested=category=="labels" and group==2
            if nested then
                if not labelGUID then labelGUID=next(payload.labelAssignmentsTs or {}) end
                if labelGUID then
                    labelID,ts=next(payload.labelAssignmentsTs[labelGUID],labelID)
                    if not labelID then labelGUID=next(payload.labelAssignmentsTs,labelGUID) end
                end
                key=labelID and (labelGUID.."\30"..labelID) or nil
            elseif f.scalar then key,ts="settings",payload[f[1]]
            else key,ts=next(payload[f[1]] or {},key) end
            if key and type(ts)=="number" then
                local r={group,key,ts}
                for n=2,#f do
                    local v=payload[f[n]]
                    if nested then v=v and v[labelGUID] and v[labelGUID][labelID]
                    elseif not f.scalar then v=v and v[key] end
                    r[n+2]=v
                end
                -- Freeze nested values before yielding; getters can return live tables.
                local sync=GP:GetModule("GuildSync")
                local ok,copy=sync:Deserialize(sync:Serialize(r))
                if not ok then done(nil);return end
                r=copy
                local k=GP.SyncIBLT.Key(r)
                local id=GP.SyncIBLT.ID(k)
                if result.byID[id] then done(nil);return end
                result.count=result.count+1
                result.records[#result.records+1]=r
                result.keys[#result.keys+1]=k
                result.byID[id]=r
                result.a=(result.a+k[1])%2147483647
                result.b=(result.b+k[2])%2147483647
            end
            if (not key and not (nested and labelGUID)) or f.scalar then group,key=group+1,nil end
        end
        C_Timer.After(0,step)
    end
    step=GP:MonitorWrap("sync.reconcileBuild",step)
    C_Timer.After(0,step)
end

function R.Assemble(category,records)
    local fields=R.fields[category]
    if not fields or type(records)~="table" or #records>R.BatchLimit() then return nil end
    local p={}
    for _,r in ipairs(records) do
        if type(r)~="table" then return nil end
        local f=fields[r[1]]
        if not f or type(r[2])~="string" or #r[2]>512 or type(r[3])~="number"
            or r[3]~=r[3] or r[3]<0 or r[3]==math.huge then return nil end
        for n=1,#f do
            if f.scalar then p[f[n]]=r[n+2]
            else p[f[n]]=p[f[n]] or {};p[f[n]][r[2]]=r[n+2] end
        end
    end
    return p
end
