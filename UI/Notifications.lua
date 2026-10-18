-- Guild Paragon — login card, notification bell and Notifications settings.
local _, GP = ...
local Theme = GP.UI.Theme
local UI = {}
GP.UI.Notifications = UI

local CARD_WIDTH = 440
-- Card height is computed from the line count; body text is 12pt, and lines
-- are kept short enough not to wrap at this width.
local LINE_HEIGHT = 17
local CARD_CHROME = 76 + 66
-- At most this many upcoming dates are listed; the rest are summarised.
local UPCOMING_ROWS = 6

local LINE_TEXT = {
    join = "%d joined the guild",
    rejoin = "%d rejoined the guild",
    leave = "%d left the guild",
    removed = "%d removed from the guild",
    promote = "%d promoted",
    demote = "%d demoted",
    inactivereturn = "%d returned after a break",
    note = "Public notes changed for %d member(s)",
    officernote = "Officer notes changed for %d member(s)",
    remotealts = "Alt links changed by others for %d member(s)",
    banwarning = "%d Ban List match(es) joined the guild",
    ban = "%d Ban List change(s)",
}

local function awayText(since, builtAt)
    local L = GP.L
    local seconds = math.max(0, (builtAt or time()) - since)
    if seconds < 3600 then return L["under an hour"] end
    if seconds < 2 * 86400 then return string.format(L["%d hour(s)"], math.floor(seconds / 3600)) end
    return string.format(L["%d day(s)"], math.floor(seconds / 86400))
end

local function sinceHeading(summary)
    return string.format(GP.L["Since you were last on (%s ago):"], awayText(summary.since, summary.builtAt))
end

-- Guild change lines in display order, as localized strings, with their line
-- keys. Lines shown under "Needs attention" are left out.
function UI:FormatLines(summary)
    local L = GP.L
    local Notifications = GP:GetModule("Notifications")
    local lines, keys = {}, {}
    for _, line in ipairs(Notifications.LINES) do
        local count = summary.counts[line.key] or 0
        if count > 0 and not line.attention and not Notifications:IsHidden(Notifications.CATEGORY_OF[line.key]) then
            local text
            if line.key == "level" then
                text = string.format(summary.opts.allLevelUps and L["%d levelled up"] or L["%d reached max level"], count)
            elseif line.key == "removed" and Notifications.SoleRemover(summary) then
                text = string.format(L["%d removed from the guild by %s"], count, Notifications.SoleRemover(summary))
            else
                text = string.format(L[LINE_TEXT[line.key]], count)
            end
            table.insert(lines, text)
            table.insert(keys, line.key)
        end
    end
    return lines, keys
end

function UI:AttentionText(item)
    local L = GP.L
    if item.key == "applicants" then
        return string.format(L["%d application(s) awaiting review"], item.count)
    elseif item.key == "welcomes" then
        return string.format(L["%d recruit(s) waiting for a welcome"], item.count)
    elseif item.key == "listing" then
        if item.expired then return L["Guild Finder listing has expired"] end
        if item.days == 0 then return L["Guild Finder listing expires within a day"] end
        return string.format(L["Guild Finder listing expires in %d day(s)"], item.days)
    elseif item.key == "banwarning" then
        return string.format(L[LINE_TEXT.banwarning], item.count)
    end
    return ""
end

function UI:UpcomingText(row)
    local L = GP.L
    local when = row.daysRemaining == 0 and L["today"] or row.daysRemaining == 1 and L["tomorrow"]
        or string.format(L["in %d days"], row.daysRemaining)
    local what
    if row.type == "birthday" then
        what = string.format(L["%s's birthday"], row.name)
    else
        what = string.format(L["%s: %d year(s) in the guild"], row.name, tonumber(row.years) or 0)
    end
    return string.format(L["%s (%s)"], what, when)
end

-- Opens the Event Log on the entries behind one summary line, or all of them.
function UI:OpenEventLog(summary, lineKey, label)
    GP.UI.EventLogTab:SetFocus({since = summary.since, line = lineKey, opts = summary.opts,
        label = label or GP.L["Since you were last on"]})
    GP.UI.MainWindow:SelectTabByID("log")
end

