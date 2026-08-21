local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.PostKickPrompt = GP.UI.PostKickPrompt or {}
local PostKickPrompt = GP.UI.PostKickPrompt

local frame

local function makeCheck(parent, label)
    local check = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    check.Text:SetFontObject(Theme.font.body)
    check.Text:SetText(label)
    check:SetHitRectInsets(0, -220, 0, 0)
    return check
end

local function linkedCounts(context)
    local total, kickable = 0, 0
    for _, linked in ipairs(context and context.linked or {}) do
        total = total + 1
        if linked.kickable then kickable = kickable + 1 end
    end
    return total, kickable
end

local function linkedNames(context, onlyKickable)
    local names = {}
    for _, linked in ipairs(context and context.linked or {}) do
        if not onlyKickable or linked.kickable then
            table.insert(names, linked.name or GP.L["Unknown"])
        end
    end
    if #names == 0 then return GP.L["None"] end
    return table.concat(names, ", ")
end

local function hide()
    if frame then
        frame:Hide()
    end
end

local function build()
    frame = Theme:CreatePanel(UIParent, "panel", "accent")
    frame:SetSize(430, 360)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    local title = frame:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.title)
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText(GP.L["Post-Kick Review"])
    frame.title = title

    local close = Theme:CreateCloseButton(frame)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", hide)

    local body = frame:CreateFontString(nil, "ARTWORK")
    body:SetFontObject(Theme.font.body)
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    body:SetPoint("RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    frame.body = body

    local linked = frame:CreateFontString(nil, "ARTWORK")
    linked:SetFontObject(Theme.font.small)
    linked:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -10)
    linked:SetPoint("RIGHT", -16, 0)
    linked:SetJustifyH("LEFT")
    linked:SetWordWrap(true)
    frame.linked = linked

    local reasonLabel = frame:CreateFontString(nil, "ARTWORK")
    reasonLabel:SetFontObject(Theme.font.small)
    reasonLabel:SetPoint("TOPLEFT", linked, "BOTTOMLEFT", 0, -14)
    reasonLabel:SetText(GP.L["Ban Reason:"])

    local reason = Theme:CreateEditBox(frame, 360)
    reason:SetHeight(62)
    reason:SetPoint("TOPLEFT", reasonLabel, "BOTTOMLEFT", 0, -4)
    reason:SetPoint("RIGHT", -16, 0)
    reason:SetMultiLine(true)
    reason:SetMaxLetters(500)
    reason:SetJustifyV("TOP")
    reason:SetTextInsets(8, 8, 6, 6)
    frame.reason = reason

    local ban = makeCheck(frame, GP.L["Add kicked character to Ban List"])
    ban:SetPoint("TOPLEFT", reason, "BOTTOMLEFT", -4, -10)
    frame.ban = ban

    local banLinked = makeCheck(frame, GP.L["Also add linked characters to Ban List"])
    banLinked:SetPoint("TOPLEFT", ban, "BOTTOMLEFT", 0, -4)
    frame.banLinked = banLinked

    local kickLinked = makeCheck(frame, GP.L["Build kick macro for linked characters"])
    kickLinked:SetPoint("TOPLEFT", banLinked, "BOTTOMLEFT", 0, -4)
    frame.kickLinked = kickLinked

    local status = frame:CreateFontString(nil, "ARTWORK")
    status:SetFontObject(Theme.font.small)
    status:SetPoint("BOTTOMLEFT", 16, 48)
    status:SetPoint("RIGHT", -16, 0)
    status:SetJustifyH("LEFT")
    status:SetTextColor(unpack(Theme.color.textSecondary))
    frame.status = status

    local confirm = Theme:CreateButton(frame, GP.L["Confirm"])
    confirm:SetPoint("BOTTOMRIGHT", -16, 14)
    frame.confirm = confirm

    local skip = Theme:CreateButton(frame, GP.L["Skip"])
    skip:SetPoint("RIGHT", confirm, "LEFT", -8, 0)
    skip:SetScript("OnClick", hide)

    confirm:SetScript("OnClick", function()
        local context = frame.context
        if not context then hide() return end

        local didSomething = false
        if frame.ban:GetChecked() then
            local ok, err, count = GP:GetModule("PostKick"):AddBans(context, frame.reason:GetText(), frame.banLinked:GetChecked())
            if not ok then
                frame.status:SetText(err or GP.L["Could not update Ban List."])
                return
            end
            didSomething = true
            GP:Print(string.format(GP.L["Added %d post-kick Ban List record(s)."], count or 0))
        end

        if frame.kickLinked:GetChecked() then
            local ok, err, count = GP:GetModule("PostKick"):BuildLinkedKickMacro(context)
            if not ok then
                frame.status:SetText(err or GP.L["Could not build linked-character kick macro."])
                return
            end
            didSomething = true
            GP:Print(string.format(GP.L["Built linked-character kick macro for %d character(s)."], count or 0))
        end

        if not didSomething then
            GP:Print(GP.L["Post-kick review skipped."])
        end
        hide()
    end)
end

function PostKickPrompt:Show(context)
    if not frame then build() end
    frame.context = context

    local linkedTotal, kickableTotal = linkedCounts(context)
    frame.body:SetText(string.format(GP.L["%s was removed from the guild by this client. Choose any follow-up actions."], context.name or GP.L["Unknown"]))
    frame.linked:SetText(string.format(GP.L["Linked active characters: %s"], linkedNames(context, false)))
    frame.reason:SetText("")
    frame.ban:SetChecked(true)
    frame.banLinked:SetChecked(linkedTotal > 0)
    frame.banLinked:SetEnabled(linkedTotal > 0)
    frame.kickLinked:SetChecked(kickableTotal > 0)
    frame.kickLinked:SetEnabled(kickableTotal > 0)
    frame.banLinked.Text:SetText(string.format(GP.L["Also add linked characters to Ban List (%d)"], linkedTotal))
    frame.kickLinked.Text:SetText(string.format(GP.L["Build kick macro for linked characters (%d)"], kickableTotal))
    frame.status:SetText(kickableTotal > 0 and string.format(GP.L["Kick macro targets: %s"], linkedNames(context, true)) or GP.L["No linked characters can be removed by this character."])

    frame:Show()
    frame.reason:SetFocus()
end

function PostKickPrompt:Hide()
    hide()
end

