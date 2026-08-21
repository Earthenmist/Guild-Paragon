-- Guild Paragon — Member tooltip
--
-- Hover popup for Guild Paragon's roster rows and Blizzard's Retail Guild &
-- Communities roster. It keeps protected Blizzard roster actions untouched,
-- but can edit Guild Paragon's own alt/main tags.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.MemberTooltip = GP.UI.MemberTooltip or {}
local MemberTooltip = GP.UI.MemberTooltip

local WIDTH = 390
local frame
local altLines = {}
local activeAnchor, activePlayer, activeGuildKey
local setAltEditorOpen
local macroIgnoreFrame
local macroIgnoreChecks = {}
local macroIgnoreStatuses = {}
local macroIgnoreOwner
local hideSerial = 0

local function getCommunitiesMemberDetailFrame()
    local detail = CommunitiesFrame and CommunitiesFrame.GuildMemberDetailFrame
    if detail and detail:IsVisible() then
        return detail
    end
    return nil
end

local function placeFrame(f, anchorFrame, mode)
    f:ClearAllPoints()

    if mode == "communities" and CommunitiesFrame and CommunitiesFrame:IsVisible() then
        local detail = getCommunitiesMemberDetailFrame()
        if detail then
            local right = detail:GetRight()
            if right and (right + WIDTH > GetScreenWidth()) then
                f:SetPoint("TOPRIGHT", detail, "TOPLEFT", -6, 5)
            else
                f:SetPoint("TOPLEFT", detail, "TOPRIGHT", -2, 5)
            end
        else
            local x = 34
            local right = CommunitiesFrame:GetRight()
            if right and (right + x + WIDTH > GetScreenWidth()) then
                f:SetPoint("TOPRIGHT", CommunitiesFrame, "TOPLEFT", -8, 5)
            else
                f:SetPoint("TOPLEFT", CommunitiesFrame, "TOPRIGHT", x, 5)
            end
        end
        return
    end

    local anchorRight = anchorFrame:GetRight()
    if anchorRight and (anchorRight + WIDTH > GetScreenWidth()) then
        f:SetPoint("TOPRIGHT", anchorFrame, "TOPLEFT", -6, 6)
    else
        f:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 6, 6)
    end
end

local function setTooltipLayerForMode(f, mode)
    local mainFrame = _G.GuildParagonMainFrame
    if mode == "communities" and mainFrame and mainFrame:IsShown() then
        f:SetFrameStrata(mainFrame:GetFrameStrata() or "HIGH")
        f:SetFrameLevel(math.max(1, (mainFrame:GetFrameLevel() or 1) - 1))
        return
    end
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(1)
end

local function classColorOf(classFile)
    local c = classFile and C_ClassColor.GetClassColor(classFile)
    if c then return c.r, c.g, c.b end
    return unpack(Theme.color.textPrimary)
end

local function setTextColor(fs, colorKey)
    fs:SetTextColor(unpack(Theme.color[colorKey]))
end

local function createText(parent, font, justify)
    local fs = parent:CreateFontString(nil, "ARTWORK")
    fs:SetFontObject(font)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(false)
    return fs
end

local function createSectionLabel(parent, text)
    local fs = createText(parent, Theme.font.small)
    setTextColor(fs, "warning")
    fs:SetText(text)
    return fs
end

local function createCheck(parent, label, onClick)
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

local function formatDuration(seconds)
    local L = GP.L
    if seconds < 60 then
        return L["less than a minute"]
    elseif seconds < 3600 then
        return string.format(L["%d minute(s)"], math.floor(seconds / 60))
    elseif seconds < 86400 then
        return string.format(L["%d hour(s)"], math.floor(seconds / 3600))
    end
    return string.format(L["%d day(s)"], math.floor(seconds / 86400))
end

