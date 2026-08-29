-- Guild Paragon — Macro Tool tab
--
-- Rule editor, decision preview, and explicit macro builder. Guild Paragon
-- still never calls guild action APIs directly; executor output is a visible
-- in-game macro the officer chooses to press.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.MacroToolTab = GP.UI.MacroToolTab or {}
local MacroToolTab = GP.UI.MacroToolTab

-- Own AceEvent identity, not GP — see UI/RecruitmentTab.lua's long comment
-- above its own Embed call for the full root-cause explanation: multiple
LibStub("AceEvent-3.0"):Embed(MacroToolTab)

local ROW_HEIGHT = 30
local frame, list, summaryText
local actionButtons, scopeButtons, rankChecks, levelButtons = {}, {}, {}, {}
local controls = {}
local savedRuleButtons = {}
local savedRuleHeaders = {}
local targetRankButtons = {}
local actionLabel, ruleSummary
local MACRO_TEXT_LIMIT = 255

local function macroActionText(plan)
    if type(plan) ~= "table" then return GP.L["No queued macro action selected."] end

    local parts = {
        string.format(GP.L["Target: %s"], plan.playerName or GP.L["Unknown"]),
        string.format(GP.L["Action: %s"], plan.actionLabel or actionLabel(plan.action)),
    }
    if plan.targetRankName then
        table.insert(parts, string.format(GP.L["Rank: %s"], plan.targetRankName))
    end
    if plan.moves and plan.moves > 1 then
        table.insert(parts, string.format(GP.L["Moves: %d"], plan.moves))
    end
    if plan.totalMoves and plan.totalMoves > (plan.moves or 0) then
        table.insert(parts, string.format(GP.L["Steps: %d/%d"], plan.moves or 0, plan.totalMoves))
    end
    if plan.truncated then
        table.insert(parts, GP.L["Macro is at WoW's length limit; rebuild after pressing it."])
    end
    return table.concat(parts, "   ")
end

local function macroBatchText(plan, state)
    if state and state.activePlan then
        plan = state.activePlan
    end
    if type(plan) ~= "table" then
        return GP.L["Batch: none armed."]
    end

    local size = plan.macroSize or #(plan.body or "")
    local parts = {
        string.format(GP.L["Batch: %d"], plan.batchNumber or 0),
        string.format(GP.L["Actions: %d/%d"], plan.selectedCount or plan.activeCount or 1, plan.requestedCount or plan.selectedCount or 1),
        string.format(GP.L["Steps: %d"], plan.moves or plan.commandLines or 0),
        string.format(GP.L["Size: %d/%d"], size, MACRO_TEXT_LIMIT),
    }
    if plan.remainingAfterBatch and plan.remainingAfterBatch > 0 then
        table.insert(parts, string.format(GP.L["After press: %d action(s) remain."], plan.remainingAfterBatch))
    elseif plan.truncated then
        table.insert(parts, GP.L["After press: rebuild for remaining actions."])
    end
    return table.concat(parts, "   ")
end

local function macroHistoryText(state)
    local history = state and state.history
    if type(history) ~= "table" or not history[1] then
        return GP.L["History: no macro batches run this session."]
    end
    local entry = history[1]
    local when = entry.time and date("%H:%M:%S", entry.time) or GP.L["Unknown"]
    return string.format(GP.L["History: %s — %s"], when, entry.text or GP.L["Unknown"])
end

local function rowKey(row)
    if type(row) ~= "table" then return nil end
    return table.concat({
        row.guid or "",
        row.actualAction or row.action or "",
        tostring(row.targetRankIndex or ""),
    }, "|")
end

local function selectedMap()
    controls.selectedMacroRows = controls.selectedMacroRows or {}
    return controls.selectedMacroRows
end

local function isRowSelected(row)
    local key = rowKey(row)
    return key and selectedMap()[key] and true or false
end

local function selectedRowsFrom(queuedRows)
    local selected = selectedMap()
    local rows, live = {}, {}
    for _, row in ipairs(queuedRows or {}) do
        local key = rowKey(row)
        if key then
            live[key] = true
            if selected[key] then table.insert(rows, row) end
        end
    end
    for key in pairs(selected) do
        if not live[key] then selected[key] = nil end
    end
    return rows
end

local function selectAllQueuedRows(queuedRows)
    local selected = selectedMap()
    wipe(selected)
    for _, row in ipairs(queuedRows or {}) do
        local key = rowKey(row)
        if key then selected[key] = true end
    end
end

local function refreshExecutor(queuedRows)
    queuedRows = queuedRows or controls.queuedRows or {}
    controls.queuedRows = queuedRows
    if controls.executionIndex == nil or controls.executionIndex < 1 or controls.executionIndex > #queuedRows then
        controls.executionIndex = #queuedRows > 0 and 1 or nil
    end

    local row = controls.executionIndex and queuedRows[controls.executionIndex] or nil
    local selectedRows = selectedRowsFrom(queuedRows)
    local MacroTool = GP:GetModule("MacroTool")
    local state = MacroTool:GetExecutionState()
    local plan, err
    if state.activePlan then
        plan = state.activePlan
    elseif #selectedRows > 0 then
        plan, err = MacroTool:BuildMacroPlanForRows(selectedRows, { singleRankMove = true })
    elseif state.remaining > 0 then
        plan, err = MacroTool:BuildMacroPlanForRows(MacroTool:GetExecutionRows(), { singleRankMove = true })
    else
        plan, err = MacroTool:BuildMacroPlan(row)
    end
    controls.executionPlan = plan
    local hotKeyBound, hotKeyMessage = true, nil
    if plan or state.activePlan then
        hotKeyBound, hotKeyMessage = MacroTool:EnsureExecutionHotKeyBound()
    end

    if controls.executionSummary then
        if plan then
            controls.executionSummary:SetText(macroActionText(plan))
        else
            controls.executionSummary:SetText(err or GP.L["No queued macro action selected."])
        end
    end
    if controls.executionBody then
        controls.executionBody:SetText(plan and plan.body or "")
    end
    if controls.hotKeyBox and not controls.hotKeyBox:HasFocus() then
        controls.hotKeyBox:SetText(MacroTool:GetExecutionHotKey())
    end
    if controls.executionQueueText then
        if state.activePlan then
            local total = state.remainingMoves or state.activePlan.totalMoves or state.activeCount or 0
            controls.executionQueueText:SetText(string.format(GP.L["Macro batch %d is armed: %d action(s), %d total step(s) remaining."],
                state.batchNumber or 0, state.activeCount or 0, total))
        elseif state.remaining and state.remaining > 0 then
            controls.executionQueueText:SetText(string.format(GP.L["Macro queue: %d done, %d remaining action(s)."], state.completed or 0, state.remainingMoves or state.remaining))
        else
            controls.executionQueueText:SetText(GP.L["Macro queue: none."])
        end
    end
    if controls.executionBatchText then
        controls.executionBatchText:SetText(macroBatchText(plan, state))
    end
    if controls.executionHistoryText then
        controls.executionHistoryText:SetText(macroHistoryText(state))
    end
    if controls.executionHint then
        if hotKeyBound == false and hotKeyMessage and hotKeyMessage ~= "" then
            controls.executionHint:SetText(hotKeyMessage)
        elseif state.activePlan then
            controls.executionHint:SetText(string.format(GP.L["Press hotkey %s; Guild Paragon will arm the next step automatically."], MacroTool:GetExecutionHotKey()))
        elseif state.remaining and state.remaining > 0 then
            controls.executionHint:SetText(GP.L["Build Macro will arm the next batch from the remaining queue."])
        elseif plan and plan.selectedCount and plan.selectedCount > 1 then
            controls.executionHint:SetText(string.format(GP.L["%d selected row(s); oversized selections are split into safe macro batches."], plan.selectedCount))
        else
            controls.executionHint:SetText(plan and string.format(GP.L["Build Macro arms Paragon_Tool and binds hotkey %s. Review the text before running it."], MacroTool:GetExecutionHotKey()) or GP.L["Pick or load a rule with queued results, then build the macro."])
        end
    end
end

local COL = {
    leftPad = 30,
    state = 0,
    name = 148,
    rank = 130,
    offline = 56,
    gap = 8,
}

local function getGuildKey()
    local Roster = GP:GetModule("Roster")
    return Roster.currentGuildKey or Roster:GetGuildKey()
end

local function getGuildData()
    local guildKey = getGuildKey()
    return guildKey and GP.db.global.guilds[guildKey], guildKey
