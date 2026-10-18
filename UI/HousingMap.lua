-- Guild Paragon - Guild Health housing neighborhood map
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.HousingMap = GP.UI.HousingMap or {}
local HousingMap = GP.UI.HousingMap
LibStub("AceEvent-3.0"):Embed(HousingMap)

local PIN_ATLAS = {
    [0] = "housing-map-plot-unoccupied",
    [1] = "housing-map-plot-occupied",
    [2] = "housing-map-plot-occupied-friend",
    [3] = "housing-map-plot-player-house",
}

local PIN_HIGHLIGHT_ATLAS = {
    [0] = "housing-map-plot-unoccupied-highlight",
    [1] = "housing-map-plot-occupied-highlight",
    [2] = "housing-map-plot-occupied-friend-highlight",
    [3] = "housing-map-plot-player-house-highlight",
}

local MIN_ZOOM = 1
local MAX_ZOOM = 3
local ZOOM_STEP = 0.2

local state = {
    neighborhoods = {},
    selectedGUID = nil,
    renderGeneration = 0,
    tiles = {},
    pins = {},
    zoom = MIN_ZOOM,
    panX = 0,
    panY = 0,
    menuMouseWasDown = false,
}

local function guildKey()
    local Roster = GP:GetModule("Roster", true)
    return Roster and (Roster.currentGuildKey or Roster:GetGuildKey()) or nil
end

local function subdivisionLabel(neighborhood)
    if neighborhood and neighborhood.subdivision then
        return string.format(GP.L["Subdivision #%s"], tostring(neighborhood.subdivision))
    end
    return neighborhood and neighborhood.neighborhoodName or GP.L["Subdivision"]
end

local function selectedNeighborhood()
    for _, neighborhood in ipairs(state.neighborhoods) do
        if neighborhood.neighborhoodGUID == state.selectedGUID then return neighborhood end
    end
    return state.neighborhoods[1]
end

local function clearMap()
    state.renderGeneration = state.renderGeneration + 1
    if state.canvas then
        state.canvas:Hide()
    end
    for _, tile in ipairs(state.tiles) do tile:Hide() end
    for _, pin in ipairs(state.pins) do pin:Hide() end
end

local function hideDropdown()
    if state.dropdownPanel then state.dropdownPanel:Hide() end
end

local function clampPan()
    if not state.canvas or not state.mapPanel or not state.fitScale then return end
    local scaledWidth = (state.layerWidth or 0) * state.fitScale * state.zoom
    local scaledHeight = (state.layerHeight or 0) * state.fitScale * state.zoom
    local maxX = math.max(0, (scaledWidth - state.mapPanel:GetWidth()) / 2)
    local maxY = math.max(0, (scaledHeight - state.mapPanel:GetHeight()) / 2)
    state.panX = math.max(-maxX, math.min(maxX, state.panX or 0))
    state.panY = math.max(-maxY, math.min(maxY, state.panY or 0))
end

local function applyZoom()
    if not state.canvas or not state.fitScale then return end
    clampPan()
    state.canvas:SetScale(state.fitScale * state.zoom)
    state.canvas:ClearAllPoints()
    state.canvas:SetPoint("CENTER", state.mapPanel, "CENTER", state.panX, state.panY)
    if state.zoomText then
        state.zoomText:SetText(string.format(GP.L["Zoom: %d%%"], math.floor(state.zoom * 100 + 0.5)))
    end
end

local function resetZoom()
    state.zoom = MIN_ZOOM
    state.panX, state.panY = 0, 0
    applyZoom()
end

local function disarmVisitMenu()
    local button = state.visitSecureButton
    if not button then return end
    if InCombatLockdown and InCombatLockdown() then
        state.visitNeedsDisarm = true
        return
    end
    state.visitNeedsDisarm = false
    if UnregisterStateDriver then UnregisterStateDriver(button, "visibility") end
    button:SetAttribute("type", nil)
    button:SetAttribute("house-neighborhood-guid", nil)
    button:SetAttribute("house-guid", nil)
    button:SetAttribute("house-plot-id", nil)
    button:Hide()
end

