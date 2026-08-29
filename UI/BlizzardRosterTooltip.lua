-- Guild Paragon — Blizzard guild roster tooltip integration
--
-- Reuses UI/MemberTooltip.lua for the default Retail Guild & Communities
-- roster. This never clicks protected Blizzard controls; tooltip actions only
-- touch Guild Paragon's own UI/data.
local _, GP = ...

local MemberTooltip = GP.UI.MemberTooltip
local Theme = GP.UI.Theme
local ICON_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\GuildParagonIcon"
local hookedRows = {}
local lastRow, lastGUID
local launcher
local hoverToggle
local frameHooksInstalled
local blizzardTooltipVisible
local lastDetailVisible
local lastTooltipInteraction = 0
local TOOLTIP_IDLE_SECONDS = 10

local function settings()
    GP.db.profile.roster = GP.db.profile.roster or {}
    GP.db.profile.roster.display = GP.db.profile.roster.display or {}
    local s = GP.db.profile.roster.display
    if s.blizzardTooltips == nil then s.blizzardTooltips = true end
    return s
end

local function anchorLauncher()
    if not launcher or not CommunitiesFrame then return end

    launcher:ClearAllPoints()
    if CommunitiesFrame.GuildInfoTab then
        launcher:SetPoint("TOP", CommunitiesFrame.GuildInfoTab, "BOTTOM", 0, -10)
    else
        launcher:SetPoint("TOPRIGHT", CommunitiesFrame, "TOPRIGHT", -4, -232)
    end
end

local function getGuildData()
    if not IsInGuild() then return nil, nil end
    local Roster = GP:GetModule("Roster")
    local guildKey = Roster.currentGuildKey or Roster:GetGuildKey()
    return guildKey, guildKey and GP.db.global.guilds[guildKey] or nil
end

local function findPlayer(memberInfo)
    local guildKey, guildData = getGuildData()
    if not guildData or type(memberInfo) ~= "table" then return nil, nil end

    local guid = GP:SafeOptionalString(memberInfo.guid) or GP:SafeOptionalString(memberInfo.GUID) or GP:SafeOptionalString(memberInfo.playerGUID)
    if guid then
        local player = guildData.roster[guid] or guildData.formerMembers[guid]
        if player then return player, guildKey end
    end

    local name = GP:SafeOptionalString(memberInfo.name)
    if not name or name == "" then return nil, nil end
    local _, player = GP:GetModule("Roster"):FindPlayerByName(guildData, name, true)
    return player, player and guildKey or nil
end

local function isGuildRosterVisible()
    if not CommunitiesFrame or not CommunitiesFrame.MemberList or not CommunitiesFrame.MemberList.ScrollBox then
        return false
    end
    if not CommunitiesFrame:IsVisible() or not CommunitiesFrame.MemberList.ScrollBox:IsVisible() then
        return false
    end

    local selectedClubID = GP:SafeCall(CommunitiesFrame.GetSelectedClubId and function() return CommunitiesFrame:GetSelectedClubId() end, nil)
    local guildClubID = GP:SafeCall(C_Club and C_Club.GetGuildClubId, nil)
    return selectedClubID == nil or guildClubID == nil or tostring(selectedClubID) == tostring(guildClubID)
end

local function isGuildParagonWindowMouseOver()
    local mainFrame = _G.GuildParagonMainFrame
    return mainFrame and mainFrame:IsShown() and mainFrame:IsMouseOver()
end

local function clearBlizzardTooltipState()
    MemberTooltip:Hide()
    lastRow, lastGUID, lastDetailVisible = nil, nil, nil
    blizzardTooltipVisible = false
end

local function showForRow(row)
    if not isGuildRosterVisible() then return end
    if not settings().blizzardTooltips then
        clearBlizzardTooltipState()
        return
    end
    if isGuildParagonWindowMouseOver() then
        clearBlizzardTooltipState()
        return
    end

    local player, guildKey = findPlayer(row.memberInfo)
    if not player then
        if lastRow == row then
            clearBlizzardTooltipState()
        end
        return
    end

    local detail = CommunitiesFrame and CommunitiesFrame.GuildMemberDetailFrame
    local detailVisible = detail and detail:IsVisible() or false
    if lastRow ~= row or lastGUID ~= player.guid or lastDetailVisible ~= detailVisible then
        MemberTooltip:ShowForPlayer(row, player, guildKey, "communities")
        lastRow, lastGUID = row, player.guid
        lastDetailVisible = detailVisible
        blizzardTooltipVisible = true
    end
    lastTooltipInteraction = time()