end

local function truncate(text, maxChars)
    text = text or ""
    if #text > maxChars then return text:sub(1, maxChars) .. "..." end
    return text
end

local function classColorOf(classFile)
    local c = classFile and C_ClassColor.GetClassColor(classFile)
    if c then return c.r, c.g, c.b end
    return unpack(Theme.color.textPrimary)
end

local function makeButton(parent, label, width)
    local button = Theme:CreateButton(parent, label)
    if width then button:SetWidth(width) end
    return button
end

local helpDialog

local function showMacroToolHelp()
    local L = GP.L
    if not helpDialog then
        helpDialog = Theme:CreatePanel(UIParent, "backdrop", "border")
        helpDialog:SetSize(760, 520)
        helpDialog:SetPoint("CENTER")
        helpDialog:SetFrameStrata("DIALOG")
        helpDialog:SetFrameLevel(100)
        helpDialog:SetClampedToScreen(true)
        helpDialog:EnableMouse(true)
        helpDialog:Hide()

        local title = helpDialog:CreateFontString(nil, "ARTWORK")
        title:SetFontObject(Theme.font.title)
        title:SetPoint("TOPLEFT", 18, -16)
        title:SetText(L["How to Use the Macro Tool"])

        local close = Theme:CreateCloseButton(helpDialog)
        close:SetPoint("TOPRIGHT", -12, -10)
        close:SetScript("OnClick", function()
            helpDialog:Hide()
        end)

        local bodyPanel = Theme:CreatePanel(helpDialog, "panel", "border")
        bodyPanel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -14)
        bodyPanel:SetPoint("BOTTOMRIGHT", -18, 18)

        local body = bodyPanel:CreateFontString(nil, "ARTWORK")
        body:SetFontObject(Theme.font.body)
        body:SetJustifyH("LEFT")
        body:SetJustifyV("TOP")
        body:SetWordWrap(true)
        body:SetPoint("TOPLEFT", 16, -14)
        body:SetPoint("BOTTOMRIGHT", -16, 14)
        body:SetText(L["Macro Tool Help Body"])
    end

    helpDialog:Show()
end

local function refreshSavedRuleText()
    if not controls.savedRulesText then return end

    local MacroTool = GP:GetModule("MacroTool")
    local names = MacroTool:GetSavedRuleNames()
    if #names == 0 then
        controls.savedRulesText:SetText(GP.L["Saved: none"])
        return
    end

    local counts = { kick = 0, promote = 0, demote = 0, special = 0 }
    for _, name in ipairs(names) do
        local rule = MacroTool:GetSavedRule(name)
        if rule and counts[rule.action] ~= nil then
            counts[rule.action] = counts[rule.action] + 1
        end
    end
    controls.savedRulesText:SetText(string.format(GP.L["Saved: %d Kick, %d Promote, %d Demote, %d Special"],
        counts.kick, counts.promote, counts.demote, counts.special))
end

local function hideSavedRulePicker()
    if controls.savedRulePicker then controls.savedRulePicker:Hide() end
end

local function clearSavedRuleSelection()
    local settings = GP:GetModule("MacroTool"):GetSettings()
    settings.currentRuleName = nil
    if controls.ruleNameBox then
        controls.ruleNameBox:SetText("")
    end
    hideSavedRulePicker()
end

local function refreshSavedRulePicker()
    local picker = controls.savedRulePicker
    if not picker then return end

    for _, button in ipairs(savedRuleButtons) do
        button:Hide()
    end
    for _, header in ipairs(savedRuleHeaders) do
        header:Hide()
    end

    local MacroTool = GP:GetModule("MacroTool")
    local names = MacroTool:GetSavedRuleNames()
    if #names == 0 then
        picker.empty:SetText(GP.L["No saved rules yet."])
        picker.empty:Show()
        picker:SetHeight(42)
        return
    end

    picker.empty:Hide()
    local grouped = { kick = {}, promote = {}, demote = {}, special = {} }
    for _, name in ipairs(names) do
        local rule = MacroTool:GetSavedRule(name)
        if rule and grouped[rule.action] then
            table.insert(grouped[rule.action], { name = name, rule = rule })
        end
    end

    local previous, headerIndex, buttonIndex, rowCount = nil, 0, 0, 0
    local order = {
        { action = "kick", label = GP.L["Kick"] },
        { action = "promote", label = GP.L["Promote"] },
        { action = "demote", label = GP.L["Demote"] },
        { action = "special", label = GP.L["Special"] },
    }

    for _, groupInfo in ipairs(order) do
        local group = grouped[groupInfo.action]
        if #group > 0 then
            headerIndex = headerIndex + 1
            local header = savedRuleHeaders[headerIndex]
            if not header then
                header = picker:CreateFontString(nil, "ARTWORK")
                header:SetFontObject(Theme.font.small)
                header:SetTextColor(unpack(Theme.color.warning))
                header:SetJustifyH("LEFT")
                header:SetWidth(338)
                savedRuleHeaders[headerIndex] = header
            end
            header:SetText(groupInfo.label)
            header:ClearAllPoints()
            if previous then
                header:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -6)
            else
                header:SetPoint("TOPLEFT", 8, -8)
            end
            header:Show()
            previous = header
            rowCount = rowCount + 1

            for _, entry in ipairs(group) do
                buttonIndex = buttonIndex + 1
                local button = savedRuleButtons[buttonIndex]
                if not button then
                    button = Theme:CreateButton(picker, "")
                    button:SetHeight(23)
                    button:SetWidth(338)
                    savedRuleButtons[buttonIndex] = button
                end

                button.text:SetText(truncate(entry.name .. " - " .. ruleSummary(entry.rule), 44))
                button.ruleName = entry.name
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
                button:SetScript("OnClick", function(self)
                    local ok, err = MacroTool:LoadRule(self.ruleName)
                    if not ok then
                        GP:Print(err)
                        return
                    end
                    if controls.ruleNameBox then controls.ruleNameBox:SetText(self.ruleName) end
                    hideSavedRulePicker()
                    MacroToolTab:Refresh(true)
                end)
                button:Show()
                previous = button
                rowCount = rowCount + 1
            end
        end
    end

    picker:SetHeight(18 + rowCount * 25)
end

local function toggleSavedRulePicker()
    local picker = controls.savedRulePicker
    if not picker then return end
    if picker:IsShown() then
        picker:Hide()
        return
    end
    refreshSavedRulePicker()
    picker:Show()
end

