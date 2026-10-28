-- Guild Paragon — one-click Promote and Demote, and a confirmed Kick, for the
-- selected roster member.
--
-- Guild rank changes and removals are protected: addon Lua cannot make them.
-- Each action button is covered by a secure action button that runs
-- Blizzard's own /gpromote, /gdemote or /gremove for the member when the
-- player clicks it. The secure buttons sit under UIParent so protection does
-- not spread into Guild Paragon's windows, are positioned numerically over the
-- visible buttons, are armed only outside combat and hide in combat.
local _, GP = ...
local Theme = GP.UI.Theme
local Buttons = {}
GP.UI.RosterRankButtons = Buttons

local BUTTON_WIDTH = 96
-- Re-checked this long after a click even if no roster update arrives.
local RECHECK_AFTER_CLICK = 3

-- Rank order is 1 for the Guild Master; a member's current order is rank + 1.
-- Listed right to left from the anchor button.
local ACTIONS = {
    { key = "kick", label = "Kick" },
    { key = "demote", label = "Demote", command = "/gdemote", targetOffset = 2,
      tooltip = "Demote %s to %s" },
    { key = "promote", label = "Promote", command = "/gpromote", targetOffset = 0,
      tooltip = "Promote %s to %s" },
}

-- A character name is one slash-command argument, never executable text.
local function isSafeName(name)
    return type(name) == "string" and name ~= "" and not name:find("[%s%c/|;%[%]]")
end

local function escaped(text)
    return (tostring(text or ""):gsub("|", "||"))
end

-- The press phase that runs secure actions follows the "cast on key down"
-- setting. Registering only that phase means one click runs exactly once.
local function clickPhase()
    local ok, down = pcall(GetCVarBool, "ActionButtonUseKeyDown")
    return (ok and down) and "AnyDown" or "AnyUp"
end

local function inCombat()
    return GP:SafeCall(InCombatLockdown, false) == true
end

-- Secure overlay: a SecureActionButtonTemplate under UIParent that is placed
-- over a visible button and armed with one slash command.
local function newOverlay(visible)
    local overlay = { visible = visible }
    local secure = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    secure:SetFrameStrata("DIALOG")
    secure:SetFrameLevel(100)
    secure:Hide()
    overlay.secure = secure

    function overlay:Disarm()
        if inCombat() then
            -- Hidden by its combat state driver; cleared once combat ends.
            self.needsDisarm = true
            return
        end
        self.needsDisarm = nil
        if UnregisterStateDriver then UnregisterStateDriver(secure, "visibility") end
        secure:SetAttribute("type", nil)
        secure:SetAttribute("macrotext", nil)
        secure:Hide()
    end

    function overlay:Arm(macrotext)
        local button = self.visible
        if not macrotext or inCombat() or not button:IsVisible() then
            self:Disarm()
            return false
        end
        local left, bottom = button:GetLeft(), button:GetBottom()
        local width, height = button:GetWidth(), button:GetHeight()
        local sourceScale, targetScale = button:GetEffectiveScale(), UIParent:GetEffectiveScale()
        if not left or not bottom or not width or not height or not sourceScale or not targetScale or targetScale == 0 then
            self:Disarm()
            return false
        end
        local ratio = sourceScale / targetScale
        self.needsDisarm = nil
        if UnregisterStateDriver then UnregisterStateDriver(secure, "visibility") end
        secure:ClearAllPoints()
        secure:SetSize(width * ratio, height * ratio)
        secure:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * ratio, bottom * ratio)
        secure:RegisterForClicks(clickPhase())
        secure:SetAttribute("type", "macro")
        secure:SetAttribute("macrotext", macrotext)
        if RegisterStateDriver then RegisterStateDriver(secure, "visibility", "[combat] hide; show") end
        secure:Show()
        return true
    end

    -- A disarm asked for in combat is applied as soon as combat ends, before
    -- the combat state driver could show a stale armed button again.
    secure:RegisterEvent("PLAYER_REGEN_ENABLED")
    secure:SetScript("OnEvent", function()
        if overlay.needsDisarm then overlay:Disarm() end
    end)

    -- Hover on the overlay drives the visible button's hover look.
    secure:SetScript("OnEnter", function()
        local onEnter = visible:GetScript("OnEnter")
        if onEnter then onEnter(visible) end
        if overlay.OnEnter then overlay.OnEnter(secure) end
    end)
    secure:SetScript("OnLeave", function()
        local onLeave = visible:GetScript("OnLeave")
        if onLeave then onLeave(visible) end
        GameTooltip_Hide()
    end)
    return overlay
end

