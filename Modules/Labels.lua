-- Officer-managed labels for recruiting and roster organization.
-- Stores a label catalog plus per-player assignments, both timestamped for sync.
local _, GP = ...

local Labels = GP:NewModule("Labels")

local LABEL_NAME_MAX_CHARS = 40
local LABEL_DESCRIPTION_MAX_CHARS = 150

-- Plain literal to keep Modules independent from UI/Theme load order.
local DEFAULT_COLOR = { 0.243, 0.851, 0.753 }

local function normalizeLabelName(name)
    name = tostring(name or "")
    name = name:gsub("[\r\n\t]+", " ")
    name = name:gsub("%s+", " ")
    return strtrim(name)
end

local function normalizeDescription(description)
    description = tostring(description or "")
    description = description:gsub("[\r\n\t]+", " ")
    description = description:gsub("%s+", " ")
    return strtrim(description)
end

-- Stable ID from the creation name; renames do not migrate assignments.
local function labelSlug(name)
    local normalized = normalizeLabelName(name):lower():gsub("%s+", "-"):gsub("[^%w%-_]", "")
    if normalized == "" then return nil end
    return "label:" .. normalized
end

local function isValidColor(color)
    if type(color) ~= "table" then return false end
    for i = 1, 3 do
        if type(color[i]) ~= "number" or color[i] < 0 or color[i] > 1 then return false end
    end
    return true
end

local function copyColor(color)
    if not isValidColor(color) then return { DEFAULT_COLOR[1], DEFAULT_COLOR[2], DEFAULT_COLOR[3] } end
    return { color[1], color[2], color[3] }
end

local function getGuildData(guildKey)
    local data = guildKey and GP.db.global.guilds[guildKey]
    if not data then return nil end

    data.labelDefinitions = data.labelDefinitions or {}
    data.labelDefinitionsUpdated = data.labelDefinitionsUpdated or {}
    data.labelAssignments = data.labelAssignments or {}
    data.labelAssignmentsUpdated = data.labelAssignmentsUpdated or {}

    return data
end

local function findPlayer(data, guid)
    return data and (data.roster[guid] or data.formerMembers[guid])
end

-- Keep display names unique across active and archived labels.
local function nameInUse(data, name, excludeLabelId)
    local normalized = normalizeLabelName(name):lower()
    for labelId, def in pairs(data.labelDefinitions) do
        if labelId ~= excludeLabelId and normalizeLabelName(def.name):lower() == normalized then
            return true
        end
    end
    return false
end

-- Prefer the base slug; suffix only to avoid overwriting another label.
local function allocateLabelId(data, name)
    local baseSlug = labelSlug(name)
    if not baseSlug then return nil end
    if not data.labelDefinitions[baseSlug] then return baseSlug end

    for suffix = 2, 9999 do
        local candidate = baseSlug .. "-" .. suffix
        if not data.labelDefinitions[candidate] then return candidate end
    end
    return nil
end

-- Label definitions (the catalog)

function Labels:CreateLabel(guildKey, name, color, description)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end

    name = normalizeLabelName(name)
    if name == "" then return false, L["Label name is required."] end
    if #name > LABEL_NAME_MAX_CHARS then
        return false, string.format(L["Label names must be %d characters or fewer."], LABEL_NAME_MAX_CHARS)
    end

    description = normalizeDescription(description)
    if #description > LABEL_DESCRIPTION_MAX_CHARS then
        return false, string.format(L["Label descriptions must be %d characters or fewer."], LABEL_DESCRIPTION_MAX_CHARS)
    end

    if nameInUse(data, name, nil) then
        return false, L["A label with that name already exists."]
    end

    local labelId = allocateLabelId(data, name)
    if not labelId then return false, L["Label name is required."] end

    local ts = time()
    data.labelDefinitions[labelId] = {
        name = name,
        color = copyColor(color),
        description = description ~= "" and description or nil,
        archived = false,
    }
    data.labelDefinitionsUpdated[labelId] = ts

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "definition", labelId, data.labelDefinitions[labelId], ts)
    return true, labelId
end

function Labels:UpdateLabelDefinition(guildKey, labelId, name, color)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    local def = data.labelDefinitions[labelId]
    if not def then return false, L["Label not found."] end

    name = normalizeLabelName(name)
    if name == "" then return false, L["Label name is required."] end
    if #name > LABEL_NAME_MAX_CHARS then
        return false, string.format(L["Label names must be %d characters or fewer."], LABEL_NAME_MAX_CHARS)
    end
    if nameInUse(data, name, labelId) then
        return false, L["A label with that name already exists."]
    end
    if not isValidColor(color) then return false, L["Invalid label color."] end

    def.name = name
    def.color = copyColor(color)
    local ts = time()
    data.labelDefinitionsUpdated[labelId] = ts

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "definition", labelId, def, ts)
    return true
end

