-- Open the native posting editor; Blizzard owns edits and submission.
local _, GP = ...
GP.UI.GuildRecruitment = {}
local Recruitment = GP.UI.GuildRecruitment

function Recruitment:IsOfficer()
    if GP:IsForeverClient() then return false end
    return GP:SafeCall(IsInGuild, false) == true
        and (GP:SafeCall(IsGuildLeader, false) == true
            or GP:SafeCall(C_GuildInfo and C_GuildInfo.IsGuildOfficer, false) == true)
end

function Recruitment:GetGuild()
    local applicants = GP:GetModule("GuildApplicants", true)
    if not applicants or not applicants:IsSafe() then return nil end
    if not self:IsOfficer() then return nil end
    if GP:SafeCall(C_ClubFinder and C_ClubFinder.IsEnabled, false) ~= true then return nil end
    local club = GP:SafeCall(C_Club and C_Club.GetGuildClubId, nil)
    if GP:IsSecretValue(club) or (type(club) ~= "number" and type(club) ~= "string") then return nil end
    if GP:SafeCall(C_ClubFinder.IsPostingBanned, true, club) ~= false then return nil end
    if type(C_ClubFinder.GetClubFinderDisableReason) ~= "function" then return nil end
    local ok, reason = pcall(C_ClubFinder.GetClubFinderDisableReason)
    if not ok or GP:IsSecretValue(reason) or reason ~= nil then return nil end
    return club
end

function Recruitment:Open()
    local club = self:GetGuild()
    if not club then
        GP:Print(GP.L["Guild recruitment settings are unavailable. You must be a guild officer or leader in a safe location, with Guild Finder posting enabled."])
        return false
    end
    local ok = pcall(function()
        if not CommunitiesFrame then
            if not C_AddOns or not C_AddOns.LoadAddOn then error("Communities unavailable") end
            C_AddOns.LoadAddOn("Blizzard_Communities")
        end
        local window = CommunitiesFrame
        if not window or not window.RecruitmentDialog or not window.SelectClub
            or not window.RecruitmentDialog.UpdatedPostingInformationInit then error("Editor unavailable") end
        -- Do not navigate applicant/roster display modes or simulate button clicks.
        if not window:IsShown() then ShowUIPanel(window) end
        if not window:IsShown() then error("Communities did not open") end
        local selected = window:GetSelectedClubId()
        if GP:IsSecretValue(selected) then error("Club unavailable") end
        if selected ~= club then
            if window.RecruitmentDialog:IsShown() then window.RecruitmentDialog:Hide() end
            window:SelectClub(club)
        end
        selected = window:GetSelectedClubId()
        if GP:IsSecretValue(selected) or selected ~= club then error("Guild not selected") end
        if not window.RecruitmentDialog:IsShown() then
            window.RecruitmentDialog:UpdatedPostingInformationInit()
        end
    end)
    if not ok then
        GP:Print(GP.L["Could not open guild recruitment settings. Open Guild & Communities and use its Recruitment button."])
        return false
    end
    GP.UI.MainWindow:Hide()
    return true
end
