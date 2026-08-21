-- Guild Paragon - roster row context menu
-- A Guild Paragon-owned menu for right-clicking rows in UI/RosterTab.lua.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.RosterContextMenu = GP.UI.RosterContextMenu or {}
local RosterContextMenu = GP.UI.RosterContextMenu

local MENU_WIDTH = 190
local HEADER_HEIGHT = 28
local GROUP_HEIGHT = 20
local ROW_HEIGHT = 24
local DIVIDER_HEIGHT = 7
local MENU_PADDING = 8
local COPY_NAME_POPUP = "GUILDPARAGON_COPY_CHARACTER_NAME"

local panel
local rows = {}
local mouseWasDown = false

local function trim(value)
    return strtrim(tostring(value or ""))
end

local function fullPlayerName(player)
    local name = trim(player and player.name)
    if name == "" then return nil end

    local Roster = GP:GetModule("Roster", true)
    if Roster and Roster.SanitizeName then
        name = Roster:SanitizeName(name) or name
    end

    if not name:find("-", 1, true) and GetNormalizedRealmName then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then
            name = name .. "-" .. realm
        end
    end
    return name
end

local function displayPlayerName(player)
    return trim(player and player.name) ~= "" and trim(player.name) or GP.L["Unknown"]
end

local function classColorOf(player)
    local c = player and player.class and C_ClassColor and C_ClassColor.GetClassColor(player.class)
    if c then return c.r, c.g, c.b end
    return unpack(Theme.color.textPrimary)
end

local function safeCallAction(label, target, fn)
    local ok, err = pcall(fn)
    if not ok then
        GP:Print(string.format(GP.L["%s failed for %s: %s"], label, target or GP.L["Unknown"], tostring(err or GP.L["Unknown error."])))
    end
end

local function isSelfOrLinkedCharacter(player)
    local targetGUID = player and player.guid
    local playerGUID = UnitGUID and UnitGUID("player")
    if targetGUID and playerGUID and targetGUID == playerGUID then return true end
    if not targetGUID or not playerGUID then return false end

    local Roster = GP:GetModule("Roster", true)
    local Alts = GP:GetModule("Alts", true)
    if not Roster or not Alts or not Roster.GetGuildKey then return false end

    local guildKey = Roster:GetGuildKey()
    if not guildKey then return false end

    local playerMain = Alts:GetMain(guildKey, playerGUID) or playerGUID
    local targetMain = Alts:GetMain(guildKey, targetGUID) or targetGUID
    return playerMain == targetMain
end

local function canAddFriend(player)
    if isSelfOrLinkedCharacter(player) then return false end
    return ((C_FriendList and C_FriendList.AddFriend) or AddFriend) and true or false
end

local function canViewHouses(player)
    return player and player.guid and C_Housing and C_Housing.GetOthersOwnedHouses and ShowUIPanel and true or false
end

StaticPopupDialogs[COPY_NAME_POPUP] = StaticPopupDialogs[COPY_NAME_POPUP] or {
    text = GP.L["Copy Character Name"],
    button1 = GP.L["Close"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    hasEditBox = true,
    editBoxWidth = 220,
    OnShow = function(self, name)
        local editBox = self.editBox or self.EditBox
        if editBox then
            editBox:SetText(name or "")
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    OnHide = function(self)
        local editBox = self.editBox or self.EditBox
        if editBox then editBox:ClearFocus() end
    end,
}

local function whisper(target)
    if ChatFrame_SendTell then
        ChatFrame_SendTell(target)
        return
    end
    if ChatFrame_OpenChat then
        ChatFrame_OpenChat("/w " .. target .. " ")
        return
    end
    error(GP.L["Whisper API is not available."])
end

local function invite(target)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(target)
        return
    end
    if InviteUnit then
        InviteUnit(target)
        return
    end
    error(GP.L["Invite API is not available."])
end

local function addFriend(target)
    if C_FriendList and C_FriendList.AddFriend then
        C_FriendList.AddFriend(target)
        return
    end
    if AddFriend then
        AddFriend(target)
        return
    end
    error(GP.L["Friend API is not available."])
end

local function ignore(target)
    if C_FriendList and C_FriendList.AddIgnore then
        C_FriendList.AddIgnore(target)
        return
    end
    if AddIgnore then
        AddIgnore(target)
        return
    end
    error(GP.L["Ignore API is not available."])
end

local function copyName(target)
    if C_Clipboard and C_Clipboard.SetText then
        local ok, copied = pcall(C_Clipboard.SetText, target)
        if ok and copied ~= false then return end
    end
    StaticPopup_Show(COPY_NAME_POPUP, target, nil, target)
end

local function viewHouses(target, player)
    if not canViewHouses(player) then
        error(GP.L["View Houses API is not available."])
    end

    if not HouseListFrame then
        if C_AddOns and C_AddOns.LoadAddOn then
            C_AddOns.LoadAddOn("Blizzard_HouseList")
        elseif LoadAddOn then
            LoadAddOn("Blizzard_HouseList")
        end
    end

    if not HouseListFrame or not HouseListFrame.InitWithContextData then
        error(GP.L["View Houses API is not available."])
    end

    ShowUIPanel(HouseListFrame)
    HouseListFrame:InitWithContextData(target, player.guid, nil, true)
end

local function ensurePanel()
    if panel then return panel end

    panel = Theme:CreatePanel(UIParent, "panelRaised", "accent")
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(200)
    panel:SetWidth(MENU_WIDTH)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:Hide()

    panel:SetScript("OnUpdate", function(self)
        local isDown = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
        if isDown and not mouseWasDown and not self:IsMouseOver() then
            self:Hide()
        end
        mouseWasDown = isDown
    end)

    return panel
end

local function acquireRow(index)
    local row = rows[index]
    if row then
        row:Show()
        return row
    end

    row = CreateFrame("Button", nil, ensurePanel(), "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", MENU_PADDING, 0)
    row:SetPoint("RIGHT", -MENU_PADDING, 0)

    row.text = row:CreateFontString(nil, "ARTWORK")
    row.text:SetFontObject(Theme.font.body)
    row.text:SetJustifyH("LEFT")
    row.text:SetPoint("LEFT", 6, 0)
    row.text:SetPoint("RIGHT", -6, 0)
    row.text:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if self.isAction then
            self:SetBackdropColor(unpack(Theme.color.accentDim))
            self:SetBackdropBorderColor(unpack(Theme.color.accent))
        end
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(0, 0, 0, 0)
    end)

    rows[index] = row
    return row
