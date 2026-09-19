-- Guild Paragon — Backup / Restore tab
--
-- Officer-only manual snapshots for the current guild bucket.
local _, GP = ...
local Theme = GP.UI.Theme

GP.UI.BackupRestoreTab = GP.UI.BackupRestoreTab or {}
local BackupRestoreTab = GP.UI.BackupRestoreTab

-- Own AceEvent identity, not GP — see UI/RecruitmentTab.lua's long comment
-- above its own Embed call for the full root-cause explanation: multiple
-- tabs registering the same message name against the shared GP table
-- silently overwrite each other. This tab shared GuildParagon_RosterScanned
-- with several other GP-registered tabs before this fix.
LibStub("AceEvent-3.0"):Embed(BackupRestoreTab)

local ROW_HEIGHT = 34
local RESTORE_POPUP = "GUILDPARAGON_RESTORE_BACKUP"
local REMOVE_POPUP = "GUILDPARAGON_REMOVE_BACKUP"
local RELOAD_POPUP = "GUILDPARAGON_RESTORE_RELOAD"

local frame, list, selectedID
local refreshDirty = false
local comparisonCache, comparisonPending = {}, {}

local function createCheck(parent, label)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check.Text:SetFontObject(Theme.font.body)
    check.Text:SetText(label)
    return check
end

local function formatDate(ts)
    return type(ts) == "number" and date("%Y-%m-%d %H:%M", ts) or ""
end

local function summaryLine(summary)
    summary = summary or {}
    return string.format(GP.L["%d active, %d former, %d log, %d alt link(s), %d nickname(s), %d custom note(s)"],
        summary.active or 0, summary.former or 0, summary.log or 0, summary.alts or 0,
        summary.nicknames or 0, summary.customNotes or 0)
end

