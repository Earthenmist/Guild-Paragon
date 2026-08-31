-- Guild Paragon - Recruitment context menu integration
local _, GP = ...

local RecruitmentContext = GP:NewModule("RecruitmentContext", "AceEvent-3.0")

local MENU_KEYS = {
    "PLAYER",
    "FRIEND",
    "PARTY",
    "RAID_PLAYER",
    "RAID",
    "GUILD",
    "GUILD_OFFLINE",
    "CHAT_ROSTER",
    "COMMUNITIES_WOW_MEMBER",
    "COMMUNITIES_GUILD_MEMBER",
    "BN_FRIEND",
    "TARGET",
    "FOCUS",
}

local function trim(value)
    return strtrim(GP:SafeString(value, ""))
end

local function protectedContentActive()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    return false
end

local function appendRealm(name, realm)
    name = trim(name)
    realm = trim(realm)
    if name == "" then return nil end
    if not name:find("-", 1, true) and realm ~= "" then
        name = name .. "-" .. realm
    elseif not name:find("-", 1, true) and GetNormalizedRealmName then
        local localRealm = GetNormalizedRealmName()
        if localRealm and localRealm ~= "" then
            name = name .. "-" .. localRealm
        end
    end
    return name
end

local function resolveFullName(context, unit, fallbackName)
    unit = GP:SafeOptionalString(unit)
    local name = GP:SafeOptionalString(fallbackName)
    local realm

    if type(context) == "table" then
        name = GP:SafeOptionalString(context.name) or GP:SafeOptionalString(context.fullName) or name
        realm = GP:SafeOptionalString(context.server) or GP:SafeOptionalString(context.realm) or GP:SafeOptionalString(context.realmName)
        unit = GP:SafeOptionalString(context.unit) or unit
    end

    if unit and UnitExists and UnitExists(unit) and UnitName then
        local ok, unitName, unitRealm = pcall(UnitName, unit)
        if not ok then
            unitName, unitRealm = nil, nil
        end
        unitName = GP:SafeOptionalString(unitName)
        unitRealm = GP:SafeOptionalString(unitRealm)
        if unitName and unitName ~= "" then
            name = unitName
            realm = unitRealm or realm
        end
    end

    return appendRealm(name, realm)
end

local function normalized(name)
    local Roster = GP:GetModule("Roster", true)
    if Roster and Roster.NormalizePlayerName then
        return Roster:NormalizePlayerName(name)
    end
    return trim(name):lower()
end

local function isSelf(fullName, unit)
    if unit and UnitIsUnit and UnitIsUnit(unit, "player") then return true end
    local playerName
    if UnitFullName then
        local name, realm = UnitFullName("player")
        playerName = appendRealm(name, realm)
    elseif UnitName then
        playerName = appendRealm(UnitName("player"))
    end
    return playerName and normalized(playerName) == normalized(fullName)
end

local function isCurrentGuildMember(fullName, unit)
    if unit and UnitIsInMyGuild and UnitIsInMyGuild(unit) then return true end
    local Roster = GP:GetModule("Roster", true)
    local guildKey = Roster and (Roster.currentGuildKey or (Roster.GetGuildKey and Roster:GetGuildKey()))
    local guildData = guildKey and GP.db and GP.db.global and GP.db.global.guilds and GP.db.global.guilds[guildKey]
    if Roster and Roster.FindPlayerByName and guildData then
        return Roster:FindPlayerByName(guildData, fullName, false) and true or false
    end
    return false
end

local function canShowFor(fullName, unit)
    if not fullName or fullName == "" then return false end
    if isSelf(fullName, unit) then return false end
    if isCurrentGuildMember(fullName, unit) then return false end
    local Recruitment = GP:GetModule("Recruitment", true)
    return Recruitment and Recruitment.CanUse and Recruitment:CanUse()
end

local function retailMenusEnabled()
    local Recruitment = GP:GetModule("Recruitment", true)
    local settings = Recruitment and Recruitment.GetSettings and Recruitment:GetSettings()
    return settings and settings.retailContextMenus and true or false
end

