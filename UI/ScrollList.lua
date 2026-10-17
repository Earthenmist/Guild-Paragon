-- Guild Paragon — Scroll List
-- A reusable virtualized list: a small pool of row frames gets repositioned
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.ScrollList = GP.UI.ScrollList or {}
local ScrollList = GP.UI.ScrollList

local SCROLLBAR_WIDTH = 6
local SCROLLBAR_GUTTER = 4

function ScrollList:New(parent, rowHeight, createRow)
    local list = {}

    local viewport = CreateFrame("Frame", nil, parent)
    viewport:SetAllPoints()
    viewport:SetClipsChildren(true)
    list.frame = viewport

    local rowContainer = CreateFrame("Frame", nil, viewport)
    rowContainer:SetPoint("TOPLEFT")
    -- Scrollbar-reserved default until the first :Refresh() (every caller
    -- triggers one via :SetData right after :New) decides whether a
    -- scrollbar is actually needed and re-anchors this accordingly.
    rowContainer:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_WIDTH + SCROLLBAR_GUTTER), 0)

    local track = Theme:CreatePanel(viewport, "panel", "border")
    track:SetWidth(SCROLLBAR_WIDTH)
    track:SetPoint("TOPRIGHT")
    track:SetPoint("BOTTOMRIGHT")
    track:Hide()

    local thumb = CreateFrame("Frame", nil, track, "BackdropTemplate")
    thumb:SetBackdrop((Theme:Backdrop("panelRaised")))
    thumb:SetBackdropColor(unpack(Theme.color.accentDim))
    thumb:SetPoint("TOP")
    thumb:SetWidth(SCROLLBAR_WIDTH)
    thumb:EnableMouse(true)

    local rows = {}
    local data = {}
    local scrollOffset = 0
    local updateRowFn

    local function visibleRowCount()
        local h = rowContainer:GetHeight()
        if not h or h <= 0 then return 0 end
        return math.max(0, math.floor(h / rowHeight))
    end

    local function maxScrollOffset()
        return math.max(0, #data - visibleRowCount())
    end

    local function ensureRowPool(n)
        for i = #rows + 1, n do
            local row = createRow(rowContainer)
            row:SetHeight(rowHeight)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
            row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)
            rows[i] = row
        end
    end

    function list:Refresh()
        local visible = visibleRowCount()
        local total = #data
        local needsScrollbar = total > visible and visible > 0

        -- Only reserve the scrollbar's gutter when a scrollbar is actually
        -- going to be shown. Previously this inset was permanent, so a
        rowContainer:ClearAllPoints()
        rowContainer:SetPoint("TOPLEFT")
        if needsScrollbar then
            rowContainer:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_WIDTH + SCROLLBAR_GUTTER), 0)
        else
            rowContainer:SetPoint("BOTTOMRIGHT")
        end

        ensureRowPool(visible)

        scrollOffset = math.max(0, math.min(scrollOffset, maxScrollOffset()))

        for i, row in ipairs(rows) do
            local item = (i <= visible) and data[scrollOffset + i] or nil
            if item then
                if updateRowFn then updateRowFn(row, item, scrollOffset + i) end
                row:Show()
            else
                row:Hide()
            end
        end

        if not needsScrollbar then
            track:Hide()
            return
        end
        track:Show()

        local trackHeight = track:GetHeight()
        local thumbHeight = math.max(20, trackHeight * (visible / total))
        thumb:SetHeight(thumbHeight)

        local maxOffset = maxScrollOffset()
        local travel = trackHeight - thumbHeight
        local y = (maxOffset > 0) and (travel * (scrollOffset / maxOffset)) or 0
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -y)
    end

    function list:SetData(newData, resetScroll)
        data = newData or {}
        if resetScroll then scrollOffset = 0 end
        self:Refresh()
    end

    function list:ScrollToIndex(index)
        index = math.floor(tonumber(index) or 0)
        if index <= 0 or #data == 0 then return false end

        local visible = visibleRowCount()
        if visible <= 0 then return false end

        if index <= scrollOffset then
            scrollOffset = math.max(0, index - 1)
        elseif index > scrollOffset + visible then
            scrollOffset = math.max(0, index - visible)
        else
            return true
        end

        scrollOffset = math.max(0, math.min(scrollOffset, maxScrollOffset()))
        self:Refresh()
        return true
    end

    function list:SetUpdateRow(fn)
        updateRowFn = fn
    end

    viewport:EnableMouseWheel(true)
    viewport:SetScript("OnMouseWheel", function(_, delta)
        scrollOffset = scrollOffset - delta
        list:Refresh()
    end)
    viewport:SetScript("OnSizeChanged", function() list:Refresh() end)

    thumb:SetScript("OnMouseDown", function(self)
        self.dragging = true
        self.startY = select(2, GetCursorPosition())
        self.startOffset = scrollOffset
    end)
    thumb:SetScript("OnMouseUp", function(self) self.dragging = false end)
    thumb:SetScript("OnUpdate", function(self)
        if not self.dragging then return end

        local travel = track:GetHeight() - self:GetHeight()
        local maxOffset = maxScrollOffset()
        if travel <= 0 or maxOffset <= 0 then return end

        local _, y = GetCursorPosition()
        local scale = track:GetEffectiveScale()
        local movedDownPixels = (self.startY - y) / scale
        local deltaRows = (movedDownPixels / travel) * maxOffset

        scrollOffset = math.floor(self.startOffset + deltaRows + 0.5)
        list:Refresh()
    end)

    return list
end