local function comparisonLines(rows)
    if rows == nil then return { GP.L["Calculating category comparison..."] } end
    if not rows or #rows == 0 then return { GP.L["No category differences detected."] } end
    local lines = { GP.L["Changes if restored (stored compared with current):"] }
    for _, row in ipairs(rows) do
        if row.category == "log" then
            lines[#lines + 1] = string.format(GP.L["%s [%s]: %d stored / %d current"],
                row.category, row.flags, row.stored or 0, row.current or 0)
        else
            local newer = row.newerCurrent > 0 and string.format(GP.L[", %d newer current"], row.newerCurrent) or ""
            lines[#lines + 1] = string.format(GP.L["%s [%s]: +%d / -%d / %d changed%s"],
                row.category, row.flags, row.added, row.removed, row.changed, newer)
            if row.risks then
                if (row.risks.joinDates or 0) > 0 then
                    lines[#lines + 1] = string.format(GP.L["  %d newer current join date(s)"], row.risks.joinDates)
                end
                if (row.risks.birthdays or 0) > 0 then
                    lines[#lines + 1] = string.format(GP.L["  %d newer current birthday(s)"], row.risks.birthdays)
                end
                if (row.risks.gmPolicy or 0) > 0 then
                    lines[#lines + 1] = GP.L["  Newer current guild-master Recruitment policy"]
                end
                if (row.risks.blacklist or 0) > 0 then
                    lines[#lines + 1] = string.format(GP.L["  %d newer current Recruitment blacklist record(s)"], row.risks.blacklist)
                end
                if (row.risks.localState or 0) > 0 then
                    lines[#lines + 1] = string.format(GP.L["  %d newer local Recruitment working-state record(s)"], row.risks.localState)
                end
            end
        end
    end
    return lines
end

local function selectedBackup()
    if not frame or not selectedID then return nil end
    for _, backup in ipairs(GP:GetModule("BackupRestore"):GetBackups(frame.guildKey)) do
        if backup.id == selectedID then return backup end
    end
    return nil
end

local function applyRowState(row, selected, hovered)
    if selected or hovered then
        row:SetBackdropColor(unpack(Theme.color.panelRaised))
        row:SetBackdropBorderColor(unpack(Theme.color.accentDim))
    else
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

StaticPopupDialogs[RELOAD_POPUP] = StaticPopupDialogs[RELOAD_POPUP] or {
    text = GP.L["Backup restored successfully. Reload the UI now to finish applying migrations."],
    button1 = GP.L["Reload UI"],
    button2 = GP.L["Later"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
    OnAccept = function() ReloadUI() end,
}

StaticPopupDialogs[RESTORE_POPUP] = StaticPopupDialogs[RESTORE_POPUP] or {
    text = GP.L["Restore backup '%s'?\n\nThis replaces all Guild Paragon data for this guild. Type %s to confirm."],
    button1 = GP.L["Restore"],
    button2 = GP.L["Cancel"],
    hasEditBox = true,
    editBoxWidth = 160,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local editBox = self.editBox or self.EditBox
        if editBox then
            editBox:SetText("")
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local editBox = self.editBox or self.EditBox
        if not editBox or editBox:GetText() ~= data.confirmation then
            GP:Print(string.format(GP.L["Restore cancelled. Type %s exactly to confirm."], data.confirmation))
            return
        end
        if frame then frame.restoringBackup = true BackupRestoreTab:Refresh() end
        GP:GetModule("BackupRestore"):RestoreBackupAsync(data.guildKey, data.id, function(ok, err)
            if frame then frame.restoringBackup = false end
            if ok then
                GP:Print(GP.L["Backup restored. Reload is required."])
                StaticPopup_Show(RELOAD_POPUP)
            else
                GP:Print(err)
                BackupRestoreTab:Refresh()
            end
        end)
    end,
}

StaticPopupDialogs[REMOVE_POPUP] = StaticPopupDialogs[REMOVE_POPUP] or {
    text = GP.L["Remove backup '%s'?\n\nType %s to confirm."],
    button1 = GP.L["Remove"],
    button2 = GP.L["Cancel"],
    hasEditBox = true,
    editBoxWidth = 160,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self)
        local editBox = self.editBox or self.EditBox
        if editBox then
            editBox:SetText("")
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local editBox = self.editBox or self.EditBox
        if not editBox or editBox:GetText() ~= data.confirmation then
            GP:Print(string.format(GP.L["Remove cancelled. Type %s exactly to confirm."], data.confirmation))
            return
        end
        local ok, err = GP:GetModule("BackupRestore"):RemoveBackup(data.guildKey, data.id)
        if ok then selectedID = nil end
        GP:Print(ok and GP.L["Backup removed."] or err)
        BackupRestoreTab:Refresh()
    end,
}

local function createRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetBackdrop((Theme:Backdrop("panelRaised")))
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "ARTWORK")
    row.name:SetFontObject(Theme.font.body)
    row.name:SetPoint("TOPLEFT", 8, -5)
    row.name:SetWidth(230)
    row.name:SetJustifyH("LEFT")

    row.date = row:CreateFontString(nil, "ARTWORK")
    row.date:SetFontObject(Theme.font.small)
    row.date:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.date:SetWidth(150)
    row.date:SetJustifyH("LEFT")

    row.summary = row:CreateFontString(nil, "ARTWORK")
    row.summary:SetFontObject(Theme.font.small)
    row.summary:SetPoint("LEFT", 260, 0)
    row.summary:SetPoint("RIGHT", -8, 0)
    row.summary:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self)
        selectedID = self.backup and self.backup.id or nil
        BackupRestoreTab:Refresh()
    end)
    row:SetScript("OnEnter", function(self)
        applyRowState(self, selectedID == (self.backup and self.backup.id), true)
    end)
    row:SetScript("OnLeave", function(self)
        applyRowState(self, selectedID == (self.backup and self.backup.id), false)
    end)

    return row
end

local function updateRow(row, backup)
    row.backup = backup
    row.name:SetText(backup.name or backup.id)
    row.date:SetText(string.format(GP.L["%s by %s"], formatDate(backup.createdAt), backup.createdBy or GP.L["Unknown"]))
    local state = backup.isValid and GP.L["Ready"] or (backup.validationState == "unsupported" and GP.L["Unsupported"] or GP.L["Corrupt"])
    row.summary:SetText(string.format(GP.L["%s - %s - %s"], backup.backupClass or "manual", state, summaryLine(backup.summary)))

    if selectedID == backup.id then
        row.name:SetTextColor(unpack(Theme.color.accent))
    else
        row.name:SetTextColor(unpack(Theme.color.textPrimary))
    end
    applyRowState(row, selectedID == backup.id, false)
end

function BackupRestoreTab:Refresh()
    if not frame then return end

    local BackupRestore = GP:GetModule("BackupRestore")
    frame.guildKey = BackupRestore:GetCurrentGuildKey()
    local backups = BackupRestore:GetBackups(frame.guildKey)
    local quarantineStatus = BackupRestore:GetQuarantineStatus(frame.guildKey)
    local automatic = BackupRestore:GetAutomaticStatus(frame.guildKey)

    local selected = selectedBackup()
    if selectedID and not selected then selectedID = nil end

    frame.guildText:SetText(frame.guildKey and string.format(GP.L["Guild: %s"], frame.guildKey) or GP.L["No roster data yet — try /gp scan."])
    frame.summaryText:SetText(frame.restoringBackup and GP.L["Validating restore and creating safety backup..."]
        or frame.creatingBackup and GP.L["Creating backup across frames..."]
        or string.format(GP.L["Showing %d backup(s). Keeping newest %d."], #backups, BackupRestore:GetMaxBackups()))
    if automatic then
        frame.automaticCheck:SetChecked(automatic.enabled)
        for key, button in pairs(frame.intervalButtons) do
            button.text:SetTextColor(unpack(key == automatic.interval and Theme.color.accent or Theme.color.textPrimary))
        end
        for keep, button in pairs(frame.retentionButtons) do
            button.text:SetTextColor(unpack(keep == automatic.keep and Theme.color.accent or Theme.color.textPrimary))
        end
        local status
        if automatic.inProgress then
            status = GP.L["Automatic backup: creating now..."]
        elseif automatic.lastReason then
            status = string.format(GP.L["Automatic backup deferred: %s"], automatic.lastReason)
        elseif automatic.lastSuccess then
            status = string.format(GP.L["Automatic backup: last %s; next eligible %s"],
                formatDate(automatic.lastSuccess), formatDate(automatic.nextEligible))
        elseif automatic.enabled then
            status = GP.L["Automatic backup: due at the next safe check."]
        else
            status = GP.L["Automatic backup: disabled."]
        end
        frame.automaticStatus:SetText(status)
    end
    list:SetData(backups, false)

    selected = selectedBackup()
    if selected then
        local canRestore = BackupRestore:CanRestoreBackup(frame.guildKey)
        local canRemove = BackupRestore:CanDeleteBackup(frame.guildKey, selected)
        local details = {
            selected.name or selected.id,
            string.format(GP.L["Class: %s"], selected.backupClass or "manual"),
            string.format(GP.L["State: %s"], selected.isValid and GP.L["Ready"] or GP.L["Blocked"]),
            string.format(GP.L["Created: %s"], formatDate(selected.createdAt)),
            string.format(GP.L["Created by: %s"], selected.createdBy or GP.L["Unknown"]),
            summaryLine(selected.summary),
        }
        if selected.snapshotMilliseconds then
            details[#details + 1] = string.format(GP.L["Snapshot time: %.1f ms"], selected.snapshotMilliseconds)
        end
        details[#details + 1] = ""
        for _, line in ipairs(comparisonLines(comparisonCache[selected.id])) do
            details[#details + 1] = line
        end
        details[#details + 1] = ""
        details[#details + 1] = GP.L["Restore replaces the current Guild Paragon data for this guild only. Backups are kept separately."]
        details[#details + 1] = GP.L["Backups are full guild snapshots and can increase memory use; keep only the restore points you need."]
        if quarantineStatus and quarantineStatus.validationState == "failed" then
            details[#details + 1] = ""
            details[#details + 1] = string.format(GP.L["Quarantine retained a failed restore review: %s"],
                quarantineStatus.reason or GP.L["Unknown"])
        end
        frame.detailText:SetText(table.concat(details, "\n"))
        frame.restoreButton:SetShown(canRestore and selected.isValid and not frame.restoringBackup)
        frame.removeButton:SetShown(canRemove)
        if not comparisonCache[selected.id] and not comparisonPending[selected.id] then
            comparisonPending[selected.id] = true
            BackupRestore:GetComparisonAsync(frame.guildKey, selected.id, function(rows)
                comparisonPending[selected.id] = nil
                comparisonCache[selected.id] = rows or {}
                if selectedID == selected.id then BackupRestoreTab:Refresh() end
            end)
        end
    else
        frame.detailText:SetText(GP.L["Select a backup to preview restore details."])
        frame.restoreButton:Hide()
        frame.removeButton:Hide()
    end
end

function BackupRestoreTab:Build(parent)
    local L = GP.L
    frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()

    local heading = frame:CreateFontString(nil, "ARTWORK")
    heading:SetFontObject(Theme.font.title)
    heading:SetPoint("TOPLEFT")
    heading:SetText(L["Backup & Restore"])

    local info = frame:CreateFontString(nil, "ARTWORK")
    info:SetFontObject(Theme.font.muted)
    info:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    info:SetWidth(620)
    info:SetJustifyH("LEFT")
    info:SetText(L["Create manual restore points for the current guild. Restore and remove actions require typed confirmation."])

    frame.guildText = frame:CreateFontString(nil, "ARTWORK")
    frame.guildText:SetFontObject(Theme.font.body)
    frame.guildText:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -18)
    frame.guildText:SetWidth(620)
    frame.guildText:SetJustifyH("LEFT")

    local nameBox = Theme:CreateEditBox(frame, 220)
    nameBox:SetPoint("TOPLEFT", frame.guildText, "BOTTOMLEFT", 0, -12)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local createButton = Theme:CreateButton(frame, L["Create Backup"])
    createButton:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    createButton:SetScript("OnClick", function()
        frame.creatingBackup = true
        createButton:Disable()
        createButton:SetText(L["Creating..."])
        BackupRestoreTab:Refresh()
        GP:GetModule("BackupRestore"):CreateBackupAsync(nameBox:GetText(), nil, nil, function(id, err, pruned)
            frame.creatingBackup = false
            createButton:Enable()
            createButton:SetText(L["Create Backup"])
            if id then
                selectedID = id
                nameBox:SetText("")
                if pruned and pruned > 0 then
                    GP:Print(string.format(L["Backup created. Pruned %d older backup(s)."], pruned))
                else
                    GP:Print(L["Backup created."])
                end
            else
                GP:Print(err)
            end
            BackupRestoreTab:Refresh()
        end)
    end)

    frame.summaryText = frame:CreateFontString(nil, "ARTWORK")
    frame.summaryText:SetFontObject(Theme.font.muted)
    frame.summaryText:SetPoint("TOPRIGHT", -Theme.layout.gutter, -4)
    frame.summaryText:SetJustifyH("RIGHT")

    frame.automaticCheck = createCheck(frame, L["Enable automatic backups"])
    frame.automaticCheck:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 0, -10)
    frame.automaticCheck:SetScript("OnClick", function(self)
        local ok, err = GP:GetModule("BackupRestore"):SetAutomaticEnabled(self:GetChecked())
        if not ok then self:SetChecked(false) GP:Print(err) end
        BackupRestoreTab:Refresh()
    end)

    local intervalLabel = frame:CreateFontString(nil, "ARTWORK")
    intervalLabel:SetFontObject(Theme.font.muted)
    intervalLabel:SetPoint("LEFT", frame.automaticCheck.Text, "RIGHT", 28, 0)
    intervalLabel:SetText(L["Interval:"])
    frame.intervalButtons = {}
    local previous = intervalLabel
    for _, definition in ipairs({ { "daily", L["Daily"] }, { "threeDays", L["Every 3 days"] }, { "weekly", L["Weekly"] } }) do
        local button = Theme:CreateButton(frame, definition[2])
        button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
        button:SetScript("OnClick", function()
            GP:GetModule("BackupRestore"):SetAutomaticInterval(definition[1])
            BackupRestoreTab:Refresh()
        end)
        frame.intervalButtons[definition[1]] = button
        previous = button
    end

    local retentionLabel = frame:CreateFontString(nil, "ARTWORK")
    retentionLabel:SetFontObject(Theme.font.muted)
    retentionLabel:SetPoint("LEFT", previous, "RIGHT", 18, 0)
    retentionLabel:SetText(L["Keep:"])
    frame.retentionButtons = {}
    previous = retentionLabel
    for keep = 1, 3 do
        local selectedKeep = keep
        local button = Theme:CreateButton(frame, tostring(selectedKeep))
        button:SetWidth(34)
        button:SetPoint("LEFT", previous, "RIGHT", 5, 0)
        button:SetScript("OnClick", function()
            GP:GetModule("BackupRestore"):SetAutomaticRetention(selectedKeep)
            BackupRestoreTab:Refresh()
        end)
        frame.retentionButtons[selectedKeep] = button
        previous = button
    end

    frame.automaticStatus = frame:CreateFontString(nil, "ARTWORK")
    frame.automaticStatus:SetFontObject(Theme.font.muted)
    frame.automaticStatus:SetPoint("TOPLEFT", frame.automaticCheck, "BOTTOMLEFT", 4, -8)
    frame.automaticStatus:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.automaticStatus:SetJustifyH("LEFT")

    local listPanel = Theme:CreatePanel(frame, "panel", "border")
    listPanel:SetPoint("TOPLEFT", frame.automaticStatus, "BOTTOMLEFT", -4, -12)
    listPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 760, Theme.layout.gutter)

    list = GP.UI.ScrollList:New(listPanel, ROW_HEIGHT, createRow)
    list:SetUpdateRow(updateRow)

    local detailPanel = Theme:CreatePanel(frame, "panel", "border")
    detailPanel:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", Theme.layout.gutter, 0)
    detailPanel:SetPoint("BOTTOMRIGHT", -Theme.layout.gutter, Theme.layout.gutter)

    local detailHeading = detailPanel:CreateFontString(nil, "ARTWORK")
    detailHeading:SetFontObject(Theme.font.heading)
    detailHeading:SetPoint("TOPLEFT", Theme.layout.gutter, -Theme.layout.gutter)
    detailHeading:SetText(L["Restore Preview"])

    frame.detailText = detailPanel:CreateFontString(nil, "ARTWORK")
    frame.detailText:SetFontObject(Theme.font.body)
    frame.detailText:SetPoint("TOPLEFT", detailHeading, "BOTTOMLEFT", 0, -10)
    frame.detailText:SetPoint("RIGHT", -Theme.layout.gutter, 0)
    frame.detailText:SetJustifyH("LEFT")
    frame.detailText:SetJustifyV("TOP")

    frame.restoreButton = Theme:CreateButton(detailPanel, L["Restore"])
    frame.restoreButton:SetPoint("BOTTOMLEFT", Theme.layout.gutter, Theme.layout.gutter)
    frame.restoreButton:SetScript("OnClick", function()
        local backup = selectedBackup()
        if backup then
            local guildName = backup.sourceGuildName or frame.guildKey
            local confirmation = string.format("%s RESTORE", guildName)
            StaticPopup_Show(RESTORE_POPUP, backup.name or backup.id, confirmation, {
                guildKey = frame.guildKey, id = backup.id, confirmation = confirmation,
            })
        end
    end)

    frame.removeButton = Theme:CreateButton(detailPanel, L["Remove"])
    frame.removeButton:SetPoint("LEFT", frame.restoreButton, "RIGHT", 8, 0)
    frame.removeButton:SetScript("OnClick", function()
        local backup = selectedBackup()
        if backup then
            local confirmation = backup.backupClass == "preRestore"
                and string.format("%s DELETE", backup.sourceGuildName or frame.guildKey) or "DELETE"
            StaticPopup_Show(REMOVE_POPUP, backup.name or backup.id, confirmation, {
                guildKey = frame.guildKey, id = backup.id, confirmation = confirmation,
            })
        end
    end)

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua: GuildParagon_RosterScanned in particular can fire
    -- many times in a row from one Guild Sync full-state apply. Collapse
    -- the burst to one refresh on the next frame instead.
    local function debouncedRefresh()
        comparisonCache, comparisonPending = {}, {}
        if not frame or not frame:IsShown() then
            refreshDirty = true
            return
        end
        GP:DebounceCall("BackupRestoreTab:Refresh", function()
            if frame and frame:IsShown() then
                refreshDirty = false
                BackupRestoreTab:Refresh()
            else
                refreshDirty = true
            end
        end)
    end
    BackupRestoreTab:RegisterMessage("GuildParagon_BackupsChanged", debouncedRefresh)
    BackupRestoreTab:RegisterMessage("GuildParagon_BackupScheduleChanged", debouncedRefresh)
    BackupRestoreTab:RegisterMessage("GuildParagon_RosterScanned", GP:MonitorWrap("listener.backup", debouncedRefresh))

    self:Refresh()
    return frame
end

function BackupRestoreTab:OnSelected()
    refreshDirty = false
    GP:GetModule("BackupRestore"):CheckAutomaticBackup("pageOpened")
    self:Refresh()
end
