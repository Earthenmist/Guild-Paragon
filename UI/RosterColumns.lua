local _, GP = ...
local Columns = {}
GP.UI.RosterColumns = Columns
Columns.options = {
    {key="nickname", labelKey="Nickname"},
    {key="tag", labelKey="Alt / Main"},
    {key="note", labelKey="Note"},
    {key="officerNote", labelKey="Officer Note", officerOnly=true},
    {key="customNote", labelKey="Custom Note"},
    {key="customOfficerNote", labelKey="Custom Officer Note", officerOnly=true},
    {key="zone", labelKey="Current Location"},
    {key="mythicScore", labelKey="M+ Score", numeric=true},
    {key="achievementPoints", labelKey="Achievement Points", numeric=true},
}
function Columns:IsAvailable(key)
    return self:Definition(key) ~= nil and not (GP:IsForeverClient()
        and (key == "mythicScore" or key == "achievementPoints"))
end
function Columns:Options()
    if not GP:IsForeverClient() then return self.options end
    local out = {}
    for _, option in ipairs(self.options) do
        if self:IsAvailable(option.key) then out[#out+1] = option end
    end
    return out
end
function Columns:Definition(key)
    for _, option in ipairs(self.options) do
        if option.key == key then return option end
    end
end
function Columns:Settings()
    GP.db.profile.roster = GP.db.profile.roster or {}
    local roster = GP.db.profile.roster
    roster.display = roster.display or {}
    local s = roster.display
    if type(s.columns) ~= "table" then
        s.columns = {"nickname", "tag", s.noteColumn1 or "note", s.noteColumn2 or "officerNote"}
    end
    local defaults = {"nickname", "tag", "note", "officerNote"}
    local used, replace = {}, {}
    for i=1,4 do
        local key = s.columns[i]
        if not self:Definition(key) or used[key] then
            replace[#replace+1] = i
        else
            used[key] = true
        end
    end
    for _, i in ipairs(replace) do
        local key = defaults[i]
        if used[key] then
            for _, option in ipairs(self.options) do
                if not used[option.key] then key = option.key; break end
            end
        end
        s.columns[i], used[key] = key, true
    end
    return s
end
function Columns:SelectedSources()
    local saved = self:Settings().columns
    local selected, used = {}, {}
    for i=1,4 do
        if self:IsAvailable(saved[i]) then
            selected[i], used[saved[i]] = saved[i], true
        end
    end
    -- Reserve available saved choices before allocating distinct client fallbacks.
    for i=1,4 do
        if not selected[i] then
            for _, option in ipairs(self:Options()) do
                if not used[option.key] then
                    selected[i], used[option.key] = option.key, true
                    break
                end
            end
        end
    end
    return selected
end
function Columns:CanSelect(index, key)
    if not self:IsAvailable(key) then return false end
    local selected = self:SelectedSources()
    for other=1,4 do
        if other ~= index and selected[other] == key then return false end
    end
    return true
end
function Columns:Source(index, canSeeOfficerNotes)
    local key = self:SelectedSources()[index]
    if not canSeeOfficerNotes then
        if key == "officerNote" then return "note" end
        if key == "customOfficerNote" then return "customNote" end
    end
    return key
end
function Columns:Label(key)
    local def = self:Definition(key)
    return GP.L[def and def.labelKey or "Note"]
end
function Columns:Value(player, guildKey, key, tagText)
    if not self:IsAvailable(key) then return nil end
    local value
    if key == "nickname" then
        value = GP:GetModule("Nicknames"):GetSharedNickname(guildKey, player.guid)
    elseif key == "tag" then
        value = tagText or ""
    elseif key == "customNote" then
        value = GP:GetModule("CustomNotes"):Get(guildKey, player.guid)
    elseif key == "officerNote" or key == "customOfficerNote" then
        local notes = GP:GetModule("CustomNotes")
        if not notes:CanAccessOfficerNotes() then return "" end
        if key == "officerNote" then value = player.officerNote
        else value = notes:GetOfficer(guildKey, player.guid) end
    elseif key == "mythicScore" then
        if GP:IsForeverClient() then return nil end
        value = GP:GetModule("GuildHealth"):GetCurrentMythicScore(player)
    elseif key == "zone" then
        if GP:SafeBool(player.online, false) then value = player.zone end
    else
        value = player[key]
    end
    if self:Definition(key).numeric then
        value = GP:SafeNumber(value, nil)
        if value and value >= 0 and value < math.huge then return value end
        return nil
    end
    return GP:SafeOptionalString(value) or ""
end
