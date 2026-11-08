-- Read-only Blizzard guild information; no native frame navigation or writes.
local _, GP = ...
local Theme = GP.UI.Theme
local Info = {}
GP.UI.GuildInfoPage = Info

local function clean(value, kind)
    if not GP:IsSecretValue(value) and type(value) == kind then return value end
end
local function read(fn, kind, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return clean(value, kind) end
end
function Info:IsSafe()
    local applicants = GP:GetModule("GuildApplicants", true)
    return applicants and applicants:IsSafe() and read(IsInGuild, "boolean") == true
end
function Info:RequestData()
    if not self:IsSafe() then return false end
    local now = GetTime()
    if self.lastRequest and now - self.lastRequest < 30 then return false end
    self.lastRequest = now
    -- Guild text is populated by the roster response, independently of news.
    GP:RequestNativeGuildRoster()
    if not GP:IsForeverClient() and RequestGuildChallengeInfo then pcall(RequestGuildChallengeInfo) end
    if QueryGuildNews then pcall(QueryGuildNews) end
    return true
end
function Info:NewsText(index)
    if not self:IsSafe() then return GP.L["Unavailable"] end
    local entry = read(C_GuildInfo and C_GuildInfo.GetGuildNewsInfo, "table", index)
    if not entry then return GP.L["Unavailable"] end
    if clean(entry.isHeader, "boolean") then
        local day, month = clean(entry.day, "number"), clean(entry.month, "number")
        local weekday = clean(entry.weekday, "number")
        local name = weekday and CALENDAR_WEEKDAY_NAMES and CALENDAR_WEEKDAY_NAMES[weekday + 1]
        local stamp = day and month and string.format("%02d/%02d", day + 1, month + 1) or GP.L["Guild News"]
        return name and (name .. " " .. stamp) or stamp, true
    end
    local kind = clean(entry.newsType, "number")
    local who = clean(entry.whoText, "string") or GP.L["Unknown"]
    local what = clean(entry.whatText, "string") or GP.L["Unavailable"]
    local link
    if kind == 3 or kind == 4 or kind == 5 or kind == 8 then
        if what:find("|Hitem:", 1, true) or what:match("^item:") then link = what end
    elseif kind == 0 or kind == 1 then
        what = "|cffffff00[" .. what .. "]|r"
    end
    if kind == 0 then who = what end
    local format = kind and _G["GUILD_NEWS_FORMAT" .. kind]
    if type(format) == "string" then
        local ok, text = pcall(string.format, format, who, what)
        if ok then return text, false, link end
    end
    return who .. " — " .. what, false, link
end
function Info:ShowNewsTooltip(row)
    GameTooltip:Hide()
    if not row.newsIndex or not self:IsSafe() then return end
    local value, header, link = self:NewsText(row.newsIndex)
    if header then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if link then
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
        if not ok then GameTooltip:SetText(value, 1, 1, 1, 1, true) end
    else
        GameTooltip:SetText(value, 1, 1, 1, 1, true)
    end
    GameTooltip:Show()
end
function Info:Challenges()
    local rows = {}
    if GP:IsForeverClient() then return rows end
    if not self:IsSafe() then return rows, GP.L["Unavailable"] end
    local count = read(GetNumGuildChallenges, "number") or 0
    -- Native Retail display order: dungeon, Mythic+, raid, rated battleground.
    for _, index in ipairs({1, 4, 2, 3}) do
        if index <= count and (index ~= 4 or not GP:IsForeverClient()) then
            local ok, id, current, maximum = pcall(GetGuildChallengeInfo, index)
            id, current, maximum = clean(id, "number"), clean(current, "number"), clean(maximum, "number")
            if ok and id and current and maximum then
                rows[#rows + 1] = {
                    index = index,
                    label = _G["GUILD_CHALLENGE_TYPE" .. id] or GP.L["Guild Challenges"],
                    current = current, maximum = maximum,
                    complete = maximum > 0 and current == maximum,
                }
            end
        end
    end
    return rows, GP.L["No challenge data available."]
end

function Info:ShowChallengeTooltip(row)
    GameTooltip:Hide()
    if not row.challengeIndex or not self:IsSafe() or type(GetGuildChallengeInfo) ~= "function" then return end
    local ok, id, _, _, _, gold = pcall(GetGuildChallengeInfo, row.challengeIndex)
    id, gold = clean(id, "number"), clean(gold, "number")
    if not ok or not id then return end
    local title = _G["GUILD_CHALLENGE_LABEL" .. id]
    local description = _G["GUILD_CHALLENGE_TOOLTIP" .. id]
    if type(title) ~= "string" or type(description) ~= "string" then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(title)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(description, 1, 1, 1, true)
    if gold and gold >= 0 and gold < math.huge and type(GUILD_CHALLENGE_REWARD_GOLD) == "string" then
        local money = read(GetMoneyString, "string", gold * (COPPER_PER_SILVER or 100) * (SILVER_PER_GOLD or 100))
        if money then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string.format(GUILD_CHALLENGE_REWARD_GOLD, money), 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

local function text(parent, title)
    local label = parent:CreateFontString(nil, "ARTWORK")
    label:SetFontObject(Theme.font.body)
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetText(title or "")
    return label
end
local function panel(parent, title)
    local box = Theme:CreatePanel(parent, "panel", "border")
    local heading = text(box, GP.L[title])
    heading:SetPoint("TOPLEFT", 12, -10)
    heading:SetTextColor(unpack(Theme.color.accent))
    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 12, -34)
    scroll:SetPoint("BOTTOMRIGHT", -12, 12)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    local body = text(child)
    body:SetPoint("TOPLEFT")
    body:SetPoint("TOPRIGHT")
    local function resize()
        child:SetWidth(math.max(1, scroll:GetWidth()))
        child:SetHeight(math.max(1, body:GetStringHeight() + 8))
        scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), math.max(0, child:GetHeight() - scroll:GetHeight())))
    end
    scroll:SetScript("OnSizeChanged", resize)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        scroll:SetVerticalScroll(math.max(0, math.min(math.max(0, child:GetHeight() - scroll:GetHeight()), scroll:GetVerticalScroll() - delta * 30)))
    end)
    local function scheduleResize()
        if box.resizePending then return end
        box.resizePending = true
        C_Timer.After(0, function()
            box.resizePending = nil
            if box:IsShown() then resize() end
        end)
    end
    box:SetScript("OnShow", scheduleResize)
    function box:SetText(value)
        body:SetText(value, true)
        resize()
        scheduleResize()
    end
    return box