end

local function configureHeader(row, player)
    row:SetHeight(HEADER_HEIGHT)
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row:EnableMouse(false)
    row.isAction = false
    row:SetScript("OnClick", nil)
    row.text:SetFontObject(Theme.font.heading)
    row.text:SetText(displayPlayerName(player))
    row.text:SetTextColor(classColorOf(player))
end

local function configureGroup(row, label)
    row:SetHeight(GROUP_HEIGHT)
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row:EnableMouse(false)
    row.isAction = false
    row:SetScript("OnClick", nil)
    row.text:SetFontObject(Theme.font.small)
    row.text:SetText(GP.L[label])
    row.text:SetTextColor(unpack(Theme.color.accent))
end

local function configureDivider(row)
    row:SetHeight(DIVIDER_HEIGHT)
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row:EnableMouse(false)
    row.isAction = false
    row:SetScript("OnClick", nil)
    row.text:SetText("")
end

local function configureAction(row, label, callback)
    row:SetHeight(ROW_HEIGHT)
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row:EnableMouse(true)
    row.isAction = true
    row.text:SetFontObject(Theme.font.body)
    row.text:SetText(GP.L[label])
    row.text:SetTextColor(unpack(Theme.color.textPrimary))
    row:SetScript("OnClick", function()
        RosterContextMenu:Hide()
        callback()
    end)
end

local function addRow(index, y, kind, ...)
    local row = acquireRow(index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", MENU_PADDING, y)
    row:SetPoint("RIGHT", panel, "RIGHT", -MENU_PADDING, 0)

    if kind == "header" then
        configureHeader(row, ...)
    elseif kind == "group" then
        configureGroup(row, ...)
    elseif kind == "divider" then
        configureDivider(row)
    else
        configureAction(row, ...)
    end
    return y - row:GetHeight(), index + 1
end

function RosterContextMenu:Hide()
    if panel then panel:Hide() end
end

function RosterContextMenu:ShowForPlayer(anchor, player)
    if not anchor or not player then return end

    panel = ensurePanel()
    panel:Hide()

    local target = fullPlayerName(player)
    if not target then return end

    local index, y = 1, -MENU_PADDING
    y, index = addRow(index, y, "header", player)
    y, index = addRow(index, y, "divider")

    if canAddFriend(player) then
        y, index = addRow(index, y, "action", "Add Friend", function()
            safeCallAction(GP.L["Add Friend"], target, function() addFriend(target) end)
        end)
        y, index = addRow(index, y, "divider")
    end

    local canTargetSocially = not isSelfOrLinkedCharacter(player)
    local canInvite = canTargetSocially and player.online
    local canIgnore = canTargetSocially and ((C_FriendList and C_FriendList.AddIgnore) or AddIgnore)
    local canWhisper = player.online
    local canViewPlayerHouses = canViewHouses(player)
    if canInvite or canWhisper or canIgnore or canViewPlayerHouses then
        y, index = addRow(index, y, "group", "Interact")
        if canInvite then
            y, index = addRow(index, y, "action", "Invite", function()
                safeCallAction(GP.L["Invite"], target, function() invite(target) end)
            end)
        end
        if canWhisper then
            y, index = addRow(index, y, "action", "Whisper", function()
                safeCallAction(GP.L["Whisper"], target, function() whisper(target) end)
            end)
        end
        if canIgnore then
            y, index = addRow(index, y, "action", "Ignore", function()
                safeCallAction(GP.L["Ignore"], target, function() ignore(target) end)
            end)
        end
        if canViewPlayerHouses then
            y, index = addRow(index, y, "action", "View Houses", function()
                safeCallAction(GP.L["View Houses"], target, function() viewHouses(target, player) end)
            end)
        end
        y, index = addRow(index, y, "divider")
    end

    y, index = addRow(index, y, "group", "Other Options")
    y, index = addRow(index, y, "action", "Copy Character Name", function()
        copyName(target)
    end)

    for i = index, #rows do
        rows[i]:Hide()
    end

    panel:SetHeight(math.abs(y) + MENU_PADDING)
    panel:ClearAllPoints()
    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (cursorX / scale) + 6, (cursorY / scale) - 6)
    mouseWasDown = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
    panel:Show()
end