function Labels:RenameLabel(guildKey, labelId, newName)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    local def = data.labelDefinitions[labelId]
    if not def then return false, L["Label not found."] end

    newName = normalizeLabelName(newName)
    if newName == "" then return false, L["Label name is required."] end
    if #newName > LABEL_NAME_MAX_CHARS then
        return false, string.format(L["Label names must be %d characters or fewer."], LABEL_NAME_MAX_CHARS)
    end
    if nameInUse(data, newName, labelId) then
        return false, L["A label with that name already exists."]
    end

    def.name = newName
    local ts = time()
    data.labelDefinitionsUpdated[labelId] = ts

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "definition", labelId, def, ts)
    return true
end

function Labels:SetLabelColor(guildKey, labelId, color)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end
    if not isValidColor(color) then return false, L["Invalid label color."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    local def = data.labelDefinitions[labelId]
    if not def then return false, L["Label not found."] end

    def.color = copyColor(color)
    local ts = time()
    data.labelDefinitionsUpdated[labelId] = ts

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "definition", labelId, def, ts)
    return true
end

local function setArchived(guildKey, labelId, archived)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    local def = data.labelDefinitions[labelId]
    if not def then return false, L["Label not found."] end
    if def.archived == archived then return true end

    def.archived = archived
    local ts = time()
    data.labelDefinitionsUpdated[labelId] = ts

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "definition", labelId, def, ts)
    return true
end

function Labels:ArchiveLabel(guildKey, labelId)
    return setArchived(guildKey, labelId, true)
end

function Labels:UnarchiveLabel(guildKey, labelId)
    return setArchived(guildKey, labelId, false)
end

-- A handful of starter labels so the feature demonstrates itself instead
-- of looking inert on a guild's first visit to the Settings "Labels" page.
local DEFAULT_LABEL_SEEDS = {
    { name = "Trial", color = { 0.541, 0.561, 0.612 } },              -- Theme.color.textSecondary
    { name = "Casual Raider", color = { 0.310, 0.659, 1.000 } },      -- Theme.color.info
    { name = "Serious Raider", color = { 1.000, 0.706, 0.329 } },     -- Theme.color.warning
}

function Labels:SeedDefaultsIfEmpty(guildKey)
    if not GP:IsOfficer() then return false end
    local data = getGuildData(guildKey)
    if not data or next(data.labelDefinitions) ~= nil then return false end

    for _, seed in ipairs(DEFAULT_LABEL_SEEDS) do
        self:CreateLabel(guildKey, seed.name, seed.color)
    end
    return true
end

-- Per-player assignment

function Labels:AssignLabel(guildKey, guid, labelId)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end

    local def = data.labelDefinitions[labelId]
    if not def then return false, L["Label not found."] end
    if def.archived then return false, L["Cannot assign an archived label."] end
    local player = findPlayer(data, guid)
    if not player then return false, L["Player not found."] end

    data.labelAssignments[guid] = data.labelAssignments[guid] or {}
    data.labelAssignmentsUpdated[guid] = data.labelAssignmentsUpdated[guid] or {}

    local ts = time()
    data.labelAssignments[guid][labelId] = true
    data.labelAssignmentsUpdated[guid][labelId] = ts

    -- Officer-sensitive (see EventLog.lua's SENSITIVE_DISPLAY_TYPES) —
    -- matches CustomNotes:SetOfficer's existing convention of logging
    -- on every apply, local or sync-received alike (Labels:SetAssignmentFromSync
    -- below does the same), not just locally-initiated changes.
    GP:GetModule("EventLog"):Add(guildKey, "labeladded", guid, player.name, { labelId = labelId, labelName = def.name })
    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "assignment", guid, labelId, true, ts)
    return true
end

function Labels:RemoveLabel(guildKey, guid, labelId)
    local L = GP.L
    if not GP:IsOfficer() then return false, L["Officer Labels require officer access."] end
    -- Unlike every other write in this file, RemoveLabel never looks up
    -- data.labelDefinitions[labelId] (by design — removal must still work
    if not labelId then return false, L["Label not found."] end

    local data = getGuildData(guildKey)
    if not data then return false, L["No roster data yet."] end
    local player = findPlayer(data, guid)
    if not player then return false, L["Player not found."] end

    data.labelAssignments[guid] = data.labelAssignments[guid] or {}
    data.labelAssignmentsUpdated[guid] = data.labelAssignmentsUpdated[guid] or {}

    local ts = time()
    data.labelAssignments[guid][labelId] = false
    data.labelAssignmentsUpdated[guid][labelId] = ts

    -- def may be missing in the (currently unreachable, since definitions
    -- are archived not deleted) edge case this function's own header
    -- comment already guards for — fall back to the raw labelId so the
    -- Event Log entry still has *something* readable rather than erroring.
    local def = data.labelDefinitions[labelId]
    GP:GetModule("EventLog"):Add(guildKey, "labelremoved", guid, player.name, { labelId = labelId, labelName = def and def.name or labelId })
    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "assignment", guid, labelId, false, ts)
    return true
end

-- Read access

function Labels:CanUse()
    return GP:IsOfficer()
end