local function guildName()
    local ok, name = pcall(GetGuildInfo, "player")
    if ok and not GP:IsSecretValue(name) and type(name) == "string" and name ~= "" then return name end
end

local function normalized(text)
    return strtrim(tostring(text or "")):lower()
end

-- Kick confirmation: removal only becomes clickable once the guild name has
-- been typed, so it cannot be confirmed by pressing Enter or OK.
local function buildKickDialog(control, setStatus)
    local L = GP.L
    local dialog = Theme:CreatePanel(UIParent, "panel", "border")
    dialog:SetSize(440, 214)
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetFrameLevel(20)
    dialog:EnableMouse(true)
    dialog:Hide()

    local accent = dialog:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    accent:SetColorTexture(unpack(Theme.color.danger))

    local title = dialog:CreateFontString(nil, "ARTWORK")
    title:SetFontObject(Theme.font.title)
    title:SetPoint("TOPLEFT", 20, -18)
    title:SetText(L["Remove from guild"])

    local body = dialog:CreateFontString(nil, "ARTWORK")
    body:SetFontObject(Theme.font.body)
    body:SetPoint("TOPLEFT", 20, -48)
    body:SetPoint("TOPRIGHT", -20, -48)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    dialog.body = body

    local box = Theme:CreateEditBox(dialog, 400)
    box:SetPoint("TOPLEFT", 20, -112)
    dialog.box = box

    local confirm = Theme:CreateButton(dialog, L["Remove from guild"])
    confirm:SetSize(180, 30)
    confirm:SetPoint("BOTTOMLEFT", 20, 18)
    dialog.confirm = confirm
    local cancel = Theme:CreateButton(dialog, L["Cancel"])
    cancel:SetSize(120, 30)
    cancel:SetPoint("BOTTOMRIGHT", -20, 18)
    cancel:SetScript("OnClick", function() dialog:Hide() end)

    local overlay = newOverlay(confirm)
    dialog.overlay = overlay
    overlay.OnEnter = function(secure)
        GameTooltip:SetOwner(secure, "ANCHOR_TOP")
        GameTooltip:SetText(string.format(L["Remove %s from the guild"], escaped(dialog.target and dialog.target.name)))
        GameTooltip:Show()
    end
    overlay.secure:SetScript("PreClick", function()
        local target = dialog.target
        local PostKick = GP:GetModule("PostKick", true)
        local Roster = GP:GetModule("Roster", true)
        local guildKey = Roster and (Roster.currentGuildKey or Roster:GetGuildKey())
        if target and PostKick and PostKick.RecordMacroKickAttempt and guildKey then
            local guildData = GP.db.global.guilds[guildKey]
            local player = guildData and guildData.roster and guildData.roster[target.guid]
            PostKick:RecordMacroKickAttempt(guildKey, target.guid, player or { guid = target.guid, name = target.name })
        end
    end)
    overlay.secure:SetScript("PostClick", function()
        local target = dialog.target
        if target then setStatus(string.format(L["Removal sent for %s."], escaped(target.name)), false) end
        dialog:Hide()
        local Roster = GP:GetModule("Roster", true)
        if Roster and Roster.RequestScan then Roster:RequestScan(1) end
        C_Timer.After(RECHECK_AFTER_CLICK, function() control:Refresh() end)
    end)

    function dialog:Update()
        local target = self.target
        local guild = guildName()
        local matches = target and guild and normalized(box:GetText()) == normalized(guild)
        confirm:SetAlpha(matches and 1 or 0.45)
        confirm:SetEnabled(matches and true or false)
        if matches then
            overlay:Arm("/gremove " .. target.name)
        else
            overlay:Disarm()
        end
    end
    box:SetScript("OnTextChanged", function() dialog:Update() end)
    box:SetScript("OnEscapePressed", function() dialog:Hide() end)
    -- Enter never removes anyone; only the armed button does.
    box:SetScript("OnEnterPressed", function() box:ClearFocus() end)

    function dialog:Open(target)
        local guild = guildName()
        if not guild then return end
        self.target = target
        body:SetText(string.format(L["Remove %s from %s? They lose access to the guild straight away.\n\nType the guild name to confirm:"],
            escaped(target.name), escaped(guild)))
        box:SetText("")
        self:Show()
        box:SetFocus()
        self:Update()
    end

    dialog:SetScript("OnHide", function(self)
        overlay:Disarm()
        self.target = nil
        box:SetText("")
        box:ClearFocus()
    end)
    dialog:RegisterEvent("PLAYER_REGEN_DISABLED")
    dialog:SetScript("OnEvent", function(self) self:Hide() end)
    -- Escape closes it like other dialogs.
    _G.GuildParagonKickDialog = dialog
    tinsert(UISpecialFrames, "GuildParagonKickDialog")
    return dialog
