-- Guild Paragon - list row right-click menu
-- A small themed menu for list rows that need a few plain (non-secure) actions.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.RowMenu = GP.UI.RowMenu or {}
local RowMenu = GP.UI.RowMenu

local MENU_WIDTH = 190
local HEADER_HEIGHT = 28
local ROW_HEIGHT = 24
local DIVIDER_HEIGHT = 7
local MENU_PADDING = 8

local panel
local rows = {}
local mouseWasDown = false

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

local function configureRow(row, item)
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row.isAction = item.kind == "action"
    row:EnableMouse(row.isAction)
    if item.kind == "header" then
        row:SetHeight(HEADER_HEIGHT)
        row.text:SetFontObject(Theme.font.heading)
        row.text:SetText(item.text or "")
        row.text:SetTextColor(unpack(item.color or Theme.color.textPrimary))
        row:SetScript("OnClick", nil)
    elseif item.kind == "divider" then
        row:SetHeight(DIVIDER_HEIGHT)
        row.text:SetText("")
        row:SetScript("OnClick", nil)
    else
        row:SetHeight(ROW_HEIGHT)
        row.text:SetFontObject(Theme.font.body)
        row.text:SetText(item.text or "")
        row.text:SetTextColor(unpack(item.color or Theme.color.textPrimary))
        local onClick = item.onClick
        row:SetScript("OnClick", function()
            RowMenu:Hide()
            if onClick then onClick() end
        end)
    end
end

function RowMenu:Hide()
    if panel then panel:Hide() end
end

-- items: ordered list of { kind = "header"|"divider"|"action", text, color, onClick }.
-- Returns false without showing anything when the list has no action.
function RowMenu:Show(items)
    local hasAction = false
    for _, item in ipairs(items or {}) do
        if item.kind == "action" then hasAction = true; break end
    end
    if not hasAction then
        self:Hide()
        return false
    end

    ensurePanel()
    panel:Hide()

    local y = -MENU_PADDING
    for index, item in ipairs(items) do
        local row = acquireRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", MENU_PADDING, y)
        row:SetPoint("RIGHT", panel, "RIGHT", -MENU_PADDING, 0)
        configureRow(row, item)
        y = y - row:GetHeight()
    end
    for i = #items + 1, #rows do
        rows[i]:Hide()
    end

    panel:SetHeight(math.abs(y) + MENU_PADDING)
    panel:ClearAllPoints()
    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (cursorX / scale) + 6, (cursorY / scale) - 6)
    mouseWasDown = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
    panel:Show()
    return true
end