local function disarmPinVisit()
    local button = state.pinVisitSecureButton
    if not button then return end
    if InCombatLockdown and InCombatLockdown() then
        state.pinVisitNeedsDisarm = true
        return
    end
    state.pinVisitNeedsDisarm = false
    if UnregisterStateDriver then UnregisterStateDriver(button, "visibility") end
    button:SetAttribute("type", nil)
    button:SetAttribute("house-neighborhood-guid", nil)
    button:SetAttribute("house-guid", nil)
    button:SetAttribute("house-plot-id", nil)
    button:Hide()
    state.armedPin = nil
end

local function armPinVisit(pin, plot, neighborhoodGUID, houseGUID, plotID)
    local button = state.pinVisitSecureButton
    if not button or not pin or not pin:IsShown() or not neighborhoodGUID or not houseGUID or not plotID then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local left, bottom = pin:GetLeft(), pin:GetBottom()
    local width, height = pin:GetWidth(), pin:GetHeight()
    local sourceScale, targetScale = pin:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if not left or not bottom or not width or not height or not sourceScale or not targetScale or targetScale == 0 then return end
    local ratio = sourceScale / targetScale
    if UnregisterStateDriver then UnregisterStateDriver(button, "visibility") end
    button:ClearAllPoints()
    button:SetSize(width * ratio, height * ratio)
    button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * ratio, bottom * ratio)
    button:SetAttribute("type", "visithouse")
    button:SetAttribute("house-neighborhood-guid", neighborhoodGUID)
    button:SetAttribute("house-guid", houseGUID)
    button:SetAttribute("house-plot-id", plotID)
    state.armedPin = pin
    state.armedPlot = plot
    if RegisterStateDriver then RegisterStateDriver(button, "visibility", "[combat] hide; show") end
    button:Show()
end

local function hidePlotMenu()
    if state.plotMenu then state.plotMenu:Hide() end
end

local function clearTransientHousingUI()
    hideDropdown()
    hidePlotMenu()
    disarmVisitMenu()
    disarmPinVisit()
    if state.mapPanel then state.mapPanel:SetScript("OnUpdate", nil) end
end

local function armVisitMenu(neighborhoodGUID, houseGUID, plotID)
    local button, row = state.visitSecureButton, state.plotMenuRow
    if not button or not row or not row:IsShown() or not neighborhoodGUID or not houseGUID or not plotID then
        disarmVisitMenu()
        return
    end
    if InCombatLockdown and InCombatLockdown() then return end
    local left, bottom = row:GetLeft(), row:GetBottom()
    local width, height = row:GetWidth(), row:GetHeight()
    local sourceScale, targetScale = row:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if not left or not bottom or not width or not height or not sourceScale or not targetScale or targetScale == 0 then return end
    local ratio = sourceScale / targetScale
    if UnregisterStateDriver then UnregisterStateDriver(button, "visibility") end
    button:ClearAllPoints()
    button:SetSize(width * ratio, height * ratio)
    button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * ratio, bottom * ratio)
    button:SetAttribute("type", "visithouse")
    button:SetAttribute("house-neighborhood-guid", neighborhoodGUID)
    button:SetAttribute("house-guid", houseGUID)
    button:SetAttribute("house-plot-id", plotID)
    if RegisterStateDriver then RegisterStateDriver(button, "visibility", "[combat] hide; show") end
    button:Show()
end

local function positionPlotMenu(anchor)
    local panel = state.plotMenu
    panel:ClearAllPoints()
    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (cursorX / scale) + 6, (cursorY / scale) - 6)
    panel:SetClampedToScreen(true)
    state.menuMouseWasDown = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
    panel:Show()
end

local function configureVacantVisit()
    state.plotMenuRow.text:SetText(GP.L["Visit House"])
    state.plotMenuRow:SetScript("OnClick", function()
        local neighborhoodGUID, plotID = state.menuNeighborhoodGUID, state.menuPlotID
        hidePlotMenu()
        if C_Housing and C_Housing.HouseFinderRequestReservationAndPort then
            local ok = pcall(C_Housing.HouseFinderRequestReservationAndPort, neighborhoodGUID, plotID)
            if not ok then GP:Print(GP.L["Housing visit request failed."]) end
        end
    end)
