local _, GP = ...
local Theme = GP.UI.Theme
GP.UI.RosterRankControl = {}
local Control = GP.UI.RosterRankControl
StaticPopupDialogs["GUILDPARAGON_CHANGE_RANK"] = {
    text = "%s", button1 = GP.L["Build Macro"], button2 = GP.L["Cancel"],
    timeout=30, whileDead=true, hideOnEscape=true,
    OnAccept=function(_,data)
        if data and data.selected() == data.token.guid then
            if GP:GetModule("RosterRanks"):Confirm(data.token) then
                GP.UI.MainWindow:SelectTabByID("macro")
            end
        end
    end,
    OnCancel=function() GP:GetModule("RosterRanks").token=nil end,
}
function Control:New(parent, anchor, selected)
    local control={}
    local ranks=GP:GetModule("RosterRanks")
    local label=parent:CreateFontString(nil,"ARTWORK")
    label:SetFontObject(Theme.font.small)
    label:SetText(GP.L["Rank:"])
    label:SetPoint("LEFT",anchor,"RIGHT",16,0)
    local button=Theme:CreateButton(parent,"")
    button:SetPoint("LEFT",label,"RIGHT",8,0)
    button:SetWidth(180)
    control.button=button
    local menu=Theme:CreatePanel(button,"panel","border")
    menu:SetPoint("BOTTOMLEFT",button,"TOPLEFT",0,4)
    menu:SetSize(240,260)
    menu:SetFrameStrata("DIALOG")
    menu:Hide()
    local list=GP.UI.ScrollList:New(menu,26,function(container)
        local row=CreateFrame("Button",nil,container,"BackdropTemplate")
        row:SetBackdrop((Theme:Backdrop("panelRaised")))
        row:SetBackdropColor(0,0,0,0);row:SetBackdropBorderColor(0,0,0,0)
        row.text=row:CreateFontString(nil,"ARTWORK")
        row.text:SetFontObject(Theme.font.body)
        row.text:SetPoint("LEFT",10,0);row.text:SetPoint("RIGHT",-10,0)
        row.text:SetJustifyH("LEFT");row.text:SetWordWrap(false)
        row:SetScript("OnEnter",function()row:SetBackdropColor(unpack(Theme.color.panelRaised))end)
        row:SetScript("OnLeave",function()row:SetBackdropColor(0,0,0,0)end)
        row:SetScript("OnClick",function()
            menu:Hide()
            local token=ranks:Prepare(selected(),row.order)
            if not token then GP:Print(GP.L["No permitted rank change is available. Refresh and select the member again."]);return end
            StaticPopup_Show("GUILDPARAGON_CHANGE_RANK",string.format(GP.L["Prepare a rank macro for %s to become %s? No rank changes until you press the macro. Each press moves one rank."],
                token.name:gsub("|","||"),token.rankName:gsub("|","||")),nil,{token=token,selected=selected})
        end)
        return row
    end)
    list:SetUpdateRow(function(row,item)row.order=item.order;row.text:SetText(item.name:gsub("|","||"))end)
    function control:Hide()
        menu:Hide();ranks.token=nil
        StaticPopup_Hide("GUILDPARAGON_CHANGE_RANK")
    end
    function control:Refresh()
        local guid,rankName,isCurrent=selected()
        local hasRank=not GP:IsSecretValue(rankName) and type(rankName)=="string" and rankName~=""
        if self.guid ~= guid or self.rankName ~= (hasRank and rankName or nil) or not ranks:CanUse() then self:Hide() end
        self.guid,self.rankName=guid,hasRank and rankName or nil
        label:SetShown(hasRank)
        button:SetShown(hasRank)
        button.text:SetText(hasRank and (rankName:gsub("|","||") .. "  v") or "")
        button:SetEnabled(hasRank and isCurrent and ranks:CanUse())
    end
    button:SetScript("OnClick",function()
        if menu:IsShown() then menu:Hide();return end
        local rows=ranks:Options(selected())
        if #rows == 0 then GP:Print(GP.L["No permitted rank change is available. Refresh and select the member again."]);return end
        menu:SetHeight(math.min(#rows,10)*26)
        menu:Show();list:SetData(rows,true)
    end)
    button:SetScript("OnEnter",function()
        GameTooltip:SetOwner(button,"ANCHOR_RIGHT")
        GameTooltip:SetText(GP.L["Choose a new guild rank for this member. Only ranks you can assign are listed."])
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave",function()GameTooltip:Hide()end)
    parent:HookScript("OnHide",function()control:Hide()end)
    control:Refresh()
    return control
end
