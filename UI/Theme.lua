-- Guild Paragon visual constants and UI helpers.
local _, GP = ...

GP.UI = GP.UI or {}
local Theme = {}
GP.UI.Theme = Theme

-- Palette. Dark, desaturated background so member-status colors (class
-- colors, the join/leave/promote/demote accents below) stay the things that
-- pop, not the chrome around them.
Theme.color = {
    backdrop      = { 0.078, 0.086, 0.106, 0.97 },  -- #14161B — window background
    panel         = { 0.114, 0.125, 0.157, 1.00 },  -- #1D2028 — cards/sidebar
    panelRaised   = { 0.145, 0.157, 0.192, 1.00 },  -- #252831 — hovered/active row
    border        = { 0.180, 0.196, 0.235, 1.00 },  -- #2E323C — hairline borders

    textPrimary   = { 0.910, 0.918, 0.941, 1.00 },  -- #E8EAF0
    textSecondary = { 0.541, 0.561, 0.612, 1.00 },  -- #8A8F9C
    textDisabled  = { 0.322, 0.341, 0.384, 1.00 },  -- #525762

    accent        = { 0.243, 0.851, 0.753, 1.00 },  -- #3ED9C0 — brand teal ("pulse")
    accentDim     = { 0.243, 0.851, 0.753, 0.35 },

    success       = { 0.298, 0.843, 0.529, 1.00 },  -- #4CD787 — joins
    danger        = { 1.000, 0.365, 0.365, 1.00 },  -- #FF5D5D — leaves/kicks
    warning       = { 1.000, 0.706, 0.329, 1.00 },  -- #FFB454 — demotions
    info          = { 0.310, 0.659, 1.000, 1.00 },  -- #4FA8FF — promotions
}

-- Fonts built on Blizzard's locale-aware default UI font.
do
    local function newFont(name, size, color, flags)
        local f = CreateFont(name)
        -- SetFont requires a string flags argument.
        f:SetFont(STANDARD_TEXT_FONT, size, flags or "")
        f:SetTextColor(unpack(color))
        return f
    end

    Theme.font = {
        title   = newFont("GuildParagonFontTitle", 16, Theme.color.textPrimary),
        heading = newFont("GuildParagonFontHeading", 13, Theme.color.textPrimary),
        body    = newFont("GuildParagonFontBody", 12, Theme.color.textPrimary),
        muted   = newFont("GuildParagonFontMuted", 12, Theme.color.textSecondary),
        small   = newFont("GuildParagonFontSmall", 10, Theme.color.textSecondary),
    }
end

-- Spacing/layout constants shared by every panel so future tabs line up
-- with the shell without each one reinventing padding numbers.
Theme.layout = {
    padding      = 16,
    gutter       = 8,
    sidebarWidth = 150,
    headerHeight = 40,
    rowHeight    = 24,
}

function Theme:BackdropEdgeSize()
    local scale = 1
    if GP.db and GP.db.profile and GP.db.profile.ui then
        scale = tonumber(GP.db.profile.ui.scale) or scale
    end
    -- WoW backdrop edges are measured in scaled UI units. At 90%, 75%, etc.,
    -- a 1-unit edge can become subpixel and disappear, so use enough UI units
    -- to remain at least one physical pixel after window scaling.
    if scale > 0 and scale < 1 then
        return math.ceil(1 / scale)
    end
    return 1
end

function Theme:Backdrop(colorKey, borderKey)
    local backdrop = {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = self:BackdropEdgeSize(),
    }
    return backdrop, self.color[colorKey or "panel"], self.color[borderKey or "border"]
end

function Theme:CreatePanel(parent, colorKey, borderKey)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local backdrop, bgColor, borderColor = self:Backdrop(colorKey, borderKey)
    frame:SetBackdrop(backdrop)
    frame:SetBackdropColor(unpack(bgColor))
    frame:SetBackdropBorderColor(unpack(borderColor))
    return frame
end

function Theme:RefreshBackdrop(frame)
    if not frame or not frame.GetBackdrop or not frame.SetBackdrop then return end
    local backdrop = frame:GetBackdrop()
    if not backdrop then return end
    local edgeSize = self:BackdropEdgeSize()
    if backdrop.edgeSize == edgeSize then return end
    local bgR, bgG, bgB, bgA = frame:GetBackdropColor()
    local brR, brG, brB, brA = frame:GetBackdropBorderColor()
    frame:SetBackdrop({
        bgFile = backdrop.bgFile,
        edgeFile = backdrop.edgeFile,
        tile = backdrop.tile,
        tileSize = backdrop.tileSize,
        edgeSize = edgeSize,
        insets = backdrop.insets,
    })
    if bgR then frame:SetBackdropColor(bgR, bgG, bgB, bgA) end
    if brR then frame:SetBackdropBorderColor(brR, brG, brB, brA) end