local function formatLastOnlineTime(lastOnlineTime)
    if type(lastOnlineTime) ~= "table" then return nil end

    local years = tonumber(lastOnlineTime[1]) or 0
    local months = tonumber(lastOnlineTime[2]) or 0
    local days = tonumber(lastOnlineTime[3]) or 0
    local hours = tonumber(lastOnlineTime[4]) or 0
    local parts = {}

    if months == 12 then
        years = years + 1
        months = 0
    end
    if years > 0 then
        table.insert(parts, years .. (years == 1 and " yr" or " yrs"))
    end
    if months > 0 then
        table.insert(parts, months .. (months == 1 and " mo" or " mos"))
    end
    if days > 0 then
        table.insert(parts, days .. (days == 1 and " day" or " days"))
    end
    if hours > 0 and years < 1 and months < 1 then
        table.insert(parts, hours .. (hours == 1 and " hr" or " hrs"))
    end

    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

local function formatDate(ts)
    return ts and date("%d %b '%y", ts) or GP.L["Unknown"]
end

local function formatBirthday(player)
    local info = player.birthdayInfo
    if type(info) == "table" and type(info.date) == "table" and (info.date[1] or 0) > 0 and (info.date[2] or 0) > 0 then
        return string.format("%02d/%02d", info.date[1], info.date[2])
    end
    return GP.L["Unknown"]
end

local function latestRankDate(player)
    local hist = player.rankHistory
    local entry = type(hist) == "table" and hist[#hist]
    return entry and entry.ts
end

local function findPlayer(guildData, guid)
    return guildData and (guildData.roster[guid] or guildData.formerMembers[guid])
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

local function findPlayerByName(guildData, name)
    if not guildData then return nil end

    local needle = strtrim(name or ""):lower()
    if needle == "" then return nil end

    local function matches(player)
        local full = (player.name or ""):lower()
        local short = full:match("^([^-]+)") or full
        return full == needle or short == needle
    end

    for _, player in pairs(guildData.roster) do
        if matches(player) then return player end
    end
    for _, player in pairs(guildData.formerMembers) do
        if matches(player) then return player end
    end
    return nil
end

local function addTopStat(parent, point, label)
    local title = createText(parent, Theme.font.small, "CENTER")
    setTextColor(title, "warning")
    title:SetPoint(unpack(point))
    title:SetWidth(108)
    title:SetText(label)

    local value = createText(parent, Theme.font.body, "CENTER")
    value:SetPoint("TOP", title, "BOTTOM", 0, -2)
    value:SetWidth(108)

    return value
end

local function syncMacroIgnoreFrame()
    if not macroIgnoreFrame or not activeGuildKey or not activePlayer then return end

    local MacroTool = GP:GetModule("MacroTool")
    if not MacroTool:CanUse() then
        macroIgnoreFrame:Hide()
        return
    end

    for action, check in pairs(macroIgnoreChecks) do
        local ignored = MacroTool:IsPlayerIgnored(activeGuildKey, activePlayer.guid, action)
        check:SetChecked(ignored)
        local status = macroIgnoreStatuses[action]
        if status then
            status:SetText(ignored and GP.L["Ignoring"] or GP.L["Monitoring"])
            status:SetTextColor(unpack(ignored and Theme.color.danger or Theme.color.accent))
        end
    end
end

local function buildMacroIgnoreFrame()
    if macroIgnoreFrame then return macroIgnoreFrame end

    local f = Theme:CreatePanel(UIParent, "panelRaised", "accent")
    f:SetFrameStrata("TOOLTIP")
    f:SetSize(360, 150)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:Hide()
    f:SetScript("OnEnter", function()
        hideSerial = hideSerial + 1
    end)
    f:SetScript("OnLeave", function()
        MemberTooltip:HideSoon(activeAnchor)
    end)
    f:SetScript("OnUpdate", function(self, elapsed)
        self.closeCheckElapsed = (self.closeCheckElapsed or 0) + elapsed
        if self.closeCheckElapsed < 0.2 then return end
        self.closeCheckElapsed = 0

        if self:IsMouseOver() then return end
        if macroIgnoreOwner and macroIgnoreOwner:IsShown() and macroIgnoreOwner:IsMouseOver() then return end
        if frame and frame:IsShown() and frame:IsMouseOver() then return end
        self:Hide()
    end)

    local close = Theme:CreateCloseButton(f)
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)

    local title = createText(f, Theme.font.title, "CENTER")
    title:SetPoint("TOP", 0, -10)
    title:SetWidth(300)
    title:SetText(GP.L["Macro Rule Ignore Lists"])

    local subtitle = createText(f, Theme.font.small, "CENTER")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    subtitle:SetWidth(310)
    subtitle:SetText(GP.L["Select categories you wish this player to be ignored from."])

    local rows = {
        { action = "kick", label = GP.L["Kick Rules"] },
        { action = "promote", label = GP.L["Promote Rules"] },
        { action = "demote", label = GP.L["Demote Rules"] },
    }

    local previous
    for _, row in ipairs(rows) do
        local check = createCheck(f, row.label, function(value)
            local ok, err = GP:GetModule("MacroTool"):SetPlayerIgnore(activeGuildKey, activePlayer and activePlayer.guid, row.action, value)
            if not ok then GP:Print(err) end
            syncMacroIgnoreFrame()
        end)
        if previous then
            check:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -7)
        else
            check:SetPoint("TOPLEFT", 26, -62)
        end
        macroIgnoreChecks[row.action] = check

        local status = createText(f, Theme.font.body, "CENTER")
        status:SetPoint("LEFT", check.text, "RIGHT", 22, 0)
        status:SetWidth(112)
        macroIgnoreStatuses[row.action] = status
        previous = check
    end

    macroIgnoreFrame = f
    return f
