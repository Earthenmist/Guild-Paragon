local _, GP = ...
local Theme = GP.UI.Theme
local Tab = {}
GP.UI.GuildApplicantsTab = Tab
LibStub("AceEvent-3.0"):Embed(Tab)

local function text(parent, font, x, y)
    local label = parent:CreateFontString(nil, "ARTWORK")
    label:SetFontObject(Theme.font[font])
    label:SetPoint("TOPLEFT", x, y)
    label:SetJustifyH("LEFT")
    return label
end

local function literal(value)
    return (value or GP.L["Unavailable"]):gsub("|", "||")
end

local function classInfo(record)
    if not record or not record.classID then return nil end
    local ok, name, token = pcall(GetClassInfo, record.classID)
    if not ok or GP:IsSecretValue(name) or GP:IsSecretValue(token) then return nil end
    return type(name) == "string" and name or nil, type(token) == "string" and token or nil
end

local function colorName(label, record)
    local _, token = classInfo(record)
    local color = token and C_ClassColor and GP:SafeCall(C_ClassColor.GetClassColor, nil, token)
    if type(color) == "table" and not GP:IsSecretValue(color.r) and not GP:IsSecretValue(color.g)
        and not GP:IsSecretValue(color.b) and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
        label:SetTextColor(color.r, color.g, color.b)
    else
        label:SetTextColor(unpack(Theme.color.textPrimary))
    end
end

function Tab:UpdateNotification(module)
    local visible = module.notificationPending and not module.snoozed and module:CanUse()
        and module.state == "ready" and module.count and module.count > 0
    if not visible then
        if self.notification then self.notification:Hide() end
        return
    end
    if not self.notification then
        local popup = Theme:CreatePanel(UIParent, "panel", "border")
        popup:SetSize(410, 166)
        popup:SetPoint("TOP", UIParent, "TOP", 0, -160)
        popup:SetFrameStrata("DIALOG")
        local accent = popup:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("TOPLEFT", 1, -1)
        accent:SetPoint("TOPRIGHT", -1, -1)
        accent:SetHeight(2)
        accent:SetColorTexture(unpack(Theme.color.accent))
        local icon = popup:CreateTexture(nil, "ARTWORK")
        icon:SetSize(48, 48)
        icon:SetPoint("TOPLEFT", 18, -18)
        icon:SetTexture("Interface\\AddOns\\GuildParagon\\Media\\GuildParagonIcon")
        local brand = text(popup, "small", 80, -20)
        brand:SetText(GP.L["Guild Paragon"])
        brand:SetTextColor(unpack(Theme.color.accent))
        text(popup, "title", 80, -38):SetText(GP.L["Applications awaiting review"])
        popup.count = text(popup, "body", 20, -82)
        popup.count:SetPoint("TOPRIGHT", -20, -82)
        local review = Theme:CreateButton(popup, GP.L["Review applications"])
        review:SetPoint("BOTTOMLEFT", 20, 18)
        review:SetSize(220, 30)
        review:SetBackdropColor(unpack(Theme.color.accent))
        review.text:SetTextColor(unpack(Theme.color.backdrop))
        local dismiss = Theme:CreateButton(popup, GP.L["Dismiss"])
        dismiss:SetPoint("BOTTOMRIGHT", -20, 18)
        dismiss:SetSize(138, 30)
        local function acknowledge()
            module.notificationPending = nil
            popup:Hide()
        end
        dismiss:SetScript("OnClick", acknowledge)
        review:SetScript("OnClick", function()
            if not module:CheckContext() or module.state ~= "ready" then return end
            acknowledge()
            GP.UI.MainWindow:SelectTabByID("applications")
            if self.selectPending then self.selectPending() end
        end)
        self.notification = popup
    end
    self.notification.count:SetText(module.count == 1 and GP.L["1 application is waiting for your review."]
        or string.format(GP.L["%d applications are waiting for your review."], module.count))
    self.notification:Show()
end

