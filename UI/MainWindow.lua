-- Guild Paragon — Main Window
-- The shell every feature UI plugs into: a custom-styled (not Blizzard
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.MainWindow = GP.UI.MainWindow or {}
local MainWindow = GP.UI.MainWindow

local ICON_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\GuildParagonIcon"
local DISCORD_URL = "https://discord.gg/U8mKfHpeeP"
local DISCORD_POPUP = "GUILDPARAGON_DISCORD_LINK"
local DISCORD_ICON_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\DiscordIcon"
local DISCORD_ICON_SIZE = 32

-- WoW cannot open web links, so the invite is shown pre-selected for copying.
-- Edits are reverted so the link cannot be changed by accident.
StaticPopupDialogs[DISCORD_POPUP] = StaticPopupDialogs[DISCORD_POPUP] or {
    text = GP.L["Join the Earthenmist Discord for support, feedback and updates. Press Ctrl+C to copy the link."],
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 260,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local editBox = self.editBox or self.EditBox
        if editBox then
            editBox:SetText(DISCORD_URL)
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    EditBoxOnTextChanged = function(editBox)
        if editBox:GetText() ~= DISCORD_URL then
            editBox:SetText(DISCORD_URL)
            editBox:HighlightText()
        end
    end,
    EditBoxOnEnterPressed = function() StaticPopup_Hide(DISCORD_POPUP) end,
    EditBoxOnEscapePressed = function() StaticPopup_Hide(DISCORD_POPUP) end,
}

local frame
local navButtons = {}     -- id -> nav button
local tabContent = {}     -- id -> content frame (built lazily, cached after)
local tabOrder = {}        -- ordered list of { id, label, build }
local activeTabID
local clearingOnHide = false

local function uiSettings()
    if not GP.db or not GP.db.profile then
        return { autoHideInCombat = true, scale = 1 }
    end

    GP.db.profile.ui = GP.db.profile.ui or {}
    local settings = GP.db.profile.ui
    if settings.autoHideInCombat == nil then settings.autoHideInCombat = true end

    settings.scale = tonumber(settings.scale) or 1
    if settings.scale < 0.50 then settings.scale = 0.50 end
    if settings.scale > 1.25 then settings.scale = 1.25 end
    return settings
end

function MainWindow:ApplySettings()
    if frame then
        frame:SetScale(uiSettings().scale)
        if Theme.RefreshBackdropTree then
            Theme:RefreshBackdropTree(frame)
        end
        GP:SendMessage("GuildParagon_MainWindowMoved")
    end
end

local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatcher:SetScript("OnEvent", function()
    if uiSettings().autoHideInCombat and frame and frame:IsShown() then
        MainWindow:Hide()
    end
end)

local guildContextWatcher = CreateFrame("Frame")
guildContextWatcher:RegisterEvent("PLAYER_GUILD_UPDATE")
guildContextWatcher:SetScript("OnEvent", function()
    if not frame then return end
    MainWindow:BuildSidebar()
    local content = activeTabID and tabContent[activeTabID]
    if content and content.OnAccessChanged then content:OnAccessChanged() end
end)

function MainWindow:RegisterTab(id, label, build, visible)
    table.insert(tabOrder, { id = id, label = label, build = build, visible = visible })
    if frame then
        self:BuildSidebar()
    end
end

function MainWindow:SetTabLabel(id, label)
    for _, entry in ipairs(tabOrder) do
        if entry.id == id then entry.label = label; break end
    end
    if navButtons[id] then navButtons[id].text:SetText(label) end
end

local function tabIsVisible(entry)
    return not entry.visible or entry.visible()
end

local function findTab(id)
    for _, entry in ipairs(tabOrder) do
        if entry.id == id then return entry end
    end
    return nil
end

local function createHeader(parent)
    local header = Theme:CreatePanel(parent, "panelRaised", "border")
    header:SetHeight(Theme.layout.headerHeight)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")

    local title = header:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.title)
    title:SetPoint("LEFT", Theme.layout.padding + 15, 0)
    title:SetText(GP.L["Guild Paragon"])

    local pulse = header:CreateTexture(nil, "ARTWORK")
    pulse:SetColorTexture(unpack(Theme.color.accent))
    pulse:SetSize(6, 6)
    pulse:SetPoint("RIGHT", title, "LEFT", -8, 0)

    local close = Theme:CreateCloseButton(header)
    close:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    close:SetScript("OnClick", function() MainWindow:Hide() end)

    local bell = GP.UI.Notifications:CreateBell(header)
    bell:SetPoint("RIGHT", close, "LEFT", -12, 0)

    header:EnableMouse(true)
    -- Secure overlays placed by position (housing visit, rank buttons) hide
    -- while the window moves and are placed again where it stops.
    header:SetScript("OnMouseDown", function()
        GP:SendMessage("GuildParagon_MainWindowMoving")
        frame:StartMoving()
    end)
    header:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        GP:SendMessage("GuildParagon_MainWindowMoved")
    end)

    return header
end