local function queueCandidate(fullName, openRecruitment)
    local Recruitment = GP:GetModule("Recruitment", true)
    if not Recruitment or not Recruitment.AddContextCandidateToQueue then return end
    local ok, err = Recruitment:AddContextCandidateToQueue(fullName, openRecruitment)
    if not ok and err then GP:Print(err) end
end

local function addToBlacklist(fullName)
    local Recruitment = GP:GetModule("Recruitment", true)
    if not Recruitment or not Recruitment.AddContextBlacklist then return end
    local ok, err = Recruitment:AddContextBlacklist(fullName)
    if not ok and err then GP:Print(err) end
end

local function injectRetailMenu(_, root, context)
    if protectedContentActive() then return end
    if not retailMenusEnabled() then return end
    if not root or not root.CreateButton then return end
    local unit = type(context) == "table" and GP:SafeOptionalString(context.unit) or nil
    local fullName = resolveFullName(context, unit)
    if not canShowFor(fullName, unit) then return end

    if root.CreateDivider then root:CreateDivider() end
    if root.CreateTitle then root:CreateTitle(GP.L["Guild Paragon"]) end
    root:CreateButton(GP.L["Queue for Recruitment"], function()
        queueCandidate(fullName, false)
    end)
    root:CreateButton(GP.L["Queue and Open Recruitment"], function()
        queueCandidate(fullName, true)
    end)
    root:CreateButton(GP.L["Add to Blacklist"], function()
        addToBlacklist(fullName)
    end)
end

local function addClassicSeparator(level)
    if UIDropDownMenu_AddSeparator then
        UIDropDownMenu_AddSeparator(level)
        return
    end
    local info = UIDropDownMenu_CreateInfo()
    info.text = ""
    info.isTitle = true
    info.notCheckable = true
    info.isUninteractable = true
    UIDropDownMenu_AddButton(info, level)
end

local function addClassicTitle(text, level)
    local info = UIDropDownMenu_CreateInfo()
    info.text = text
    info.isTitle = true
    info.notCheckable = true
    info.isUninteractable = true
    UIDropDownMenu_AddButton(info, level)
end

local function addClassicButton(text, callback, level)
    local info = UIDropDownMenu_CreateInfo()
    info.text = text
    info.notCheckable = true
    info.func = function()
        if CloseDropDownMenus then CloseDropDownMenus() end
        callback()
    end
    UIDropDownMenu_AddButton(info, level)
end

local function injectClassicMenu(dropdown, _, unit, name)
    if protectedContentActive() then return end
    local level = UIDROPDOWNMENU_MENU_LEVEL or 1
    if level ~= 1 or not UIDropDownMenu_CreateInfo or not UIDropDownMenu_AddButton then return end

    local fullName = resolveFullName(dropdown, unit, name)
    if not canShowFor(fullName, unit) then return end

    addClassicSeparator(level)
    addClassicTitle(GP.L["Guild Paragon"], level)
    addClassicButton(GP.L["Queue for Recruitment"], function()
        queueCandidate(fullName, false)
    end, level)
    addClassicButton(GP.L["Queue and Open Recruitment"], function()
        queueCandidate(fullName, true)
    end, level)
    addClassicButton(GP.L["Add to Blacklist"], function()
        addToBlacklist(fullName)
    end, level)
end

function RecruitmentContext:OnEnable()
    self.retailMenusRegistered = false
    self:RefreshRetailIntegration()

    if type(Menu) == "table" and type(Menu.ModifyMenu) == "function" then
        return
    end

    if type(UnitPopup_ShowMenu) == "function" then
        hooksecurefunc("UnitPopup_ShowMenu", injectClassicMenu)
    end
end

function RecruitmentContext:RefreshRetailIntegration()
    if type(Menu) == "table" and type(Menu.ModifyMenu) == "function" then
        if retailMenusEnabled() and not self.retailMenusRegistered then
            for _, key in ipairs(MENU_KEYS) do
                Menu.ModifyMenu("MENU_UNIT_" .. key, injectRetailMenu)
            end
            self.retailMenusRegistered = true
        end
    end
end
