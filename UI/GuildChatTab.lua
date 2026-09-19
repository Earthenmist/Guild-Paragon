local _, GP = ...
local Theme = GP.UI.Theme
local Chat = GP.GuildChatView
GP.UI.GuildChatTab = {}
function GP.UI.GuildChatTab:Build(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local kind, club, stream, cursor, oldest = "guild"
    local generation, lastRequest, pending = 0, -30, false
    local refreshQueued = false
    local channels = {}
    local records, rendered = {}, {}
    local atBeginning=false
    local privacyRevealed=false
    local loadOlder
    local heading = page:CreateFontString(nil,"ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(GP.L["Guild Chat"])
    local dropdown = Theme:CreateButton(page, GP.L["Guild"] .. "  v")
    dropdown:SetSize(180,26)
    dropdown:SetPoint("TOPLEFT",0,-36)
    local latest = Theme:CreateButton(page,GP.L["Latest"])
    latest:SetPoint("LEFT",dropdown,"RIGHT",10,0)
    local status = page:CreateFontString(nil,"ARTWORK")
    status:SetFontObject(Theme.font.body)
    status:SetPoint("TOPLEFT",0,-74)
    status:SetPoint("TOPRIGHT",0,-74)
    status:SetJustifyH("LEFT")
    local panel = Theme:CreatePanel(page,"panel","border")
    panel:SetPoint("TOPLEFT",0,-100)
    panel:SetPoint("BOTTOMRIGHT",0,52)
    local history = CreateFrame("ScrollingMessageFrame",nil,panel)
    history:SetPoint("TOPLEFT",12,-12)
    history:SetPoint("BOTTOMRIGHT",-28,12)
    history:SetFontObject(Theme.font.body)
    history:SetJustifyH("LEFT")
    history:SetFading(false)
    history:SetMaxLines(2000)
    history:EnableMouseWheel(true)
    history:SetScript("OnMouseWheel",function(self,delta)
        if delta>0 then
            self:ScrollUp()
            if self:GetMaxScrollRange()-self:GetScrollOffset()<=math.max(0,self:GetNumVisibleLines()-2)
                and loadOlder then loadOlder() end
        else self:ScrollDown() end
    end)
    history:SetHyperlinksEnabled(true)
    history:SetScript("OnHyperlinkClick",function(_,link,_,button)
        if button~="LeftButton" or GP:IsSecretValue(link) or type(link)~="string" then return end
        if Chat:PrivacyEnabled() and not privacyRevealed then return end
        for _,record in ipairs(records) do
            if record.link==link then Chat:OpenWhisper(club,stream,kind,record);return end
        end
    end)
    local scrollbar = CreateFrame("Slider",nil,panel,"BackdropTemplate")
    scrollbar:SetPoint("TOPRIGHT",-8,-12)
    scrollbar:SetPoint("BOTTOMRIGHT",-8,12)
    scrollbar:SetWidth(8)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetBackdrop(Theme:Backdrop("panelRaised","border"))
    scrollbar:SetBackdropColor(unpack(Theme.color.panelRaised))
    scrollbar:SetBackdropBorderColor(unpack(Theme.color.border))
    scrollbar:SetValueStep(1)
    scrollbar:SetObeyStepOnDrag(true)
    local thumb=scrollbar:CreateTexture(nil,"ARTWORK")
    thumb:SetSize(8,32)
    thumb:SetColorTexture(unpack(Theme.color.accent))
    scrollbar:SetThumbTexture(thumb)
    local adjusting=false
    local function updateScrollbar()
        adjusting=true
        local maximum=history:GetMaxScrollRange()
        scrollbar:SetMinMaxValues(0,math.max(1,maximum))
        scrollbar:SetValue(maximum>0 and maximum-history:GetScrollOffset() or 1)
        scrollbar:SetEnabled(maximum>0)
        adjusting=false
    end
    scrollbar:SetScript("OnValueChanged",function(_,v)
        if not adjusting then
            history:SetScrollOffset(history:GetMaxScrollRange()-v)
            if v<=math.max(0,history:GetNumVisibleLines()-2) and loadOlder then loadOlder() end
        end
    end)
    history:SetOnScrollChangedCallback(updateScrollbar)
    history:HookScript("OnSizeChanged",updateScrollbar)
    local send = Theme:CreateButton(page,GP.L["Send"])
    send:SetPoint("BOTTOMRIGHT",0,8)
    send:SetWidth(90)
    local input = Theme:CreateEditBox(page,400)
    input:ClearAllPoints()
    input:SetPoint("BOTTOMLEFT",0,8)
    input:SetPoint("BOTTOMRIGHT",send,"BOTTOMLEFT",-10,0)
    input:SetMaxBytes(255)
    input:SetAutoFocus(false)
    local menu = Theme:CreatePanel(page,"panel","border")
    menu:SetPoint("TOPLEFT",dropdown,"BOTTOMLEFT",0,-2)
    menu:SetSize(180,56)
    menu:SetFrameStrata("DIALOG")
    menu:Hide()
    local privacy=CreateFrame("Button",nil,panel)
    privacy:SetAllPoints(panel)
    local privacyBackground=privacy:CreateTexture(nil,"BACKGROUND")
    privacyBackground:SetAllPoints()
    privacyBackground:SetColorTexture(0.08,0.09,0.11,1)
    local privacyText=privacy:CreateFontString(nil,"OVERLAY")
    privacyText:SetFontObject(Theme.font.title)
    privacyText:SetPoint("CENTER")
    privacyText:SetText(GP.L["Click to Show"])
    privacy:Hide()
    local refresh, request
    local function clear()
        generation=generation+1; pending=false
        records,rendered={},{};atBeginning=false;privacyRevealed=false
        privacy:Hide()
        club,stream,cursor,oldest=nil,nil,nil,nil
        history:Clear();updateScrollbar();input:SetText("");input:ClearFocus();menu:Hide()
        input:Disable();send:Disable()
    end
    refresh = function()
        if not page:IsShown() then return end
        local nextClub, nextChannels = Chat:Channels()
        channels=nextChannels
        local nextStream=channels[kind]
        if not nextClub or not nextStream then
            clear()
            dropdown:SetEnabled(nextClub ~= nil)
            status:SetText(GP.L["Chat is unavailable here or you no longer have access to this channel."])
            return
        end
        if club ~= nextClub or stream ~= nextStream then clear();club,stream=nextClub,nextStream end
        dropdown:Enable()
        dropdown.text:SetText(GP.L[kind=="officer" and "Officer" or "Guild"] .. "  v")
        local _, first, beginning, incoming = Chat:Messages(club,stream,kind,cursor)
        local offset=history:GetScrollOffset()
        local anchor=offset>0 and rendered[#rendered-offset]
        records=Chat:Merge(records,incoming or {},cursor~=nil)
        oldest=records[1] and records[1].id or first
        if first and oldest and first.epoch==oldest.epoch and first.position==oldest.position then
            atBeginning=beginning
        end
        rendered=Chat:Lines(records)
        history:Clear()
        for i,line in ipairs(rendered) do
            if line.heading then history:AddMessage(line.text,1,0.82,0.2)
            elseif kind=="officer" then history:AddMessage(line.text,0.25,0.85,0.45)
            else history:AddMessage(line.text,0.4,1,0.4) end
            if anchor and line.key==anchor.key then offset=#rendered-i end
        end
        if offset>0 then history:SetScrollOffset(offset) else history:ScrollToBottom() end
        updateScrollbar()
        local covered=Chat:PrivacyEnabled() and not privacyRevealed
        privacy:SetShown(covered)
        history:SetShown(not covered);scrollbar:SetShown(not covered)
        if covered then input:ClearFocus() end
        local canSend=not covered and Chat:CanSend(club,stream,kind)
        input:SetEnabled(canSend);send:SetEnabled(canSend)
        status:SetText(pending and GP.L["Loading chat..."] or (#rendered==0 and GP.L["No messages available."]
            or GP.L["Scroll to the top to load earlier history; use Latest to return to the newest messages."]))
    end
    privacy:SetScript("OnClick",function()privacyRevealed=true;refresh()end)
    request = function()
        refresh()
        if not club or not stream or pending or GetTime()-lastRequest<2 then return end
        lastRequest=GetTime()
        local ok, available=Chat:Request(club,stream,kind,cursor)
        pending=ok and not available
        refresh()
        if not pending then return end
        local token=generation
        local requestedAt=lastRequest
        C_Timer.After(5,function()
            if token~=generation or requestedAt~=lastRequest or not page:IsShown() then return end
            pending=false;refresh()
        end)
    end
    for i,key in ipairs({"guild","officer"}) do
        local option=Theme:CreateButton(menu,GP.L[key=="guild" and "Guild" or "Officer"])
        option:SetPoint("TOPLEFT",2,-2-(i-1)*26);option:SetSize(176,24)
        option:SetScript("OnClick",function()
            clear();kind=key;lastRequest=-30;request()
        end)
        menu[key]=option
    end
    dropdown:SetScript("OnClick",function()
        if menu:IsShown() then menu:Hide();return end
        refresh()
        menu.guild:SetShown(channels.guild~=nil)
        menu.officer:SetShown(channels.officer~=nil)
        menu:SetHeight(channels.officer and 56 or 30)
        menu:Show()
    end)
    loadOlder=function()
        if pending or atBeginning or not oldest or GetTime()-lastRequest<2 then return end
        cursor=oldest;request()
    end
    latest:SetScript("OnClick",function()
        generation=generation+1;pending=false;lastRequest=-30
        cursor,oldest=nil,nil;records,rendered={},{};atBeginning=false
        history:Clear();history:ScrollToBottom();request()
    end)
    local function submit(keepFocus)
        if Chat:PrivacyEnabled() and not privacyRevealed then return end
        if Chat:Send(club,stream,kind,input:GetText()) then
            input:SetText("")
            if not keepFocus then input:ClearFocus() end
        else refresh();status:SetText(GP.L["Message was not sent. Check channel access and try again."]) end
    end
    send:SetScript("OnClick",function()submit(false)end)
    input:SetScript("OnEnterPressed",function(self)
        -- Keep focus through Enter so the theme's focus-loss handler cannot
        -- propagate the same keypress into WoW's OPENCHAT binding.
        self:SetPropagateKeyboardInput(false)
        submit(true)
    end)
    input:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
    local events={"CLUB_MESSAGE_ADDED","CLUB_MESSAGE_UPDATED","CLUB_MESSAGE_HISTORY_RECEIVED",
        "CLUB_STREAM_ADDED","CLUB_STREAM_UPDATED","CLUB_STREAM_REMOVED","CLUB_MEMBER_UPDATED",
        "CLUB_MEMBER_ROLE_UPDATED","CLUB_MEMBER_REMOVED","CLUB_MEMBERS_UPDATED","CLUB_STREAMS_LOADED",
        "CLUB_STREAM_SUBSCRIBED","CLUB_STREAM_UNSUBSCRIBED","CLUB_REMOVED",
        "PLAYER_GUILD_UPDATE","GUILD_ROSTER_UPDATE","PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED",
        "PLAYER_ENTERING_WORLD","PLAYER_LEAVING_WORLD","ZONE_CHANGED_NEW_AREA"}
    page:SetScript("OnEvent",function(self,event,eventClub,eventStream)
        if not self:IsShown() then return end
        if event=="PLAYER_REGEN_DISABLED" or event=="PLAYER_LEAVING_WORLD" then clear();return end
        if event=="PLAYER_GUILD_UPDATE" then clear();kind="guild";lastRequest=-30 end
        if event=="CLUB_MESSAGE_HISTORY_RECEIVED" and not GP:IsSecretValue(eventClub) and not GP:IsSecretValue(eventStream)
            and eventClub==club and eventStream==stream then pending=false end
        if event=="CLUB_STREAMS_LOADED" or event=="PLAYER_REGEN_ENABLED" or event=="PLAYER_ENTERING_WORLD" then request();return end
        if not Chat:Allowed(club,stream,kind) then refresh();return end
        if refreshQueued then return end
        refreshQueued=true
        C_Timer.After(0.15,function()refreshQueued=false;if page:IsShown() then refresh() end end)
    end)
    page:SetScript("OnShow",function(self)
        for _,event in ipairs(events)do self:RegisterEvent(event)end
        lastRequest=-30;request()
    end)
    page:SetScript("OnHide",function(self)self:UnregisterAllEvents();clear()end)
    page.OnSelected=function()request()end
    page.OnDeselected=function()page:UnregisterAllEvents();clear()end
    for _,event in ipairs(events)do page:RegisterEvent(event)end
    request()
    return page
end
