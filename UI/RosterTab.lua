-- Guild Paragon — Roster tab
--
-- Primary member screen: roster search, notes, labels, alts, and history.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.RosterTab = GP.UI.RosterTab or {}
local RosterTab = GP.UI.RosterTab

-- Own AceEvent identity so this tab's message handlers do not overwrite
-- handlers registered by other UI tables.
LibStub("AceEvent-3.0"):Embed(RosterTab)

local COL = {
    leftPad    = 8,
    dotWidth   = 6,
    gap        = 8,
    nameWidth  = 152,
    rankWidth  = 90,
    levelWidth = 34,
    lastWidth  = 82,
    nickWidth  = 96,
    tagWidth   = 122,
}

local NAME_MAX_CHARS = 21
local NICK_MAX_CHARS = 16
local TAG_MAX_CHARS = 26
-- Public note column width, calibrated to common spec/note strings.
local NOTE_MAX_CHARS = 40
local NOTE_COL_WIDTH = 180
-- Blizzard's native Officer Note, distinct from Guild Paragon's Custom
-- Officer Note in the detail panel.
local OFFICER_NOTE_MAX_CHARS = 48
local OFFICER_NOTE_COL_WIDTH = 150
local ROW_HEIGHT = 28
local DETAIL_HEIGHT = 292
-- Roster audit opens as a fixed-size flyout.
local AUDIT_PANEL_WIDTH = 230
local AUDIT_FLYOUT_HEIGHT = 220
-- Fixed width prevents table jitter as the active-filter count changes.
local AUDIT_TOGGLE_WIDTH = 160
local MAX_SUGGESTIONS = 6
local ALT_DETAIL_ROW_HEIGHT = 18
local SUGGESTION_ROW_HEIGHT = 22
-- Fixed flyout sizes keep label/alt management stable while rows change.
local ALTS_FLYOUT_WIDTH = 520
local ALTS_FLYOUT_HEIGHT = 260
local LABELS_FLYOUT_WIDTH = 260
local LABELS_FLYOUT_HEIGHT = 260
-- Match the main roster row height used by label management rows.
local LABELS_ROW_HEIGHT = 28

local frame, list, searchBox, onlineOnlyButton, untaggedOnlyButton, auditPanel, summaryText
local refreshDirty = false
local detailHeading, detailLastOnlineText, statusText, historyHeading, historyBody
local nickLabel, nickBox, nickButton
local customNoteLabel, customNoteBox, customNoteButton
local officerNoteLabel, officerNoteBox, officerNoteButton, officerNoteLockedText
local birthdayLabel, birthdayDayBox, birthdayMonthBox, birthdaySaveButton, birthdayClearButton
local auditDetailHeading, auditDetailBody
-- Grouped rather than one bare local per widget to avoid Lua's upvalue ceiling:
-- this costs each of them exactly one upvalue (JD) no matter how many
-- fields get added here, instead of one per name.
local JD = {}
local altOfText, altOfClearButton, altPromoteButton
local altsOfMineText, altDetailListArea, altDetailList
local setMainLabel, setMainBox, setMainButton
local mainToggleButton
local suggestionPanel, suggestionRows = nil, {}
local headerButtons = {}
local auditChecks = {}
-- Same JD-style grouping as above, for the same reason: this file sits near
-- Lua's 60-upvalue ceiling. auditPanel (already declared above) is reused as
-- the floating audit flyout itself; RN only needs to hold the new pieces.
local RN = {}
-- Officer Labels: same
-- JD/RN-style grouping, one more time, for the Alts-area redesign (View
-- Alts flyout replacing the old always-inline altDetailListArea grid) and
-- the new Labels area (Labels (N) text, Manage Labels button, its own
-- flyout with per-label Add/Remove rows) built alongside it.
local AL = {}
local selectedGUID, lastDetailGUID
local scrollToSelectedOnRefresh = false
local sortKey, sortAsc = "rankIndex", true
local showOnlineOnly = false
local showUntaggedOnly = false

local hideSuggestions, updateSuggestions

local function getGuildData()
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey and GP.db.global.guilds[guildKey], guildKey
end

local function classColorOf(classFile)
    local c = classFile and C_ClassColor.GetClassColor(classFile)
    if c then return c.r, c.g, c.b end
    return unpack(Theme.color.textPrimary)
end

local function truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then
        return text:sub(1, maxChars) .. "..."
    end
    return text
end

local function activeAltGUIDsFor(guildData, altGUIDs)
    local active = {}
    if not guildData or not guildData.roster then return active end

    for _, guid in ipairs(altGUIDs or {}) do
        if guildData.roster[guid] then
            table.insert(active, guid)
        end
    end

    return active
end

local function singleLine(text)
    text = text or ""
    text = text:gsub("[\r\n\t]+", " ")
    text = text:gsub("%s+", " ")
    return strtrim(text)
end

local function setEditBoxReadOnly(box, readOnly)
    if not box then return end
    box:ClearFocus()
    box:EnableMouse(not readOnly)
    if readOnly then
        box:SetTextColor(unpack(Theme.color.textSecondary))
    else
        box:SetTextColor(unpack(Theme.color.textPrimary))
    end
end

local function isTagged(guildKey, guid)
    local Alts = GP:GetModule("Alts")
    return Alts:GetMain(guildKey, guid) ~= nil or Alts:IsMain(guildKey, guid)
end

local AUDIT_FILTERS = {
    { key = "issues", labelKey = "Issues" },
    { key = "tag", labelKey = "Tags" },
    { key = "join", labelKey = "Join" },
    { key = "promo", labelKey = "Promo" },
    { key = "birthday", labelKey = "Birthday" },
    { key = "staleNote", labelKey = "Old Tags" },
}

local function getAuditFilterState()
    GP.db.profile.roster = GP.db.profile.roster or {}
    GP.db.profile.roster.auditFilters = GP.db.profile.roster.auditFilters or {}
    return GP.db.profile.roster.auditFilters
end

local function rosterDisplaySettings()
    GP.db.profile.roster = GP.db.profile.roster or {}
    GP.db.profile.roster.display = GP.db.profile.roster.display or {}
    local s = GP.db.profile.roster.display
    if s.classColorNames == nil then s.classColorNames = true end
    if s.showLevel == nil then s.showLevel = true end
    return s
end

local function isAuditFilterEnabled(key)
    return getAuditFilterState()[key] == true
end

local function hasActiveAuditFilters()
    local filters = getAuditFilterState()
    for _, def in ipairs(AUDIT_FILTERS) do
        if filters[def.key] == true then return true end
    end
    return false
end

local function formatDate(ts)
    return type(ts) == "number" and ts > 0 and date("%Y-%m-%d", ts) or nil
end

local function formatLastOnlineTime(player)
    if not player then return "" end
    if player.online then return GP.L["Online"] end
    local lastOnlineTime = player.lastOnlineTime
    if type(lastOnlineTime) ~= "table" then return GP.L["Unknown"] end

    local years = tonumber(lastOnlineTime[1]) or 0
    local months = tonumber(lastOnlineTime[2]) or 0
    local days = tonumber(lastOnlineTime[3]) or 0
    local hours = tonumber(lastOnlineTime[4]) or 0
    local parts = {}

    if months == 12 then
        years = years + 1
        months = 0
    end
    if years > 0 then table.insert(parts, years .. (years == 1 and " yr" or " yrs")) end
    if months > 0 then table.insert(parts, months .. (months == 1 and " mo" or " mos")) end
    if days > 0 then table.insert(parts, days .. (days == 1 and " day" or " days")) end
    if hours > 0 and years < 1 and months < 1 then table.insert(parts, hours .. (hours == 1 and " hr" or " hrs")) end

    if #parts == 0 then return GP.L["< 1 hr"] end
    return table.concat(parts, ", ")
end

local function customJoinDateText(note)
    note = note or ""
    return note:match("[Rr]ejoined:%s*([%d%-]+)") or note:match("[Jj]oined:%s*([%d%-]+)")
end

local function canonicalJoinDateText(text)
    text = strtrim(tostring(text or ""))
    local year, month, day = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if year then
        year, month, day = tonumber(year), tonumber(month), tonumber(day)
    else
        day, month, year = text:match("^(%d%d?)%-(%d%d?)%-(%d%d)$")
        if not year then return nil end
        day, month, year = tonumber(day), tonumber(month), 2000 + tonumber(year)
    end
    if not year or not month or not day or month < 1 or month > 12 or day < 1 or day > 31 then return nil end

    local ts = time({ year = year, month = month, day = day, hour = 12 })
    local canonical = string.format("%04d-%02d-%02d", year, month, day)
    if date("%Y-%m-%d", ts) ~= canonical then return nil end
    return canonical
end

local function joinDateSourceText(player)
    local L = GP.L
    if not player or type(player.firstSeen) ~= "number" or player.firstSeen <= 0 or player.joinDateUnknown then
        return L["Unknown"]
    end
    local source = player.joinDateSource
    if source == "guildevent" then return L["Source: guild roster log"] end
    if source == "manual" then return L["Source: manual edit"] end
    if source == "customnote" then return L["Source: imported from note"] end
    if source == "sync" or source == "firstseen" then return L["Source: synced"] end
    return L["Source: unconfirmed"]
end

local function hasBirthday(player)
    local day, month = GP:GetModule("Roster"):GetBirthday(player)
    return day ~= nil and month ~= nil
end

local function latestRankDate(player)
    local hist = player and player.rankHistory
    if type(hist) ~= "table" or #hist == 0 then return nil end
    for i = #hist, 1, -1 do
        local entry = hist[i]
        if type(entry) == "table" and type(entry.ts) == "number" and entry.ts > 0 then
            return entry.ts
        end
    end
    return nil