end

local function hideForRow(row)
    if lastRow == row then
        local list = CommunitiesFrame and CommunitiesFrame.MemberList and CommunitiesFrame.MemberList.ScrollBox
        local detail = CommunitiesFrame and CommunitiesFrame.GuildMemberDetailFrame
        if detail and detail:IsVisible() then
            MemberTooltip:HideSoon(detail)
        else
            MemberTooltip:HideSoon(list or row)
        end
        lastRow, lastGUID, lastDetailVisible = nil, nil, nil
    end
end

local function hookRow(row)
    if hookedRows[row] then return end
    hookedRows[row] = true

    row:HookScript("OnEnter", showForRow)
    row:HookScript("OnLeave", hideForRow)
    row:HookScript("OnHide", function(self)
        if lastRow == self then
            MemberTooltip:Hide()
            lastRow, lastGUID, lastDetailVisible = nil, nil, nil
            blizzardTooltipVisible = false
        end
    end)
    row:HookScript("OnUpdate", function(self)
        if self:IsMouseOver() then
            showForRow(self)
        elseif lastRow == self then
            hideForRow(self)
        end
    end)
end

local function hookVisibleRows()
    if not isGuildRosterVisible() then
        if lastRow then
            clearBlizzardTooltipState()
        end
        return
    end

    CommunitiesFrame.MemberList.ScrollBox:ForEachFrame(hookRow)
end

local function hideIfPointerLeftRoster()
    if not blizzardTooltipVisible then return end
    if isGuildParagonWindowMouseOver() then
        clearBlizzardTooltipState()
        return
    end

    local list = CommunitiesFrame and CommunitiesFrame.MemberList and CommunitiesFrame.MemberList.ScrollBox
    local detail = CommunitiesFrame and CommunitiesFrame.GuildMemberDetailFrame
    if list and list:IsVisible() and list:IsMouseOver() then
        lastTooltipInteraction = time()
        return
    end
    if detail and detail:IsVisible() and detail:IsMouseOver() then
        lastTooltipInteraction = time()
        return
    end
    if MemberTooltip:IsMouseOver() then
        lastTooltipInteraction = time()
        return
    end

    if MemberTooltip:IsSticky() and time() - lastTooltipInteraction < TOOLTIP_IDLE_SECONDS then return end

    MemberTooltip:Hide()
    lastRow, lastGUID, lastDetailVisible = nil, nil, nil
    blizzardTooltipVisible = false
end

local function createHoverToggle()
    if hoverToggle or not CommunitiesFrame then return end

    local parent = CommunitiesFrame.TitleContainer or CommunitiesFrame.PortraitOverlay or CommunitiesFrame
    hoverToggle = CreateFrame("CheckButton", "GuildParagonCommunitiesMouseoverToggle", parent, "InterfaceOptionsCheckButtonTemplate")
    hoverToggle:SetSize(20, 20)
    hoverToggle:SetHitRectInsets(-92, 1, 1, 1)
    hoverToggle:SetFrameLevel((parent:GetFrameLevel() or CommunitiesFrame:GetFrameLevel() or 1) + 5)

    hoverToggle.text = hoverToggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hoverToggle.text:SetPoint("RIGHT", hoverToggle, "LEFT", -3, 0)
    hoverToggle.text:SetText(GP.L["Show Mouseover"])

    hoverToggle:SetScript("OnClick", function(self)
        local enabled = self:GetChecked() and true or false
        settings().blizzardTooltips = enabled
        hoverToggle.text:SetTextColor(1, enabled and 0.82 or 0.2, 0, 1)
        if not enabled then
            MemberTooltip:Hide()
            lastRow, lastGUID, lastDetailVisible = nil, nil, nil
            blizzardTooltipVisible = false
        end
    end)
    hoverToggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(GP.L["Show Guild Paragon roster tooltip on mouseover."])
        GameTooltip:Show()
    end)
    hoverToggle:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function updateHoverToggle()
    createHoverToggle()
    if not hoverToggle or not CommunitiesFrame then return end

    hoverToggle:ClearAllPoints()
    local nextToButton = CommunitiesFrame.MaximizeMinimizeFrame and CommunitiesFrame.MaximizeMinimizeFrame.MinimizeButton
    if nextToButton then
        hoverToggle:SetPoint("RIGHT", nextToButton, "LEFT", -14, 0)
    else
        hoverToggle:SetPoint("TOPRIGHT", CommunitiesFrame, "TOPRIGHT", -44, -14)
    end

    local enabled = settings().blizzardTooltips
    hoverToggle:SetChecked(enabled)
    hoverToggle.text:SetTextColor(1, enabled and 0.82 or 0.2, 0, 1)
    hoverToggle:SetShown(isGuildRosterVisible())