end

local function showPlotMenu(anchor, plot, neighborhood)
    if not state.plotMenu or not plot or not neighborhood or (InCombatLockdown and InCombatLockdown()) then return end
    hidePlotMenu()
    disarmVisitMenu()

    local ownerType = tonumber(plot.ownerType) or 0
    state.menuNeighborhoodGUID = neighborhood.neighborhoodGUID
    state.menuPlotID = plot.plotID
    state.menuOwnerGUID = nil
    state.menuIsEmpty = ownerType == 0
    state.plotMenuRow:SetScript("OnClick", nil)

    if ownerType == 0 then
        local Housing = GP:GetModule("Housing", true)
        if Housing and Housing:IsNeighborhoodListReady() then
            configureVacantVisit()
        else
            state.plotMenuRow.text:SetText(GP.L["Preparing House Visit…"])
            if Housing then Housing:EnsureNeighborhoodList() end
        end
        positionPlotMenu(anchor)
        return
    end

    local Housing = GP:GetModule("Housing", true)
    local key = guildKey()
    local ownerGUID = Housing and Housing:GetPlotOwnerGUID(key, neighborhood.neighborhoodGUID, plot.plotID)
    state.menuOwnerGUID = ownerGUID
    if not ownerGUID then
        state.plotMenuRow.text:SetText(GP.L["Visit unavailable"])
        positionPlotMenu(anchor)
        return
    end

    local preparedNeighborhoodGUID, houseGUID, preparedPlotID = Housing:GetPreparedVisit(key, ownerGUID)
    state.plotMenuRow.text:SetText(houseGUID and GP.L["Visit House"] or GP.L["Preparing House Visit…"])
    positionPlotMenu(anchor)
    if houseGUID then
        C_Timer.After(0, function()
            if state.plotMenu:IsShown() then armVisitMenu(preparedNeighborhoodGUID, houseGUID, preparedPlotID) end
        end)
    else
        Housing:PrepareVisit(key, ownerGUID)
    end
end