end

-- firstSeen is the sole join-date source now. A
-- note's Joined:/Rejoined: tag, if one is still there from before that
-- change, is no longer a competing data source to resolve a "conflict"
-- against. It only matters as leftover text worth tidying up, hence
-- "staleNote" below rather than a core correctness issue.
local function auditIssuesFor(player, guildKey)
    local issues = {}
    if not player then return issues end

    local hasJoinDate = type(player.firstSeen) == "number" and player.firstSeen > 0 and not player.joinDateUnknown

    if not isTagged(guildKey, player.guid) then
        issues.tag = true
        table.insert(issues, GP.L["Needs Tag"])
    end
    if not hasJoinDate then
        issues.join = true
        table.insert(issues, GP.L["Missing Join"])
    end
    if player.promoteDateUnknown or not latestRankDate(player) then
        issues.promo = true
        table.insert(issues, GP.L["Missing Promo"])
    end
    if not hasBirthday(player) then
        issues.birthday = true
        table.insert(issues, GP.L["Missing Birthday"])
    end
    if hasJoinDate then
        local customNote = GP:GetModule("CustomNotes"):Get(guildKey, player.guid)
        local joinText = customJoinDateText(customNote)
        local canonicalJoinText = canonicalJoinDateText(joinText)
        if joinText and canonicalJoinText and canonicalJoinText ~= formatDate(player.firstSeen) then
            issues.staleNote = true
            table.insert(issues, GP.L["Old Tag In Note"])
        end
    end

    return issues
end

local function auditTextFor(player, guildKey)
    local issues = auditIssuesFor(player, guildKey)
    if #issues == 0 then return GP.L["Complete"] end
    return table.concat(issues, ", ")
end

local function hasCoreAuditIssue(issues)
    return issues.tag or issues.join or issues.promo
end

local function auditDetailTextFor(player, guildKey)
    local L = GP.L
    local issues = auditIssuesFor(player, guildKey)
    if #issues == 0 then return L["No audit issues found."] end

    local lines = {}
    if issues.join then
        table.insert(lines, L["Missing join date."])
    end
    if issues.promo then
        table.insert(lines, L["Missing promoted-date history."])
    end
    if issues.birthday then
        table.insert(lines, L["Missing birthday."])
    end
    if issues.tag then
        table.insert(lines, L["Missing main/alt tag."])
    end
    if issues.staleNote then
        local customNote = GP:GetModule("CustomNotes"):Get(guildKey, player.guid)
        local joinText = customJoinDateText(customNote)
        table.insert(lines, string.format(L["Note still has an old join tag (%s) — Guild Paragon's join date is %s. Settings has a guild-master tool to remove these."],
            canonicalJoinDateText(joinText) or joinText or L["Unknown"],
            formatDate(player.firstSeen) or L["Unknown"]))
    end

    return table.concat(lines, "\n")
end

local function matchesActiveAuditFilters(issues)
    if not hasActiveAuditFilters() then return true end
    if isAuditFilterEnabled("issues") and hasCoreAuditIssue(issues) then return true end
    for _, def in ipairs(AUDIT_FILTERS) do
        if def.key ~= "issues" and isAuditFilterEnabled(def.key) and issues[def.key] then
            return true
        end
    end
    return false
end

local function paintFilterButton(button, selected)
    if not button then return end
    button:SetBackdropBorderColor(unpack(selected and Theme.color.accent or Theme.color.accentDim))
    button.text:SetFontObject(selected and Theme.font.heading or Theme.font.body)
end

local function paintFilterButtons()
    paintFilterButton(onlineOnlyButton, showOnlineOnly)
    paintFilterButton(untaggedOnlyButton, showUntaggedOnly)
end

local function setStatus(text, isError)
    if not statusText then return end
    statusText:SetText(text or "")
    statusText:SetTextColor(unpack(isError and Theme.color.danger or Theme.color.textSecondary))
end

local function tagTextFor(player, guildData, guildKey)
    local L = GP.L
    local Alts = GP:GetModule("Alts")
    local mainGUID = guildData and Alts:GetMain(guildKey, player.guid)
    if mainGUID then
        local mainPlayer = guildData.roster[mainGUID] or guildData.formerMembers[mainGUID]
        return string.format(L["Alt of %s"], mainPlayer and mainPlayer.name or "?")
    end

    local altGUIDs = guildData and Alts:GetAlts(guildKey, player.guid) or {}
    local altCount = #activeAltGUIDsFor(guildData, altGUIDs)
    if altCount > 0 then
        return string.format(L["%d alt(s)"], altCount)
    end

    if guildData and (Alts:IsMarkedMain(guildKey, player.guid) or Alts:IsMain(guildKey, player.guid)) then
        return L["Main"]
    end

    return L["Needs tag"]
end

local function displayedTagTextFor(player, guildData, guildKey)
    if hasActiveAuditFilters() then
        return auditTextFor(player, guildKey)
    end
    return tagTextFor(player, guildData, guildKey)
end

local function normalizedSortText(text)
    return strtrim(tostring(text or "")):lower()
end

local function rosterSortValue(player, guildData, guildKey, canSeeOfficerNotes)
    if sortKey == "nickname" then
        return normalizedSortText(GP:GetModule("Nicknames"):Get(guildKey, player.guid))
    end
    if sortKey == "tag" then
        return normalizedSortText(displayedTagTextFor(player, guildData, guildKey))
    end
    if sortKey == "note" then
        return normalizedSortText(player.note)
    end
    if sortKey == "officerNote" then
        return canSeeOfficerNotes and normalizedSortText(player.officerNote) or ""
    end
    return player[sortKey]
end

-- Row widget

local function createRosterRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    local dot = row:CreateTexture(nil, "ARTWORK")
    dot:SetSize(COL.dotWidth, COL.dotWidth)
    dot:SetPoint("LEFT", COL.leftPad, 0)
    row.dot = dot

    local name = row:CreateFontString(nil, "ARTWORK")
    name:SetFontObject(Theme.font.body)
    name:SetJustifyH("LEFT")
    name:SetPoint("LEFT", dot, "RIGHT", COL.gap, 0)
    name:SetWidth(COL.nameWidth)
    name:SetWordWrap(false)
    row.name = name

    local rank = row:CreateFontString(nil, "ARTWORK")
    rank:SetFontObject(Theme.font.muted)
    rank:SetJustifyH("LEFT")
    rank:SetPoint("LEFT", name, "RIGHT", COL.gap, 0)
    rank:SetWidth(COL.rankWidth)
    rank:SetWordWrap(false)
    row.rank = rank

    local level = row:CreateFontString(nil, "ARTWORK")
    level:SetFontObject(Theme.font.muted)
    level:SetJustifyH("LEFT")
    level:SetPoint("LEFT", rank, "RIGHT", COL.gap, 0)
    level:SetWidth(COL.levelWidth)
    row.level = level

    local nick = row:CreateFontString(nil, "ARTWORK")
    nick:SetFontObject(Theme.font.muted)
    nick:SetJustifyH("LEFT")
    local lastOnline = row:CreateFontString(nil, "ARTWORK")
    lastOnline:SetFontObject(Theme.font.muted)
    lastOnline:SetJustifyH("LEFT")
    lastOnline:SetPoint("LEFT", level, "RIGHT", COL.gap, 0)
    lastOnline:SetWidth(COL.lastWidth)
    lastOnline:SetWordWrap(false)
    row.lastOnline = lastOnline

    nick:SetPoint("LEFT", lastOnline, "RIGHT", COL.gap, 0)
    nick:SetWidth(COL.nickWidth)
    nick:SetWordWrap(false)
    row.nick = nick

    local tag = row:CreateFontString(nil, "ARTWORK")
    tag:SetFontObject(Theme.font.muted)
    tag:SetJustifyH("LEFT")
    tag:SetPoint("LEFT", nick, "RIGHT", COL.gap, 0)
    tag:SetWidth(COL.tagWidth)
    tag:SetWordWrap(false)
    row.tag = tag

    local note = row:CreateFontString(nil, "ARTWORK")
    note:SetFontObject(Theme.font.muted)
    note:SetJustifyH("LEFT")
    note:SetPoint("LEFT", tag, "RIGHT", COL.gap, 0)
    -- Fixed width; Officer Note owns the row's remaining space.
    note:SetWidth(NOTE_COL_WIDTH)
    note:SetWordWrap(false)
    row.note = note

    -- Blizzard's native Officer Note; shown/hidden on each refresh because
    -- permissions can change during login.
    local officerNote = row:CreateFontString(nil, "ARTWORK")
    officerNote:SetFontObject(Theme.font.muted)
    officerNote:SetJustifyH("LEFT")
    officerNote:SetPoint("LEFT", note, "RIGHT", COL.gap, 0)
    officerNote:SetPoint("RIGHT", -8, 0)
    officerNote:SetWordWrap(false)
    row.officerNote = officerNote

    row:SetScript("OnEnter", function(self)
        if not self.selected then self:SetBackdropColor(unpack(Theme.color.panelRaised)) end
    end)
    row:SetScript("OnLeave", function(self)
        if not self.selected then self:SetBackdropColor(0, 0, 0, 0) end
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self.player then return end
        if button == "RightButton" and GP.UI.RosterContextMenu then
            if auditPanel then auditPanel:Hide() end
            if AL.altsFlyoutPanel then AL.altsFlyoutPanel:Hide() end
            if AL.labelsFlyoutPanel then AL.labelsFlyoutPanel:Hide() end
            GP.UI.RosterContextMenu:ShowForPlayer(self, self.player)
            return
        end

        RosterTab:SelectPlayer(self.player)
        if GP.UI.RosterContextMenu then
            GP.UI.RosterContextMenu:Hide()
        end
    end)

    return row