function UI:OpenAttention(item, summary, text)
    if item.key == "applicants" then
        GP.UI.MainWindow:SelectTabByID("applications")
    elseif item.key == "welcomes" then
        GP.UI.MainWindow:SelectTabByID("recruitment")
    elseif item.key == "listing" then
        GP.UI.GuildRecruitment:Open()
    elseif item.key == "banwarning" and summary then
        self:OpenEventLog(summary, "banwarning", text)
    end
end

-- Login card: open attention items, then the guild changes since last online.
function UI:ShowSummary(summary, attention)
    local L = GP.L
    attention = attention or {}
    if not self.card then
        local card = Theme:CreateNotice({width = CARD_WIDTH, title = L["While you were away"],
            primaryLabel = L["Show details"]})
        card.primary:SetScript("OnClick", function()
            card:Hide()
            self:OpenNotifications()
        end)
        self.card = card
    end
    local parts, rows = {}, 0
    if #attention > 0 then
        parts[#parts + 1] = L["Needs attention:"]
        for _, item in ipairs(attention) do parts[#parts + 1] = "- " .. self:AttentionText(item) end
        rows = rows + #attention + 1
    end
    local lines = self:FormatLines(summary)
    if #lines > 0 or #attention == 0 then
        parts[#parts + 1] = sinceHeading(summary)
        if #lines == 0 then
            parts[#parts + 1] = L["No guild changes."]
        else
            for _, text in ipairs(lines) do parts[#parts + 1] = "- " .. text end
        end
        rows = rows + math.max(#lines, 1) + 1
    end
    self.card.body:SetText(table.concat(parts, "\n"))
    self.card:SetHeight(CARD_CHROME + rows * LINE_HEIGHT)
    self.card:Show()
end

-- Header bell: grey when there is nothing new, accent with a count badge when
-- there are unseen guild changes or open attention items. A soft pulsing glow
-- shows while any of it has not been seen yet. Clicking opens the flyout,
-- which marks everything in it seen.
local BELL_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\NotificationBell"
local DOT_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\NotificationDot"
local GLOW_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\NotificationGlow"
local FLYOUT_WIDTH = 340
local FLYOUT_ROW_HEIGHT = 24
local FLYOUT_TOP = 36
local FLYOUT_BOTTOM = 52
local FLYOUT_BOTTOM_PLAIN = 10

function UI:RefreshBell()
    local bell = self.bell
    if not bell then return end
    local module = GP:GetModule("Notifications")
    -- Anything arriving while the flyout is open is on screen, so it is seen.
    -- MarkRead announces the change, which calls back here; the guard keeps
    -- that to one pass even if something cannot be marked.
    if self.flyout and self.flyout:IsShown() and not self.markingRead and module:HasUnseen() then
        self.markingRead = true
        module:MarkRead()
        self.markingRead = false
    end
    local count = module:BadgeCount()
    bell.icon:SetVertexColor(unpack(count > 0 and Theme.color.accent or Theme.color.textSecondary))
    local glowing = (count > 0 or module.glowPreview) and module:HasUnseen()
    bell.glow:SetShown(glowing)
    if glowing and not bell.pulse:IsPlaying() then
        bell.pulse:Play()
    elseif not glowing and bell.pulse:IsPlaying() then
        bell.pulse:Stop()
    end
    bell.badge:SetShown(count > 0)
    bell.badgeText:SetShown(count > 0)
    bell.badgeText:SetText(count > 99 and "99+" or tostring(count))
    if self.flyout and self.flyout:IsShown() then self:RefreshFlyout() end
end

function UI:CreateBell(header)
    local bell = CreateFrame("Button", nil, header)
    bell:SetSize(22, 22)
    local glow = bell:CreateTexture(nil, "BACKGROUND")
    glow:SetSize(44, 44)
    glow:SetPoint("CENTER", bell, "CENTER", 0, 0)
    glow:SetTexture(GLOW_TEXTURE)
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(unpack(Theme.color.accent))
    glow:SetAlpha(0.35)
    glow:Hide()
    bell.glow = glow
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.35)
    fade:SetToAlpha(0.9)
    fade:SetDuration(1.1)
    fade:SetSmoothing("IN_OUT")
    bell.pulse = pulse
    local icon = bell:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(BELL_TEXTURE)
    bell.icon = icon

    local badge = bell:CreateTexture(nil, "OVERLAY")
    badge:SetSize(16, 16)
    badge:SetPoint("CENTER", bell, "TOPRIGHT", -2, -3)
    badge:SetTexture(DOT_TEXTURE)
    badge:SetVertexColor(unpack(Theme.color.accent))
    bell.badge = badge
    local badgeText = bell:CreateFontString(nil, "OVERLAY")
    badgeText:SetFontObject(Theme.font.small)
    badgeText:SetPoint("CENTER", badge, "CENTER", 0, 0)
    badgeText:SetTextColor(unpack(Theme.color.backdrop))
    bell.badgeText = badgeText

    bell:SetScript("OnEnter", function(selfButton)
        local module = GP:GetModule("Notifications")
        GameTooltip:SetOwner(selfButton, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText(GP.L["Notifications"])
        local unread = module:UnreadCount()
        if unread > 0 then
            GameTooltip:AddLine(string.format(GP.L["%d unread guild change(s)"], unread), 1, 1, 1)
        end
        for _, item in ipairs(module:CollectAttention()) do
            if item.key ~= "banwarning" then GameTooltip:AddLine(self:AttentionText(item), 1, 1, 1) end
        end
        GameTooltip:Show()
    end)
    bell:SetScript("OnLeave", GameTooltip_Hide)
    bell:SetScript("OnClick", function()
        if self.flyout and self.flyout:IsShown() then
            self.flyout:Hide()
        else
            self:ShowFlyout(header:GetParent(), bell)
        end
    end)

    self.bell = bell
    if not self.listening then
        self.listening = true
        LibStub("AceEvent-3.0"):Embed(self)
        self:RegisterMessage("GuildParagon_NotificationsChanged", "RefreshBell")
        self:RegisterMessage("GuildParagon_ApplicantsChanged", "RefreshBell")
        self:RegisterMessage("GuildParagon_RecruitmentChanged", "RefreshBell")
    end
    self:RefreshBell()
    return bell
end

-- Flyout rows are pooled and reused as section headings, notes or links.
local function createFlyoutRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(FLYOUT_ROW_HEIGHT)
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    local text = row:CreateFontString(nil, "ARTWORK")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text
    local arrow = row:CreateFontString(nil, "ARTWORK")
    arrow:SetFontObject(Theme.font.muted)
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetText(">")
    row.arrow = arrow
    -- Links are not a selection: hover feedback only.
    row:SetScript("OnEnter", function(selfRow)
        if selfRow.isLink then selfRow:SetBackdropColor(unpack(Theme.color.panelRaised)) end
    end)
    row:SetScript("OnLeave", function(selfRow) selfRow:SetBackdropColor(0, 0, 0, 0) end)
    return row
end

local function setFlyoutRow(row, entry)
    row.isLink = entry.onClick ~= nil
    row:SetBackdropColor(0, 0, 0, 0)
    row:EnableMouse(row.isLink)
    row.arrow:SetShown(row.isLink)
    if entry.heading then
        row.text:SetFontObject(Theme.font.small)
        row.text:SetTextColor(unpack(Theme.color.accent))
    elseif entry.note then
        row.text:SetFontObject(Theme.font.muted)
        row.text:SetTextColor(unpack(Theme.color.textSecondary))
    else
        row.text:SetFontObject(Theme.font.body)
        row.text:SetTextColor(unpack(Theme.color.textPrimary))
    end
    row.text:SetText(entry.text)
    row:SetScript("OnClick", entry.onClick)
    row:Show()
end

function UI:ShowFlyout(window, bell)
    if not self.flyout then
        local flyout = Theme:CreatePanel(window, "panelRaised", "border")
        flyout:SetWidth(FLYOUT_WIDTH)
        flyout:SetPoint("TOPRIGHT", bell, "BOTTOMRIGHT", 6, -8)
        flyout:SetFrameLevel(window:GetFrameLevel() + 60)
        flyout:EnableMouse(true)
        local title = flyout:CreateFontString(nil, "ARTWORK")
        title:SetFontObject(Theme.font.heading)
        title:SetPoint("TOPLEFT", 12, -12)
        title:SetText(GP.L["Notifications"])
        local open = Theme:CreateButton(flyout, GP.L["Open Event Log"])
        open:SetPoint("BOTTOMLEFT", 12, 12)
        open:SetScript("OnClick", function()
            local summary = GP:GetModule("Notifications").summary
            flyout:Hide()
            if summary then self:OpenEventLog(summary) end
        end)
        flyout.open = open
        flyout.rows = {}
        -- Closes on a fresh mouse press anywhere outside the flyout. The bell
        -- counts as inside so its own click still toggles the flyout.
        flyout:HookScript("OnShow", function(selfFlyout) selfFlyout.mouseWasDown = true end)
        flyout:SetScript("OnUpdate", function(selfFlyout)
            local down = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
            if down and not selfFlyout.mouseWasDown and not selfFlyout:IsMouseOver()
                and not (self.bell and self.bell:IsMouseOver()) then
                selfFlyout:Hide()
            end
            selfFlyout.mouseWasDown = down
        end)
        self.flyout = flyout
    end
    self.flyout:Show()
    self:RefreshFlyout()
    GP:GetModule("Notifications"):MarkRead()
end

-- Opens the main window with the flyout showing, e.g. from the login card.
function UI:OpenNotifications()
    GP.UI.MainWindow:Open()
    if self.bell then self:ShowFlyout(self.bell:GetParent():GetParent(), self.bell) end
end

function UI:BuildFlyoutEntries()
    local L = GP.L
    local module = GP:GetModule("Notifications")
    local summary = module.summary
    local entries = {}
    local function close() if self.flyout then self.flyout:Hide() end end

    local attention = module:CollectAttention()
    if #attention > 0 then
        entries[#entries + 1] = {heading = true, text = L["Needs attention"]}
        for _, item in ipairs(attention) do
            local text = self:AttentionText(item)
            entries[#entries + 1] = {text = text, onClick = function()
                close()
                self:OpenAttention(item, summary, text)
            end}
        end
    end

    local lines, keys = {}, {}
    if summary then
        lines, keys = self:FormatLines(summary)
        entries[#entries + 1] = {heading = true, text = sinceHeading(summary)}
    else
        entries[#entries + 1] = {heading = true, text = L["Since you were last on"]}
    end
    if not summary then
        entries[#entries + 1] = {note = true, text = L["The summary appears shortly after login."]}
    elseif #lines == 0 then
        entries[#entries + 1] = {note = true, text = L["No guild changes."]}
    end
    for index, text in ipairs(lines) do
        local key = keys[index]
        entries[#entries + 1] = {text = text, onClick = function()
            close()
            self:OpenEventLog(summary, key, text)
        end}
    end

    local upcoming = module:CollectUpcoming()
    if #upcoming > 0 then
        local function openUpcoming()
            close()
            GP.UI.GuildHealthTab:OpenPage("upcoming")
        end
        entries[#entries + 1] = {heading = true, text = L["Coming up (next 7 days)"]}
        for index, row in ipairs(upcoming) do
            if index > UPCOMING_ROWS then
                entries[#entries + 1] = {text = string.format(L["and %d more"], #upcoming - UPCOMING_ROWS), onClick = openUpcoming}
                break
            end
            entries[#entries + 1] = {text = self:UpcomingText(row), onClick = openUpcoming}
        end
    end
    return entries, #lines > 0
end

function UI:RefreshFlyout()
    local flyout = self.flyout
    local entries, hasLines = self:BuildFlyoutEntries()
    for index, entry in ipairs(entries) do
        local row = flyout.rows[index]
        if not row then
            row = createFlyoutRow(flyout)
            row:SetPoint("TOPLEFT", 4, -FLYOUT_TOP - (index - 1) * FLYOUT_ROW_HEIGHT)
            row:SetPoint("TOPRIGHT", -4, -FLYOUT_TOP - (index - 1) * FLYOUT_ROW_HEIGHT)
            flyout.rows[index] = row
        end
        setFlyoutRow(row, entry)
    end
    for index = #entries + 1, #flyout.rows do flyout.rows[index]:Hide() end
    flyout.open:SetShown(hasLines)
    flyout:SetHeight(FLYOUT_TOP + #entries * FLYOUT_ROW_HEIGHT + (hasLines and FLYOUT_BOTTOM or FLYOUT_BOTTOM_PLAIN))
end

-- Settings > Logs & Sync > Notifications. Built outside Settings:Build to keep
-- that function's upvalue count unchanged.
function UI:BuildSettings(section, createCheck, addOptionDescription)
    local L = GP.L
    local module = GP:GetModule("Notifications")
    local settings = module:Settings()

    local summaryCheck = createCheck(section, L["Summarise guild changes after login"], function(value)
        settings.loginSummary = value
    end)
    summaryCheck:SetPoint("TOPLEFT", section.heading, "BOTTOMLEFT", 0, -8)
    summaryCheck:SetChecked(settings.loginSummary)
    local summaryDesc = addOptionDescription(section, summaryCheck,
        L["Counts joins, leaves, rank changes and other guild changes since you were last online on any of your characters."], 380)

    local popupCheck = createCheck(section, L["Pop up the summary after login"], function(value)
        settings.loginPopup = value
    end)
    popupCheck:SetPoint("TOPLEFT", summaryDesc, "BOTTOMLEFT", -26, -8)
    popupCheck:SetChecked(module:WantsPopup())
    local popupDesc = addOptionDescription(section, popupCheck,
        L["On by default for officers and off for members. Shown out of combat, never during a loading screen or in an instance."], 380)

    local levelCheck = createCheck(section, L["Count every level-up"], function(value)
        settings.allLevelUps = value
    end)
    levelCheck:SetPoint("TOPLEFT", popupDesc, "BOTTOMLEFT", -26, -8)
    levelCheck:SetChecked(settings.allLevelUps)
    local levelDesc = addOptionDescription(section, levelCheck,
        L["When off, only members reaching the level cap are counted."], 380)

    local showButton = Theme:CreateButton(section, L["Show last summary"])
    showButton:SetPoint("TOPLEFT", levelDesc, "BOTTOMLEFT", -26, -12)
    showButton:SetScript("OnClick", function() module:ShowLastSummary() end)

    local chooseButton = Theme:CreateButton(section, L["Choose what's included"])
    chooseButton:SetPoint("LEFT", showButton, "RIGHT", 8, 0)
    local panel = self:BuildCategoryPanel(section, chooseButton, createCheck)
    chooseButton:SetScript("OnClick", function() panel:SetShown(not panel:IsShown()) end)

    section:HookScript("OnShow", function() popupCheck:SetChecked(module:WantsPopup()) end)
    section:HookScript("OnHide", function() panel:Hide() end)
end

-- Two-column panel of category switches, opening upwards from its button so
-- it stays inside the Settings window.
local CATEGORY_COLUMN_WIDTH = 230
local CATEGORY_ROW_HEIGHT = 26

function UI:BuildCategoryPanel(section, button, createCheck)
    local L = GP.L
    local module = GP:GetModule("Notifications")
    local categories = module.CATEGORIES
    local rows = math.ceil(#categories / 2)
    local panel = Theme:CreatePanel(section, "panelRaised", "border")
    panel:SetFrameStrata("DIALOG")
    panel:SetSize(CATEGORY_COLUMN_WIDTH * 2 + 24, 44 + rows * CATEGORY_ROW_HEIGHT + 44)
    panel:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, 6)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:Hide()

    local title = panel:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.heading)
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText(L["Include in notifications"])

    local checks = {}
    for index, category in ipairs(categories) do
        local check = createCheck(panel, L[category.label], function(value)
            module:SetHidden(category.key, not value)
        end)
        local column = (index - 1) % 2
        local row = math.floor((index - 1) / 2)
        check:SetPoint("TOPLEFT", 12 + column * CATEGORY_COLUMN_WIDTH, -40 - row * CATEGORY_ROW_HEIGHT)
        checks[category.key] = check
    end

    local done = Theme:CreateButton(panel, L["Done"])
    done:SetPoint("BOTTOMRIGHT", -12, 12)
    done:SetScript("OnClick", function() panel:Hide() end)
    panel:SetScript("OnShow", function()
        for key, check in pairs(checks) do check:SetChecked(not module:IsHidden(key)) end
    end)
    return panel
end
