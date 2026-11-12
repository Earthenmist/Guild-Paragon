local _, GP = ...

-- Optional surfaces differ between clients; do not replace Blizzard globals.
function GP:RegisterOptionalEvent(target, event, handler)
    if C_EventUtils and type(C_EventUtils.IsEventValid) == "function" then
        if self:SafeCall(C_EventUtils.IsEventValid, false, event) ~= true then return false end
    end
    if handler then return pcall(target.RegisterEvent, target, event, handler) end
    return pcall(target.RegisterEvent, target, event)
end

function GP:GetClassColor(classFile)
    if self:IsSecretValue(classFile) or type(classFile) ~= "string" then return nil end
    local color = C_ClassColor and self:SafeCall(C_ClassColor.GetClassColor, nil, classFile)
    return color or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
end

function GP:RequestNativeGuildRoster()
    return self:SafeCall(C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster, nil)
end

function GP:HasGuildChatHistory()
    return C_Club and type(C_Club.GetGuildClubId) == "function"
        and type(C_Club.GetStreams) == "function" and type(C_Club.GetMessagesBefore) == "function"
end

function GP:IsForeverClient()
    local version = self:SafeOptionalString(self:SafeCall(GetBuildInfo, nil))
    return version ~= nil and version:match("^1%.") ~= nil
end

function GP:HasHousingService()
    -- Housing is Retail-only; preserve Retail behavior regardless of service flags.
    return not self:IsForeverClient()
end

function GP:HasGuildFinder()
    if self:IsForeverClient() then return false end
    return C_ClubFinder and type(C_ClubFinder.RequestApplicantList) == "function"
        and Enum and Enum.ClubFinderRequestType ~= nil
end

function GP:PrintClientCompatibility()
    local version, build, _, interface = GetBuildInfo()
    self:Print(string.format(self.L["Client: %s (build %s), interface %s"],
        self:SafeOptionalString(version) or "?", self:SafeOptionalString(build) or "?",
        tostring(self:SafeNumber(interface, 0))))
    for _, entry in ipairs({
        {self.L["Guild Chat"], self:HasGuildChatHistory()},
        {self.L["Applications"], self:HasGuildFinder()},
        {self.L["Housing"], C_Housing and type(C_Housing.HouseFinderRequestNeighborhoods) == "function"},
        {self.L["Calendar"], C_Calendar and type(C_Calendar.CreateGuildAnnouncementEvent) == "function"},
    }) do
        self:Print(entry[1] .. ": " .. (entry[2] and self.L["API available"] or self.L["API unavailable"]))
    end
end
