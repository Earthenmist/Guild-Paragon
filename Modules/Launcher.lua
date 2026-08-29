-- Guild Paragon — launcher buttons
-- Keeps access to the main window close at hand without taking a dependency
local ADDON_NAME, GP = ...

local Launcher = GP:NewModule("Launcher")

local ICON_TEXTURE = "Interface\\AddOns\\GuildParagon\\Media\\GuildParagonIcon"
local MINIMAP_RADIUS = 82
local DEFAULT_ANGLE = 225

local minimapButton
local compartmentRegistered = false

local function launcherSettings()
    GP.db.profile.minimapIcon = GP.db.profile.minimapIcon or {}
    local s = GP.db.profile.minimapIcon
    if s.hide == nil then s.hide = false end
    s.angle = tonumber(s.angle) or DEFAULT_ANGLE
    return s
end

local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function positionButton()
    if not minimapButton or not Minimap then return end
    local angle = math.rad(launcherSettings().angle)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * MINIMAP_RADIUS, math.sin(angle) * MINIMAP_RADIUS)
end

local function updateDragPosition()
    if not minimapButton or not Minimap then return end
    local scale = Minimap:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    local centerX, centerY = Minimap:GetCenter()
    if not cursorX or not cursorY or not centerX or not centerY then return end

    local x = (cursorX / scale) - centerX
    local y = (cursorY / scale) - centerY
    launcherSettings().angle = math.deg(atan2(y, x))
    positionButton()
end

local function showTooltip(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(GP.L["Guild Paragon"])
    GameTooltip:AddLine(GP.L["Left-click to open Guild Paragon."], 0.8, 0.8, 0.8)
    GameTooltip:AddLine(GP.L["Drag to move this button."], 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

local function hideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

local function createMinimapButton()
    if minimapButton or not Minimap then return end

    minimapButton = CreateFrame("Button", "GuildParagonMinimapButton", Minimap, "BackdropTemplate")
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetClampedToScreen(true)

    local border = minimapButton:CreateTexture(nil, "BACKGROUND")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56, 56)
    border:SetPoint("TOPLEFT")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    icon:SetSize(22, 22)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    minimapButton.icon = icon

    minimapButton:SetScript("OnClick", function()
        GP.UI.MainWindow:Toggle()
    end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", updateDragPosition)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        positionButton()
    end)
    minimapButton:SetScript("OnEnter", showTooltip)
    minimapButton:SetScript("OnLeave", hideTooltip)

    positionButton()
end

local function showMinimapButton()
    createMinimapButton()
    if not minimapButton then return end

    if minimapButton:GetParent() ~= Minimap then
        minimapButton:SetParent(Minimap)
    end
    minimapButton:EnableMouse(true)
    minimapButton:SetAlpha(1)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    positionButton()
    minimapButton:Show()
    minimapButton:Raise()
end

function Launcher:Refresh()
    if launcherSettings().hide then
        createMinimapButton()
        if not minimapButton then return end
        minimapButton:Hide()
    else
        showMinimapButton()
    end
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