function MainWindow:SelectTab(id)
    if activeTabID == id then return end
    local entry = findTab(id)
    if not entry or not tabIsVisible(entry) then return end

    if GP.UI.MemberTooltip and GP.UI.MemberTooltip.HideMacroRules then
        GP.UI.MemberTooltip:HideMacroRules()
    end

    local previousContent = activeTabID and tabContent[activeTabID]
    if previousContent and previousContent.OnDeselected then
        previousContent:OnDeselected()
    end

    for tabID, content in pairs(tabContent) do
        if tabID ~= id then content:Hide() end
    end

    if not tabContent[id] then
        tabContent[id] = entry.build(frame.content)
    end
    tabContent[id]:Show()
    if tabContent[id].OnSelected then
        tabContent[id]:OnSelected()
    end

    for tabID, button in pairs(navButtons) do
        button:SetSelected(tabID == id)
    end

    activeTabID = id
end

function MainWindow:RebuildTab(id)
    local entry = findTab(id)
    if not entry then return false end

    local wasActive = activeTabID == id
    local content = tabContent[id]
    if content and content.OnDeselected then content:OnDeselected() end
    if content then
        content:Hide()
        content:SetParent(nil)
    end
    tabContent[id] = nil

    if wasActive then
        activeTabID = nil
        if tabIsVisible(entry) then
            self:SelectTab(id)
        else
            self:BuildSidebar()
        end
    end
    return true
end

function MainWindow:BuildSidebar()
    local sidebar = frame.sidebar
    for _, button in pairs(navButtons) do
        button:Hide()
        button:SetParent(nil)
    end
    wipe(navButtons)

    local previous
    local firstVisibleID
    for _, entry in ipairs(tabOrder) do
        if tabIsVisible(entry) and entry.id ~= "settings" and entry.id ~= "help" then
            firstVisibleID = firstVisibleID or entry.id
            local button = Theme:CreateNavButton(sidebar, entry.label)
            if previous then
                button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -1)
                button:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -1)
            else
                button:SetPoint("TOPLEFT")
                button:SetPoint("TOPRIGHT")
            end
            button:SetScript("OnClick", function() MainWindow:SelectTab(entry.id) end)
            navButtons[entry.id] = button
            previous = button
        end
    end

    local helpButton
    local helpEntry = findTab("help")
    if helpEntry and tabIsVisible(helpEntry) then
        firstVisibleID = firstVisibleID or helpEntry.id
        helpButton = Theme:CreateNavButton(sidebar, helpEntry.label)
        helpButton:SetPoint("BOTTOMLEFT")
        helpButton:SetPoint("BOTTOMRIGHT")
        helpButton:SetScript("OnClick", function() MainWindow:SelectTab(helpEntry.id) end)
        navButtons[helpEntry.id] = helpButton
    end

    local settingsEntry = findTab("settings")
    if settingsEntry and tabIsVisible(settingsEntry) then
        firstVisibleID = firstVisibleID or settingsEntry.id
        local button = Theme:CreateNavButton(sidebar, settingsEntry.label)
        if helpButton then
            button:SetPoint("BOTTOMLEFT", helpButton, "TOPLEFT", 0, 1)
            button:SetPoint("BOTTOMRIGHT", helpButton, "TOPRIGHT", 0, 1)
        else
            button:SetPoint("BOTTOMLEFT")
            button:SetPoint("BOTTOMRIGHT")
        end
        button:SetScript("OnClick", function() MainWindow:SelectTab(settingsEntry.id) end)
        navButtons[settingsEntry.id] = button
    end

    if activeTabID and not navButtons[activeTabID] then
        local content = tabContent[activeTabID]
        if content and content.OnAccessLost then content:OnAccessLost() end
        if content and content.OnDeselected then content:OnDeselected() end
        if content then
            content:Hide()
            content:SetParent(nil)
        end
        tabContent[activeTabID] = nil
        activeTabID = nil
    end

    if not activeTabID and firstVisibleID then
        self:SelectTab(firstVisibleID)
    elseif activeTabID and navButtons[activeTabID] then
        navButtons[activeTabID]:SetSelected(true)
    end
end