local function renderPin(canvas, plot, neighborhood, canvasWidth, canvasHeight, index)
    local position = plot and plot.mapPosition
    local x, y = tonumber(position and position.x), tonumber(position and position.y)
    if not x or not y then return end

    local ownerType = tonumber(plot.ownerType) or 0
    local pin = state.pins[index]
    if not pin then
        pin = CreateFrame("Button", nil, canvas)
        pin:SetSize(54, 54)
        pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        pin.icon = pin:CreateTexture(nil, "ARTWORK")
        pin.icon:SetAllPoints()
        pin.number = pin:CreateFontString(nil, "OVERLAY")
        pin.number:SetFontObject(Theme.font.heading)
        pin.number:SetPoint("CENTER", 0, 1)
        pin.number:SetTextColor(1, 1, 1)
        state.pins[index] = pin
    end
    pin:SetParent(canvas)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvas, "TOPLEFT", canvasWidth * x, -(canvasHeight * y))
    pin:SetFrameLevel(canvas:GetFrameLevel() + 10)
    pin.icon:SetAtlas(PIN_ATLAS[ownerType] or PIN_ATLAS[1])
    pin.number:SetText(tostring(plot.plotID or ""))

    pin:SetScript("OnEnter", function(self)
        disarmPinVisit()
        local highlight = PIN_HIGHLIGHT_ATLAS[ownerType]
        if highlight then self.icon:SetAtlas(highlight) end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(string.format(GP.L["Plot #%s"], tostring(plot.plotID or "?")))
        if plot.ownerName and plot.ownerName ~= "" then
            GameTooltip:AddLine(string.format(GP.L["Owner: %s"], plot.ownerName), 1, 1, 1)
        elseif ownerType > 0 then
            GameTooltip:AddLine(GP.L["Occupied plot"], unpack(Theme.color.warning))
        else
            GameTooltip:AddLine(GP.L["Empty plot"], unpack(Theme.color.success))
        end

        local Housing = GP:GetModule("Housing", true)
        local key = guildKey()
        if ownerType == 0 then
            if Housing and Housing:IsNeighborhoodListReady() then
                GameTooltip:AddLine(GP.L["Click to visit"], unpack(Theme.color.accent))
            else
                GameTooltip:AddLine(GP.L["Preparing visit…"], unpack(Theme.color.warning))
                if Housing then Housing:EnsureNeighborhoodList() end
            end
        else
            local ownerGUID = Housing and Housing:GetPlotOwnerGUID(key, neighborhood.neighborhoodGUID, plot.plotID)
            if ownerGUID then
                state.hoverPin, state.hoverPlot = self, plot
                state.hoverOwnerGUID = ownerGUID
                local preparedNeighborhoodGUID, houseGUID, preparedPlotID = Housing:GetPreparedVisit(key, ownerGUID)
                if houseGUID then
                    GameTooltip:AddLine(GP.L["Click to visit"], unpack(Theme.color.accent))
                    C_Timer.After(0, function()
                        if state.hoverPin == self then
                            armPinVisit(self, plot, preparedNeighborhoodGUID, houseGUID, preparedPlotID)
                        end
                    end)
                else
                    GameTooltip:AddLine(GP.L["Preparing visit…"], unpack(Theme.color.warning))
                    Housing:PrepareVisit(key, ownerGUID)
                end
            else
                GameTooltip:AddLine(GP.L["Visit unavailable"], unpack(Theme.color.textSecondary))
            end
        end
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function(self)
        pin.icon:SetAtlas(PIN_ATLAS[ownerType] or PIN_ATLAS[1])
        if state.armedPin ~= self and state.hoverPin == self then
            state.hoverPin, state.hoverPlot, state.hoverOwnerGUID = nil, nil, nil
        end
        GameTooltip_Hide()
    end)
    pin:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            showPlotMenu(self, plot, neighborhood)
        elseif button == "LeftButton" and ownerType == 0 then
            local Housing = GP:GetModule("Housing", true)
            if Housing and Housing:IsNeighborhoodListReady() and C_Housing
                and C_Housing.HouseFinderRequestReservationAndPort then
                pcall(C_Housing.HouseFinderRequestReservationAndPort, neighborhood.neighborhoodGUID, plot.plotID)
            end
        end
    end)
    pin:Show()
end

