-- Guild Paragon — Alts & Nicknames tab
-- A searchable member list (reusing UI/ScrollList.lua, same shape as the
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.AltsTab = GP.UI.AltsTab or {}
local AltsTab = GP.UI.AltsTab

-- Own AceEvent identity, not GP — see UI/RecruitmentTab.lua's long comment
-- above its own Embed call for the full root-cause explanation: multiple
LibStub("AceEvent-3.0"):Embed(AltsTab)

local COL = {
    leftPad    = 8,
    dotWidth   = 6,
    gap        = 8,
    nameWidth  = 180,
    nickWidth  = 110,
}
local NAME_MAX_CHARS = 24
local TAG_MAX_CHARS = 40
local ROW_HEIGHT = 28
local DETAIL_HEIGHT = 260

local MAX_SUGGESTIONS = 6
local SUGGESTION_ROW_HEIGHT = 22

local frame, list, searchBox, untaggedOnlyButton, summaryText
local refreshDirty = false
local detailHeading, statusText
local nickLabel, nickBox, nickButton
local customNoteLabel, customNoteBox, customNoteButton
local officerNoteLabel, officerNoteBox, officerNoteButton, officerNoteLockedText
local altOfText, altOfClearButton
local altsOfMineText
local setMainLabel, setMainBox, setMainButton
local mainToggleButton
local suggestionPanel, suggestionRows = nil, {}
local selectedGUID
local showUntaggedOnly = false

-- Preserve in-progress edits across refreshes for the selected member.
local lastDetailGUID

-- Forward-declared for selection and suggestion callbacks.
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
        return text:sub(1, maxChars) .. "…"
    end
    return text
end

local function singleLine(text)
    text = text or ""
    text = text:gsub("[\r\n\t]+", " ")
    text = text:gsub("%s+", " ")
    return strtrim(text)
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

local function isTagged(guildKey, guid)
    local Alts = GP:GetModule("Alts")
    return Alts:GetMain(guildKey, guid) ~= nil or Alts:IsMain(guildKey, guid)
end

local function paintUntaggedButton()
    if not untaggedOnlyButton then return end
    untaggedOnlyButton:SetBackdropBorderColor(unpack(showUntaggedOnly and Theme.color.accent or Theme.color.accentDim))
    untaggedOnlyButton.text:SetFontObject(showUntaggedOnly and Theme.font.heading or Theme.font.body)
end

-- Row widget

local function createAltRow(parent)
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

    local nick = row:CreateFontString(nil, "ARTWORK")
    nick:SetFontObject(Theme.font.muted)
    nick:SetJustifyH("LEFT")
    nick:SetPoint("LEFT", name, "RIGHT", COL.gap, 0)
    nick:SetWidth(COL.nickWidth)
    nick:SetWordWrap(false)
    row.nick = nick

    local tag = row:CreateFontString(nil, "ARTWORK")
    tag:SetFontObject(Theme.font.muted)
    tag:SetJustifyH("LEFT")
    tag:SetPoint("LEFT", nick, "RIGHT", COL.gap, 0)
    tag:SetPoint("RIGHT", -8, 0)
    tag:SetWordWrap(false)
    row.tag = tag

    row:SetScript("OnEnter", function(self)
        if not self.selected then self:SetBackdropColor(unpack(Theme.color.panelRaised)) end
    end)
    row:SetScript("OnLeave", function(self)
        if not self.selected then self:SetBackdropColor(0, 0, 0, 0) end
    end)
    row:SetScript("OnClick", function(self)
        if self.player then AltsTab:SelectPlayer(self.player) end
    end)

    return row
end

local function updateAltRow(row, player)
    local L = GP.L
    row.player = player
    row.selected = (player.guid == selectedGUID)
    if row.selected then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
    else
        row:SetBackdropColor(0, 0, 0, 0)
    end

    row.dot:SetColorTexture(unpack(player.online and Theme.color.success or Theme.color.textDisabled))
    row.name:SetTextColor(classColorOf(player.class))
    row.name:SetText(truncate(player.name, NAME_MAX_CHARS))

    local guildData, guildKey = getGuildData()
    local nickname = guildData and GP:GetModule("Nicknames"):Get(guildKey, player.guid) or ""
    row.nick:SetText(nickname ~= "" and ("\"" .. nickname .. "\"") or "")

    local Alts = GP:GetModule("Alts")
    local mainGUID = guildData and Alts:GetMain(guildKey, player.guid)
    if mainGUID then
        local mainPlayer = guildData.roster[mainGUID] or guildData.formerMembers[mainGUID]
        row.tag:SetText(truncate(string.format(L["Alt of %s"], mainPlayer and mainPlayer.name or "?"), TAG_MAX_CHARS))
    else
        local altGUIDs = guildData and Alts:GetAlts(guildKey, player.guid) or {}
        local altCount = #activeAltGUIDsFor(guildData, altGUIDs)
        if altCount > 0 then
            row.tag:SetText(string.format(L["%d alt(s)"], altCount))
        elseif guildData and (Alts:IsMarkedMain(guildKey, player.guid) or Alts:IsMain(guildKey, player.guid)) then
            row.tag:SetText(L["Main"])
        else
            row.tag:SetText(L["Needs tag"])
        end
    end
end

-- Data: filter + sort (alphabetical only — no sortable columns on this tab)

local function buildDisplayList()
    local guildData, guildKey = getGuildData()
    local out = {}
    if not guildData then return out end

    local filterText = strtrim(searchBox:GetText() or ""):lower()
    for _, player in pairs(guildData.roster) do
        if filterText == "" or player.name:lower():find(filterText, 1, true) then
            if not showUntaggedOnly or not isTagged(guildKey, player.guid) then
                table.insert(out, player)
            end
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Detail panel

local function setStatus(text, isError)
    statusText:SetText(text or "")
    statusText:SetTextColor(unpack(isError and Theme.color.danger or Theme.color.textSecondary))
end

function AltsTab:SelectPlayer(player)
    selectedGUID = player.guid
    setStatus("")
    hideSuggestions()
    self:Refresh()
end

local function refreshDetail()
    local L = GP.L
    local guildData, guildKey = getGuildData()
    local player = guildData and selectedGUID and (guildData.roster[selectedGUID] or guildData.formerMembers[selectedGUID])

    -- Only reset form field *contents* when the selection has
    -- actually changed — refreshDetail() also runs for background events
    -- (a rescan, a change made on another instance of this tab) while the
    -- SAME member is still selected, and resetting on every one of those
    -- was silently wiping out whatever the user was mid-typing.
    local isNewSelection = (selectedGUID ~= lastDetailGUID)
    lastDetailGUID = selectedGUID

    if not player then
        detailHeading:SetText(L["Select a member to manage their nickname, notes, or alt/main tag."])
        detailHeading:SetTextColor(unpack(Theme.color.textSecondary))
        nickLabel:Hide(); nickBox:Hide(); nickButton:Hide()
        customNoteLabel:Hide(); customNoteBox:Hide(); customNoteButton:Hide()
        officerNoteLabel:Hide(); officerNoteBox:Hide(); officerNoteButton:Hide(); officerNoteLockedText:Hide()
        altOfText:Hide(); altOfClearButton:Hide()
        altsOfMineText:Hide()
        setMainLabel:Hide(); setMainBox:Hide(); setMainButton:Hide()
        mainToggleButton:Hide()
        hideSuggestions()
        return
    end

    detailHeading:SetText(string.format("%s — %s (%d)", player.name, player.rankName, player.level))
    detailHeading:SetTextColor(classColorOf(player.class))

    nickLabel:Show(); nickBox:Show(); nickButton:Show()
    customNoteLabel:Show(); customNoteBox:Show(); customNoteButton:Show()
    if isNewSelection then
        nickBox:SetText(GP:GetModule("Nicknames"):Get(guildKey, selectedGUID))
        customNoteBox:SetText(singleLine(GP:GetModule("CustomNotes"):Get(guildKey, selectedGUID)))
    end

    local CustomNotes = GP:GetModule("CustomNotes")
    officerNoteLabel:Show()
    if CustomNotes:CanAccessOfficerNotes() then
        officerNoteBox:Show(); officerNoteButton:Show(); officerNoteLockedText:Hide()
        if isNewSelection then
            officerNoteBox:SetText(singleLine(CustomNotes:GetOfficer(guildKey, selectedGUID)))
        end
    else
        officerNoteBox:Hide(); officerNoteButton:Hide(); officerNoteLockedText:Show()
        if isNewSelection then officerNoteBox:SetText("") end
    end

    local Alts = GP:GetModule("Alts")
    local mainGUID = Alts:GetMain(guildKey, selectedGUID)
    local allMyAlts = Alts:GetAlts(guildKey, selectedGUID)
    local myAlts = activeAltGUIDsFor(guildData, allMyAlts)
    local markedMain = Alts:IsMarkedMain(guildKey, selectedGUID)
    local knownMain = Alts:IsMain(guildKey, selectedGUID)

    if mainGUID then
        -- State A: this member IS an alt of someone else.
        local mainPlayer = guildData.roster[mainGUID] or guildData.formerMembers[mainGUID]
        altOfText:SetText(string.format(L["Alt of: %s"], mainPlayer and mainPlayer.name or "?"))
        altOfText:Show(); altOfClearButton:Show()
        altsOfMineText:Hide()
        setMainLabel:Hide(); setMainBox:Hide(); setMainButton:Hide()
        mainToggleButton:Hide()
        hideSuggestions()
    elseif #myAlts > 0 or markedMain or knownMain then
        -- State B: this member IS a main — either it has real alts tagged
        -- to it, or it's explicitly flagged as one (SetAsMain) with none
        -- tagged yet.
        if #myAlts > 0 then
            -- Capped at 4 names + "+N more" rather than left to wrap
            -- freely — statusText below is anchored at a fixed offset, so
            -- this needs to stay a single line regardless of alt count.
            local names = {}
            for i, altGUID in ipairs(myAlts) do
                if i > 4 then break end
                local altPlayer = guildData.roster[altGUID] or guildData.formerMembers[altGUID]
                table.insert(names, altPlayer and altPlayer.name or "?")
            end
            if #myAlts > 4 then
                table.insert(names, string.format(L["+%d more"], #myAlts - 4))
            end
            altsOfMineText:SetText(string.format(L["Alts (%d): %s"], #myAlts, table.concat(names, ", ")))
        else
            altsOfMineText:SetText((#allMyAlts > 0) and L["Alts (0): none active"] or L["Alts (0): none tagged yet"])
        end
        altsOfMineText:Show()
        altOfText:Hide(); altOfClearButton:Hide()
        setMainLabel:Hide(); setMainBox:Hide(); setMainButton:Hide()
        hideSuggestions()

        if #allMyAlts == 0 and markedMain then
            -- Unmark only makes sense while the flag is the ONLY thing
            -- making this a main — once real alts exist, IsMain stays true
            -- regardless of the flag, so there's nothing to toggle off.
            mainToggleButton.text:SetText(L["Unmark as Main"])
            mainToggleButton:SetWidth(mainToggleButton.text:GetStringWidth() + 32)
            mainToggleButton:Show()
        else
            mainToggleButton:Hide()
        end
    else
        -- State C: neither an alt nor a main yet.
        setMainLabel:Show(); setMainBox:Show(); setMainButton:Show()
        if isNewSelection then
            setMainBox:SetText("")
        end
        altOfText:Hide(); altOfClearButton:Hide()
        altsOfMineText:Hide()
        hideSuggestions()

        mainToggleButton.text:SetText(L["Mark as Main"])
        mainToggleButton:SetWidth(mainToggleButton.text:GetStringWidth() + 32)
        mainToggleButton:Show()
    end
end

-- Autocomplete dropdown for "Tag as alt of:" — picking a name beats typing
-- the whole thing out.

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
            -- SetText fires OnTextChanged, which re-triggers updateSuggestions
            -- and would reopen this dropdown for the new (self-matching)
            -- text — harmless (synchronous, single-threaded), but the
            -- explicit hideSuggestions() below runs after and wins, so the
            -- dropdown ends up closed as intended either way.
            setMainBox:SetCursorPosition(#self.player.name)
            setMainBox:HighlightText(0, 0) -- clear any text selection
        end
        hideSuggestions()
    end)

    return row
end

function AltsTab:BuildSuggestions(detail)
    suggestionPanel = Theme:CreatePanel(detail, "panelRaised", "accent")
    suggestionPanel:SetWidth(140)
    suggestionPanel:SetFrameStrata("DIALOG") -- draw above every other row in this panel
    -- Opens UPWARD from the input, not downward: setMainBox is the lowest
    -- row in this panel, close to the main window's own bottom edge, with
    -- nowhere near enough room below it for a multi-row dropdown. There's
    -- plenty of clearance above (the rest of the panel, and the list above
    -- that).
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
            -- Excludes the selected member (can't be their own main) and
            -- anyone already tagged as someone ELSE's alt — Alts:SetMain
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

function AltsTab:Refresh(resetScroll)
    if not frame then return end

    local guildData = getGuildData()
    local displayList = buildDisplayList()
    list:SetData(displayList, resetScroll)

    if guildData then
        summaryText:SetText(string.format(showUntaggedOnly and GP.L["Showing %d untagged member(s)"] or GP.L["Showing %d members"], #displayList))
    else
        summaryText:SetText(GP.L["No roster data yet — try /gp scan."])
    end

    refreshDetail()
    paintUntaggedButton()
end

-- Build

function AltsTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    searchBox = Theme:CreateSearchBox(frame, 200, function() AltsTab:Refresh(true) end)
    searchBox:SetPoint("TOPLEFT")

    untaggedOnlyButton = Theme:CreateButton(frame, L["Untagged Only"])
    untaggedOnlyButton:SetWidth(118)
    untaggedOnlyButton:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
    untaggedOnlyButton:SetScript("OnClick", function()
        showUntaggedOnly = not showUntaggedOnly
        AltsTab:Refresh(true)
    end)
    untaggedOnlyButton:SetScript("OnLeave", paintUntaggedButton)

    summaryText = frame:CreateFontString(nil, "ARTWORK")
    summaryText:SetFontObject(Theme.font.muted)
    summaryText:SetJustifyH("RIGHT")
    summaryText:SetPoint("LEFT", untaggedOnlyButton, "RIGHT", 12, 0)
    summaryText:SetPoint("RIGHT")

    local headerRow = CreateFrame("Frame", nil, frame)
    headerRow:SetHeight(Theme.layout.rowHeight)
    headerRow:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -Theme.layout.gutter)
    headerRow:SetPoint("RIGHT")

    local function addLabel(text, x)
        local fs = headerRow:CreateFontString(nil, "ARTWORK")
        fs:SetFontObject(Theme.font.small)
        fs:SetJustifyH("LEFT")
        fs:SetPoint("LEFT", x, 0)
        fs:SetText(text)
        return fs
    end
    addLabel(L["Name"], COL.leftPad + COL.dotWidth + COL.gap)
    addLabel(L["Nickname"], COL.leftPad + COL.dotWidth + COL.gap + COL.nameWidth + COL.gap)
    addLabel(L["Alt / Main"], COL.leftPad + COL.dotWidth + COL.gap + COL.nameWidth + COL.gap + COL.nickWidth + COL.gap)

    local listArea = CreateFrame("Frame", nil, frame)
    listArea:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -4)
    listArea:SetPoint("TOPRIGHT", headerRow, "BOTTOMRIGHT", 0, -4)
    listArea:SetPoint("BOTTOM", frame, "BOTTOM", 0, DETAIL_HEIGHT + Theme.layout.gutter)

    list = GP.UI.ScrollList:New(listArea, ROW_HEIGHT, createAltRow)
    list:SetUpdateRow(updateAltRow)

    -- Detail / action panel
    local detail = Theme:CreatePanel(frame, "panel", "border")
    detail:SetHeight(DETAIL_HEIGHT)
    detail:SetPoint("BOTTOMLEFT")
    detail:SetPoint("BOTTOMRIGHT")

    detailHeading = detail:CreateFontString(nil, "ARTWORK")
    detailHeading:SetFontObject(Theme.font.heading)
    detailHeading:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    detailHeading:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    detailHeading:SetJustifyH("LEFT")

    -- Every form row below is anchored with a fixed vertical stride directly
    -- off detailHeading, NOT chained off the row above's own bottom edge.
    local ROW_STRIDE = 32
    local FIRST_ROW_Y = -18

    -- Nickname row
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
            AltsTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    -- Custom Guild Paragon note rows. These are addon-owned notes, never the
    -- protected Blizzard roster Note / Officer's Note fields.
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
            AltsTab:Refresh()
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
            AltsTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    officerNoteLockedText = detail:CreateFontString(nil, "ARTWORK")
    officerNoteLockedText:SetFontObject(Theme.font.small)
    officerNoteLockedText:SetPoint("LEFT", officerNoteLabel, "RIGHT", 8, 0)
    officerNoteLockedText:SetText(L["Officer-only notes require officer access."])
    officerNoteLockedText:SetTextColor(unpack(Theme.color.textSecondary))

    -- Alt/main row (three mutually-exclusive states, same anchor)
    altOfText = detail:CreateFontString(nil, "ARTWORK")
    altOfText:SetFontObject(Theme.font.body)
    altOfText:SetJustifyH("LEFT")
    altOfText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 3)

    altOfClearButton = Theme:CreateButton(detail, L["Clear"])
    altOfClearButton:SetPoint("LEFT", altOfText, "RIGHT", 8, 0)
    altOfClearButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        GP:GetModule("Alts"):ClearMain(guildKey, selectedGUID)
        setMainBox:SetText("") -- start fresh next time this row is shown
        setStatus(L["Cleared."])
        AltsTab:Refresh()
    end)

    altsOfMineText = detail:CreateFontString(nil, "ARTWORK")
    altsOfMineText:SetFontObject(Theme.font.body)
    altsOfMineText:SetJustifyH("LEFT")
    altsOfMineText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 3)
    altsOfMineText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    -- Deliberately no SetWordWrap(true): the name list above is capped to
    -- stay short enough for one line, and statusText below is anchored at
    -- a fixed offset that assumes this row's height never grows.
    altsOfMineText:SetWordWrap(false)

    setMainLabel = detail:CreateFontString(nil, "ARTWORK")
    setMainLabel:SetFontObject(Theme.font.small)
    setMainLabel:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 3)
    setMainLabel:SetText(L["Tag as alt of:"])

    setMainBox = Theme:CreateEditBox(detail, 140)
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
            setMainBox:SetText("") -- start fresh next time this row is shown
            setStatus(L["Saved."])
            hideSuggestions()
            AltsTab:Refresh()
        else
            setStatus(err, true)
        end
    end)

    -- Main toggle: shown in State C ("Mark as Main") or State B when the
    -- character is a main *only* because of this flag, with no real alts
    -- yet ("Unmark as Main") — hidden otherwise. One handler checks current
    -- state at click-time rather than being reassigned on every refresh.
    mainToggleButton = Theme:CreateButton(detail, L["Mark as Main"])
    mainToggleButton:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 4)
    mainToggleButton:SetScript("OnClick", function()
        local _, guildKey = getGuildData()
        local Alts = GP:GetModule("Alts")
        if Alts:IsMarkedMain(guildKey, selectedGUID) then
            Alts:UnsetAsMain(guildKey, selectedGUID)
            setStatus(L["Unmarked."])
        else
            local ok, err = Alts:SetAsMain(guildKey, selectedGUID)
            setStatus(ok and L["Marked as main."] or err, not ok)
        end
        AltsTab:Refresh()
    end)

    statusText = detail:CreateFontString(nil, "ARTWORK")
    statusText:SetFontObject(Theme.font.small)
    statusText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, FIRST_ROW_Y - ROW_STRIDE * 5)
    statusText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    statusText:SetJustifyH("LEFT")

    -- Autocomplete dropdown for setMainBox — built after setMainBox exists.
    AltsTab:BuildSuggestions(detail)

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua: a Guild Sync full-state apply can fire hundreds of
    -- these in one burst, and full-list refreshes that often in a row
    -- tripped WoW's "script ran too long" watchdog in live testing.
    local function debouncedRefresh()
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("AltsTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                AltsTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    AltsTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefresh)
    AltsTab:RegisterMessage("GuildParagon_AltsChanged", debouncedRefresh)
    AltsTab:RegisterMessage("GuildParagon_NicknamesChanged", debouncedRefresh)
    AltsTab:RegisterMessage("GuildParagon_CustomNotesChanged", debouncedRefresh)

    frame.OnSelected = function()
        if refreshDirty then
            refreshDirty = false
            AltsTab:Refresh()
        end
    end

    self:Refresh()
    return frame
end