end

local function updateRosterRow(row, player)
    row.player = player
    row.selected = (player.guid == selectedGUID)

    if row.selected then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
    else
        row:SetBackdropColor(0, 0, 0, 0)
    end

    row.dot:SetColorTexture(unpack(player.online and Theme.color.success or Theme.color.textDisabled))

    local guildData, guildKey = getGuildData()
    local nickname = guildKey and GP:GetModule("Nicknames"):Get(guildKey, player.guid) or ""

    local display = rosterDisplaySettings()
    if display.classColorNames then
        row.name:SetTextColor(classColorOf(player.class))
    else
        row.name:SetTextColor(unpack(Theme.color.textPrimary))
    end
    row.name:SetText(truncate(player.name, NAME_MAX_CHARS))
    row.rank:SetText(truncate(player.rankName, 16))
    row.level:SetText(display.showLevel and tostring(player.level) or "")
    row.lastOnline:SetText(truncate(formatLastOnlineTime(player), 12))
    row.lastOnline:SetTextColor(unpack(player.online and Theme.color.success or Theme.color.textSecondary))
    row.nick:SetText(nickname ~= "" and truncate("\"" .. nickname .. "\"", NICK_MAX_CHARS) or "")
    row.tag:SetText(truncate(displayedTagTextFor(player, guildData, guildKey), TAG_MAX_CHARS))
    row.note:SetText(truncate(player.note, NOTE_MAX_CHARS))

    -- Officer Note permission is checked fresh every row update.
    if GP:GetModule("CustomNotes"):CanAccessOfficerNotes() then
        row.officerNote:Show()
        row.officerNote:SetText(truncate(player.officerNote, OFFICER_NOTE_MAX_CHARS))
    else
        row.officerNote:Hide()
    end
end

-- Data: filter + sort

local function buildDisplayList()
    local guildData, guildKey = getGuildData()
    local out = {}
    if not guildData then return out end

    local Nicknames = GP:GetModule("Nicknames")
    local Labels = GP:GetModule("Labels")
    -- Checked once per search, not per player: player.officerNote only enters the
    -- searchable string when the *current* viewer has officer-note
    local canSeeOfficerNotes = GP:GetModule("CustomNotes"):CanAccessOfficerNotes()
    local canSeeLabels = Labels:CanUse()
    local filterText = strtrim(searchBox:GetText() or ""):lower()
    for _, player in pairs(guildData.roster) do
        local nickname = Nicknames:Get(guildKey, player.guid) or ""
        local lastOnlineText = formatLastOnlineTime(player)
        local officerNote = canSeeOfficerNotes and (player.officerNote or "") or ""
        local labelNames = canSeeLabels and Labels:GetLabelNamesForPlayer(guildKey, player.guid) or ""
        local searchable = (player.name .. " " .. (player.rankName or "") .. " " .. (player.note or "") .. " " .. officerNote .. " " .. nickname .. " " .. lastOnlineText .. " " .. labelNames):lower()
        if filterText == "" or searchable:find(filterText, 1, true) then
            if (not showOnlineOnly or player.online)
                and (not showUntaggedOnly or not isTagged(guildKey, player.guid)) then
                local issues = auditIssuesFor(player, guildKey)
                if matchesActiveAuditFilters(issues) then
                    table.insert(out, player)
                end
            end
        end
    end

    table.sort(out, function(a, b)
        local av, bv = rosterSortValue(a, guildData, guildKey, canSeeOfficerNotes), rosterSortValue(b, guildData, guildKey, canSeeOfficerNotes)
        if sortKey == "lastOnline" then
            av = tonumber(av) or 999999
            bv = tonumber(bv) or 999999
        end
        if type(av) == "string" and type(bv) == "string" then
            local aBlank, bBlank = av == "", bv == ""
            if aBlank ~= bBlank then return not aBlank end
        end
        if av == bv then return a.name < b.name end
        if sortAsc then return av < bv else return av > bv end
    end)

    return out
end

-- Detail panel