end

function Theme:RefreshBackdropTree(frame)
    self:RefreshBackdrop(frame)
    if not frame or not frame.GetChildren then return end
    local kids = { frame:GetChildren() }
    for i = 1, #kids do
        self:RefreshBackdropTree(kids[i])
    end
end

function Theme:CreateNavButton(parent, label)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetHeight(self.layout.rowHeight + 6)
    button:SetBackdrop((self:Backdrop("panel")))
    button:SetBackdropColor(0, 0, 0, 0)
    button:SetBackdropBorderColor(0, 0, 0, 0)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(self.font.body)
    text:SetPoint("LEFT", 12, 0)
    text:SetJustifyH("LEFT")
    button.text = text
    text:SetText(label)

    local accentBar = button:CreateTexture(nil, "ARTWORK")
    accentBar:SetColorTexture(unpack(self.color.accent))
    accentBar:SetPoint("TOPLEFT")
    accentBar:SetPoint("BOTTOMLEFT")
    accentBar:SetWidth(2)
    accentBar:Hide()
    button.accentBar = accentBar

    button:SetScript("OnEnter", function(self)
        if not self.selected then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
        end
    end)
    button:SetScript("OnLeave", function(self)
        if not self.selected then
            self:SetBackdropColor(0, 0, 0, 0)
        end
    end)

    function button:SetSelected(selected)
        self.selected = selected
        if selected then
            self:SetBackdropColor(unpack(Theme.color.panelRaised))
            self.accentBar:Show()
            self.text:SetFontObject(Theme.font.heading)
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self.accentBar:Hide()
            self.text:SetFontObject(Theme.font.body)
        end
    end

    return button
end

function Theme:CreateCloseButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(20, 20)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(self.font.heading)
    text:SetPoint("CENTER")
    text:SetText("×")
    text:SetTextColor(unpack(self.color.textSecondary))

    button:SetScript("OnEnter", function() text:SetTextColor(unpack(Theme.color.textPrimary)) end)
    button:SetScript("OnLeave", function() text:SetTextColor(unpack(Theme.color.textSecondary)) end)

    return button
end

function Theme:CreateButton(parent, label)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetHeight(26)
    button:SetBackdrop((self:Backdrop("panelRaised", "accent")))
    button:SetBackdropColor(unpack(self.color.panelRaised))
    button:SetBackdropBorderColor(unpack(self.color.accentDim))

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(self.font.body)
    text:SetPoint("CENTER")
    text:SetText(label)
    button.text = text
    button:SetWidth(text:GetStringWidth() + 32)

    button:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Theme.color.accent)) end)
    button:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(Theme.color.accentDim)) end)

    return button
end

function Theme:CreateEditBox(parent, width)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetHeight(24)
    box:SetWidth(width or 160)
    box:SetBackdrop((self:Backdrop("panel", "border")))
    box:SetBackdropColor(unpack(self.color.panel))
    box:SetBackdropBorderColor(unpack(self.color.border))
    box:SetFontObject(self.font.body)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetAutoFocus(false)
    box:HookScript("OnMouseDown", function(self)
        self:SetFocus()
    end)
    box:HookScript("OnEditFocusGained", function(self)
        if self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(false)
        end
    end)
    box:HookScript("OnEditFocusLost", function(self)
        if self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    return box
end

function Theme:CreateSearchBox(parent, width, onTextChanged)
    local box = self:CreateEditBox(parent, width)
    box:SetTextInsets(8, 20, 0, 0) -- leave room for the clear button

    local clear = CreateFrame("Button", nil, box)
    clear:SetSize(16, 16)
    clear:SetPoint("RIGHT", -4, 0)
    clear:Hide()

    local clearText = clear:CreateFontString(nil, "ARTWORK")
    clearText:SetFontObject(self.font.muted)
    clearText:SetPoint("CENTER")
    clearText:SetText("×")

    clear:SetScript("OnEnter", function() clearText:SetTextColor(unpack(Theme.color.textPrimary)) end)
    clear:SetScript("OnLeave", function() clearText:SetTextColor(unpack(Theme.color.textSecondary)) end)
    clear:SetScript("OnClick", function()
        box:SetText("")
        box:ClearFocus()
    end)

    box:SetScript("OnTextChanged", function(self)
        if self:GetText() ~= "" then clear:Show() else clear:Hide() end
        if onTextChanged then onTextChanged(self) end
    end)
    box:SetScript("OnEscapePressed", function(self)
        if self:GetText() ~= "" then self:SetText("") end
        self:ClearFocus()
    end)

    return box
end