local function createFrame()
    frame = CreateFrame("Frame", "GuildParagonMainFrame", UIParent, "BackdropTemplate")
    -- Sized for the denser management tabs. Macro Tool in particular needs a
    -- persistent rule editor and a review list side by side without hiding
    -- critical safety options.
    frame:SetSize(1240, 780)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    if frame.SetMouseClickEnabled then frame:SetMouseClickEnabled(true) end
    if frame.SetMouseMotionEnabled then frame:SetMouseMotionEnabled(true) end
    if frame.SetPropagateMouseClicks then frame:SetPropagateMouseClicks(false) end
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetBackdrop((Theme:Backdrop("backdrop", "border")))
    frame:SetBackdropColor(unpack(Theme.color.backdrop))
    frame:SetBackdropBorderColor(unpack(Theme.color.border))
    frame:SetScript("OnHide", function()
        MainWindow:OnHide()
    end)
    frame:Hide()
    MainWindow:ApplySettings()

    tinsert(UISpecialFrames, "GuildParagonMainFrame")

    createHeader(frame)

    local sidebar = Theme:CreatePanel(frame, "panel", "border")
    sidebar:SetWidth(Theme.layout.sidebarWidth)
    sidebar:SetPoint("BOTTOMLEFT")
    sidebar:SetPoint("TOPLEFT", 0, -Theme.layout.headerHeight)
    frame.sidebar = sidebar

    local brandIcon = sidebar:CreateTexture(nil, "ARTWORK")
    brandIcon:SetTexture(ICON_TEXTURE)
    brandIcon:SetSize(96, 96)
    brandIcon:SetPoint("BOTTOM", 0, 98)
    brandIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    brandIcon:SetAlpha(0.9)
    sidebar.brandIcon = brandIcon
    MainWindow:ApplySeasonalArt(frame, sidebar)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", Theme.layout.padding, -Theme.layout.padding)
    content:SetPoint("BOTTOMRIGHT", -Theme.layout.padding, Theme.layout.padding)
    frame.content = content

    MainWindow:BuildSidebar()
end

-- During a seasonal theme: swaps the sidebar logo and adds faint corner
-- cobwebs. Webs are window and sidebar textures, so they sit behind every
-- control and panel and never cover text or take clicks.
local COBWEB_ALPHA = 0.16
local COBWEBS = {
    -- parent, size, anchor, x, y, texture coordinates (mirroring)
    { "frame", 120, "TOPRIGHT", 0, -Theme.layout.headerHeight, { 1, 0, 0, 1 } },
    { "frame", 84, "BOTTOMRIGHT", 0, 0, { 1, 0, 1, 0 } },
    { "sidebar", 72, "BOTTOMLEFT", 0, 0, { 0, 1, 1, 0 } },
}

function MainWindow:ApplySeasonalArt(mainFrame, sidebar)
    local art = Theme.activeSeason and Theme.seasonalArt[Theme.activeSeason]
    if not art then return false end
    if art.logo then
        sidebar.brandIcon:SetTexture(art.logo)
    end
    if art.cobweb then
        local parents = { frame = mainFrame, sidebar = sidebar }
        for _, spec in ipairs(COBWEBS) do
            local web = parents[spec[1]]:CreateTexture(nil, "BORDER")
            web:SetTexture(art.cobweb)
            web:SetSize(spec[2], spec[2])
            web:SetPoint(spec[3], spec[4], spec[5])
            web:SetTexCoord(unpack(spec[6]))
            web:SetAlpha(COBWEB_ALPHA)
        end
    end
    return true
end

-- Icon button that opens the Discord invite popup; the caller anchors it.
function MainWindow:CreateDiscordButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(DISCORD_ICON_SIZE, DISCORD_ICON_SIZE)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(DISCORD_ICON_TEXTURE)
    icon:SetAlpha(0.85)
    button:SetScript("OnClick", function()
        StaticPopup_Show(DISCORD_POPUP)
    end)
    button:SetScript("OnEnter", function(self)
        icon:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(GP.L["Earthenmist Discord"])
        GameTooltip:AddLine(GP.L["Support, feedback and update news."], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        icon:SetAlpha(0.85)
        GameTooltip_Hide()
    end)
    return button
end

function MainWindow:Toggle()
    if not frame then
        createFrame()
    end
    if frame:IsShown() then
        self:Hide()
    else
        self:BuildSidebar()
        self:ApplySettings()
        if GP.UI.MemberTooltip then
            GP.UI.MemberTooltip:Hide()
        end
        frame:Show()
        if activeTabID and tabContent[activeTabID] and tabContent[activeTabID].OnSelected then
            tabContent[activeTabID]:OnSelected()
        end
    end
end

function MainWindow:Hide()
    if frame then frame:Hide() end
end

-- Shows the window without changing the selected tab.
function MainWindow:Open()
    if not frame or not frame:IsShown() then self:Toggle() end
end

function MainWindow:OnHide()
    if clearingOnHide then return end
    clearingOnHide = true

    if GP.UI.MemberTooltip and GP.UI.MemberTooltip.HideMacroRules then
        GP.UI.MemberTooltip:HideMacroRules()
    end

    local activeContent = activeTabID and tabContent[activeTabID]
    if activeContent and activeContent.OnDeselected then
        activeContent:OnDeselected()
    end

    local MacroTool = GP.GetModule and GP:GetModule("MacroTool", true)
    if MacroTool and MacroTool.SetMacroToolVisible then
        pcall(function()
            MacroTool:SetMacroToolVisible(false)
        end)
    end
    if MacroTool and MacroTool.ClearExecutionMacro then
        pcall(function()
            MacroTool:ClearExecutionMacro()
        end)
    end

    clearingOnHide = false
end

function MainWindow:SelectTabByID(id)
    if not frame then
        createFrame()
    end
    self:ApplySettings()
    if GP.UI.MemberTooltip then
        GP.UI.MemberTooltip:Hide()
    end
    frame:Show()
    self:SelectTab(id)
end