end

local function showMacroIgnoreFrame(owner)
    if not activePlayer or not activeGuildKey then return end
    if not GP:GetModule("MacroTool"):CanUse() then return end

    local f = buildMacroIgnoreFrame()
    macroIgnoreOwner = owner
    f:ClearAllPoints()
    if owner.guildParagonMacroRulesAnchor == "above" then
        f:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", 0, 6)
    else
        f:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -6)
    end
    syncMacroIgnoreFrame()
    f:Show()
end

function MemberTooltip:ShowMacroRulesForPlayer(anchorFrame, player, guildKey)
    if not anchorFrame or not player or not guildKey then return false end
    if not GP:GetModule("MacroTool"):CanUse() then return false end

    activeAnchor, activePlayer, activeGuildKey = anchorFrame, player, guildKey
    showMacroIgnoreFrame(anchorFrame)
    return true
end

function MemberTooltip:HideMacroRules()
    macroIgnoreOwner = nil
    if macroIgnoreFrame then macroIgnoreFrame:Hide() end
end

local function build()
    if frame then return frame end

    frame = CreateFrame("Frame", "GuildParagonMemberTooltip", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("TOOLTIP")
    frame:SetWidth(WIDTH)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetBackdrop((Theme:Backdrop("backdrop", "accent")))
    frame:SetBackdropColor(unpack(Theme.color.backdrop))
    frame:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    frame:Hide()
    frame:SetScript("OnEnter", function()
        hideSerial = hideSerial + 1
    end)
    frame:SetScript("OnLeave", function()
        MemberTooltip:HideSoon(activeAnchor)
    end)

    frame.headerAccent = frame:CreateTexture(nil, "ARTWORK")
    frame.headerAccent:SetColorTexture(unpack(Theme.color.accent))
    frame.headerAccent:SetPoint("TOPLEFT", 1, -1)
    frame.headerAccent:SetPoint("TOPRIGHT", -1, -1)
    frame.headerAccent:SetHeight(2)

    frame.closeButton = Theme:CreateCloseButton(frame)
    frame.closeButton:SetPoint("TOPRIGHT", -8, -8)
    frame.closeButton:SetScript("OnClick", function()
        MemberTooltip:Hide()
    end)
    frame.closeButton:Hide()

    frame.role = createText(frame, Theme.font.small, "CENTER")
    setTextColor(frame.role, "danger")
    frame.role:SetPoint("TOP", 0, -8)
    frame.role:SetWidth(120)

    frame.lastOnline = addTopStat(frame, { "TOPLEFT", frame, "TOPLEFT", 12, -22 }, GP.L["Last Online"])
    frame.dateJoined = addTopStat(frame, { "TOPRIGHT", frame, "TOPRIGHT", -12, -22 }, GP.L["Date Joined"])

    frame.name = createText(frame, Theme.font.title, "CENTER")
    frame.name:SetPoint("TOP", 0, -26)
    frame.name:SetWidth(160)

    frame.level = createText(frame, Theme.font.body, "CENTER")
    frame.level:SetPoint("TOP", frame.name, "BOTTOM", 0, -2)
    frame.level:SetWidth(180)

    frame.rank = createText(frame, Theme.font.title, "CENTER")
    setTextColor(frame.rank, "warning")
    frame.rank:SetPoint("TOP", frame.level, "BOTTOM", 0, -2)
    frame.rank:SetWidth(220)

    frame.promoted = createText(frame, Theme.font.small, "CENTER")
    frame.promoted:SetPoint("TOP", frame.rank, "BOTTOM", 0, -3)
    frame.promoted:SetWidth(180)

    frame.zoneLabel = createSectionLabel(frame, GP.L["Zone:"])
    frame.zoneLabel:SetPoint("TOPLEFT", 16, -118)
    frame.zone = createText(frame, Theme.font.body)
    frame.zone:SetPoint("LEFT", frame.zoneLabel, "RIGHT", 6, 0)
    frame.zone:SetWidth(150)

    frame.timeInLabel = createSectionLabel(frame, GP.L["Time In:"])
    frame.timeInLabel:SetPoint("TOPLEFT", frame.zoneLabel, "BOTTOMLEFT", 0, -3)
    frame.timeIn = createText(frame, Theme.font.body)
    frame.timeIn:SetPoint("LEFT", frame.timeInLabel, "RIGHT", 6, 0)
    frame.timeIn:SetWidth(150)

    frame.noteLabel = createSectionLabel(frame, GP.L["Note:"])
    frame.noteLabel:SetPoint("TOPLEFT", frame.timeInLabel, "BOTTOMLEFT", 0, -18)
    frame.note = createText(frame, Theme.font.body)
    frame.note:SetPoint("TOPLEFT", frame.noteLabel, "BOTTOMLEFT", 0, -6)
    frame.note:SetWidth(172)

    frame.customLabel = createSectionLabel(frame, GP.L["Custom Public Notes:"])
    frame.customLabel:SetPoint("TOPLEFT", frame.note, "BOTTOMLEFT", 0, -24)
    frame.custom = createText(frame, Theme.font.body)
    frame.custom:SetPoint("TOPLEFT", frame.customLabel, "BOTTOMLEFT", 0, -8)
    frame.custom:SetWidth(172)
    frame.custom:SetWordWrap(true)

    frame.officerLabel = createSectionLabel(frame, GP.L["Officer's Note:"])
    frame.officerLabel:SetPoint("TOPLEFT", 218, -155)
    frame.officer = createText(frame, Theme.font.body)
    frame.officer:SetPoint("TOPLEFT", frame.officerLabel, "BOTTOMLEFT", 0, -6)
    frame.officer:SetWidth(150)
    frame.officer:SetWordWrap(true)

    frame.altsLabel = createSectionLabel(frame, GP.L["Player Alts"])
    frame.altsLabel:SetPoint("TOPLEFT", 218, -205)
    frame.altsLabel:SetWidth(150)
    frame.altsLabel:SetJustifyH("CENTER")

    frame.addAltButton = Theme:CreateButton(frame, GP.L["Add Alt"])
    frame.addAltButton:SetPoint("BOTTOMLEFT", 132, 12)
    frame.addAltButton:SetScript("OnClick", function()
        if not activePlayer or not activeGuildKey then return end
        setAltEditorOpen(not frame.altEditorOpen)
        MemberTooltip:ShowForPlayer(activeAnchor, activePlayer, activeGuildKey)
    end)

    frame.macroRulesButton = Theme:CreateButton(frame, GP.L["Macro Rules"])
    frame.macroRulesButton:SetPoint("BOTTOMLEFT", 16, 12)
    frame.macroRulesButton:SetScript("OnClick", function()
        showMacroIgnoreFrame(frame)
    end)

    frame.mainButton = Theme:CreateButton(frame, GP.L["Mark as Main"])
    frame.mainButton:SetPoint("BOTTOMRIGHT", -16, 12)
    frame.mainButton:SetScript("OnClick", function()
        if not activePlayer or not activeGuildKey then return end

        local Alts = GP:GetModule("Alts")
        local altCount = #Alts:GetAlts(activeGuildKey, activePlayer.guid)
        local ok, err
        if Alts:IsMarkedMain(activeGuildKey, activePlayer.guid) and altCount == 0 then
            ok, err = Alts:UnsetAsMain(activeGuildKey, activePlayer.guid)
            GP:Print(ok and GP.L["Unmarked."] or err)
        else
            ok, err = Alts:SetAsMain(activeGuildKey, activePlayer.guid)
            GP:Print(ok and GP.L["Marked as main."] or err)
        end

        MemberTooltip:ShowForPlayer(activeAnchor, activePlayer, activeGuildKey)
    end)

    frame.addAltBox = Theme:CreateEditBox(frame, 142)
    frame.addAltBox:SetPoint("BOTTOMLEFT", 16, 44)
    frame.addAltBox:SetScript("OnEnterPressed", function(self)
        frame.addAltSetButton:Click()
        self:ClearFocus()
    end)
    frame.addAltBox:SetScript("OnEscapePressed", function(self)
        setAltEditorOpen(false)
        MemberTooltip:ShowForPlayer(activeAnchor, activePlayer, activeGuildKey)
        self:ClearFocus()
    end)

    frame.addAltSetButton = Theme:CreateButton(frame, GP.L["Set"])
    frame.addAltSetButton:SetPoint("LEFT", frame.addAltBox, "RIGHT", 6, 0)
    frame.addAltSetButton:SetScript("OnClick", function()
        if not activePlayer or not activeGuildKey then return end

        local guildData = GP.db.global.guilds[activeGuildKey]
        local typedPlayer = findPlayerByName(guildData, frame.addAltBox:GetText())
        if not typedPlayer then
            GP:Print(GP.L["Player not found."])
            return
        end

        local Alts = GP:GetModule("Alts")
        local activeMainGUID = Alts:GetMain(activeGuildKey, activePlayer.guid)
        local activeAltCount = #Alts:GetAlts(activeGuildKey, activePlayer.guid)
        local typedIsAlt = Alts:GetMain(activeGuildKey, typedPlayer.guid) ~= nil
        local typedIsKnownMain = Alts:IsMain(activeGuildKey, typedPlayer.guid)

        local makeHoveredPlayerAlt = not activeMainGUID
            and activeAltCount == 0
            and activePlayer.guid ~= typedPlayer.guid
            and not typedIsAlt
            and typedIsKnownMain

        local ok, err
        if makeHoveredPlayerAlt then
            if Alts:IsMarkedMain(activeGuildKey, activePlayer.guid) then
                local unmarked, unmarkErr = Alts:UnsetAsMain(activeGuildKey, activePlayer.guid)
                if not unmarked then
                    GP:Print(unmarkErr)
                    return
                end
            end
            ok, err = Alts:SetMain(activeGuildKey, activePlayer.guid, typedPlayer.guid)
        else
            local targetMainGUID = frame.addAltTargetMainGUID or activePlayer.guid
            ok, err = Alts:SetMain(activeGuildKey, typedPlayer.guid, targetMainGUID)
        end

        GP:Print(ok and GP.L["Saved."] or err)
        if ok then
            setAltEditorOpen(false)
            MemberTooltip:ShowForPlayer(activeAnchor, activePlayer, activeGuildKey)
        end
    end)

    frame.addAltCancelButton = Theme:CreateButton(frame, GP.L["Cancel"])
    frame.addAltCancelButton:SetPoint("LEFT", frame.addAltSetButton, "RIGHT", 6, 0)
    frame.addAltCancelButton:SetScript("OnClick", function()
        setAltEditorOpen(false)
        MemberTooltip:ShowForPlayer(activeAnchor, activePlayer, activeGuildKey)
    end)

    setAltEditorOpen = function(open)
        frame.altEditorOpen = open and true or false
        if frame.altEditorOpen then
            frame.addAltBox:SetText("")
            frame.addAltBox:Show()
            frame.addAltSetButton:Show()
            frame.addAltCancelButton:Show()
            frame.addAltBox:SetFocus()
        else
            frame.addAltBox:Hide()
            frame.addAltSetButton:Hide()
            frame.addAltCancelButton:Hide()
        end
    end
    setAltEditorOpen(false)

    return frame
end

local function setButtonText(button, text)
    button.text:SetText(text)
    button:SetWidth(button.text:GetStringWidth() + 32)
end

local function setTopStats(f, player)
    local L = GP.L
    local lastOnlineText = formatLastOnlineTime(player.lastOnlineTime)
    if player.online then
        f.lastOnline:SetText(L["Online"])
        setTextColor(f.lastOnline, "success")
    elseif lastOnlineText then
        f.lastOnline:SetText(lastOnlineText)
        setTextColor(f.lastOnline, "textPrimary")
    else
        f.lastOnline:SetText(L["Unknown"])
        setTextColor(f.lastOnline, "textSecondary")
    end

    f.dateJoined:SetText(formatDate(player.firstSeen))
    setTextColor(f.dateJoined, "textPrimary")
end

local function populateAlts(f, guildData, guildKey, player)
    for _, line in ipairs(altLines) do line:Hide() end

    local Alts = GP:GetModule("Alts")
    local altGUIDs = activeAltGUIDsFor(guildData, Alts:GetAlts(guildKey, player.guid))
    if #altGUIDs == 0 then
        local mainGUID = Alts:GetMain(guildKey, player.guid)
        if mainGUID then altGUIDs = { mainGUID } end
    end

    table.sort(altGUIDs, function(a, b)
        local pa, pb = findPlayer(guildData, a), findPlayer(guildData, b)
        return (pa and pa.name or "") < (pb and pb.name or "")
    end)

    local max = #altGUIDs
    for i = 1, max do
        local altPlayer = findPlayer(guildData, altGUIDs[i])
        if altPlayer then
            local line = altLines[i]
            if not line then
                line = createText(f, Theme.font.small, "CENTER")
                line:SetWidth(74)
                altLines[i] = line
            end
            local col = ((i - 1) % 2)
            local row = math.floor((i - 1) / 2)
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", f.altsLabel, "BOTTOMLEFT", col * 78, -6 - row * 14)
            line:SetText(altPlayer.name:gsub("%-.*", ""))
            line:SetTextColor(classColorOf(altPlayer.class))
            line:Show()
        end
    end
    return math.ceil(max / 2)
end

function MemberTooltip:ShowForPlayer(anchorFrame, player, guildKey, mode)
    if not player or not guildKey then return end

    local f = build()
    local L = GP.L
    local Nicknames = GP:GetModule("Nicknames")
    local Alts = GP:GetModule("Alts")
    local CustomNotes = GP:GetModule("CustomNotes")
    local guildData = GP.db.global.guilds[guildKey]
    if f.editorGUID ~= player.guid then
        setAltEditorOpen(false)
    end
    f.editorGUID = player.guid
    f.sticky = mode == "communities"
    if f.sticky then
        f.closeButton:Show()
    else
        f.closeButton:Hide()
    end
    activeAnchor, activePlayer, activeGuildKey = anchorFrame, player, guildKey
    if macroIgnoreFrame and macroIgnoreFrame:IsShown() then
        macroIgnoreFrame:ClearAllPoints()
        macroIgnoreFrame:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -6)
        syncMacroIgnoreFrame()
    end

    local nickname = Nicknames:Get(guildKey, player.guid)
    local displayName = (nickname ~= "") and nickname or player.name:gsub("%-.*", "")
    local mainGUID = Alts:GetMain(guildKey, player.guid)
    f.addAltTargetMainGUID = mainGUID or player.guid
    local roleText = ""
    if Alts:IsMain(guildKey, player.guid) then
        roleText = L["(Main)"]
    elseif mainGUID then
        local mainPlayer = findPlayer(guildData, mainGUID)
        roleText = string.format(L["(Alt of %s)"], mainPlayer and mainPlayer.name:gsub("%-.*", "") or "?")
    end

    f.role:SetText(roleText)
    f.name:SetText(displayName)
    f.name:SetTextColor(classColorOf(player.class))
    f.level:SetText(string.format(L["Level: %d"], player.level or 0))
    f.rank:SetText('"' .. (player.rankName or "?") .. '"')
    f.promoted:SetText(string.format(L["Promoted: %s"], formatDate(latestRankDate(player))))

    local customNote = CustomNotes:Get(guildKey, player.guid)
    setTopStats(f, player)

    f.zone:SetText((player.zone and player.zone ~= "") and player.zone or L["Unknown"])
    if player.online and player.timeEnteredZone then
        f.timeIn:SetText(formatDuration(time() - player.timeEnteredZone))
    elseif player.online then
        f.timeIn:SetText(L["Online"])
    else
        f.timeIn:SetText(L["Offline"])
    end

    f.note:SetText((player.note and player.note ~= "") and player.note or "")
    if CustomNotes:CanAccessOfficerNotes() then
        f.officerLabel:Show()
        f.officer:Show()
        f.officer:SetText((player.officerNote and player.officerNote ~= "") and player.officerNote or "")
    else
        f.officerLabel:Hide()
        f.officer:Hide()
        f.officer:SetText("")
    end

    f.custom:SetText(customNote ~= "" and customNote or "")
    local altRows = populateAlts(f, guildData, guildKey, player)

    local canUseMacroTool = GP:GetModule("MacroTool"):CanUse()
    if canUseMacroTool then
        f.macroRulesButton:Show()
    else
        f.macroRulesButton:Hide()
        if macroIgnoreFrame then macroIgnoreFrame:Hide() end
    end

    local isOfficer = GP:IsOfficer()
    local myAlts = Alts:GetAlts(guildKey, player.guid)
    if not isOfficer then
        f.addAltButton:Hide()
        f.mainButton:Hide()
        setAltEditorOpen(false)
    elseif mainGUID then
        f.addAltButton:Show()
        f.mainButton:Hide()
    else
        f.addAltButton:Show()
        if Alts:IsMarkedMain(guildKey, player.guid) and #myAlts == 0 then
            setButtonText(f.mainButton, L["Unmark as Main"])
            f.mainButton:SetAlpha(1)
            f.mainButton:Enable()
            f.mainButton:Show()
        elseif Alts:IsMain(guildKey, player.guid) then
            setButtonText(f.mainButton, L["Main"])
            f.mainButton:SetAlpha(0.55)
            f.mainButton:Disable()
            f.mainButton:Show()
        else
            setButtonText(f.mainButton, L["Mark as Main"])
            f.mainButton:SetAlpha(1)
            f.mainButton:Enable()
            f.mainButton:Show()
        end
    end

    setTooltipLayerForMode(f, mode)
    placeFrame(f, anchorFrame, mode)

    local customHeight = f.custom:GetStringHeight() or 0
    local editorHeight = f.altEditorOpen and 36 or 0
    local contentHeight = math.max(330 + editorHeight, 274 + customHeight + editorHeight, 270 + altRows * 14 + editorHeight)
    local screenHeight = (UIParent and UIParent:GetHeight()) or GetScreenHeight() or 768
    f:SetHeight(math.min(contentHeight, math.max(330, screenHeight - 40)))
    f:Show()
end

function MemberTooltip:HideSoon(anchorFrame)
    hideSerial = hideSerial + 1
    local serial = hideSerial
    C_Timer.After(0.12, function()
        if serial ~= hideSerial or not frame or not frame:IsShown() then return end
        if frame.sticky then return end
        if frame:IsMouseOver() then return end
        if macroIgnoreFrame and macroIgnoreFrame:IsShown() and macroIgnoreFrame:IsMouseOver() then return end
        if anchorFrame and anchorFrame:IsShown() and anchorFrame:IsMouseOver() then return end
        MemberTooltip:Hide()
    end)
end

function MemberTooltip:Hide()
    hideSerial = hideSerial + 1
    activeAnchor, activePlayer, activeGuildKey = nil, nil, nil
    MemberTooltip:HideMacroRules()
    if frame then
        frame.sticky = false
        frame.closeButton:Hide()
        frame:Hide()
    end
end

function MemberTooltip:IsMouseOver()
    return frame and frame:IsShown() and frame:IsMouseOver()
end

function MemberTooltip:IsSticky()
    return frame and frame:IsShown() and frame.sticky
end