local function hideMemberControls()
    nickLabel:Hide(); nickBox:Hide(); nickButton:Hide()
    customNoteLabel:Hide(); customNoteBox:Hide(); customNoteButton:Hide()
    officerNoteLabel:Hide(); officerNoteBox:Hide(); officerNoteButton:Hide(); officerNoteLockedText:Hide()
    birthdayLabel:Hide(); birthdayDayBox:Hide(); birthdayMonthBox:Hide(); birthdaySaveButton:Hide(); birthdayClearButton:Hide()
    auditDetailHeading:Hide(); auditDetailBody:Hide()
    JD.label:Hide(); JD.box:Hide(); JD.saveButton:Hide(); JD.sourceText:Hide()
    altOfText:Hide(); altOfClearButton:Hide(); altPromoteButton:Hide()
    altsOfMineText:Hide()
    setMainLabel:Hide(); setMainBox:Hide(); setMainButton:Hide()
    mainToggleButton:Hide()
    -- Officer Labels: altDetailListArea no longer lives inline in
    -- the detail panel (it's inside AL.altsFlyoutPanel now, see
    if AL.viewAltsButton then AL.viewAltsButton:Hide() end
    if AL.altsFlyoutPanel then AL.altsFlyoutPanel:Hide() end
    if AL.labelsCountText then AL.labelsCountText:Hide() end
    if AL.manageLabelsButton then AL.manageLabelsButton:Hide() end
    if AL.labelsFlyoutPanel then AL.labelsFlyoutPanel:Hide() end
    if frame and frame.macroRulesButton then frame.macroRulesButton:Hide() end
end

local function showAltDetailLines(guildData, altGUIDs)
    local rows = {}
    local currentRow
    for i, altGUID in ipairs(altGUIDs or {}) do
        local altPlayer = guildData.roster[altGUID] or guildData.formerMembers[altGUID]
        if altPlayer then
            if not currentRow or #currentRow >= 3 then
                currentRow = {}
                table.insert(rows, currentRow)
            end
            table.insert(currentRow, altPlayer)
        end
    end

    -- Data only — visibility is now flyout-toggle-controlled
    -- (AL.viewAltsButton/AL.altsFlyoutPanel), not tied to having data.
    altDetailList:SetData(rows, true)
end

local function createAltDetailRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.names = {}
    for i = 1, 3 do
        local button = CreateFrame("Button", nil, row)
        button:SetSize(150, ALT_DETAIL_ROW_HEIGHT)
        if i == 1 then
            button:SetPoint("LEFT")
        else
            button:SetPoint("LEFT", row.names[i - 1], "RIGHT", 10, 0)
        end

        local text = button:CreateFontString(nil, "ARTWORK")
        text:SetFontObject(Theme.font.body)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        text:SetAllPoints()
        button.text = text
        button:SetScript("OnClick", function(self)
            if self.player then RosterTab:SelectPlayer(self.player, true) end
        end)
        row.names[i] = button
    end
    return row
end

local function updateAltDetailRow(row, players)
    for i = 1, 3 do
        local button = row.names[i]
        local player = players and players[i]
        if player then
            button.player = player
            button.text:SetText(truncate(player.name, 20))
            button.text:SetTextColor(classColorOf(player.class))
            button:Show()
        else
            button.player = nil
            button.text:SetText("")
            button:Hide()
        end
    end
end

-- Officer Labels: Manage Labels flyout row builder

-- One row per catalog label, unioned with any archived label the selected
-- player still carries (Labels:GetAllLabelDefinitions(guildKey, false)
-- alone would drop those — an officer needs to still be able to remove an
-- archived label from a player who already has it, even though it can't be
-- newly assigned to anyone else). Sorted by name.
local function labelRowsForPlayer(guildKey, guid)
    local Labels = GP:GetModule("Labels")
    local assignedIDs = {}
    local rows = {}

    for _, rec in ipairs(Labels:GetLabelsForPlayer(guildKey, guid)) do
        assignedIDs[rec.labelId] = true
        if rec.archived then
            table.insert(rows, { labelId = rec.labelId, name = rec.name, color = rec.color, archived = true, isAssigned = true })
        end
    end
    for _, def in ipairs(Labels:GetAllLabelDefinitions(guildKey, false)) do
        table.insert(rows, { labelId = def.labelId, name = def.name, color = def.color, archived = false, isAssigned = assignedIDs[def.labelId] or false })
    end

    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

local function createLabelManageRow(parent)
    local row = CreateFrame("Frame", nil, parent)

    row.swatch = row:CreateTexture(nil, "ARTWORK")
    row.swatch:SetSize(12, 12)
    row.swatch:SetPoint("LEFT", 4, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("LEFT", row.swatch, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", -60, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.actionButton = Theme:CreateButton(row, "")
    row.actionButton:SetWidth(54)
    row.actionButton:SetPoint("RIGHT", -4, 0)
    -- Reads `row.rowData` (a closure upvalue), not `self.rowData` — `self`
    -- here is row.actionButton itself, and updateLabelManageRow below only
    -- ever sets `row.rowData`, never `row.actionButton.rowData`. Using
    -- `self.rowData` silently no-opped on every click since it was always nil.
    row.actionButton:SetScript("OnClick", function()
        if not row.rowData then return end
        local _, guildKey = getGuildData()
        local Labels = GP:GetModule("Labels")
        local ok, err
        if row.rowData.isAssigned then
            ok, err = Labels:RemoveLabel(guildKey, selectedGUID, row.rowData.labelId)
        else
            ok, err = Labels:AssignLabel(guildKey, selectedGUID, row.rowData.labelId)
        end
        if not ok then setStatus(err, true) end
        AL.refreshLabelRows()
        RosterTab:Refresh()
    end)

    return row
end

local function updateLabelManageRow(row, rowData)
    row.rowData = rowData
    row.swatch:SetColorTexture(unpack(rowData.color))

    local nameText = truncate(rowData.name or "?", 22)
    if rowData.archived then
        nameText = nameText .. " " .. GP.L["(archived)"]
        row.name:SetTextColor(unpack(Theme.color.textSecondary))
    else
        row.name:SetTextColor(unpack(Theme.color.textPrimary))
    end
    row.name:SetText(nameText)

    row.actionButton.text:SetText(rowData.isAssigned and GP.L["Remove"] or GP.L["Add"])
    row.actionButton:SetShown(not (rowData.archived and not rowData.isAssigned))
end

function RosterTab:SelectPlayer(player, scrollIntoView)
    if GP.UI.MemberTooltip then GP.UI.MemberTooltip:HideMacroRules() end
    selectedGUID = player.guid
    scrollToSelectedOnRefresh = scrollIntoView and true or false
    setStatus("")
    if hideSuggestions then hideSuggestions() end
    self:Refresh()
end

function RosterTab:SelectPlayerByGUID(guid, name)
    local guildData = getGuildData()
    if not guildData then return false end

    local player
    if guid and guid ~= "" then
        player = (guildData.roster or {})[guid] or (guildData.formerMembers or {})[guid]
    end
    if not player and name and name ~= "" then
        local foundGUID, foundPlayer = GP:GetModule("Roster"):FindPlayerByName(guildData, name, true)
        guid, player = foundGUID, foundPlayer
    end
    if not player then return false end

    self:SelectPlayer(player, true)
    return true
end

local function refreshHistory(guildKey)
    local L = GP.L
    local EventLog = GP:GetModule("EventLog")
    local log = EventLog:GetLog(guildKey) or {}
    local lines = {}
    for i = #log, 1, -1 do
        if log[i].guid == selectedGUID and EventLog:CanDisplayEntry(log[i]) and not EventLog:IsRemoved(guildKey, log[i]) then
            table.insert(lines, date("%Y-%m-%d", log[i].ts) .. "  " .. EventLog:Render(log[i]))
            if #lines >= 9 then break end
        end
    end

    historyBody:SetText(#lines > 0 and table.concat(lines, "\n") or L["No recorded history yet."])
end

local function refreshDetail()
    local L = GP.L
    local guildData, guildKey = getGuildData()
    local player = guildData and selectedGUID and (guildData.roster[selectedGUID] or guildData.formerMembers[selectedGUID])
    local isNewSelection = (selectedGUID ~= lastDetailGUID)
    lastDetailGUID = selectedGUID

    if not player then
        -- Own string, not shared with the legacy UI/AltsTab.lua fallback
        -- (which still uses the old "nickname, notes, or alt/main tag"
        detailHeading:SetText(L["Select a member to view their profile."])
        detailHeading:SetTextColor(unpack(Theme.color.textSecondary))
        detailLastOnlineText:SetText("")
        detailLastOnlineText:Hide()
        hideMemberControls()
        historyHeading:SetText("")
        historyBody:SetText("")
        auditDetailHeading:SetText("")
        auditDetailBody:SetText("")
        if hideSuggestions then hideSuggestions() end
        return
    end

    detailHeading:SetText(string.format("%s — %s (%d)", player.name, player.rankName, player.level))
    detailHeading:SetTextColor(classColorOf(player.class))
    detailLastOnlineText:SetText(string.format("%s: %s", L["Last Online"], formatLastOnlineTime(player)))
    detailLastOnlineText:SetTextColor(unpack(player.online and Theme.color.success or Theme.color.textSecondary))
    detailLastOnlineText:Show()
    historyHeading:SetText(L["Recent History"])

    local isOfficer = GP:IsOfficer()
    local canEditProfile = GP:CanEditMemberProfile(selectedGUID)
    local canUseMacroTool = isOfficer and GP:GetModule("MacroTool"):CanUse()

    nickLabel:Show(); nickBox:Show(); nickButton:Show()
    customNoteLabel:Show(); customNoteBox:Show(); customNoteButton:Show()
    birthdayLabel:Show(); birthdayDayBox:Show(); birthdayMonthBox:Show(); birthdaySaveButton:Show(); birthdayClearButton:Show()
    auditDetailHeading:Show(); auditDetailBody:Show()
    JD.label:Show(); JD.box:Show(); JD.sourceText:Show()
    if isNewSelection then
        nickBox:SetText(GP:GetModule("Nicknames"):Get(guildKey, selectedGUID))
        customNoteBox:SetText(singleLine(GP:GetModule("CustomNotes"):Get(guildKey, selectedGUID)))
        local day, month = GP:GetModule("Roster"):GetBirthday(player)
        birthdayDayBox:SetText(day and tostring(day) or "")
        birthdayMonthBox:SetText(month and tostring(month) or "")
        JD.box:SetText(formatDate(player.firstSeen) or "")
    end
    setEditBoxReadOnly(nickBox, not canEditProfile)
    nickButton:SetShown(canEditProfile)
    setEditBoxReadOnly(customNoteBox, not isOfficer)
    customNoteButton:SetShown(isOfficer)
    setEditBoxReadOnly(birthdayDayBox, not canEditProfile)
    setEditBoxReadOnly(birthdayMonthBox, not canEditProfile)
    birthdaySaveButton:SetShown(canEditProfile)
    birthdayClearButton:SetShown(canEditProfile)
    setEditBoxReadOnly(JD.box, not isOfficer)
    JD.saveButton:SetShown(isOfficer)
    JD.sourceText:SetText(joinDateSourceText(player))
    if frame.macroRulesButton then frame.macroRulesButton:SetShown(canUseMacroTool) end

    local CustomNotes = GP:GetModule("CustomNotes")
    if CustomNotes:CanAccessOfficerNotes() then
        officerNoteLabel:Show()
        officerNoteBox:Show(); officerNoteButton:Show(); officerNoteLockedText:Hide()
        setEditBoxReadOnly(officerNoteBox, false)
        if isNewSelection then
            officerNoteBox:SetText(singleLine(CustomNotes:GetOfficer(guildKey, selectedGUID)))
        end
    else
        officerNoteLabel:Hide(); officerNoteBox:Hide(); officerNoteButton:Hide(); officerNoteLockedText:Hide()
        if isNewSelection then officerNoteBox:SetText("") end
    end

    local Alts = GP:GetModule("Alts")
    local mainGUID = Alts:GetMain(guildKey, selectedGUID)
    local allMyAlts = Alts:GetAlts(guildKey, selectedGUID)
    local myAlts = activeAltGUIDsFor(guildData, allMyAlts)
    local markedMain = Alts:IsMarkedMain(guildKey, selectedGUID)
    local knownMain = Alts:IsMain(guildKey, selectedGUID)

    -- Officer Labels: a flyout open for the *previous* selection
    -- makes no sense once the selection changes — same reasoning as
    -- hideSuggestions() calls below, applied to both new flyouts.
    if isNewSelection then
        AL.altsFlyoutPanel:Hide()
        AL.labelsFlyoutPanel:Hide()
    end

    if mainGUID then
        local mainPlayer = guildData.roster[mainGUID] or guildData.formerMembers[mainGUID]
        altOfText:SetText(string.format(L["Alt of: %s"], mainPlayer and mainPlayer.name or "?"))
        altOfText:Show(); altOfClearButton:SetShown(isOfficer); altPromoteButton:SetShown(isOfficer)
        altsOfMineText:Hide()
        AL.viewAltsButton:Hide()
        setMainLabel:Hide(); setMainBox:Hide(); setMainButton:Hide()
        mainToggleButton:Hide()
        if hideSuggestions then hideSuggestions() end
    elseif #myAlts > 0 or markedMain or knownMain then
        if #myAlts > 0 then
            table.sort(myAlts, function(a, b)
                local pa = guildData.roster[a] or guildData.formerMembers[a]
                local pb = guildData.roster[b] or guildData.formerMembers[b]
                return (pa and pa.name or "") < (pb and pb.name or "")
            end)
            altsOfMineText:SetText(string.format(L["Alts (%d):"], #myAlts))
            showAltDetailLines(guildData, myAlts)
            AL.viewAltsButton:Show()
        else
            altsOfMineText:SetText((#allMyAlts > 0) and L["Alts (0): none active"] or L["Alts (0): none tagged yet"])
            AL.viewAltsButton:Hide()
        end
        altsOfMineText:Show()
        altOfText:Hide(); altOfClearButton:Hide(); altPromoteButton:Hide()
        setMainLabel:Hide(); setMainBox:Hide(); setMainButton:Hide()
        if hideSuggestions then hideSuggestions() end

        if isOfficer and #allMyAlts == 0 and markedMain then
            mainToggleButton.text:SetText(L["Unmark as Main"])
            mainToggleButton:SetWidth(mainToggleButton.text:GetStringWidth() + 32)
            mainToggleButton:Show()
        else
            mainToggleButton:Hide()
        end
    else
        setMainLabel:SetShown(isOfficer); setMainBox:SetShown(isOfficer); setMainButton:SetShown(isOfficer)
        if isNewSelection then
            setMainBox:SetText("")
        end
        altOfText:Hide(); altOfClearButton:Hide(); altPromoteButton:Hide()
        altsOfMineText:Hide()
        AL.viewAltsButton:Hide()
        if hideSuggestions then hideSuggestions() end

        if isOfficer then
            mainToggleButton.text:SetText(L["Mark as Main"])
            mainToggleButton:SetWidth(mainToggleButton.text:GetStringWidth() + 32)
            mainToggleButton:Show()
        else
            mainToggleButton:Hide()
        end
    end

    -- Labels are independent of alt/main state — any player can carry
    -- them — so this isn't part of the if/elseif/else branching above.
    -- Fully hidden for non-officers, not just disabled, matching every
    -- other officer-only control in this panel.
    if isOfficer then
        local labelCount = #GP:GetModule("Labels"):GetLabelsForPlayer(guildKey, selectedGUID)
        AL.labelsCountText:SetText(string.format(L["Labels (%d)"], labelCount))
        AL.labelsCountText:Show()
        AL.manageLabelsButton:Show()
    else
        AL.labelsCountText:Hide()
        AL.manageLabelsButton:Hide()
        -- Officer access can change (or resolve
        -- differently) on the same selected player without a fresh
        -- selection happening — the count/button above already hid, but an
        -- already-open flyout was left showing the label catalog and
        -- assignment controls regardless.
        AL.labelsFlyoutPanel:Hide()
    end

    auditDetailHeading:SetText(L["Audit Details"])
    auditDetailBody:SetText(auditDetailTextFor(player, guildKey))
    refreshHistory(guildKey)
end

-- Autocomplete dropdown for "Tag as alt of:"

local function createSuggestionRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(SUGGESTION_ROW_HEIGHT)
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)

    local text = row:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(Theme.font.body)
    text:SetJustifyH("LEFT")
    text:SetPoint("LEFT", 6, 0)
    row.text = text

    row:SetScript("OnEnter", function(self) self:SetBackdropColor(unpack(Theme.color.panelRaised)) end)
    row:SetScript("OnLeave", function(self) self:SetBackdropColor(0, 0, 0, 0) end)
    row:SetScript("OnClick", function(self)
        if self.player then
            setMainBox:SetText(self.player.name)
            setMainBox:SetCursorPosition(#self.player.name)
            setMainBox:HighlightText(0, 0)
        end
        hideSuggestions()
    end)

    return row
end

function RosterTab:BuildSuggestions(detail)
    suggestionPanel = Theme:CreatePanel(detail, "panelRaised", "accent")
    suggestionPanel:SetWidth(170)
    suggestionPanel:SetFrameStrata("DIALOG")
    suggestionPanel:SetPoint("BOTTOMLEFT", setMainBox, "TOPLEFT", 0, 2)
    suggestionPanel:Hide()

    for i = 1, MAX_SUGGESTIONS do
        local row = createSuggestionRow(suggestionPanel)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * SUGGESTION_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * SUGGESTION_ROW_HEIGHT)
        suggestionRows[i] = row
    end

    hideSuggestions = function()
        suggestionPanel:Hide()
    end

    updateSuggestions = function()
        local guildData, guildKey = getGuildData()
        local Roster = GP:GetModule("Roster")
        local query = Roster:NormalizePlayerName(setMainBox:GetText() or "")
        if not guildData or query == "" then
            hideSuggestions()
            return
        end

        local Alts = GP:GetModule("Alts")
        local matches = {}
        for guid, p in pairs(guildData.roster) do
            if guid ~= selectedGUID and Roster:NormalizePlayerName(p.name):find(query, 1, true)
                and not Alts:GetMain(guildKey, guid) then
                table.insert(matches, p)
            end
        end
        table.sort(matches, function(a, b) return a.name < b.name end)

        if #matches == 0 then
            hideSuggestions()
            return
        end

        for i, row in ipairs(suggestionRows) do
            local p = matches[i]
            if p then
                row.player = p
                row.text:SetText(p.name)
                row.text:SetTextColor(classColorOf(p.class))
                row:Show()
            else
                row.player = nil
                row:Hide()
            end
        end

        local shown = math.min(#matches, MAX_SUGGESTIONS)
        suggestionPanel:SetHeight(shown * SUGGESTION_ROW_HEIGHT)
        suggestionPanel:Show()
    end

    setMainBox:SetScript("OnTextChanged", function() updateSuggestions() end)
end

-- Top-level refresh

function RosterTab:Refresh(resetScroll)
    if not frame then return end

    -- Officer Note visibility follows current permissions every refresh.
    if RN.officerNoteHeader then
        if GP:GetModule("CustomNotes"):CanAccessOfficerNotes() then
            RN.officerNoteHeader:Show()
        else
            RN.officerNoteHeader:Hide()
        end
    end

    local guildData = getGuildData()
    local displayList = buildDisplayList()
    list:SetData(displayList, resetScroll)
    if scrollToSelectedOnRefresh and selectedGUID then
        scrollToSelectedOnRefresh = false
        for index, player in ipairs(displayList) do
            if player.guid == selectedGUID then
                list:ScrollToIndex(index)
                break
            end
        end
    end

    if guildData then
        local Roster = GP:GetModule("Roster")
        local active, former = Roster:CountMembers(guildData)
        if hasActiveAuditFilters() then
            summaryText:SetText(string.format(GP.L["Showing %d audit member(s)"], #displayList))
        elseif showOnlineOnly and showUntaggedOnly then
            summaryText:SetText(string.format(GP.L["Showing %d online untagged member(s)"], #displayList))
        elseif showOnlineOnly then
            summaryText:SetText(string.format(GP.L["Showing %d online member(s)"], #displayList))
        elseif showUntaggedOnly then
            summaryText:SetText(string.format(GP.L["Showing %d untagged member(s)"], #displayList))
        else
            summaryText:SetText(string.format(GP.L["Showing %d of %d active (%d former)"], #displayList, active, former))
        end
    else
        summaryText:SetText(GP.L["No roster data yet — try /gp scan."])
    end

    refreshDetail()
    -- GuildParagon_LabelsChanged (a remote officer's
    -- live label change) routes through here, which updates AL.labelsCountText
    if AL.refreshLabelRows then AL.refreshLabelRows() end
    paintFilterButtons()
end

-- Build

local function setSortIndicators()
    for field, button in pairs(headerButtons) do
        local arrow = (field == sortKey) and (sortAsc and " ^" or " v") or ""
        button.text:SetText(button.label .. arrow)
    end
end

local function addHeaderButton(parent, label, field, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(Theme.layout.rowHeight)
    button:SetWidth(width)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(Theme.font.small)
    text:SetJustifyH("LEFT")
    text:SetPoint("LEFT")
    button.text = text
    button.label = label
    text:SetText(label)

    if field then
        button:SetScript("OnClick", function()
            if sortKey == field then
                sortAsc = not sortAsc
            else
                sortKey, sortAsc = field, true
            end
            setSortIndicators()
            RosterTab:Refresh(true)
        end)
        headerButtons[field] = button
    end

    return button
end

local function addHeaderLabel(parent, label, width)
    local fs = parent:CreateFontString(nil, "ARTWORK")
    fs:SetFontObject(Theme.font.small)
    fs:SetJustifyH("LEFT")
    fs:SetWidth(width)
    fs:SetText(label)
    return fs
end

local function createAuditCheck(parent, label, onClick)
    local button = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    button:SetSize(22, 22)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(Theme.font.body)
    text:SetPoint("LEFT", button, "RIGHT", 4, 0)
    text:SetText(label)
    button.text = text

    button:SetScript("OnClick", function(self)
        if onClick then onClick(self:GetChecked() and true or false) end
    end)
    return button
end

local function auditActiveCount()
    local n = 0
    for _, def in ipairs(AUDIT_FILTERS) do
        if isAuditFilterEnabled(def.key) then n = n + 1 end
    end
    return n
end

local function refreshAuditToggleButton()
    if not RN.auditToggleButton then return end
    local n = auditActiveCount()
    RN.auditToggleButton.text:SetText(n > 0
        and string.format(GP.L["Roster Audit (%d)"], n)
        or GP.L["Roster Audit"])
    paintFilterButton(RN.auditToggleButton, n > 0)
end

local function buildAuditPanel(parent)
    auditChecks = {}

    RN.auditToggleButton = Theme:CreateButton(parent, GP.L["Roster Audit"])
    RN.auditToggleButton:SetPoint("TOPRIGHT")
    RN.auditToggleButton:SetWidth(AUDIT_TOGGLE_WIDTH)
    -- Preserve active-filter styling across hover changes.
    RN.auditToggleButton:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(Theme.color.accent))
    end)
    RN.auditToggleButton:SetScript("OnLeave", refreshAuditToggleButton)
    RN.auditToggleButton:SetScript("OnClick", function()
        if auditPanel:IsShown() then
            auditPanel:Hide()
        else
            auditPanel:Show()
        end
    end)

    auditPanel = Theme:CreatePanel(parent, "panelRaised", "accent")
    auditPanel:SetFrameStrata("DIALOG")
    auditPanel:SetPoint("TOPRIGHT", RN.auditToggleButton, "BOTTOMRIGHT", 0, -4)
    auditPanel:SetWidth(AUDIT_PANEL_WIDTH)
    auditPanel:SetHeight(AUDIT_FLYOUT_HEIGHT)
    auditPanel:Hide()

    local title = auditPanel:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.heading)
    title:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    title:SetText(GP.L["Roster Audit"])

    local previous
    for _, filter in ipairs(AUDIT_FILTERS) do
        local check = createAuditCheck(auditPanel, GP.L[filter.labelKey], function(value)
            getAuditFilterState()[filter.key] = value
            refreshAuditToggleButton()
            RosterTab:Refresh(true)
        end)
        check:SetChecked(isAuditFilterEnabled(filter.key))
        if previous then
            check:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
        else
            check:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
        end
        auditChecks[filter.key] = check
        previous = check
    end

    local checkAllButton = Theme:CreateButton(auditPanel, GP.L["Check All"])
    checkAllButton:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    checkAllButton:SetScript("OnClick", function()
        local filters = getAuditFilterState()
        for _, def in ipairs(AUDIT_FILTERS) do
            filters[def.key] = true
            if auditChecks[def.key] then auditChecks[def.key]:SetChecked(true) end
        end
        refreshAuditToggleButton()
        RosterTab:Refresh(true)
        auditPanel:Hide()
    end)

    local clearAllButton = Theme:CreateButton(auditPanel, GP.L["Clear All"])
    clearAllButton:SetPoint("LEFT", checkAllButton, "RIGHT", 8, 0)
    clearAllButton:SetScript("OnClick", function()
        local filters = getAuditFilterState()
        for _, def in ipairs(AUDIT_FILTERS) do
            filters[def.key] = false
            if auditChecks[def.key] then auditChecks[def.key]:SetChecked(false) end
        end
        refreshAuditToggleButton()
        RosterTab:Refresh(true)
        auditPanel:Hide()
    end)

    -- The old "Use Note Dates" bulk button lived here. It's now a
    -- guild-master-only, dry-run-then-confirm Settings/slash-command tool
    -- (GP:MigrateJoinDates) rather than an everyday Roster Audit action.

    refreshAuditToggleButton()
end

local function buildAltsLabelsFlyouts(parent)
    AL.viewAltsButton = Theme:CreateButton(parent, GP.L["View Alts"])
    AL.viewAltsButton:SetPoint("LEFT", altsOfMineText, "RIGHT", 8, 0)
    AL.viewAltsButton:Hide()

    AL.altsFlyoutPanel = Theme:CreatePanel(parent, "panelRaised", "accent")
    AL.altsFlyoutPanel:SetFrameStrata("DIALOG")
    -- Opens upward (BOTTOMLEFT anchored to the button's TOPLEFT), not
    -- downward. The detail panel sits near the
    AL.altsFlyoutPanel:SetPoint("BOTTOMLEFT", AL.viewAltsButton, "TOPLEFT", 0, 4)
    AL.altsFlyoutPanel:SetWidth(ALTS_FLYOUT_WIDTH)
    AL.altsFlyoutPanel:SetHeight(ALTS_FLYOUT_HEIGHT)
    AL.altsFlyoutPanel:Hide()

    local altsTitle = AL.altsFlyoutPanel:CreateFontString(nil, "ARTWORK")
    altsTitle:SetFontObject(Theme.font.heading)
    altsTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    altsTitle:SetText(GP.L["Alts"])

    -- The flyout owns the alt detail list.
    altDetailListArea = CreateFrame("Frame", nil, AL.altsFlyoutPanel)
    altDetailListArea:SetPoint("TOPLEFT", altsTitle, "BOTTOMLEFT", 0, -10)
    altDetailListArea:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    altDetailList = GP.UI.ScrollList:New(altDetailListArea, ALT_DETAIL_ROW_HEIGHT, createAltDetailRow)
    altDetailList:SetUpdateRow(updateAltDetailRow)

    AL.viewAltsButton:SetScript("OnClick", function()
        if AL.altsFlyoutPanel:IsShown() then
            AL.altsFlyoutPanel:Hide()
        else
            AL.altsFlyoutPanel:Show()
            AL.labelsFlyoutPanel:Hide()
        end
    end)

    -- Same row (FIRST_ROW_Y - ROW_STRIDE*5, see refreshDetail) as
    -- altOfText/altsOfMineText/setMainLabel above, but anchored directly
    local FIRST_ROW_Y, ROW_STRIDE = -18, 32
    local LABELS_COLUMN_X = 280

    AL.labelsCountText = parent:CreateFontString(nil, "ARTWORK")
    AL.labelsCountText:SetFontObject(Theme.font.body)
    AL.labelsCountText:SetJustifyH("LEFT")
    AL.labelsCountText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", LABELS_COLUMN_X, FIRST_ROW_Y - ROW_STRIDE * 5)
    AL.labelsCountText:Hide()

    AL.manageLabelsButton = Theme:CreateButton(parent, GP.L["Manage Labels"])
    AL.manageLabelsButton:SetPoint("LEFT", AL.labelsCountText, "RIGHT", 8, 0)
    AL.manageLabelsButton:Hide()

    AL.labelsFlyoutPanel = Theme:CreatePanel(parent, "panelRaised", "accent")
    AL.labelsFlyoutPanel:SetFrameStrata("DIALOG")
    -- Opens upward, same reasoning as AL.altsFlyoutPanel above.
    AL.labelsFlyoutPanel:SetPoint("BOTTOMLEFT", AL.manageLabelsButton, "TOPLEFT", 0, 4)
    AL.labelsFlyoutPanel:SetWidth(LABELS_FLYOUT_WIDTH)
    AL.labelsFlyoutPanel:SetHeight(LABELS_FLYOUT_HEIGHT)
    AL.labelsFlyoutPanel:Hide()

    local labelsTitle = AL.labelsFlyoutPanel:CreateFontString(nil, "ARTWORK")
    labelsTitle:SetFontObject(Theme.font.heading)
    labelsTitle:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    labelsTitle:SetText(GP.L["Manage Labels"])

    local labelsEmptyText = AL.labelsFlyoutPanel:CreateFontString(nil, "ARTWORK")
    labelsEmptyText:SetFontObject(Theme.font.small)
    labelsEmptyText:SetPoint("TOPLEFT", labelsTitle, "BOTTOMLEFT", 0, -12)
    labelsEmptyText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    labelsEmptyText:SetJustifyH("LEFT")
    labelsEmptyText:SetText(GP.L["No labels exist yet — an officer can create some from Settings."])
    labelsEmptyText:Hide()

    local labelListArea = CreateFrame("Frame", nil, AL.labelsFlyoutPanel)
    labelListArea:SetPoint("TOPLEFT", labelsTitle, "BOTTOMLEFT", 0, -10)
    labelListArea:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    AL.labelList = GP.UI.ScrollList:New(labelListArea, LABELS_ROW_HEIGHT, createLabelManageRow)
    AL.labelList:SetUpdateRow(updateLabelManageRow)

    -- Called both by the toggle button below (so reopening always reflects
    -- current assignment state) and by each row's own Add/Remove click
    function AL.refreshLabelRows()
        if not selectedGUID or not AL.labelsFlyoutPanel:IsShown() then return end
        local _, guildKey = getGuildData()
        local rows = labelRowsForPlayer(guildKey, selectedGUID)
        labelListArea:SetShown(#rows > 0)
        labelsEmptyText:SetShown(#rows == 0)
        AL.labelList:SetData(rows, true)
    end

    AL.manageLabelsButton:SetScript("OnClick", function()
        if AL.labelsFlyoutPanel:IsShown() then
            AL.labelsFlyoutPanel:Hide()
        else
            AL.labelsFlyoutPanel:Show()
            AL.altsFlyoutPanel:Hide()
            AL.refreshLabelRows()
        end
    end)

    -- Passive outside-click watcher: observe mouse state without taking
    -- click ownership away from the underlying roster row or flyout.
    local outsideMouseWasDown = false

    AL.clickOutsideWatcher = CreateFrame("Frame")
    AL.clickOutsideWatcher:Hide()
    AL.clickOutsideWatcher:SetScript("OnUpdate", function()
        local isDown = IsMouseButtonDown("LeftButton")
        -- Rising edge only (was up, now down) — a held-down button must
        -- not re-trigger this check on every subsequent frame.
        if isDown and not outsideMouseWasDown then
            local overAlts = AL.altsFlyoutPanel:IsShown() and AL.altsFlyoutPanel:IsMouseOver()
            local overLabels = AL.labelsFlyoutPanel:IsShown() and AL.labelsFlyoutPanel:IsMouseOver()
            if not overAlts and not overLabels then
                AL.altsFlyoutPanel:Hide()
                AL.labelsFlyoutPanel:Hide()
            end
        end
        outsideMouseWasDown = isDown
    end)

    -- Seed from the current mouse state so the opening click is not
    -- immediately treated as an outside click.
    local function updateClickOutsideWatcher()
        if AL.altsFlyoutPanel:IsShown() or AL.labelsFlyoutPanel:IsShown() then
            outsideMouseWasDown = IsMouseButtonDown("LeftButton")
            AL.clickOutsideWatcher:Show()
        else
            AL.clickOutsideWatcher:Hide()
        end
    end
    AL.altsFlyoutPanel:SetScript("OnShow", updateClickOutsideWatcher)
    AL.altsFlyoutPanel:SetScript("OnHide", updateClickOutsideWatcher)
    AL.labelsFlyoutPanel:SetScript("OnShow", updateClickOutsideWatcher)
    AL.labelsFlyoutPanel:SetScript("OnHide", updateClickOutsideWatcher)
end

-- Confirmation gate for JD.saveButton below: only shown when overwriting a
-- join date that already has a confirmed source (guild event log, a prior
StaticPopupDialogs["GUILDPARAGON_OVERRIDE_JOIN_DATE"] = StaticPopupDialogs["GUILDPARAGON_OVERRIDE_JOIN_DATE"] or {
    text = "%s\n\n" .. GP.L["Override this member's join date?"],
    button1 = GP.L["Override"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, data)
        if data and data.save then data.save() end
    end,
}

local function buildDetailPanel(parent)
    local L = GP.L
    local detail = Theme:CreatePanel(parent, "panel", "border")
    detail:SetHeight(DETAIL_HEIGHT)
    detail:SetPoint("BOTTOMLEFT")
    detail:SetPoint("BOTTOMRIGHT")

    detailHeading = detail:CreateFontString(nil, "ARTWORK")
    detailHeading:SetFontObject(Theme.font.heading)
    detailHeading:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    detailHeading:SetPoint("RIGHT", detail, "LEFT", 300, 0)
    detailHeading:SetJustifyH("LEFT")
    detailHeading:SetWordWrap(false)

    detailLastOnlineText = detail:CreateFontString(nil, "ARTWORK")
    detailLastOnlineText:SetFontObject(Theme.font.muted)
    detailLastOnlineText:SetPoint("LEFT", detailHeading, "RIGHT", 14, 0)
    detailLastOnlineText:SetPoint("RIGHT", detail, "LEFT", 540, 0)
    detailLastOnlineText:SetJustifyH("LEFT")
    detailLastOnlineText:SetWordWrap(false)
    detailLastOnlineText:Hide()

    local ROW_STRIDE = 32
    local FIRST_ROW_Y = -18

    nickLabel = detail:CreateFontString(nil, "ARTWORK")
    nickLabel:SetFontObject(Theme.font.small)
    nickLabel:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y)
    nickLabel:SetText(L["Nickname:"])

    nickBox = Theme:CreateEditBox(detail, 140)
    nickBox:SetPoint("LEFT", nickLabel, "RIGHT", 8, 0)

    nickButton = Theme:CreateButton(detail, L["Save"])
    nickButton:SetPoint("LEFT", nickBox, "RIGHT", 8, 0)
    nickButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local ok, err = GP:GetModule("Nicknames"):Set(guildKey, selectedGUID, nickBox:GetText())
        if ok then
            setStatus(L["Saved."])
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    customNoteLabel = detail:CreateFontString(nil, "ARTWORK")
    customNoteLabel:SetFontObject(Theme.font.small)
    customNoteLabel:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE)
    customNoteLabel:SetText(L["Custom Note:"])

    customNoteBox = Theme:CreateEditBox(detail, 300)
    customNoteBox:SetPoint("LEFT", customNoteLabel, "RIGHT", 8, 0)

    customNoteButton = Theme:CreateButton(detail, L["Save"])
    customNoteButton:SetPoint("LEFT", customNoteBox, "RIGHT", 8, 0)
    customNoteButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local ok, err = GP:GetModule("CustomNotes"):Set(guildKey, selectedGUID, customNoteBox:GetText())
        if ok then
            setStatus(L["Saved."])
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    officerNoteLabel = detail:CreateFontString(nil, "ARTWORK")
    officerNoteLabel:SetFontObject(Theme.font.small)
    officerNoteLabel:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 2)
    officerNoteLabel:SetText(L["Custom Officer Note:"])

    officerNoteBox = Theme:CreateEditBox(detail, 260)
    officerNoteBox:SetPoint("LEFT", officerNoteLabel, "RIGHT", 8, 0)

    officerNoteButton = Theme:CreateButton(detail, L["Save"])
    officerNoteButton:SetPoint("LEFT", officerNoteBox, "RIGHT", 8, 0)
    officerNoteButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local ok, err = GP:GetModule("CustomNotes"):SetOfficer(guildKey, selectedGUID, officerNoteBox:GetText())
        if ok then
            setStatus(L["Saved."])
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    officerNoteLockedText = detail:CreateFontString(nil, "ARTWORK")
    officerNoteLockedText:SetFontObject(Theme.font.small)
    officerNoteLockedText:SetPoint("LEFT", officerNoteLabel, "RIGHT", 8, 0)
    officerNoteLockedText:SetText(L["Officer-only notes require officer access."])
    officerNoteLockedText:SetTextColor(unpack(Theme.color.textSecondary))

    birthdayLabel = detail:CreateFontString(nil, "ARTWORK")
    birthdayLabel:SetFontObject(Theme.font.small)
    birthdayLabel:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 3)
    birthdayLabel:SetText(L["Birthday:"])

    birthdayDayBox = Theme:CreateEditBox(detail, 42)
    birthdayDayBox:SetPoint("LEFT", birthdayLabel, "RIGHT", 8, 0)
    birthdayDayBox:SetNumeric(true)

    birthdayMonthBox = Theme:CreateEditBox(detail, 42)
    birthdayMonthBox:SetPoint("LEFT", birthdayDayBox, "RIGHT", 6, 0)
    birthdayMonthBox:SetNumeric(true)

    birthdaySaveButton = Theme:CreateButton(detail, L["Save"])
    birthdaySaveButton:SetPoint("LEFT", birthdayMonthBox, "RIGHT", 8, 0)
    birthdaySaveButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local ok, err = GP:GetModule("Roster"):SetBirthday(guildKey, selectedGUID, birthdayDayBox:GetText(), birthdayMonthBox:GetText())
        if ok then
            setStatus(L["Saved."])
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    birthdayClearButton = Theme:CreateButton(detail, L["Clear"])
    birthdayClearButton:SetPoint("LEFT", birthdaySaveButton, "RIGHT", 8, 0)
    birthdayClearButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local ok, err = GP:GetModule("Roster"):ClearBirthday(guildKey, selectedGUID)
        if ok then
            birthdayDayBox:SetText("")
            birthdayMonthBox:SetText("")
            setStatus(L["Cleared."])
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    -- Join date: a real field (Roster's player.firstSeen), not text baked
    -- into the custom note. Visible to
    JD.label = detail:CreateFontString(nil, "ARTWORK")
    JD.label:SetFontObject(Theme.font.small)
    JD.label:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 4)
    JD.label:SetText(L["Joined:"])

    JD.box = Theme:CreateEditBox(detail, 100)
    JD.box:SetPoint("LEFT", JD.label, "RIGHT", 8, 0)

    JD.saveButton = Theme:CreateButton(detail, L["Save"])
    JD.saveButton:SetPoint("LEFT", JD.box, "RIGHT", 8, 0)
    JD.saveButton:SetScript("OnClick", function()
        local guildData, guildKey = getGuildData()
        local player = guildData and (guildData.roster[selectedGUID] or guildData.formerMembers[selectedGUID])

        local function doSave()
            local ok, err = GP:GetModule("Roster"):SetJoinDate(guildKey, selectedGUID, JD.box:GetText())
            setStatus(ok and L["Saved."] or err, not ok)
            RosterTab:Refresh()
        end

        local hasConfirmedDate = player and player.joinDateSource and not player.joinDateUnknown
            and type(player.firstSeen) == "number" and player.firstSeen > 0
        local newDate = canonicalJoinDateText(JD.box:GetText())
        if hasConfirmedDate and newDate and newDate ~= formatDate(player.firstSeen) then
            StaticPopup_Show("GUILDPARAGON_OVERRIDE_JOIN_DATE", joinDateSourceText(player), nil, { save = doSave })
        else
            doSave()
        end
    end)

    JD.sourceText = detail:CreateFontString(nil, "ARTWORK")
    JD.sourceText:SetFontObject(Theme.font.small)
    JD.sourceText:SetJustifyH("LEFT")
    JD.sourceText:SetTextColor(unpack(Theme.color.textSecondary))
    JD.sourceText:SetPoint("LEFT", JD.saveButton, "RIGHT", 10, 0)

    altOfText = detail:CreateFontString(nil, "ARTWORK")
    altOfText:SetFontObject(Theme.font.body)
    altOfText:SetJustifyH("LEFT")
    altOfText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 5)

    -- Below altOfText, not beside it; placing these buttons beside the
    -- text made this row too cramped.
    altOfClearButton = Theme:CreateButton(detail, L["Clear"])
    altOfClearButton:SetPoint("TOPLEFT", altOfText, "BOTTOMLEFT", 0, -6)
    altOfClearButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local ok, err = GP:GetModule("Alts"):ClearMain(guildKey, selectedGUID)
        if ok then
            setMainBox:SetText("")
            setStatus(L["Cleared."])
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    -- Promotes the selected alt to the group's main in one call.
    altPromoteButton = Theme:CreateButton(detail, L["Set as Main"])
    altPromoteButton:SetPoint("LEFT", altOfClearButton, "RIGHT", 8, 0)
    altPromoteButton:SetScript("OnClick", function()
        local guildData, guildKey = getGuildData()
        local ok, err = GP:GetModule("Alts"):PromoteToMain(guildKey, selectedGUID)
        if ok then
            local player = guildData and (guildData.roster[selectedGUID] or guildData.formerMembers[selectedGUID])
            setStatus(string.format(L["%s is now the main. Alts have been re-linked."], player and player.name or "?"))
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    altsOfMineText = detail:CreateFontString(nil, "ARTWORK")
    altsOfMineText:SetFontObject(Theme.font.body)
    altsOfMineText:SetJustifyH("LEFT")
    altsOfMineText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 5)
    -- No RIGHT anchor; the following button should sit after the visible text.
    altsOfMineText:SetWordWrap(false)

    -- Build the paired View Alts and Manage Labels flyouts together.
    buildAltsLabelsFlyouts(detail)

    setMainLabel = detail:CreateFontString(nil, "ARTWORK")
    setMainLabel:SetFontObject(Theme.font.small)
    setMainLabel:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 5)
    setMainLabel:SetText(L["Tag as alt of:"])

    setMainBox = Theme:CreateEditBox(detail, 150)
    setMainBox:SetPoint("LEFT", setMainLabel, "RIGHT", 8, 0)

    setMainButton = Theme:CreateButton(detail, L["Set"])
    setMainButton:SetPoint("LEFT", setMainBox, "RIGHT", 8, 0)
    setMainButton:SetScript("OnClick", function()
        local guildData, guildKey = getGuildData()
        local mainName = strtrim(setMainBox:GetText() or "")
        if mainName == "" then
            setStatus(L["Type a character name first."], true)
            return
        end

        local mainGUID, _, reason = GP:GetModule("Roster"):FindPlayerByName(guildData, mainName, false)

        if not mainGUID then
            setStatus(reason == "ambiguous" and L["More than one guild member matches that name. Use Name-Realm."] or L["Player not found."], true)
            return
        end

        local ok, err = GP:GetModule("Alts"):SetMain(guildKey, selectedGUID, mainGUID)
        if ok then
            setMainBox:SetText("")
            setStatus(L["Saved."])
            hideSuggestions()
            RosterTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    mainToggleButton = Theme:CreateButton(detail, L["Mark as Main"])
    mainToggleButton:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 6)
    mainToggleButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local Alts = GP:GetModule("Alts")
        if Alts:IsMarkedMain(guildKey, selectedGUID) then
            local ok, err = Alts:UnsetAsMain(guildKey, selectedGUID)
            setStatus(ok and L["Unmarked."] or err, not ok)
        else
            local ok, err = Alts:SetAsMain(guildKey, selectedGUID)
            setStatus(ok and L["Marked as main."] or err, not ok)
        end
        RosterTab:Refresh()
    end)

    local macroRulesButton = Theme:CreateButton(detail, L["Macro Rules"])
    macroRulesButton:SetWidth(128)
    macroRulesButton:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)
    macroRulesButton.guildParagonMacroRulesAnchor = "above"
    macroRulesButton:SetScript("OnClick", function()
        local guildData, guildKey = getGuildData()
        local player = guildData and selectedGUID and (guildData.roster[selectedGUID] or guildData.formerMembers[selectedGUID])
        local ok = GP.UI.MemberTooltip:ShowMacroRulesForPlayer(macroRulesButton, player, guildKey)
        if not ok then
            setStatus(L["Macro Tool is officer-only."], true)
        end
    end)
    frame.macroRulesButton = macroRulesButton

    statusText = detail:CreateFontString(nil, "ARTWORK")
    statusText:SetFontObject(Theme.font.small)
    statusText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 7)
    statusText:SetPoint("RIGHT", detail, "LEFT", 540, 0)
    statusText:SetJustifyH("LEFT")

    historyHeading = detail:CreateFontString(nil, "ARTWORK")
    historyHeading:SetFontObject(Theme.font.small)
    historyHeading:SetPoint("TOPLEFT", detail, "TOPLEFT", 560, -Theme.layout.gutter)
    historyHeading:SetText(L["Recent History"])
    historyHeading:SetTextColor(unpack(Theme.color.textSecondary))

    historyBody = detail:CreateFontString(nil, "ARTWORK")
    historyBody:SetFontObject(Theme.font.small)
    historyBody:SetPoint("TOPLEFT", historyHeading, "BOTTOMLEFT", 0, -8)
    historyBody:SetPoint("BOTTOMRIGHT", detail, "BOTTOMLEFT", 850, Theme.layout.gutter)
    historyBody:SetJustifyH("LEFT")
    historyBody:SetJustifyV("TOP")

    auditDetailHeading = detail:CreateFontString(nil, "ARTWORK")
    auditDetailHeading:SetFontObject(Theme.font.small)
    auditDetailHeading:SetPoint("TOPLEFT", detail, "TOPLEFT", 880, -Theme.layout.gutter)
    auditDetailHeading:SetTextColor(unpack(Theme.color.textSecondary))

    auditDetailBody = detail:CreateFontString(nil, "ARTWORK")
    auditDetailBody:SetFontObject(Theme.font.small)
    auditDetailBody:SetPoint("TOPLEFT", auditDetailHeading, "BOTTOMLEFT", 0, -8)
    auditDetailBody:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    auditDetailBody:SetHeight(96)
    auditDetailBody:SetJustifyH("LEFT")
    auditDetailBody:SetJustifyV("TOP")

    RosterTab:BuildSuggestions(detail)


end

function RosterTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    searchBox = Theme:CreateSearchBox(frame, 200, function() RosterTab:Refresh(true) end)
    searchBox:SetPoint("TOPLEFT")

    onlineOnlyButton = Theme:CreateButton(frame, L["Online Only"])
    onlineOnlyButton:SetWidth(108)
    onlineOnlyButton:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    onlineOnlyButton:SetScript("OnClick", function()
        showOnlineOnly = not showOnlineOnly
        RosterTab:Refresh(true)
    end)
    onlineOnlyButton:SetScript("OnLeave", paintFilterButtons)

    untaggedOnlyButton = Theme:CreateButton(frame, L["Untagged Only"])
    untaggedOnlyButton:SetWidth(118)
    untaggedOnlyButton:SetPoint("LEFT", onlineOnlyButton, "RIGHT", 8, 0)
    untaggedOnlyButton:SetScript("OnClick", function()
        showUntaggedOnly = not showUntaggedOnly
        RosterTab:Refresh(true)
    end)
    untaggedOnlyButton:SetScript("OnLeave", paintFilterButtons)

    buildAuditPanel(frame)

    summaryText = frame:CreateFontString(nil, "ARTWORK")
    summaryText:SetFontObject(Theme.font.muted)
    summaryText:SetJustifyH("RIGHT")
    summaryText:SetPoint("LEFT", untaggedOnlyButton, "RIGHT", 12, 0)
    -- Anchored to the always-visible collapsed toggle button, not the
    -- floating auditPanel flyout (which is hidden by default and, even
    -- when shown, overlays the table rather than affecting its layout —
    -- see buildAuditPanel's comment). Keeps table width perfectly stable
    -- regardless of whether the audit flyout is open or closed.
    summaryText:SetPoint("RIGHT", RN.auditToggleButton, "LEFT", -12, 0)

    local headerRow = CreateFrame("Frame", nil, frame)
    headerRow:SetHeight(Theme.layout.rowHeight)
    headerRow:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    headerRow:SetPoint("RIGHT", RN.auditToggleButton, "LEFT", -Theme.layout.gutter, 0)

    local nameHeader = addHeaderButton(headerRow, L["Name"], "name", COL.nameWidth)
    nameHeader:SetPoint("LEFT", COL.leftPad + COL.dotWidth + COL.gap, 0)
    local rankHeader = addHeaderButton(headerRow, L["Rank"], "rankIndex", COL.rankWidth)
    rankHeader:SetPoint("LEFT", nameHeader, "RIGHT", COL.gap, 0)
    local levelHeader = addHeaderButton(headerRow, L["Lvl"], "level", COL.levelWidth)
    levelHeader:SetPoint("LEFT", rankHeader, "RIGHT", COL.gap, 0)
    local lastOnlineHeader = addHeaderButton(headerRow, L["Last Online"], "lastOnline", COL.lastWidth)
    lastOnlineHeader:SetPoint("LEFT", levelHeader, "RIGHT", COL.gap, 0)
    local nickHeader = addHeaderButton(headerRow, L["Nickname"], "nickname", COL.nickWidth)
    nickHeader:SetPoint("LEFT", lastOnlineHeader, "RIGHT", COL.gap, 0)
    local tagHeader = addHeaderButton(headerRow, L["Alt / Main"], "tag", COL.tagWidth)
    tagHeader:SetPoint("LEFT", nickHeader, "RIGHT", COL.gap, 0)
    local noteHeader = addHeaderButton(headerRow, L["Note"], "note", NOTE_COL_WIDTH)
    noteHeader:SetPoint("LEFT", tagHeader, "RIGHT", COL.gap, 0)
    -- Blizzard's native Officer Note column; Refresh handles permission
    -- changes for both header and row cells.
    RN.officerNoteHeader = addHeaderButton(headerRow, L["Officer Note"], "officerNote", OFFICER_NOTE_COL_WIDTH)
    RN.officerNoteHeader:SetPoint("LEFT", noteHeader, "RIGHT", COL.gap, 0)

    setSortIndicators()

    local listArea = CreateFrame("Frame", nil, frame)
    listArea:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -4)
    -- Rows use the full window width; only the header avoids the audit
    -- toggle band.
    listArea:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    listArea:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, DETAIL_HEIGHT + Theme.layout.gutter)
    -- Anchor-only sizing avoids conflicting explicit dimensions.

    list = GP.UI.ScrollList:New(listArea, ROW_HEIGHT, createRosterRow)
    list:SetUpdateRow(updateRosterRow)

    buildDetailPanel(frame)

    -- Debounced (GP:DebounceCall): a Guild Sync full-state apply can fire
    -- several hundred of these messages in one unyielding burst (one per
    local function debouncedRefresh()
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("RosterTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                RosterTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    RosterTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_AltsChanged", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_NicknamesChanged", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_CustomNotesChanged", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_JoinDateChanged", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_BirthdayChanged", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_LogEntryAdded", debouncedRefresh)
    RosterTab:RegisterMessage("GuildParagon_LabelsChanged", debouncedRefresh)

    -- MainWindow:SelectTab calls this whenever the user switches *away*
    -- from Roster to a different top-level tab (Core/Core.lua registers
    frame.OnDeselected = function()
        if auditPanel then auditPanel:Hide() end
        if AL.altsFlyoutPanel then AL.altsFlyoutPanel:Hide() end
        if AL.labelsFlyoutPanel then AL.labelsFlyoutPanel:Hide() end
        if GP.UI.RosterContextMenu then GP.UI.RosterContextMenu:Hide() end
    end

    frame.OnSelected = function()
        if refreshDirty then
            refreshDirty = false
            RosterTab:Refresh()
        end
    end

    self:Refresh()
    return frame
end
