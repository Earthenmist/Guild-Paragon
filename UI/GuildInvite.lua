local _,GP=...
local Invite={}
GP.UI.GuildInvite=Invite
function Invite:Open(parent)
    local Theme=GP.UI.Theme
    local dialog=self.dialog
    if not dialog then
        dialog=Theme:CreatePanel(parent,"panel","accent")
        dialog:SetSize(420,230)
        dialog:SetFrameStrata("DIALOG")
        dialog:EnableMouse(true)
        dialog:SetClampedToScreen(true)
        dialog:SetPoint("CENTER",GuildParagonMainFrame or parent,"CENTER")
        local title=dialog:CreateFontString(nil,"ARTWORK")
        title:SetFontObject(Theme.font.title)
        title:SetPoint("TOPLEFT",18,-18)
        title:SetText(GP.L["Guild Invite"])
        title:SetTextColor(unpack(Theme.color.accent))
        local description=dialog:CreateFontString(nil,"ARTWORK")
        description:SetFontObject(Theme.font.body)
        description:SetPoint("TOPLEFT",18,-48)
        description:SetWidth(384)
        description:SetJustifyH("LEFT")
        description:SetText(GP.L["Enter the character name to invite to your guild (Name-Realm for another realm):"])
        dialog.input=Theme:CreateEditBox(dialog,384)
        dialog.input:SetPoint("TOPLEFT",18,-98)
        dialog.input:SetMaxLetters(96)
        dialog.error=dialog:CreateFontString(nil,"ARTWORK")
        dialog.error:SetFontObject(Theme.font.small)
        dialog.error:SetPoint("TOPLEFT",18,-132)
        dialog.error:SetWidth(384)
        dialog.error:SetJustifyH("LEFT")
        dialog.error:SetTextColor(unpack(Theme.color.warning))
        local cancel=Theme:CreateButton(dialog,GP.L["Cancel"])
        cancel:SetSize(90,26);cancel:SetPoint("BOTTOMRIGHT",-18,18)
        cancel:SetScript("OnClick",function()dialog:Hide()end)
        dialog.accept=Theme:CreateButton(dialog,OKAY)
        dialog.accept:SetSize(90,26);dialog.accept:SetPoint("RIGHT",cancel,"LEFT",-8,0)
        local function submit(fromEnter)
            local data=dialog.data
            if not dialog:IsShown() or not data or data.submitted then return end
            data.submitted=true
            local ok,err=GP:GetModule("Recruitment"):InviteMemberByName(dialog.input:GetText(),data.guildKey)
            if ok then
                dialog.accept:Disable()
                if fromEnter then
                    -- Keep keyboard focus until Enter has finished dispatching.
                    C_Timer.After(0,function()if dialog.data==data then dialog:Hide() end end)
                else dialog:Hide() end
            else
                data.submitted=false
                dialog.error:SetText(err or "")
                dialog.input:SetFocus()
            end
        end
        dialog.accept:SetScript("OnClick",function()submit(false)end)
        dialog.input:SetScript("OnEnterPressed",function(self)
            self:SetPropagateKeyboardInput(false);submit(true)
        end)
        dialog.input:SetScript("OnEscapePressed",function()dialog:Hide()end)
        dialog:SetScript("OnHide",function()
            dialog.data=nil;dialog.input:ClearFocus();dialog.input:SetText("")
        end)
        parent:HookScript("OnHide",function()dialog:Hide()end)
        self.dialog=dialog
    end
    dialog.data={guildKey=GP:GetModule("Roster"):GetGuildKey()}
    dialog.error:SetText("");dialog.input:SetText("");dialog.accept:Enable()
    dialog:Show();dialog.input:SetFocus()
end
function Invite:CreateButton(parent,anchor)
    local button=GP.UI.Theme:CreateButton(parent,GP.L["Guild Invite"])
    button:SetWidth(130)
    button:SetPoint("LEFT",anchor,"RIGHT",8,0)
    local function refresh()
        local recruitment=GP:GetModule("Recruitment")
        local safety=GP:GetModule("GuildApplicants",true)
        button:SetShown(recruitment:CanManuallyInvite())
        button:SetEnabled(safety and safety:IsSafe())
    end
    button:SetScript("OnClick",function()
        refresh()
        local recruitment=GP:GetModule("Recruitment")
        local safety=GP:GetModule("GuildApplicants",true)
        if not recruitment:CanManuallyInvite() or not safety or not safety:IsSafe() then return end
        Invite:Open(parent)
    end)
    button:SetScript("OnShow",refresh)
    button:SetScript("OnEvent",refresh)
    for _,event in ipairs({"GUILD_ROSTER_UPDATE","PLAYER_GUILD_UPDATE","PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","PLAYER_ENTERING_WORLD","ZONE_CHANGED_NEW_AREA"}) do
        button:RegisterEvent(event)
    end
    refresh()
    return button
end