end

local function installFrameHooks()
    if frameHooksInstalled or not CommunitiesFrame then return end
    frameHooksInstalled = true

    local function hideTooltip()
        MemberTooltip:Hide()
        lastRow, lastGUID, lastDetailVisible = nil, nil, nil
        blizzardTooltipVisible = false
        lastTooltipInteraction = 0
    end

    CommunitiesFrame:HookScript("OnHide", hideTooltip)

    if CommunitiesFrame.MemberList and CommunitiesFrame.MemberList.ScrollBox then
        CommunitiesFrame.MemberList.ScrollBox:HookScript("OnHide", hideTooltip)
    end

    if CommunitiesFrame.GuildBenefitsTab then
        CommunitiesFrame.GuildBenefitsTab:HookScript("OnClick", hideTooltip)
    end
    if CommunitiesFrame.GuildInfoTab then
        CommunitiesFrame.GuildInfoTab:HookScript("OnClick", hideTooltip)
    end
    if CommunitiesFrame.ChatTab then
        CommunitiesFrame.ChatTab:HookScript("OnClick", hideTooltip)
    end
    if CommunitiesFrame.RecruitmentDialog then
        CommunitiesFrame.RecruitmentDialog:HookScript("OnShow", hideTooltip)
    end

    local hideOnShowFrames = {
        "GuildParagonMainFrame",
        "CharacterFrame",
        "SpellBookFrame",
        "QuestLogFrame",
        "FriendsFrame",
        "PVEFrame",
        "EncounterJournal",
        "CollectionsJournal",
        "ProfessionsFrame",
        "AuctionHouseFrame",
        "MailFrame",
        "BankFrame",
    }
    for _, frameName in ipairs(hideOnShowFrames) do
        local otherFrame = _G[frameName]
        if otherFrame and otherFrame.HookScript then
            otherFrame:HookScript("OnShow", hideTooltip)
        end
    end
end

local function createLauncher()
    if launcher or not CommunitiesFrame then return end

    launcher = CreateFrame("Button", "GuildParagonCommunitiesOpenButton", CommunitiesFrame, "BackdropTemplate")
    launcher:SetSize(36, 36)
    launcher:SetFrameStrata(CommunitiesFrame:GetFrameStrata() or "MEDIUM")
    launcher:SetFrameLevel((CommunitiesFrame:GetFrameLevel() or 1) + 3)
    launcher:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    launcher:SetBackdropColor(0.03, 0.04, 0.05, 0.86)
    launcher:SetBackdropBorderColor(0.10, 0.34, 0.32, 0.45)
    anchorLauncher()

    local icon = launcher:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", launcher, "CENTER", 1, -1)
    icon:SetSize(30, 30)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    launcher.icon = icon

    launcher:SetScript("OnClick", function()
        MemberTooltip:Hide()
        lastRow, lastGUID, lastDetailVisible = nil, nil, nil
        blizzardTooltipVisible = false
        GP.UI.MainWindow:SelectTabByID("roster")
    end)
    launcher:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.24, 0.85, 0.75, 0.80)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(GP.L["Open Guild Paragon"])
        GameTooltip:Show()
    end)
    launcher:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.10, 0.34, 0.32, 0.45)
        GameTooltip:Hide()
    end)
end

local function updateLauncher()
    createLauncher()
    updateHoverToggle()
    if launcher then
        anchorLauncher()
        launcher:SetShown(isGuildRosterVisible())
    end
end

local watcher = CreateFrame("Frame")
watcher.timer = 0
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("GUILD_ROSTER_UPDATE")
watcher:SetScript("OnEvent", function(_, event)
    installFrameHooks()
    updateLauncher()
    hookVisibleRows()
end)
watcher:SetScript("OnUpdate", function(self, elapsed)
    self.timer = self.timer + elapsed
    if self.timer < 0.25 then return end
    self.timer = 0
    installFrameHooks()
    updateLauncher()
    hookVisibleRows()
    hideIfPointerLeftRoster()
end)