-- Matches Modules/Recruitment.lua:GetCurrentGuildKey's exact convenience-
-- wrapper convention, so UI/Settings.lua's Labels page can call this the
-- same way it already calls into Recruitment for the same purpose.
function Labels:GetCurrentGuildKey()
    local Roster = GP:GetModule("Roster")
    return Roster.currentGuildKey or Roster:GetGuildKey()
end

function Labels:GetAllLabelDefinitions(guildKey, includeArchived, search)
    local out = {}
    if not GP:IsOfficer() then return out end

    local data = getGuildData(guildKey)
    if not data then return out end

    search = search and normalizeLabelName(search):lower() or nil
    if search == "" then search = nil end

    for labelId, def in pairs(data.labelDefinitions) do
        if (includeArchived or not def.archived)
            and (not search or normalizeLabelName(def.name):lower():find(search, 1, true)) then
            table.insert(out, {
                labelId = labelId,
                name = def.name,
                color = copyColor(def.color),
                description = def.description,
                archived = def.archived and true or false,
            })
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function Labels:GetLabelsForPlayer(guildKey, guid)
    local out = {}
    if not GP:IsOfficer() then return out end

    local data = getGuildData(guildKey)
    local assigned = data and data.labelAssignments[guid]
    if not data or not assigned then return out end

    for labelId, isAssigned in pairs(assigned) do
        if isAssigned then
            local def = data.labelDefinitions[labelId]
            if def then
                table.insert(out, {
                    labelId = labelId,
                    name = def.name,
                    color = copyColor(def.color),
                    archived = def.archived and true or false,
                })
            end
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function Labels:GetLabelNamesForPlayer(guildKey, guid)
    if not GP:IsOfficer() then return "" end
    local data = getGuildData(guildKey)
    local assigned = data and data.labelAssignments[guid]
    if not data or not assigned then return "" end

    local names = {}
    for labelId, isAssigned in pairs(assigned) do
        if isAssigned then
            local def = data.labelDefinitions[labelId]
            if def then table.insert(names, def.name) end
        end
    end
    return table.concat(names, " ")
end

function Labels:GetPlayersForLabel(guildKey, labelId)
    local out = {}
    if not GP:IsOfficer() then return out end

    local data = getGuildData(guildKey)
    if not data then return out end

    for guid, assigned in pairs(data.labelAssignments) do
        if assigned[labelId] then
            table.insert(out, guid)
        end
    end
    return out
end

function Labels:GetDefinitionUpdatedAt(guildKey, labelId)
    local data = getGuildData(guildKey)
    return data and data.labelDefinitionsUpdated[labelId]
end

function Labels:GetAssignmentUpdatedAt(guildKey, guid, labelId)
    local data = getGuildData(guildKey)
    local updated = data and data.labelAssignmentsUpdated[guid]
    return updated and updated[labelId]
end

function Labels:GetAllForSync(guildKey)
    local data = getGuildData(guildKey)
    if not data then return {}, {}, {}, {} end
    if not GP:IsOfficer() then return {}, {}, {}, {} end
    return data.labelDefinitions, data.labelDefinitionsUpdated, data.labelAssignments, data.labelAssignmentsUpdated
end

-- Sync apply — called from Modules/GuildSync.lua only

function Labels:SetDefinitionFromSync(guildKey, labelId, record, ts)
    if not GP:IsOfficer() then return false end
    local data = getGuildData(guildKey)
    if not data or not labelId or type(ts) ~= "number" then return false end

    if type(record) == "table" then
        local description = normalizeDescription(record.description)
        data.labelDefinitions[labelId] = {
            name = normalizeLabelName(record.name),
            color = copyColor(record.color),
            description = description ~= "" and description or nil,
            archived = record.archived and true or false,
        }
    else
        data.labelDefinitions[labelId] = nil
    end
    data.labelDefinitionsUpdated[labelId] = ts

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "definition", labelId, data.labelDefinitions[labelId], ts)
    return true
end

function Labels:SetAssignmentFromSync(guildKey, guid, labelId, isAssigned, ts)
    if not GP:IsOfficer() then return false end
    local data = getGuildData(guildKey)
    if not data or not guid or not labelId or type(ts) ~= "number" then return false end

    data.labelAssignments[guid] = data.labelAssignments[guid] or {}
    data.labelAssignmentsUpdated[guid] = data.labelAssignmentsUpdated[guid] or {}

    isAssigned = isAssigned and true or false
    data.labelAssignments[guid][labelId] = isAssigned
    data.labelAssignmentsUpdated[guid][labelId] = ts

    -- Log every applied label change when the player exists locally.
    local player = findPlayer(data, guid)
    if player then
        local def = data.labelDefinitions[labelId]
        GP:GetModule("EventLog"):Add(guildKey, isAssigned and "labeladded" or "labelremoved", guid, player.name,
            { labelId = labelId, labelName = def and def.name or labelId })
    end

    GP:SendMessage("GuildParagon_LabelsChanged", guildKey, "assignment", guid, labelId, isAssigned, ts)
    return true
end