local function renderNeighborhood()
    if not state.mapPanel or not state.mapPanel:IsShown() then return end
    clearMap()

    local neighborhood = selectedNeighborhood()
    if not neighborhood then
        state.dropdownButton.text:SetText(GP.L["No subdivisions"])
        state.summary:SetText(GP.L["Run a housing scan to load the guild neighborhood map."])
        state.emptyText:SetText(GP.L["No housing neighborhood data is available yet."])
        state.emptyText:Show()
        return
    end
    state.selectedGUID = neighborhood.neighborhoodGUID
    state.dropdownButton.text:SetText(subdivisionLabel(neighborhood) .. "  v")

    local occupied = 0
    for _, plot in ipairs(neighborhood.plots or {}) do
        if (tonumber(plot.ownerType) or 0) > 0 then occupied = occupied + 1 end
    end
    state.summary:SetText(string.format(GP.L["%s · %d plots · %d occupied · %d empty"],
        neighborhood.neighborhoodName or subdivisionLabel(neighborhood), #(neighborhood.plots or {}),
        occupied, math.max(0, #(neighborhood.plots or {}) - occupied)))

    local uiMapID = tonumber(neighborhood.uiMapID)
    if (not uiMapID) and C_Housing and C_Housing.GetUIMapIDForNeighborhood then
        local ok, value = pcall(C_Housing.GetUIMapIDForNeighborhood, neighborhood.neighborhoodGUID)
        if ok then uiMapID = tonumber(value) end
    end
    local layers = uiMapID and C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(uiMapID)
    local layer = layers and layers[1]
    local textures = layer and C_Map.GetMapArtLayerTextures(uiMapID, 1)
    if not layer or not textures or #textures == 0 or not layer.layerWidth or not layer.layerHeight then
        state.emptyText:SetText(GP.L["The neighborhood map art is not available from Blizzard right now."])
        state.emptyText:Show()
        return
    end

    state.emptyText:Hide()
    local availableWidth = math.max(1, state.mapPanel:GetWidth() - 20)
    local availableHeight = math.max(1, state.mapPanel:GetHeight() - 20)
    local scale = math.min(availableWidth / layer.layerWidth, availableHeight / layer.layerHeight)
    local canvas = state.canvas or CreateFrame("Frame", nil, state.mapPanel)
    state.canvas = canvas
    canvas:SetParent(state.mapPanel)
    canvas:ClearAllPoints()
    canvas:SetSize(layer.layerWidth, layer.layerHeight)
    state.fitScale = scale
    state.layerWidth, state.layerHeight = layer.layerWidth, layer.layerHeight
    canvas:SetClipsChildren(true)
    canvas:Show()
    applyZoom()

    local tileSize = 256
    local columns = math.ceil(layer.layerWidth / tileSize)
    local rows = math.ceil(layer.layerHeight / tileSize)
    local index = 1
    for row = 0, rows - 1 do
        for column = 0, columns - 1 do
            if index > #textures then break end
            local width = math.min(tileSize, layer.layerWidth - column * tileSize)
            local height = math.min(tileSize, layer.layerHeight - row * tileSize)
            local texture = state.tiles[index]
            if not texture then
                texture = canvas:CreateTexture(nil, "ARTWORK")
                state.tiles[index] = texture
            end
            texture:ClearAllPoints()
            texture:SetPoint("TOPLEFT", column * tileSize, -(row * tileSize))
            texture:SetSize(width, height)
            texture:SetTexture(textures[index])
            if width < tileSize or height < tileSize then
                texture:SetTexCoord(0, width / tileSize, 0, height / tileSize)
            else
                texture:SetTexCoord(0, 1, 0, 1)
            end
            texture:Show()
            index = index + 1
        end
    end

    for plotIndex, plot in ipairs(neighborhood.plots or {}) do
        renderPin(canvas, plot, neighborhood, layer.layerWidth, layer.layerHeight, plotIndex)
    end
end

local function rebuildDropdown()
    local panel = state.dropdownPanel
    for _, row in ipairs(state.dropdownRows or {}) do row:Hide() end
    state.dropdownRows = state.dropdownRows or {}
    local count = #state.neighborhoods
    panel:SetHeight(math.max(1, count) * 26 + 8)
    for index, neighborhood in ipairs(state.neighborhoods) do
        local row = state.dropdownRows[index]
        if not row then
            row = Theme:CreateButton(panel, "")
            row:SetHeight(24)
            row:SetPoint("LEFT", 4, 0)
            row:SetPoint("RIGHT", -4, 0)
            state.dropdownRows[index] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 4, -4 - ((index - 1) * 26))
        row:SetPoint("RIGHT", -4, 0)
        row.text:SetText(subdivisionLabel(neighborhood))
        row:SetScript("OnClick", function()
            state.selectedGUID = neighborhood.neighborhoodGUID
            hideDropdown()
            resetZoom()
            renderNeighborhood()
        end)
        row:Show()
    end
end

function HousingMap:Refresh()
    if GP:IsForeverClient() then return end
    if not state.page then return end
    local Housing = GP:GetModule("Housing", true)
    if Housing then Housing:EnsureNeighborhoodList() end
    state.neighborhoods = Housing and Housing:GetNeighborhoods(guildKey()) or {}
    if #state.neighborhoods > 0 then
        local found
        for _, neighborhood in ipairs(state.neighborhoods) do
            if neighborhood.neighborhoodGUID == state.selectedGUID then found = true break end
        end
        if not found then state.selectedGUID = state.neighborhoods[1].neighborhoodGUID end
    else
        state.selectedGUID = nil
    end
    state.dropdownButton:SetEnabled(#state.neighborhoods > 1)
    rebuildDropdown()
    C_Timer.After(0, renderNeighborhood)
end

function HousingMap:Build(parent)
    if GP:IsForeverClient() then return nil end
    if state.page then return state.page end
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    state.page = page

    local title = page:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.heading)
    title:SetPoint("TOPLEFT", 2, -4)
    title:SetText(GP.L["Guild Housing"])

    state.summary = page:CreateFontString(nil, "ARTWORK")
    state.summary:SetFontObject(Theme.font.small)
    state.summary:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    state.summary:SetTextColor(unpack(Theme.color.textSecondary))

    state.zoomText = page:CreateFontString(nil, "ARTWORK")
    state.zoomText:SetFontObject(Theme.font.small)
    state.zoomText:SetPoint("LEFT", state.summary, "RIGHT", 14, 0)
    state.zoomText:SetTextColor(unpack(Theme.color.textSecondary))

    state.dropdownButton = Theme:CreateButton(page, "")
    state.dropdownButton:SetWidth(190)
    state.dropdownButton:SetPoint("TOPRIGHT", -2, -2)
    state.dropdownButton:SetScript("OnClick", function()
        state.dropdownPanel:SetShown(not state.dropdownPanel:IsShown())
    end)

    local scanButton = Theme:CreateButton(page, GP.L["Scan Housing"])
    scanButton:SetPoint("RIGHT", state.dropdownButton, "LEFT", -8, 0)
    scanButton:SetScript("OnClick", function()
        local Housing = GP:GetModule("Housing", true)
        local ok, message
        if Housing then
            ok, message = Housing:StartScan()
        end
        if not ok and message then GP:Print(message) end
    end)

    local mapPanel = Theme:CreatePanel(page, "panel", "border")
    mapPanel:SetPoint("TOPLEFT", state.summary, "BOTTOMLEFT", 0, -10)
    mapPanel:SetPoint("BOTTOMRIGHT")
    mapPanel:SetClipsChildren(true)
    mapPanel:EnableMouse(true)
    mapPanel:EnableMouseWheel(true)
    state.mapPanel = mapPanel

    mapPanel:SetScript("OnMouseWheel", function(_, delta)
        if not state.canvas then return end
        local previous = state.zoom
        state.zoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, state.zoom + (delta > 0 and ZOOM_STEP or -ZOOM_STEP)))
        if previous > 0 and state.zoom ~= previous then
            local ratio = state.zoom / previous
            state.panX, state.panY = state.panX * ratio, state.panY * ratio
            applyZoom()
        end
    end)
    mapPanel:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or state.zoom <= MIN_ZOOM then return end
        local scale = self:GetEffectiveScale()
        local x, y = GetCursorPosition()
        state.dragStartX, state.dragStartY = x / scale, y / scale
        state.dragPanX, state.dragPanY = state.panX, state.panY
        self:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then
                self:SetScript("OnUpdate", nil)
                return
            end
            local cursorX, cursorY = GetCursorPosition()
            state.panX = state.dragPanX + (cursorX / scale) - state.dragStartX
            state.panY = state.dragPanY + (cursorY / scale) - state.dragStartY
            applyZoom()
        end)
    end)
    mapPanel:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    state.emptyText = mapPanel:CreateFontString(nil, "ARTWORK")
    state.emptyText:SetFontObject(Theme.font.body)
    state.emptyText:SetPoint("CENTER")
    state.emptyText:SetWidth(520)
    state.emptyText:SetJustifyH("CENTER")
    state.emptyText:SetTextColor(unpack(Theme.color.textSecondary))

    state.dropdownPanel = Theme:CreatePanel(page, "panelRaised", "accent")
    state.dropdownPanel:SetPoint("TOPRIGHT", state.dropdownButton, "BOTTOMRIGHT", 0, -2)
    state.dropdownPanel:SetWidth(190)
    state.dropdownPanel:SetFrameLevel(page:GetFrameLevel() + 30)
    state.dropdownPanel:Hide()

    state.plotMenu = Theme:CreatePanel(UIParent, "panelRaised", "accent")
    state.plotMenu:SetFrameStrata("TOOLTIP")
    state.plotMenu:SetFrameLevel(200)
    state.plotMenu:SetSize(180, 34)
    state.plotMenu:EnableMouse(true)
    state.plotMenu:Hide()
    state.plotMenuRow = Theme:CreateButton(state.plotMenu, "")
    state.plotMenuRow:SetPoint("TOPLEFT", 4, -4)
    state.plotMenuRow:SetPoint("BOTTOMRIGHT", -4, 4)
    state.plotMenu:SetScript("OnHide", function()
        disarmVisitMenu()
        state.menuNeighborhoodGUID = nil
        state.menuPlotID = nil
        state.menuOwnerGUID = nil
        state.menuIsEmpty = nil
    end)
    state.plotMenu:SetScript("OnUpdate", function(self)
        local isDown = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
        if isDown and not state.menuMouseWasDown and not self:IsMouseOver() then hidePlotMenu() end
        state.menuMouseWasDown = isDown
    end)

    state.visitSecureButton = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    state.visitSecureButton:SetFrameStrata("TOOLTIP")
    state.visitSecureButton:SetFrameLevel(210)
    state.visitSecureButton:RegisterForClicks("AnyDown", "AnyUp")
    state.visitSecureButton:Hide()
    state.visitSecureButton:SetScript("PostClick", function()
        C_Timer.After(0, hidePlotMenu)
    end)

    state.pinVisitSecureButton = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    state.pinVisitSecureButton:SetFrameStrata("TOOLTIP")
    state.pinVisitSecureButton:SetFrameLevel(210)
    state.pinVisitSecureButton:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    state.pinVisitSecureButton:Hide()
    state.pinVisitSecureButton:SetScript("OnEnter", function(self)
        local plot = state.armedPlot
        if not plot then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(string.format(GP.L["Plot #%s"], tostring(plot.plotID or "?")))
        if plot.ownerName and plot.ownerName ~= "" then
            GameTooltip:AddLine(string.format(GP.L["Owner: %s"], plot.ownerName), 1, 1, 1)
        end
        GameTooltip:AddLine(GP.L["Click to visit"], unpack(Theme.color.accent))
        GameTooltip:Show()
    end)
    state.pinVisitSecureButton:SetScript("OnLeave", function()
        GameTooltip_Hide()
        state.hoverPin, state.hoverPlot, state.hoverOwnerGUID = nil, nil, nil
        disarmPinVisit()
    end)

    page.OnSelected = function()
        resetZoom()
        HousingMap:Refresh()
    end
    page.OnDeselected = clearTransientHousingUI
    page:HookScript("OnHide", function()
        clearTransientHousingUI()
        resetZoom()
    end)
    return page
