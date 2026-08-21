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

local frame, list, selectedID
local refreshDirty = false

local function formatDate(ts)
    return type(ts) == "number" and date("%Y-%m-%d %H:%M", ts) or ""
end

local function summaryLine(summary)
    summary = summary or {}
    return string.format(GP.L["%d active, %d former, %d log, %d alt link(s), %d nickname(s), %d custom note(s)"],
        summary.active or 0, summary.former or 0, summary.log or 0, summary.alts or 0,
        summary.nicknames or 0, summary.customNotes or 0)
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

StaticPopupDialogs[RESTORE_POPUP] = StaticPopupDialogs[RESTORE_POPUP] or {
    text = GP.L["Restore backup '%s'?\n\nThis replaces Guild Paragon data for the current guild. Type RESTORE to confirm."],
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
        if not editBox or editBox:GetText() ~= "RESTORE" then
            GP:Print(GP.L["Restore cancelled. Type RESTORE exactly to confirm."])
            return
        end
        local ok, err = GP:GetModule("BackupRestore"):RestoreBackup(data.guildKey, data.id)
        if ok then
            GP:Print(GP.L["Backup restored. Reloading UI."])
            ReloadUI()
        else
            GP:Print(err)
            BackupRestoreTab:Refresh()
        end
    end,
}

StaticPopupDialogs[REMOVE_POPUP] = StaticPopupDialogs[REMOVE_POPUP] or {
    text = GP.L["Remove backup '%s'?\n\nType DELETE to confirm."],
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
        if not editBox or editBox:GetText() ~= "DELETE" then
            GP:Print(GP.L["Remove cancelled. Type DELETE exactly to confirm."])
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
    row.summary:SetText(summaryLine(backup.summary))

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

    local selected = selectedBackup()
    if selectedID and not selected then selectedID = nil end

    frame.guildText:SetText(frame.guildKey and string.format(GP.L["Guild: %s"], frame.guildKey) or GP.L["No roster data yet — try /gp scan."])
    frame.summaryText:SetText(string.format(GP.L["Showing %d backup(s). Keeping newest %d."], #backups, BackupRestore:GetMaxBackups()))
    list:SetData(backups, false)

    selected = selectedBackup()
    if selected then
        frame.detailText:SetText(table.concat({
            selected.name or selected.id,
            string.format(GP.L["Created: %s"], formatDate(selected.createdAt)),
            string.format(GP.L["Created by: %s"], selected.createdBy or GP.L["Unknown"]),
            summaryLine(selected.summary),
            "",
            GP.L["Restore replaces the current Guild Paragon data for this guild only. Backups are kept separately."],
            GP.L["Backups are full guild snapshots and can increase memory use; keep only the restore points you need."],
        }, "\n"))
        frame.restoreButton:Show()
        frame.removeButton:Show()
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
        local id, err, pruned = GP:GetModule("BackupRestore"):CreateBackup(nameBox:GetText())
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

    frame.summaryText = frame:CreateFontString(nil, "ARTWORK")
    frame.summaryText:SetFontObject(Theme.font.muted)
    frame.summaryText:SetPoint("TOPRIGHT", -Theme.layout.gutter, -4)
    frame.summaryText:SetJustifyH("RIGHT")

    local listPanel = Theme:CreatePanel(frame, "panel", "border")
    listPanel:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 0, -18)
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
            StaticPopup_Show(RESTORE_POPUP, backup.name or backup.id, nil, { guildKey = frame.guildKey, id = backup.id })
        end
    end)

    frame.removeButton = Theme:CreateButton(detailPanel, L["Remove"])
    frame.removeButton:SetPoint("LEFT", frame.restoreButton, "RIGHT", 8, 0)
    frame.removeButton:SetScript("OnClick", function()
        local backup = selectedBackup()
        if backup then
            StaticPopup_Show(REMOVE_POPUP, backup.name or backup.id, nil, { guildKey = frame.guildKey, id = backup.id })
        end
    end)

    -- Debounced (GP:DebounceCall) — see the matching comment in
    -- RosterTab.lua: GuildParagon_RosterScanned in particular can fire
    -- many times in a row from one Guild Sync full-state apply. Collapse
    -- the burst to one refresh on the next frame instead.
    local function debouncedRefresh()
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
    BackupRestoreTab:RegisterMessage("GuildParagon_RosterScanned", debouncedRefresh)

    self:Refresh()
    return frame
end

function BackupRestoreTab:OnSelected()
    refreshDirty = false
    self:Refresh()
end
