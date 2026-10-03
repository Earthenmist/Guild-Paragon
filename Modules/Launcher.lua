-- Guild Paragon — launcher buttons
-- Uses the shared broker launcher for minimap collector compatibility.
local ADDON_NAME, GP = ...

local Launcher = GP:NewModule("Launcher")

local ICON_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\GuildParagonIcon"
local LAUNCHER_NAME = "Guild Paragon"
local DEFAULT_ANGLE = 225

local minimapRegistered = false
local compartmentRegistered = false

local function launcherSettings()
    GP.db.profile.minimapIcon = GP.db.profile.minimapIcon or {}
    local s = GP.db.profile.minimapIcon
    if s.hide == nil then s.hide = false end
    s.angle = tonumber(s.angle) or DEFAULT_ANGLE
    return s
end

local function showTooltip(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(GP.L["Guild Paragon"])
    GameTooltip:AddLine(GP.L["Left-click to open Guild Paragon."], 0.8, 0.8, 0.8)
    GameTooltip:AddLine(GP.L["Drag to move this button."], 0.8, 0.8, 0.8)
    local applicants = GP:GetModule("GuildApplicants", true)
    if applicants and applicants:CanUse() then GameTooltip:AddLine(applicants:StatusText(), 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
end

local function hideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

function Launcher:Refresh()
    if not Minimap then return end
    local settings = launcherSettings()
    if settings.minimapPos == nil then settings.minimapPos = settings.angle end
    local icon = LibStub("LibDBIcon-1.0")
    if not minimapRegistered then
        local broker = LibStub("LibDataBroker-1.1")
        local object = broker:GetDataObjectByName(LAUNCHER_NAME) or broker:NewDataObject(LAUNCHER_NAME, {
            type = "launcher",
            label = GP.L["Guild Paragon"],
            icon = ICON_TEXTURE,
            iconCoords = {0.08, 0.92, 0.08, 0.92},
            OnClick = function(_, button)
                if button == "LeftButton" then GP.UI.MainWindow:Toggle() end
            end,
            OnEnter = showTooltip,
            OnLeave = hideTooltip,
        })
        if not icon:IsRegistered(LAUNCHER_NAME) then
            icon:Register(LAUNCHER_NAME, object, settings)
        end
        minimapRegistered = true
    end
    icon:Refresh(LAUNCHER_NAME, settings)
end

function Launcher:SetMinimapShown(shown)
    launcherSettings().hide = not shown
    self:Refresh()
end

function Launcher:IsMinimapShown()
    return not launcherSettings().hide
end

local function registerAddonCompartment()
    if compartmentRegistered then return end
    if not AddonCompartmentFrame or not AddonCompartmentFrame.RegisterAddon then return end
    local ok = pcall(AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
        text = GP.L["Guild Paragon"],
        icon = ICON_TEXTURE,
        registerForAnyClick = true,
        notCheckable = true,
        func = function()
            GP.UI.MainWindow:Toggle()
        end,
        funcOnEnter = function(menuItem)
            if not GameTooltip then return end
            GameTooltip:SetOwner(menuItem, "ANCHOR_CURSOR")
            GameTooltip:SetText("|T" .. ICON_TEXTURE .. ":0|t " .. GP.L["Guild Paragon"])
            GameTooltip:AddLine(GP.L["Left-click to open Guild Paragon."], 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end,
        funcOnLeave = function()
            if GameTooltip then GameTooltip:Hide() end
        end,
    })
    compartmentRegistered = ok and true or false
end

function Launcher:OnEnable()
    self:Refresh()
    registerAddonCompartment()
end

-- Optional global callbacks for clients that prefer TOC-style addon
-- compartment wiring. We still register at runtime above so older clients
-- simply ignore this without error.
_G.GuildParagon_OnAddonCompartmentClick = function()
    GP.UI.MainWindow:Toggle()
end