end

function Buttons:New(parent, anchor, selected, setStatus)
    local L = GP.L
    local control = { actions = {} }
    local Ranks = GP:GetModule("RosterRanks")

    local previous = anchor
    for _, def in ipairs(ACTIONS) do
        local action = { def = def }
        local visible = Theme:CreateButton(parent, L[def.label])
        visible:SetWidth(BUTTON_WIDTH)
        visible:SetPoint("RIGHT", previous, "LEFT", -8, 0)
        previous = visible
        action.visible = visible

        if def.command then
            local overlay = newOverlay(visible)
            action.overlay = overlay
            overlay.OnEnter = function(secure)
                local ready = action.ready
                if not ready then return end
                GameTooltip:SetOwner(secure, "ANCHOR_TOP")
                GameTooltip:SetText(string.format(L[def.tooltip], escaped(ready.name), escaped(ready.rankName)))
                GameTooltip:AddLine(L["One rank per click. Blizzard applies the change and the roster updates shortly after."], 1, 1, 1, true)
                GameTooltip:Show()
            end
            overlay.secure:SetScript("PostClick", function()
                local ready = action.ready
                if ready then
                    setStatus(string.format(L[def.key == "promote" and "Promotion sent for %s." or "Demotion sent for %s."],
                        escaped(ready.name)), false)
                end
                -- Stays disarmed until the roster shows the new rank, so an
                -- accidental double click cannot move the member twice.
                overlay:Disarm()
                local Roster = GP:GetModule("Roster", true)
                if Roster and Roster.RequestScan then Roster:RequestScan(1) end
                C_Timer.After(RECHECK_AFTER_CLICK, function() control:Refresh() end)
            end)
        else
            -- Kick opens the confirmation; it never removes anyone itself.
            visible:SetScript("OnClick", function()
                if not action.ready then return end
                control.kickDialog = control.kickDialog or buildKickDialog(control, setStatus)
                control.kickDialog:Open(action.ready)
            end)
        end
        table.insert(control.actions, action)
    end

    function control:Disarm()
        for _, action in ipairs(self.actions) do
            if action.overlay then action.overlay:Disarm() end
        end
        if self.kickDialog then
            self.kickDialog:Hide()
            self.kickDialog.overlay:Disarm()
        end
    end

    -- Re-reads the selected member's live rank and the player's permissions,
    -- then enables, arms or disarms each button.
    function control:Refresh()
        local guid = selected()
        local member = guid and Ranks:Snapshot(guid) or nil
        local safeMember = member and isSafeName(member.name) and member or nil
        local canRank = GP:SafeCall(CanGuildPromote, false) == true or GP:SafeCall(CanGuildDemote, false) == true
        local canRemove = GP:SafeCall(CanGuildRemove, false) == true
        for _, action in ipairs(self.actions) do
            local ready, permitted
            if action.def.command then
                permitted = canRank
                local rankName = safeMember and Ranks:Allowed(safeMember, safeMember.rank + action.def.targetOffset)
                ready = safeMember and rankName and { guid = guid, name = safeMember.name, rankName = rankName } or nil
            else
                permitted = canRemove
                ready = safeMember and Ranks:CanRemove(safeMember) and { guid = guid, name = safeMember.name } or nil
            end
            action.ready = ready
            action.visible:SetShown(permitted)
            action.visible:SetEnabled(ready ~= nil)
            action.visible:SetAlpha(ready and 1 or 0.45)
            if action.overlay then
                if ready then
                    action.overlay:Arm(action.def.command .. " " .. ready.name)
                else
                    action.overlay:Disarm()
                end
            end
        end
        local dialog = self.kickDialog
        if dialog and dialog:IsShown() then
            local kick = self.actions[1]
            if not kick.ready or kick.ready.guid ~= dialog.target.guid then
                dialog:Hide()
            else
                dialog:Update()
            end
        end
    end

    parent:HookScript("OnHide", function() control:Disarm() end)
    -- The secure buttons are placed by position, so they are hidden while the
    -- window moves and placed again where it stops.
    LibStub("AceEvent-3.0"):Embed(control)
    control:RegisterMessage("GuildParagon_MainWindowMoving", function() control:Disarm() end)
    control:RegisterMessage("GuildParagon_MainWindowMoved", function() control:Refresh() end)
    control:RegisterMessage("GuildParagon_RankAccessChanged", function() control:Refresh() end)
    control:Refresh()
    return control
end
