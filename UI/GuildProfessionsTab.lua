local _, GP = ...
local Theme = GP.UI.Theme
GP.UI.GuildProfessionsTab = {}

function GP.UI.GuildProfessionsTab:Build(parent)
    local model = GP:GetModule("GuildProfessions")
    local page = CreateFrame("Frame",nil,parent)
    page:SetAllPoints()
    local groups,selected,showOffline,search = {},nil,true,""
    local queued = false
    local function label(owner,text,x,y,font)
        local textFrame=owner:CreateFontString(nil,"ARTWORK")
        textFrame:SetFontObject(font or Theme.font.body)
        textFrame:SetPoint("TOPLEFT",x,y)
        textFrame:SetText(text == "" and "" or GP.L[text])
        textFrame:SetJustifyH("LEFT")
        return textFrame
    end
    label(page,"Guild Professions",0,0,Theme.font.title)
    label(page,"Browse guild members and the recipes shared by Blizzard.",0,-28,Theme.font.muted)
    local status=label(page,"",0,-64,Theme.font.muted)
    local refresh=Theme:CreateButton(page,GP.L["Refresh"])
    refresh:SetPoint("TOPRIGHT")
    local offline=Theme:CreateButton(page,GP.L["Hide Offline Members"])
    offline:SetWidth(170);offline:SetPoint("RIGHT",refresh,"LEFT",-8,0)
    local searchBox=Theme:CreateEditBox(page,220)
    searchBox:SetPoint("TOPLEFT",0,-94)
    label(page,"Search members",230,-100,Theme.font.small)
    local professions=Theme:CreatePanel(page,"panel","border")
    professions:SetPoint("TOPLEFT",0,-132);professions:SetPoint("BOTTOMLEFT",0,0);professions:SetWidth(240)
    local members=Theme:CreatePanel(page,"panel","border")
    members:SetPoint("TOPLEFT",professions,"TOPRIGHT",12,0);members:SetPoint("BOTTOMRIGHT")
    local title=label(members,"Select a profession",12,-12,Theme.font.heading)
    local viewAll=Theme:CreateButton(members,GP.L["View All Recipes"])
    viewAll:SetWidth(140);viewAll:SetPoint("TOPRIGHT",-12,-8)
    label(members,"Name",12,-48,Theme.font.small)
    label(members,"Status / Location",260,-48,Theme.font.small)
    local leftArea=CreateFrame("Frame",nil,professions);leftArea:SetPoint("TOPLEFT",6,-6);leftArea:SetPoint("BOTTOMRIGHT",-6,6)
    local rightArea=CreateFrame("Frame",nil,members);rightArea:SetPoint("TOPLEFT",8,-68);rightArea:SetPoint("BOTTOMRIGHT",-8,8)
    local paint,read
    local left=GP.UI.ScrollList:New(leftArea,34,function(owner)
        local row=Theme:CreateNavButton(owner,"")
        row:SetHeight(34)
        row.text:SetJustifyH("LEFT")
        row.text:SetPoint("RIGHT",-6,0)
        row.text:SetWordWrap(false)
        row:SetScript("OnClick",function(self)
            selected=self.data.id;model:Expand(self.data);paint();read()
        end)
        return row
    end)
    local right=GP.UI.ScrollList:New(rightArea,32,function(owner)
        local row=CreateFrame("Frame",nil,owner)
        row:SetHeight(32)
        row.name=label(row,"",4,-9)
        row.name:SetWidth(238);row.name:SetWordWrap(false)
        row.location=label(row,"",252,-9,Theme.font.muted)
        row.location:SetWidth(180);row.location:SetWordWrap(false)
        row.view=Theme:CreateButton(row,GP.L["View Recipes"])
        row.view:SetWidth(110);row.view:SetPoint("RIGHT",-4,0)
        row.view:SetScript("OnClick",function(self)
            if not model:View(row.data.id,row.data.name) then status:SetText(GP.L["Recipe viewing is unavailable right now."]) end
        end)
        return row
    end)
    left:SetUpdateRow(function(row,data)
        row.data=data
        row.text:SetText(string.format("%s  (%d/%d)",data.name,data.online,data.total))
        row:SetSelected(data.id==selected)
    end)
    right:SetUpdateRow(function(row,data)
        row.data=data;row.name:SetText(data.name)
        local color=data.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.class]
        row.name:SetTextColor(color and color.r or 1,color and color.g or 1,color and color.b or 1)
        row.location:SetText(data.online and (data.zone~="" and data.zone or GP.L["Online"]) or GP.L["Offline"])
        row.view:SetShown(model:CanView(data.id))
    end)
    paint=function()
        local group
        for _,entry in ipairs(groups) do if entry.id==selected then group=entry;break end end
        title:SetText(group and group.name or GP.L["Select a profession"])
        viewAll:SetShown(group~=nil and model:CanView(group.id))
        left:SetData(groups)
        local rows=model:Members(group,search,showOffline)
        right:SetData(rows)
        status:SetText(#groups==0 and GP.L["No guild profession data available yet. Try Refresh."]
            or string.format(GP.L["%d professions; %d matching members"],#groups,#rows))
    end
    read=function()
        if not page:IsShown() then return end
        model:Read(function(data)
            if not page:IsShown() then return end
            groups=data
            if not selected and groups[1] then selected=groups[1].id end
            for _,group in ipairs(groups) do
                if group.id==selected and group.collapsed then
                    if model:Expand(group) then C_Timer.After(0,read) end
                    break
                end
            end
            paint()
        end)
    end
    local function request()
        if not model:Request(showOffline) then status:SetText(GP.L["Profession refresh is unavailable right now."]);return end
        read()
    end
    refresh:SetScript("OnClick",request)
    offline:SetScript("OnClick",function()
        showOffline=not showOffline
        offline.text:SetText(GP.L[showOffline and "Hide Offline Members" or "Show Offline Members"])
        request()
    end)
    searchBox:SetScript("OnTextChanged",function(self)search=self:GetText();paint()end)
    viewAll:SetScript("OnClick",function()
        if not model:View(selected) then status:SetText(GP.L["Recipe viewing is unavailable right now."]) end
    end)
    local function start()
        if not model:CanUse() or model.active then return end
        model:Begin()
        page:RegisterEvent("GUILD_TRADESKILL_UPDATE")
        page:RegisterEvent("GUILD_ROSTER_UPDATE")
        page:RegisterEvent("PLAYER_GUILD_UPDATE")
        request()
    end
    page:SetScript("OnEvent",function(_,event)
        if event=="PLAYER_GUILD_UPDATE" then groups={};selected=nil;paint() end
        if queued then return end
        queued=true
        C_Timer.After(0.2,function()queued=false;read()end)
    end)
    page:SetScript("OnShow",start)
    page:SetScript("OnHide",function()page:UnregisterAllEvents();model:Finish();groups={};selected=nil end)
    page.OnSelected=start
    page.OnDeselected=function()page:UnregisterAllEvents();model:Finish()end
    return page
end