end

HousingMap:RegisterMessage("GuildParagon_HousingVisitPrepared", function(_event, preparedGuildKey, ownerGUID, houseGUID)
    if state.plotMenu and state.plotMenu:IsShown() and state.menuOwnerGUID
        and preparedGuildKey == guildKey() and ownerGUID == state.menuOwnerGUID then
        if not houseGUID then
            state.plotMenuRow.text:SetText(GP.L["Visit unavailable"])
        else
            local Housing = GP:GetModule("Housing", true)
            local neighborhoodGUID, preparedHouseGUID, plotID
            if Housing then
                neighborhoodGUID, preparedHouseGUID, plotID = Housing:GetPreparedVisit(preparedGuildKey, ownerGUID)
            end
            state.plotMenuRow.text:SetText(GP.L["Visit House"])
            armVisitMenu(neighborhoodGUID, preparedHouseGUID, plotID)
        end
    end

    local pin = state.hoverPin
    if not pin or not pin:IsShown() or ownerGUID ~= state.hoverOwnerGUID or preparedGuildKey ~= guildKey() then return end
    if not houseGUID or not pin:IsMouseOver() then return end
    local Housing = GP:GetModule("Housing", true)
    local neighborhoodGUID, preparedHouseGUID, plotID
    if Housing then
        neighborhoodGUID, preparedHouseGUID, plotID = Housing:GetPreparedVisit(preparedGuildKey, ownerGUID)
    end
    armPinVisit(pin, state.hoverPlot, neighborhoodGUID, preparedHouseGUID, plotID)
end)

HousingMap:RegisterMessage("GuildParagon_HousingNeighborhoodListReady", function()
    if state.plotMenu and state.plotMenu:IsShown() and state.menuIsEmpty then configureVacantVisit() end
end)

local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function()
    if state.visitNeedsDisarm then disarmVisitMenu() end
    if state.pinVisitNeedsDisarm then disarmPinVisit() end
end)