function Tab:Build(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    local module = GP:GetModule("GuildApplicants")
    local view = {history=false}
    text(frame, "heading", 0, 0):SetText(GP.L["Guild Finder applications"])
    local status = text(frame, "body", 0, -32)
    status:SetPoint("TOPRIGHT", 0, -32)
    local pending = Theme:CreateButton(frame, GP.L["Pending applications"])
    pending:SetPoint("TOPLEFT", 0, -70)
    local history = Theme:CreateButton(frame, GP.L["Applicant history"])
    history:SetPoint("LEFT", pending, "RIGHT", 8, 0)
    local refresh = Theme:CreateButton(frame, GP.L["Refresh"])
    refresh:SetPoint("LEFT", history, "RIGHT", 16, 0)
    local reminders = Theme:CreateButton(frame, GP.L["Mute reminders until reload"])
    reminders:SetPoint("TOPRIGHT", 0, -70)
    local last = text(frame, "small", 0, -106)
    last:SetPoint("TOPRIGHT", 0, -106)

    local panel = Theme:CreatePanel(frame, "panel", "border")
    panel:SetPoint("TOPLEFT", 0, -132)
    panel:SetPoint("BOTTOMRIGHT", 0, 252)
    local empty = text(panel, "muted", 12, -12)
    empty:SetPoint("TOPRIGHT", -12, -12)
    local list
    list = GP.UI.ScrollList:New(panel, 30, function(container)
        local row = CreateFrame("Button", nil, container, "BackdropTemplate")
        row:SetBackdrop((Theme:Backdrop("panelRaised")))
        row.name = text(row, "body", 10, -9)
        row.name:SetWidth(200)
        row.name:SetWordWrap(false)
        row.status = row:CreateFontString(nil, "ARTWORK")
        row.status:SetFontObject(Theme.font.muted)
        row.status:SetPoint("TOPRIGHT", -12, -9)
        row.status:SetWidth(180)
        row.status:SetJustifyH("RIGHT")
        row.status:SetWordWrap(false)
        row.info = text(row, "small", 220, -9)
        row.info:SetPoint("TOPRIGHT", -204, -9)
        row.info:SetWordWrap(false)
        row:SetScript("OnClick", function()
            view.selected, view.token, view.feedback = row.record, nil, nil
            module.confirmation = nil
            if view.noteScroll then view.noteScroll:SetVerticalScroll(0) end
            view.update()
        end)
        row:SetScript("OnEnter", function() row:SetBackdropColor(unpack(Theme.color.panelRaised)) end)
        row:SetScript("OnLeave", function() list:Refresh() end)
        return row
    end)
    list:SetUpdateRow(function(row, record)
        row.record = record
        row.name:SetText(literal(record.name))
        colorName(row.name, record)
        row.info:SetText(string.format(GP.L["Level %s | %s | Item level %s"], record.level or "?", literal(classInfo(record)), record.ilvl or "?"))
        row.status:SetText(module:StatusLabel(record.requestStatus))
        local selected = view.selected and view.selected.playerGUID == record.playerGUID
        if selected then
            row:SetBackdropColor(unpack(Theme.color.panelRaised))
            row:SetBackdropBorderColor(unpack(Theme.color.accent))
        else
            row:SetBackdropColor(0, 0, 0, 0)
            row:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end)
    local detail = Theme:CreatePanel(frame, "panel", "border")
    detail:SetPoint("BOTTOMLEFT", 0, 82)
    detail:SetPoint("BOTTOMRIGHT", 0, 82)
    detail:SetHeight(156)
    local name = text(detail, "body", 12, -10)
    name:SetPoint("TOPRIGHT", -12, -10)
    local info = text(detail, "small", 12, -34)
    info:SetPoint("TOPRIGHT", -12, -34)
    local scroll = CreateFrame("ScrollFrame", nil, detail)
    scroll:SetPoint("TOPLEFT", 12, -64)
    scroll:SetPoint("BOTTOMRIGHT", -12, 26)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    local note = text(content, "body", 0, 0)
    scroll:SetScrollChild(content)
    view.noteScroll = scroll
    local hint = text(detail, "small", 12, 0)
    hint:ClearAllPoints()
    hint:SetPoint("BOTTOMRIGHT", -12, 8)
    hint:SetText(GP.L["Scroll to read more"])
    local function fitNote()
        local width = math.max(1, scroll:GetWidth())
        content:SetWidth(width)
        note:SetWidth(width)
        local height = math.max(1, note:GetStringHeight())
        content:SetHeight(height)
        local overflow = math.max(0, height-scroll:GetHeight())
        hint:SetShown(overflow > 0)
        scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), overflow))
    end
    scroll:SetScript("OnSizeChanged", fitNote)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local maximum = math.max(0, content:GetHeight()-scroll:GetHeight())
        scroll:SetVerticalScroll(math.max(0, math.min(maximum, scroll:GetVerticalScroll()-delta*24)))
    end)

    local approve = Theme:CreateButton(frame, GP.L["Approve"])
    approve:SetPoint("BOTTOMLEFT", 0, 44)
    local decline = Theme:CreateButton(frame, GP.L["Decline"])
    decline:SetPoint("LEFT", approve, "RIGHT", 8, 0)
    local confirm = Theme:CreateButton(frame, GP.L["Confirm"])
    confirm:SetPoint("LEFT", decline, "RIGHT", 20, 0)
    local cancel = Theme:CreateButton(frame, GP.L["Cancel"])
    cancel:SetPoint("LEFT", confirm, "RIGHT", 8, 0)
    local feedback = text(frame, "body", 0, 0)
    feedback:ClearAllPoints()
    feedback:SetPoint("BOTTOMLEFT", 0, 4)
    feedback:SetPoint("BOTTOMRIGHT", 0, 4)

    function view.update()
        local allowed = module:CanUse() and module.clubID ~= nil and module.state ~= "waiting"
        status:SetText(module:StatusText())
        pending:SetBackdropBorderColor(unpack(view.history and Theme.color.accentDim or Theme.color.accent))
        history:SetBackdropBorderColor(unpack(view.history and Theme.color.accent or Theme.color.accentDim))
        refresh:SetEnabled(module:CanUse() and not module.pending)
        reminders.text:SetText(module.snoozed and GP.L["Enable reminders"] or GP.L["Mute reminders until reload"])
        last:SetText(module.lastSuccess and string.format(GP.L["Last successful check: %s"], date("%H:%M:%S", module.lastSuccess)) or "")
        local rows = allowed and (view.history and module.historyAvailable and module.history
            or not view.history and module.applicants) or {}
        rows = rows or {}
        local selected
        for _, row in ipairs(rows) do
            if view.selected and row.playerGUID == view.selected.playerGUID then selected = row; break end
        end
        view.selected = selected
        if not selected or not allowed or module.state ~= "ready" or module.confirmation ~= view.token then view.token = nil end
        list:SetData(rows)
        empty:SetShown(#rows == 0)
        empty:SetText(not allowed and GP.L["Application data is unavailable. Refresh and try again."]
            or view.history and (module.historyAvailable and GP.L["No applicant history available."] or GP.L["Applicant history is unavailable from Blizzard."])
            or module.count == 0 and GP.L["No applications awaiting review."] or GP.L["Waiting for a fresh response from Blizzard."])
        name:SetText(selected and literal(selected.name) or GP.L["Select an applicant to view their details."])
        colorName(name, selected)
        local specs = {}
        if selected then
            for _, id in ipairs(selected.specIds) do
                local ok, _, specName = pcall(GetSpecializationInfoByID, id)
                if ok and not GP:IsSecretValue(specName) and type(specName) == "string" then specs[#specs+1] = specName end
            end
        end
        local class = selected and selected.classID and GP:SafeCall(GetClassInfo, nil, selected.classID)
        if type(class) ~= "string" then class = nil end
        info:SetText(selected and string.format(GP.L["Level %s | %s | Item level %s | %s"],
            selected.level or "?", literal(class), selected.ilvl or "?", module:StatusLabel(selected.requestStatus))
            .. (#specs > 0 and "\n" .. table.concat(specs, ", ") or "") or "")
        local audit = GP:GetModule("ApplicantAudit", true)
        local auditText = selected and audit and type(audit.Text) == "function" and audit:Text(selected) or nil
        note:SetText(selected and (literal(selected.message) .. (auditText and "\n\n" .. auditText or "")) or "")
        fitNote()
        local actionable = allowed and module.state == "ready" and not view.history and selected
            and selected.name and selected.clubFinderGUID and not (module.responses and module.responses[selected.playerGUID])
        approve:SetEnabled(actionable and not view.token and true or false)
        decline:SetEnabled(actionable and not view.token and true or false)
        confirm:SetShown(view.token ~= nil)
        cancel:SetShown(view.token ~= nil)
        if view.token then
            feedback:SetText(string.format(view.token.approve and GP.L["Approve %s's guild application?"] or GP.L["Decline %s's guild application?"], literal(view.token.row.name)))
        else
            feedback:SetText(view.feedback or module.actionMessage or GP.L["Select a pending application, then approve or decline it. History is read-only."])
        end
    end
    local function changeView(showHistory)
        view.history, view.selected, view.token, view.feedback = showHistory, nil, nil, nil
        module.confirmation = nil
        scroll:SetVerticalScroll(0)
        list:SetData({}, true)
        view.update()
    end
    self.selectPending = function() changeView(false) end
    pending:SetScript("OnClick", self.selectPending)
    history:SetScript("OnClick", function() changeView(true) end)
    refresh:SetScript("OnClick", function() module:Request() end)
    reminders:SetScript("OnClick", function()
        module.snoozed = not module.snoozed
        if module.snoozed then module.notificationPending = nil end
        module:NotifyChanged()
    end)
    local function prepare(accept)
        view.token, view.feedback = module:PrepareResponse(view.selected, accept)
        view.update()
    end
    approve:SetScript("OnClick", function() prepare(true) end)
    decline:SetScript("OnClick", function() prepare(false) end)
    confirm:SetScript("OnClick", function()
        local token = view.token
        view.token = nil
        local _, message = module:ConfirmResponse(token)
        view.feedback = message
        view.update()
    end)
    cancel:SetScript("OnClick", function() view.token, module.confirmation = nil, nil; view.update() end)
    frame:SetScript("OnHide", function() view.token, module.confirmation = nil, nil end)
    self:RegisterMessage("GuildParagon_ApplicantsChanged", function() view.feedback = nil; view.update() end)
    self:RegisterMessage("GuildParagon_ApplicantAuditChanged", function() view.update() end)
    frame.OnSelected = function() module:Request(); view.update() end
    frame.OnAccessChanged = view.update
    view.update()
    return frame
end
