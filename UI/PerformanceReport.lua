-- Paged, copyable performance history. Built only on explicit export.
local _, GP = ...
local panel, output, pageLabel, pages, page
function GP.Recorder:ShowExport()
    local L=GP.L
    -- Formatting is explicit user work and excluded from monitoring.
    local wasActive=self:GetState()
    if wasActive then self:Stop() end
    local report=self:Report()
    pages={}; local chunk=""
    for line in (report.."\n"):gmatch("([^\n]*)\n") do
        if #chunk+#line>24000 then pages[#pages+1]=chunk; chunk="" end
        chunk=chunk..line.."\n"
    end
    pages[#pages+1]=chunk; page=1
    if not panel then
        panel=CreateFrame("Frame","GuildParagonPerformanceReport",UIParent,"BackdropTemplate")
        panel:SetSize(800,550); panel:SetPoint("CENTER"); panel:SetFrameStrata("DIALOG")
        panel:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
        panel:SetBackdropColor(0.06,0.07,0.09,1); panel:SetBackdropBorderColor(0.3,0.3,0.3,1)
        panel:EnableMouse(true); panel:SetMovable(true); panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart",panel.StartMoving); panel:SetScript("OnDragStop",panel.StopMovingOrSizing)
        table.insert(UISpecialFrames,"GuildParagonPerformanceReport")
        local title=panel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        title:SetPoint("TOPLEFT",16,-16); title:SetText(L["Performance history - copy each page with Ctrl+A, Ctrl+C"])
        local scroll=CreateFrame("ScrollFrame",nil,panel,"UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",16,-50); scroll:SetPoint("BOTTOMRIGHT",-36,62)
        output=CreateFrame("EditBox",nil,scroll)
        output:SetMultiLine(true); output:SetAutoFocus(false); output:SetFontObject("ChatFontNormal")
        output:SetWidth(735); output:SetMaxLetters(0)
        output:SetScript("OnEscapePressed",function() panel:Hide() end)
        output:SetScript("OnTextChanged",function(box) box:SetHeight(math.max(400,(box:GetNumLines() or 1)*16+20)) end)
        scroll:SetScrollChild(output)
        pageLabel=panel:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        pageLabel:SetPoint("BOTTOM",0,24)
        local function refresh()
            output:SetText(pages[page]); scroll:SetVerticalScroll(0); output:SetCursorPosition(0)
            pageLabel:SetText(string.format(L["Page %d of %d"],page,#pages))
        end
        panel.refresh=refresh
        local function button(text,x,fn)
            local b=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
            b:SetSize(110,26); b:SetPoint("BOTTOMLEFT",x,16); b:SetText(text); b:SetScript("OnClick",fn)
        end
        button(L["Previous"],16,function() page=math.max(1,page-1); refresh() end)
        button(L["Next"],136,function() page=math.min(#pages,page+1); refresh() end)
        button(L["Close"],670,function() panel:Hide() end)
    end
    panel.refresh(); panel:Show()
    if wasActive then GP:Print(L["Export stopped recording to exclude report overhead. Use /gp monitor start to resume."]) end
end
