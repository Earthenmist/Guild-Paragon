local _, GP = ...
local Theme=GP.UI.Theme
local UI={}
GP.UI.RecruitmentExpiry=UI
function UI:Hide()
    if self.popup then self.popup:Hide() end
end
function UI:Show(days,expired)
    -- Waits while the login card is being prepared; it is included or released then.
    local notifications=GP:GetModule("Notifications",true)
    if notifications and notifications:HoldsLoginCards() then return false end
    if not self.popup then
        local popup=Theme:CreateNotice({width=430,height=174,title=GP.L["Guild Finder listing reminder"],
            primaryLabel=GP.L["Guild Recruitment"],primaryWidth=230})
        popup.primary:SetScript("OnClick",function()
            local module=GP:GetModule("RecruitmentExpiry")
            if module.notice and module:Guild()==module.notice.club and GP.UI.GuildRecruitment:Open() then module:Dismiss() end
        end)
        popup.dismiss:SetScript("OnClick",function()GP:GetModule("RecruitmentExpiry"):Dismiss()end)
        self.popup=popup
    end
    self.popup.body:SetText(expired and GP.L["Your Guild Finder listing has expired. Review it to renew recruitment."]
        or (days==0 and GP.L["Your Guild Finder listing expires in less than a day. Review it to keep recruitment active."]
        or string.format(GP.L["Your Guild Finder listing expires in %d day(s). Review it to keep recruitment active."],days)))
    self.popup:Show()
    return true
end
function UI:BuildSettings(parent,anchor)
    local module=GP:GetModule("RecruitmentExpiry")
    local label=parent:CreateFontString(nil,"ARTWORK")
    label:SetFontObject(Theme.font.body);label:SetPoint("TOPLEFT",anchor,"BOTTOMLEFT",0,-20)
    label:SetText(GP.L["Guild Finder reminder below days:"])
    local input=Theme:CreateEditBox(parent,48)
    input:SetPoint("LEFT",label,"RIGHT",8,0);input:SetNumeric(true);input:SetMaxLetters(2)
    input:SetText(tostring(module:GetDays()))
    local save=Theme:CreateButton(parent,GP.L["Save"])
    save:SetPoint("LEFT",input,"RIGHT",8,0)
    local function apply()
        if not module:SetDays(input:GetText()) then GP:Print(GP.L["Enter 0 to disable reminders, or a whole number from 1 to 30."]) end
        input:SetText(tostring(module:GetDays()));input:ClearFocus()
    end
    save:SetScript("OnClick",apply);input:SetScript("OnEnterPressed",apply)
    local hint=parent:CreateFontString(nil,"ARTWORK")
    hint:SetFontObject(Theme.font.small);hint:SetPoint("TOPLEFT",label,"BOTTOMLEFT",0,-12)
    hint:SetPoint("RIGHT",parent,"RIGHT",-14,0);hint:SetJustifyH("LEFT");hint:SetWordWrap(true)
    hint:SetText(GP.L["Checks daily while you are online. Default: 10 days. Set 0 to turn off. Dismissed reminders return no sooner than the next day."])
end