local DELETE_RULE_POPUP = "GUILDPARAGON_DELETE_MACRO_RULE"
StaticPopupDialogs[DELETE_RULE_POPUP] = StaticPopupDialogs[DELETE_RULE_POPUP] or {
    text = GP.L["Delete saved macro rule \"%s\"?"],
    button1 = GP.L["Delete"],
    button2 = GP.L["Cancel"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(_, ruleName)
        local MacroTool = GP:GetModule("MacroTool")
        local ok, err = MacroTool:DeleteRule(ruleName)
        if not ok then GP:Print(err) end
        hideSavedRulePicker()
        MacroToolTab:Refresh(true)
    end,
}

local function confirmDeleteRule(ruleName)
    local MacroTool = GP:GetModule("MacroTool")
    ruleName = strtrim(ruleName or "")
    if ruleName == "" then
        GP:Print(GP.L["Enter a rule name first."])
        return
    end
    if not MacroTool:GetSavedRule(ruleName) then
        GP:Print(GP.L["Saved rule not found."])
        return
    end
    StaticPopup_Show(DELETE_RULE_POPUP, ruleName, nil, ruleName)
end

local function createCheck(parent, label, checked, onClick)
    local button = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    button:SetSize(22, 22)
    button:SetChecked(checked and true or false)

    local text = button:CreateFontString(nil, "ARTWORK")
    text:SetFontObject(Theme.font.small)
    text:SetPoint("LEFT", button, "RIGHT", 2, 0)
    text:SetText(label)
    button.text = text

    button:SetScript("OnClick", function(self)
        if onClick then onClick(self:GetChecked() and true or false) end
    end)
    return button
end

local function modeButton(parent, bucket, key, label, setter, width)
    local button = makeButton(parent, label, width or 72)
    button:SetScript("OnClick", function()
        setter(key)
        MacroToolTab:Refresh(true)
    end)
    bucket[key] = button
    return button
end

local function paintButtons(bucket, active)
    for key, button in pairs(bucket) do
        local selected = key == active
        button:SetBackdropBorderColor(unpack(selected and Theme.color.accent or Theme.color.accentDim))
        button.text:SetFontObject(selected and Theme.font.heading or Theme.font.body)
    end
end

local function setShown(control, shown)
    if not control then return end
    if shown then
        control:Show()
    else
        control:Hide()
    end
end

local function setGroupShown(bucket, shown)
    for _, control in pairs(bucket or {}) do
        setShown(control, shown)
    end
end

local function createLabel(parent, text, anchor, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK")
    fs:SetFontObject(Theme.font.small)
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x or 0, y or -10)
    fs:SetText(text)
    return fs
end

local function rankName(rankIndex)
    if GuildControlGetRankName then
        local ok, name = pcall(GuildControlGetRankName, rankIndex + 1)
        if ok and name and name ~= "" then return name end
    end
    return string.format(GP.L["Rank %d"], rankIndex)
end

actionLabel = function(action)
    if action == "kick" then return GP.L["Kick"] end
    if action == "promote" then return GP.L["Promote"] end
    if action == "demote" then return GP.L["Demote"] end
    if action == "special" then return GP.L["Special"] end
    return GP.L["Unknown"]
end

ruleSummary = function(rule)
    if type(rule) ~= "table" then return GP.L["No saved rule loaded."] end

    local parts = {
        actionLabel(rule.action),
        string.format(GP.L["%d day(s)"], tonumber(rule.minOfflineDays) or 0),
    }
    if rule.action == "promote" and tonumber(rule.minRankDays) and tonumber(rule.minRankDays) > 0 then
        table.insert(parts, string.format(GP.L["rank %d day(s)"], tonumber(rule.minRankDays)))
    end
    if rule.action == "promote" and tonumber(rule.maxOfflineDays) and tonumber(rule.maxOfflineDays) > 0 then
        table.insert(parts, string.format(GP.L["online %d day(s)"], tonumber(rule.maxOfflineDays)))
    end
    if (rule.action == "promote" or rule.action == "demote") and rule.targetRankIndex ~= nil then
        table.insert(parts, string.format(GP.L["to %s"], rankName(rule.targetRankIndex)))
    elseif rule.action == "special" then
        if rule.specialSameRank then
            table.insert(parts, GP.L["same as main"])
        elseif rule.targetRankIndex ~= nil then
            table.insert(parts, string.format(GP.L["to %s"], rankName(rule.targetRankIndex)))
        else
            table.insert(parts, GP.L["Select Rank"])
        end
        table.insert(parts, GP.L["main rank filter"])
        if rule.specialDisableDemote then
            table.insert(parts, GP.L["promote only"])
        end
    end
    if rule.targetScope == "alts" then
        table.insert(parts, GP.L["Alts Only"])
    elseif rule.targetScope == "mains" then
        table.insert(parts, GP.L["Mains Only"])
    else
        table.insert(parts, GP.L["All"])
    end
    return table.concat(parts, " / ")
end

local function getGuildRanks()
    local ranks = {}
    if GuildControlGetNumRanks then
        local ok, count = pcall(GuildControlGetNumRanks)
        if ok and tonumber(count) and tonumber(count) > 0 then
            for rankIndex = 0, tonumber(count) - 1 do
                table.insert(ranks, rankIndex)
            end
            return ranks
        end
    end

    local data = getGuildData()
    local seen = {}
    if data then
        for _, player in pairs(data.roster or {}) do
            if player.rankIndex ~= nil and not seen[player.rankIndex] then
                seen[player.rankIndex] = true
                table.insert(ranks, player.rankIndex)
            end
        end
    end
    table.sort(ranks)
    return ranks
end

local function hideTargetRankPicker()
    if controls.targetRankPicker then controls.targetRankPicker:Hide() end
end

local function refreshTargetRankPicker()
    local picker = controls.targetRankPicker
    if not picker then return end

    for _, button in ipairs(targetRankButtons) do
        button:Hide()
    end

    local ranks = getGuildRanks()
    if #ranks == 0 then
        picker.empty:SetText(GP.L["No guild ranks found."])
        picker.empty:Show()
        picker:SetHeight(42)
        return
    end

    picker.empty:Hide()
    local previous
    for i, rankIndex in ipairs(ranks) do
        local button = targetRankButtons[i]
        if not button then
            button = Theme:CreateButton(picker, "")
            button:SetHeight(23)
            button:SetWidth(188)
            targetRankButtons[i] = button
        end

        button.rankIndex = rankIndex
        button.text:SetText(truncate(rankName(rankIndex), 24))
        button:ClearAllPoints()
        if previous then
            button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
        else
            button:SetPoint("TOPLEFT", 8, -8)
        end
        button:SetScript("OnClick", function(self)
            GP:GetModule("MacroTool"):SetSetting("targetRankIndex", self.rankIndex)
            hideTargetRankPicker()
            MacroToolTab:Refresh(true)
        end)
        button:Show()
        previous = button
    end

    picker:SetHeight(16 + #ranks * 25)
end

local function toggleTargetRankPicker()
    local picker = controls.targetRankPicker
    if not picker then return end
    if picker:IsShown() then
        picker:Hide()
        return
    end
    refreshTargetRankPicker()
    picker:Show()
end

local function rebuildRankChecks(parent, anchor)
    for _, check in pairs(rankChecks) do
        check:Hide()
        check:SetParent(nil)
    end
    wipe(rankChecks)

    local data = getGuildData()
    local seen = {}
    local ranks = {}
    if data then
        for _, player in pairs(data.roster or {}) do
            if player.rankIndex ~= nil and not seen[player.rankIndex] then
                seen[player.rankIndex] = true
                table.insert(ranks, player.rankIndex)
            end
        end
    end
    table.sort(ranks)

    local previous
    for i, rankIndex in ipairs(ranks) do
        local check = createCheck(parent, truncate(rankName(rankIndex), 18), false, function(value)
            GP:GetModule("MacroTool"):GetSettings().selectedRanks[rankIndex] = value or nil
            MacroToolTab:Refresh(true)
        end)
        if i == 1 then
            check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
        elseif i % 2 == 1 then
            check:SetPoint("TOPLEFT", rankChecks[ranks[i - 2]], "BOTTOMLEFT", 0, -5)
        else
            check:SetPoint("LEFT", previous.text, "RIGHT", 18, 0)
        end
        rankChecks[rankIndex] = check
        previous = check
    end
end

local function createRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panel")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:EnableMouse(true)
    row:SetScript("OnMouseDown", function(self)
        if self.executionIndex then
            controls.executionIndex = self.executionIndex
            refreshExecutor()
            if list then list:Refresh() end
        end
    end)

    local select = CreateFrame("CheckButton", nil, row, "InterfaceOptionsCheckButtonTemplate")
    select:SetSize(20, 20)
    select:SetPoint("LEFT", 4, 0)
    select:SetScript("OnClick", function(self)
        local key = self.resultKey
        if key then
            selectedMap()[key] = self:GetChecked() and true or nil
            refreshExecutor()
            if list then list:Refresh() end
        end
    end)
    row.select = select

    local name = row:CreateFontString(nil, "ARTWORK")
    name:SetFontObject(Theme.font.body)
    name:SetJustifyH("LEFT")
    name:SetPoint("LEFT", COL.leftPad, 0)
    name:SetWidth(COL.name)
    name:SetWordWrap(false)
    row.name = name

    local rank = row:CreateFontString(nil, "ARTWORK")
    rank:SetFontObject(Theme.font.muted)
    rank:SetJustifyH("LEFT")
    rank:SetPoint("LEFT", name, "RIGHT", COL.gap, 0)
    rank:SetWidth(COL.rank)
    rank:SetWordWrap(false)
    row.rank = rank

    local offline = row:CreateFontString(nil, "ARTWORK")
    offline:SetFontObject(Theme.font.muted)
    offline:SetJustifyH("LEFT")
    offline:SetPoint("LEFT", rank, "RIGHT", COL.gap, 0)
    offline:SetWidth(COL.offline)
    row.offline = offline

    local reason = row:CreateFontString(nil, "ARTWORK")
    reason:SetFontObject(Theme.font.muted)
    reason:SetJustifyH("LEFT")
    reason:SetPoint("LEFT", offline, "RIGHT", COL.gap, 0)
    reason:SetPoint("RIGHT", -8, 0)
    reason:SetWordWrap(false)
    row.reason = reason

    return row
end

local function updateRow(row, result)
    row.result = result
    row.executionIndex = result.executionIndex
    row.select.resultKey = rowKey(result)
    row.select:SetChecked(isRowSelected(result))
    row:SetBackdropColor(unpack(Theme.color.panelRaised))
    row:SetBackdropBorderColor(unpack(result.executionIndex == controls.executionIndex and Theme.color.accent or Theme.color.border))
    row.name:SetText(truncate(result.player.name, 24))
    row.name:SetTextColor(classColorOf(result.player.class))
    if result.targetRankName and result.targetRankName ~= "" then
        row.rank:SetText(truncate((result.player.rankName or GP.L["Unknown"]) .. " > " .. result.targetRankName, 22))
    else
        row.rank:SetText(truncate(result.player.rankName or GP.L["Unknown"], 20))
    end
    row.offline:SetText(result.player.online and GP.L["Online"] or (result.offlineDays and (result.offlineDays .. "d") or "?"))
    row.reason:SetText(truncate(table.concat(result.reasons, "; "), 84))
end

local function syncControls(settings)
    paintButtons(actionButtons, settings.action)
    paintButtons(scopeButtons, settings.targetScope)
    paintButtons(levelButtons, settings.levelMode)
    local isStandardAction = settings.action == "kick" or settings.action == "promote" or settings.action == "demote"
    local isSpecialAction = settings.action == "special"
    local hasAction = isStandardAction or isSpecialAction

    if controls.includeOnline then controls.includeOnline:SetChecked(settings.includeOnline) end
    if controls.specialSameRank then controls.specialSameRank:SetChecked(settings.specialSameRank) end
    if controls.specialDisableDemote then controls.specialDisableDemote:SetChecked(settings.specialDisableDemote) end
    if controls.allRanks then controls.allRanks:SetChecked(settings.allRanks) end
    if controls.requireEmpty then controls.requireEmpty:SetChecked(settings.requireTextEmptyOnly) end
    if controls.safeAllNotes then controls.safeAllNotes:SetChecked(settings.safeTextAllNotes) end
    if controls.daysBox and not controls.daysBox:HasFocus() then controls.daysBox:SetText(tostring(settings.minOfflineDays)) end
    if controls.rankDaysBox and not controls.rankDaysBox:HasFocus() then controls.rankDaysBox:SetText(tostring(settings.minRankDays or 0)) end
    if controls.onlineWithinBox and not controls.onlineWithinBox:HasFocus() then controls.onlineWithinBox:SetText(tostring(settings.maxOfflineDays or 0)) end
    if controls.minBox and not controls.minBox:HasFocus() then controls.minBox:SetText(tostring(settings.minLevel)) end
    if controls.maxBox and not controls.maxBox:HasFocus() then controls.maxBox:SetText(tostring(settings.maxLevel)) end
    if controls.requireBox and not controls.requireBox:HasFocus() then controls.requireBox:SetText(settings.requireText or "") end
    if controls.safeBox and not controls.safeBox:HasFocus() then controls.safeBox:SetText(settings.safeText or "") end
    if controls.targetRankButton then
        local usesTargetRank = settings.action == "promote" or settings.action == "demote" or (settings.action == "special" and not settings.specialSameRank)
        if usesTargetRank then
            controls.targetRankLabel:Show()
            controls.targetRankButton:Show()
            controls.targetRankLabel:SetText(settings.action == "special" and GP.L["Alt Target Rank"] or GP.L["Target Rank"])
            controls.targetRankButton.text:SetText(settings.targetRankIndex and truncate(rankName(settings.targetRankIndex), 20) or GP.L["Select Rank"])
            if controls.targetRankPicker and controls.targetRankPicker:IsShown() then refreshTargetRankPicker() end
        else
            controls.targetRankLabel:Hide()
            controls.targetRankButton:Hide()
            controls.targetRankLabel:SetText(GP.L["Target Rank"])
            hideTargetRankPicker()
        end
        if controls.specialSameRank and controls.specialDisableDemote then
            controls.specialSameRank:ClearAllPoints()
            if usesTargetRank then
                controls.specialSameRank:SetPoint("TOPLEFT", controls.targetRankButton, "BOTTOMLEFT", 0, -8)
            else
                controls.specialSameRank:SetPoint("TOPLEFT", actionButtons.kick, "BOTTOMLEFT", 0, -12)
            end
            controls.specialDisableDemote:ClearAllPoints()
            controls.specialDisableDemote:SetPoint("TOPLEFT", controls.specialSameRank, "BOTTOMLEFT", 0, -4)
        end
        if controls.scopeLabel then
            controls.scopeLabel:ClearAllPoints()
            if isSpecialAction then
                controls.scopeLabel:SetPoint("TOPLEFT", controls.specialDisableDemote, "BOTTOMLEFT", 0, -12)
            elseif usesTargetRank then
                controls.scopeLabel:SetPoint("TOPLEFT", controls.targetRankButton, "BOTTOMLEFT", 0, -12)
            else
                controls.scopeLabel:SetPoint("TOPLEFT", actionButtons.kick, "BOTTOMLEFT", 0, -12)
            end
        end
        if controls.scopeAll and controls.scopeLabel then
            controls.scopeAll:ClearAllPoints()
            controls.scopeAll:SetPoint("TOPLEFT", controls.scopeLabel, "BOTTOMLEFT", 0, -6)
        end
    end
    if controls.activityLabel then
        controls.activityLabel:ClearAllPoints()
        if isSpecialAction then
            controls.activityLabel:SetText(GP.L["Main Activity"])
            controls.activityLabel:SetPoint("TOPLEFT", controls.specialDisableDemote, "BOTTOMLEFT", 0, -12)
        else
            controls.activityLabel:SetText(GP.L["Activity"])
            controls.activityLabel:SetPoint("TOPLEFT", controls.scopeAll, "BOTTOMLEFT", 0, -12)
        end
    end
    setShown(controls.specialSameRank, isSpecialAction)
    setShown(controls.specialDisableDemote, isSpecialAction)
    setShown(controls.scopeLabel, isStandardAction)
    setGroupShown(scopeButtons, isStandardAction)
    setShown(controls.activityLabel, hasAction)
    setShown(controls.includeOnline, isStandardAction)
    setShown(controls.daysLabel, hasAction)
    setShown(controls.daysBox, hasAction)
    setShown(controls.rankLabel, hasAction)
    setShown(controls.allRanks, hasAction)
    setGroupShown(rankChecks, hasAction)
    setShown(controls.levelLabel, isStandardAction)
    setGroupShown(levelButtons, isStandardAction)
    setShown(controls.minBox, isStandardAction)
    setShown(controls.maxBox, isStandardAction)
    setShown(controls.requireLabel, isStandardAction)
    setShown(controls.requireBox, isStandardAction)
    setShown(controls.requireEmpty, isStandardAction)
    setShown(controls.safeLabel, isStandardAction)
    setShown(controls.safeBox, isStandardAction)
    setShown(controls.safeAllNotes, isStandardAction)

    if controls.rankDaysLabel and controls.rankDaysBox and controls.onlineWithinLabel and controls.onlineWithinBox then
        if settings.action == "promote" then
            if controls.daysLabel then controls.daysLabel:SetText(GP.L["Offline days:"]) end
            controls.daysLabel:ClearAllPoints()
            controls.daysLabel:SetPoint("TOPLEFT", controls.includeOnline, "BOTTOMLEFT", 0, -8)
            controls.rankDaysLabel:Show()
            controls.rankDaysBox:Show()
            controls.onlineWithinLabel:Show()
            controls.onlineWithinBox:Show()
            if controls.rankLabel then
                controls.rankLabel:ClearAllPoints()
                controls.rankLabel:SetPoint("TOPLEFT", controls.onlineWithinLabel, "BOTTOMLEFT", 0, -14)
            end
        elseif settings.action == "special" then
            controls.rankDaysLabel:Hide()
            controls.rankDaysBox:Hide()
            controls.onlineWithinLabel:Hide()
            controls.onlineWithinBox:Hide()
            if controls.daysLabel then controls.daysLabel:SetText(GP.L["Ignore main offline days:"]) end
            controls.daysLabel:ClearAllPoints()
            controls.daysLabel:SetPoint("TOPLEFT", controls.activityLabel, "BOTTOMLEFT", 0, -8)
            if controls.rankLabel then
                controls.rankLabel:ClearAllPoints()
                controls.rankLabel:SetPoint("TOPLEFT", controls.daysLabel, "BOTTOMLEFT", 0, -14)
                controls.rankLabel:SetText(GP.L["Main Ranks"])
            end
        else
            controls.rankDaysLabel:Hide()
            controls.rankDaysBox:Hide()
            controls.onlineWithinLabel:Hide()
            controls.onlineWithinBox:Hide()
            if controls.daysLabel then controls.daysLabel:SetText(GP.L["Offline days:"]) end
            controls.daysLabel:ClearAllPoints()
            controls.daysLabel:SetPoint("TOPLEFT", controls.includeOnline, "BOTTOMLEFT", 0, -8)
            if controls.rankLabel then
                controls.rankLabel:ClearAllPoints()
                controls.rankLabel:SetPoint("TOPLEFT", controls.daysLabel, "BOTTOMLEFT", 0, -14)
                controls.rankLabel:SetText(GP.L["Ranks"])
            end
        end
        if controls.allRanks and controls.rankLabel then
            controls.allRanks:ClearAllPoints()
            controls.allRanks:SetPoint("TOPLEFT", controls.rankLabel, "BOTTOMLEFT", 0, -6)
        end
    end
    for rankIndex, check in pairs(rankChecks) do
        check:SetChecked(settings.selectedRanks[rankIndex] and true or false)
        if settings.allRanks then
            check:Disable()
            check.text:SetTextColor(unpack(Theme.color.textDisabled))
        else
            check:Enable()
            check.text:SetTextColor(unpack(Theme.color.textSecondary))
        end
    end
    if controls.allRanks and controls.allRanks.text then
        controls.allRanks.text:SetText(isSpecialAction and GP.L["Apply to all main ranks"] or GP.L["Apply to all ranks"])
    end
    if controls.ruleNameBox and not controls.ruleNameBox:HasFocus() then
        controls.ruleNameBox:SetText(settings.currentRuleName or "")
    end
    if controls.loadedRuleText then
        local rule = settings.currentRuleName and GP:GetModule("MacroTool"):GetSavedRule(settings.currentRuleName)
        controls.loadedRuleText:SetText(ruleSummary(rule))
    end
    refreshSavedRuleText()
    if controls.savedRulePicker and controls.savedRulePicker:IsShown() then
        refreshSavedRulePicker()
    end
end

function MacroToolTab:Refresh(resetScroll)
    if not frame then return end
    if resetScroll and list then list:SetData({}, true) end

    local MacroTool = GP:GetModule("MacroTool")
    if not MacroTool:CanUse() then
        if summaryText then summaryText:SetText(GP.L["Macro Tool requires officer access."]) end
        if list then list:SetData({}, true) end
        refreshExecutor({})
        return
    end

    local settings = MacroTool:GetSettings()
    syncControls(settings)

    local report, err = MacroTool:Analyze(getGuildKey())
    if not report then
        summaryText:SetText(err or GP.L["No roster data yet — try /gp scan."])
        list:SetData({}, true)
        refreshExecutor({})
        return
    end
    if report.idle then
        summaryText:SetText(GP.L["Pick or load a saved macro rule to preview affected characters."])
        list:SetData({}, true)
        refreshExecutor({})
        return
    end

    summaryText:SetText(string.format(GP.L["Macro preview: %d queued, %d ignored, %d total. Permission: %s. Your rank index: %s."],
        report.queued, report.ignored, report.total, report.permission and GP.L["yes"] or GP.L["no"], report.myRankIndex or GP.L["Unknown"]))
    local queuedRows = {}
    for _, row in ipairs(report.rows) do
        if row.include then
            row.executionIndex = #queuedRows + 1
            table.insert(queuedRows, row)
        end
    end
    local state = MacroTool:GetExecutionState()
    if not controls.selectionTouched and not state.activePlan and (state.remaining or 0) == 0 then
        selectAllQueuedRows(queuedRows)
    end
    refreshExecutor(queuedRows)
    list:SetData(queuedRows, resetScroll)
end

function MacroToolTab:Build(parent)
    local L = GP.L
    local MacroTool = GP:GetModule("MacroTool")
    local settings = MacroTool:GetSettings()

    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    frame.OnSelected = function()
        MacroTool:SetMacroToolVisible(true)
        if MacroToolTab.preserveOnNextSelect then
            MacroToolTab.preserveOnNextSelect = nil
        else
            MacroTool:ResetWorkingRule()
            clearSavedRuleSelection()
            controls.selectionTouched = nil
        end
        MacroToolTab:Refresh(true)
    end
    frame.OnDeselected = function()
        MacroTool:SetMacroToolVisible(false)
    end
    frame:SetScript("OnHide", function()
        MacroTool:SetMacroToolVisible(false)
    end)

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Macro Tool"])

    local guard = frame:CreateFontString(nil, "ARTWORK")
    guard:SetFontObject(Theme.font.muted)
    guard:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -6)
    guard:SetPoint("RIGHT")
    guard:SetJustifyH("LEFT")
    guard:SetText(L["Review matches first. Build Macro updates a visible WoW macro; Guild Paragon does not perform guild actions directly."])

    if not MacroTool:CanUse() then
        local locked = Theme:CreatePanel(frame, "panel", "border")
        locked:SetPoint("TOPLEFT", guard, "BOTTOMLEFT", 0, -18)
        locked:SetSize(520, 96)

        local lockedText = locked:CreateFontString(nil, "ARTWORK")
        lockedText:SetFontObject(Theme.font.body)
        lockedText:SetJustifyH("LEFT")
        lockedText:SetPoint("TOPLEFT", 14, -14)
        lockedText:SetPoint("RIGHT", -14, 0)
        lockedText:SetText(L["Macro Tool requires officer access."])
        return frame
    end

    local options = Theme:CreatePanel(frame, "panel", "border")
    options:SetPoint("TOPLEFT", guard, "BOTTOMLEFT", 0, -12)
    options:SetPoint("BOTTOMLEFT")
    options:SetWidth(520)

    local optTitle = options:CreateFontString(nil, "ARTWORK")
    optTitle:SetFontObject(Theme.font.heading)
    optTitle:SetPoint("TOPLEFT", 10, -10)
    optTitle:SetText(L["Rule Options"])

    local saveLabel = createLabel(options, L["Saved Rules"], optTitle, 0, -12)
    local ruleNameBox = Theme:CreateEditBox(options, 134)
    ruleNameBox:SetPoint("TOPLEFT", saveLabel, "BOTTOMLEFT", 0, -6)
    ruleNameBox:SetText(settings.currentRuleName or "")
    controls.ruleNameBox = ruleNameBox

    local saveButton = makeButton(options, L["Save Rule"], 64)
    saveButton:SetPoint("LEFT", ruleNameBox, "RIGHT", 6, 0)
    saveButton:SetScript("OnClick", function()
        local ok, err = MacroTool:SaveRule(ruleNameBox:GetText())
        if not ok then GP:Print(err) end
        MacroToolTab:Refresh(true)
    end)

    local loadButton = makeButton(options, L["Load"], 56)
    loadButton:SetPoint("LEFT", saveButton, "RIGHT", 6, 0)
    loadButton:SetScript("OnClick", function()
        local ok, err = MacroTool:LoadRule(ruleNameBox:GetText())
        if not ok then GP:Print(err) end
        hideSavedRulePicker()
        MacroToolTab:Refresh(true)
    end)

    local deleteButton = makeButton(options, L["Delete"], 58)
    deleteButton:SetPoint("TOPLEFT", ruleNameBox, "BOTTOMLEFT", 0, -6)
    deleteButton:SetScript("OnClick", function()
        confirmDeleteRule(ruleNameBox:GetText())
    end)

    local pickButton = makeButton(options, L["Pick"], 52)
    pickButton:SetPoint("LEFT", deleteButton, "RIGHT", 6, 0)
    pickButton:SetScript("OnClick", toggleSavedRulePicker)

    local savedRulesText = options:CreateFontString(nil, "ARTWORK")
    savedRulesText:SetFontObject(Theme.font.small)
    savedRulesText:SetJustifyH("LEFT")
    savedRulesText:SetPoint("LEFT", pickButton, "RIGHT", 8, 0)
    savedRulesText:SetWidth(130)
    savedRulesText:SetWordWrap(false)
    controls.savedRulesText = savedRulesText

    local loadedRuleText = options:CreateFontString(nil, "ARTWORK")
    loadedRuleText:SetFontObject(Theme.font.small)
    loadedRuleText:SetJustifyH("LEFT")
    loadedRuleText:SetPoint("TOPLEFT", deleteButton, "BOTTOMLEFT", 0, -6)
    loadedRuleText:SetWidth(340)
    loadedRuleText:SetWordWrap(false)
    controls.loadedRuleText = loadedRuleText

    local savedRulePicker = Theme:CreatePanel(options, "backdrop", "border")
    savedRulePicker:SetFrameLevel(options:GetFrameLevel() + 20)
    savedRulePicker:SetPoint("TOPLEFT", deleteButton, "BOTTOMLEFT", 0, -4)
    savedRulePicker:SetWidth(354)
    savedRulePicker:EnableMouse(true)
    savedRulePicker:Hide()
    savedRulePicker.empty = savedRulePicker:CreateFontString(nil, "ARTWORK")
    savedRulePicker.empty:SetFontObject(Theme.font.muted)
    savedRulePicker.empty:SetPoint("CENTER")
    savedRulePicker.empty:SetText(L["No saved rules yet."])
    controls.savedRulePicker = savedRulePicker

    local actionLabel = createLabel(options, L["Action"], loadedRuleText, 0, -12)
    local actionWidth = 64
    local kick = modeButton(options, actionButtons, "kick", L["Kick"], function(v) MacroTool:SetSetting("action", v) end, actionWidth)
    kick:SetPoint("TOPLEFT", actionLabel, "BOTTOMLEFT", 0, -6)
    local promote = modeButton(options, actionButtons, "promote", L["Promote"], function(v) MacroTool:SetSetting("action", v) end, actionWidth)
    promote:SetPoint("LEFT", kick, "RIGHT", 6, 0)
    local demote = modeButton(options, actionButtons, "demote", L["Demote"], function(v) MacroTool:SetSetting("action", v) end, actionWidth)
    demote:SetPoint("LEFT", promote, "RIGHT", 6, 0)
    local special = modeButton(options, actionButtons, "special", L["Special"], function(v) MacroTool:SetSetting("action", v) end, actionWidth)
    special:SetPoint("LEFT", demote, "RIGHT", 6, 0)

    local targetRankLabel = createLabel(options, L["Target Rank"], kick, 0, -12)
    controls.targetRankLabel = targetRankLabel
    local targetRankButton = makeButton(options, L["Select Rank"], 150)
    targetRankButton:SetPoint("TOPLEFT", targetRankLabel, "BOTTOMLEFT", 0, -6)
    targetRankButton:SetScript("OnClick", toggleTargetRankPicker)
    controls.targetRankButton = targetRankButton

    local targetRankPicker = Theme:CreatePanel(options, "backdrop", "border")
    targetRankPicker:SetFrameLevel(options:GetFrameLevel() + 20)
    targetRankPicker:SetPoint("TOPLEFT", targetRankButton, "BOTTOMLEFT", 0, -4)
    targetRankPicker:SetWidth(204)
    targetRankPicker:EnableMouse(true)
    targetRankPicker:Hide()
    targetRankPicker.empty = targetRankPicker:CreateFontString(nil, "ARTWORK")
    targetRankPicker.empty:SetFontObject(Theme.font.muted)
    targetRankPicker.empty:SetPoint("CENTER")
    targetRankPicker.empty:SetText(L["No guild ranks found."])
    controls.targetRankPicker = targetRankPicker

    controls.specialSameRank = createCheck(options, L["Move alts to same rank as main"], settings.specialSameRank, function(value)
        MacroTool:SetSetting("specialSameRank", value)
        MacroToolTab:Refresh(true)
    end)
    controls.specialSameRank:SetPoint("TOPLEFT", targetRankButton, "BOTTOMLEFT", 0, -8)
    controls.specialDisableDemote = createCheck(options, L["Disable demote option; only promote alts"], settings.specialDisableDemote, function(value)
        MacroTool:SetSetting("specialDisableDemote", value)
        MacroToolTab:Refresh(true)
    end)
    controls.specialDisableDemote:SetPoint("TOPLEFT", controls.specialSameRank, "BOTTOMLEFT", 0, -4)

    local scopeLabel = createLabel(options, L["Apply Rules To"], targetRankButton, 0, -12)
    controls.scopeLabel = scopeLabel
    local scopeWidth = 74
    local all = modeButton(options, scopeButtons, "all", L["All"], function(v) MacroTool:SetSetting("targetScope", v) end, scopeWidth)
    all:SetPoint("TOPLEFT", scopeLabel, "BOTTOMLEFT", 0, -6)
    controls.scopeAll = all
    local alts = modeButton(options, scopeButtons, "alts", L["Alts Only"], function(v) MacroTool:SetSetting("targetScope", v) end, scopeWidth)
    alts:SetPoint("LEFT", all, "RIGHT", 6, 0)
    local mains = modeButton(options, scopeButtons, "mains", L["Mains Only"], function(v) MacroTool:SetSetting("targetScope", v) end, scopeWidth)
    mains:SetPoint("LEFT", alts, "RIGHT", 6, 0)

    local activityLabel = createLabel(options, L["Activity"], all, 0, -12)
    controls.activityLabel = activityLabel
    controls.includeOnline = createCheck(options, L["Include online"], settings.includeOnline, function(value)
        MacroTool:SetSetting("includeOnline", value)
        MacroToolTab:Refresh(true)
    end)
    controls.includeOnline:SetPoint("TOPLEFT", activityLabel, "BOTTOMLEFT", 0, -6)

    local daysLabel = options:CreateFontString(nil, "ARTWORK")
    daysLabel:SetFontObject(Theme.font.small)
    daysLabel:SetPoint("TOPLEFT", controls.includeOnline, "BOTTOMLEFT", 0, -8)
    daysLabel:SetText(L["Offline days:"])
    controls.daysLabel = daysLabel
    local daysBox = Theme:CreateEditBox(options, 56)
    daysBox:SetPoint("LEFT", daysLabel, "RIGHT", 8, 0)
    daysBox:SetText(tostring(settings.minOfflineDays))
    controls.daysBox = daysBox
    daysBox:SetScript("OnEnterPressed", function(self)
        MacroTool:SetSetting("minOfflineDays", tonumber(self:GetText()) or 0)
        self:ClearFocus()
        MacroToolTab:Refresh(true)
    end)
    daysBox:SetScript("OnEditFocusLost", function(self)
        MacroTool:SetSetting("minOfflineDays", tonumber(self:GetText()) or 0)
        MacroToolTab:Refresh(true)
    end)

    local rankDaysLabel = options:CreateFontString(nil, "ARTWORK")
    rankDaysLabel:SetFontObject(Theme.font.small)
    rankDaysLabel:SetPoint("TOPLEFT", daysLabel, "BOTTOMLEFT", 0, -8)
    rankDaysLabel:SetText(L["Rank days:"])
    controls.rankDaysLabel = rankDaysLabel
    local rankDaysBox = Theme:CreateEditBox(options, 56)
    rankDaysBox:SetPoint("LEFT", rankDaysLabel, "RIGHT", 8, 0)
    rankDaysBox:SetText(tostring(settings.minRankDays or 0))
    controls.rankDaysBox = rankDaysBox
    rankDaysBox:SetScript("OnEnterPressed", function(self)
        MacroTool:SetSetting("minRankDays", tonumber(self:GetText()) or 0)
        self:ClearFocus()
        MacroToolTab:Refresh(true)
    end)
    rankDaysBox:SetScript("OnEditFocusLost", function(self)
        MacroTool:SetSetting("minRankDays", tonumber(self:GetText()) or 0)
        MacroToolTab:Refresh(true)
    end)

    local onlineWithinLabel = options:CreateFontString(nil, "ARTWORK")
    onlineWithinLabel:SetFontObject(Theme.font.small)
    onlineWithinLabel:SetPoint("TOPLEFT", rankDaysLabel, "BOTTOMLEFT", 0, -8)
    onlineWithinLabel:SetText(L["Online within days:"])
    controls.onlineWithinLabel = onlineWithinLabel
    local onlineWithinBox = Theme:CreateEditBox(options, 56)
    onlineWithinBox:SetPoint("LEFT", onlineWithinLabel, "RIGHT", 8, 0)
    onlineWithinBox:SetText(tostring(settings.maxOfflineDays or 0))
    controls.onlineWithinBox = onlineWithinBox
    onlineWithinBox:SetScript("OnEnterPressed", function(self)
        MacroTool:SetSetting("maxOfflineDays", tonumber(self:GetText()) or 0)
        self:ClearFocus()
        MacroToolTab:Refresh(true)
    end)
    onlineWithinBox:SetScript("OnEditFocusLost", function(self)
        MacroTool:SetSetting("maxOfflineDays", tonumber(self:GetText()) or 0)
        MacroToolTab:Refresh(true)
    end)

    local rankLabel = createLabel(options, L["Ranks"], onlineWithinLabel, 0, -14)
    controls.rankLabel = rankLabel
    controls.allRanks = createCheck(options, L["Apply to all ranks"], settings.allRanks, function(value)
        MacroTool:SetSetting("allRanks", value)
        MacroToolTab:Refresh(true)
    end)
    controls.allRanks:SetPoint("TOPLEFT", rankLabel, "BOTTOMLEFT", 0, -6)
    rebuildRankChecks(options, controls.allRanks)

    local levelLabel = createLabel(options, L["Level"], optTitle, 285, -12)
    controls.levelLabel = levelLabel
    local levelWidth = 70
    local levelAll = modeButton(options, levelButtons, "all", L["All"], function(v) MacroTool:SetSetting("levelMode", v) end, levelWidth)
    levelAll:SetPoint("TOPLEFT", levelLabel, "BOTTOMLEFT", 0, -6)
    local levelMax = modeButton(options, levelButtons, "max", L["Max"], function(v) MacroTool:SetSetting("levelMode", v) end, levelWidth)
    levelMax:SetPoint("LEFT", levelAll, "RIGHT", 6, 0)
    local levelRange = modeButton(options, levelButtons, "range", L["Range"], function(v) MacroTool:SetSetting("levelMode", v) end, levelWidth)
    levelRange:SetPoint("LEFT", levelMax, "RIGHT", 6, 0)

    local minBox = Theme:CreateEditBox(options, 44)
    minBox:SetPoint("TOPLEFT", levelAll, "BOTTOMLEFT", 0, -8)
    minBox:SetText(tostring(settings.minLevel))
    controls.minBox = minBox
    local maxBox = Theme:CreateEditBox(options, 44)
    maxBox:SetPoint("LEFT", minBox, "RIGHT", 8, 0)
    maxBox:SetText(tostring(settings.maxLevel))
    controls.maxBox = maxBox
    local function saveLevels()
        MacroTool:SetSetting("minLevel", tonumber(minBox:GetText()) or 1)
        MacroTool:SetSetting("maxLevel", tonumber(maxBox:GetText()) or 90)
        MacroToolTab:Refresh(true)
    end
    minBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); saveLevels() end)
    maxBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); saveLevels() end)
    minBox:SetScript("OnEditFocusLost", saveLevels)
    maxBox:SetScript("OnEditFocusLost", saveLevels)

    local requireLabel = createLabel(options, L["Require Text Match"], minBox, 0, -14)
    controls.requireLabel = requireLabel
    local requireBox = Theme:CreateEditBox(options, 210)
    requireBox:SetPoint("TOPLEFT", requireLabel, "BOTTOMLEFT", 0, -6)
    requireBox:SetText(settings.requireText or "")
    controls.requireBox = requireBox
    requireBox:SetScript("OnEnterPressed", function(self)
        MacroTool:SetSetting("requireText", self:GetText() or "")
        self:ClearFocus()
        MacroToolTab:Refresh(true)
    end)
    requireBox:SetScript("OnEditFocusLost", function(self)
        MacroTool:SetSetting("requireText", self:GetText() or "")
        MacroToolTab:Refresh(true)
    end)
    controls.requireEmpty = createCheck(options, L["Only empty notes"], settings.requireTextEmptyOnly, function(value)
        MacroTool:SetSetting("requireTextEmptyOnly", value)
        MacroToolTab:Refresh(true)
    end)
    controls.requireEmpty:SetPoint("TOPLEFT", requireBox, "BOTTOMLEFT", 0, -4)

    local safeLabel = createLabel(options, L["Ignore Rule With Text Match"], controls.requireEmpty, 0, -10)
    controls.safeLabel = safeLabel
    local safeBox = Theme:CreateEditBox(options, 210)
    safeBox:SetPoint("TOPLEFT", safeLabel, "BOTTOMLEFT", 0, -6)
    safeBox:SetText(settings.safeText or "")
    controls.safeBox = safeBox
    safeBox:SetScript("OnEnterPressed", function(self)
        MacroTool:SetSetting("safeText", self:GetText() or "")
        self:ClearFocus()
        MacroToolTab:Refresh(true)
    end)
    safeBox:SetScript("OnEditFocusLost", function(self)
        MacroTool:SetSetting("safeText", self:GetText() or "")
        MacroToolTab:Refresh(true)
    end)
    controls.safeAllNotes = createCheck(options, L["Search all notes for safe tag"], settings.safeTextAllNotes, function(value)
        MacroTool:SetSetting("safeTextAllNotes", value)
        MacroToolTab:Refresh(true)
    end)
    controls.safeAllNotes:SetPoint("TOPLEFT", safeBox, "BOTTOMLEFT", 0, -4)

    controls.suppressMacroChatSpam = createCheck(options, L["Disable chat log spam while using the Macro Tool"], settings.suppressMacroChatSpam, function(value)
        MacroTool:SetSetting("suppressMacroChatSpam", value)
        MacroToolTab:Refresh(true)
    end)
    controls.suppressMacroChatSpam:SetPoint("BOTTOMLEFT", options, "BOTTOMLEFT", 12, 46)

    local clearFormButton = makeButton(options, L["Clear All"], 86)
    clearFormButton:SetPoint("BOTTOMRIGHT", options, "BOTTOMRIGHT", -12, 12)
    clearFormButton:SetScript("OnClick", function()
        local ok, msg = MacroTool:ClearExecutionMacro()
        if not ok then
            GP:Print(msg or L["Could not clear the Guild Paragon macro."])
            return
        end
        MacroTool:ResetWorkingRule()
        clearSavedRuleSelection()
        hideTargetRankPicker()
        controls.executionIndex = nil
        wipe(selectedMap())
        controls.selectionTouched = nil
        MacroToolTab:Refresh(true)
    end)

    local howToUseButton = makeButton(options, L["How to Use"], 104)
    howToUseButton:SetPoint("BOTTOMLEFT", options, "BOTTOMLEFT", 12, 12)
    howToUseButton:SetScript("OnClick", showMacroToolHelp)

    summaryText = frame:CreateFontString(nil, "ARTWORK")
    summaryText:SetFontObject(Theme.font.muted)
    summaryText:SetJustifyH("LEFT")
    summaryText:SetPoint("TOPLEFT", options, "TOPRIGHT", 20, 0)
    summaryText:SetPoint("RIGHT")

    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(Theme.layout.rowHeight)
    header:SetPoint("TOPLEFT", summaryText, "BOTTOMLEFT", 0, -8)
    header:SetPoint("RIGHT")

    local headers = {
        { L["Name"], COL.leftPad, COL.name },
        { L["Rank Change"], COL.leftPad + COL.name + COL.gap, COL.rank },
        { L["Offline"], COL.leftPad + COL.name + COL.gap + COL.rank + COL.gap, COL.offline },
    }
    for _, h in ipairs(headers) do
        local fs = header:CreateFontString(nil, "ARTWORK")
        fs:SetFontObject(Theme.font.small)
        fs:SetJustifyH("LEFT")
        fs:SetPoint("LEFT", h[2], 0)
        fs:SetWidth(h[3])
        fs:SetText(h[1])
    end
    local reasonHeader = header:CreateFontString(nil, "ARTWORK")
    reasonHeader:SetFontObject(Theme.font.small)
    reasonHeader:SetPoint("LEFT", COL.leftPad + COL.name + COL.gap + COL.rank + COL.gap + COL.offline + COL.gap, 0)
    reasonHeader:SetText(L["Reason"])

    local executor = Theme:CreatePanel(frame, "panel", "border")
    executor:SetPoint("BOTTOMLEFT", options, "BOTTOMRIGHT", 20, 0)
    executor:SetPoint("BOTTOMRIGHT")
    executor:SetHeight(250)
    executor:EnableMouse(true)
    controls.executor = executor

    local executorTitle = executor:CreateFontString(nil, "ARTWORK")
    executorTitle:SetFontObject(Theme.font.heading)
    executorTitle:SetPoint("TOPLEFT", 10, -10)
    executorTitle:SetText(L["Current Macro"])

    local clearSelectionButton = makeButton(executor, L["Clear Selection"], 104)
    clearSelectionButton:SetPoint("TOPRIGHT", executor, "TOPRIGHT", -10, -8)
    clearSelectionButton:SetScript("OnClick", function()
        controls.selectionTouched = true
        wipe(selectedMap())
        refreshExecutor()
        if list then list:Refresh() end
    end)

    local selectAllButton = makeButton(executor, L["Select All"], 84)
    selectAllButton:SetPoint("RIGHT", clearSelectionButton, "LEFT", -6, 0)
    selectAllButton:SetScript("OnClick", function()
        controls.selectionTouched = true
        selectAllQueuedRows(controls.queuedRows or {})
        refreshExecutor()
        if list then list:Refresh() end
    end)

    local executionSummary = executor:CreateFontString(nil, "ARTWORK")
    executionSummary:SetFontObject(Theme.font.body)
    executionSummary:SetJustifyH("LEFT")
    executionSummary:SetPoint("TOPLEFT", executorTitle, "BOTTOMLEFT", 0, -8)
    executionSummary:SetPoint("RIGHT", selectAllButton, "LEFT", -10, 0)
    executionSummary:SetWordWrap(false)
    controls.executionSummary = executionSummary

    local executionQueueText = executor:CreateFontString(nil, "ARTWORK")
    executionQueueText:SetFontObject(Theme.font.small)
    executionQueueText:SetJustifyH("LEFT")
    executionQueueText:SetPoint("TOPLEFT", executionSummary, "BOTTOMLEFT", 0, -5)
    executionQueueText:SetPoint("RIGHT", -10, 0)
    executionQueueText:SetWordWrap(false)
    controls.executionQueueText = executionQueueText

    local executionBatchText = executor:CreateFontString(nil, "ARTWORK")
    executionBatchText:SetFontObject(Theme.font.small)
    executionBatchText:SetJustifyH("LEFT")
    executionBatchText:SetPoint("TOPLEFT", executionQueueText, "BOTTOMLEFT", 0, -5)
    executionBatchText:SetPoint("RIGHT", -10, 0)
    executionBatchText:SetWordWrap(false)
    controls.executionBatchText = executionBatchText

    local bodyPanel = Theme:CreatePanel(executor, "backdrop", "border")
    bodyPanel:SetPoint("TOPLEFT", executionBatchText, "BOTTOMLEFT", 0, -6)
    bodyPanel:SetPoint("RIGHT", -10, 0)
    bodyPanel:SetHeight(52)
    bodyPanel:EnableMouse(true)

    local executionBody = bodyPanel:CreateFontString(nil, "ARTWORK")
    executionBody:SetFontObject(Theme.font.muted)
    executionBody:SetJustifyH("LEFT")
    executionBody:SetJustifyV("TOP")
    executionBody:SetPoint("TOPLEFT", 8, -6)
    executionBody:SetPoint("BOTTOMRIGHT", -8, 6)
    controls.executionBody = executionBody

    local executionHistoryText = executor:CreateFontString(nil, "ARTWORK")
    executionHistoryText:SetFontObject(Theme.font.small)
    executionHistoryText:SetJustifyH("LEFT")
    executionHistoryText:SetPoint("TOPLEFT", bodyPanel, "BOTTOMLEFT", 0, -6)
    executionHistoryText:SetPoint("RIGHT", -10, 0)
    executionHistoryText:SetWordWrap(false)
    controls.executionHistoryText = executionHistoryText

    local buildMacroButton = makeButton(executor, L["Build Macro"], 104)
    buildMacroButton:SetPoint("BOTTOMLEFT", 10, 12)
    buildMacroButton:SetScript("OnClick", function()
        local rows
        local selectedRows = selectedRowsFrom(controls.queuedRows or {})
        local state = MacroTool:GetExecutionState()
        if #selectedRows > 0 then
            rows = selectedRows
        elseif state.remaining == 0 then
            local current = controls.executionIndex and (controls.queuedRows or {})[controls.executionIndex]
            rows = current and { current } or nil
        end

        local ok, msg, plan = MacroTool:BuildExecutionBatch(rows)
        if ok then
            wipe(selectedMap())
            controls.selectionTouched = true
            controls.executionPlan = plan
            if list then list:Refresh() end
            refreshExecutor()
        end
        GP:Print(msg or (ok and L["Macro updated."] or L["Could not update the Guild Paragon macro."]))
    end)

    local nextButton = makeButton(executor, L["Next"], 58)
    nextButton:SetPoint("LEFT", buildMacroButton, "RIGHT", 6, 0)
    nextButton:SetScript("OnClick", function()
        local rows = controls.queuedRows or {}
        if #rows == 0 then return end
        controls.executionIndex = ((controls.executionIndex or 0) % #rows) + 1
        refreshExecutor(rows)
        if list then list:Refresh() end
    end)

    local clearMacroButton = makeButton(executor, L["Clear Macro"], 94)
    clearMacroButton:SetPoint("LEFT", nextButton, "RIGHT", 6, 0)
    clearMacroButton:SetScript("OnClick", function()
        local ok, msg = MacroTool:ClearExecutionMacro()
        refreshExecutor()
        if list then list:Refresh() end
        GP:Print(msg or (ok and L["Macro cleared."] or L["Could not clear the Guild Paragon macro."]))
    end)

    local executionHint = executor:CreateFontString(nil, "ARTWORK")
    executionHint:SetFontObject(Theme.font.small)
    executionHint:SetJustifyH("LEFT")
    executionHint:SetPoint("BOTTOMLEFT", buildMacroButton, "TOPLEFT", 0, 52)
    executionHint:SetPoint("RIGHT", -10, 0)
    executionHint:SetWordWrap(false)
    controls.executionHint = executionHint

    local hotKeyLabel = executor:CreateFontString(nil, "ARTWORK")
    hotKeyLabel:SetFontObject(Theme.font.small)
    hotKeyLabel:SetPoint("BOTTOMLEFT", buildMacroButton, "TOPLEFT", 0, 12)
    hotKeyLabel:SetText(L["Hot Key:"])

    local hotKeyBox = Theme:CreateEditBox(executor, 148)
    hotKeyBox:SetPoint("LEFT", hotKeyLabel, "RIGHT", 10, 0)
    hotKeyBox:SetText(MacroTool:GetExecutionHotKey())
    hotKeyBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    end)
    hotKeyBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(Theme.color.border))
    end)
    controls.hotKeyBox = hotKeyBox

    local function applyHotKeyFromBox()
        local _, msg = MacroTool:SetExecutionHotKey(hotKeyBox:GetText())
        hotKeyBox:ClearFocus()
        if msg then GP:Print(msg) end
        refreshExecutor()
    end

    hotKeyBox:SetScript("OnEnterPressed", applyHotKeyFromBox)
    hotKeyBox:SetScript("OnEscapePressed", function(self)
        self:SetText(MacroTool:GetExecutionHotKey())
        self:ClearFocus()
    end)

    local applyHotKeyButton = makeButton(executor, L["Apply"], 66)
    applyHotKeyButton:SetPoint("LEFT", hotKeyBox, "RIGHT", 8, 0)
    applyHotKeyButton:SetScript("OnClick", applyHotKeyFromBox)

    local listArea = CreateFrame("Frame", nil, frame)
    listArea:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    listArea:SetPoint("BOTTOMRIGHT", executor, "TOPRIGHT", 0, 8)
    list = GP.UI.ScrollList:New(listArea, ROW_HEIGHT, createRow)
    list:SetUpdateRow(updateRow)

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua: a Guild Sync full-state apply can fire hundreds of
    -- these in one burst; collapse to one refresh on the next frame.
    local function refreshIfShown()
        if frame and frame:IsShown() then
            GP:DebounceCall("MacroToolTab:Refresh", function() MacroToolTab:Refresh() end)
        end
    end
    MacroToolTab:RegisterMessage("GuildParagon_RosterScanned", refreshIfShown)
    MacroToolTab:RegisterMessage("GuildParagon_AltsChanged", refreshIfShown)
    MacroToolTab:RegisterMessage("GuildParagon_CustomNotesChanged", refreshIfShown)
    MacroToolTab:RegisterMessage("GuildParagon_MacroRuleChanged", refreshIfShown)
    MacroToolTab:RegisterMessage("GuildParagon_MacroIgnoresChanged", refreshIfShown)
    MacroToolTab:RegisterMessage("GuildParagon_MacroExecutorChanged", refreshIfShown)

    refreshSavedRuleText()
    clearSavedRuleSelection()
    self:Refresh(true)
    return frame
end