end
local function challengePanel(parent)
    local box = Theme:CreatePanel(parent, "panel", "border")
    local heading = text(box, GP.L["Guild Challenges"])
    heading:SetPoint("TOPLEFT", 12, -10)
    heading:SetTextColor(unpack(Theme.color.accent))
    local empty = text(box)
    empty:SetPoint("TOPLEFT", 18, -38)
    local rows = {}
    for i = 1, 4 do
        local row = CreateFrame("Frame", nil, box)
        row:SetPoint("TOPLEFT", 18, -30 - (i - 1) * 32)
        row:SetPoint("TOPRIGHT", -14, -30 - (i - 1) * 32)
        row:SetHeight(30)
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self) Info:ShowChallengeTooltip(self) end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnHide", function(self)
            if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        end)
        row.label = text(row)
        row.label:SetPoint("LEFT")
        row.label:SetPoint("RIGHT", -78, 0)
        row.label:SetJustifyV("MIDDLE")
        row.count = text(row)
        row.count:SetPoint("RIGHT", -4, 0)
        row.count:SetTextColor(1, 0.82, 0)
        row.check = row:CreateTexture(nil, "ARTWORK")
        row.check:SetTexture("Interface\\GuildFrame\\GuildChallenges")
        row.check:SetTexCoord(0.00195313, 0.05664063, 0.00390625, 0.09765625)
        row.check:SetSize(28, 24)
        row.check:SetPoint("RIGHT")
        rows[i] = row
    end
    function box:Refresh()
        local data, message = Info:Challenges()
        empty:SetText(message)
        empty:SetShown(#data == 0)
        for i, row in ipairs(rows) do
            local entry = data[i]
            row.challengeIndex = entry and entry.index or nil
            row:SetShown(entry ~= nil)
            if entry then
                row.label:SetText(entry.label)
                if entry.complete then row.label:SetTextColor(0.1, 1, 0.1)
                else row.label:SetTextColor(unpack(Theme.color.textPrimary)) end
                row.count:SetText(entry.current .. " / " .. entry.maximum)
                row.count:SetShown(not entry.complete)
                row.check:SetShown(entry.complete)
            end
        end
    end
    return box
end

function Info:Build(page)
    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    left:SetWidth(360)
    local challenges
    if not GP:IsForeverClient() then
        challenges = challengePanel(left)
        challenges:SetPoint("TOPLEFT")
        challenges:SetPoint("TOPRIGHT")
        challenges:SetHeight(175)
    end
    local motd = panel(left, "Message of the Day")
    if challenges then
        motd:SetPoint("TOPLEFT", challenges, "BOTTOMLEFT", 0, -8)
        motd:SetPoint("TOPRIGHT", challenges, "BOTTOMRIGHT", 0, -8)
    else
        motd:SetPoint("TOPLEFT")
        motd:SetPoint("TOPRIGHT")
    end
    motd:SetHeight(135)
    local editMOTD = Theme:CreateButton(motd, GP.L["Edit in Blizzard"])
    editMOTD:SetSize(110, 22)
    editMOTD:SetPoint("TOPRIGHT", -8, -5)
    editMOTD:SetScript("OnClick", function() GP.UI.GuildMOTDEditor:Open() end)
    local details = panel(left, "Guild Information")
    details:SetPoint("TOPLEFT", motd, "BOTTOMLEFT", 0, -8)
    details:SetPoint("BOTTOMRIGHT")
    local editInfo = Theme:CreateButton(details, GP.L["Edit in Blizzard"])
    editInfo:SetSize(110, 22)
    editInfo:SetPoint("TOPRIGHT", -8, -5)
    editInfo:SetScript("OnClick", function() GP.UI.GuildMOTDEditor:Open("info") end)
    local news = Theme:CreatePanel(page, "panel", "border")
    news:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    news:SetPoint("BOTTOMRIGHT")
    local heading = text(news, GP.L["Guild News"])
    heading:SetPoint("TOPLEFT", 12, -10)
    heading:SetTextColor(unpack(Theme.color.accent))
    local status = text(news)
    status:SetPoint("TOPLEFT", 12, -32)
    local area = CreateFrame("Frame", nil, news)
    area:SetPoint("TOPLEFT", 10, -34)
    area:SetPoint("BOTTOMRIGHT", -10, 10)
    local list = GP.UI.ScrollList:New(area, 24, function(parent)
        local row = CreateFrame("Frame", nil, parent)
        row.text = text(row)
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetPoint("RIGHT", -6, 0)
        row.text:SetWordWrap(false)
        row.text:SetJustifyV("MIDDLE")
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self) Info:ShowNewsTooltip(self) end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnHide", function(self)
            if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
        end)
        return row
    end)
    list:SetUpdateRow(function(row, index)
        row.newsIndex = index
        local value, header = Info:NewsText(index)
        row.text:SetText(header and value or ("- " .. value))
        if header then row.text:SetTextColor(1, 0.82, 0)
        else row.text:SetTextColor(unpack(Theme.color.textPrimary)) end
        if GameTooltip:IsOwned(row) then Info:ShowNewsTooltip(row) end
    end)
    function page:Refresh()
        if not self:IsShown() then return end
        editMOTD:SetShown(GP.UI.GuildMOTDEditor:CanEdit())
        editInfo:SetShown(GP.UI.GuildMOTDEditor:CanEdit("info"))
        if not Info:IsSafe() then
            if challenges then challenges:Refresh() end
            motd:SetText(GP.L["Unavailable"])
            details:SetText(GP.L["Unavailable"])
            status:SetText(GP.L["Guild information pauses during combat, loading and protected instances."])
            list:SetData({})
            return
        end
        if challenges then challenges:Refresh() end
        motd:SetText(read(C_GuildInfo and C_GuildInfo.GetMOTD or GetGuildRosterMOTD, "string") or GP.L["Unavailable"])
        details:SetText(read(C_GuildInfo and C_GuildInfo.GetInfoText or GetGuildInfoText, "string") or GP.L["Unavailable"])
        local count = read(GetNumGuildNews, "number") or 0
        local rows = {}
        for i = 1, math.min(count, 500) do rows[i] = i end
        status:SetText(count > 0 and "" or GP.L["No guild news available."])
        list:SetData(rows)
    end
    local function request()
        Info:RequestData()
        page:Refresh()
    end
    page.OnSelected = request
    page:SetScript("OnShow", request)
    page:SetScript("OnHide", function() GameTooltip:Hide() end)
    for _, event in ipairs({"GUILD_RANKS_UPDATE", "GUILD_NEWS_UPDATE", "GUILD_CHALLENGE_UPDATED", "GUILD_MOTD", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD"}) do
        if event ~= "GUILD_CHALLENGE_UPDATED" or not GP:IsForeverClient() then
            GP:RegisterOptionalEvent(page, event)
        end
    end
    page:SetScript("OnEvent", function(self, event)
        if not self:IsShown() then return end
        if event == "PLAYER_GUILD_UPDATE" then Info.lastRequest = nil end
        if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
            Info:RequestData()
        end
        if self.pending then return end
        self.pending = true
        C_Timer.After(0.2, function() self.pending = nil; self:Refresh() end)
    end)
    page:Refresh()
    return page
end
